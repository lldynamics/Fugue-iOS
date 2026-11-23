import Foundation
import SwiftData

extension ChatEngine {
    // MARK: - Arena Comparison, Critique, Synthesis & Blind Voting

    static func setBlindArenaMode(_ enabled: Bool, in conversation: Conversation) {
        conversation.assistanceSettings.blindArenaMode = enabled
        if enabled, conversation.isArenaMode || conversation.messages.contains(where: { $0.comparisonGroupID != nil && $0.isStreaming }) {
            LiveActivityCoordinator.shared.anonymizeComparison(in: conversation.id)
        }
    }

    /// Promotes a single-chat assistant reply into a side-by-side comparison group with a second model.
    func compareWithAnotherModel(
        assistantMessage: ChatMessage,
        secondTarget: ResolvedModelTarget,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) {
        guard !isGenerating(in: conversation.id),
              assistantMessage.role == .assistant,
              assistantMessage.comparisonGroupID == nil,
              let resolvedSecond = AssistancePolicy.resolve(secondTarget, providers: providers) else {
            return
        }

        let active = ConversationTree.activeMessages(in: conversation)
        guard let targetIdx = active.firstIndex(where: { $0.id == assistantMessage.id }) else { return }

        let priorMessages = Array(active[..<targetIdx])
        let historySnapshot = buildPromptHistory(messages: priorMessages, limit: conversation.contextMessageLimit)
        guard !historySnapshot.isEmpty else { return }

        let groupID = UUID()
        conversation.normalizeMessageOrderIfNeeded()
        assistantMessage.comparisonGroupID = groupID
        assistantMessage.isSelectedInGroup = true

        let secondReply = ChatMessage(
            role: .assistant,
            target: resolvedSecond,
            comparisonGroupID: groupID,
            isSelectedInGroup: false,
            isStreaming: true,
            sortIndex: assistantMessage.sortIndex + 1,
            createdAt: assistantMessage.createdAt.addingTimeInterval(0.001)
        )
        secondReply.parentMessageID = assistantMessage.parentMessageID
        secondReply.conversation = conversation
        conversation.messages.append(secondReply)
        context.insert(secondReply)

        let meta = assistantMessage.assistanceMetadata
        if meta.omittedKnowledge { secondReply.assistanceMetadata.omittedKnowledge = true }
        let memoryInfo = prepareMemory(
            conversation: conversation,
            omitMemory: meta.omittedMemory,
            context: context
        )
        try? context.save()

        let slot = StreamSlot(
            message: secondReply,
            candidates: [resolvedSecond],
            kind: .answer,
            systemPromptOverride: memoryInfo.systemPrompt,
            bookTurn: conversation.activeBookFriend.map { BookTurn(friend: $0, question: bookQuestion(in: priorMessages)) }
        )

        launchStreamingTasks(
            slots: [slot],
            historySnapshot: historySnapshot,
            searchQuery: nil,
            conversation: conversation,
            providers: providers,
            context: context
        )
    }

