import Foundation
import SwiftData

extension ChatEngine {
    // MARK: - External Webpage Approval Gate

    func pendingWebpageApproval(in conversationID: UUID) -> PendingWebpageApproval? {
        pendingWebpageApprovals.first { $0.conversationID == conversationID }
    }

    func cancelWebpageApprovals(in conversationID: UUID) {
        for request in pendingWebpageApprovals where request.conversationID == conversationID {
            resolvePendingWebpageApproval(id: request.id, decision: .deny, rememberHost: false)
        }
    }

    func resolvePendingWebpageApproval(id: UUID, decision: WebpageApprovalDecision, rememberHost: Bool) {
        guard let index = pendingWebpageApprovals.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingWebpageApprovals.remove(at: index)
        if rememberHost, decision == .allow, pending.url.query == nil,
           let host = pending.url.host?.lowercased(), !host.isEmpty {
            approvedWebpageHostsByConversation[pending.conversationID, default: []].insert(host)
        }
        pending.continuation.resume(returning: decision)
    }

    func requestWebpageApproval(for url: URL, conversationID: UUID) async -> WebpageApprovalDecision {
        if let custom = customWebpageApprovalHandler {
            return await custom(url, conversationID)
        }
        // Only trust conversation-level host approval when the URL carries no query string,
        // preventing query-parameter exfiltration (`https://trusted.tld/?secret=...`).
        if url.query == nil,
           let host = url.host?.lowercased(),
           approvedWebpageHostsByConversation[conversationID]?.contains(host) == true {
            return .allow
        }

        let promptID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .deny)
                    return
                }
                pendingWebpageApprovals.append(PendingWebpageApproval(
                    id: promptID, conversationID: conversationID, url: url, continuation: continuation
                ))
            }
        } onCancel: {
            Task { @MainActor in
                self.resolvePendingWebpageApproval(id: promptID, decision: .deny, rememberHost: false)
            }
        }
    }

    private func reloadKnowledgeSnapshots(
        volumeIDs: [UUID],
        conversationID: UUID
    ) -> [KnowledgeDocumentSnapshot] {
        guard let ctx = activeGenerations[conversationID]?.context else { return [] }
        return ProjectKnowledgeSearch.snapshots(for: volumeIDs, in: ctx, skipCachedIn: nil)
    }

    // MARK: - Streaming & Multi-Round Tool Execution

    func launchStreamingTasks(
        slots: [StreamSlot],
        historySnapshot: [LLMPromptMessage],
        searchQuery: String?,
        conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext,
        expectedTitleForAutoGenerate: String? = nil
    ) {
        let convID = conversation.id
        let token = UUID()
        activeConversationIDs.insert(convID)

        let masterTask = Task { @MainActor in
            var workingHistory = historySnapshot

            let firstLabel = slots.first?.candidates.first?.modelDisplayName ?? "AI"
            LiveActivityCoordinator.shared.start(
                conversationID: convID,
                chatTitle: conversation.title,
                modeBadge: slots.count > 1 ? String(localized: "并发对比") : String(localized: "对话"),
                speakerOrModel: firstLabel,
                phaseText: String(localized: "正在生成…"),
                totalTurns: slots.count
            )

            let limits = conversation.readingChapterLimits
            let usesKnowledge = !slots.contains { $0.message.assistanceMetadata.omittedKnowledge } && !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty
            let isSynthesisTurn = slots.allSatisfy { $0.kind == .synthesis }
            let isContinuationTurn = slots.allSatisfy { $0.kind == .continuation || $0.appendToExisting }
            if !isSynthesisTurn && usesKnowledge {
                if isContinuationTurn {
                    if let existingKB = slots.compactMap({ $0.message.assistanceMetadata.knowledgeEvidence }).first {
                        if !existingKB.passages.isEmpty {
                            let targetIdx = workingHistory.dropLast().lastIndex(where: { $0.role == .user })
                                ?? workingHistory.indices.last
                            if let targetIdx {
                                let targetMsg = workingHistory[targetIdx]
                                workingHistory[targetIdx] = LLMPromptMessage(
                                    role: targetMsg.role,
                                    content: (targetMsg.content.isEmpty ? "" : targetMsg.content + "\n\n") + existingKB.promptText(),
                                    attachments: targetMsg.attachments
                                )
                            }
                        }
                    } else if let contMsg = slots.first?.message {
                        let active = ConversationTree.activeMessages(in: conversation)
                        let cutoff = active.firstIndex(where: { $0.id == contMsg.id }).map { Array(active[..<$0]) } ?? active
                        let originalQuestion = self.bookQuestion(in: cutoff)
                        if !originalQuestion.isEmpty,
                           let kbEv = try? await ProjectKnowledgeSearch.retrieve(
                               volumeIDs: conversation.assistanceSettings.knowledgeVolumeIDs,
                               in: context,
                               query: originalQuestion,
                               maxPassages: 4,
                               chapterLimits: limits
                           ),
                           !kbEv.passages.isEmpty {
                            for slot in slots where Self.isAlive(slot.message) && slot.message.assistanceMetadata.knowledgeEvidence == nil {
                                var meta = slot.message.assistanceMetadata
                                meta.knowledgeEvidence = kbEv
                                slot.message.assistanceMetadata = meta
                            }
                            let targetIdx = workingHistory.dropLast().lastIndex(where: { $0.role == .user })
                                ?? workingHistory.indices.last
                            if let targetIdx {
                                let targetMsg = workingHistory[targetIdx]
                                workingHistory[targetIdx] = LLMPromptMessage(
                                    role: targetMsg.role,
                                    content: (targetMsg.content.isEmpty ? "" : targetMsg.content + "\n\n") + kbEv.promptText(),
                                    attachments: targetMsg.attachments
                                )
                            }
                        }
                    }
                } else {
                    let question = workingHistory.last(where: { $0.role == .user })?.content ?? ""
                    if let kbEv = try? await ProjectKnowledgeSearch.retrieve(
                        volumeIDs: conversation.assistanceSettings.knowledgeVolumeIDs,
                        in: context,
                        query: question,
                        maxPassages: 4,
                        chapterLimits: limits
                    ) {
                        for slot in slots where Self.isAlive(slot.message) {
                            var meta = slot.message.assistanceMetadata
                            meta.knowledgeEvidence = kbEv
                            slot.message.assistanceMetadata = meta
                        }
                        if !kbEv.passages.isEmpty, let lastIdx = workingHistory.indices.last {
                            let oldLast = workingHistory[lastIdx]
                            workingHistory[lastIdx] = LLMPromptMessage(
                                role: oldLast.role,
                                content: (oldLast.content.isEmpty ? "" : oldLast.content + "\n\n") + kbEv.promptText(),
                                attachments: oldLast.attachments
                            )
                        }
                    }
                }
            }

            let workingSlots = slots

            if let searchQuery, let primaryMessage = workingSlots.first?.message {
                let searchStart = ContinuousClock.now
                let searchRecord = RequestRecord(
                    target: TavilySearchClient.ledgerTarget,
                    spec: nil,
                    conversationID: convID,
                    messageID: primaryMessage.id,
                    kind: .webSearch
                )
                context.insert(searchRecord)

                do {
                    let evidence = try await self.search(searchQuery)
                    try Task.checkCancellation()
                    searchRecord.finish(.succeeded, elapsedMs: Self.milliseconds(searchStart.duration(to: .now)))

                    for slot in slots where Self.isAlive(slot.message) {
                        var meta = slot.message.assistanceMetadata
                        meta.search = evidence
                        slot.message.assistanceMetadata = meta
                    }

                    if let lastIdx = workingHistory.indices.last {
                        let oldLast = workingHistory[lastIdx]
                        let augmented = oldLast.content.isEmpty
                            ? evidence.prompt
                            : (oldLast.content + "\n\n" + evidence.prompt)
                        workingHistory[lastIdx] = LLMPromptMessage(
                            role: oldLast.role,
                            content: augmented,
                            attachments: oldLast.attachments
                        )
                    }
                } catch {
                    let elapsed = Self.milliseconds(searchStart.duration(to: .now))
                    if Self.isCancellation(error) {
                        searchRecord.finish(.cancelled, elapsedMs: elapsed)
                        for slot in slots where Self.isAlive(slot.message) {
                            slot.message.errorMessage = String(localized: "已停止生成")
                            slot.message.isStreaming = false
                        }
                    } else {
                        if case SearchError.http(let code) = error {
                            searchRecord.httpStatus = code
                        }
                        searchRecord.finish(.failed, elapsedMs: elapsed)
                        for slot in slots where Self.isAlive(slot.message) {
                            slot.message.errorMessage = error.localizedDescription
                            slot.message.isStreaming = false
                        }
                    }
                    if Self.isAlive(conversation) {
                        conversation.updatedAt = Date()
                        try? context.save()
                    }
                    self.finishGeneration(conversationID: convID, token: token, statuses: [searchRecord.status])
                    return
                }
            }

            let finalHistory = workingHistory
            await withTaskGroup(of: Void.self) { group in
                for var slot in workingSlots {
                    if usesKnowledge { slot.knowledgeChapterLimits = limits }
                    group.addTask { @MainActor [slot] in
                        _ = await self.runSlotWithFallback(
                            slot: slot,
                            historySnapshot: finalHistory,
                            conversation: conversation,
                            providers: providers,
                            context: context
                        )
                    }
                }
            }

            if Self.isAlive(conversation) {
                conversation.updatedAt = Date()
                try? context.save()
                SpotlightIndexService.shared.indexConversation(conversation)
            }
            self.finishGeneration(conversationID: convID, token: token, statuses: slots.map { Self.outcomeStatus(of: $0.message) })

            if let expectedTitle = expectedTitleForAutoGenerate, Self.isAlive(conversation) {
                self.scheduleAutoTitleGeneration(
                    for: conversation,
                    providers: providers,
                    context: context,
                    expectedUnchangedTitle: expectedTitle
                )
            }
            if Self.isAlive(conversation) {
                self.scheduleRollingSummaryIfNeeded(for: conversation, providers: providers, context: context)
                self.scheduleFriendMemoryExtractionIfNeeded(for: conversation, providers: providers, context: context)
            }
        }

        activeGenerations[convID] = ActiveGeneration(token: token, task: masterTask, context: context)
        updateBackgroundExecution()
    }

    @discardableResult
    func runSlotWithFallback(
        slot: StreamSlot,
        historySnapshot: [LLMPromptMessage],
        conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) async -> GroupTurnDirective? {
        let message = slot.message
        let operationID = UUID()
        var attemptNumber = 1

        let preferEnglishBookPrompt = slot.bookTurn != nil && GroupDiscussionCoordinator.prefersEnglishPrompts(
            in: ConversationTree.activeMessages(in: conversation)
        )
        var groundedHistory = historySnapshot
        if let turn = slot.bookTurn {
            do {
                guard Self.isAlive(message), Self.isAlive(conversation), turn.matches(conversation, target: slot.candidates.first) else { throw BookImportError.unavailable }
                let book = try BookLibrary.source(for: turn.friend, in: context)
                let evidence = try await BookReferenceSearch.shared.reference(
                    for: turn.friend,
                    manuscript: book.manuscript,
                    question: turn.question
                )
                try Task.checkCancellation()
                guard Self.isAlive(message), Self.isAlive(conversation), turn.matches(conversation, target: slot.candidates.first),
                      let i = groundedHistory.lastIndex(where: { $0.role == .user }) else { throw BookImportError.unavailable }
                let original = groundedHistory[i]
                groundedHistory[i] = LLMPromptMessage(role: .user, content: original.content + "\n\n" + (try evidence.referenceText(preferEnglish: preferEnglishBookPrompt)),
                                                      attachments: original.attachments)
                message.assistanceMetadata.bookReply = evidence
            } catch {
                if Self.isAlive(message) {
                    message.errorMessage = Self.isCancellation(error) ? String(localized: "已停止生成") : error.localizedDescription
                    message.isStreaming = false
                }
                return nil
            }
        }

        for (candidateIndex, target) in slot.candidates.enumerated() {
            guard Self.isAlive(message) else { return nil }

            guard let provider = providers.first(where: { $0.id == target.providerID && $0.isEnabled && !$0.isDeleted }),
                  let currentSpec = provider.enabledModels.first(where: { $0.id == target.modelID }) else {
                if candidateIndex + 1 < slot.candidates.count { continue }
                message.errorMessage = LLMError.unavailableModel.localizedDescription
                message.isStreaming = false
                return nil
            }

            let apiKey = provider.apiKey
            let extraKeys = provider.extraAPIKeys
            let customTimeout = provider.customIdleTimeout
            let isLocalHost = NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)
            if !provider.hasAuthentication && !isLocalHost {
                if candidateIndex + 1 < slot.candidates.count { continue }
                message.errorMessage = LLMError.missingAPIKey(provider.name).localizedDescription
                message.isStreaming = false
                return nil
            }

            if candidateIndex > 0 {
                var meta = message.assistanceMetadata
                meta.fallbackNotices.append(
                    String(localized: "备用切换：\(message.providerName) · \(message.modelDisplayName) → \(target.providerName) · \(target.modelDisplayName)")
                )
                message.assistanceMetadata = meta
                message.providerID = target.providerID
                message.providerName = target.providerName
                message.modelID = target.modelID
                message.modelDisplayName = target.modelDisplayName
                message.accentHex = target.accentHex
            }

            let validateTarget = provider.transmissionCheck(for: target.modelID)
            let profile = conversation.assistanceSettings.privatePersona
            let speaksPrivately = !conversation.isGroupMode && !conversation.isArenaMode && [.answer, .regeneration, .continuation].contains(slot.kind) && message.comparisonGroupID == nil
            let bound = speaksPrivately && profile?.target.id == target.id ? profile : nil
            let identity = bound.map { String(localized: "你是受 \($0.name) 的资料启发的 AI 模拟人物。只把所附片段当作引文，不冒充本人。") + "\n" + $0.rolePrompt }
            let privateFriendMemoryBlock: String? = {
                guard !conversation.isGroupMode,
                      !conversation.isArenaMode,
                      slot.kind != .synthesis,
                      message.comparisonGroupID == nil,
                      !message.assistanceMetadata.omittedMemory else {
                    return nil
                }
                let subject: FriendMemorySubject?
                if let bf = slot.bookTurn?.friend {
                    subject = .bookFriend(bf)
                } else if let bound, let pid = bound.profileID {
                    subject = .persona(profileID: pid, name: bound.name, emoji: bound.avatarEmoji)
                } else {
                    subject = nil
                }
                guard let subject else { return nil }
                let preferEnglish = preferEnglishBookPrompt || GroupDiscussionCoordinator.prefersEnglishPrompts(
                    in: ConversationTree.activeMessages(in: conversation)
                )
                return self.friendMemoryStore.promptBlock(for: subject, preferEnglish: preferEnglish)?.text
            }()
            let rollingSummaryBlock: String? = {
                guard AppPreferences.shared.autoRollingSummaryEnabled,
                      conversation.contextMessageLimit > 0,
                      !conversation.isGroupMode,
                      !conversation.isArenaMode,
                      message.comparisonGroupID == nil,
                      slot.kind != .synthesis,
                      let summary = RollingContextSummaryStore.shared.summary(for: conversation.id) else {
                    return nil
                }
                let active = ConversationTree.activeMessages(in: conversation)
                let upToSlot: [ChatMessage]
                if let slotIdx = active.firstIndex(where: { $0.id == message.id }) {
                    upToSlot = Array(active[...slotIdx])
                } else {
                    upToSlot = active
                }
                let latestDividerID = upToSlot.last(where: { $0.assistanceMetadata.isContextDivider })?.id
                let collapsed = self.eligiblePromptContext(upToSlot)
                let dropped = RollingContextSummaryStore.droppedMessages(
                    from: collapsed,
                    limit: conversation.contextMessageLimit
                )
                guard RollingContextSummaryStore.isSummaryValid(
                    summary,
                    dropped: dropped,
                    latestContextDividerID: latestDividerID
                ) else {
                    self.invalidateStaleRollingSummaryIfNeeded(in: conversation, branchMessages: active)
                    return nil
                }
                return RollingContextSummaryStore.promptBlock(for: summary)
            }()
            let rawSystemPrompt = [slot.systemPromptOverride ?? conversation.systemPrompt, rollingSummaryBlock, identity, slot.bookTurn?.friend.systemInstruction(preferEnglish: preferEnglishBookPrompt), privateFriendMemoryBlock].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let renderedSystemPrompt = PromptTemplateEngine.render(rawSystemPrompt, target: target)
            let shouldEnableCache = conversation.assistanceSettings.enablePromptCaching
                && slot.kind != .synthesis

            var workingHistory = groundedHistory
            if speaksPrivately, profile != nil {
                if !slot.appendToExisting {
                    message.assistanceMetadata.isPersonaSimulation = bound != nil
                    message.assistanceMetadata.privateSpeaker = bound.map(PersonaByline.init)
                    message.assistanceMetadata.personaExcerpts = nil
                } else if let bound {
                    message.assistanceMetadata.isPersonaSimulation = true
                    if message.assistanceMetadata.privateSpeaker == nil { message.assistanceMetadata.privateSpeaker = PersonaByline(bound) }
                }
                if let bound, let i = workingHistory.lastIndex(where: { $0.role == .user }) {
                    let turn = workingHistory[i]
                    let topic = slot.kind == .continuation ? workingHistory[..<i].last(where: { $0.role == .user })?.content : turn.content
                    let samples = PersonaMaterials.excerpts(bound.persona?.materials ?? [], topic: topic ?? turn.content)
                    if let references = PersonaMaterials.referenceBlock(samples) {
                        workingHistory[i] = LLMPromptMessage(role: .user, content: turn.content + "\n\n" + references, attachments: turn.attachments)
                        message.assistanceMetadata.appendPersonaExcerpts(samples)
                    }
                }
            }
            var toolRound = 0
            var remainingToolCalls = AgentToolRunner.maxCallsPerTurn
            var remainingSearches = AgentToolRunner.maxSearchesPerTurn

            roundLoop: while true {
                let roundKind: RequestKind = toolRound == 0 ? slot.kind : .agentTool
                let effectiveTemperature: Double?
                if let customTemp = slot.temperatureOverride {
                    effectiveTemperature = customTemp
                } else if slot.kind == .synthesis {
                    effectiveTemperature = 0.2
                } else {
                    effectiveTemperature = conversation.useCustomTemperature ? conversation.temperature : nil
                }
                var request = LLMChatRequest(
                    providerName: provider.name,
                    protocolType: provider.protocolType,
                    baseURL: provider.baseURL,
                    apiKey: apiKey,
                    apiKeys: extraKeys,
                    customHeaders: provider.resolvedCustomHeaders,
                    modelID: target.modelID,
                    supportsReasoning: currentSpec.supportsReasoning,
                    systemPrompt: renderedSystemPrompt,
                    messages: workingHistory,
                    temperature: effectiveTemperature,
                    topP: slot.kind == .synthesis ? 1.0 : conversation.topP,
                    maxOutputTokens: conversation.maxOutputTokens > 0 ? conversation.maxOutputTokens : nil,
                    enableThinking: slot.kind == .synthesis ? false : conversation.enableThinking,
                    thinkingBudgetTokens: conversation.thinkingBudgetTokens,
                    enablePromptCaching: shouldEnableCache,
                    enableNativeSearch: slot.kind != .synthesis && !conversation.isGroupMode && conversation.assistanceSettings.enableNativeGrounding,
                    idleTimeoutSeconds: customTimeout,
                    tools: toolRound < AgentToolRunner.maxToolRounds && conversation.assistanceSettings.enableAgentTools
                        && !conversation.isGroupMode && !conversation.isArenaMode ? slot.tools : []
                )
                let requiresTools = !request.tools.isEmpty || toolRound > 0
                request.validateBeforeSending = { [weak conversation] in
                    try validateTarget()
                    if let limits = slot.knowledgeChapterLimits {
                        guard let conversation, Self.isAlive(conversation), conversation.readingChapterLimits == limits else {
                            throw BookImportError.unavailable
                        }
                    }
                    if let turn = slot.bookTurn {
                        guard let conversation, Self.isAlive(conversation), turn.matches(conversation, target: target),
                              try BookLibrary.find(turn.friend.bookID, in: context) != nil else { throw BookImportError.unavailable }
                    }
                    if requiresTools {
                        guard let conversation, Self.isAlive(conversation), conversation.assistanceSettings.enableAgentTools,
                              !conversation.isGroupMode, !conversation.isArenaMode else { throw LLMError.unavailableTool }
                    }
                }
                do { try request.validateBeforeSending?() } catch {
                    if toolRound == 0 && candidateIndex + 1 < slot.candidates.count, case LLMError.unavailableModel = error {
                        break roundLoop
                    }
                    message.errorMessage = error.localizedDescription
                    message.isStreaming = false
                    return nil
                }

                let outcome = await runCandidateStream(
                    request: request,
                    target: target,
                    spec: currentSpec,
                    kind: roundKind,
                    operationID: operationID,
                    attemptNumber: &attemptNumber,
                    conversationID: conversation.id,
                    appendToExisting: slot.appendToExisting || toolRound > 0,
                    groupSanitizer: slot.groupSanitizer,
                    into: message,
                    context: context
                )

                switch outcome {
                case .completed(let toolCalls, let roundText, let roundReasoning, let thinkingBlocks, let groupDirective):
                    if !toolCalls.isEmpty && toolRound < AgentToolRunner.maxToolRounds && Self.isAlive(message) {
                        let searches = toolCalls.filter { $0.name == "web_search" }.count
                        guard toolCalls.count <= remainingToolCalls, searches <= remainingSearches else {
                            message.errorMessage = String(localized: "本轮工具调用已达上限。")
                            message.isStreaming = false
                            return groupDirective
                        }
                        remainingToolCalls -= toolCalls.count
                        remainingSearches -= searches
                        workingHistory.append(LLMPromptMessage(
                            role: .assistant,
                            content: roundText,
                            reasoningContent: roundReasoning,
                            thinkingBlocks: thinkingBlocks,
                            toolCalls: toolCalls
                        ))
                        var cancelledDuringTools = false
                        for call in toolCalls {
                            if Task.isCancelled {
                                cancelledDuringTools = true
                                break
                            }
                            do { try validateTarget() } catch {
                                message.errorMessage = error.localizedDescription
                                message.isStreaming = false
                                return groupDirective
                            }
                            guard conversation.assistanceSettings.enableAgentTools,
                                  !conversation.isGroupMode, !conversation.isArenaMode else {
                                message.errorMessage = LLMError.unavailableTool.localizedDescription
                                message.isStreaming = false
                                return groupDirective
                            }
                            let exec = await executeToolCall(
                                call,
                                conversation: conversation,
                                message: message,
                                providers: providers,
                                context: context,
                                userProvidedURLs: slot.userProvidedURLs
                            )
                            if Task.isCancelled {
                                cancelledDuringTools = true
                                break
                            }
                            workingHistory.append(LLMPromptMessage(
                                role: .tool,
                                content: exec.toolOutputJSON,
                                toolCallID: call.id,
                                toolName: call.name
                            ))
                        }
                        if cancelledDuringTools {
                            if Self.isAlive(message) {
                                if message.content.isEmpty && message.reasoningContent.isEmpty && message.attachments.isEmpty {
                                    message.errorMessage = String(localized: "已停止生成")
                                }
                                message.isStreaming = false
                            }
                            return groupDirective
                        }
                        if !message.content.isEmpty && !message.content.hasSuffix("\n") {
                            message.content.append("\n\n")
                        }
                        toolRound += 1
                        attemptNumber += 1
                        continue roundLoop
                    }
                    if Self.isAlive(message) {
                        message.isStreaming = false
                    }
                    return groupDirective

                case .failed(let error, let receivedOutput, let hadAbnormalFinish):
                    let hasMoreBackups = candidateIndex + 1 < slot.candidates.count
                    if toolRound == 0 && hasMoreBackups && AssistancePolicy.mayFallback(
                        error,
                        receivedOutput: receivedOutput,
                        abnormalFinish: hadAbnormalFinish,
                        includeExtendedErrors: conversation.assistanceSettings.fallbackOnExtendedErrors
                    ) {
                        attemptNumber += 1
                        break roundLoop
                    }
                    guard Self.isAlive(message) else { return nil }
                    if Self.isCancellation(error) {
                        if message.content.isEmpty && message.reasoningContent.isEmpty && message.attachments.isEmpty {
                            message.errorMessage = String(localized: "已停止生成")
                        }
                    } else {
                        message.errorMessage = error.localizedDescription
                    }
                    message.isStreaming = false
                    return nil
                }
            }
        }
        return nil
    }

    private func executeToolCall(
        _ call: LLMToolCall,
        conversation: Conversation,
        message: ChatMessage,
        providers: [ProviderConfig],
        context: ModelContext,
        userProvidedURLs: Set<String>
    ) async -> AgentToolRunner.ExecutionOutput {
        let conversationID = conversation.id
        let start = ContinuousClock.now
        var searchRecord: RequestRecord?
        if call.name == "web_search" {
            let r = RequestRecord(
                target: TavilySearchClient.ledgerTarget,
                spec: nil,
                conversationID: conversationID,
                messageID: message.id,
                kind: .webSearch
            )
            context.insert(r)
            searchRecord = r
        }

        let knowledgeHandler: (@Sendable (String) async throws -> KnowledgeEvidence)?
        if call.name == "search_documents" && !message.assistanceMetadata.omittedKnowledge {
            let kbVolumeIDs = conversation.assistanceSettings.knowledgeVolumeIDs
            let limits = conversation.readingChapterLimits
            if kbVolumeIDs.isEmpty {
                knowledgeHandler = nil
            } else {
                // Skip faulting 12 MiB book blobs already indexed in `ProjectKnowledgeSearch.shared`,
                // falling back cleanly on `@MainActor` if an entry was concurrently evicted.
                let initialSnapshots = ProjectKnowledgeSearch.snapshots(
                    for: kbVolumeIDs,
                    in: context,
                    skipCachedIn: .shared
                )
                if initialSnapshots.isEmpty {
                    knowledgeHandler = { query in
                        KnowledgeEvidence(query: query, passages: [])
                    }
                } else {
                    knowledgeHandler = { [weak self] query in
                        let firstPass = try await ProjectKnowledgeSearch.shared.retrieveCheckingCache(
                            from: initialSnapshots,
                            query: query,
                            maxPassages: 5,
                            chapterLimits: limits
                        )
                        guard !firstPass.missingVolumeIDs.isEmpty else {
                            return firstPass.evidence
                        }
                        let missedIDs = firstPass.missingVolumeIDs
                        let reloadedList: [KnowledgeDocumentSnapshot]
                        if let self {
                            reloadedList = await self.reloadKnowledgeSnapshots(
                                volumeIDs: missedIDs,
                                conversationID: conversationID
                            )
                        } else {
                            reloadedList = []
                        }
                        let missedSet = Set(missedIDs)
                        let reloadedMap = Dictionary(uniqueKeysWithValues: reloadedList.map { ($0.id, $0) })
                        let merged = initialSnapshots.map { doc in
                            missedSet.contains(doc.id) ? (reloadedMap[doc.id] ?? doc) : doc
                        }
                        return try await ProjectKnowledgeSearch.shared.retrieve(
                            from: merged,
                            query: query,
                            maxPassages: 5,
                            chapterLimits: limits
                        )
                    }
                }
            }
        } else {
            knowledgeHandler = nil
        }

        let webpageApprovalGate: (@Sendable (URL) async -> WebpageApprovalDecision)?
        if call.name == "read_webpage" {
            webpageApprovalGate = { [weak self] url in
                if userProvidedURLs.contains(AgentToolRunner.canonicalURLKey(url)) {
                    return .allow
                }
                guard let self else { return .deny }
                return await self.requestWebpageApproval(for: url, conversationID: conversationID)
            }
        } else {
            webpageApprovalGate = nil
        }

        let output = await AgentToolRunner.execute(
            call,
            searchHandler: self.search,
            webpageHandler: self.webpageReader,
            webpageApproval: webpageApprovalGate,
            knowledgeHandler: knowledgeHandler
        )

        if let searchRecord {
            let elapsed = Self.milliseconds(start.duration(to: .now))
            if let err = output.error, Self.isCancellation(err) {
                searchRecord.finish(.cancelled, elapsedMs: elapsed)
            } else {
                if case SearchError.http(let code)? = output.error {
                    searchRecord.httpStatus = code
                }
                searchRecord.finish(output.record.succeeded ? .succeeded : .failed, elapsedMs: elapsed)
            }
        }

        if Self.isAlive(message) {
            var meta = message.assistanceMetadata
            meta.toolCalls.append(output.record)
            if let evidence = output.searchEvidence {
                if var existing = meta.search {
                    let baseCount = existing.sources.count
                    existing.sources.append(contentsOf: evidence.sources.enumerated().map { idx, s in
                        var copy = s
                        copy.id = baseCount + idx + 1
                        return copy
                    })
                    meta.search = existing
                } else {
                    meta.search = evidence
                }
            }
            if let kbEv = output.knowledgeEvidence {
                if let existingKB = meta.knowledgeEvidence {
                    meta.knowledgeEvidence = existingKB.merged(with: kbEv)
                } else {
                    meta.knowledgeEvidence = kbEv
                }
            }
            if let memory = output.proposedMemory,
               !meta.proposedMemories.contains(memory),
               !meta.handledMemories.contains(memory) {
                meta.proposedMemories.append(memory)
            }
            message.assistanceMetadata = meta
        }
        return output
    }

    private enum CandidateStreamResult {
        case completed(
            toolCalls: [LLMToolCall],
            roundText: String,
            roundReasoning: String,
            thinkingBlocks: [LLMThinkingBlock],
            groupDirective: GroupTurnDirective?
        )
        case failed(error: Error, receivedOutput: Bool, abnormalFinish: Bool)
    }

    /// Adapts streaming UI flush cadence to message length so short replies feel instant
    /// while 6K–20K+ character long-form responses avoid starving SwiftUI layout & TextKit.
    nonisolated static func streamingFlushInterval(forContentLength length: Int) -> Duration {
        switch length {
        case ..<1_500:
            return .milliseconds(35)
        case 1_500..<6_000:
            return .milliseconds(60)
        default:
            return .milliseconds(95)
        }
    }

    private func runCandidateStream(
        request: LLMChatRequest,
        target: ResolvedModelTarget,
        spec: ModelSpec?,
        kind: RequestKind,
        operationID: UUID,
        attemptNumber: inout Int,
        conversationID: UUID,
        appendToExisting: Bool,
        groupSanitizer: GroupStreamSanitizer? = nil,
        into message: ChatMessage,
        context: ModelContext
    ) async -> CandidateStreamResult {
        var attemptStart = ContinuousClock.now
        var thinkingStartTime: ContinuousClock.Instant?
        var recordedThinkingDuration = false
        var receivedOutput = false
        let initialPromptTokens = appendToExisting ? (LLMUsage.valid(message.promptTokens) ?? 0) : 0
        let initialCompletionTokens = appendToExisting ? (LLMUsage.valid(message.completionTokens) ?? 0) : 0
        let initialCachedTokens = appendToExisting ? (LLMUsage.valid(message.cachedTokens) ?? 0) : 0
        let prefixBeforeContinuation = appendToExisting ? message.content : ""
        var roundContent = ""
        var roundReasoning = ""
        var collectedToolCalls: [LLMToolCall] = []
        var collectedThinkingBlocks: [LLMThinkingBlock] = []
        var remainingText = max(0, 1_000_000 - message.content.utf8.count - message.reasoningContent.utf8.count)
        var remainingMedia = 24 * 1024 * 1024
        for attachment in message.attachments {
            remainingMedia = max(0, remainingMedia - (attachment.dataBase64?.utf8.count ?? 0))
        }
        var auxiliaryBytes = 0
        var sanitizer = groupSanitizer

        var pendingContent = ""
        var pendingReasoning = ""
        var lastFlush = ContinuousClock.now
        var lastSave = ContinuousClock.now
        var finishReason: LLMFinishReason?

        var record = RequestRecord(
            target: target,
            spec: spec,
            conversationID: conversationID,
            messageID: message.id,
            kind: kind,
            operationID: operationID,
            attempt: attemptNumber
        )
        context.insert(record)
        message.latestRequest = record

        func flushBuffers() {
            guard Self.isAlive(message) else {
                pendingReasoning = ""
                pendingContent = ""
                return
            }
            if !pendingReasoning.isEmpty {
                message.reasoningContent.append(pendingReasoning)
                pendingReasoning = ""
            }
            if !pendingContent.isEmpty {
                message.content.append(pendingContent)
                pendingContent = ""
            }
            lastFlush = ContinuousClock.now
            if lastSave.duration(to: lastFlush) >= .seconds(2) {
                try? message.modelContext?.save()
                lastSave = lastFlush
            }
        }

        do {
            for try await event in self.stream(request) {
                try Task.checkCancellation()
                let elapsed = Self.milliseconds(attemptStart.duration(to: .now))
                record.observe(event, elapsedMs: elapsed)

                switch event {
                case .retrying(let httpStatus):
                    record = record.startRetry(after: httpStatus, elapsedMs: elapsed, target: target, spec: spec, in: context)
                    attemptNumber = record.attempt
                    if Self.isAlive(message) {
                        message.latestRequest = record
                    }
                    attemptStart = .now

                case .nonStreamingResponse:
                    break

                case .reasoningDelta(let delta):
                    guard !delta.isEmpty else { break }
                    remainingText -= delta.utf8.count
                    guard remainingText >= 0 else { throw LLMError.interruptedStream }
                    receivedOutput = true
                    roundReasoning.append(delta)
                    if thinkingStartTime == nil {
                        thinkingStartTime = ContinuousClock.now
                    }
                    pendingReasoning.append(delta)
                    let reasoningLen = (Self.isAlive(message) ? message.reasoningContent.count : 0) + pendingReasoning.count
                    if lastFlush.duration(to: ContinuousClock.now) >= Self.streamingFlushInterval(forContentLength: reasoningLen) {
                        flushBuffers()
                        LiveActivityCoordinator.shared.update(
                            conversationID: conversationID,
                            phaseText: String(localized: "深度思考中…")
                        )
                    }

                case .thinkingBlock(let block):
                    auxiliaryBytes += block.thinking.utf8.count + (block.signature?.utf8.count ?? 0) + (block.redactedData?.utf8.count ?? 0)
                    guard auxiliaryBytes <= 512 * 1024, collectedThinkingBlocks.count < 64 else { throw LLMError.interruptedStream }
                    collectedThinkingBlocks.append(block)

                case .contentDelta(let delta):
                    guard !delta.isEmpty else { break }
                    remainingText -= delta.utf8.count
                    guard remainingText >= 0 else { throw LLMError.interruptedStream }
                    receivedOutput = true
                    roundContent.append(delta)
                    if let tStart = thinkingStartTime, !recordedThinkingDuration, Self.isAlive(message) {
                        message.thinkingDurationMs = Self.milliseconds(tStart.duration(to: ContinuousClock.now))
                        recordedThinkingDuration = true
                    }
                    let visibleDelta = sanitizer != nil ? sanitizer!.ingest(delta) : delta
                    if !visibleDelta.isEmpty {
                        pendingContent.append(visibleDelta)
                        let visibleLen = (Self.isAlive(message) ? message.content.count : 0) + pendingContent.count
                        if lastFlush.duration(to: ContinuousClock.now) >= Self.streamingFlushInterval(forContentLength: visibleLen) {
                            flushBuffers()
                            LiveActivityCoordinator.shared.update(
                                conversationID: conversationID,
                                phaseText: String(localized: "正在生成…"),
                                previewSnippet: Self.isAlive(message) ? message.content : nil
                            )
                        }
                    }

                case .attachmentDelta(let attachment):
                    remainingMedia -= attachment.dataBase64?.utf8.count ?? 0
                    guard remainingMedia >= 0, message.attachments.count < 8 else { throw LLMError.interruptedStream }
                    receivedOutput = true
                    if Self.isAlive(message) {
                        var current = message.attachments
                        current.append(attachment)
                        message.attachments = current
                    }

                case .toolCall(let call):
                    auxiliaryBytes += call.argumentsJSON.utf8.count
                    guard auxiliaryBytes <= 512 * 1024,
                          collectedToolCalls.count < AgentToolRunner.maxCallsPerTurn else { throw LLMError.unavailableTool }
                    guard request.tools.contains(where: { $0.name == call.name }) else {
                        throw LLMError.unavailableTool
                    }
                    receivedOutput = true
                    collectedToolCalls.append(call)

                case .groundingSource(let title, let urlString):
                    guard Self.isAlive(message), urlString.count <= 4096,
                          let url = URL(string: urlString),
                          (try? URLReader.validate(url)) != nil else { break }
                    var meta = message.assistanceMetadata
                    var evidence = meta.search ?? SearchEvidence(query: String(localized: "服务商原生联网"), searchedAt: Date(), sources: [], credits: nil)
                    if evidence.sources.count < 8 && !evidence.sources.contains(where: { $0.url.absoluteString == url.absoluteString }) {
                        evidence.sources.append(SearchSource(
                            id: evidence.sources.count + 1,
                            title: String(title.prefix(300)),
                            url: url,
                            snippet: ""
                        ))
                        meta.search = evidence
                        message.assistanceMetadata = meta
                    }

                case .usage(let prompt, let completion):
                    guard Self.isAlive(message) else { break }
                    if let prompt = LLMUsage.valid(prompt) {
                        message.promptTokens = LLMUsage.combined(initialPromptTokens, prompt)
                    }
                    if let completion = LLMUsage.valid(completion) {
                        message.completionTokens = LLMUsage.combined(initialCompletionTokens, completion)
                    }

                case .cacheUsage(let cached, _):
                    if let cached = LLMUsage.valid(cached), let totalCached = LLMUsage.combined(initialCachedTokens, cached), Self.isAlive(message) {
                        if let totalPrompt = message.promptTokens, totalPrompt < totalCached {
                            message.promptTokens = totalCached
                        }
                        message.cachedTokens = totalCached
                    }

                case .finished(let reason):
                    finishReason = reason

                case .done:
                    flushBuffers()
                }
            }

            try Task.checkCancellation()
            flushBuffers()

            var parsedGroupDirective: GroupTurnDirective?
            if var activeSanitizer = sanitizer {
                let finalized = activeSanitizer.finalize()
                parsedGroupDirective = finalized.directive
                if Self.isAlive(message) {
                    message.content = appendToExisting
                        ? (prefixBeforeContinuation + finalized.visibleText)
                        : finalized.visibleText
                }
            }

            let totalElapsed = Self.milliseconds(attemptStart.duration(to: .now))
            guard Self.isAlive(message) else {
                record.finish(.cancelled, elapsedMs: totalElapsed)
                return .completed(
                    toolCalls: [],
                    roundText: roundContent,
                    roundReasoning: roundReasoning,
                    thinkingBlocks: collectedThinkingBlocks,
                    groupDirective: parsedGroupDirective
                )
            }

            message.latencyMs = LLMUsage.combined(appendToExisting ? message.latencyMs : nil, totalElapsed)
            if let tStart = thinkingStartTime, !recordedThinkingDuration {
                message.thinkingDurationMs = Self.milliseconds(tStart.duration(to: ContinuousClock.now))
            }
            message.finishReason = finishReason?.rawValue

            if !collectedToolCalls.isEmpty {
                record.finish(.succeeded, elapsedMs: totalElapsed)
                return .completed(
                    toolCalls: collectedToolCalls,
                    roundText: roundContent,
                    roundReasoning: roundReasoning,
                    thinkingBlocks: collectedThinkingBlocks,
                    groupDirective: parsedGroupDirective
                )
            }

            if parsedGroupDirective?.isPass == true {
                record.finish(.succeeded, elapsedMs: totalElapsed)
            } else if message.content.isEmpty && message.attachments.isEmpty {
                switch finishReason {
                case .contentFilter:
                    message.errorMessage = LLMFinishReason.contentFilter.userNotice
                    record.finish(.incomplete, elapsedMs: totalElapsed)
                case .length:
                    message.errorMessage = message.reasoningContent.isEmpty
                        ? LLMFinishReason.length.userNotice
                        : String(localized: "思考过程用完了输出长度上限，未生成正文。请调大「最大输出 Tokens」或降低思考预算后重答。")
                    record.finish(.incomplete, elapsedMs: totalElapsed)
                case nil:
                    if message.reasoningContent.isEmpty {
                        message.errorMessage = String(localized: "服务端返回成功，但回复内容为空")
                        record.finish(.failed, elapsedMs: totalElapsed)
                    } else {
                        record.finish(.succeeded, elapsedMs: totalElapsed)
                    }
                }
            } else {
                record.finish(finishReason == nil ? .succeeded : .incomplete, elapsedMs: totalElapsed)
            }

            return .completed(
                toolCalls: [],
                roundText: roundContent,
                roundReasoning: roundReasoning,
                thinkingBlocks: collectedThinkingBlocks,
                groupDirective: parsedGroupDirective
            )
        } catch {
            flushBuffers()
            let totalElapsed = Self.milliseconds(attemptStart.duration(to: .now))
            if case LLMError.httpError(let status, _) = error {
                record.httpStatus = status
            }
            record.finish(Self.isCancellation(error) ? .cancelled : .failed, elapsedMs: totalElapsed)
            return .failed(error: error, receivedOutput: receivedOutput, abnormalFinish: finishReason != nil)
        }
    }

    func scheduleRollingSummaryIfNeeded(
        for conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext? = nil
    ) {
        guard AppPreferences.shared.autoRollingSummaryEnabled,
              conversation.contextMessageLimit > 0,
              !conversation.isArenaMode,
              !conversation.isGroupMode else { return }

        let active = ConversationTree.activeMessages(in: conversation)
        let latestDividerID = active.last(where: { $0.assistanceMetadata.isContextDivider })?.id
        let collapsed = eligiblePromptContext(active)
        let dropped = RollingContextSummaryStore.droppedMessages(from: collapsed, limit: conversation.contextMessageLimit)

        let rawExisting = RollingContextSummaryStore.shared.summary(for: conversation.id)
        let validExisting: RollingContextSummary?
        if let rawExisting {
            if RollingContextSummaryStore.isSummaryValid(rawExisting, dropped: dropped, latestContextDividerID: latestDividerID) {
                validExisting = rawExisting
            } else {
                RollingContextSummaryStore.shared.clear(for: conversation.id)
                validExisting = nil
            }
        } else {
            validExisting = nil
        }

        guard dropped.count >= 2, let lastDropped = dropped.last else { return }

        if validExisting?.lastCoveredMessageID == lastDropped.id && validExisting?.coveredMessageCount == dropped.count {
            return
        }

        let newDroppedSlice: [ChatMessage]
        if let prevID = validExisting?.lastCoveredMessageID,
           let prevIdx = dropped.firstIndex(where: { $0.id == prevID }) {
            newDroppedSlice = Array(dropped[dropped.index(after: prevIdx)...])
        } else {
            newDroppedSlice = dropped
        }
        guard !newDroppedSlice.isEmpty else { return }

        guard let target = conversation.primaryTarget,
              let provider = providers.first(where: { $0.id == target.providerID && $0.isEnabled && !$0.isDeleted }),
              let spec = provider.enabledModels.first(where: { $0.id == target.modelID }),
              provider.hasAuthentication || NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL) else {
            return
        }

        let resolvedTarget = provider.makeTarget(for: spec)
        let convID = conversation.id
        let contextLimit = conversation.contextMessageLimit
        let coveredCount = dropped.count
        let lastID = lastDropped.id
        let coveredIDs = dropped.map(\.id)
        let expectedDigest = RollingContextSummaryStore.prefixDigest(for: dropped)
        let expectedExisting = RollingContextSummaryStore.shared.summary(for: convID)
        let promptInput = RollingContextSummaryStore.buildSummarizationPrompt(
            previousSummary: validExisting?.summaryText,
            newlyTruncatedMessages: newDroppedSlice.map { ($0.role, $0.content) }
        )
        let effectiveReasoning = ModelSpec.inferReasoningSupport(modelID: resolvedTarget.modelID)
        var request = LLMChatRequest(
            providerName: provider.name,
            protocolType: provider.protocolType,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            apiKeys: provider.extraAPIKeys,
            customHeaders: provider.resolvedCustomHeaders,
            modelID: resolvedTarget.modelID,
            supportsReasoning: effectiveReasoning,
            systemPrompt: "Summarize the earlier conversation turns into concise bullet points preserving key facts, decisions, user preferences, names, and open tasks. Output only the summary in the same language as the conversation, under 350 words.",
            messages: [LLMPromptMessage(role: .user, content: promptInput)],
            temperature: effectiveReasoning ? nil : 0.2,
            topP: 1.0,
            maxOutputTokens: effectiveReasoning ? 2048 : 600,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            idleTimeoutSeconds: provider.customIdleTimeout
        )
        let validateTarget = provider.transmissionCheck(for: resolvedTarget.modelID)
        request.validateBeforeSending = { [weak self, weak conversation] in
            try validateTarget()
            guard let self, let conversation, Self.isAlive(conversation),
                  AppPreferences.shared.autoRollingSummaryEnabled,
                  conversation.contextMessageLimit == contextLimit,
                  conversation.primaryTarget?.id == target.id,
                  !conversation.isArenaMode, !conversation.isGroupMode else {
                throw AppCompliance.RequestChanged()
            }
            let currentActive = ConversationTree.activeMessages(in: conversation)
            let currentDividerID = currentActive.last(where: { $0.assistanceMetadata.isContextDivider })?.id
            let currentCollapsed = self.eligiblePromptContext(currentActive)
            let currentDropped = RollingContextSummaryStore.droppedMessages(from: currentCollapsed, limit: contextLimit)
            guard currentDividerID == latestDividerID,
                  currentDropped.count >= coveredCount,
                  Array(currentDropped.prefix(coveredCount)).map(\.id) == coveredIDs,
                  RollingContextSummaryStore.prefixDigest(for: Array(currentDropped.prefix(coveredCount))) == expectedDigest else {
                throw AppCompliance.RequestChanged()
            }
        }
        let ledgerContext = context ?? conversation.modelContext
        let streamFn = self.stream
        let summaryToken = UUID()
        activeSummaryTasks[convID]?.cancel()
        activeSummaryTokens[convID] = summaryToken
        let summaryTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.activeSummaryTokens[convID] == summaryToken {
                    self.activeSummaryTokens.removeValue(forKey: convID)
                    self.activeSummaryTasks.removeValue(forKey: convID)
                    self.updateBackgroundExecution()
                }
                if let ledgerContext, ledgerContext.hasChanges {
                    try? ledgerContext.save()
                }
            }
            var record: RequestRecord?
            var started = ContinuousClock.now
            var collected = ""
            var abnormalFinish = false
            do {
                try Task.checkCancellation()
                try request.validateBeforeSending?()
                if let ledgerContext {
                    let created = RequestRecord(
                        target: resolvedTarget,
                        spec: spec,
                        conversationID: convID,
                        messageID: lastID,
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
                for try await event in streamFn(request) {
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
                    case .contentDelta(let chunk):
                        collected += chunk
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
                return
            }
            let clean = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            let status: RequestStatus = abnormalFinish ? .incomplete : (clean.isEmpty ? .failed : .succeeded)
            record?.finish(status, elapsedMs: Self.milliseconds(started.duration(to: .now)))
            guard status == .succeeded,
                  RollingContextSummaryStore.shared.summary(for: convID) == expectedExisting else {
                return
            }
            RollingContextSummaryStore.shared.save(
                RollingContextSummary(
                    conversationID: convID,
                    summaryText: clean,
                    coveredMessageCount: coveredCount,
                    lastCoveredMessageID: lastID,
                    updatedAt: Date(),
                    contextDividerMessageID: latestDividerID,
                    coveredMessageIDs: coveredIDs,
                    coveredPrefixDigest: expectedDigest
                )
            )
        }
        activeSummaryTasks[convID] = summaryTask
        updateBackgroundExecution()
    }
}
