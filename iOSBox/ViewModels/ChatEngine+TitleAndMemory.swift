import Foundation
import SwiftData

extension ChatEngine {
    // MARK: - Smart Title Generation

    func scheduleAutoTitleGeneration(
        for conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext,
        expectedUnchangedTitle: String
    ) {
        let convID = conversation.id
        activeTitleTasks[convID]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeTitleTasks.removeValue(forKey: convID)
                self.updateBackgroundExecution()
            }
            _ = await self.generateSmartTitle(
                for: conversation,
                providers: providers,
                context: context,
                expectedUnchangedTitle: expectedUnchangedTitle
            )
        }
        activeTitleTasks[convID] = task
        updateBackgroundExecution()
    }

    @MainActor
    @discardableResult
    func generateSmartTitle(
        for conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext,
        expectedUnchangedTitle: String? = nil
    ) async -> String? {
        guard Self.isAlive(conversation), !Task.isCancelled,
              expectedUnchangedTitle == nil || expectedUnchangedTitle == conversation.title else { return nil }
        let visible = eligiblePromptContext(ConversationTree.activeMessages(in: conversation)).filter { !$0.content.isEmpty }
        guard let firstUser = visible.first(where: { $0.role == .user }),
              let firstAssistant = visible.first(where: { $0.role == .assistant }) else {
            return nil
        }

        let target = titleTarget(in: conversation, providers: providers)
        guard let target,
              let provider = providers.first(where: { $0.id == target.providerID && $0.isEnabled }) else {
            return nil
        }
        let apiKey = provider.apiKey
        let extraKeys = provider.extraAPIKeys
        let isLocalHost = NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)
        guard provider.hasAuthentication || isLocalHost else { return nil }

        let userExcerpt = String(firstUser.content.prefix(400))
        let assistantExcerpt = String(firstAssistant.content.prefix(500))
        var request = LLMChatRequest(
            providerName: provider.name,
            protocolType: provider.protocolType,
            baseURL: provider.baseURL,
            apiKey: apiKey,
            apiKeys: extraKeys,
            customHeaders: provider.resolvedCustomHeaders,
            modelID: target.modelID,
            supportsReasoning: false,
            systemPrompt: "Summarize the conversation topic into a concise plain-text title (max 14 characters in Chinese or 6 words in English). Output only the title without quotes or trailing punctuation.",
            messages: [
                LLMPromptMessage(role: .user, content: "User: \(userExcerpt)\n\nAssistant: \(assistantExcerpt)")
            ],
            temperature: 0.2,
            topP: 1.0,
            maxOutputTokens: 48,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enablePromptCaching: false,
            idleTimeoutSeconds: provider.customIdleTimeout
        )

        let validateRecipient = provider.transmissionCheck(for: target.modelID)
        request.validateBeforeSending = { [weak self, weak conversation] in
            try validateRecipient()
            guard let self, let conversation, Self.isAlive(conversation) else { throw AppCompliance.RequestChanged() }
            let current = self.eligiblePromptContext(ConversationTree.activeMessages(in: conversation)).filter { !$0.content.isEmpty }
            guard current.first(where: { $0.role == .user })?.id == firstUser.id,
                  current.first(where: { $0.role == .assistant })?.id == firstAssistant.id,
                  String(firstUser.content.prefix(400)) == userExcerpt,
                  String(firstAssistant.content.prefix(500)) == assistantExcerpt else { throw AppCompliance.RequestChanged() }
        }
        let spec = provider.enabledModels.first { $0.id == target.modelID }
        var record = RequestRecord(
            target: target,
            spec: spec,
            conversationID: conversation.id,
            messageID: firstUser.id,
            kind: .titleGeneration
        )
        context.insert(record)
        do { try context.save() } catch { context.delete(record); return nil }
        var started = ContinuousClock.now
        var rawTitle = ""
        var abnormalFinish = false
        defer { if context.hasChanges { try? context.save() } }
        do {
            try Task.checkCancellation()
            try request.validateBeforeSending?()
            for try await event in self.stream(request) {
                try Task.checkCancellation()
                let elapsed = Self.milliseconds(started.duration(to: .now))
                record.observe(event, elapsedMs: elapsed)
                switch event {
                case .retrying(let status):
                    record = record.startRetry(after: status, elapsedMs: elapsed, target: target, spec: spec, in: context)
                    started = .now
                    rawTitle = ""
                    abnormalFinish = false
                    try context.save()
                case .contentDelta(let delta):
                    rawTitle.append(delta)
                case .finished:
                    abnormalFinish = true
                case .toolCall:
                    throw LLMError.unavailableTool
                default:
                    break
                }
            }
            try Task.checkCancellation()
        } catch {
            if case LLMError.httpError(let status, _) = error { record.httpStatus = status }
            record.finish(Self.isCancellation(error) ? .cancelled : .failed,
                          elapsedMs: Self.milliseconds(started.duration(to: .now)))
            return nil
        }

        let cleaned = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'「」《》。.!")))
        let status: RequestStatus = abnormalFinish ? .incomplete : (cleaned.isEmpty ? .failed : .succeeded)
        record.finish(status, elapsedMs: Self.milliseconds(started.duration(to: .now)))
        guard status == .succeeded, Self.isAlive(conversation) else { return nil }
        if let expectedUnchangedTitle, conversation.title != expectedUnchangedTitle {
            return nil
        }
        let bounded = String(cleaned.prefix(32))
        let previousTitle = conversation.title
        let previousEdits = conversation.backupState.organizationEdits
        conversation.rename(to: bounded)
        do { try context.save() } catch {
            conversation.title = previousTitle
            conversation.backupState.organizationEdits = previousEdits
            return nil
        }
        SpotlightIndexService.shared.indexConversation(conversation)
        return bounded
    }

    // MARK: - Memory Proposal Actions

    @discardableResult
    func acceptMemoryProposal(_ fact: String, on message: ChatMessage, context: ModelContext) -> Bool {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let existing = (try? context.fetch(FetchDescriptor<PersonalMemory>())) ?? []
        let alreadyStored = existing.contains(where: { $0.content.caseInsensitiveCompare(trimmed) == .orderedSame })
        if !alreadyStored {
            guard existing.count < PersonalMemory.maximumCount else {
                return false
            }
            context.insert(PersonalMemory(content: String(trimmed.prefix(PersonalMemory.maximumCharacters))))
        }
        dismissMemoryProposal(fact, on: message, context: context)
        return true
    }

    func dismissMemoryProposal(_ fact: String, on message: ChatMessage, context: ModelContext) {
        var meta = message.assistanceMetadata
        meta.proposedMemories.removeAll { $0 == fact }
        if !meta.handledMemories.contains(fact) {
            meta.handledMemories.append(fact)
        }
        if meta.hasPersistedContent {
            message.assistanceMetadata = meta
        } else {
            message.assistanceMetadataData = nil
        }
        try? context.save()
    }
}
