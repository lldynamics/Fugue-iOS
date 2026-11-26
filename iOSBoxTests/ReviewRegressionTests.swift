import XCTest
import SwiftData
@testable import iOSBox

let onePixelPNGFixture = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGOQmbDvPwAEoAJqugc36QAAAABJRU5ErkJggg=="

private actor RedirectFixture {
    private(set) var requested: [URL] = []

    func exchange(_ request: URLRequest, types: Set<String>?) throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        requested.append(url)
        if requested.count == 1 {
            return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                                         headerFields: ["Location": "https://library.example.com/notes"])))
        }
        return (Data("Reading notes".utf8), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                                        headerFields: ["Content-Type": "text/plain"])))
    }
}

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
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(for: schema,
                                  configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testBoundedReviewDatesAndMalformedStoredNumbers() {
        XCTAssertEqual(LLMUsage.combined(18, nil, .max, -2), 18)
        XCTAssertEqual(LLMUsage.saturatedSum(.max, 1), .max)
        XCTAssertEqual(ReadingCitation.marker(document: "Guide", chapter: "Intro", index: .max, offset: 2), "[Guide · Intro]")
        XCTAssertEqual(ReadingCitation.marker(document: "Guide", chapter: "Intro", index: 1, offset: 2), "[Guide · Intro #2.2]")
    }

    func testRestoredSortOrderIsNormalizedBeforeAppending() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let conversation = Conversation(title: "Reading")
        let first = ChatMessage(role: .user, content: "First", sortIndex: 7, createdAt: date)
        let second = ChatMessage(role: .assistant, content: "Second", sortIndex: .max, createdAt: date.addingTimeInterval(1))
        conversation.messages = [second, first]
        XCTAssertEqual(conversation.nextMessageSortIndex(), 2)
        XCTAssertEqual(conversation.sortedMessages.map(\.id), [first.id, second.id])
        XCTAssertEqual(conversation.sortedMessages.map(\.sortIndex), [0, 1])
    }

    func testArticleSourceRedactionAndOrdinaryHTMLExtraction() throws {
        let url = try XCTUnwrap(ReadingInput.sharedSourceURL("https://reader:secret@example.com/guide?tracking=1#part"))
        XCTAssertEqual(url.absoluteString, "https://example.com/guide")
        XCTAssertNil(ReadingInput.sharedSourceURL(""))
        let page = try HTMLTextExtractor.extract(
            "<title>Guide &amp; notes</title><nav>Menu</nav><article><svg /><p>One &lt; two</p><p>Second line.</p></article>", url: url
        )
        XCTAssertEqual(page.title, "Guide & notes")
        XCTAssertTrue(page.text.contains("One < two"))
        XCTAssertTrue(page.text.contains("Second line."))
        XCTAssertFalse(page.text.contains("Menu"))
    }

    func testOversizedMarkdownTableHasBoundedTextFallback() {
        let lines = ["| Title | Page |", "| --- | --- |"] + Array(repeating: "| Chapter | 1 |", count: 129)
        let blocks = MarkdownBlockParser.parse(lines.joined(separator: "\n"))
        guard case .codeBlock(_, let code) = blocks.first else { return XCTFail("Expected bounded text") }
        XCTAssertTrue(code.contains("Chapter"))
        XCTAssertLessThanOrEqual(code.utf8.count, 16_000)
    }

    func testTablesShareTheRenderingBudgetOfTheMessage() {
        let header = "|" + Array(repeating: " Chapter ", count: 16).joined(separator: "|") + "|"
        let separator = "|" + Array(repeating: " --- ", count: 16).joined(separator: "|") + "|"
        let table = ([header, separator] + Array(repeating: header, count: 70)).joined(separator: "\n")
        let blocks = MarkdownBlockParser.parse(table + "\n\n" + table)
        XCTAssertEqual(blocks.count, 2)
        guard case .table = blocks.first, case .codeBlock = blocks.last else {
            return XCTFail("The second table exceeds the remaining cell budget.")
        }
    }

    func testUnreadableImagePayloadDoesNotEnterThumbnailCache() {
        let attachment = MessageAttachment(kind: .image, fileName: "note.png", mimeType: "image/png",
                                           dataBase64: Data("A note".utf8).base64EncodedString(), byteSize: 6)
        XCTAssertNil(attachment.withBoundedImagePayload.dataBase64)
        XCTAssertNil(attachment.cachedImage)
    }

    func testShareGrantRequiresTheApprovedDestinationAndProviderInstance() throws {
        let suite = "iosbox.test.share.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let integration = SystemIntegration(defaults: defaults)
        let provider = ProviderConfig(name: "Library", protocolType: .openAICompatible, baseURL: "https://library.example/v1")
        defaults.set([provider.credentialID.uuidString: SystemIntegration.destinationDigest(for: provider)],
                     forKey: "systemShareProviderDestinations")
        XCTAssertTrue(integration.isEnabled(provider))
        provider.baseURL = "https://library.example/other-endpoint"
        XCTAssertFalse(integration.isEnabled(provider))
        provider.baseURL = "https://library.example/v1"
        let restored = ProviderConfig(id: provider.id, name: provider.name, protocolType: provider.protocolType,
                                      baseURL: provider.baseURL, isRestored: true)
        XCTAssertFalse(integration.isEnabled(restored))
    }

    func testWebpageRedirectChecksAuthorizationBeforeTheSecondRequest() async throws {
        let start = URLRequest(url: try XCTUnwrap(URL(string: "https://reader.example.com/article")))
        let denied = RedirectFixture()
        do {
            _ = try await URLReader.follow(start, accepting: ["text/plain"], authorizeRedirect: { _ in false }) { request, types in
                try await denied.exchange(request, types: types)
            }
            XCTFail("A new destination needs approval.")
        } catch URLReaderError.destinationNotApproved {}
        let deniedRequests = await denied.requested
        XCTAssertEqual(deniedRequests.map(\.host), ["reader.example.com"])

        let allowed = RedirectFixture()
        let (data, result) = try await URLReader.follow(start, accepting: ["text/plain"],
                                                        authorizeRedirect: { $0.host == "library.example.com" }) { request, types in
            try await allowed.exchange(request, types: types)
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Reading notes")
        XCTAssertEqual(result.url?.host, "library.example.com")
    }

    func testPinnedWebpageTransportAcceptsNumericPublicEndpointsAndOrdinaryChunking() throws {
        XCTAssertNotNil(PinnedHTTPSReader.publicEndpoint("8.8.8.8"))
        XCTAssertNil(PinnedHTTPSReader.publicEndpoint("127.0.0.1"))
        XCTAssertNil(PinnedHTTPSReader.publicEndpoint("ff02::1"))
        let url = try XCTUnwrap(URL(string: "https://reader.example.com"))
        var parser = PinnedHTTPSReader.ResponseParser(url: url, types: ["text/plain"])
        XCTAssertNil(try parser.receive(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nHel".utf8)))
        let (data, response) = try XCTUnwrap(parser.receive(Data("lo\r\n0\r\n\r\n".utf8)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Hello")
        XCTAssertEqual(response.textEncodingName, "utf-8")

        var fixed = PinnedHTTPSReader.ResponseParser(url: url, types: ["text/plain"])
        XCTAssertNil(try fixed.receive(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nHel".utf8)))
        XCTAssertEqual(try fixed.receive(Data("lo".utf8))?.0, Data("Hello".utf8))

        var closed = PinnedHTTPSReader.ResponseParser(url: url, types: ["text/plain"])
        XCTAssertNil(try closed.receive(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nHello".utf8)))
        XCTAssertEqual(try closed.receive(Data(), end: true)?.0, Data("Hello".utf8))
    }

    func testReadingProgressIsBoundedAndKeepsItsSpoilerLimit() throws {
        let store = try container()
        let context = store.mainContext
        let book = try BookLibrary.store(PreparedBook(BookManuscript(title: "Book", chapters: [
            BookChapter(title: "First", text: "Guide"), BookChapter(title: "Second", text: "Guide")
        ])), in: context)
        let friend = BookFriend(bookID: book.id, bookTitle: book.title, name: "Guide", aliases: [], throughChapter: Int.max)
        let restored = friend.validatingRestoredProgress(chapterCount: 2)
        XCTAssertEqual(restored.throughChapter, -1)
        XCTAssertEqual(friend.progressLabel(in: nil), restored.progressLabel(in: nil))
        var valid = friend
        valid.throughChapter = 0
        XCTAssertEqual(valid.validatingRestoredProgress(chapterCount: 2).throughChapter, 0)
        XCTAssertNotEqual(valid.progressLabel(in: book), restored.progressLabel(in: book))

        let chat = Conversation(title: "Book friend")
        chat.assistanceSettings.bookFriend = restored
        context.insert(chat)
        try context.save()
        let updated = try BookLibrary.changeProgress(in: chat, through: 0, context: context)
        XCTAssertEqual(updated.id, chat.id)
        XCTAssertEqual(updated.activeBookFriend?.throughChapter, 0)
    }

    func testShareImageRequiresARegularBoundedImageFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("cover.png")
        try XCTUnwrap(Data(base64Encoded: onePixelPNGFixture)).write(to: fixture)
        XCTAssertNotNil(ShareInputLoader.downsampleImage(at: fixture, maxPixelSize: 256))
        XCTAssertNil(ShareInputLoader.downsampleImage(at: directory, maxPixelSize: 256))
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
        case .openAIResponses: stream = OpenAIResponsesAdapter.streamChat(req, session: session)
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
                case .openAIResponses: stream = OpenAIResponsesAdapter.streamChat(req, session: session)
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
        XCTAssertThrowsError(try AttachmentProcessor.validate(Array(repeating: attachment, count: AttachmentProcessor.maximumAttachmentCount + 1)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(AttachmentProcessor.maximumFileBytes + 1))
        try file.close()
        XCTAssertThrowsError(try AttachmentProcessor.processFileURL(url))
    }
}
