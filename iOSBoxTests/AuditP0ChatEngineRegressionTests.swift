import Foundation
import SwiftData
import Testing
@testable import iOSBox

private final class AuditRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [LLMChatRequest] = []

    func record(_ request: LLMChatRequest) {
        lock.lock()
        defer { lock.unlock() }
        captured.append(request)
    }

    var requests: [LLMChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        captured.removeAll()
    }
}

private final class AuditSignalFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func signal() {
        lock.lock()
        defer { lock.unlock() }
        signaled = true
    }

    var isSignaled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signaled
    }
}

private final class AuditTurnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

@Suite("Audit P0 ChatEngine Regression Tests", .serialized)
@MainActor
struct AuditP0ChatEngineRegressionTests {
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeLocalProvider(
        name: String = "Local",
        models: [ModelSpec] = [ModelSpec(id: "local-chat", displayName: "Local Chat", supportsVision: false)]
    ) -> ProviderConfig {
        ProviderConfig(
            name: name,
            protocolType: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            isEnabled: true,
            models: models
        )
    }

    private func waitUntilIdle(_ engine: ChatEngine, conversationID: UUID, timeoutMs: Int = 4_000) async {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while engine.isGenerating(in: conversationID) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func appendMessage(
        _ msg: ChatMessage,
        to conversation: Conversation,
        in context: ModelContext,
        parentID: UUID? = nil
    ) {
        msg.parentMessageID = parentID
        msg.conversation = conversation
        conversation.messages.append(msg)
        context.insert(msg)
    }

    // MARK: - 1. Rolling Summary Divider Reset, Branch/Regeneration Anchor Isolation & Ledger Accounting

    @Test("Context divider clears rolling summary and legacy summary JSON decodes cleanly")
    func contextDividerClearsRollingSummaryAndLegacyDecodes() throws {
        let legacyJSON = """
        [
          {
            "conversationID": "11111111-2222-3333-4444-555555555555",
            "summaryText": "- Legacy persisted bullet",
            "coveredMessageCount": 4,
            "lastCoveredMessageID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "updatedAt": 1700000000
          }
        ]
        """
        let decoded = try JSONDecoder().decode([RollingContextSummary].self, from: Data(legacyJSON.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].summarizedUpToMessageID == UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        #expect(decoded[0].contextDividerMessageID == nil)

        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let conv = Conversation(title: "Summary Divider Test")
        context.insert(conv)
        let u1 = ChatMessage(role: .user, content: "Early question", sortIndex: 1)
        let a1 = ChatMessage(role: .assistant, content: "Early answer", sortIndex: 2)
        appendMessage(u1, to: conv, in: context)
        appendMessage(a1, to: conv, in: context)
        try context.save()

        let store = RollingContextSummaryStore.shared
        defer { store.clear(for: conv.id) }
        store.save(RollingContextSummary(
            conversationID: conv.id,
            summaryText: "- Earlier topic facts",
            coveredMessageCount: 2,
            lastCoveredMessageID: a1.id
        ))
        #expect(store.summary(for: conv.id) != nil)

        let engine = ChatEngine { _ in
            AsyncThrowingStream { $0.finish() }
        }
        engine.insertContextDivider(in: conv, context: context)

        #expect(store.summary(for: conv.id) == nil)
        #expect(conv.sortedMessages.last?.assistanceMetadata.isContextDivider == true)
    }

    @Test("Rolling summary records ledger usage and invalidates stale branch, regeneration, and group-mode anchors")
    func rollingSummaryAnchorValidationAndLedgerAccounting() async throws {
        let prefs = AppPreferences.shared
        let wasAutoSummary = prefs.autoRollingSummaryEnabled
        prefs.autoRollingSummaryEnabled = true

        let container = try makeInMemoryContainer()
        let context = container.mainContext

        var pricedSpec = ModelSpec(id: "summary-main", displayName: "Summary Main", supportsVision: false)
        pricedSpec.inputPricePerMillion = 2.0
        pricedSpec.outputPricePerMillion = 8.0
        pricedSpec.priceCurrency = "USD"
        let provider = makeLocalProvider(models: [pricedSpec])
        context.insert(provider)

        let target = provider.makeTarget(for: pricedSpec)
        let conv = Conversation(title: "Anchor Isolation", contextMessageLimit: 2, primaryTarget: target)
        context.insert(conv)

        let store = RollingContextSummaryStore.shared
        defer {
            prefs.autoRollingSummaryEnabled = wasAutoSummary
            store.clear(for: conv.id)
        }

        let u1 = ChatMessage(role: .user, content: "First question", sortIndex: 1)
        let a1 = ChatMessage(role: .assistant, content: "First answer", target: target, sortIndex: 2)
        let u2 = ChatMessage(role: .user, content: "Second question", sortIndex: 3)
        let a2 = ChatMessage(role: .assistant, content: "Second answer", target: target, sortIndex: 4)
        appendMessage(u1, to: conv, in: context, parentID: ConversationTree.virtualRootID)
        appendMessage(a1, to: conv, in: context, parentID: u1.id)
        appendMessage(u2, to: conv, in: context, parentID: a1.id)
        appendMessage(a2, to: conv, in: context, parentID: u2.id)
        conv.activeLeafMessageID = a2.id
        try context.save()

        let recorder = AuditRequestRecorder()
        let engine = ChatEngine { req in
            recorder.record(req)
            return AsyncThrowingStream { continuation in
                if req.systemPrompt.contains("Summarize the earlier conversation turns") {
                    continuation.yield(.contentDelta("- User asked first question and got first answer"))
                    continuation.yield(.usage(promptTokens: 100, completionTokens: 25))
                } else {
                    continuation.yield(.contentDelta("Fresh reply"))
                    continuation.yield(.usage(promptTokens: 40, completionTokens: 10))
                }
                continuation.yield(.done)
                continuation.finish()
            }
        }

        // 1. Trigger background rolling summary and verify RequestRecord ledger accounting
        engine.scheduleRollingSummaryIfNeeded(for: conv, providers: [provider], context: context)
        let summaryDeadline = ContinuousClock.now + .seconds(3)
        while store.summary(for: conv.id) == nil && ContinuousClock.now < summaryDeadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        // Allow summary task defer block to finish saving ledger record
        while engine.activeSummaryTasks[conv.id] != nil && ContinuousClock.now < summaryDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let initialSummary = try #require(store.summary(for: conv.id))
        #expect(initialSummary.summarizedUpToMessageID == a1.id)
        #expect(initialSummary.coveredMessageCount == 2)
        #expect(initialSummary.coveredMessageIDs == [u1.id, a1.id])

        let summaryRecords = try context.fetch(FetchDescriptor<RequestRecord>())
        #expect(summaryRecords.count == 1)
        let ledgerEntry = try #require(summaryRecords.first)
        #expect(ledgerEntry.status == .succeeded)
        #expect(ledgerEntry.promptTokens == 100)
        #expect(ledgerEntry.completionTokens == 25)
        let totalCost = RequestLedger.costs(summaryRecords)["USD"] ?? 0
        #expect(totalCost > 0)

        // 2. Sending on the active branch where [u1, a1] is in the dropped prefix injects the summary
        recorder.reset()
        #expect(engine.sendUserMessage(text: "Third question", attachments: [], in: conv, providers: [provider], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        while engine.activeSummaryTasks[conv.id] != nil && ContinuousClock.now < (ContinuousClock.now + .seconds(2)) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let thirdTurnRequest = try #require(recorder.requests.first { !$0.systemPrompt.contains("Summarize the earlier conversation turns") })
        #expect(thirdTurnRequest.systemPrompt.contains("[Earlier Conversation Rolling Summary"))

        // 3. Switching to a sibling branch at root where the summary anchor is NOT in dropped history must NOT inject stale summary
        let altU1 = ChatMessage(role: .user, content: "Alternate root question", sortIndex: 10)
        let altA1 = ChatMessage(role: .assistant, content: "Alternate root answer", target: target, sortIndex: 11)
        appendMessage(altU1, to: conv, in: context, parentID: ConversationTree.virtualRootID)
        appendMessage(altA1, to: conv, in: context, parentID: altU1.id)
        ConversationTree.switchBranch(to: altA1, in: conv)
        try context.save()

        recorder.reset()
        #expect(engine.sendUserMessage(text: "Follow up on alt branch", attachments: [], in: conv, providers: [provider], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        let altDeadline = ContinuousClock.now + .seconds(2)
        while engine.activeSummaryTasks[conv.id] != nil && ContinuousClock.now < altDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let altBranchRequest = try #require(recorder.requests.first { !$0.systemPrompt.contains("Summarize the earlier conversation turns") })
        #expect(!altBranchRequest.systemPrompt.contains("[Earlier Conversation Rolling Summary"))
        if let postAltSummary = store.summary(for: conv.id) {
            // Stale [u1, a1] summary was evicted; any new background summary after altA2 must belong to [altU1, altA1].
            #expect(postAltSummary.summarizedUpToMessageID == altA1.id)
            #expect(postAltSummary.coveredMessageIDs == [altU1.id, altA1.id])
        }

        // 4. Regenerating an earlier summarized assistant message invalidates the stale summary
        ConversationTree.switchBranch(to: a2, in: conv)
        store.save(RollingContextSummary(
            conversationID: conv.id,
            summaryText: "- Stale summary covering a1",
            coveredMessageCount: 2,
            lastCoveredMessageID: a1.id
        ))
        recorder.reset()
        engine.regenerate(assistantMessage: a1, in: conv, providers: [provider], context: context)
        await waitUntilIdle(engine, conversationID: conv.id)
        let regenSummaryDeadline = ContinuousClock.now + .seconds(2)
        while engine.activeSummaryTasks[conv.id] != nil && ContinuousClock.now < regenSummaryDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let regenRequest = try #require(recorder.requests.first { !$0.systemPrompt.contains("Summarize the earlier conversation turns") })
        #expect(!regenRequest.systemPrompt.contains("- Stale summary covering a1"))
        #expect(store.summary(for: conv.id)?.summaryText != "- Stale summary covering a1")

        // 5. Group mode never injects a private rolling summary
        store.save(RollingContextSummary(
            conversationID: conv.id,
            summaryText: "- Should never leak into group mode",
            coveredMessageCount: 2,
            lastCoveredMessageID: a1.id
        ))
        let member = GroupMember(name: "Alex", title: "Reviewer", avatarEmoji: "🧑‍💻", rolePrompt: "Concise", target: target)
        conv.isGroupMode = true
        conv.groupMembers = [member]
        recorder.reset()
        #expect(engine.sendUserMessage(text: "@Alex Thoughts?", attachments: [], in: conv, providers: [provider], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        let groupReq = try #require(recorder.requests.first)
        #expect(!groupReq.systemPrompt.contains("Should never leak into group mode"))
    }

    // MARK: - 2. continueGeneration Local Knowledge Evidence Preservation

    @Test("continueGeneration preserves existing knowledgeEvidence and never queries RAG with synthetic prompt")
    func continueGenerationPreservesKnowledgeEvidence() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let provider = makeLocalProvider()
        context.insert(provider)
        let target = provider.makeTarget(for: provider.models[0])

        let markdown = """
        # 核心协议
        分布式状态机的一致性写入目标延迟为 9ms。

        # Distractor Section
        Continue writing directly introductory remarks distractor passage that must never be matched.
        """
        let book = try BookLibrary.store(
            PreparedBook(BookImporter.parse(Data(markdown.utf8), filename: "architecture.md")),
            in: context
        )
        let bookID = book.id
        defer {
            Task { await ProjectKnowledgeSearch.shared.invalidate(volumeID: bookID) }
        }

        let conv = Conversation(title: "RAG Continuation", primaryTarget: target)
        conv.assistanceSettings.knowledgeVolumeIDs = [bookID]
        context.insert(conv)
        try context.save()

        let turnCounter = AuditTurnCounter()
        let recorder = AuditRequestRecorder()
        let engine = ChatEngine { req in
            recorder.record(req)
            let currentTurn = turnCounter.next()
            return AsyncThrowingStream { continuation in
                if currentTurn == 1 {
                    continuation.yield(.contentDelta("一致性写入目标延迟"))
                    continuation.yield(.finished(.length))
                } else {
                    continuation.yield(.contentDelta("为 9ms。"))
                    continuation.yield(.done)
                }
                continuation.finish()
            }
        }

        // Initial turn populates knowledgeEvidence from user's real question
        #expect(engine.sendUserMessage(
            text: "一致性写入目标延迟是多少？",
            attachments: [],
            in: conv,
            providers: [provider],
            context: context
        ) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)

