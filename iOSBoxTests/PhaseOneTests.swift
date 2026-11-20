import XCTest
import SwiftData
@testable import iOSBox

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LLMChatRequest] = []
    func append(_ request: LLMChatRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
    var requests: [LLMChatRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Exercises real adapter HTTP parsing while keeping all traffic inside URLProtocol.
private final class MeteringURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]
    static func count(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path, default: 0]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        Self.counts[url.path, default: 0] += 1
        let count = Self.counts[url.path]!
        Self.lock.unlock()
        let retry = url.path.contains("retry") && count == 1
        let json = url.path.contains("json")
        let body: String
        if retry {
            body = #"{"error":{"message":"unsupported stream_options"}}"#
        } else if json {
            body = #"{"choices":[{"message":{"content":"JSON answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}"#
        } else {
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"SSE answer\"}}]}\n\ndata: [DONE]\n\n"
        }
        let response = HTTPURLResponse(url: url, statusCode: retry ? 400 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": retry || json ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class PhaseOneTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    override func tearDown() async throws { context = nil; container = nil }

    private func provider() -> ProviderConfig {
        var spec = ModelSpec(id: "test", supportsVision: false)
        spec.inputPricePerMillion = 2
        spec.outputPricePerMillion = 8
        spec.priceCurrency = "USD"
        let p = ProviderConfig(name: "Fixture", protocolType: .openAICompatible,
                               baseURL: "http://localhost:12345/v1", models: [spec])
        context.insert(p)
        return p
    }

    private func conversation(provider: ProviderConfig) -> Conversation {
        let c = Conversation(primaryTarget: provider.makeTarget(for: provider.models[0]))
        context.insert(c)
        return c
    }

    private func append(_ message: ChatMessage, to conversation: Conversation) {
        message.conversation = conversation
        conversation.messages.append(message)
        context.insert(message)
    }

    private func arena(_ conversation: Conversation) -> (UUID, [ChatMessage]) {
        append(ChatMessage(role: .user, content: "Original question", sortIndex: 1), to: conversation)
        let groupID = UUID()
        let first = ChatMessage(role: .assistant, content: "Candidate A", reasoningContent: "PRIVATE REASONING",
                                comparisonGroupID: groupID, sortIndex: 2)
        let second = ChatMessage(role: .assistant, content: "Candidate B", comparisonGroupID: groupID,
                                 isSelectedInGroup: false, sortIndex: 3)
        [first, second].forEach { append($0, to: conversation) }
        return (groupID, [first, second])
    }

    private func successfulEngine(capture: RequestCapture = RequestCapture(), retry: Bool = false) -> ChatEngine {
        ChatEngine { request in
            capture.append(request)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    if retry { continuation.yield(.retrying(httpStatus: 400)) }
                    continuation.yield(.reasoningDelta(""))
                    try? await Task.sleep(for: .milliseconds(15))
                    continuation.yield(.reasoningDelta("thinking"))
                    try? await Task.sleep(for: .milliseconds(15))
                    continuation.yield(.contentDelta("Synthesis "))
                    try? await Task.sleep(for: .milliseconds(15))
                    continuation.yield(.contentDelta("answer"))
                    continuation.yield(.usage(promptTokens: 100, completionTokens: 25))
                    continuation.yield(.done)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func waitForCompletion(_ engine: ChatEngine, _ conversation: Conversation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while engine.isGenerating(in: conversation.id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(engine.isGenerating(in: conversation.id))
    }

    func testSynthesisExcludesFailedAnswersAndReasoningAndUsesOriginalQuestion() async throws {
        let p = provider(), c = conversation(provider: p)
        let (gid, originals) = arena(c)
        let failed = ChatMessage(role: .assistant, content: "FAILED PARTIAL", comparisonGroupID: gid,
                                 isSelectedInGroup: false, sortIndex: 4)
        failed.errorMessage = "network failure"
        append(failed, to: c)
        // Synthesizing an old group must never incorporate later user messages.
        append(ChatMessage(role: .user, content: "LATER QUESTION", sortIndex: 5), to: c)
        let capture = RequestCapture(), engine = successfulEngine(capture: capture)
        XCTAssertEqual(engine.synthesize(groupID: gid, target: c.primaryTarget!, in: c, providers: [p], context: context), .started)
        XCTAssertEqual(engine.synthesize(groupID: gid, target: c.primaryTarget!, in: c, providers: [p], context: context), .busy)
        try await waitForCompletion(engine, c)

        let request = try XCTUnwrap(capture.requests.first)
        let prompt = request.messages.map(\.content).joined()
        XCTAssertTrue(prompt.contains("Original question"))
        XCTAssertTrue(prompt.contains("Candidate A"))
        XCTAssertTrue(prompt.contains("Candidate B"))
        XCTAssertFalse(prompt.contains("FAILED PARTIAL"))
        XCTAssertFalse(prompt.contains("PRIVATE REASONING"))
        XCTAssertFalse(prompt.contains("LATER QUESTION"))
        XCTAssertEqual(request.systemPrompt, ArenaSynthesis.systemPrompt)
        let summary = try XCTUnwrap(c.messages.first(where: \.isSynthesis))
        XCTAssertEqual(originals.map(\.content), ["Candidate A", "Candidate B"])
        XCTAssertTrue(ArenaSynthesis.isCurrent(summary, in: c.messages))
        XCTAssertEqual(summary.latestRequest?.kind, .synthesis)
        XCTAssertEqual(summary.latestRequest?.status, .succeeded)
        XCTAssertFalse(summary.isSelectedInGroup, "the user explicitly chooses which reply to use")
        try engine.selectContextReply(summary, in: c, context: context)
        let history = engine.buildPromptHistory(messages: c.sortedMessages, limit: 0)
        XCTAssertEqual(history.map(\.content), ["Original question", "Synthesis answer", "LATER QUESTION"])

        originals[0].content = "Corrected answer"
        XCTAssertFalse(ArenaSynthesis.isCurrent(summary, in: c.messages))
        XCTAssertFalse(engine.buildPromptHistory(messages: c.sortedMessages, limit: 0).contains { $0.content == "Synthesis answer" })
    }

    func testSynthesisRequiresTwoCompleteAnswersAndAnEnabledJudge() {
        let p = provider(), c = conversation(provider: p)
        let (gid, originals) = arena(c)
        let engine = successfulEngine()
        originals[1].finishReason = LLMFinishReason.length.rawValue
        XCTAssertEqual(engine.synthesize(groupID: gid, target: c.primaryTarget!, in: c, providers: [p], context: context), .insufficientAnswers)
        originals[1].finishReason = nil
        originals[1].isStreaming = true
        XCTAssertEqual(engine.synthesize(groupID: gid, target: c.primaryTarget!, in: c, providers: [p], context: context), .insufficientAnswers)
        originals[1].isStreaming = false
        p.isEnabled = false
        XCTAssertEqual(engine.synthesize(groupID: gid, target: c.primaryTarget!, in: c, providers: [p], context: context), .unavailableModel)
        XCTAssertFalse(c.messages.contains(where: \.isSynthesis))
    }

    func testCancellationAndDeletionKeepIndependentLedgerAndPartialText() async throws {
        let p = provider(), c = conversation(provider: p)
        let received = expectation(description: "partial output received")
        let engine = ChatEngine { _ in
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.contentDelta("partial"))
                    received.fulfill()
                    do {
                        try await Task.sleep(for: .seconds(30))
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        engine.sendUserMessage(text: "Hello", attachments: [], in: c, providers: [p], context: context)
        await fulfillment(of: [received], timeout: 2)
        // Let the main-actor consumer process the emitted event.
        try await Task.sleep(for: .milliseconds(30))
        await engine.stopGenerationAndWait(for: c.id)
        let reply = try XCTUnwrap(c.messages.first { $0.role == .assistant })
        XCTAssertEqual(reply.content, "partial")
        XCTAssertFalse(ArenaSynthesis.isComplete(reply))
        XCTAssertEqual(reply.latestRequest?.status, .cancelled)
        XCTAssertNil(reply.latestRequest?.estimatedCost)
        context.delete(c)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
        let requests = try context.fetch(FetchDescriptor<RequestRecord>())
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.status, .cancelled)
    }

    func testRetryAndRegenerationKeepAttemptCostsAndPriceSnapshots() async throws {
        let p = provider(), c = conversation(provider: p), engine = successfulEngine(retry: true)
        engine.sendUserMessage(text: "Hello", attachments: [], in: c, providers: [p], context: context)
        try await waitForCompletion(engine, c)
        let firstAttempts = try context.fetch(FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.attempt)]))
        XCTAssertEqual(firstAttempts.count, 2)
        XCTAssertEqual(firstAttempts.map(\.status), [.failed, .succeeded])
        XCTAssertEqual(firstAttempts[0].operationID, firstAttempts[1].operationID)
        XCTAssertEqual(firstAttempts[0].httpStatus, 400)
        XCTAssertNil(firstAttempts[0].estimatedCost)
        XCTAssertEqual(try XCTUnwrap(firstAttempts[1].estimatedCost), 0.0004, accuracy: 0.0000001)
        XCTAssertLessThan(try XCTUnwrap(firstAttempts[1].firstReasoningMs), try XCTUnwrap(firstAttempts[1].firstContentMs))
        XCTAssertNotNil(firstAttempts[1].tokensPerSecond)

        var spec = p.models[0]
        spec.inputPricePerMillion = 20
        p.models = [spec]
        let reply = try XCTUnwrap(c.messages.first { $0.role == .assistant })
        engine.regenerate(assistantMessage: reply, in: c, providers: [p], context: context)
        try await waitForCompletion(engine, c)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestRecord>()), 4)
        XCTAssertEqual(reply.latestRequest?.kind, .regeneration)
        XCTAssertEqual(reply.latestRequest?.inputPricePerMillion, 20)
        XCTAssertEqual(firstAttempts[1].inputPricePerMillion, 2)
        XCTAssertEqual(try XCTUnwrap(firstAttempts[1].estimatedCost), 0.0004, accuracy: 0.0000001)
    }

    func testIncompleteAndNonStreamingResponsesDoNotAppearInSpeedRanking() async throws {
        let p = provider(), c = conversation(provider: p)
        let engine = ChatEngine { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.nonStreamingResponse)
                continuation.yield(.contentDelta("answer"))
                continuation.yield(.usage(promptTokens: 10, completionTokens: 20))
                continuation.yield(.finished(.length))
                continuation.finish()
            }
        }
        engine.sendUserMessage(text: "Hello", attachments: [], in: c, providers: [p], context: context)
        try await waitForCompletion(engine, c)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<RequestRecord>()).first)
        XCTAssertEqual(record.status, .incomplete)
        XCTAssertFalse(record.isStreamed)
        XCTAssertNil(record.tokensPerSecond)
        XCTAssertNotNil(record.estimatedCost)
        XCTAssertEqual(RequestLedger.groups([record]).first?.speedSampleCount, 0)
    }

    func testBackupRoundTripsSynthesisAndIndependentLedgerWithoutDuplicates() async throws {
        let p = provider(), c = conversation(provider: p), engine = successfulEngine()
        let (gid, _) = arena(c)
        engine.synthesize(groupID: gid, target: c.primaryTarget!, in: c, providers: [p], context: context)
        try await waitForCompletion(engine, c)
        let archive = try BackupService.decode(BackupService.encode(BackupService.makeArchive(context: context)))
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let target = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try BackupService.apply(archive, to: target.mainContext)
        try BackupService.apply(archive, to: target.mainContext)
        let verify = ModelContext(target)
        let restored = try XCTUnwrap(verify.fetch(FetchDescriptor<Conversation>()).first)
        let summary = try XCTUnwrap(restored.messages.first(where: \.isSynthesis))
        XCTAssertTrue(ArenaSynthesis.isCurrent(summary, in: restored.messages))
        XCTAssertEqual(summary.latestRequest?.kind, .synthesis)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<RequestRecord>()), 1)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<ProviderConfig>()).first?.models.first?.inputPricePerMillion, 2)
    }

    func testV2BackupWithoutNewFieldsStillImports() throws {
        let p = provider(), c = conversation(provider: p)
        _ = arena(c)
        let data = try BackupService.encode(BackupService.makeArchive(context: context))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["formatVersion"] = 2
        json.removeValue(forKey: "requests")
        let decoded = try BackupService.decode(JSONSerialization.data(withJSONObject: json))
        guard case .full(let archive) = decoded else { return XCTFail("wrong format") }
        XCTAssertNil(archive.requests)
        XCTAssertEqual(archive.conversations.first?.messages.count, 3)
    }

    func testRecoveryMarksOrphanRunningRequestsInterruptedWithoutInventingEndTime() throws {
        let p = provider(), c = conversation(provider: p)
        let record = RequestRecord(target: c.primaryTarget!, spec: p.models[0], conversationID: c.id,
                                   messageID: UUID(), kind: .answer)
        context.insert(record)
        try context.save()
        XCTAssertEqual(InterruptedStreamRecovery.run(in: container), 0)
        let recovered = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<RequestRecord>()).first)
        XCTAssertEqual(recovered.status, .interrupted)
        XCTAssertNil(recovered.durationMs)
        XCTAssertNil(recovered.endedAt)
    }

    func testActualOpenAIAdapterRetryCreatesTwoRecordsAndMissingUsageStaysUnknown() async throws {
        let p = provider(), c = conversation(provider: p)
        p.baseURL = "http://localhost/retry-\(UUID())/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeteringURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = ChatEngine { OpenAICompatibleAdapter.streamChat($0, session: session) }
        engine.sendUserMessage(text: "Hello", attachments: [], in: c, providers: [p], context: context)
        try await waitForCompletion(engine, c)
        let requests = try context.fetch(FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.attempt)]))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.status), [.failed, .succeeded])
        XCTAssertEqual(requests.first?.httpStatus, 400)
        XCTAssertEqual(c.messages.first(where: { $0.role == .assistant })?.content, "SSE answer")
        XCTAssertTrue(requests.allSatisfy { $0.estimatedCost == nil && $0.tokensPerSecond == nil })
    }

    func testCompatibilityRetryRechecksTheModelBeforeIssuingHTTP() async throws {
        let p = provider()
        p.baseURL = "http://localhost/retry-\(UUID())/v1"
        try context.save()
        let model = p.models[0]
        let entry = SharedModelEntry(target: p.makeTarget(for: model), spec: model, connectionID: p.id)
        var request = try SystemIntegration.connection(p).request(for: entry, text: "Fixture", systemPrompt: "")
        let validate = p.transmissionCheck(for: model.id)
        var checks = 0
        request.validateBeforeSending = {
            checks += 1
            if checks == 2 { p.models[0].isEnabled = false }
            try validate()
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MeteringURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            for try await _ in OpenAICompatibleAdapter.streamChat(request, session: session) {}
            XCTFail("A revoked model must stop before the compatibility retry")
        } catch LLMError.unavailableModel {}
        let url = try EndpointResolver.chatEndpoint(baseURL: p.baseURL, protocolType: p.protocolType)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(MeteringURLProtocol.count(for: url.path), 1)
    }

    func testActualNonStreamingAdapterRecordsUsageWithoutInventingSpeed() async throws {
        let p = provider(), c = conversation(provider: p)
        p.baseURL = "http://localhost/json-\(UUID())/v1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeteringURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = ChatEngine { OpenAICompatibleAdapter.streamChat($0, session: session) }
        engine.sendUserMessage(text: "Hello", attachments: [], in: c, providers: [p], context: context)
        try await waitForCompletion(engine, c)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<RequestRecord>()).first)
        XCTAssertEqual(record.status, .succeeded)
        XCTAssertEqual(record.promptTokens, 10)
        XCTAssertEqual(record.completionTokens, 20)
        XCTAssertFalse(record.isStreamed)
        XCTAssertNotNil(record.firstContentMs)
        XCTAssertNil(record.tokensPerSecond)
        XCTAssertEqual(try XCTUnwrap(record.estimatedCost), 0.00018, accuracy: 0.0000001)
    }

    func testCostCurrenciesUnknownUsageAndCalendarBoundaries() throws {
        let p = provider(), c = conversation(provider: p)
        func record(currency: String) -> RequestRecord {
            let r = RequestRecord(target: c.primaryTarget!, spec: p.models[0], conversationID: c.id,
                                  messageID: UUID(), kind: .answer)
            r.currency = currency
            r.promptTokens = 100
            r.completionTokens = 25
            r.status = .succeeded
            return r
        }
        let usd = record(currency: "USD"), cny = record(currency: "CNY"), unknown = record(currency: "USD")
        unknown.completionTokens = nil
        XCTAssertNil(unknown.estimatedCost)
        let costs = RequestLedger.costs([usd, cny, unknown])
        XCTAssertEqual(costs.count, 2)
        XCTAssertEqual(try XCTUnwrap(costs["USD"]), 0.0004, accuracy: 0.0000001)
        XCTAssertNil(RequestRecord.validPrice(.nan))
        XCTAssertNil(RequestRecord.validPrice(-1))
        XCTAssertNil(RequestRecord.validPrice(.infinity))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z"))
        let start = calendar.startOfDay(for: now)
        XCTAssertTrue(LedgerPeriod.today.includes(start, now: now, calendar: calendar))
        XCTAssertFalse(LedgerPeriod.today.includes(start.addingTimeInterval(-1), now: now, calendar: calendar))
        XCTAssertFalse(LedgerPeriod.today.includes(start.addingTimeInterval(86400), now: now, calendar: calendar))
        XCTAssertEqual(RequestLedger.median([1, 3, 5, 7]), 4)
    }

    func testV2StoreMigratesPreservingBlobsAndSelectionWithoutCreatingHistoricalCharges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phase1-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("old.store")
        let blob = Data(repeating: 42, count: 320_000)
        let groupID = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV2.self)
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let context = ModelContext(old)
            let c = SchemaV2.Conversation(title: "V2 history")
            let m = SchemaV2.ChatMessage(role: .assistant, content: "kept", comparisonGroupID: groupID)
            m.attachmentsData = blob
            m.promptTokens = 123
            m.conversation = c
            context.insert(c)
            context.insert(m)
            try context.save()
        }
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let migrated = try PersistenceController.open(schema: schema, configuration: ModelConfiguration(schema: schema, url: url))
        let verify = ModelContext(migrated)
        let message = try XCTUnwrap(verify.fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertEqual(message.content, "kept")
        XCTAssertEqual(message.attachmentsData, blob)
        XCTAssertEqual(message.comparisonGroupID, groupID)
        XCTAssertTrue(message.isSelectedInGroup)
        XCTAssertEqual(message.promptTokens, 123)
        XCTAssertNil(message.latestRequest)
        XCTAssertFalse(message.isSynthesis)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<RequestRecord>()), 0)
    }

    func testSynthesisRequiresImmediatelyPrecedingUserMessage() async throws {
        let p = provider(), c = conversation(provider: p)
        append(ChatMessage(role: .user, content: "Earlier question", sortIndex: 1), to: c)
        append(ChatMessage(role: .assistant, content: "Earlier answer", sortIndex: 2), to: c)

        let arenaUser = ChatMessage(role: .user, content: "Arena question", sortIndex: 3)
        append(arenaUser, to: c)
        let groupID = UUID()
        append(ChatMessage(role: .assistant, content: "Candidate A", comparisonGroupID: groupID, sortIndex: 4), to: c)
        append(ChatMessage(role: .assistant, content: "Candidate B", comparisonGroupID: groupID, isSelectedInGroup: false, sortIndex: 5), to: c)

        let engine = successfulEngine()
        await engine.deleteSingleMessage(arenaUser, in: c, context: context)

        let outcome = engine.synthesize(groupID: groupID, target: c.primaryTarget!, in: c, providers: [p], context: context)
        XCTAssertEqual(outcome, .missingQuestion)
        XCTAssertFalse(c.messages.contains(where: \.isSynthesis))
    }

    func testEditUserMessageAndResendPreservesSearchQueryAndOmittedMemory() async throws {
        let p = provider(), c = conversation(provider: p)
        c.assistanceSettings.usePersonalMemory = true
        context.insert(PersonalMemory(content: "SECRET_MEMORY"))

        let capture = RequestCapture()
        var recordedQueries: [String] = []
        let engine = ChatEngine(
            search: { query in
                await MainActor.run { recordedQueries.append(query) }
                return SearchEvidence(
                    query: query,
                    searchedAt: Date(),
                    sources: [SearchSource(id: 1, title: "Ref", url: URL(string: "https://example.com/ref")!, snippet: "Evidence")],
                    credits: 1
                )
            },
            stream: { req in
                capture.append(req)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.contentDelta("Reply"))
                    continuation.yield(.usage(promptTokens: 10, completionTokens: 20))
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
        )

        let firstOutcome = engine.sendUserMessage(
            text: "Initial prompt",
            attachments: [],
            in: c,
            providers: [p],
            context: context,
            options: GenerationOptions(omitMemory: true, searchQuery: "swift query")
        )
        XCTAssertEqual(firstOutcome, .sent)
        try await waitForCompletion(engine, c)

        let userMsg = try XCTUnwrap(c.sortedMessages.first(where: { $0.role == .user }))
        let editOutcome = await engine.editUserMessageAndResend(
            userMessage: userMsg,
            newText: "Edited prompt",
            in: c,
            providers: [p],
            context: context
        )
        XCTAssertEqual(editOutcome, .sent)
        try await waitForCompletion(engine, c)

        XCTAssertEqual(recordedQueries, ["swift query", "swift query"])
        XCTAssertEqual(capture.requests.count, 2)
        let resentReq = try XCTUnwrap(capture.requests.last)
        XCTAssertFalse(resentReq.systemPrompt.contains("SECRET_MEMORY"))
        XCTAssertTrue(resentReq.messages.last?.content.contains("Edited prompt") == true)
        XCTAssertTrue(resentReq.messages.last?.content.contains("https://example.com/ref") == true)

        let regenerated = try XCTUnwrap(c.sortedMessages.last(where: { $0.role == .assistant }))
        XCTAssertTrue(regenerated.assistanceMetadata.omittedMemory)
        XCTAssertEqual(regenerated.assistanceMetadata.requestedSearchQuery, "swift query")
    }
}
