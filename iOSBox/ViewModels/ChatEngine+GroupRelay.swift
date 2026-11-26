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
            expectedTitleForAutoGenerate: String?,
            mentions: GroupDiscussionCoordinator.MentionParseResult?,
            mentionOnly: Bool
        )
        case continueDiscussion
        case groupVote
        case summarize(by: GroupMember)
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
            text: text,
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
        guard sendTargets(text: "", attachments: [], in: conversation, providers: providers, forGroupAction: true) != nil else {
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
        guard sendTargets(text: "", attachments: [], in: conversation, providers: providers, forGroupAction: true) != nil else {
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
        guard let chosen = groupSummarizer(member, in: conversation, providers: providers)?.member else {
            return .noAvailableModel
        }
        let mentionPrefix = "@\(chosen.mentionToken) "
        appendHostGroupActionMessage(
            String(localized: "📋 \(mentionPrefix)请帮大家梳理总结目前讨论的核心共识、关键分歧与下一步行动建议。"),
            in: conversation,
            context: context
        )
        launchGroupRelaySession(mode: .summarize(by: chosen), in: conversation, providers: providers, context: context)
        return .sent
    }

    func groupSummarizer(_ preferred: GroupMember?, in conversation: Conversation,
                         providers: [ProviderConfig]) -> (member: GroupMember, target: ResolvedModelTarget)? {
        let candidates = conversation.activeGroupMembers.reversed()
        for member in candidates {
            if let preferred, preferred.id != member.id || preferred.target.id != member.target.id { continue }
            if let target = AssistancePolicy.resolve(member.target, providers: providers),
               providers.contains(where: { $0.id == target.providerID && $0.hasConfiguredChatAPI }) {
                return (member, target)
            }
        }
        return nil
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
        let nextSort = conversation.nextMessageSortIndex()
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
            var speakingMode = settings.groupSpeakingMode
            let capturedMentions: GroupDiscussionCoordinator.MentionParseResult?
            if case .afterUserMessage(_, _, _, _, _, _, let mentions, let only) = mode {
                if only { speakingMode = .mentionOnly }
                capturedMentions = mentions
            } else {
                capturedMentions = nil
            }
            let resolvedRoster: [(member: GroupMember, target: ResolvedModelTarget)] = conversation.activeGroupMembers.compactMap { m in
                if speakingMode == .mentionOnly, let capturedMentions,
                   !capturedMentions.members.contains(where: { $0.id == m.id && $0.target.id == m.target.id }) {
                    return nil
                }
                guard let resolved = AssistancePolicy.resolve(m.target, providers: providers) else { return nil }
                var copy = m
                copy.target = resolved
                return (copy, resolved)
            }
            let activeMembers = resolvedRoster.map(\.member)
            let targetByMemberID = Dictionary(resolvedRoster.map { ($0.member.id, $0.target) }, uniquingKeysWith: { first, _ in first })
            let resolvedMentions = capturedMentions.map { mentions in
                GroupDiscussionCoordinator.MentionParseResult(mentionsAll: mentions.mentionsAll, members: mentions.members.compactMap { selected in
                    activeMembers.first { $0.id == selected.id && $0.target.id == selected.target.id }
                })
            }

            guard !activeMembers.isEmpty else {
                self.finishGeneration(conversationID: convID, token: token, statuses: [.blocked])
                return
            }

            let omitMemory: Bool
            let memoryInfo: (systemPrompt: String, count: Int)
            var searchEvidence: SearchEvidence?
            var knowledgeEvidence: KnowledgeEvidence?
            var requestedSearchQuery: String?
            var expectedTitleForAutoGenerate: String?

            let limits = conversation.readingChapterLimits
            let sourceOptions: AssistanceMetadata?
            switch mode {
            case .afterUserMessage(let question, _, _, _, _, _, _, _):
                sourceOptions = question.assistanceMetadata
            default:
                let active = ConversationTree.activeMessages(in: conversation)
                if let start = active.lastIndex(where: { $0.role == .user }) {
                    var original = active[start].assistanceMetadata
                    // Earlier archives recorded per-turn exclusions on the answering messages.
                    let answers = active[start...].filter { $0.role == .assistant }.map(\.assistanceMetadata)
                    original.omittedMemory = original.omittedMemory || answers.contains(where: \.omittedMemory)
                    original.omittedKnowledge = original.omittedKnowledge || answers.contains(where: \.omittedKnowledge)
                    sourceOptions = original
                } else {
                    sourceOptions = nil
                }
            }
            let omitKnowledge = sourceOptions?.omittedKnowledge ?? false
            let kbVolumeIDs = omitKnowledge ? [] : conversation.assistanceSettings.knowledgeVolumeIDs
            if !kbVolumeIDs.isEmpty {
                let q = self.bookQuestion(in: ConversationTree.activeMessages(in: conversation))
                knowledgeEvidence = try? await ProjectKnowledgeSearch.retrieve(volumeIDs: kbVolumeIDs, in: context, query: q, maxPassages: 4, chapterLimits: limits)
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
            case .afterUserMessage(let userMsg, _, let sq, let omit, let mem, let expectedTitle, _, _):
                omitMemory = omit
                memoryInfo = mem
                requestedSearchQuery = sq
                expectedTitleForAutoGenerate = speakingMode == .mentionOnly ? nil : expectedTitle

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
                            let nextSort = conversation.nextMessageSortIndex()
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
                            errMeta.selectedMemoryIDs = sourceOptions?.selectedMemoryIDs
                            errMeta.omittedKnowledge = omitKnowledge
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
                        self.finishGeneration(conversationID: convID, token: token, statuses: [searchRecord.status])
                        return
                    }
                }

            case .continueDiscussion, .groupVote, .summarize:
                omitMemory = sourceOptions?.omittedMemory ?? false
                memoryInfo = self.prepareMemory(conversation: conversation, omitMemory: omitMemory,
                                                selectedIDs: sourceOptions?.selectedMemoryIDs, context: context)
            }

            if Task.isCancelled || !Self.isAlive(conversation) {
                self.finishGeneration(conversationID: convID, token: token, statuses: [.cancelled])
                return
            }

            var explicitQueue: [(member: GroupMember, intent: GroupSpeechIntent, allowPass: Bool)] = []
            let maxRelayTurns: Int
            let dynamicSmartRelay: Bool

            switch mode {
            case .afterUserMessage(let userMsg, let priorMessages, _, _, _, _, _, _):
                let planned = GroupDiscussionCoordinator.selectInitialPlan(
                    userText: userMsg.content,
                    activeMembers: activeMembers,
                    speakingMode: speakingMode,
                    maxRelayTurns: settings.groupMaxRelayTurns,
                    priorMessages: priorMessages,
                    resolvedMentions: resolvedMentions
                )
                if planned.isEmpty {
                    self.finishGeneration(conversationID: convID, token: token, statuses: [.blocked])
                    return
                }
                let hasExplicitMentions = planned.contains(where: \.explicitMention)
                maxRelayTurns = GroupDiscussionCoordinator.maximumTurnsForUserMessage(
                    speakingMode: speakingMode, plannedCount: planned.count, explicitMentions: hasExplicitMentions,
                    activeCount: activeMembers.count, configuredLimit: settings.groupMaxRelayTurns
                )
                if speakingMode == .smartRelay && !hasExplicitMentions {
                    explicitQueue = [(planned[0].member, planned[0].intent, false)]
                    dynamicSmartRelay = true
                } else if speakingMode == .smartRelay && hasExplicitMentions {
                    explicitQueue = planned.map { ($0.member, $0.intent, false) }
                    dynamicSmartRelay = true
                } else {
                    explicitQueue = planned.map { ($0.member, $0.intent, !hasExplicitMentions) }
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
                dynamicSmartRelay = speakingMode != .mentionOnly
                maxRelayTurns = dynamicSmartRelay ? min(max(settings.groupMaxRelayTurns, 2), max(activeMembers.count, 2)) : 1

            case .groupVote:
                explicitQueue = activeMembers.map { ($0, .vote, false) }
                maxRelayTurns = activeMembers.count
                dynamicSmartRelay = false

            case .summarize(let preferred):
                guard let summarizer = activeMembers.first(where: { $0.id == preferred.id && $0.target.id == preferred.target.id }) else {
                    self.finishGeneration(conversationID: convID, token: token, statuses: [.blocked])
                    return
                }
                explicitQueue = [(summarizer, .summarize, false)]
                maxRelayTurns = 1
                dynamicSmartRelay = false
            }

            var turnsCompleted = 0
            var turnOutcomes: [RequestStatus] = []
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
                    completedTurns: turnOutcomes.filter { $0 == .succeeded }.count,
                    totalTurns: maxRelayTurns,
                    force: true
                )

                let shouldUseTree = ConversationTree.usesTree(conversation)
                let parentID = shouldUseTree
                    ? (ConversationTree.currentAnchorID(in: conversation) ?? ConversationTree.virtualRootID)
                    : nil
                let priorActive = ConversationTree.activeMessages(in: conversation)

                let nextSort = conversation.nextMessageSortIndex()
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
                meta.selectedMemoryIDs = sourceOptions?.selectedMemoryIDs
                meta.omittedKnowledge = omitKnowledge
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
                    preferEnglish: englishPreferred,
                    recordReferences: { replyMsg.assistanceMetadata.personaExcerpts = $0 }
                )
                if let searchEvidence, let lastIdx = memberHistory.indices.last {
                    let oldLast = memberHistory[lastIdx]
                    memberHistory[lastIdx] = LLMPromptMessage(
                        role: oldLast.role,
                        content: oldLast.content + "\n\n" + searchEvidence.prompt,
                        attachments: oldLast.attachments
                    )
                }
                if let knowledgeEvidence, !knowledgeEvidence.passages.isEmpty, let lastIdx = memberHistory.indices.last {
                    let oldLast = memberHistory[lastIdx]
                    memberHistory[lastIdx] = LLMPromptMessage(
                        role: oldLast.role,
                        content: oldLast.content + "\n\n" + knowledgeEvidence.promptText(),
                        attachments: oldLast.attachments
                    )
                }

                let friendMemoryPrompt: String? = {
                    guard !omitMemory,
                          step.intent != .summarize,
                          let subject = FriendMemorySubject.from(member: step.member),
                          let prompt = self.friendMemoryStore.promptBlock(for: subject, preferEnglish: englishPreferred) else {
                        return nil
                    }
                    return prompt.text
                }()
                let combinedBaseSystemPrompt = [memoryInfo.systemPrompt, friendMemoryPrompt]
                    .compactMap { $0 }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")

                let systemPrompt = GroupDiscussionCoordinator.buildSystemPrompt(
                    for: step.member,
                    activeMembers: activeMembers,
                    speechStyle: settings.groupSpeechStyle,
                    intent: step.intent,
                    baseSystemPrompt: combinedBaseSystemPrompt,
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
                    bookTurn: step.member.bookFriend.map { BookTurn(friend: $0, question: self.bookQuestion(in: priorActive), memberID: step.member.id) },
                    knowledgeChapterLimits: kbVolumeIDs.isEmpty ? nil : limits
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

                turnOutcomes.append(Self.outcomeStatus(of: replyMsg))
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
                if burstParts.count > 1 {
                    replyMsg.content = burstParts[0]
                    try? context.save()
                    roundMessages.append(replyMsg)
                    var lastEmittedBubble = replyMsg

                    for segIdx in 1..<burstParts.count {
                        try? await Task.sleep(for: .milliseconds(200))
                        if Task.isCancelled || !Self.isAlive(conversation) {
                            if Self.isAlive(lastEmittedBubble) {
                                if segIdx == 1 {
                                    lastEmittedBubble.content = fullTextForRouting
                                } else {
                                    let remainingText = burstParts[segIdx...].joined(separator: "\n\n")
                                    lastEmittedBubble.content = lastEmittedBubble.content.isEmpty
                                        ? remainingText
                                        : (lastEmittedBubble.content + "\n\n" + remainingText)
                                }
                                if finalizedDirective.asksHost {
                                    var restoredMeta = lastEmittedBubble.assistanceMetadata
                                    restoredMeta.groupAskedHost = true
                                    lastEmittedBubble.assistanceMetadata = restoredMeta
                                }
                                try? context.save()
                            }
                            break
                        }

                        let burstSort = conversation.nextMessageSortIndex()
                        let extraBubble = ChatMessage(
                            role: .assistant,
                            content: burstParts[segIdx],
                            target: target,
                            comparisonGroupID: nil,
                            isSelectedInGroup: true,
                            isStreaming: false,
                            sortIndex: burstSort
                        )
                        extraBubble.accentHex = step.member.accentHex
                        extraBubble.parentMessageID = shouldUseTree ? lastEmittedBubble.id : nil
                        var extraMeta = AssistanceMetadata()
                        extraMeta.groupMemberID = step.member.id
                        extraMeta.groupMemberName = step.member.name
                        extraMeta.isPersonaSimulation = step.member.isSimulatedPersona
                        extraMeta.groupMemberTitle = step.member.title
                        extraMeta.groupMemberEmoji = step.member.avatarEmoji
                        extraMeta.omittedKnowledge = replyMsg.assistanceMetadata.omittedKnowledge
                        extraMeta.bookReply = replyMsg.assistanceMetadata.bookReply
                        extraMeta.personaExcerpts = replyMsg.assistanceMetadata.personaExcerpts
                        let isLastSegment = segIdx == burstParts.count - 1
                        if finalizedDirective.asksHost {
                            var prevMeta = lastEmittedBubble.assistanceMetadata
                            prevMeta.groupAskedHost = false
                            lastEmittedBubble.assistanceMetadata = prevMeta
                            if isLastSegment {
                                extraMeta.groupAskedHost = true
                            }
                        }
                        extraBubble.assistanceMetadata = extraMeta
                        extraBubble.conversation = conversation
                        conversation.messages.append(extraBubble)
                        context.insert(extraBubble)
                        if shouldUseTree {
                            conversation.activeLeafMessageID = extraBubble.id
                        }
                        try? context.save()
                        roundMessages.append(extraBubble)
                        lastEmittedBubble = extraBubble
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
            self.finishGeneration(conversationID: convID, token: token, statuses: turnOutcomes)

            if let expectedTitle = expectedTitleForAutoGenerate, Self.isAlive(conversation) {
                self.scheduleAutoTitleGeneration(
                    for: conversation,
                    providers: providers,
                    context: context,
                    expectedUnchangedTitle: expectedTitle
                )
            }
            if Self.isAlive(conversation) {
                let spokenIDs = Set(roundMessages.compactMap { $0.assistanceMetadata.groupMemberID })
                let spokenKeys = Set(
                    conversation.groupMembers
                        .filter { spokenIDs.contains($0.id) }
                        .compactMap { FriendMemorySubject.from(member: $0)?.friendKey }
                )
                if !spokenKeys.isEmpty {
                    self.scheduleFriendMemoryExtractionIfNeeded(
                        for: conversation,
                        speakerKeysFilter: spokenKeys,
                        providers: providers,
                        context: context
                    )
                }
            }
        }

        activeGenerations[convID] = ActiveGeneration(token: token, task: masterTask, context: context)
        updateBackgroundExecution()
    }
}
