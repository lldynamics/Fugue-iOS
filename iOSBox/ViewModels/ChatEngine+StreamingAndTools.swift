import Foundation
import SwiftData

extension ChatEngine {
    // MARK: - External Webpage Approval Gate

    func resolvePendingWebpageApproval(id: UUID, decision: WebpageApprovalDecision, rememberHost: Bool) {
        if rememberHost, decision == .allow,
           let pending = pendingWebpageApproval, pending.id == id,
           let host = pending.url.host?.lowercased(), !host.isEmpty {
            approvedWebpageHostsByConversation[pending.conversationID, default: []].insert(host)
        }
        if pendingWebpageApproval?.id == id {
            pendingWebpageApproval = nil
        }
        if let cont = pendingWebpageContinuations.removeValue(forKey: id) {
            cont.resume(returning: decision)
        }
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

        let prompt = PendingWebpageApproval(conversationID: conversationID, url: url)
        let promptID = prompt.id
        pendingWebpageApproval = prompt

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    if self.pendingWebpageApproval?.id == promptID {
                        self.pendingWebpageApproval = nil
                    }
                    continuation.resume(returning: .deny)
                    return
                }
                self.pendingWebpageContinuations[promptID] = continuation
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

            let isSynthesisTurn = slots.allSatisfy { $0.kind == .synthesis }
            if !isSynthesisTurn && !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty {
                let question = workingHistory.last(where: { $0.role == .user })?.content ?? ""
                if let kbEv = try? await ProjectKnowledgeSearch.retrieve(
                    volumeIDs: conversation.assistanceSettings.knowledgeVolumeIDs,
                    in: context,
                    query: question,
                    maxPassages: 4
                ), !kbEv.passages.isEmpty {
                    for slot in slots where Self.isAlive(slot.message) {
                        var meta = slot.message.assistanceMetadata
                        meta.knowledgeEvidence = kbEv
                        slot.message.assistanceMetadata = meta
                    }
                    if let lastIdx = workingHistory.indices.last {
                        let oldLast = workingHistory[lastIdx]
                        workingHistory[lastIdx] = LLMPromptMessage(
                            role: oldLast.role,
                            content: (oldLast.content.isEmpty ? "" : oldLast.content + "\n\n") + kbEv.promptText(),
                            attachments: oldLast.attachments
                        )
                    }
                }
            }

