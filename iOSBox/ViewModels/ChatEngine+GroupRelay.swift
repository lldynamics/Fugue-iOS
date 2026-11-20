import Foundation
import SwiftData

extension ChatEngine {
    // MARK: - Group Discussion Actions & Relay Orchestration

    enum GroupSessionRunMode {
        case afterUserMessage(
            userMessage: ChatMessage,
            priorMessages: [ChatMessage],
            searchQuery: String?,
            omitMemory: Bool,
            memoryInfo: (systemPrompt: String, count: Int),
            expectedTitleForAutoGenerate: String?
        )
        case continueDiscussion
        case groupVote
        case summarize(by: GroupMember?)
    }

    /// Interrupts any ongoing group discussion immediately, keeps already-spoken bubbles clean,
    /// removes any unstarted placeholder bubble, and starts a fresh discussion round on the host's new message.
    @discardableResult
    func bargeInGroupMessage(
        text: String,
        attachments: [MessageAttachment],
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext,
        options: GenerationOptions = GenerationOptions()
    ) async -> SendOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .emptyInput }

        if isGenerating(in: conversation.id) {
            await stopGenerationAndWait(for: conversation.id)
            cleanupInterruptedGroupTail(in: conversation, context: context)
        }

        return sendUserMessageInternal(
            text: trimmed,
            attachments: attachments,
            in: conversation,
            providers: providers,
            context: context,
            kind: .answer,
            options: options
        )
    }

    private func cleanupInterruptedGroupTail(in conversation: Conversation, context: ModelContext) {
        let active = ConversationTree.activeMessages(in: conversation)
        guard let last = active.last, last.role == .assistant else { return }
        if last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && last.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && last.attachments.isEmpty {
            ConversationTree.detachBeforeDeleting(last, in: conversation)
            conversation.messages.removeAll { $0.id == last.id }
            context.delete(last)
        } else if last.errorMessage == String(localized: "已停止生成") {
            last.errorMessage = nil
        }
        try? context.save()
    }

    @discardableResult
    func continueGroupDiscussion(
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) -> SendOutcome {
        guard conversation.isGroupMode else { return .noAvailableModel }
        guard !isGenerating(in: conversation.id) else { return .busy }
        guard sendTargets(text: "", attachments: [], in: conversation, providers: providers) != nil else {
            return .noAvailableModel
        }
        launchGroupRelaySession(mode: .continueDiscussion, in: conversation, providers: providers, context: context)
        return .sent
    }

    @discardableResult
    func startGroupVote(
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) -> SendOutcome {
        guard conversation.isGroupMode else { return .noAvailableModel }
        guard !isGenerating(in: conversation.id) else { return .busy }
        guard sendTargets(text: "", attachments: [], in: conversation, providers: providers) != nil else {
            return .noAvailableModel
        }
        appendHostGroupActionMessage(
            String(localized: "🗳️ 发起圆桌表决：请各位明确亮牌（赞成 / 反对 / 中立），并用 1～3 句话说明核心理由。"),
            in: conversation,
            context: context
        )
        launchGroupRelaySession(mode: .groupVote, in: conversation, providers: providers, context: context)
        return .sent
    }

    @discardableResult
    func summarizeGroupDiscussion(
        by member: GroupMember? = nil,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) -> SendOutcome {
        guard conversation.isGroupMode else { return .noAvailableModel }
        guard !isGenerating(in: conversation.id) else { return .busy }
        guard sendTargets(text: "", attachments: [], in: conversation, providers: providers) != nil else {
            return .noAvailableModel
        }
        let chosen = member ?? conversation.activeGroupMembers.last ?? conversation.activeGroupMembers.first
        let mentionPrefix = chosen.map { "@\($0.mentionToken) " } ?? ""
        appendHostGroupActionMessage(
            String(localized: "📋 \(mentionPrefix)请帮大家梳理总结目前讨论的核心共识、关键分歧与下一步行动建议。"),
            in: conversation,
            context: context
        )
        launchGroupRelaySession(mode: .summarize(by: chosen), in: conversation, providers: providers, context: context)
        return .sent
    }

    private func appendHostGroupActionMessage(
        _ content: String,
        in conversation: Conversation,
        context: ModelContext
    ) {
        let shouldUseTree = ConversationTree.usesTree(conversation)
        let parentID = shouldUseTree
            ? (ConversationTree.currentAnchorID(in: conversation) ?? ConversationTree.virtualRootID)
            : nil
        let nextSort = (conversation.sortedMessages.last?.sortIndex ?? 0) + 1
        let msg = ChatMessage(role: .user, content: content, sortIndex: nextSort)
        msg.parentMessageID = parentID
        msg.conversation = conversation
        conversation.messages.append(msg)
        context.insert(msg)
        if shouldUseTree {
            conversation.activeLeafMessageID = msg.id
        }
        conversation.updatedAt = Date()
        try? context.save()
    }

    func launchGroupRelaySession(
        mode: GroupSessionRunMode,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) {
        let convID = conversation.id
        let token = UUID()
        activeConversationIDs.insert(convID)

        let masterTask = Task { @MainActor in
            let settings = conversation.assistanceSettings
            let resolvedRoster: [(member: GroupMember, target: ResolvedModelTarget)] = conversation.activeGroupMembers.compactMap { m in
                guard let resolved = AssistancePolicy.resolve(m.target, providers: providers) else { return nil }
                var copy = m
                copy.target = resolved
                return (copy, resolved)
            }
            let activeMembers = resolvedRoster.map(\.member)
            let targetByMemberID = Dictionary(uniqueKeysWithValues: resolvedRoster.map { ($0.member.id, $0.target) })

            guard !activeMembers.isEmpty else {
                self.finishGeneration(conversationID: convID, token: token)
                return
            }

            let omitMemory: Bool
            let memoryInfo: (systemPrompt: String, count: Int)
            var searchEvidence: SearchEvidence?
            var knowledgeEvidence: KnowledgeEvidence?
            var requestedSearchQuery: String?
            var expectedTitleForAutoGenerate: String?

            let kbVolumeIDs = conversation.assistanceSettings.knowledgeVolumeIDs
            if !kbVolumeIDs.isEmpty {
                let q = self.bookQuestion(in: ConversationTree.activeMessages(in: conversation))
                if let ev = try? await ProjectKnowledgeSearch.retrieve(volumeIDs: kbVolumeIDs, in: context, query: q, maxPassages: 4),
                   !ev.passages.isEmpty {
                    knowledgeEvidence = ev
                }
            }

            LiveActivityCoordinator.shared.start(
                conversationID: convID,
                chatTitle: conversation.title,
                modeBadge: String(localized: "圆桌群聊"),
                speakerOrModel: activeMembers.first?.displayLabel ?? "AI",
                phaseText: String(localized: "群成员正在接力讨论…"),
                totalTurns: max(1, settings.groupMaxRelayTurns)
            )

            switch mode {
            case .afterUserMessage(let userMsg, _, let sq, let omit, let mem, let expectedTitle):
                omitMemory = omit
                memoryInfo = mem
                requestedSearchQuery = sq
                expectedTitleForAutoGenerate = expectedTitle

                if let sq {
                    let searchStart = ContinuousClock.now
                    let searchRecord = RequestRecord(
                        target: TavilySearchClient.ledgerTarget,
                        spec: nil,
                        conversationID: convID,
                        messageID: userMsg.id,
                        kind: .webSearch
                    )
                    context.insert(searchRecord)
                    do {
                        let ev = try await self.search(sq)
                        try Task.checkCancellation()
                        searchRecord.finish(.succeeded, elapsedMs: Self.milliseconds(searchStart.duration(to: .now)))
                        searchEvidence = ev
                    } catch {
                        let elapsed = Self.milliseconds(searchStart.duration(to: .now))
                        let errorText: String
                        if Self.isCancellation(error) {
                            searchRecord.finish(.cancelled, elapsedMs: elapsed)
                            errorText = String(localized: "已停止生成")
                        } else {
                            if case SearchError.http(let code) = error {
                                searchRecord.httpStatus = code
                            }
                            searchRecord.finish(.failed, elapsedMs: elapsed)
                            errorText = error.localizedDescription
                        }
                        if Self.isAlive(conversation), let leadMember = activeMembers.first, let leadTarget = targetByMemberID[leadMember.id] {
                            let useTree = ConversationTree.usesTree(conversation)
                            let nextSort = (conversation.sortedMessages.last?.sortIndex ?? 0) + 1
                            let errMsg = ChatMessage(
                                role: .assistant,
                                target: leadTarget,
                                isStreaming: false,
                                sortIndex: nextSort
                            )
                            errMsg.accentHex = leadMember.accentHex
                            errMsg.errorMessage = errorText
                            errMsg.parentMessageID = useTree ? userMsg.id : nil
                            var errMeta = AssistanceMetadata()
                            errMeta.groupMemberID = leadMember.id
                            errMeta.groupMemberName = leadMember.name
                            errMeta.isPersonaSimulation = leadMember.isSimulatedPersona
                            errMeta.groupMemberTitle = leadMember.title
                            errMeta.groupMemberEmoji = leadMember.avatarEmoji
                            errMeta.requestedSearchQuery = sq
                            errMeta.omittedMemory = omit && conversation.assistanceSettings.usePersonalMemory
                            errMsg.assistanceMetadata = errMeta
                            errMsg.conversation = conversation
                            conversation.messages.append(errMsg)
                            context.insert(errMsg)
                            if useTree {
                                conversation.activeLeafMessageID = errMsg.id
                            }
                            conversation.updatedAt = Date()
                            try? context.save()
                        } else {
                            try? context.save()
                        }
                        self.finishGeneration(conversationID: convID, token: token)
                        return
                    }
                }

            case .continueDiscussion, .groupVote, .summarize:
                omitMemory = false
                memoryInfo = self.prepareMemory(conversation: conversation, omitMemory: false, context: context)
            }

            if Task.isCancelled || !Self.isAlive(conversation) {
                self.finishGeneration(conversationID: convID, token: token)
                return
            }

            var explicitQueue: [(member: GroupMember, intent: GroupSpeechIntent, allowPass: Bool)] = []
            let maxRelayTurns: Int
            let dynamicSmartRelay: Bool

            switch mode {
            case .afterUserMessage(let userMsg, let priorMessages, _, _, _, _):
                let planned = GroupDiscussionCoordinator.selectInitialPlan(
                    userText: userMsg.content,
                    activeMembers: activeMembers,
                    speakingMode: settings.groupSpeakingMode,
                    maxRelayTurns: settings.groupMaxRelayTurns,
                    priorMessages: priorMessages
                )
                if planned.isEmpty {
                    self.finishGeneration(conversationID: convID, token: token)
                    return
                }
                let hasExplicitMentions = planned.contains(where: \.explicitMention)
                if settings.groupSpeakingMode == .smartRelay && !hasExplicitMentions {
                    explicitQueue = [(planned[0].member, planned[0].intent, false)]
                    maxRelayTurns = min(max(settings.groupMaxRelayTurns, 1), max(activeMembers.count + 1, 2))
                    dynamicSmartRelay = true
                } else if settings.groupSpeakingMode == .smartRelay && hasExplicitMentions {
                    explicitQueue = planned.map { ($0.member, $0.intent, false) }
                    maxRelayTurns = max(planned.count, settings.groupMaxRelayTurns)
                    dynamicSmartRelay = true
                } else {
                    explicitQueue = planned.map { ($0.member, $0.intent, !hasExplicitMentions) }
                    maxRelayTurns = planned.count
                    dynamicSmartRelay = false
                }

            case .continueDiscussion:
                let currentActive = ConversationTree.activeMessages(in: conversation)
                let lastSpeakerID = currentActive.last(where: { $0.role == .assistant })?.assistanceMetadata.groupMemberID
                let startIdx: Int
                if let lastSpeakerID, let idx = activeMembers.firstIndex(where: { $0.id == lastSpeakerID }) {
                    startIdx = (idx + 1) % activeMembers.count
                } else {
                    startIdx = 0
                }
                let starter = activeMembers[startIdx]
                explicitQueue = [(starter, .rebuttal, false)]
                maxRelayTurns = min(max(settings.groupMaxRelayTurns, 2), max(activeMembers.count, 2))
                dynamicSmartRelay = true

            case .groupVote:
                explicitQueue = activeMembers.map { ($0, .vote, false) }
                maxRelayTurns = activeMembers.count
                dynamicSmartRelay = false

            case .summarize(let preferred):
                let summarizer = preferred
                    .flatMap { p in activeMembers.first(where: { $0.id == p.id }) }
                    ?? activeMembers.last
                    ?? activeMembers[0]
                explicitQueue = [(summarizer, .summarize, false)]
                maxRelayTurns = 1
                dynamicSmartRelay = false
            }

            var turnsCompleted = 0
            var spokenMemberIDs = Set<UUID>()
            var roundMessages: [ChatMessage] = []
            var nextStep: (member: GroupMember, intent: GroupSpeechIntent, allowPass: Bool)? = explicitQueue.isEmpty ? nil : explicitQueue.removeFirst()
            let englishPreferred = GroupDiscussionCoordinator.prefersEnglishPrompts(in: ConversationTree.activeMessages(in: conversation))

            while var step = nextStep, turnsCompleted < maxRelayTurns {
                if Task.isCancelled || !Self.isAlive(conversation) { break }
                guard let target = targetByMemberID[step.member.id], conversation.isGroupMode,
                      let current = conversation.activeGroupMembers.first(where: { $0.id == step.member.id && $0.target.id == target.id }) else {
                    nextStep = explicitQueue.isEmpty ? nil : explicitQueue.removeFirst()
                    continue
                }
                step.member = current

                self.activeGroupSpeakers[convID] = "\(step.member.avatarEmoji) \(step.member.displayLabel)"
                LiveActivityCoordinator.shared.update(
                    conversationID: convID,
                    speakerOrModel: "\(step.member.avatarEmoji) \(step.member.displayLabel)",
                    phaseText: String(localized: "正在发言…"),
                    completedTurns: turnsCompleted,
                    totalTurns: maxRelayTurns,
                    force: true
                )

                let shouldUseTree = ConversationTree.usesTree(conversation)
                let parentID = shouldUseTree
                    ? (ConversationTree.currentAnchorID(in: conversation) ?? ConversationTree.virtualRootID)
                    : nil
                let priorActive = ConversationTree.activeMessages(in: conversation)

                let nextSort = (conversation.sortedMessages.last?.sortIndex ?? 0) + 1
                let replyMsg = ChatMessage(
                    role: .assistant,
                    target: target,
                    comparisonGroupID: nil,
                    isSelectedInGroup: true,
                    isStreaming: true,
                    sortIndex: nextSort
                )
                replyMsg.accentHex = step.member.accentHex
                replyMsg.parentMessageID = parentID

                var meta = AssistanceMetadata()
                meta.groupMemberID = step.member.id
                meta.groupMemberName = step.member.name
                meta.isPersonaSimulation = step.member.isSimulatedPersona
                meta.groupMemberTitle = step.member.title
                meta.groupMemberEmoji = step.member.avatarEmoji
                meta.groupSpeechIntent = step.intent
                meta.omittedMemory = omitMemory && settings.usePersonalMemory
                meta.memoryCount = memoryInfo.count
                if turnsCompleted == 0 {
                    meta.requestedSearchQuery = requestedSearchQuery
                    meta.search = searchEvidence
                    meta.knowledgeEvidence = knowledgeEvidence
                }
                replyMsg.assistanceMetadata = meta
                replyMsg.conversation = conversation
                conversation.messages.append(replyMsg)
                context.insert(replyMsg)
                if shouldUseTree {
                    conversation.activeLeafMessageID = replyMsg.id
                }
                try? context.save()

                let trailingCue: String?
                switch step.intent {
                case .vote:
                    trailingCue = englishPreferred
                        ? "[State your explicit vote now (Agree / Disagree / Neutral) and briefly explain why]"
                        : "[请现在亮出你的表决态度（赞成 / 反对 / 中立）并简述理由]"
                case .summarize:
                    trailingCue = englishPreferred
                        ? "[Synthesize and output the key consensus, disagreements, and next steps from the discussion now]"
                        : "[请现在梳理并输出本轮群讨论纪要]"
                default:
                    trailingCue = nil
                }

                var memberHistory = GroupDiscussionCoordinator.buildPromptHistory(
                    messages: priorActive,
                    for: step.member,
                    limit: conversation.contextMessageLimit,
                    trailingCueIfNeeded: trailingCue,
                    preferEnglish: englishPreferred
                )
                if let searchEvidence, let lastIdx = memberHistory.indices.last {
                    let oldLast = memberHistory[lastIdx]
                    memberHistory[lastIdx] = LLMPromptMessage(
                        role: oldLast.role,
                        content: oldLast.content + "\n\n" + searchEvidence.prompt,
                        attachments: oldLast.attachments
                    )
                }
                if let knowledgeEvidence, let lastIdx = memberHistory.indices.last {
                    let oldLast = memberHistory[lastIdx]
                    memberHistory[lastIdx] = LLMPromptMessage(
                        role: oldLast.role,
                        content: oldLast.content + "\n\n" + knowledgeEvidence.promptText(),
                        attachments: oldLast.attachments
                    )
                }

                let systemPrompt = GroupDiscussionCoordinator.buildSystemPrompt(
                    for: step.member,
                    activeMembers: activeMembers,
                    speechStyle: settings.groupSpeechStyle,
                    intent: step.intent,
                    baseSystemPrompt: memoryInfo.systemPrompt,
                    allowPass: step.allowPass || turnsCompleted > 0,
                    preferEnglish: englishPreferred
                )

                let slot = StreamSlot(
                    message: replyMsg,
                    candidates: [target],
                    kind: step.intent == .summarize ? .synthesis : .answer,
                    systemPromptOverride: systemPrompt,
                    temperatureOverride: step.intent == .summarize ? 0.3 : step.member.temperature,
                    groupSanitizer: GroupStreamSanitizer(
                        speakerName: step.member.name,
                        speakerDisplayLabel: step.member.displayLabel
                    ),
                    bookTurn: step.member.bookFriend.map { BookTurn(friend: $0, question: self.bookQuestion(in: priorActive), memberID: step.member.id) }
                )

                let directive = await self.runSlotWithFallback(
                    slot: slot,
                    historySnapshot: memberHistory,
                    conversation: conversation,
                    providers: providers,
                    context: context
                )

                if Task.isCancelled || !Self.isAlive(conversation) { break }

                let finalizedDirective = directive ?? GroupTurnDirective()
                let canHonorPass = (step.allowPass || turnsCompleted > 0 || !explicitQueue.isEmpty)
                    && finalizedDirective.isPass
                if canHonorPass, Self.isAlive(replyMsg) {
                    ConversationTree.detachBeforeDeleting(replyMsg, in: conversation)
                    conversation.messages.removeAll { $0.id == replyMsg.id }
                    context.delete(replyMsg)
                    try? context.save()

                    if !explicitQueue.isEmpty {
                        nextStep = explicitQueue.removeFirst()
                    } else {
                        let remaining = activeMembers.filter { !spokenMemberIDs.contains($0.id) && $0.id != step.member.id }
                        if let alt = remaining.first {
                            spokenMemberIDs.insert(step.member.id)
                            nextStep = (alt, step.intent, false)
                        } else {
                            nextStep = nil
                        }
                    }
                    continue
                }

                guard Self.isAlive(replyMsg) else { break }

                var updatedMeta = replyMsg.assistanceMetadata
                if finalizedDirective.asksHost {
                    updatedMeta.groupAskedHost = true
                }
                if let quote = GroupDiscussionCoordinator.resolveReplyQuote(
                    for: step.member,
                    visibleReply: replyMsg.content,
                    directive: finalizedDirective,
                    intent: step.intent,
                    roundMessages: roundMessages,
                    activeMembers: activeMembers
                ) {
                    updatedMeta.groupReplyToMessageID = quote.messageID
                    updatedMeta.groupReplyToSpeaker = quote.speakerName
                    updatedMeta.groupReplyToExcerpt = quote.excerpt
                }
                replyMsg.assistanceMetadata = updatedMeta

                if let reactionEmoji = finalizedDirective.reactionEmoji {
                    let targetForReaction: ChatMessage? = roundMessages.last ?? priorActive.last
                    if let targetForReaction, Self.isAlive(targetForReaction) {
                        var targetMeta = targetForReaction.assistanceMetadata
                        if targetMeta.groupReactions.count < 2,
                           let reaction = GroupDiscussionCoordinator.pickBystanderReaction(
                               emojiHint: reactionEmoji,
                               excludingMemberIDs: Set([step.member.id] + targetMeta.groupReactions.map(\.memberID)),
                               activeMembers: activeMembers
                           ) {
                            targetMeta.groupReactions.append(reaction)
                            targetForReaction.assistanceMetadata = targetMeta
                        }
                    }
                }

                let fullTextForRouting = replyMsg.content
                let burstParts = GroupDiscussionCoordinator.splitShortBubbles(
                    fullTextForRouting,
                    style: settings.groupSpeechStyle,
                    enabled: settings.groupSplitShortBubbles,
                    intent: step.intent
                )
                if burstParts.count == 2 {
                    replyMsg.content = burstParts[0]
                    try? context.save()
                    try? await Task.sleep(for: .milliseconds(200))
                    if !Task.isCancelled && Self.isAlive(conversation) {
                        let burstSort = (conversation.sortedMessages.last?.sortIndex ?? 0) + 1
                        let secondBubble = ChatMessage(
                            role: .assistant,
                            content: burstParts[1],
                            target: target,
                            comparisonGroupID: nil,
                            isSelectedInGroup: true,
                            isStreaming: false,
                            sortIndex: burstSort
                        )
                        secondBubble.accentHex = step.member.accentHex
                        secondBubble.parentMessageID = shouldUseTree ? replyMsg.id : nil
                        var secondMeta = AssistanceMetadata()
                        secondMeta.groupMemberID = step.member.id
                        secondMeta.groupMemberName = step.member.name
                        secondMeta.isPersonaSimulation = step.member.isSimulatedPersona
                        secondMeta.groupMemberTitle = step.member.title
                        secondMeta.groupMemberEmoji = step.member.avatarEmoji
                        secondMeta.bookReply = replyMsg.assistanceMetadata.bookReply
                        if finalizedDirective.asksHost {
                            secondMeta.groupAskedHost = true
                            var firstMeta = replyMsg.assistanceMetadata
                            firstMeta.groupAskedHost = false
                            replyMsg.assistanceMetadata = firstMeta
                        }
                        secondBubble.assistanceMetadata = secondMeta
                        secondBubble.conversation = conversation
                        conversation.messages.append(secondBubble)
                        context.insert(secondBubble)
                        if shouldUseTree {
                            conversation.activeLeafMessageID = secondBubble.id
                        }
                        roundMessages.append(replyMsg)
                        roundMessages.append(secondBubble)
                    } else {
                        roundMessages.append(replyMsg)
                    }
                } else {
                    roundMessages.append(replyMsg)
                }

                spokenMemberIDs.insert(step.member.id)
                try? context.save()

                if replyMsg.errorMessage != nil {
                    if !explicitQueue.isEmpty {
                        nextStep = explicitQueue.removeFirst()
                    } else if dynamicSmartRelay {
                        let remaining = activeMembers.filter { !spokenMemberIDs.contains($0.id) }
                        nextStep = remaining.first.map { ($0, step.intent, true) }
                    } else {
                        nextStep = nil
                    }
                    continue
                }

                turnsCompleted += 1

                if finalizedDirective.asksHost {
                    nextStep = nil
                } else if !explicitQueue.isEmpty {
                    let queued = explicitQueue.removeFirst()
                    nextStep = queued
                } else if dynamicSmartRelay,
                          let selected = GroupDiscussionCoordinator.selectNextRelaySpeaker(
                              after: step.member,
                              visibleReply: fullTextForRouting,
                              directive: finalizedDirective,
                              activeMembers: activeMembers,
                              spokenMemberIDs: spokenMemberIDs,
                              turnsCompleted: turnsCompleted,
                              maxRelayTurns: maxRelayTurns,
                              speakingMode: settings.groupSpeakingMode
                          ) {
                    nextStep = (selected.member, selected.intent, true)
                } else {
                    nextStep = nil
                }

                if nextStep != nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(160))
                }
            }

            if Self.isAlive(conversation) {
                conversation.updatedAt = Date()
                try? context.save()
                SpotlightIndexService.shared.indexConversation(conversation)
            }
            self.finishGeneration(conversationID: convID, token: token)

            if let expectedTitle = expectedTitleForAutoGenerate, Self.isAlive(conversation) {
                self.scheduleAutoTitleGeneration(
                    for: conversation,
                    providers: providers,
                    context: context,
                    expectedUnchangedTitle: expectedTitle
                )
            }
        }

        activeGenerations[convID] = ActiveGeneration(token: token, task: masterTask, context: context)
        updateBackgroundExecution()
    }
}
