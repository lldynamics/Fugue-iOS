import XCTest
import SwiftData
@testable import iOSBox
// Regression fixtures never contact real providers.
private final class ReviewFixtureURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stopExpectations: [String: XCTestExpectation] = [:]
    static func expectStop(_ expectation: XCTestExpectation, route: String) {
        lock.lock(); defer { lock.unlock() }
        stopExpectations[route] = expectation
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let route = request.url!.path
        var body: String
        if route.contains("multiline") {
            body = "data: {\"choices\":\ndata: [{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: [DONE]\n\n"
        } else if route.contains("anthropic") {
            body = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Partial\"}}\n\n"
        } else if route.contains("gemini") {
            body = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Partial\"}]}}]}\n\n"
        } else {
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"},\"finish_reason\":null}]}\n\n"
        }
        if route.contains("malformed") { body += "data: {broken-json}\n\n" }
        if route.contains("bom") { body = "\u{FEFF}" + body }
        if route.contains("complete") {
            if route.contains("anthropic") { body += "data: {\"type\":\"message_stop\"}\n\n" }
            else if route.contains("gemini") { body += "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n" }
            else { body += "data: [DONE]\n\n" }
        }
        if route.contains("crlf") { body = body.replacingOccurrences(of: "\n", with: "\r\n") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if !route.contains("keepopen") { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {
        Self.lock.lock()
        let key = Self.stopExpectations.keys.first { request.url!.path.contains($0) }
        let expectation = key.flatMap { Self.stopExpectations.removeValue(forKey: $0) }
        Self.lock.unlock()
        expectation?.fulfill()
    }
}

@MainActor
final class ReviewRegressionTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: ProviderConfig.self, AssistantPreset.self, Conversation.self, ChatMessage.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testHeaderOnlyGatewayHasAuthentication() throws {
        let provider = ProviderConfig(name: "Gateway", protocolType: .openAICompatible, baseURL: "https://review.invalid/v1")
        XCTAssertFalse(provider.hasAuthentication)
        provider.customHeaders = [CustomHeader(key: "Authorization", value: "Bearer fixture")]
        XCTAssertTrue(provider.hasAuthentication)
        provider.customHeaders = [CustomHeader(key: "Authorization", value: "Bearer fixture", isEnabled: false)]
        XCTAssertFalse(provider.hasAuthentication)
    }

    func testConflictingImportPreservesExistingMessage() throws {
        let store = try container()
        let context = store.mainContext
        let original = Conversation(title: "Original retained chat")
        context.insert(original)
        let originalMessage = ChatMessage(role: .user, content: "Original content")
        originalMessage.conversation = original
        context.insert(originalMessage)
        try context.save()
        let messageID = originalMessage.id
        let originalID = original.id
        var archive = try BackupService.makeArchive(context: context)
        let importedConversationID = UUID()
        archive.conversations[0].id = importedConversationID
        archive.conversations[0].title = "Conflicting backup chat"
        archive.conversations[0].messages[0].content = "Changed by import"
        XCTAssertThrowsError(try BackupService.apply(.full(archive), to: context))
        let verify = ModelContext(store)
        let all = try verify.fetch(FetchDescriptor<ChatMessage>())
        let existing = try XCTUnwrap(all.first { $0.id == messageID })
        XCTAssertEqual(existing.content, "Original content")
        XCTAssertEqual(existing.conversation?.id, originalID)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<Conversation>()), 1)
    }

    private func request(_ type: APIProtocolType, route: String) -> LLMChatRequest {
        LLMChatRequest(providerName: "Review fixture", protocolType: type, baseURL: "https://review.invalid/\(route)/v1",
            apiKey: "fixture", customHeaders: [], modelID: "test-model", supportsReasoning: false,
            systemPrompt: "", messages: [LLMPromptMessage(role: .user, content: "hello", attachments: [])],
            temperature: nil, topP: 1, maxOutputTokens: nil, enableThinking: false, thinkingBudgetTokens: 1024)
    }

    private func collect(_ type: APIProtocolType, route: String) async throws -> (String, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let req = request(type, route: route)
        let stream: AsyncThrowingStream<LLMStreamEvent, Error>
        switch type {
        case .openAICompatible: stream = OpenAICompatibleAdapter.streamChat(req, session: session)
        case .anthropic: stream = AnthropicAdapter.streamChat(req, session: session)
        case .gemini: stream = GeminiAdapter.streamChat(req, session: session)
        }
        var content = ""
        var done = 0
        for try await event in stream {
            if case .contentDelta(let text) = event { content += text }
            if case .done = event { done += 1 }
        }
        return (content, done)
    }

    func testNormalCompletionForEveryProtocol() async throws {
        for (type, route) in [(APIProtocolType.openAICompatible, "openai-complete"), (.anthropic, "anthropic-complete"), (.gemini, "gemini-complete")] {
            let result = try await collect(type, route: route)
            XCTAssertEqual(result.0, "Partial")
            XCTAssertEqual(result.1, 1)
        }
    }
    func testTerminalEventClosesOpenHTTPConnection() async throws {
        for (type, route) in [(APIProtocolType.openAICompatible, "openai-complete-keepopen"), (.anthropic, "anthropic-complete-keepopen")] {
            let stopped = expectation(description: "Connection closed for \(route)")
            ReviewFixtureURLProtocol.expectStop(stopped, route: route)
            let result = try await collect(type, route: route)
            XCTAssertEqual(result.1, 1)
            await fulfillment(of: [stopped], timeout: 2)
        }
    }
    func testCancellingEachProtocolClosesOpenHTTPConnection() async throws {
        for (type, route) in [(APIProtocolType.openAICompatible, "openai-cancel-keepopen"), (.anthropic, "anthropic-cancel-keepopen"), (.gemini, "gemini-cancel-keepopen")] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReviewFixtureURLProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let stopped = expectation(description: "Cancelled connection for \(route)")
            ReviewFixtureURLProtocol.expectStop(stopped, route: route)
            let req = request(type, route: route)
            let consumer = Task {
                let stream: AsyncThrowingStream<LLMStreamEvent, Error>
                switch type {
                case .openAICompatible: stream = OpenAICompatibleAdapter.streamChat(req, session: session)
                case .anthropic: stream = AnthropicAdapter.streamChat(req, session: session)
                case .gemini: stream = GeminiAdapter.streamChat(req, session: session)
                }
                var content = ""
                do {
                    for try await event in stream {
                        if case .contentDelta(let text) = event {
                            content += text
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                        if case .done = event { XCTFail("Cancellation reported as success") }
                    }
                } catch { }
                return content
            }
            let content = await consumer.value
            XCTAssertEqual(content, "Partial")
            await fulfillment(of: [stopped], timeout: 2)
        }
    }
    func testMultilineCRLF() async throws {
        let result = try await collect(.openAICompatible, route: "multiline-crlf")
        XCTAssertEqual(result.0, "Hello")
    }
    func testMalformedEventCannotBeReportedAsComplete() async throws {
        for (type, route) in [(APIProtocolType.openAICompatible, "openai"), (.anthropic, "anthropic"), (.gemini, "gemini")] {
            do {
                _ = try await collect(type, route: route + "-malformed-complete")
                XCTFail("Malformed event silently discarded for \(type)")
            } catch { XCTAssertTrue(error is LLMError) }
        }
    }
    func testSSELeadingBOMPreservesFirstEvent() async throws {
        let result = try await collect(.openAICompatible, route: "openai-bom-complete")
        XCTAssertEqual(result.0, "Partial")
    }
    func testDuplicateArchiveIDsRejected() throws {
        let store = try container()
        let context = store.mainContext
        context.insert(Conversation(title: "Retain"))
        try context.save()
        var archive = try BackupService.makeArchive(context: context)
        archive.conversations.append(archive.conversations[0])
        XCTAssertThrowsError(try BackupService.apply(.full(archive), to: context))
        XCTAssertEqual(try ModelContext(store).fetchCount(FetchDescriptor<Conversation>()), 1)
    }
    func testPrematureEOFThrowsForEveryProtocol() async throws {
        for (type, route) in [(APIProtocolType.openAICompatible, "openai"), (.anthropic, "anthropic"), (.gemini, "gemini")] {
            do { _ = try await collect(type, route: route); XCTFail("Incomplete stream accepted") }
            catch { XCTAssertTrue(error is LLMError) }
        }
    }
    func testMultilineSSEContentPreserved() async throws {
        let result = try await collect(.openAICompatible, route: "multiline")
        XCTAssertEqual(result.0, "Hello")
        XCTAssertEqual(result.1, 1)
    }
    func testFailedSecretSaveRetainsDatabaseState() {
        let provider = ProviderConfig(name: "Gateway", protocolType: .openAICompatible, baseURL: "https://review.invalid")
        XCTAssertFalse(provider.addCustomHeader(key: "Authorization", value: "secret", isSecret: true, save: { _, _ in false }))
        XCTAssertTrue(provider.customHeaders.isEmpty)
    }
    func testDraftRoundTripAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID()
        let draft = ChatDraft(text: "unsent", attachments: [MessageAttachment(kind: .document, fileName: "a.txt", mimeType: "text/plain", extractedText: "test", byteSize: 4)])
        try ChatDraftStore(directory: directory).save(draft, for: id)
        let second = ChatDraftStore(directory: directory)
        XCTAssertEqual(try second.load(id).text, "unsent")
        XCTAssertEqual(try second.load(id).attachments.count, 1)
        try second.save(ChatDraft(), for: id)
        XCTAssertEqual(try ChatDraftStore(directory: directory).load(id).text, "")
    }
    func testAttachmentLimits() throws {
        let attachment = MessageAttachment(kind: .document, fileName: "a.txt", mimeType: "text/plain", extractedText: "test", byteSize: 4)
        XCTAssertThrowsError(try AttachmentProcessor.validate(Array(repeating: attachment, count: 9)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(AttachmentProcessor.maximumFileBytes + 1))
        try file.close()
        XCTAssertThrowsError(try AttachmentProcessor.processFileURL(url))
    }
}
