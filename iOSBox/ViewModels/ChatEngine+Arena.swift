import Foundation
import SwiftData

extension ChatEngine {
    // MARK: - Arena Comparison & Synthesis

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

        var historySnapshot = buildPromptHistory(
            messages: priorMessages,
            limit: conversation.contextMessageLimit
        )
        historySnapshot.append(LLMPromptMessage(
            role: .user,
            content: ArenaSynthesis.candidatePrompt(eligible, totalCount: allOriginals.count),
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