        let reply = try #require(conv.sortedMessages.last { $0.role == .assistant })
        #expect(reply.finishReasonValue == .length)
        let originalEvidence = try #require(reply.assistanceMetadata.knowledgeEvidence)
        #expect(originalEvidence.query == "一致性写入目标延迟是多少？")
        #expect(originalEvidence.passages.contains { $0.excerpt.contains("9ms") })
        #expect(!originalEvidence.passages.contains { $0.excerpt.contains("distractor") })

        // Evict in-memory cache so we can verify continueGeneration does not re-query RAG when evidence exists
        await ProjectKnowledgeSearch.shared.evictAllCachedChunks()
        #expect(!ProjectKnowledgeSearch.shared.isCached(book.id))

        engine.continueGeneration(assistantMessage: reply, in: conv, providers: [provider], context: context)
        await waitUntilIdle(engine, conversationID: conv.id)

        #expect(reply.content == "一致性写入目标延迟为 9ms。")
        #expect(reply.assistanceMetadata.knowledgeEvidence == originalEvidence)
        #expect(!ProjectKnowledgeSearch.shared.isCached(book.id))

        // Also verify that if a truncated message had nil knowledgeEvidence, continuation uses the original user question, not the synthetic cue
        let manualUser = ChatMessage(role: .user, content: "一致性写入目标延迟是多少？", sortIndex: 10)
        let manualReply = ChatMessage(role: .assistant, content: "部分回答：", target: target, sortIndex: 11)
        manualReply.finishReason = LLMFinishReason.length.rawValue
        appendMessage(manualUser, to: conv, in: context)
        appendMessage(manualReply, to: conv, in: context)
        try context.save()

