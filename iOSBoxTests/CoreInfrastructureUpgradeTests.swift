import SwiftData
import XCTest
@testable import iOSBox

private final class CoreUpgradeMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer.prefix(read))
            }
            copy.httpBody = data
        }
        do {
            let (response, data) = try handler(copy)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class CoreInfrastructureUpgradeTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var previousEmbeddingScope: String?

    override func setUp() {
        super.setUp()
        previousEmbeddingScope = UserDefaults.standard.string(forKey: EmbeddingConsent.key)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousEmbeddingScope, forKey: EmbeddingConsent.key)
        CoreUpgradeMockURLProtocol.handler = nil
        containers.removeAll()
        super.tearDown()
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return container
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoreUpgradeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func authorize(_ config: EmbeddingConfig) throws {
        let scope = try config.consentScope(for: config.endpoint)
        UserDefaults.standard.set(scope, forKey: EmbeddingConsent.key)
    }

    // MARK: - Pillar 1: Sync Tombstones & Sharded WebDAV Sync

    func testSyncTombstoneStoreRecordsMergesPrunesAndRemoves() {
        let store = SyncTombstoneStore(fileURL: nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-(SyncTombstoneStore.retentionInterval + 3600))
        let idA = UUID()
        let idB = UUID()

        store.recordDeletion(kind: .conversation, id: idA, at: now.addingTimeInterval(-600))
        // Older timestamp must not overwrite newer deletion.
        store.recordDeletion(kind: .conversation, id: idA, at: now.addingTimeInterval(-1200))
        XCTAssertEqual(store.latestDeletion(kind: .conversation, id: idA, now: now), now.addingTimeInterval(-600))

        // Merging incoming newer tombstone updates timestamp; expired entries are pruned.
        let merged = store.merge([
            SyncTombstone(kind: .conversation, id: idA, deletedAt: now.addingTimeInterval(-100)),
            SyncTombstone(kind: .book, id: idB, deletedAt: oldDate)
        ], now: now)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(store.latestDeletion(kind: .conversation, id: idA, now: now), now.addingTimeInterval(-100))
        XCTAssertNil(store.latestDeletion(kind: .book, id: idB, now: now))

        store.removeTombstone(kind: .conversation, id: idA)
        XCTAssertEqual(store.count(now: now), 0)
    }

    func testBackupSyncMergeWithTombstonesPropagatesDeletesAndRespectsNewerEdits() throws {
        let deviceA = try makeInMemoryContainer()
        let deviceB = try makeInMemoryContainer()
        let cardsA = FlashcardStore(fileURL: nil)
        let cardsB = FlashcardStore(fileURL: nil)
        let kbA = PresetKnowledgeStore(fileURL: nil)
        let kbB = PresetKnowledgeStore(fileURL: nil)
        let tombstonesA = SyncTombstoneStore(fileURL: nil)
        let tombstonesB = SyncTombstoneStore(fileURL: nil)

        let baseTime = Date().addingTimeInterval(-3600)

        // Seed identical items on both devices.
        let convDeleteID = UUID()
        let convEditedLaterID = UUID()
        let memDeleteID = UUID()
        let preparedBook = try PreparedBook(BookManuscript(
            title: "同步测试手册",
            chapters: [BookChapter(title: "第一章", text: "这是一本用于验证跨设备删除同步的测试书籍。")]
        ))

        for (ctx, cards) in [(deviceA.mainContext, cardsA), (deviceB.mainContext, cardsB)] {
            let c1 = Conversation(id: convDeleteID, title: "将被删除的对话")
            c1.updatedAt = baseTime
            let c2 = Conversation(id: convEditedLaterID, title: "稍后更新的对话")
            c2.updatedAt = baseTime
            ctx.insert(c1)
            ctx.insert(c2)

            let mem = PersonalMemory(id: memDeleteID, content: "待删除记忆", createdAt: baseTime)
            ctx.insert(mem)

            let book = BookVolume(
                id: preparedBook.id,
                title: preparedBook.title,
                chapterTitles: preparedBook.chapterTitles,
                manuscript: preparedBook.data,
                importedAt: baseTime
            )
            ctx.insert(book)
            try ctx.save()
            _ = try cards.mergeImported([
                StudyFlashcard(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    deckName: "测试",
                    front: "问题",
                    back: "答案",
                    createdAt: baseTime
                )
            ])
        }

        let cardID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let deleteTime = baseTime.addingTimeInterval(120)

        // Device A deletes c1, c2, mem, book, and card at deleteTime.
        for chat in try deviceA.mainContext.fetch(FetchDescriptor<Conversation>()) {
            deviceA.mainContext.delete(chat)
        }
        for mem in try deviceA.mainContext.fetch(FetchDescriptor<PersonalMemory>()) {
            deviceA.mainContext.delete(mem)
        }
        for book in try deviceA.mainContext.fetch(FetchDescriptor<BookVolume>()) {
            deviceA.mainContext.delete(book)
        }
        try deviceA.mainContext.save()
        _ = try cardsA.deleteCards(ids: [cardID])

        tombstonesA.recordDeletion(kind: .conversation, id: convDeleteID, at: deleteTime)
        tombstonesA.recordDeletion(kind: .conversation, id: convEditedLaterID, at: deleteTime)
        tombstonesA.recordDeletion(kind: .memory, id: memDeleteID, at: deleteTime)
        tombstonesA.recordDeletion(kind: .book, id: preparedBook.id, at: deleteTime)
        tombstonesA.recordDeletion(kind: .flashcard, id: cardID, at: deleteTime)

        // Meanwhile Device B edited convEditedLaterID AFTER deleteTime -> newer edit must win!
        if let editedConv = try deviceB.mainContext.fetch(FetchDescriptor<Conversation>()).first(where: { $0.id == convEditedLaterID }) {
            editedConv.title = "编辑后保留的对话"
            editedConv.updatedAt = deleteTime.addingTimeInterval(60)
            try deviceB.mainContext.save()
        }

        // Export from Device A with tombstones and sync-apply onto Device B.
        let archiveFromA = try BackupService.makeArchive(
            context: deviceA.mainContext,
            flashcardStore: cardsA,
            knowledgeStore: kbA,
            tombstoneStore: tombstonesA
        )
        XCTAssertEqual(archiveFromA.tombstones?.count, 5)

        let summaryB = try BackupService.apply(
            .full(archiveFromA),
            to: deviceB.mainContext,
            flashcardStore: cardsB,
            knowledgeStore: kbB,
            tombstonePolicy: .enforce(tombstonesB)
        )
        XCTAssertEqual(summaryB.deleted, 4, "c1, mem, book, card should be deleted; c2 survived because edited later")

        let remainingChatsB = try deviceB.mainContext.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(remainingChatsB.map(\.id), [convEditedLaterID])
        XCTAssertTrue(try deviceB.mainContext.fetch(FetchDescriptor<PersonalMemory>()).isEmpty)
        XCTAssertTrue(try deviceB.mainContext.fetch(FetchDescriptor<BookVolume>()).isEmpty)
        XCTAssertTrue(cardsB.cards.isEmpty)
        // Tombstone for convEditedLaterID must be cleared so it doesn't get deleted later.
        XCTAssertNil(tombstonesB.latestDeletion(kind: .conversation, id: convEditedLaterID))
        XCTAssertNotNil(tombstonesB.latestDeletion(kind: .conversation, id: convDeleteID))

        // Manual restore with `.ignore` must still allow restoring convDeleteID from an old backup.
        let oldBackup = BackupArchive(
            formatVersion: BackupArchive.currentFormatVersion,
            exportedAt: baseTime,
            appVersion: "test",
            providers: [],
            presets: [],
            conversations: [
                ConversationBackup(
                    id: convDeleteID,
                    title: "从历史备份恢复的对话",
                    isPinned: false,
                    assistantID: nil,
                    assistantEmoji: "💬",
                    systemPrompt: "",
                    temperature: 0.7,
                    useCustomTemperature: false,
                    topP: 1.0,
                    maxOutputTokens: 0,
                    contextMessageLimit: 20,
                    enableThinking: false,
                    thinkingBudgetTokens: 0,
                    isArenaMode: false,
                    primaryTarget: nil,
                    arenaTargets: [],
                    assistanceSettings: nil,
                    activeLeafMessageID: nil,
                    folderTag: nil,
                    createdAt: baseTime,
                    updatedAt: baseTime,
                    messages: []
                )
            ]
        )
        let manualSummary = try BackupService.apply(
            .full(oldBackup),
            to: deviceB.mainContext,
            flashcardStore: cardsB,
            knowledgeStore: kbB,
            tombstonePolicy: .ignore
        )
        XCTAssertEqual(manualSummary.conversations, 1)
        XCTAssertEqual(try deviceB.mainContext.fetchCount(FetchDescriptor<Conversation>()), 2)
    }

    func testWebDAVPayloadSharderSplitsDeduplicatesAndReassembles() throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext
        let largePayload = String(repeating: "A", count: 24 * 1024)
        let smallPayload = "c21hbGw="

        let prepared = try PreparedBook(BookManuscript(
            title: "分片电子书",
            chapters: [BookChapter(title: "序言", text: String(repeating: "这是一段正文内容。", count: 200))]
        ))
        ctx.insert(BookVolume(
            id: prepared.id,
            title: prepared.title,
            chapterTitles: prepared.chapterTitles,
            manuscript: prepared.data
        ))

        let chat = Conversation(title: "多图对话")
        ctx.insert(chat)
        let att1 = MessageAttachment(kind: .image, fileName: "one.png", mimeType: "image/png", dataBase64: largePayload, extractedText: nil, byteSize: largePayload.count)
        let attDup = MessageAttachment(kind: .image, fileName: "dup.png", mimeType: "image/png", dataBase64: largePayload, extractedText: nil, byteSize: largePayload.count)
        let attSmall = MessageAttachment(kind: .image, fileName: "tiny.png", mimeType: "image/png", dataBase64: smallPayload, extractedText: nil, byteSize: 5)
        let m1 = ChatMessage(role: .user, content: "发图1", attachments: [att1, attSmall], sortIndex: 0)
        let m2 = ChatMessage(role: .user, content: "发图2", attachments: [attDup], sortIndex: 1)
        m1.conversation = chat
        m2.conversation = chat
        ctx.insert(m1)
        ctx.insert(m2)
        try ctx.save()

        let full = try EncryptedBackupService.makeExportPayload(
            context: ctx,
            flashcardStore: FlashcardStore(fileURL: nil),
            knowledgeStore: PresetKnowledgeStore(fileURL: nil)
        )
        let bundle = try WebDAVPayloadSharder.split(full)

        // 1 book blob + 1 deduplicated attachment blob = 2 unique blobs total.
        XCTAssertEqual(bundle.blobs.count, 2)
        XCTAssertEqual(bundle.manifest.bookRefs.count, 1)
        XCTAssertEqual(bundle.manifest.corePayload.archive.books?.count, 0)

        let shardedMessages = try XCTUnwrap(bundle.manifest.corePayload.archive.conversations.first?.messages)
        XCTAssertTrue(shardedMessages[0].attachments[0].dataBase64?.hasPrefix(WebDAVPayloadSharder.blobSentinelPrefix) == true)
        XCTAssertEqual(shardedMessages[0].attachments[1].dataBase64, smallPayload)
        XCTAssertEqual(shardedMessages[0].attachments[0].dataBase64, shardedMessages[1].attachments[0].dataBase64)

        // Reassemble from blobs reproduces identical payload.
        let restored = try WebDAVPayloadSharder.reassemble(bundle.manifest, blobs: bundle.blobs)
        XCTAssertEqual(restored.archive.books?.count, 1)
        XCTAssertEqual(restored.archive.books?.first?.id, prepared.id)
        XCTAssertEqual(restored.archive.conversations.first?.messages[0].attachments[0].dataBase64, largePayload)
        XCTAssertEqual(restored.archive.conversations.first?.messages[1].attachments[0].dataBase64, largePayload)

        // Reassemble skipping downloaded book blob when book already exists locally.
        let localBookSnap = try XCTUnwrap(full.archive.books?.first)
        let attachmentOnlyBlobs = bundle.blobs.filter { $0.key != bundle.manifest.bookRefs[0].blobHash }
        let restoredWithLocalBook = try WebDAVPayloadSharder.reassemble(
            bundle.manifest,
            blobs: attachmentOnlyBlobs,
            existingBooks: [localBookSnap.id: localBookSnap]
        )
        XCTAssertEqual(restoredWithLocalBook.archive.books?.first?.title, "分片电子书")
    }

    func testWebDAVShardedPushAndPullIncrementalSkipping() async throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext
        let prepared = try PreparedBook(BookManuscript(
            title: "云端分片书",
            chapters: [BookChapter(title: "第1章", text: "增量分片同步测试正文。")]
        ))
        ctx.insert(BookVolume(
            id: prepared.id,
            title: prepared.title,
            chapterTitles: prepared.chapterTitles,
            manuscript: prepared.data
        ))
        let largeImg = String(repeating: "B", count: 20 * 1024)
        let chat = Conversation(title: "同步会话")
        ctx.insert(chat)
        let m1 = ChatMessage(
            role: .user,
            content: "第一轮",
            attachments: [MessageAttachment(kind: .image, fileName: "pic.jpg", mimeType: "image/jpeg", dataBase64: largeImg, extractedText: nil, byteSize: largeImg.count)],
            sortIndex: 0
        )
        m1.conversation = chat
        ctx.insert(m1)
        try ctx.save()

        // In-memory mock WebDAV storage.
        final class RemoteStore: @unchecked Sendable {
            let lock = NSLock()
            var files: [String: Data] = [:]
            var putPaths: [String] = []
            var getPaths: [String] = []
        }
        let remote = RemoteStore()
        let session = makeMockSession()

        CoreUpgradeMockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"
            return remote.lock.withLock {
                switch method {
                case "MKCOL":
                    return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
                case "PUT":
                    remote.files[path] = req.httpBody ?? Data()
                    remote.putPaths.append(path)
                    let etag = "\"\(remote.putPaths.count)\""
                    return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["ETag": etag])!, Data())
                case "HEAD":
                    if let body = remote.files[path] {
                        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"ok\"", "Content-Length": "\(body.count)"])!, Data())
                    }
                    return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
                case "GET":
                    remote.getPaths.append(path)
                    if let body = remote.files[path] {
                        return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"ok\"", "Content-Length": "\(body.count)"])!, body)
                    }
                    return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
                default:
                    return (HTTPURLResponse(url: req.url!, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!, Data())
                }
            }
        }

        let payload1 = try EncryptedBackupService.makeExportPayload(
            context: ctx,
            flashcardStore: FlashcardStore(fileURL: nil),
            knowledgeStore: PresetKnowledgeStore(fileURL: nil)
        )
        let push1 = try await WebDAVShardedSyncService.pushSharded(
            payload: payload1,
            passphrase: "strong-sync-password",
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "alice",
            password: "pw",
            session: session
        )
        XCTAssertEqual(push1.stats.uploadedBlobs, 2)
        XCTAssertEqual(push1.stats.skippedUploadBlobs, 0)
        XCTAssertEqual(push1.presentBlobs.count, 2)

        // Add a lightweight text message and push again: existing static blobs must be skipped!
        let m2 = ChatMessage(role: .assistant, content: "第二轮纯文本回复", sortIndex: 1)
        m2.conversation = chat
        ctx.insert(m2)
        try ctx.save()

        let payload2 = try EncryptedBackupService.makeExportPayload(
            context: ctx,
            flashcardStore: FlashcardStore(fileURL: nil),
            knowledgeStore: PresetKnowledgeStore(fileURL: nil)
        )
        let push2 = try await WebDAVShardedSyncService.pushSharded(
            payload: payload2,
            passphrase: "strong-sync-password",
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "alice",
            password: "pw",
            knownSaltBase64: push1.saltBase64,
            knownKeyFingerprint: push1.keyFingerprint,
            knownRemoteBlobs: Set(push1.presentBlobs),
            session: session
        )
        XCTAssertEqual(push2.stats.uploadedBlobs, 0)
        XCTAssertEqual(push2.stats.skippedUploadBlobs, 2)

        // Pull on a device that already owns the book locally -> only attachment blob downloaded.
        let localBook = try XCTUnwrap(payload2.archive.books?.first)
        let pulled = try await WebDAVShardedSyncService.pullSharded(
            passphrase: "strong-sync-password",
            serverURL: "https://dav.example.com/dav/",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "alice",
            password: "pw",
            existingBooks: [localBook.id: localBook],
            session: session
        )
        XCTAssertEqual(pulled.stats.skippedLocalBlobs, 1)
        XCTAssertEqual(pulled.stats.downloadedBlobs, 1)
        XCTAssertEqual(pulled.payload.archive.conversations.first?.messages.count, 2)

        // Wrong passphrase must fail decryption cleanly.
        do {
            _ = try await WebDAVShardedSyncService.pullSharded(
                passphrase: "wrong-password-123",
                serverURL: "https://dav.example.com/dav/",
                remotePath: "Fugue/fugue-sync.enc.json",
                username: "alice",
                password: "pw",
                session: session
            )
            XCTFail("Expected wrong passphrase error")
        } catch let err as EncryptedBackupError {
            XCTAssertEqual(err, .wrongPasswordOrCorrupted)
        }
    }

    // MARK: - Pillar 2: SQLite FTS5 Full-Text Global Search

    func testSearchTokenizerCJKAndFTS5SafeEscaping() {
        let indexed = SearchTokenizer.indexText("SwiftData 数据库迁移指南 v8")
        XCTAssertTrue(indexed.contains("swiftdata"))
        XCTAssertTrue(indexed.contains("数据"))
        XCTAssertTrue(indexed.contains("据库"))
        XCTAssertTrue(indexed.contains("迁移"))
        XCTAssertTrue(indexed.contains("v8"))

        let parsed = SearchTokenizer.parseQuery("Swift 迁移")
        XCTAssertFalse(parsed.isEmpty)
        XCTAssertTrue(parsed.ftsMatchExpression.contains("\"swift\"*"))
        XCTAssertTrue(parsed.ftsMatchExpression.contains("\"迁移\""))
        XCTAssertEqual(parsed.highlightTerms, ["Swift", "迁移"])
        let strictChinese = SearchTokenizer.parseQuery("高铁座报销")
        let relaxedChinese = SearchTokenizer.parseQuery("高铁座报销", useOR: true)
        XCTAssertEqual(strictChinese.ftsMatchExpression, #"("高铁" AND "铁座" AND "座报" AND "报销")"#)
        XCTAssertTrue(relaxedChinese.ftsMatchExpression.contains(#""高铁" OR "铁座" OR "座报" OR "报销""#))

        // FTS5 syntax metacharacters must never break parsing.
        let hostile = SearchTokenizer.parseQuery(#"NOT "hello"* (foo:bar) ^baz"#)
        XCTAssertFalse(hostile.isEmpty)
        XCTAssertFalse(hostile.ftsMatchExpression.contains(":"))
    }

    func testFTS5GlobalSearchCoversMultiTermReasoningBooksFlashcardsAndUpdates() async throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext

        let chat1 = Conversation(title: "数据库架构复盘")
        chat1.folderTag = "工程"
        ctx.insert(chat1)
        let msg1 = ChatMessage(
            role: .assistant,
            content: "建议在 SwiftData 升级到 V8 之前，先制定完整的回滚与迁移方案。",
            reasoningContent: "内部推导：需要检查外置大字段与索引重建耗时。",
            sortIndex: 0
        )
        msg1.conversation = chat1
        ctx.insert(msg1)

        let chat2 = Conversation(title: "量子计算专题")
        ctx.insert(chat2)
        let msg2 = ChatMessage(role: .user, content: "帮我总结今天的购物清单。", sortIndex: 0)
        msg2.conversation = chat2
        ctx.insert(msg2)

        let book = try PreparedBook(BookManuscript(
            title: "分布式系统笔记",
            chapters: [
                BookChapter(title: "第 1 章 共识算法", text: "Raft 通过领导者选举与日志复制保证状态机一致性。"),
                BookChapter(title: "第 2 章 存储引擎", text: "LSM-Tree 与 B+Tree 在写放大与点查延迟上有本质权衡。")
            ]
        ))
        ctx.insert(BookVolume(id: book.id, title: book.title, chapterTitles: book.chapterTitles, manuscript: book.data))
        try ctx.save()

        let card = StudyFlashcard(
            deckName: "系统设计",
            front: "什么是 RRF 倒数排名融合？",
            back: "Reciprocal Rank Fusion 通过 1/(k+rank) 合并词法 BM25 与向量检索排序。"
        )

        let search = ConversationHistorySearch(index: FullTextSearchIndex(databaseURL: nil))

        // 1. Multi-term out-of-order Chinese + English match across message body.
        let multiTerm = try await search.searchAll(
            for: HistorySearchQuery(text: "Swift 方案 迁移"),
            in: container,
            flashcards: [card]
        )
        XCTAssertEqual(multiTerm.conversations.map(\.id), [chat1.id])
        XCTAssertEqual(multiTerm.conversations.first?.hits.map(\.id), [msg1.id])
        XCTAssertEqual(multiTerm.conversations.first?.hits.first?.matchedField, .content)

        // 2. Reasoning-only keyword matches when includeReasoning is true, excluded when false.
        let reasoningOn = try await search.searchAll(
            for: HistorySearchQuery(text: "外置大字段", includeReasoning: true),
            in: container,
            flashcards: [card]
        )
        XCTAssertEqual(reasoningOn.conversations.first?.hits.first?.matchedField, .reasoning)

        let reasoningOff = try await search.searchAll(
            for: HistorySearchQuery(text: "外置大字段", includeReasoning: false),
            in: container,
            flashcards: [card]
        )
        XCTAssertTrue(reasoningOff.conversations.isEmpty)

        // 3. Title-only match must NOT spuriously emit unrelated message hits.
        let titleOnly = try await search.searchAll(
            for: HistorySearchQuery(text: "量子计算"),
            in: container,
            flashcards: [card]
        )
        XCTAssertEqual(titleOnly.conversations.count, 1)
        XCTAssertTrue(titleOnly.conversations[0].matchesDetails)
        XCTAssertTrue(titleOnly.conversations[0].hits.isEmpty)

        // 4. Cross-entity search matches bookshelf chapters and flashcards!
        let bookRes = try await search.searchAll(
            for: HistorySearchQuery(text: "Raft 状态机", scope: .books),
            in: container,
            flashcards: [card]
        )
        XCTAssertEqual(bookRes.books.count, 1)
        XCTAssertEqual(bookRes.books[0].volumeID, book.id)
        XCTAssertEqual(bookRes.books[0].chapterIndex, 0)
        XCTAssertTrue(bookRes.conversations.isEmpty)

        let cardRes = try await search.searchAll(
            for: HistorySearchQuery(text: "BM25 融合", scope: .flashcards),
            in: container,
            flashcards: [card]
        )
        XCTAssertEqual(cardRes.flashcards.count, 1)
        XCTAssertEqual(cardRes.flashcards[0].id, card.id)

        // 5. Equal-length edit is picked up on incremental sync.
        msg2.content = "帮我总结今天的滑雪装备。"
        try ctx.save()
        let editedRes = try await search.searchAll(
            for: HistorySearchQuery(text: "滑雪装备"),
            in: container,
            flashcards: [card]
        )
        XCTAssertEqual(editedRes.conversations.map(\.id), [chat2.id])
    }

    // MARK: - Pillar 3: Persistent Hybrid RAG, RRF & EmbeddingClient

    func testRAGHybridRankerFuseRRFRewardsDualChannelConsensus() {
        let scores = RAGHybridRanker.fuseRRF(
            lexicalRankedIDs: ["chunk-lex-only", "chunk-both"],
            semanticRankedIDs: ["chunk-sem-only", "chunk-both"],
            k: 60,
            lexicalWeight: 1.0,
            semanticWeight: 1.0
        )
        XCTAssertGreaterThan(scores["chunk-both"] ?? 0, scores["chunk-lex-only"] ?? 0)
        XCTAssertGreaterThan(scores["chunk-both"] ?? 0, scores["chunk-sem-only"] ?? 0)
    }

    func testEmbeddingEndpointResolutionAndClientOpenAIAndGemini() async throws {
        // Endpoint resolution tests
        let openAIURL = try EndpointResolver.embeddingsEndpoint(baseURL: "https://api.openai.com/v1/chat/completions", protocolType: .openAICompatible)
        XCTAssertEqual(openAIURL.absoluteString, "https://api.openai.com/v1/embeddings")

        let rawURL = try EndpointResolver.embeddingsEndpoint(baseURL: "https://gw.example.com/custom#", protocolType: .openAICompatible)
        XCTAssertEqual(rawURL.absoluteString, "https://gw.example.com/custom/embeddings")

        let geminiURL = try EndpointResolver.embeddingsEndpoint(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            protocolType: .gemini,
            modelID: "text-embedding-004"
        )
        XCTAssertEqual(
            geminiURL.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/text-embedding-004:batchEmbedContents"
        )

        XCTAssertThrowsError(try EndpointResolver.embeddingsEndpoint(baseURL: "https://api.anthropic.com/v1", protocolType: .anthropic))

        // Mock OpenAI embeddings response (out-of-order indices must be sorted & L2-normalized)
        let session = makeMockSession()
        CoreUpgradeMockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/v1/embeddings")
            let body = #"{"data":[{"index":1,"embedding":[0,3,4]},{"index":0,"embedding":[3,4,0]}]}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data(body.utf8))
        }
        let openAIConfig = EmbeddingConfig(
            providerID: UUID(),
            providerName: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            extraKeys: [],
            customHeaders: [],
            modelID: "text-embedding-3-small"
        )
        try authorize(openAIConfig)
        let oaiVecs = try await EmbeddingClient.embed(texts: ["first", "second"], config: openAIConfig, session: session)
        XCTAssertEqual(oaiVecs.count, 2)
        XCTAssertEqual(oaiVecs[0][0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(oaiVecs[0][1], 0.8, accuracy: 0.0001)
        XCTAssertEqual(oaiVecs[1][1], 0.6, accuracy: 0.0001)
        XCTAssertEqual(oaiVecs[1][2], 0.8, accuracy: 0.0001)

        // Mock Gemini batchEmbedContents response
        CoreUpgradeMockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.absoluteString.contains(":batchEmbedContents") == true)
            let body = #"{"embeddings":[{"values":[1,0,0]}]}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data(body.utf8))
        }
        let geminiConfig = EmbeddingConfig(
            providerID: UUID(),
            providerName: "Gemini",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "gm-test",
            extraKeys: [],
            customHeaders: [],
            modelID: "text-embedding-004"
        )
        try authorize(geminiConfig)
        let gemVecs = try await EmbeddingClient.embed(texts: ["hello"], config: geminiConfig, session: session)
        XCTAssertEqual(gemVecs.first, [1, 0, 0])
    }

    func testPersistentHybridRAGPersistsVectorsFusesSemanticsAndDegradesGracefully() async throws {
        let storage = FullTextSearchIndex(databaseURL: nil)
        let rag = ProjectKnowledgeSearch(storage: storage)

        let prepared = try PreparedBook(BookManuscript(
            title: "企业财务与研发规范",
            chapters: [
                BookChapter(title: "第一章 固定资产", text: "大型服务器设备按五年直线法计提折旧，残值率为百分之五。"),
                BookChapter(title: "第二章 故障代码", text: "型号 XK-9042 在供电电压低于 4.75V 时触发保护重启。"),
                BookChapter(title: "第三章 差旅标准", text: "跨省出差高铁二等座据实报销，住宿标准按城市分级执行。")
            ]
        ))
        let snapshot = KnowledgeDocumentSnapshot(id: prepared.id, title: prepared.title, manuscript: prepared.data)

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var callCount = 0
        }
        let counter = Counter()
        let session = makeMockSession()

        // Semantic embedding stub: map "折旧" and synonym query "资产减值摊销" to [1, 0, 0]; others orthogonal.
        CoreUpgradeMockURLProtocol.handler = { req in
            counter.lock.withLock { counter.callCount += 1 }
            let json = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            let inputs = (json["input"] as? [String]) ?? []
            var rows: [[String: Any]] = []
            for (idx, text) in inputs.enumerated() {
                let vec: [Double]
                if text.contains("折旧") || text.contains("摊销") || text.contains("资产减值") {
                    vec = [1.0, 0.0, 0.0]
                } else if text.contains("XK-9042") || text.contains("电压") {
                    vec = [0.0, 1.0, 0.0]
                } else {
                    vec = [0.0, 0.0, 1.0]
                }
                rows.append(["index": idx, "embedding": vec])
            }
            let data = try JSONSerialization.data(withJSONObject: ["data": rows])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, data)
        }

        let embedConfig = EmbeddingConfig(
            providerID: UUID(),
            providerName: "TestEmbed",
            protocolType: .openAICompatible,
            baseURL: "https://embed.example.test/v1",
            apiKey: "test-key",
            extraKeys: [],
            customHeaders: [],
            modelID: "bge-m3"
        )
        try authorize(embedConfig)

        // Query has ZERO lexical overlap with "大型服务器设备按五年直线法计提折旧", yet vector channel finds Chapter 1!
        let evidence1 = try await rag.retrieve(
            from: [snapshot],
            query: "服务器资产减值摊销年限是多少？",
            maxPassages: 2,
            embeddingConfig: embedConfig,
            embeddingSession: session
        )
        XCTAssertEqual(evidence1.passages.first?.sectionTitle, "第一章 固定资产")
        let callsAfterFirst = counter.lock.withLock { counter.callCount }
        XCTAssertEqual(callsAfterFirst, 2, "1 batch for chunks + 1 for query")

        // Verify persisted chunks & vectors in SQLite!
        let stats = await storage.stats()
        XCTAssertEqual(stats.ragVolumeCount, 1)
        XCTAssertEqual(stats.ragChunkCount, 3)
        XCTAssertEqual(stats.ragEmbeddedChunkCount, 3)

        // Second query must NOT re-embed chunks (only 1 call for query vector!).
        _ = try await rag.retrieve(
            from: [KnowledgeDocumentSnapshot(id: prepared.id, title: prepared.title, manuscript: nil)],
            query: "资产减值摊销",
            maxPassages: 1,
            embeddingConfig: embedConfig,
            embeddingSession: session
        )
        let callsAfterSecond = counter.lock.withLock { counter.callCount }
        XCTAssertEqual(callsAfterSecond, callsAfterFirst + 1, "Persisted chunk vectors must be reused without re-calling API")

        // Strict alphanumeric identifier precision guard stays intact.
        let codeEvidence = try await rag.retrieve(
            from: [snapshot],
            query: "XK-9042 为什么会重启",
            maxPassages: 2
        )
        XCTAssertEqual(codeEvidence.passages.count, 1)
        XCTAssertEqual(codeEvidence.passages.first?.sectionTitle, "第二章 故障代码")

        // Graceful fallback when Embedding API errors (HTTP 500): lexical FTS5 still succeeds!
        CoreUpgradeMockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!, Data("err".utf8))
        }
        let fallbackEvidence = try await rag.retrieve(
            from: [snapshot],
            query: "高铁二等座报销标准",
            maxPassages: 2,
            embeddingConfig: embedConfig,
            embeddingSession: session
        )
        XCTAssertEqual(fallbackEvidence.passages.first?.sectionTitle, "第三章 差旅标准")
    }

    func testEmbeddingRequiresSeparateConsentForTheExactEndpointAndStopsAfterRevocation() async throws {
        let session = makeMockSession()
        let providerID = UUID()
        let consentDefaults = UserDefaults.standard
        consentDefaults.removeObject(forKey: EmbeddingConsent.key)
        let config = EmbeddingConfig(
            providerID: providerID, providerName: "Gateway", protocolType: .openAICompatible,
            baseURL: "https://embed.example.test/account-a/v1", apiKey: "test-key",
            extraKeys: [], customHeaders: [], modelID: "bge-m3"
        )
        let moved = EmbeddingConfig(
            providerID: providerID, providerName: "Gateway", protocolType: .openAICompatible,
            baseURL: "https://embed.example.test/account-b/v1", apiKey: "test-key",
            extraKeys: [], customHeaders: [], modelID: "bge-m3"
        )
        CoreUpgradeMockURLProtocol.handler = { _ in
            XCTFail("No request should leave the device without matching consent")
            throw URLError(.cancelled)
        }

        do {
            _ = try await EmbeddingClient.embed(texts: ["Private query"], config: config, session: session)
            XCTFail("Expected consent to be required")
        } catch EmbeddingClientError.consentRequired {}

        try authorize(config)
        XCTAssertTrue(EmbeddingConsent.allows(config))
        XCTAssertFalse(EmbeddingConsent.allows(moved))
        do {
            _ = try await EmbeddingClient.embed(texts: ["Private query"], config: moved, session: session)
            XCTFail("Expected consent for the new endpoint")
        } catch EmbeddingClientError.consentRequired {}

        let firstBatch = expectation(description: "Only the first batch is sent")
        firstBatch.assertForOverFulfill = true
        CoreUpgradeMockURLProtocol.handler = { request in
            firstBatch.fulfill()
            XCTAssertEqual(request.url?.path, "/account-a/v1/embeddings")
            UserDefaults.standard.removeObject(forKey: EmbeddingConsent.key)
            let rows: [[String: Any]] = (0..<EmbeddingClient.maxBatchSize).map { ["index": $0, "embedding": [1, 0, 0]] }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: ["data": rows]))
        }
        do {
            _ = try await EmbeddingClient.embed(texts: Array(repeating: "Private text", count: EmbeddingClient.maxBatchSize + 1),
                                                config: config, session: session)
            XCTFail("Expected revocation to stop the remaining batch")
        } catch EmbeddingClientError.consentRequired {}
        await fulfillment(of: [firstBatch], timeout: 1)
        XCTAssertFalse(EmbeddingConsent.allows(config))
    }
}
