import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class PublicationReviewRegressionTests: XCTestCase {
    func testUnlockReopensOriginalStoreOnce() throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let recovery = try PersistenceController.makeRecoveryContainer(schema: schema)
        let runtime = AppRuntime(store: .init(container: recovery, startupNotice: "locked"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("original.store"), cloudKitDatabase: .none)
        let conversationID: UUID
        do {
            let original = try ModelContainer(for: schema, configurations: config)
            let conversation = Conversation(title: "Original conversation")
            conversationID = conversation.id
            original.mainContext.insert(conversation)
            try original.mainContext.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: config)
        runtime.retryStorageIfAvailable(protectedDataAvailable: false) {
            XCTFail("Attempted to open while protected data was unavailable")
            return .init(container: reopened, startupNotice: nil)
        }
        XCTAssertTrue(runtime.store.container === recovery)
        runtime.retryStorageIfAvailable(protectedDataAvailable: true) { .init(container: reopened, startupNotice: nil) }
        XCTAssertEqual(try runtime.store.container.mainContext.fetch(FetchDescriptor<Conversation>()).map(\.id), [conversationID])
        XCTAssertNil(runtime.store.startupNotice)
        runtime.retryStorageIfAvailable(protectedDataAvailable: true) {
            XCTFail("Opened an already usable store twice")
            return .init(container: recovery, startupNotice: nil)
        }
        XCTAssertTrue(runtime.store.container === reopened)
    }

    func testBackupByteLimitAppliesToBothWritersAndReaders() throws {
        let limit = BackupService.maximumFileBytes
        XCTAssertEqual(limit, 256 * 1024 * 1024)
        XCTAssertNoThrow(try BackupService.validateFileSize(limit))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(limit + 1))
        try file.close()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        XCTAssertThrowsError(try BackupService.writeToTemporaryFile(data), "", checkFileTooLarge)
        XCTAssertThrowsError(try BackupService.decode(data), "", checkFileTooLarge)
        XCTAssertThrowsError(try EncryptedBackupService.writeEncryptedTemporaryFile(data), "", checkFileTooLarge)
        XCTAssertThrowsError(try EncryptedBackupService.decryptPayload(data: data, password: "test-pass"), "", checkFileTooLarge)
    }

    func testIndividuallyValidBooksCannotProduceAnOversizedBackup() throws {
        let chapters = [BookChapter(title: "Appendix", text: String(repeating: "A", count: 11 * 1024 * 1024))]
        XCTAssertFalse(try BookManuscript(title: "Appendix", chapters: chapters).encoded().isEmpty)
        let books = (1...24).map { BookVolume.Snapshot(id: UUID(), title: "Book \($0)", chapters: chapters, importedAt: .now) }
        let archive = BackupArchive(formatVersion: BackupArchive.currentFormatVersion, exportedAt: .now, appVersion: "test",
                                    providers: [], presets: [], conversations: [], books: books)
        XCTAssertThrowsError(try BackupService.encode(archive), "", checkFileTooLarge)
        let payload = EncryptedBackupService.FullPayload(archive: archive, providerSecrets: [], tavilyAPIKey: "")
        XCTAssertThrowsError(try EncryptedBackupService.encryptPayload(payload, password: "test-pass"), "", checkFileTooLarge)
    }

    private func checkFileTooLarge(_ error: Error) {
        guard case .fileTooLarge? = error as? BackupError else { return XCTFail("Unexpected error: \(error)") }
    }

    func testWebpageApprovalsStayWithTheirChatAndResolveOnceInOrder() async throws {
        let engine = ChatEngine()
        let a = UUID(), b = UUID()
        let firstURL = try XCTUnwrap(URL(string: "https://one.example/first"))
        let nextURL = try XCTUnwrap(URL(string: "https://one.example/second?item=test"))
        let otherURL = try XCTUnwrap(URL(string: "https://two.example/page"))
        func waitForRequest(_ url: URL) async throws -> ChatEngine.PendingWebpageApproval {
            for _ in 0..<100 {
                if let request = engine.pendingWebpageApprovals.first(where: { $0.url == url }) { return request }
                try await Task.sleep(for: .milliseconds(10))
            }
            return try XCTUnwrap(engine.pendingWebpageApprovals.first(where: { $0.url == url }))
        }
        let first = Task { await engine.requestWebpageApproval(for: firstURL, conversationID: a) }
        defer { first.cancel() }
        let firstRequest = try await waitForRequest(firstURL)
        let next = Task { await engine.requestWebpageApproval(for: nextURL, conversationID: a) }
        defer { next.cancel() }
        let nextRequest = try await waitForRequest(nextURL)
        let other = Task { await engine.requestWebpageApproval(for: otherURL, conversationID: b) }
        defer { other.cancel() }
        let otherRequest = try await waitForRequest(otherURL)
        XCTAssertEqual(engine.pendingWebpageApproval(in: a)?.id, firstRequest.id)
        XCTAssertEqual(engine.pendingWebpageApproval(in: b)?.id, otherRequest.id)
        engine.cancelWebpageApprovals(in: b)
        let otherDecision = await other.value
        XCTAssertEqual(otherDecision, .deny)
        XCTAssertEqual(engine.pendingWebpageApproval(in: a)?.id, firstRequest.id)
        engine.resolvePendingWebpageApproval(id: firstRequest.id, decision: .allow, rememberHost: true)
        engine.resolvePendingWebpageApproval(id: firstRequest.id, decision: .deny, rememberHost: false)
        let firstDecision = await first.value
        XCTAssertEqual(firstDecision, .allow)
        XCTAssertEqual(engine.pendingWebpageApproval(in: a)?.id, nextRequest.id)
        next.cancel()
        let nextDecision = await next.value
        XCTAssertEqual(nextDecision, .deny)
        XCTAssertTrue(engine.pendingWebpageApprovals.isEmpty)
        let remembered = await engine.requestWebpageApproval(for: firstURL, conversationID: a)
        XCTAssertEqual(remembered, .allow)
        XCTAssertNil(engine.approvedWebpageHostsByConversation[b])
        let withQuery = Task { await engine.requestWebpageApproval(for: nextURL, conversationID: a) }
        defer { withQuery.cancel() }
        _ = try await waitForRequest(nextURL)
        engine.cancelWebpageApprovals(in: a)
        let queryDecision = await withQuery.value
        XCTAssertEqual(queryDecision, .deny)
    }

    func testKnowledgeRejectsUnrelatedPassagesAndPartialIdentifiers() async throws {
        func document(_ title: String, _ body: String) throws -> KnowledgeDocumentSnapshot {
            let chapters = [BookChapter(title: title, text: body)]
            return .init(id: UUID(), title: title, manuscript: try JSONEncoder().encode(chapters))
        }
        let bread = try document("面包配方", "称取面粉，加入温水和酵母。")
        let similar = try document("早期型号", "QXJ73490 和 QXJ7349-B 供电规格。")
        let match = try document("说明书", "qxj7349 采用低压供电。")
        let search = ProjectKnowledgeSearch()
        for query in ["QXJ7349", "请查 QXJ7349 的参数", "  ", "！？"] {
            let result = try await search.retrieve(from: [bread, similar], query: query)
            XCTAssertTrue(result.passages.isEmpty, query)
            XCTAssertTrue(result.promptText().isEmpty)
        }
        let result = try await search.retrieve(from: [bread, match, similar], query: "请查 QXJ7349 的参数")
        XCTAssertEqual(result.passages.map(\.volumeID), [match.id])
        let manual = KnowledgeDocumentSnapshot(id: UUID(), title: "QXJ7349 手册", manuscript: try JSONEncoder().encode([
            BookChapter(title: "包装", text: "附带电源线。"), BookChapter(title: "安装温度", text: "安装温度建议为二十度。")
        ]))
        let byTitle = try await search.retrieve(from: [bread, manual], query: "QXJ7349 的安装温度", maxPassages: 1)
        XCTAssertEqual(byTitle.passages.first?.sectionTitle, "安装温度")
        let tool = await AgentToolRunner.execute(
            .init(id: "lookup", name: "search_documents", argumentsJSON: #"{"query":"QXJ7349"}"#),
            searchHandler: { _ in throw CancellationError() },
            knowledgeHandler: { try await search.retrieve(from: [bread], query: $0) }
        )
        XCTAssertTrue(tool.record.succeeded)
        XCTAssertEqual(tool.toolOutputJSON, #"{"matches":[]}"#)
        XCTAssertEqual(tool.knowledgeEvidence?.passages, [])
    }

    func testCancellingSpeechDuringActivationKeepsPlaybackStopped() async throws {
        let speech = SpeechService.shared
        defer { speech.stopSpeaking() }
        let id = UUID()
        speech.toggleSpeaking(messageID: id, text: "Speech activation test")
        XCTAssertEqual(speech.speakingMessageID, id)
        speech.toggleSpeaking(messageID: id, text: "Speech activation test")
        XCTAssertNil(speech.speakingMessageID)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(speech.speakingMessageID)
    }

    func testLiveActivityPrivacyDefaultsAndRevocation() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let live = LiveActivityCoordinator(defaults: defaults)
        let id = UUID()
        defer { live.end(conversationID: id, outcome: GenerationOutcome(statuses: [], stopped: true)) }
        func generate() throws -> IOSBoxGenerationAttributes.ContentState {
            live.start(conversationID: id, chatTitle: "Secret title", modeBadge: "Chat",
                       speakerOrModel: "Secret model", phaseText: "Generating")
            live.update(conversationID: id, previewSnippet: "Secret reply", force: true)
            return try XCTUnwrap(live.activeStates[id])
        }
        func assertPrivate(_ state: IOSBoxGenerationAttributes.ContentState) throws {
            let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            XCTAssertFalse(json.contains("Secret"))
            XCTAssertNil(state.visibleTitle)
            XCTAssertNil(state.visibleSnippet)
        }
        XCTAssertFalse(live.showsPreviews)
        try assertPrivate(generate())
        live.setShowsPreviews(true)
        XCTAssertTrue(LiveActivityCoordinator(defaults: defaults).showsPreviews)
        let optedIn = try generate()
        XCTAssertEqual(optedIn.visibleTitle, "Secret title")
        XCTAssertEqual(optedIn.visibleSpeaker, "Secret model")
        XCTAssertEqual(optedIn.visibleSnippet, "Secret reply")
        live.setShowsPreviews(false)
        live.update(conversationID: id, speakerOrModel: "Secret again", previewSnippet: "Secret again", force: true)
        try assertPrivate(XCTUnwrap(live.activeStates[id]))
        let oldJSON = #"{"speakerOrModel":"Secret model","phaseText":"Generating","completedTurns":0,"totalTurns":1,"previewSnippet":"Secret reply"}"#
        let legacy = try JSONDecoder().decode(IOSBoxGenerationAttributes.ContentState.self, from: Data(oldJSON.utf8))
        XCTAssertNotEqual(legacy.visibleSpeaker, "Secret model")
        XCTAssertNil(legacy.visibleSnippet)
        XCTAssertNil(legacy.visibleTitle)
    }
}
