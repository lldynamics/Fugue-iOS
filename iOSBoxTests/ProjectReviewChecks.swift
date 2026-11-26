import XCTest
import SwiftData
@testable import iOSBox

@MainActor
final class ProjectReviewChecks: XCTestCase {
    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func provider() -> ProviderConfig {
        ProviderConfig(name: "Offline fixture", protocolType: .openAICompatible,
                       baseURL: "http://localhost/v1", models: [ModelSpec(id: "demo")])
    }

    private func engine() -> ChatEngine {
        ChatEngine(stream: { _ in AsyncThrowingStream { continuation in
            continuation.yield(.contentDelta("Demo"))
            continuation.yield(.usage(promptTokens: 18, completionTokens: 2))
            continuation.yield(.done)
            continuation.finish()
        } })
    }

    private func insert(_ messages: [ChatMessage], in chat: Conversation, context: ModelContext) throws {
        for message in messages {
            context.insert(message)
            message.conversation = chat
        }
        try context.save()
    }

    private func waitForCompletion(_ engine: ChatEngine, in chat: Conversation) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while engine.isGenerating(in: chat.id) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(engine.isGenerating(in: chat.id))
    }

    func testGroupHonorsFourSourceMessages() throws {
        let p = provider()
        let member = GroupMember(name: "A", rolePrompt: "", target: p.makeTarget(for: p.models[0]))
        let messages = (1...30).map { ChatMessage(role: .user, content: "entry[\($0)]", sortIndex: $0) }
        let prompt = GroupDiscussionCoordinator.buildPromptHistory(messages: messages, for: member, limit: 4)
        let combined = prompt.map(\.content).joined(separator: "\n")
        let included = (1...30).filter { combined.contains("entry[\($0)]") }
        XCTAssertEqual(included, [27, 28, 29, 30])
    }

    func testCompletedShareIsRetainedOnVolatileStore() throws {
        let database = try container()
        let context = database.mainContext
        let p = provider()
        let target = p.makeTarget(for: p.models[0])
        var receipt = ExternalRunReceipt(target: target, title: "Fixture", prompt: "Question")
        receipt.answer = "Answer"
        receipt.isRunning = false
        let record = RequestRecord(target: target, spec: p.models[0], conversationID: receipt.id,
                                   messageID: receipt.answerMessageID, kind: .sharedReading)
        record.finish(.succeeded, elapsedMs: 5)
        receipt.records = [record.snapshot]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = SystemEntryStore(directory: path)
        try store.save(receipt)
        XCTAssertEqual(try store.receipts().count, 1)
        try ExternalReceiptImporter.drain(store, context: context)
        XCTAssertEqual(try store.receipts().count, 1, "Volatile recovery must leave a durable receipt for the next launch")
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let disk = ModelConfiguration(schema: schema, url: path.appendingPathComponent("recovered.store"), cloudKitDatabase: .none)
        let recovered = try ModelContainer(for: schema, configurations: disk)
        try ExternalReceiptImporter.drain(store, context: recovered.mainContext)
        XCTAssertTrue(try store.receipts().isEmpty)
        XCTAssertEqual(try recovered.mainContext.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(try recovered.mainContext.fetchCount(FetchDescriptor<RequestRecord>()), 1)
    }

    func testRecoveryContainerStartsAndDeclinesChatCommitsAndReceiptAcknowledgement() throws {
        let database = try PersistenceController.makeRecoveryContainer(schema: Schema(versionedSchema: CurrentSchema.self))
        let ctx = database.mainContext
        let p = provider()
        let target = p.makeTarget(for: p.models[0])
        let chat = Conversation(primaryTarget: target)
        ctx.insert(p)
        ctx.insert(chat)
        try ctx.save()
        let generator = ChatEngine { _ in
            XCTFail("Recovery mode must not transmit a message it cannot retain")
            return AsyncThrowingStream { $0.finish() }
        }
        XCTAssertEqual(generator.sendUserMessage(text: "Keep my draft", attachments: [], in: chat, providers: [p], context: ctx), .saveFailed)
        XCTAssertTrue(chat.messages.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemEntryStore(directory: directory)
        var receipt = ExternalRunReceipt(target: target, title: "Saved share", prompt: "Reading")
        receipt.records = [RequestRecord(target: target, spec: p.models[0], conversationID: receipt.id,
                                         messageID: receipt.answerMessageID, kind: .sharedReading).snapshot]
        receipt.isRunning = false
        try store.save(receipt)
        try ExternalReceiptImporter.drain(store, context: ctx)
        XCTAssertEqual(try store.receipts().map { $0.1.id }, [receipt.id])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Conversation>()), 1)
    }

    func testGeneratedTitleCreatesUsageRecord() async throws {
        let database = try container()
        let context = database.mainContext
        let p = provider()
        let chat = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        p.models[0].inputPricePerMillion = 1
        p.models[0].outputPricePerMillion = 3
        p.models[0].priceCurrency = "USD"
        context.insert(p)
        context.insert(chat)
        try insert([ChatMessage(role: .user, content: "A question"), ChatMessage(role: .assistant, content: "An answer")],
                   in: chat, context: context)
        let title = await engine().generateSmartTitle(for: chat, providers: [p], context: context)
        XCTAssertEqual(title, "Demo")
        let records = try context.fetch(FetchDescriptor<RequestRecord>())
        XCTAssertEqual(records.count, 1, "One model request returned usage")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.kind, .titleGeneration)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.promptTokens, 18)
        XCTAssertEqual(record.completionTokens, 2)
        XCTAssertEqual(try XCTUnwrap(record.estimatedCost), 0.000024, accuracy: 1e-10)
        XCTAssertEqual(chat.messages.count, 2)
    }

    func testAutoTitleTracksRetryWithoutOverwritingTheAnswerRecord() async throws {
        let database = try container()
        let ctx = database.mainContext
        let p = provider()
        let chat = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        chat.assistanceSettings.autoGenerateTitle = true
        ctx.insert(p)
        ctx.insert(chat)
        let generator = ChatEngine { request in
            AsyncThrowingStream { stream in
                let title = request.maxOutputTokens == 48
                if title {
                    stream.yield(.retrying(httpStatus: 400))
                    stream.yield(.nonStreamingResponse)
                    stream.yield(.cacheUsage(cachedTokens: 3, cacheWriteTokens: nil))
                }
                stream.yield(.contentDelta(title ? "Topic" : "Answer"))
                stream.yield(.usage(promptTokens: 10, completionTokens: 2))
                stream.yield(.done)
                stream.finish()
            }
        }
        XCTAssertEqual(generator.sendUserMessage(text: "Question", attachments: [], in: chat, providers: [p], context: ctx), .sent)
        try await waitForCompletion(generator, in: chat)
        // Title generation runs independently so the composer can accept the next turn.
        let deadline = ContinuousClock.now + .seconds(3)
        while chat.title != "Topic" && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let records = try ctx.fetch(FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.attempt)]))
        let titles = records.filter { $0.kind == .titleGeneration }
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(titles.map(\.status), [.failed, .succeeded])
        XCTAssertEqual(titles.map(\.attempt), [1, 2])
        XCTAssertEqual(titles.first?.operationID, titles.last?.operationID)
        XCTAssertEqual(titles.first?.httpStatus, 400)
        XCTAssertEqual(titles.last?.cachedTokens, 3)
        XCTAssertEqual(titles.last?.isStreamed, false)
        XCTAssertEqual(chat.title, "Topic")
        XCTAssertEqual(chat.sortedMessages.last?.latestRequest?.kind, .answer)
    }

    func testPrivateEndpointBackupAndRestore() throws {
        let database = try container()
        let ctx = database.mainContext
        let p = provider()
        ctx.insert(p)
        let chat = Conversation()
        ctx.insert(chat)
        let answer = ChatMessage(role: .assistant, content: "Partial answer")
        answer.errorMessage = "HTTP 403: sample-private-value"
        var meta = AssistanceMetadata()
        meta.toolCalls = [.init(id: "1", name: "read_webpage", argumentsSummary: "fixture",
                                resultSummary: "sample-private-value", succeeded: false)]
        answer.assistanceMetadata = meta
        try insert([answer], in: chat, context: ctx)
        p.customHeaders = [
            CustomHeader(key: "Ocp-Apim-Subscription-Key", value: "sample-private-value"),
            CustomHeader(key: "Authorization", value: "sample-private-value"),
            CustomHeader(key: "X-Trace", value: "keep-this")
        ]
        for address in ["https://sample-private-value@example.com/v1", "https://example.com/v1?k=sample-private-value",
                        "https://example.com/sample-private-value/v1", "https://example.com/v1#sample-private-value"] {
            p.baseURL = address
            try ctx.save()
            let archive = try BackupService.makeArchive(context: ctx)
            let data = try BackupService.encode(archive)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sample-private-value"))
            XCTAssertEqual(archive.providers.first?.baseURL, "")
            XCTAssertEqual(archive.providers.first?.customHeaders.map(\.isSecret), [true, true, false])
            let recovery = try container()
            _ = try BackupService.apply(BackupService.decode(data), to: recovery.mainContext)
            let restored = try XCTUnwrap(recovery.mainContext.fetch(FetchDescriptor<ProviderConfig>()).first)
            XCTAssertFalse(restored.isEnabled)
            var request = URLRequest(url: URL(string: "https://example.com/v1")!)
            request.setValue("Bearer new-key", forHTTPHeaderField: "Authorization")
            LLMClient.applyCustomHeaders(restored.resolvedCustomHeaders, to: &request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "keep-this")
            _ = try BackupService.apply(.full(archive), to: ctx)
            XCTAssertEqual(p.baseURL, address)
            XCTAssertTrue(p.isEnabled)
        }
        p.baseURL = "http://localhost:11434/api/v1#"
        XCTAssertEqual(try BackupService.makeArchive(context: ctx).providers.first?.baseURL, p.baseURL)
        let undo = try BackupService.clearMessages(in: chat, context: ctx)
        XCTAssertEqual(undo.messages.first?.errorMessage, "HTTP 403: sample-private-value")
    }

    func testHistoryEstimateRespondsToEditsAttachmentsAndContextBoundaries() throws {
        let database = try container()
        let ctx = database.mainContext
        let chat = Conversation()
        ctx.insert(chat)
        let old = ChatMessage(role: .user, content: "a", sortIndex: 1)
        let recent = ChatMessage(role: .assistant, content: "b", sortIndex: 2)
        try insert([old, recent], in: chat, context: ctx)
        func estimate() -> Int {
            TokenEstimator.estimateUpcomingInput(conversation: chat, providers: [], draftText: "next",
                                                 attachments: [], quotedText: nil, target: nil).inputTokens
        }
        let original = estimate()
        XCTAssertEqual(estimate(), original)
        recent.content = "字"
        XCTAssertEqual(estimate(), original + 1)
        recent.attachments = [MessageAttachment(kind: .image, fileName: "sample", mimeType: "image/png",
                                                dataBase64: "AA==", extractedText: nil, byteSize: 1)]
        XCTAssertEqual(estimate(), original + 851)
        recent.assistanceMetadata.isExcludedFromContext = true
        XCTAssertEqual(estimate(), original - 5)
        chat.contextMessageLimit = 1
        XCTAssertEqual(estimate(), TokenEstimator.estimateTokens(for: "next") + 4)
        chat.contextMessageLimit = 20
        recent.assistanceMetadata.isExcludedFromContext = false
        let divider = ChatMessage(role: .system, content: "", sortIndex: 3)
        divider.assistanceMetadata.isContextDivider = true
        try insert([divider], in: chat, context: ctx)
        XCTAssertEqual(estimate(), TokenEstimator.estimateTokens(for: "next") + 4)
    }

    func testShareRevocationRemovesOldConnectionWhenManifestCannotBeWritten() throws {
        let p = provider()
        let revoked = SharedModelEntry(target: p.makeTarget(for: p.models[0]), spec: p.models[0], connectionID: UUID())
        let kept = SharedModelEntry(target: p.makeTarget(for: p.models[0]), spec: p.models[0], connectionID: UUID())
        var deleted: [UUID] = []
        XCTAssertThrowsError(try SystemIntegration.revoke([revoked, revoked], keeping: [kept], save: { retained in
            XCTAssertEqual(retained, [kept])
            throw SystemEntryError.storage
        }, delete: { deleted.append($0) }))
        XCTAssertEqual(deleted, [revoked.connectionID])
    }

    func testHistoricalArenaSummaryIsGroupedWithAnswers() async throws {
        let database = try container()
        let context = database.mainContext
        let p = provider()
        let target = p.makeTarget(for: p.models[0])
        let chat = Conversation(primaryTarget: target)
        context.insert(p)
        context.insert(chat)
        let gid = UUID()
        let start = Date(timeIntervalSince1970: 100)
        try insert([
            ChatMessage(role: .user, content: "First question", sortIndex: 1, createdAt: start),
            ChatMessage(role: .assistant, content: "First candidate", target: target, comparisonGroupID: gid,
                        sortIndex: 2, createdAt: start.addingTimeInterval(1)),
            ChatMessage(role: .assistant, content: "Second candidate", target: target, comparisonGroupID: gid,
                        isSelectedInGroup: false, sortIndex: 3, createdAt: start.addingTimeInterval(2)),
            ChatMessage(role: .user, content: "Later question", sortIndex: 4, createdAt: start.addingTimeInterval(3)),
            ChatMessage(role: .assistant, content: "Later answer", target: target, sortIndex: 5, createdAt: start.addingTimeInterval(4))
        ], in: chat, context: context)
        let generator = engine()
        XCTAssertEqual(generator.synthesize(groupID: gid, target: target, in: chat, providers: [p], context: context), .started)
        try await waitForCompletion(generator, in: chat)
        let visible = ConversationTree.activeMessages(in: chat)
        XCTAssertEqual(visible.enumerated().compactMap { $0.element.comparisonGroupID == gid ? $0.offset : nil },
                       [1, 2, 3], "A timeline entry collects only adjacent group members")
    }

    func testSendReportsUnwritableHistory() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.store")
        do {
            let config = ModelConfiguration(schema: schema, url: path, cloudKitDatabase: .none)
            let writable = try ModelContainer(for: schema, configurations: config)
            let p = provider()
            writable.mainContext.insert(p)
            writable.mainContext.insert(Conversation(primaryTarget: p.makeTarget(for: p.models[0])))
            try writable.mainContext.save()
        }
        let config = ModelConfiguration(schema: schema, url: path, allowsSave: false, cloudKitDatabase: .none)
        let readOnly = try ModelContainer(for: schema, configurations: config)
        let ctx = readOnly.mainContext
        let p = try XCTUnwrap(ctx.fetch(FetchDescriptor<ProviderConfig>()).first)
        let chat = try XCTUnwrap(ctx.fetch(FetchDescriptor<Conversation>()).first)
        let generator = ChatEngine { _ in
            XCTFail("A rejected write must not start a model request")
            return AsyncThrowingStream { $0.finish() }
        }
        let outcome = generator.sendUserMessage(text: "Fixture message", attachments: [], in: chat, providers: [p], context: ctx)
        XCTAssertEqual(outcome, .saveFailed)
        XCTAssertFalse(generator.isGenerating(in: chat.id))
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<ChatMessage>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RequestRecord>()), 0)
    }

    func testFailedEditPreservesOriginalHistoryAndCanBeRetried() async throws {
        let database = try container()
        let ctx = database.mainContext
        let p = provider()
        let chat = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        ctx.insert(chat)
        ctx.insert(p)
        let original = ChatMessage(role: .user, content: "Original", sortIndex: 1)
        let reply = ChatMessage(role: .assistant, content: "Reply", sortIndex: 2)
        try insert([original, reply], in: chat, context: ctx)
        chat.folderTag = "Keep preexisting edit"
        var canSave = false
        let generator = ChatEngine(search: { _ in throw SearchError.invalidQuery }, persistNewTurn: { context in
            guard canSave else { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        }, stream: { _ in AsyncThrowingStream { $0.yield(.contentDelta("New reply")); $0.finish() } })
        let failed = await generator.editUserMessageAndResend(userMessage: original, newText: "New", in: chat, providers: [p], context: ctx)
        XCTAssertEqual(failed, .saveFailed)
        XCTAssertFalse(generator.isGenerating(in: chat.id))
        XCTAssertEqual(chat.sortedMessages.map(\.id), [original.id, reply.id])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ChatMessage>()).count, 2)
        XCTAssertEqual(chat.folderTag, "Keep preexisting edit")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RequestRecord>()), 0)
        canSave = true
        let retried = await generator.editUserMessageAndResend(userMessage: original, newText: "New", in: chat, providers: [p], context: ctx)
        XCTAssertEqual(retried, .sent)
        try await waitForCompletion(generator, in: chat)
        XCTAssertEqual(chat.sortedMessages.map(\.content), ["New", "New reply"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RequestRecord>()), 1)
    }

    func testOnlyDeclaredToolsMayRun() async throws {
        let database = try container()
        let context = database.mainContext
        let p = provider()
        context.insert(p)
        let chat = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        context.insert(chat)
        let generator = ChatEngine { request in
            XCTAssertTrue(request.tools.isEmpty)
            return AsyncThrowingStream { stream in
                stream.yield(.toolCall(LLMToolCall(id: "fixture", name: "propose_memory", argumentsJSON: "{}")))
                stream.finish()
            }
        }
        XCTAssertEqual(generator.sendUserMessage(text: "Hello", attachments: [], in: chat, providers: [p], context: context), .sent)
        try await waitForCompletion(generator, in: chat)
        let reply = try XCTUnwrap(chat.sortedMessages.last)
        XCTAssertEqual(reply.errorMessage, LLMError.unavailableTool.localizedDescription)
        XCTAssertEqual(reply.latestRequest?.status, .failed)
        XCTAssertTrue(reply.assistanceMetadata.toolCalls.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestRecord>()), 1)
    }

    func testRevokingToolsOrProviderWhileAnAnswerIsStreamingStopsToolDispatch() async throws {
        for disableProvider in [false, true] {
            let database = try container()
            let ctx = database.mainContext
            let p = provider()
            let chat = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
            chat.assistanceSettings.enableAgentTools = true
            ctx.insert(p)
            ctx.insert(chat)
            let started = expectation(description: "Initial request")
            let (events, output) = AsyncThrowingStream<LLMStreamEvent, Error>.makeStream()
            let generator = ChatEngine { request in
                XCTAssertTrue(request.tools.contains { $0.name == "propose_memory" })
                started.fulfill()
                return events
            }
            XCTAssertEqual(generator.sendUserMessage(text: "Question", attachments: [], in: chat, providers: [p], context: ctx), .sent)
            await fulfillment(of: [started], timeout: 10)
            if disableProvider { p.isEnabled = false } else { chat.assistanceSettings.enableAgentTools = false }
            output.yield(.toolCall(LLMToolCall(id: "fixture", name: "propose_memory", argumentsJSON: #"{"fact":"sample"}"#)))
            output.finish()
            try await waitForCompletion(generator, in: chat)
            let answer = try XCTUnwrap(chat.sortedMessages.last)
            XCTAssertEqual(answer.errorMessage, (disableProvider ? LLMError.unavailableModel : .unavailableTool).localizedDescription)
            XCTAssertTrue(answer.assistanceMetadata.toolCalls.isEmpty)
            XCTAssertTrue(answer.assistanceMetadata.proposedMemories.isEmpty)
            XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RequestRecord>()), 1)
        }
    }

    func testDisabledHistoricalTargetsPreserveAnswers() throws {
        let database = try container()
        let context = database.mainContext
        let p = provider()
        context.insert(p)
        let target = p.makeTarget(for: p.models[0])
        let chat = Conversation(primaryTarget: target)
        context.insert(chat)
        let gid = UUID()
        let answer = ChatMessage(role: .assistant, content: "Original", target: target, comparisonGroupID: gid)
        let other = ChatMessage(role: .assistant, content: "Other", target: target, comparisonGroupID: gid)
        try insert([ChatMessage(role: .user, content: "Question"), answer, other], in: chat, context: context)
        let generator = engine()
        let validate = p.transmissionCheck(for: target.modelID)
        XCTAssertNoThrow(try validate())
        for disableProvider in [true, false] {
            p.isEnabled = !disableProvider
            p.models[0].isEnabled = disableProvider
            XCTAssertThrowsError(try validate())
            XCTAssertNil(generator.replyTarget(answer, in: chat, providers: [p]))
            generator.regenerate(assistantMessage: answer, overrideTarget: target, in: chat, providers: [p], context: context)
            generator.continueGeneration(assistantMessage: answer, in: chat, providers: [p], context: context)
            XCTAssertFalse(generator.isGenerating(in: chat.id))
            XCTAssertEqual(answer.content, "Original")
            XCTAssertEqual(chat.messages.count, 3)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestRecord>()), 0)
        }
    }
}
