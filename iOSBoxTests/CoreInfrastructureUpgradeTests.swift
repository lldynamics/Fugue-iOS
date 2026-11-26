import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class CoreInfrastructureUpgradeTests: XCTestCase {
    private var containers: [ModelContainer] = []

    override func tearDown() {
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

    // MARK: - Pillar 1: Sync Tombstones

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

        for ctx in [deviceA.mainContext, deviceB.mainContext] {
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
        }

        let deleteTime = baseTime.addingTimeInterval(120)

        // Device A deletes c1, c2, mem, and book at deleteTime.
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

        tombstonesA.recordDeletion(kind: .conversation, id: convDeleteID, at: deleteTime)
        tombstonesA.recordDeletion(kind: .conversation, id: convEditedLaterID, at: deleteTime)
        tombstonesA.recordDeletion(kind: .memory, id: memDeleteID, at: deleteTime)
        tombstonesA.recordDeletion(kind: .book, id: preparedBook.id, at: deleteTime)

        // Meanwhile Device B edited convEditedLaterID AFTER deleteTime -> newer edit must win!
        if let editedConv = try deviceB.mainContext.fetch(FetchDescriptor<Conversation>()).first(where: { $0.id == convEditedLaterID }) {
            editedConv.title = "编辑后保留的对话"
            editedConv.updatedAt = deleteTime.addingTimeInterval(60)
            try deviceB.mainContext.save()
        }

        // Export from Device A with tombstones and sync-apply onto Device B.
        let archiveFromA = try BackupService.makeArchive(
            context: deviceA.mainContext,
            knowledgeStore: kbA,
            tombstoneStore: tombstonesA
        )
        XCTAssertEqual(archiveFromA.tombstones?.count, 4)

        let summaryB = try BackupService.apply(
            .full(archiveFromA),
            to: deviceB.mainContext,
            knowledgeStore: kbB,
            tombstonePolicy: .enforce(tombstonesB)
        )
        XCTAssertEqual(summaryB.deleted, 3, "c1, mem, book should be deleted; c2 survived because edited later")

        let remainingChatsB = try deviceB.mainContext.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(remainingChatsB.map(\.id), [convEditedLaterID])
        XCTAssertTrue(try deviceB.mainContext.fetch(FetchDescriptor<PersonalMemory>()).isEmpty)
        XCTAssertTrue(try deviceB.mainContext.fetch(FetchDescriptor<BookVolume>()).isEmpty)
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
            knowledgeStore: kbB,
            tombstonePolicy: .ignore
        )
        XCTAssertEqual(manualSummary.conversations, 1)
        XCTAssertEqual(try deviceB.mainContext.fetchCount(FetchDescriptor<Conversation>()), 2)
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

        let search = ConversationHistorySearch(index: FullTextSearchIndex(databaseURL: nil))

        // 1. Multi-term out-of-order Chinese + English match across message body.
        let multiTerm = try await search.searchAll(
            for: HistorySearchQuery(text: "Swift 方案 迁移"),
            in: container
        )
        XCTAssertEqual(multiTerm.conversations.map(\.id), [chat1.id])
        XCTAssertEqual(multiTerm.conversations.first?.hits.map(\.id), [msg1.id])
        XCTAssertEqual(multiTerm.conversations.first?.hits.first?.matchedField, .content)

        // 2. Reasoning-only keyword matches when includeReasoning is true, excluded when false.
        let reasoningOn = try await search.searchAll(
            for: HistorySearchQuery(text: "外置大字段", includeReasoning: true),
            in: container
        )
        XCTAssertEqual(reasoningOn.conversations.first?.hits.first?.matchedField, .reasoning)

        let reasoningOff = try await search.searchAll(
            for: HistorySearchQuery(text: "外置大字段", includeReasoning: false),
            in: container
        )
        XCTAssertTrue(reasoningOff.conversations.isEmpty)

        // 3. Title-only match must NOT spuriously emit unrelated message hits.
        let titleOnly = try await search.searchAll(
            for: HistorySearchQuery(text: "量子计算"),
            in: container
        )
        XCTAssertEqual(titleOnly.conversations.count, 1)
        XCTAssertTrue(titleOnly.conversations[0].matchesDetails)
        XCTAssertTrue(titleOnly.conversations[0].hits.isEmpty)

        // 4. Cross-entity search matches bookshelf chapters!
        let bookRes = try await search.searchAll(
            for: HistorySearchQuery(text: "Raft 状态机", scope: .books),
            in: container
        )
        XCTAssertEqual(bookRes.books.count, 1)
        XCTAssertEqual(bookRes.books[0].volumeID, book.id)
        XCTAssertEqual(bookRes.books[0].chapterIndex, 0)
        XCTAssertTrue(bookRes.conversations.isEmpty)

        // 5. Equal-length edit is picked up on incremental sync.
        msg2.content = "帮我总结今天的滑雪装备。"
        try ctx.save()
        let editedRes = try await search.searchAll(
            for: HistorySearchQuery(text: "滑雪装备"),
            in: container
        )
        XCTAssertEqual(editedRes.conversations.map(\.id), [chat2.id])
    }

    // MARK: - Pillar 3: Persistent SQLite FTS5 RAG

    func testPersistentFTS5RAGPersistsChunksAndMatchesLexicalQueries() async throws {
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

        let evidence1 = try await rag.retrieve(
            from: [snapshot],
            query: "服务器设备按直线法计提折旧年限是多少？",
            maxPassages: 2
        )
        XCTAssertEqual(evidence1.passages.first?.sectionTitle, "第一章 固定资产")

        // Verify persisted chunks in SQLite!
        let stats = await storage.stats()
        XCTAssertEqual(stats.ragVolumeCount, 1)
        XCTAssertEqual(stats.ragChunkCount, 3)

        // Second query reuses persisted chunks without passing manuscript bytes again.
        let cachedEvidence = try await rag.retrieve(
            from: [KnowledgeDocumentSnapshot(id: prepared.id, title: prepared.title, manuscript: nil)],
            query: "高铁二等座报销标准",
            maxPassages: 2
        )
        XCTAssertEqual(cachedEvidence.passages.first?.sectionTitle, "第三章 差旅标准")

        // Strict alphanumeric identifier precision guard stays intact.
        let codeEvidence = try await rag.retrieve(
            from: [snapshot],
            query: "XK-9042 为什么会重启",
            maxPassages: 2
        )
        XCTAssertEqual(codeEvidence.passages.count, 1)
        XCTAssertEqual(codeEvidence.passages.first?.sectionTitle, "第二章 故障代码")
    }
}
