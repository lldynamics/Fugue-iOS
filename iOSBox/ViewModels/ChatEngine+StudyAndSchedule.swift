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
            kind: .titleGeneration,
            pricingMultiplier: AppPreferences.shared.pricingMultiplier(for: target.providerID)
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

    // MARK: - Study Flashcards & Quiz Actions

    func studyTarget(
        for message: ChatMessage,
        in conversation: Conversation,
        providers: [ProviderConfig]
    ) -> (target: ResolvedModelTarget, provider: ProviderConfig, spec: ModelSpec)? {
        guard !message.assistanceMetadata.isExcludedFromContext else { return nil }
        let candidate = replyTarget(message, in: conversation, providers: providers)
            ?? conversation.primaryTarget.flatMap { AssistancePolicy.resolve($0, providers: providers) }
            ?? availableTargets(from: providers).first
        guard let candidate,
              let provider = providers.first(where: { $0.id == candidate.providerID && $0.isEnabled && !$0.isDeleted }),
              let spec = provider.enabledModels.first(where: { $0.id == candidate.modelID }) else {
            return nil
        }
        return (provider.makeTarget(for: spec), provider, spec)
    }

    func generateStudyFlashcards(
        for message: ChatMessage,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) async throws {
        guard !generatingStudyMessageIDs.contains(message.id) else { return }
        guard let resolved = studyTarget(for: message, in: conversation, providers: providers) else {
            throw LLMError.unavailableModel
        }
        let source = buildStudySourceContext(for: message, in: conversation)
        generatingStudyMessageIDs.insert(message.id)
        defer { generatingStudyMessageIDs.remove(message.id) }

        let cards = try await StudyGeneratorService.requestFlashcards(
            sourceText: source,
            target: resolved.target,
            provider: resolved.provider,
            spec: resolved.spec,
            conversationID: conversation.id,
            messageID: message.id,
            context: context,
            stream: stream
        )
        guard Self.isAlive(message) else { return }
        var meta = message.assistanceMetadata
        meta.generatedFlashcards = cards
        message.assistanceMetadata = meta
        try? context.save()
    }

    func generateStudyQuiz(
        for message: ChatMessage,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) async throws {
        guard !generatingStudyMessageIDs.contains(message.id) else { return }
        guard let resolved = studyTarget(for: message, in: conversation, providers: providers) else {
            throw LLMError.unavailableModel
        }
        let source = buildStudySourceContext(for: message, in: conversation)
        generatingStudyMessageIDs.insert(message.id)
        defer { generatingStudyMessageIDs.remove(message.id) }

        let quiz = try await StudyGeneratorService.requestQuiz(
            sourceText: source,
            fallbackTitle: conversation.title,
            target: resolved.target,
            provider: resolved.provider,
            spec: resolved.spec,
            conversationID: conversation.id,
            messageID: message.id,
            context: context,
            stream: stream
        )
        guard Self.isAlive(message) else { return }
        var meta = message.assistanceMetadata
        meta.generatedQuiz = quiz
        message.assistanceMetadata = meta
        try? context.save()
    }

    func selectQuizOption(
        questionID: UUID,
        optionIndex: Int,
        on message: ChatMessage,
        context: ModelContext
    ) {
        var meta = message.assistanceMetadata
        guard var quiz = meta.generatedQuiz,
              let qIdx = quiz.questions.firstIndex(where: { $0.id == questionID }),
              quiz.questions[qIdx].options.indices.contains(optionIndex) else { return }
        quiz.questions[qIdx].selectedIndex = optionIndex
        meta.generatedQuiz = quiz
        message.assistanceMetadata = meta
        try? context.save()
    }

    private func buildStudySourceContext(for message: ChatMessage, in conversation: Conversation) -> String {
        let active = ConversationTree.activeMessages(in: conversation)
        var parts: [String] = []
        if let idx = active.firstIndex(where: { $0.id == message.id }), idx > 0 {
            let prev = active[idx - 1]
            if prev.role == .user && !prev.assistanceMetadata.isExcludedFromContext && !prev.content.isEmpty {
                parts.append("Question / Topic:\n" + String(prev.content.prefix(2_000)))
            }
        }
        if let bookExcerpts = message.assistanceMetadata.bookReply,
           let ref = try? bookExcerpts.referenceText(), !ref.isEmpty {
            parts.append(String(ref.prefix(4_000)))
        }
        if !message.content.isEmpty {
            parts.append("Explanation / Material:\n" + String(message.content.prefix(12_000)))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Schedule / EventKit Proposal Actions

    func extractScheduleItems(
        for message: ChatMessage,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) async throws {
        guard !generatingStudyMessageIDs.contains(message.id) else { return }
        guard let resolved = studyTarget(for: message, in: conversation, providers: providers) else {
            throw LLMError.unavailableModel
        }
        let source = buildStudySourceContext(for: message, in: conversation)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudyGenerationError.emptySource
        }

        generatingStudyMessageIDs.insert(message.id)
        defer { generatingStudyMessageIDs.remove(message.id) }

        let apiKey = resolved.provider.apiKey
        let isLocal = NetworkLocation.isLocalOrPrivate(baseURL: resolved.provider.baseURL)
        if !resolved.provider.hasAuthentication && !isLocal {
            throw LLMError.missingAPIKey(resolved.provider.name)
        }
        let validateTarget = resolved.provider.transmissionCheck(for: resolved.target.modelID)

        var req = LLMChatRequest(
            providerName: resolved.provider.name,
            protocolType: resolved.provider.protocolType,
            baseURL: resolved.provider.baseURL,
            apiKey: apiKey,
            apiKeys: resolved.provider.extraAPIKeys,
            customHeaders: resolved.provider.resolvedCustomHeaders,
            modelID: resolved.target.modelID,
            supportsReasoning: resolved.spec.supportsReasoning,
            systemPrompt: ScheduleExtractorService.systemPrompt,
            messages: [LLMPromptMessage(role: .user, content: "Current local time: \(Date().formatted(date: .numeric, time: .shortened))\n\nExtract action items and calendar events:\n\n" + String(source.prefix(12_000)))],
            temperature: 0.2,
            topP: 1.0,
            maxOutputTokens: 1536,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            idleTimeoutSeconds: resolved.provider.customIdleTimeout
        )
        req.validateBeforeSending = { try validateTarget() }

        var start = ContinuousClock.now
        var record = RequestRecord(
            target: resolved.target,
            spec: resolved.spec,
            conversationID: conversation.id,
            messageID: message.id,
            kind: .studyGeneration,
            pricingMultiplier: AppPreferences.shared.pricingMultiplier(for: resolved.target.providerID)
        )
        context.insert(record)

        var raw = ""
        do {
            for try await event in stream(req) {
                let elapsed = Self.milliseconds(start.duration(to: .now))
                if case .retrying(let status) = event {
                    record = record.startRetry(
                        after: status,
                        elapsedMs: max(1, elapsed),
                        target: resolved.target,
                        spec: resolved.spec,
                        in: context
                    )
                    raw = ""
                    start = .now
                    continue
                }
                record.observe(event, elapsedMs: max(0, elapsed))
                if case .contentDelta(let d) = event { raw += d }
            }
            record.finish(.succeeded, elapsedMs: max(1, Self.milliseconds(start.duration(to: .now))))
        } catch {
            if case LLMError.httpError(let status, _) = error {
                record.httpStatus = status
            }
            record.finish(Self.isCancellation(error) ? .cancelled : .failed, elapsedMs: max(1, Self.milliseconds(start.duration(to: .now))))
            try? context.save()
            throw error
        }

        let extracted = ScheduleExtractorService.parseScheduleItemsJSON(raw)
        guard !extracted.isEmpty else {
            try? context.save()
            throw LLMError.apiError(String(localized: "未从该条内容中识别出明确的待办事项或日程安排。"))
        }
        guard Self.isAlive(message) else { return }
        var meta = message.assistanceMetadata
        for item in extracted where !meta.proposedSchedules.contains(where: { $0.title == item.title && $0.kind == item.kind }) {
            meta.proposedSchedules.append(item)
        }
        message.assistanceMetadata = meta
        try? context.save()
    }

    func confirmScheduleProposal(
        _ item: ProposedScheduleItem,
        on message: ChatMessage,
        context: ModelContext
    ) async throws {
        try await EventKitService.shared.saveToSystem(item)
        dismissScheduleProposal(item, on: message, context: context)
    }

    func dismissScheduleProposal(
        _ item: ProposedScheduleItem,
        on message: ChatMessage,
        context: ModelContext
    ) {
        var meta = message.assistanceMetadata
        meta.proposedSchedules.removeAll { $0.id == item.id }
        if !meta.handledScheduleIDs.contains(item.id) {
            meta.handledScheduleIDs.append(item.id)
        }
        if meta.hasPersistedContent {
            message.assistanceMetadata = meta
        } else {
            message.assistanceMetadataData = nil
        }
        try? context.save()
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