        engine.continueGeneration(assistantMessage: manualReply, in: conv, providers: [provider], context: context)
        await waitUntilIdle(engine, conversationID: conv.id)

        if let hydratedEvidence = manualReply.assistanceMetadata.knowledgeEvidence {
            #expect(hydratedEvidence.query == "一致性写入目标延迟是多少？")
            #expect(!hydratedEvidence.query.contains("Continue writing directly"))
        }
    }

    // MARK: - 3. Extended Error Fallback, Automatic Routing Fallbacks & Group English Retry/Continue

    @Test("Extended error fallback flag, automaticRouting fallbackTargets, and group preferEnglish propagation")
    func extendedFallbackAutomaticRoutingAndGroupEnglish() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let primaryProvider = makeLocalProvider(
            name: "Primary",
            models: [ModelSpec(id: "primary-text", displayName: "Primary Text", supportsVision: false)]
        )
        let codeProvider = makeLocalProvider(
            name: "Code",
            models: [ModelSpec(id: "code-specialist", displayName: "Code Specialist", supportsVision: false)]
        )
        let visionProvider = makeLocalProvider(
            name: "Vision",
            models: [ModelSpec(id: "vision-specialist", displayName: "Vision Specialist", supportsVision: true)]
        )
        let backupTextProvider = makeLocalProvider(
            name: "BackupText",
            models: [ModelSpec(id: "backup-text", displayName: "Backup Text", supportsVision: false)]
        )
        let backupVisionProvider = makeLocalProvider(
            name: "BackupVision",
            models: [ModelSpec(id: "backup-vision", displayName: "Backup Vision", supportsVision: true)]
        )
        let providers = [primaryProvider, codeProvider, visionProvider, backupTextProvider, backupVisionProvider]
        providers.forEach { context.insert($0) }

        let primaryTarget = primaryProvider.makeTarget(for: primaryProvider.models[0])
        let codeTarget = codeProvider.makeTarget(for: codeProvider.models[0])
        let visionTarget = visionProvider.makeTarget(for: visionProvider.models[0])
        let backupTextTarget = backupTextProvider.makeTarget(for: backupTextProvider.models[0])
        let backupVisionTarget = backupVisionProvider.makeTarget(for: backupVisionProvider.models[0])

        let conv = Conversation(title: "Fallback & Routing", primaryTarget: primaryTarget)
        conv.assistanceSettings.fallbackEnabled = true
        conv.assistanceSettings.fallbackTargets = [backupTextTarget, backupVisionTarget]
        conv.assistanceSettings.fallbackOnExtendedErrors = false
        context.insert(conv)
        try context.save()

        let recorder = AuditRequestRecorder()
        let engine = ChatEngine { req in
            recorder.record(req)
            if req.modelID == "primary-text" {
                return AsyncThrowingStream { $0.finish(throwing: LLMError.httpError(500, "Internal Server Error")) }
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(.contentDelta("Served by \(req.modelID)"))
                continuation.yield(.done)
                continuation.finish()
            }
        }

        // Part A1: HTTP 500 does NOT fallback when fallbackOnExtendedErrors == false
        #expect(engine.sendUserMessage(text: "Test 500 off", attachments: [], in: conv, providers: providers, context: context) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        #expect(recorder.requests.map(\.modelID) == ["primary-text"])
        #expect(conv.sortedMessages.last?.errorMessage != nil)

        // Part A2: HTTP 500 DOES fallback when fallbackOnExtendedErrors == true
        conv.assistanceSettings.fallbackOnExtendedErrors = true
        recorder.reset()
        #expect(engine.sendUserMessage(text: "Test 500 on", attachments: [], in: conv, providers: providers, context: context) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        #expect(recorder.requests.map(\.modelID) == ["primary-text", "backup-text"])
        let recoveredReply = try #require(conv.sortedMessages.last)
        #expect(recoveredReply.content == "Served by backup-text")
        #expect(recoveredReply.assistanceMetadata.fallbackNotices.count == 1)

        // Part B: automaticRouting falls back to fallbackTargets when primary & routed models are disabled
        conv.assistanceSettings.automaticRouting = true
        conv.assistanceSettings.codeTarget = codeTarget
        conv.assistanceSettings.imageTarget = visionTarget
        primaryProvider.isEnabled = false
        codeProvider.isEnabled = false
        visionProvider.isEnabled = false

        recorder.reset()
        #expect(engine.sendUserMessage(
            text: "```swift\nlet value = 42\n```",
            attachments: [],
            in: conv,
            providers: providers,
            context: context
        ) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        #expect(conv.sortedMessages.last?.content == "Served by backup-text")

        recorder.reset()
        let img = MessageAttachment(kind: .image, fileName: "chart.png", mimeType: "image/png", dataBase64: "eA==", byteSize: 2)
        #expect(engine.sendUserMessage(
            text: "Describe this image",
            attachments: [img],
            in: conv,
            providers: providers,
            context: context
        ) == .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        #expect(conv.sortedMessages.last?.content == "Served by backup-vision")

        // Part C: Group chat regenerate & continueGeneration preserve preferEnglish formatting
        let groupConv = Conversation(title: "Architecture Room", primaryTarget: backupTextTarget)
        let member = GroupMember(
            name: "Grace",
            title: "Architect",
            avatarEmoji: "🧭",
            rolePrompt: "Direct systems engineering advice",
            target: backupTextTarget
        )
        groupConv.isGroupMode = true
        groupConv.groupMembers = [member]
        context.insert(groupConv)

        let engUser = ChatMessage(role: .user, content: "Should we migrate our service to Swift 6 actors?", sortIndex: 1)
        let engReply = ChatMessage(role: .assistant, content: "Yes, isolate stateful coordinators", target: backupTextTarget, sortIndex: 2)
        var memberMeta = AssistanceMetadata()
        memberMeta.groupMemberID = member.id
        memberMeta.groupMemberName = member.name
        memberMeta.groupMemberTitle = member.title
        memberMeta.groupMemberEmoji = member.avatarEmoji
        engReply.assistanceMetadata = memberMeta
        appendMessage(engUser, to: groupConv, in: context)
        appendMessage(engReply, to: groupConv, in: context)
        try context.save()

        recorder.reset()
        engine.regenerate(assistantMessage: engReply, in: groupConv, providers: providers, context: context)
        await waitUntilIdle(engine, conversationID: groupConv.id)
        let regenGroupReq = try #require(recorder.requests.first)
        #expect(regenGroupReq.messages.first?.content.contains("[Host]:") == true)
        #expect(regenGroupReq.messages.first?.content.contains("[群主]:") == false)

        engReply.finishReason = LLMFinishReason.length.rawValue
        recorder.reset()
        engine.continueGeneration(assistantMessage: engReply, in: groupConv, providers: providers, context: context)
        await waitUntilIdle(engine, conversationID: groupConv.id)
        let contGroupReq = try #require(recorder.requests.first)
        #expect(contGroupReq.messages.first?.content.contains("[Host]:") == true)
        #expect(contGroupReq.messages.first?.content.contains("[群主]:") == false)
    }

    // MARK: - 4. Arena Context Selection Branch Re-parenting

    @Test("Switching historical Arena primary candidate re-parents downstream child messages on active branch")
    func arenaSelectContextReplyReparentsDownstreamChildren() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let conv = Conversation(title: "Arena Tree Branch", isArenaMode: true)
        context.insert(conv)

        let groupID = UUID()
        let u1 = ChatMessage(role: .user, content: "Compare two architectures", sortIndex: 1)
        let replyA = ChatMessage(
            role: .assistant,
            content: "Architecture A: Monolith",
            comparisonGroupID: groupID,
            isSelectedInGroup: true,
            sortIndex: 2
        )
        let replyB = ChatMessage(
            role: .assistant,
            content: "Architecture B: Modular services",
            comparisonGroupID: groupID,
            isSelectedInGroup: false,
            sortIndex: 3
        )
        let u2 = ChatMessage(role: .user, content: "How should we deploy that?", sortIndex: 4)
        let a2 = ChatMessage(role: .assistant, content: "Deploy with rolling blue-green", sortIndex: 5)

        appendMessage(u1, to: conv, in: context, parentID: ConversationTree.virtualRootID)
        appendMessage(replyA, to: conv, in: context, parentID: u1.id)
        appendMessage(replyB, to: conv, in: context, parentID: u1.id)
        appendMessage(u2, to: conv, in: context, parentID: replyA.id)
        appendMessage(a2, to: conv, in: context, parentID: u2.id)
        conv.activeLeafMessageID = a2.id
        try context.save()

        let engine = ChatEngine { _ in AsyncThrowingStream { $0.finish() } }
        try engine.selectContextReply(replyB, in: conv, context: context)

        #expect(replyB.isSelectedInGroup)
        #expect(!replyA.isSelectedInGroup)
        #expect(u2.parentMessageID == replyB.id)

        // Switching branch from root must traverse through replyB down to a2 without orphaning downstream turns
        ConversationTree.switchBranch(to: u1, in: conv)
        #expect(conv.activeLeafMessageID == a2.id)

        let active = ConversationTree.activeMessages(in: conv)
        let activeIDs: [UUID] = active.map(\.id)
        let expectedIDs: [UUID] = [u1.id, replyA.id, replyB.id, u2.id, a2.id]
        #expect(activeIDs == expectedIDs)

        let promptHistory = engine.buildPromptHistory(messages: active, limit: 0)
        #expect(promptHistory.map(\.content) == [
            "Compare two architectures",
            "Architecture B: Modular services",
            "How should we deploy that?",
            "Deploy with rolling blue-green"
        ])
    }

    // MARK: - 5. Group Relay Multi-Bubble Stop / Cancellation Data Preservation

    @Test("Stopping group relay during multi-bubble split delay preserves all generated segments")
    func groupRelayMultiBubbleCancellationPreservesGeneratedText() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let provider = makeLocalProvider(models: [
            ModelSpec(id: "member-a", displayName: "Member A"),
            ModelSpec(id: "member-b", displayName: "Member B")
        ])
        context.insert(provider)

        let targetA = provider.makeTarget(for: provider.models[0])
        let targetB = provider.makeTarget(for: provider.models[1])
        let memberA = GroupMember(name: "林晓", title: "产品", avatarEmoji: "👩‍💼", rolePrompt: "犀利", target: targetA)
        let memberB = GroupMember(name: "老王", title: "架构", avatarEmoji: "🧑‍💻", rolePrompt: "稳健", target: targetB)

        let conv = Conversation(title: "Group Split Cancel", primaryTarget: targetA)
        var settings = AssistanceSettings()
        settings.isGroupMode = true
        settings.groupMembers = [memberA, memberB]
        settings.groupSpeakingMode = .smartRelay
        settings.groupSpeechStyle = .naturalShort
        settings.groupSplitShortBubbles = true
        conv.assistanceSettings = settings
        context.insert(conv)
        try context.save()

        let streamFinished = AuditSignalFlag()
        let part1 = "第一段核心判断非常明确，切入点很准！"
        let part2 = "第二段关键执行细节也已经生成完毕，绝不能在停止时丢失！ @群主 你觉得呢？"

        let engine = ChatEngine { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.contentDelta("\(part1)\n\n\(part2)"))
                continuation.yield(.contentDelta("[[GROUP_META: next=HOST | intent=probe]]"))
                continuation.yield(.done)
                continuation.finish()
                streamFinished.signal()
            }
        }

        #expect(engine.sendUserMessage(
            text: "@林晓 评估一下这个方案",
            attachments: [],
            in: conv,
            providers: [provider],
            context: context
        ) == .sent)

        let waitStream = ContinuousClock.now + .seconds(2)
        while !streamFinished.isSignaled && ContinuousClock.now < waitStream {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Wait briefly so the main actor enters the 200ms inter-bubble sleep after truncating to part 1
        try? await Task.sleep(for: .milliseconds(40))
        await engine.stopGenerationAndWait(for: conv.id)

        let assistantBubbles = ConversationTree.activeMessages(in: conv).filter { $0.role == .assistant }
        #expect(!assistantBubbles.isEmpty)
        let combinedText = assistantBubbles.map(\.content).joined(separator: "\n\n")
        #expect(combinedText.contains(part1))
        #expect(combinedText.contains(part2))
        #expect(assistantBubbles.last?.assistanceMetadata.groupAskedHost == true)
    }
}
