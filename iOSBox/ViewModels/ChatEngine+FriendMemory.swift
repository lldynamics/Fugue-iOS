import Foundation
import SwiftData

extension ChatEngine {
    // MARK: - Friend Persistent Memory Extraction

    func resolveFriendTarget(
        for subject: FriendMemorySubject,
        in conversation: Conversation,
        providers: [ProviderConfig]
    ) -> ResolvedModelTarget? {
        if conversation.isGroupMode {
            if let matchingMember = conversation.activeGroupMembers.first(where: {
                FriendMemoryStore.SubjectMatch.matches(member: $0, subject: subject)
            }), let resolved = AssistancePolicy.resolve(matchingMember.target, providers: providers) {
                return resolved
            }
        } else {
            if let personaTarget = conversation.assistanceSettings.privatePersona?.target,
               let resolved = AssistancePolicy.resolve(personaTarget, providers: providers) {
                return resolved
            }
            if let primary = conversation.primaryTarget,
               let resolved = AssistancePolicy.resolve(primary, providers: providers) {
                return resolved
            }
        }
        return titleTarget(in: conversation, providers: providers)
    }

    /// Relevant messages in the active branch involving the user and this specific friend.
    func relevantMessagesForFriendMemory(
        subject: FriendMemorySubject,
        in conversation: Conversation
    ) -> [ChatMessage] {
        let active = ConversationTree.activeMessages(in: conversation)
        let eligible = eligiblePromptContext(active).filter {
            !$0.isStreaming
                && ($0.errorMessage?.isEmpty ?? true)
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard conversation.isGroupMode else {
            let requiresPersonaFlag = conversation.activeBookFriend == nil
                && conversation.assistanceSettings.privatePersona != nil
            return eligible.filter { msg in
                if msg.role == .user { return true }
                guard msg.role == .assistant else { return false }
                return !requiresPersonaFlag || msg.assistanceMetadata.isPersonaSimulation
            }
        }
        let targetMemberIDs = Set(
            conversation.groupMembers
                .filter { FriendMemoryStore.SubjectMatch.matches(member: $0, subject: subject) }
                .map(\.id)
        )
        return eligible.filter { msg in
            if msg.role == .user { return true }
            guard msg.role == .assistant else { return false }
            if let mid = msg.assistanceMetadata.groupMemberID, targetMemberIDs.contains(mid) {
                return true
            }
            if let mName = msg.assistanceMetadata.groupMemberName,
               FriendMemorySubject.normalizeCharacterName(mName) == FriendMemorySubject.normalizeCharacterName(subject.characterName) {
                return true
            }
            return false
        }
    }

    func scheduleFriendMemoryExtractionIfNeeded(
        for conversation: Conversation,
        speakerKeysFilter: Set<String>? = nil,
        providers: [ProviderConfig],
        context: ModelContext?,
        store: FriendMemoryStore? = nil
    ) {
        let store = store ?? self.friendMemoryStore
        if store === FriendMemoryStore.shared,
           let checkContext = context ?? conversation.modelContext,
           checkContext.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
            return
        }
        guard Self.isAlive(conversation), !conversation.isArenaMode else { return }
        let subjects = FriendMemorySubject.subjects(in: conversation).filter { subject in
            guard let filter = speakerKeysFilter else { return true }
            return filter.contains(subject.friendKey)
        }
        guard !subjects.isEmpty else { return }

        for subject in subjects {
            let rec = store.record(for: subject)
            guard rec.isEnabled && rec.autoExtractEnabled else { continue }
            let relevant = relevantMessagesForFriendMemory(subject: subject, in: conversation)
            let hasAssistantTurn = relevant.contains { $0.role == .assistant }
            let hasUserTurn = relevant.contains { $0.role == .user }
            guard hasUserTurn && hasAssistantTurn, let lastMsg = relevant.last else { continue }

            let checkpoint = rec.conversationCheckpoints[conversation.id]
            let newCount: Int
            if let checkpoint,
               let prevIdx = relevant.firstIndex(where: { $0.id == checkpoint.lastProcessedMessageID }) {
                newCount = relevant.count - (prevIdx + 1)
            } else {
                newCount = relevant.count
            }
            guard newCount >= FriendMemoryStore.autoExtractMinNewMessages else { continue }

            let taskKey = "\(conversation.id.uuidString):\(subject.friendKey)"
            guard activeFriendMemoryTasks[taskKey] == nil else { continue }

            let token = UUID()
            activeFriendMemoryTokens[taskKey] = token
            extractingFriendKeys.insert(subject.friendKey)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.activeFriendMemoryTokens[taskKey] == token {
                        self.activeFriendMemoryTokens.removeValue(forKey: taskKey)
                        self.activeFriendMemoryTasks.removeValue(forKey: taskKey)
                        self.extractingFriendKeys.remove(subject.friendKey)
                        self.updateBackgroundExecution()
                    }
                }
                _ = try? await self.performFriendMemoryExtraction(
                    for: subject,
                    in: conversation,
                    relevantMessages: relevant,
                    lastMessageID: lastMsg.id,
                    force: false,
                    providers: providers,
                    context: context,
                    store: store
                )
            }
            activeFriendMemoryTasks[taskKey] = task
            updateBackgroundExecution()
        }
    }

    @discardableResult
    func extractFriendMemoryNow(
        for subject: FriendMemorySubject,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext?,
        store: FriendMemoryStore? = nil
    ) async throws -> Bool {
        let store = store ?? self.friendMemoryStore
        let relevant = relevantMessagesForFriendMemory(subject: subject, in: conversation)
        guard let lastMsg = relevant.last,
              relevant.contains(where: { $0.role == .user }) else {
            return false
        }
        let taskKey = "\(conversation.id.uuidString):\(subject.friendKey)"
        activeFriendMemoryTasks[taskKey]?.cancel()
        extractingFriendKeys.insert(subject.friendKey)
        defer {
            extractingFriendKeys.remove(subject.friendKey)
            updateBackgroundExecution()
        }
        return try await performFriendMemoryExtraction(
            for: subject,
            in: conversation,
            relevantMessages: relevant,
            lastMessageID: lastMsg.id,
            force: true,
            providers: providers,
            context: context,
            store: store
        )
    }

    private func performFriendMemoryExtraction(
        for subject: FriendMemorySubject,
        in conversation: Conversation,
        relevantMessages: [ChatMessage],
        lastMessageID: UUID,
        force: Bool,
        providers: [ProviderConfig],
        context: ModelContext?,
        store: FriendMemoryStore
    ) async throws -> Bool {
        guard Self.isAlive(conversation) else { return false }
        guard let resolvedTarget = resolveFriendTarget(for: subject, in: conversation, providers: providers),
              let provider = providers.first(where: { $0.id == resolvedTarget.providerID && $0.isEnabled && !$0.isDeleted }) else {
            if force { throw LLMError.unavailableModel }
            return false
        }
        let isLocalHost = NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)
        guard provider.hasAuthentication || isLocalHost else {
            if force { throw LLMError.missingAPIKey(provider.name) }
            return false
        }

        let rec = store.record(for: subject)
        if !force && (!rec.isEnabled || !rec.autoExtractEnabled) {
            return false
        }

        let windowMessages: [ChatMessage] = {
            if !force,
               let cp = rec.conversationCheckpoints[conversation.id],
               let prevIdx = relevantMessages.firstIndex(where: { $0.id == cp.lastProcessedMessageID }),
               prevIdx + 1 < relevantMessages.count {
                let start = max(0, prevIdx - 1)
                return Array(relevantMessages[start...].suffix(14))
            }
            return Array(relevantMessages.suffix(14))
        }()
        guard !windowMessages.isEmpty else { return false }

        let preferEnglish = GroupDiscussionCoordinator.prefersEnglishPrompts(in: windowMessages)
        let currentSummary = store.visibleSummary(for: subject) ?? ""
        let existingItems = store.visibleEntries(for: subject, includeDisabled: true).map(\.content)

        let transcript = windowMessages.map { msg -> String in
            let speaker = msg.role == .user ? "User" : subject.characterName
            let snippet = String(msg.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            return "\(speaker): \(snippet)"
        }.joined(separator: "\n\n")

        let spoilerRule: String = {
            guard subject.kind == .bookFriend else { return "" }
            if let ch = subject.currentThroughChapter {
                return preferEnglish
                    ? "\n- Spoiler boundary: the user has read up to chapter index \(ch + 1). Never infer or mention plot events beyond what appears in the dialogue above."
                    : "\n- 防剧透边界：用户当前仅读到第 \(ch + 1) 节，切勿推测或写入对话中未出现的后续情节。"
            }
            return ""
        }()

        let systemPrompt: String
        if preferEnglish {
            systemPrompt = """
            You maintain persistent relationship memory for "\(subject.characterName)" with the user.
            Update the shared memory incrementally from the recent dialogue and output ONLY valid JSON matching:
            {"relationship_summary":"1-2 sentences on rapport, ongoing topics, and where you left off","upsert_memories":["concise durable shared memory, user situation/preference, or promise (max 5 new items)"],"obsolete_memories":["exact existing memory text superseded by newer facts"]}
            Rules:
            - Keep existing memories in mind so you do NOT output duplicates; return [] for upsert_memories if nothing new is worth remembering long-term.
            - Write each item from "\(subject.characterName)"'s perspective of knowing the user (under 120 chars each).\(spoilerRule)
            - Output raw JSON only, no markdown fences.
            """
        } else {
            systemPrompt = """
            你负责维护好友「\(subject.characterName)」对用户的专属持续记忆。
            请结合已有记忆与最新对话增量提炼，并**仅输出合法 JSON**（不要代码块包裹），格式严格如下：
            {"relationship_summary":"1～2 句话概括你们的熟悉关系、共同关注点与上次聊到的脉络","upsert_memories":["值得长期记住的共同话题、用户近况偏好或约定（单次最多新增 5 条，每条不超过 80 字）"],"obsolete_memories":["已被新近况取代的旧记忆原文（无则留空数组）"]}
            规则：
            - 参考下方已有记忆避免重复输出相同内容；若本段寒暄无新增长期信息，`upsert_memories` 返回 `[]`。\(spoilerRule)
            - 只输出纯 JSON 对象。
            """
        }

        let existingJSON = (try? String(decoding: JSONEncoder().encode(existingItems), as: UTF8.self)) ?? "[]"
        let userPayload = """
        Existing relationship_summary: \(currentSummary.isEmpty ? "(none)" : currentSummary)
        Existing memories: \(existingJSON)

        Recent dialogue:
        \(transcript)
        """

        let convID = conversation.id
        var request = LLMChatRequest(
            providerName: provider.name,
            protocolType: provider.protocolType,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            apiKeys: provider.extraAPIKeys,
            customHeaders: provider.resolvedCustomHeaders,
            modelID: resolvedTarget.modelID,
            supportsReasoning: false,
            systemPrompt: systemPrompt,
            messages: [LLMPromptMessage(role: .user, content: userPayload)],
            temperature: 0.2,
            topP: 1.0,
            maxOutputTokens: 600,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enablePromptCaching: false,
            idleTimeoutSeconds: provider.customIdleTimeout
        )

        let validateRecipient = provider.transmissionCheck(for: resolvedTarget.modelID)
        request.validateBeforeSending = { [weak conversation] in
            try validateRecipient()
            guard let conversation, Self.isAlive(conversation) else {
                throw AppCompliance.RequestChanged()
            }
        }

        let ledgerContext = context ?? conversation.modelContext
        let spec = provider.enabledModels.first { $0.id == resolvedTarget.modelID }
        var record: RequestRecord?
        var started = ContinuousClock.now
        var collected = ""
        var abnormalFinish = false

        defer {
            if let ledgerContext, ledgerContext.hasChanges {
                try? ledgerContext.save()
            }
        }

        do {
            try Task.checkCancellation()
            try request.validateBeforeSending?()
            if let ledgerContext {
                let created = RequestRecord(
                    target: resolvedTarget,
                    spec: spec,
                    conversationID: convID,
                    messageID: lastMessageID,
                    kind: .synthesis
                )
                ledgerContext.insert(created)
                do {
                    try ledgerContext.save()
                    record = created
                } catch {
                    ledgerContext.delete(created)
                }
            }
            started = ContinuousClock.now
            for try await event in self.stream(request) {
                try Task.checkCancellation()
                let elapsed = Self.milliseconds(started.duration(to: .now))
                record?.observe(event, elapsedMs: elapsed)
                switch event {
                case .retrying(let status):
                    if let ledgerContext, let current = record {
                        record = current.startRetry(
                            after: status,
                            elapsedMs: elapsed,
                            target: resolvedTarget,
                            spec: spec,
                            in: ledgerContext
                        )
                        try? ledgerContext.save()
                    }
                    started = .now
                    collected = ""
                    abnormalFinish = false
                case .contentDelta(let delta):
                    collected += delta
                case .finished:
                    abnormalFinish = true
                case .toolCall:
                    throw LLMError.unavailableTool
                default:
                    break
                }
            }
            try Task.checkCancellation()
            try request.validateBeforeSending?()
        } catch {
            if let record {
                if case LLMError.httpError(let status, _) = error {
                    record.httpStatus = status
                }
                record.finish(
                    Self.isCancellation(error) ? .cancelled : .failed,
                    elapsedMs: Self.milliseconds(started.duration(to: .now))
                )
            }
            if force { throw error }
            return false
        }

        let cleaned = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !abnormalFinish, let payload = FriendMemoryStore.parseExtractionPayload(from: cleaned) else {
            record?.finish(abnormalFinish ? .incomplete : .failed, elapsedMs: Self.milliseconds(started.duration(to: .now)))
            return false
        }
        record?.finish(.succeeded, elapsedMs: Self.milliseconds(started.duration(to: .now)))

        let checkpoint = FriendConversationCheckpoint(
            lastProcessedMessageID: lastMessageID,
            processedRelevantCount: relevantMessages.count,
            updatedAt: Date()
        )
        let changed = store.applyExtraction(
            payload,
            for: subject,
            conversationID: convID,
            checkpoint: checkpoint
        )
        if !changed {
            store.updateCheckpoint(checkpoint, conversationID: convID, for: subject)
        }
        return changed
    }
}

extension FriendMemoryStore {
    enum SubjectMatch {
        static func matches(member: GroupMember, subject: FriendMemorySubject) -> Bool {
            guard let memberSubject = FriendMemorySubject.from(member: member) else { return false }
            return memberSubject.friendKey == subject.friendKey
        }
    }
}