            if let searchQuery, let primaryMessage = slots.first?.message {
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
                    self.finishGeneration(conversationID: convID, token: token)
                    return
                }
            }

            let finalHistory = workingHistory
            await withTaskGroup(of: Void.self) { group in
                for slot in slots {
                    group.addTask { @MainActor in
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
                let evidence = try await BookReferenceSearch.shared.reference(for: turn.friend, manuscript: book.manuscript, question: turn.question)
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

            let apiKey = KeychainService.shared.loadAPIKey(for: provider.id)
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
            let coachPrompt = (!conversation.isGroupMode && slot.kind != .synthesis)
                ? conversation.assistanceSettings.studyCoachMode.systemInstruction
                : ""
            let rawSystemPrompt = [slot.systemPromptOverride ?? conversation.systemPrompt, slot.bookTurn?.friend.systemInstruction(preferEnglish: preferEnglishBookPrompt), coachPrompt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let renderedSystemPrompt = PromptTemplateEngine.render(rawSystemPrompt, target: target)
            let shouldEnableCache = conversation.assistanceSettings.enablePromptCaching
                && slot.kind != .synthesis

            var workingHistory = groundedHistory
            var toolRound = 0

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
                                context: context
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
                        abnormalFinish: hadAbnormalFinish
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
        context: ModelContext
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
        if call.name == "search_documents" {
            let kbVolumeIDs = conversation.assistanceSettings.knowledgeVolumeIDs
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
                            maxPassages: 5
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
                            maxPassages: 5
                        )
                    }
                }
            }
        } else {
            knowledgeHandler = nil
        }

        let webpageApprovalGate: (@Sendable (URL) async -> WebpageApprovalDecision)?
        if call.name == "read_webpage" {
            let activeUserTexts = ConversationTree.activeMessages(in: conversation)
                .filter { $0.role == .user && !$0.assistanceMetadata.isExcludedFromContext }
                .map { Self.promptContent($0.content, quotedExcerpt: $0.assistanceMetadata.quotedExcerpt) }
            var preapprovedURLs = AgentToolRunner.extractUserProvidedURLs(from: activeUserTexts)
            if let turnSearchSources = message.assistanceMetadata.search?.sources {
                for source in turnSearchSources where source.url.scheme?.lowercased() == "https" {
                    preapprovedURLs.insert(AgentToolRunner.canonicalURLKey(source.url))
                }
            }
            let allowedSnapshot = preapprovedURLs
            webpageApprovalGate = { [weak self] url in
                if allowedSnapshot.contains(AgentToolRunner.canonicalURLKey(url)) {
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
            if let schedule = output.proposedSchedule,
               !meta.handledScheduleIDs.contains(schedule.id),
               !meta.proposedSchedules.contains(where: { $0.title == schedule.title && $0.kind == schedule.kind }) {
                meta.proposedSchedules.append(schedule)
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
        let initialPromptTokens = appendToExisting ? (message.promptTokens ?? 0) : 0
        let initialCompletionTokens = appendToExisting ? (message.completionTokens ?? 0) : 0
        let initialCachedTokens = appendToExisting ? (message.cachedTokens ?? 0) : 0
        let prefixBeforeContinuation = appendToExisting ? message.content : ""
        var roundContent = ""
        var roundReasoning = ""
        var collectedToolCalls: [LLMToolCall] = []
        var collectedThinkingBlocks: [LLMThinkingBlock] = []
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
                    receivedOutput = true
                    roundReasoning.append(delta)
                    if thinkingStartTime == nil {
                        thinkingStartTime = ContinuousClock.now
                    }
                    pendingReasoning.append(delta)
                    if lastFlush.duration(to: ContinuousClock.now) >= .milliseconds(35) {
                        flushBuffers()
                        LiveActivityCoordinator.shared.update(
                            conversationID: conversationID,
                            phaseText: String(localized: "深度思考中…"),
                            previewSnippet: roundReasoning
                        )
                    }

                case .thinkingBlock(let block):
                    collectedThinkingBlocks.append(block)

                case .contentDelta(let delta):
                    guard !delta.isEmpty else { break }
                    receivedOutput = true
                    roundContent.append(delta)
                    if let tStart = thinkingStartTime, !recordedThinkingDuration, Self.isAlive(message) {
                        message.thinkingDurationMs = Self.milliseconds(tStart.duration(to: ContinuousClock.now))
                        recordedThinkingDuration = true
                    }
                    let visibleDelta = sanitizer != nil ? sanitizer!.ingest(delta) : delta
                    if !visibleDelta.isEmpty {
                        pendingContent.append(visibleDelta)
                        if lastFlush.duration(to: ContinuousClock.now) >= .milliseconds(35) {
                            flushBuffers()
                            LiveActivityCoordinator.shared.update(
                                conversationID: conversationID,
                                phaseText: String(localized: "正在生成…"),
                                previewSnippet: roundContent
                            )
                        }
                    }

                case .attachmentDelta(let attachment):
                    receivedOutput = true
                    if Self.isAlive(message) {
                        var current = message.attachments
                        current.append(attachment)
                        message.attachments = current
                    }

                case .toolCall(let call):
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
                    if let prompt {
                        message.promptTokens = appendToExisting ? (initialPromptTokens + prompt) : prompt
                    }
                    if let completion {
                        message.completionTokens = appendToExisting ? (initialCompletionTokens + completion) : completion
                    }

                case .cacheUsage(let cached, _):
                    if let cached, cached >= 0, Self.isAlive(message) {
                        let totalCached = initialCachedTokens + cached
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

            message.latencyMs = appendToExisting ? ((message.latencyMs ?? 0) + totalElapsed) : totalElapsed
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
}