    @discardableResult
    func crossCritique(
        groupID: UUID,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) -> SynthesisOutcome {
        guard !isGenerating(in: conversation.id) else { return .busy }
        let active = ConversationTree.activeMessages(in: conversation)
        let eligible = ArenaSynthesis.eligibleSources(in: active, groupID: groupID)
        guard eligible.count >= 2 else { return .insufficientAnswers }
        let targets = eligible.compactMap { source in
            source.providerID == nil ? nil : replyTarget(source, in: conversation, providers: providers)
        }
        guard targets.count == eligible.count else { return .unavailableModel }

        guard let firstGroupIdx = active.firstIndex(where: { $0.comparisonGroupID == groupID }),
              let lastGroupIdx = active.lastIndex(where: { $0.comparisonGroupID == groupID }) else {
            return .missingQuestion
        }
        let priorMessages = Array(active[..<firstGroupIdx])
        guard priorMessages.last?.role == .user else {
            return .missingQuestion
        }

        let baseHistory = buildPromptHistory(messages: priorMessages, limit: conversation.contextMessageLimit)
        let isHistoricalTurn = lastGroupIdx < active.count - 1
        if isHistoricalTurn {
            ConversationTree.ensureExplicitParentLinks(in: conversation)
        }
        let useTree = ConversationTree.usesTree(conversation)
        let groupMembers = active.filter { $0.comparisonGroupID == groupID }
        let groupWinner = groupMembers.first(where: \.isSelectedInGroup) ?? groupMembers.first
        let anchorID: UUID?
        if useTree {
            anchorID = groupWinner?.id ?? ConversationTree.currentAnchorID(in: conversation) ?? ConversationTree.virtualRootID
        } else {
            anchorID = nil
        }

        let nextSort = conversation.nextMessageSortIndex()
        let critiquePromptMsg = ChatMessage(
            role: .user,
            content: String(localized: "请各模型审阅同组其他候选答案，吸收优点并修正遗漏或错误，给出完善后的最终回答。"),
            sortIndex: nextSort
        )
        critiquePromptMsg.parentMessageID = anchorID
        critiquePromptMsg.conversation = conversation
        conversation.messages.append(critiquePromptMsg)
        context.insert(critiquePromptMsg)

        let newGroupID = UUID()
        let isUnrevealedBlind = conversation.assistanceSettings.blindArenaMode
            && !eligible.contains(where: { $0.assistanceMetadata.blindArenaRevealed })
        var slots: [StreamSlot] = []
        var perSlotHistories: [UUID: [LLMPromptMessage]] = [:]

        for (idx, resolved) in targets.enumerated() {
            let reply = ChatMessage(
                role: .assistant,
                target: resolved,
                comparisonGroupID: newGroupID,
                isSelectedInGroup: idx == 0,
                isStreaming: true,
                sortIndex: nextSort + 1 + idx
            )
            if useTree {
                reply.parentMessageID = critiquePromptMsg.id
            }
            reply.conversation = conversation
            conversation.messages.append(reply)
            context.insert(reply)

            perSlotHistories[reply.id] = baseHistory + [
                LLMPromptMessage(
                    role: .user,
                    content: ArenaSynthesis.critiquePrompt(for: resolved, allSources: eligible, blind: isUnrevealedBlind),
                    attachments: []
                )
            ]
            slots.append(StreamSlot(
                message: reply,
                candidates: [resolved],
                kind: .answer,
                systemPromptOverride: ArenaSynthesis.critiqueSystemPrompt
            ))
        }

        if useTree, let first = slots.first?.message {
            conversation.activeLeafMessageID = first.id
        }
        try? context.save()

        let convID = conversation.id
        let token = UUID()
        activeConversationIDs.insert(convID)
        let task = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for slot in slots {
                    let slotHistory = perSlotHistories[slot.message.id] ?? baseHistory
                    group.addTask { @MainActor in
                        _ = await self.runSlotWithFallback(
                            slot: slot,
                            historySnapshot: slotHistory,
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
        }
        activeGenerations[convID] = ActiveGeneration(token: token, task: task, context: context)
        updateBackgroundExecution()
        return .started
    }

    @discardableResult
    func synthesize(
        groupID: UUID,
        target: ResolvedModelTarget,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) -> SynthesisOutcome {
        guard !isGenerating(in: conversation.id) else { return .busy }
        guard let resolvedJudge = AssistancePolicy.resolve(target, providers: providers) else {
            return .unavailableModel
        }

        let active = ConversationTree.activeMessages(in: conversation)
        let allOriginals = ArenaSynthesis.sources(in: active, groupID: groupID)
        let eligible = ArenaSynthesis.eligibleSources(in: active, groupID: groupID)
        guard eligible.count >= 2 else { return .insufficientAnswers }

        guard let firstGroupIdx = active.firstIndex(where: { $0.comparisonGroupID == groupID }) else {
            return .missingQuestion
        }
        let priorMessages = Array(active[..<firstGroupIdx])
        guard priorMessages.last?.role == .user else {
            return .missingQuestion
        }

        let isUnrevealedBlind = conversation.assistanceSettings.blindArenaMode
            && !allOriginals.contains(where: { $0.assistanceMetadata.blindArenaRevealed })
        var historySnapshot = buildPromptHistory(
            messages: priorMessages,
            limit: conversation.contextMessageLimit
        )
        historySnapshot.append(LLMPromptMessage(
            role: .user,
            content: ArenaSynthesis.candidatePrompt(
                eligible,
                totalCount: allOriginals.count,
                blind: isUnrevealedBlind,
                allGroupCandidates: allOriginals
            ),
            attachments: []
        ))

        let digest = ArenaSynthesis.digest(of: allOriginals)
        let summaryMessage: ChatMessage
        if let existing = active.first(where: { $0.comparisonGroupID == groupID && $0.isSynthesis }) {
            summaryMessage = existing
            summaryMessage.providerID = resolvedJudge.providerID
            summaryMessage.providerName = resolvedJudge.providerName
            summaryMessage.modelID = resolvedJudge.modelID
            summaryMessage.modelDisplayName = resolvedJudge.modelDisplayName
            summaryMessage.accentHex = resolvedJudge.accentHex
            summaryMessage.content = ""
            summaryMessage.reasoningContent = ""
            summaryMessage.errorMessage = nil
            summaryMessage.finishReason = nil
            summaryMessage.promptTokens = nil
            summaryMessage.completionTokens = nil
            summaryMessage.cachedTokens = nil
            summaryMessage.latencyMs = nil
            summaryMessage.thinkingDurationMs = nil
            summaryMessage.synthesisSourceDigest = digest
            summaryMessage.isStreaming = true
        } else {
            conversation.normalizeMessageOrderIfNeeded()
            let groupMaxSort = conversation.sortedMessages.filter { $0.comparisonGroupID == groupID }.map(\.sortIndex).max()
                ?? (conversation.sortedMessages.last?.sortIndex ?? 0)
            let created = ChatMessage(
                role: .assistant,
                target: resolvedJudge,
                comparisonGroupID: groupID,
                isSelectedInGroup: false,
                isStreaming: true,
                sortIndex: groupMaxSort + 1
            )
            created.parentMessageID = allOriginals.first?.parentMessageID
            created.synthesisSourceDigest = digest
            created.conversation = conversation
            conversation.messages.append(created)
            context.insert(created)
            summaryMessage = created
        }

        try? context.save()

        let slot = StreamSlot(
            message: summaryMessage,
            candidates: [resolvedJudge],
            kind: .synthesis,
            systemPromptOverride: ArenaSynthesis.systemPrompt
        )

        launchStreamingTasks(
            slots: [slot],
            historySnapshot: historySnapshot,
            searchQuery: nil,
            conversation: conversation,
            providers: providers,
            context: context
        )
        return .started
    }

    func castBlindVote(for winner: ChatMessage, in conversation: Conversation, context: ModelContext) throws {
        guard conversation.assistanceSettings.blindArenaMode, !isGenerating(in: conversation.id),
              let groupID = winner.comparisonGroupID else { return }
        let group = ArenaSynthesis.sources(in: conversation.messages, groupID: groupID)
        guard !group.contains(where: { $0.assistanceMetadata.blindArenaRevealed }) else { return }
        let eligible = group.filter(ArenaSynthesis.isComplete)
        guard eligible.count >= 2, eligible.contains(where: { $0.id == winner.id }) else { return }
        let ballot = ArenaBallot(winnerID: winner.id, candidates: eligible.map {
            .init(messageID: $0.id, providerID: $0.providerID, providerName: $0.providerName,
                  modelID: $0.modelID, modelName: $0.modelDisplayName)
        })
        let previous = group.map { ($0, $0.assistanceMetadataData) }
        for message in group {
            var metadata = message.assistanceMetadata
            metadata.blindArenaRevealed = true
            if message.id == winner.id { metadata.blindArenaBallot = ballot }
            message.assistanceMetadata = metadata
        }
        do { try context.save() } catch {
            for (message, data) in previous { message.assistanceMetadataData = data }
            throw error
        }
    }

    func selectContextReply(_ reply: ChatMessage, in conversation: Conversation, context: ModelContext) throws {
        guard let groupID = reply.comparisonGroupID, !isGenerating(in: conversation.id) else { return }
        let group = conversation.messages.filter { $0.comparisonGroupID == groupID }
        guard group.contains(where: { $0.id == reply.id }),
              !reply.isSynthesis || (ArenaSynthesis.isComplete(reply) && ArenaSynthesis.isCurrent(reply, in: group)) else { return }
        let previous = group.map { ($0, $0.isSelectedInGroup) }
        for message in group { message.isSelectedInGroup = message.id == reply.id }
        do { try context.save() } catch {
            for (message, selected) in previous { message.isSelectedInGroup = selected }
            throw error
        }
    }
}
