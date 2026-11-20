import AVFoundation
import Foundation
import PDFKit
import SwiftData
import UIKit
import XCTest
@testable import iOSBox

private struct ByteArraySequence: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]
    func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes) }
    struct Iterator: AsyncIteratorProtocol {
        let bytes: [UInt8]
        var index = 0
        mutating func next() async throws -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class AuditFixesTests: XCTestCase {
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    func testFrozenSchemaV5AndV6AreDistinctAndMigrateToV7() throws {
        XCTAssertFalse(SchemaV5.models.contains { $0 == Conversation.self }, "SchemaV5 must use frozen model snapshots")
        XCTAssertFalse(SchemaV6.models.contains { $0 == Conversation.self }, "SchemaV6 must use frozen model snapshots")
        XCTAssertTrue(SchemaV7.models.contains { $0 == Conversation.self })
        XCTAssertTrue(SchemaV7.models.contains { $0 == BookVolume.self })

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v5-freeze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("iosbox.store")

        let chatID = UUID()
        let memID = UUID()
        do {
            let v5Schema = Schema(versionedSchema: SchemaV5.self)
            let db = try ModelContainer(for: v5Schema, configurations: [ModelConfiguration(schema: v5Schema, url: storeURL)])
            let chat = SchemaV5.Conversation(id: chatID, title: "冻结 V5 迁移测试", folderTag: "工作")
            let msg = SchemaV5.ChatMessage(role: .user, content: "Hello V5", sortIndex: 0)
            msg.conversation = chat
            chat.messages.append(msg)
            db.mainContext.insert(chat)
            db.mainContext.insert(msg)
            db.mainContext.insert(SchemaV5.PersonalMemory(id: memID, content: "偏好 Swift"))
            try db.mainContext.save()
        }

        let currentSchema = Schema(versionedSchema: CurrentSchema.self)
        let migrated = try PersistenceController.open(
            schema: currentSchema,
            configuration: ModelConfiguration(schema: currentSchema, url: storeURL)
        )
        let chats = try migrated.mainContext.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(chats.first?.id, chatID)
        XCTAssertEqual(chats.first?.folderTag, "工作")
        XCTAssertEqual(chats.first?.messages.first?.content, "Hello V5")
        let memories = try migrated.mainContext.fetch(FetchDescriptor<PersonalMemory>())
        XCTAssertEqual(memories.first?.id, memID)
    }

    func testBackupRoundTripIncludesFlashcardsKnowledgeBindingsConversationParamsAndXToken() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcFlashcards = FlashcardStore(fileURL: dir.appendingPathComponent("src-cards.json"))
        let dstFlashcards = FlashcardStore(fileURL: dir.appendingPathComponent("dst-cards.json"))
        let srcKnowledge = PresetKnowledgeStore(fileURL: dir.appendingPathComponent("src-kb.json"))
        let dstKnowledge = PresetKnowledgeStore(fileURL: dir.appendingPathComponent("dst-kb.json"))

        let srcContainer = try makeInMemoryContainer()
        let srcCtx = srcContainer.mainContext

        let preset = AssistantPreset(name: "知识助手", systemPrompt: "回答基于文档")
        let boundBookID = UUID()
        srcKnowledge.setVolumeIDs([boundBookID], for: preset.id)
        srcCtx.insert(preset)

        let card = try XCTUnwrap(srcFlashcards.addCard(
            deckName: "Swift 并发",
            front: "Actor 隔离是什么？",
            back: "保护可变状态避免数据竞争。"
        ))
        try srcFlashcards.recordReview(cardID: card.id, rating: .good)
        let expectedInterval = try XCTUnwrap(srcFlashcards.cards.first { $0.id == card.id }?.intervalDays)

        let targetA = ResolvedModelTarget(
            providerID: UUID(), providerName: "P1", protocolType: .openAICompatible,
            modelID: "m-old", modelDisplayName: "Old", accentHex: "#111111", supportsVision: false, supportsReasoning: false
        )
        let targetB = ResolvedModelTarget(
            providerID: UUID(), providerName: "P2", protocolType: .anthropic,
            modelID: "m-new", modelDisplayName: "New", accentHex: "#222222", supportsVision: true, supportsReasoning: true
        )
        let convID = UUID()
        let newerConv = Conversation(
            id: convID, title: "新版标题", temperature: 0.25, useCustomTemperature: false,
            topP: 0.85, maxOutputTokens: 2048, contextMessageLimit: 40,
            enableThinking: false, thinkingBudgetTokens: 8192, isArenaMode: false,
            primaryTarget: targetB, arenaTargets: [targetA, targetB]
        )
        newerConv.updatedAt = Date(timeIntervalSince1970: 2_000_000)
        srcCtx.insert(newerConv)
        try srcCtx.save()

        let previousXToken = KeychainService.shared.loadSecret(account: PersonaFeedReader.xTokenAccount)
        defer {
            if previousXToken.isEmpty {
                KeychainService.shared.deleteSecret(account: PersonaFeedReader.xTokenAccount)
            } else {
                _ = KeychainService.shared.saveSecret(previousXToken, account: PersonaFeedReader.xTokenAccount)
            }
        }
        XCTAssertTrue(KeychainService.shared.saveSecret("x-bearer-secret-999", account: PersonaFeedReader.xTokenAccount))

        let encryptedData = try EncryptedBackupService.exportEncryptedData(
            context: srcCtx,
            password: "Audit-Pass-2026!",
            flashcardStore: srcFlashcards,
            knowledgeStore: srcKnowledge
        )
        XCTAssertTrue(EncryptedBackupService.isEncryptedBackup(encryptedData))
        XCTAssertFalse(EncryptedBackupService.isEncryptedBackup(Data(#"{"formatVersion":6}"#.utf8)))

        KeychainService.shared.deleteSecret(account: PersonaFeedReader.xTokenAccount)
        XCTAssertEqual(KeychainService.shared.loadSecret(account: PersonaFeedReader.xTokenAccount), "")

        let dstContainer = try makeInMemoryContainer()
        let dstCtx = dstContainer.mainContext
        let olderConv = Conversation(
            id: convID, title: "旧版标题", temperature: 0.9, useCustomTemperature: true,
            topP: 1.0, maxOutputTokens: 0, contextMessageLimit: 10,
            enableThinking: true, thinkingBudgetTokens: 1024, primaryTarget: targetA
        )
        olderConv.updatedAt = Date(timeIntervalSince1970: 1_000_000)
        dstCtx.insert(olderConv)
        try dstCtx.save()

        let summary = try await EncryptedBackupService.decryptAndApplyAsync(
            data: encryptedData,
            password: "Audit-Pass-2026!",
            to: dstCtx,
            flashcardStore: dstFlashcards,
            knowledgeStore: dstKnowledge
        )
        XCTAssertEqual(summary.flashcards, 1)
        XCTAssertEqual(dstFlashcards.cards.first?.id, card.id)
        XCTAssertEqual(try XCTUnwrap(dstFlashcards.cards.first?.intervalDays), expectedInterval, accuracy: 0.01)
        XCTAssertEqual(dstKnowledge.volumeIDs(for: preset.id), [boundBookID])
        XCTAssertEqual(KeychainService.shared.loadSecret(account: PersonaFeedReader.xTokenAccount), "x-bearer-secret-999")

        // Verify newer conversation parameters merged onto existing conversation
        XCTAssertEqual(olderConv.title, "新版标题")
        XCTAssertEqual(olderConv.temperature, 0.25, accuracy: 0.001)
        XCTAssertFalse(olderConv.useCustomTemperature)
        XCTAssertEqual(olderConv.topP, 0.85, accuracy: 0.001)
        XCTAssertEqual(olderConv.maxOutputTokens, 2048)
        XCTAssertEqual(olderConv.contextMessageLimit, 40)
        XCTAssertFalse(olderConv.enableThinking)
        XCTAssertEqual(olderConv.thinkingBudgetTokens, 8192)
        XCTAssertEqual(olderConv.primaryTarget?.modelID, "m-new")
        XCTAssertEqual(olderConv.arenaTargets.count, 2)
    }

    func testGroupWebSearchFailureIsFailClosed() async throws {
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext
        let provider = ProviderConfig(
            name: "Local", protocolType: .openAICompatible,
            baseURL: "http://localhost:11434/v1", models: [ModelSpec(id: "m1")]
        )
        ctx.insert(provider)
        let target = provider.makeTarget(for: provider.models[0])
        let chat = Conversation(title: "圆桌搜索测试", primaryTarget: target)
        chat.isGroupMode = true
        chat.groupMembers = [
            GroupMember(name: "甲", title: "分析", avatarEmoji: "🦊", accentHex: "#3F6EF6", rolePrompt: "分析问题", target: target),
            GroupMember(name: "乙", title: "反方", avatarEmoji: "🦉", accentHex: "#E85D75", rolePrompt: "提出质疑", target: target)
        ]
        ctx.insert(chat)
        try ctx.save()

        let modelCalls = LockedInt()
        let engine = ChatEngine(
            search: { _ in throw SearchError.http(429) },
            stream: { _ in
                modelCalls.increment()
                return AsyncThrowingStream { c in
                    c.yield(.contentDelta("不应该出现"))
                    c.yield(.done)
                    c.finish()
                }
            }
        )

        let outcome = engine.sendUserMessage(
            text: "今天的新闻是什么？",
            attachments: [],
            in: chat,
            providers: [provider],
            context: ctx,
            options: GenerationOptions(searchQuery: "今日科技新闻")
        )
        XCTAssertEqual(outcome, .sent)
        let deadline = ContinuousClock.now + .seconds(3)
        while engine.isGenerating(in: chat.id) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(modelCalls.get(), 0, "Group models must not start when explicit web search fails")
        let searchRecords = try ctx.fetch(FetchDescriptor<RequestRecord>()).filter { $0.kind == .webSearch }
        XCTAssertEqual(searchRecords.count, 1)
        XCTAssertEqual(searchRecords.first?.status, .failed)
        XCTAssertEqual(searchRecords.first?.httpStatus, 429)

        let errReply = try XCTUnwrap(chat.sortedMessages.last { $0.role == .assistant })
        XCTAssertNotNil(errReply.errorMessage)
        XCTAssertEqual(errReply.assistanceMetadata.requestedSearchQuery, "今日科技新闻")
    }

    func testSSEDecoderAllowsCustomLargerLimitForGeminiImages() async throws {
        let payload = String(repeating: "A", count: 2_500_000)
        let raw = Array(("data: " + payload + "\n\n").utf8)

        // Default 2 MB limit rejects it
        do {
            for try await _ in SSEDecoder.events(ByteArraySequence(bytes: raw)) { }
            XCTFail("Expected default 2 MB SSE limit to reject 2.5 MB event")
        } catch {
            XCTAssertTrue(error is LLMError)
        }

        // Raised limit (as used by GeminiAdapter for inlineData images) accepts it
        var received: [String] = []
        for try await event in SSEDecoder.events(ByteArraySequence(bytes: raw), maximumBytes: 5 * 1024 * 1024) {
            received.append(event)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].count, 2_500_000)
    }

    func testAnkiTSVEscapesHTMLAndMermaidSequenceHandlesAliases() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("anki-escape-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = FlashcardStore(fileURL: tempURL)
        _ = try store.addCard(
            deckName: "Generics",
            front: "What is Array<String> & Set<Int>?",
            back: "Line 1: a < b\nLine 2: c > d"
        )
        let tsv = store.exportAnkiTSV()
        XCTAssertTrue(tsv.contains("Array&lt;String&gt; &amp; Set&lt;Int&gt;"))
        XCTAssertTrue(tsv.contains("Line 1: a &lt; b<br>Line 2: c &gt; d"))

        let doc = ArtifactDocumentBuilder.htmlDocument(
            language: "mermaid",
            code: "sequenceDiagram\nparticipant A as Alice\nparticipant B as Bob\nA->>B: Hello"
        )
        XCTAssertTrue(doc.contains("actorLabels"))
        XCTAssertTrue(doc.contains("participant|actor"))
    }

    func testAttachmentProcessorRejectsBinaryFilesWithNULBytes() throws {
        let binURL = FileManager.default.temporaryDirectory.appendingPathComponent("sample-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: binURL) }
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x14, 0x00, 0xFF]).write(to: binURL)

        XCTAssertThrowsError(try AttachmentProcessor.processFileURL(binURL)) { error in
            guard case AttachmentError.unsupportedBinary = error else {
                return XCTFail("Expected AttachmentError.unsupportedBinary, got \(error)")
            }
        }
    }

    func testAcceptMemoryProposalPreservesProposalWhenAtCapacity() throws {
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext
        for i in 0..<PersonalMemory.maximumCount {
            ctx.insert(PersonalMemory(content: "Existing memory \(i)"))
        }
        let msg = ChatMessage(role: .assistant, content: "Noted")
        var meta = AssistanceMetadata()
        meta.proposedMemories = ["Brand new preference"]
        msg.assistanceMetadata = meta
        ctx.insert(msg)
        try ctx.save()

        let accepted = ChatEngine.shared.acceptMemoryProposal("Brand new preference", on: msg, context: ctx)
        XCTAssertFalse(accepted)
        XCTAssertEqual(msg.assistanceMetadata.proposedMemories, ["Brand new preference"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PersonalMemory>()), PersonalMemory.maximumCount)
    }

    func testSpotlightRemovesUnbookmarkedMessageAndBranchSiblingsMapMatches() throws {
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext
        let chat = Conversation(title: "分支与书签测试")
        ctx.insert(chat)

        let u1 = ChatMessage(role: .user, content: "问题 A", sortIndex: 0)
        u1.parentMessageID = ConversationTree.virtualRootID
        let u2 = ChatMessage(role: .user, content: "问题 B", sortIndex: 1)
        u2.parentMessageID = ConversationTree.virtualRootID
        let a2 = ChatMessage(role: .assistant, content: "收藏的回答内容", sortIndex: 2)
        a2.parentMessageID = u2.id
        for m in [u1, u2, a2] {
            m.conversation = chat
            chat.messages.append(m)
            ctx.insert(m)
        }
        chat.activeLeafMessageID = a2.id
        try ctx.save()

        let siblingsMap = ConversationTree.branchSiblingsMap(in: chat)
        XCTAssertEqual(siblingsMap[u1.id]?.map(\.id), [u1.id, u2.id])
        XCTAssertEqual(siblingsMap[u2.id]?.map(\.id), [u1.id, u2.id])
        XCTAssertNil(siblingsMap[a2.id])

        // Spotlight defaults to disabled for privacy; opt in explicitly for indexing assertions
        let msgKey = SpotlightIndexService.makeIdentifier(conversationID: chat.id, messageID: a2.id)
        SpotlightIndexService.shared.setEnabled(false)
        ChatEngine.shared.toggleBookmark(for: a2, context: ctx)
        XCTAssertNil(SpotlightIndexService.shared.recentIndexedEntries[msgKey], "Opt-out Spotlight must not index bookmarks")
        ChatEngine.shared.toggleBookmark(for: a2, context: ctx)

        SpotlightIndexService.shared.setEnabled(true)
        defer { SpotlightIndexService.shared.setEnabled(false) }

        // Bookmark -> indexed; un-bookmark -> removed from Spotlight snapshot
        ChatEngine.shared.toggleBookmark(for: a2, context: ctx)
        XCTAssertNotNil(SpotlightIndexService.shared.recentIndexedEntries[msgKey])

        ChatEngine.shared.toggleBookmark(for: a2, context: ctx)
        XCTAssertNil(SpotlightIndexService.shared.recentIndexedEntries[msgKey])
        SpotlightIndexService.shared.removeConversation(id: chat.id)
    }

    func testNetworkLocationAndURLReaderBlockAlternateIPv4AndIPv6LinkLocal() {
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "localhost."))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "127.1"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "0177.0.0.1"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "0x7f.0.0.1"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "2130706433"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "fe90::1"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "febf::1234"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "0:0:0:0:0:0:0:1"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "0:0:0:0:0:ffff:127.0.0.1"))
        XCTAssertTrue(NetworkLocation.isLocalOrPrivate(host: "fe80::1%en0"))
        XCTAssertFalse(NetworkLocation.isLocalOrPrivate(host: "api.openai.com"))
        XCTAssertFalse(NetworkLocation.isLocalOrPrivate(host: "1.1.1.1"))
        XCTAssertFalse(NetworkLocation.isLocalOrPrivate(host: "2001:4860:4860::8888"))

        for unsafe in [
            "https://0x7f.0.0.1/secret",
            "https://0177.0.0.1/secret",
            "https://127.1/secret",
            "https://localhost./secret",
            "https://[fe90::1]/secret",
            "https://[0:0:0:0:0:0:0:1]/secret",
            "https://.../secret"
        ] {
            if let url = URL(string: unsafe) {
                XCTAssertThrowsError(try URLReader.validate(url), "Should reject \(unsafe)")
            }
        }
    }

    func testSpeechServiceStaleUtteranceCallbackDoesNotClearNewPlayback() {
        let speech = SpeechService.shared
        let firstID = UUID()
        let secondID = UUID()
        let staleUtterance = AVSpeechUtterance(string: "old")

        speech.toggleSpeaking(messageID: firstID, text: "First message")
        speech.toggleSpeaking(messageID: secondID, text: "Second message")
        XCTAssertEqual(speech.speakingMessageID, secondID)

        // Simulating delayed didCancel callback from a previous utterance must not clear active secondID
        speech.handleUtteranceEnded(ObjectIdentifier(staleUtterance))
        XCTAssertEqual(speech.speakingMessageID, secondID)

        speech.stopSpeaking()
        XCTAssertNil(speech.speakingMessageID)
    }

    func testStudyGeneratorHandlesRetryAndExtraAPIKeys() async throws {
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext
        let provider = ProviderConfig(
            name: "Local", protocolType: .openAICompatible,
            baseURL: "http://localhost:11434/v1", models: [ModelSpec(id: "study-m")]
        )
        ctx.insert(provider)
        try ctx.save()

        let providerID = provider.id
        defer {
            KeychainService.shared.deleteAPIKey(for: providerID)
            ProviderConnectionSettingsStore.shared.setIdleTimeoutSeconds(0, for: providerID)
        }
        XCTAssertTrue(KeychainService.shared.saveExtraAPIKeys(["sk-backup-1"], for: providerID))
        ProviderConnectionSettingsStore.shared.setIdleTimeoutSeconds(75, for: providerID)

        let capturedReq = LockedBox<LLMChatRequest?>(nil)
        let cards = try await StudyGeneratorService.requestFlashcards(
            sourceText: "Swift Concurrency uses structured tasks and actors.",
            target: provider.makeTarget(for: provider.models[0]),
            provider: provider,
            spec: provider.models[0],
            conversationID: UUID(),
            messageID: UUID(),
            context: ctx,
            stream: { req in
                capturedReq.set(req)
                return AsyncThrowingStream { cont in
                    cont.yield(.contentDelta("corrupted partial"))
                    cont.yield(.retrying(httpStatus: 429))
                    cont.yield(.contentDelta(#"{"cards":[{"front":"Q1","back":"A1"}]}"#))
                    cont.yield(.usage(promptTokens: 10, completionTokens: 12))
                    cont.yield(.done)
                    cont.finish()
                }
            }
        )

        XCTAssertEqual(capturedReq.get()?.apiKeys, ["sk-backup-1"])
        XCTAssertEqual(capturedReq.get()?.idleTimeoutSeconds, 75)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.front, "Q1")

        let records = try ctx.fetch(FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.attempt)]))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.status), [.failed, .succeeded])
        XCTAssertEqual(records.first?.httpStatus, 429)
    }

    func testTemporaryExportCleanerRemovesOnlyExpiredManagedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tmp-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldBackup = dir.appendingPathComponent("Fugue_Backup_20260101.json")
        let oldLegacyBackup = dir.appendingPathComponent("iOSBox_Backup_20260101.json")
        let freshBackup = dir.appendingPathComponent("Fugue-EncryptedBackup-20261119.json")
        let unrelated = dir.appendingPathComponent("other-app-file.json")

        let now = Date()
        let oldDate = now.addingTimeInterval(-5 * 3600)
        for url in [oldBackup, oldLegacyBackup, freshBackup, unrelated] {
            try Data("test".utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldBackup.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldLegacyBackup.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelated.path)

        let exportsDir = dir.appendingPathComponent(ConversationExporter.exportsSubdirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let oldChatExport = exportsDir.appendingPathComponent("工作讨论.md")
        try Data("# chat".utf8).write(to: oldChatExport)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldChatExport.path)

        iOSBoxApp.cleanupExpiredTemporaryExports(in: dir, maxAge: 2 * 3600, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBackup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLegacyBackup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldChatExport.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshBackup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testSecondPassFixesKnowledgeEvictionRecoveryExportDirRotatedPDFAndSM2Sanitization() async throws {
        // 1. ConversationExporter strips leading dots & uses managed exports subdirectory
        let chat = Conversation(title: "...hidden-title")
        let mdURL = try ConversationExporter.writeMarkdownFile(for: chat)
        defer { try? FileManager.default.removeItem(at: mdURL) }
        XCTAssertEqual(mdURL.deletingLastPathComponent().lastPathComponent, ConversationExporter.exportsSubdirectoryName)
        XCTAssertEqual(mdURL.lastPathComponent, "hidden-title.md")

        // 2. ProjectKnowledgeSearch recovers gracefully when a cached volume is invalidated in flight
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext
        let book = try BookLibrary.store(
            PreparedBook(BookImporter.parse(Data("# 架构\n一致性协议目标延迟 9ms。".utf8), filename: "spec.md")),
            in: ctx
        )
        let isolatedSearch = ProjectKnowledgeSearch()
        let warm = try await ProjectKnowledgeSearch.retrieve(volumeIDs: [book.id], in: ctx, query: "延迟", search: isolatedSearch)
        XCTAssertFalse(warm.passages.isEmpty)
        XCTAssertTrue(isolatedSearch.isCached(book.id))

        // Simulate concurrent eviction right after skipCachedIn snapshot was built
        let staleSnapshots = ProjectKnowledgeSearch.snapshots(for: [book.id], in: ctx, skipCachedIn: isolatedSearch)
        XCTAssertNil(staleSnapshots.first?.manuscript)
        await isolatedSearch.invalidate(volumeID: book.id)
        let checkResult = try await isolatedSearch.retrieveCheckingCache(from: staleSnapshots, query: "延迟")
        XCTAssertEqual(checkResult.missingVolumeIDs, [book.id])

        // Full race-free helper recovers automatically
        let recovered = try await ProjectKnowledgeSearch.retrieve(volumeIDs: [book.id], in: ctx, query: "延迟", search: isolatedSearch)
        XCTAssertTrue(recovered.passages.first?.excerpt.contains("9ms") == true)

        // 3. FlashcardStore.mergeImported clamps malformed SM-2 values
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("sm2-clamp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let cardStore = FlashcardStore(fileURL: storeURL)
        var malformed = StudyFlashcard(deckName: "Math", front: "F", back: "B")
        malformed.easeFactor = -5.0
        malformed.intervalDays = -10.0
        malformed.repetitions = -3
        malformed.lapses = -2
        XCTAssertEqual(try cardStore.mergeImported([malformed]), 1)
        let saved = try XCTUnwrap(cardStore.cards.first)
        XCTAssertGreaterThanOrEqual(saved.easeFactor, 1.3)
        XCTAssertGreaterThanOrEqual(saved.intervalDays, 0)
        XCTAssertEqual(saved.repetitions, 0)
        XCTAssertEqual(saved.lapses, 0)

        // 4. PDFOCRService handles rotated scanned pages cleanly
        let pageRect = CGRect(x: 0, y: 0, width: 420, height: 180)
        let imgFmt = UIGraphicsImageRendererFormat.default()
        imgFmt.scale = 2.0
        imgFmt.opaque = true
        let bitmap = UIGraphicsImageRenderer(size: pageRect.size, format: imgFmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(pageRect)
            ("QUANTUM BRIDGE" as NSString).draw(at: CGPoint(x: 32, y: 70), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 28),
                .foregroundColor: UIColor.black
            ])
        }
        let pdfData = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { ctx in
            ctx.beginPage()
            bitmap.draw(in: pageRect)
        }
        let pdfDoc = try XCTUnwrap(PDFDocument(data: pdfData))
        let page = try XCTUnwrap(pdfDoc.page(at: 0))
        page.rotation = 90
        let recognized = PDFOCRService.recognizeText(on: page).uppercased()
        XCTAssertTrue(recognized.contains("QUANTUM") || recognized.contains("BRIDGE"),
                      "Expected OCR text on rotated PDF page, got: \(recognized)")
    }
}
