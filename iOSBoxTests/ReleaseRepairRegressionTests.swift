import Foundation
import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ReleaseRepairRegressionTests: XCTestCase {
    private func database() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testPartialArchiveAndFailedRollbackRetainTheDatabaseAcrossRestart() throws {
        let fm = FileManager.default, dir = try directory()
        let main = dir.appendingPathComponent("default.store")
        let names = ["default.store", "default.store-wal", "default.store-shm"]
        for name in names { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
        var archive: URL?
        XCTAssertThrowsError(try PersistenceController.backupStoreFiles(at: main) { source, dest in
            if source.lastPathComponent == "default.store-shm" || dest == main { throw CocoaError(.fileWriteNoPermission) }
            try fm.moveItem(at: source, to: dest)
        }) { archive = ($0 as? PersistenceController.IncompleteArchive)?.folder }
        let retained = try XCTUnwrap(archive)
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("default.store")), Data(names[0].utf8))
        XCTAssertThrowsError(try PersistenceController.restoreInterruptedArchive(at: main) { _, _ in throw CocoaError(.fileWriteNoPermission) })
        try PersistenceController.restoreInterruptedArchive(at: main)
        for name in names { XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(name)), Data(name.utf8)) }
        XCTAssertFalse(fm.fileExists(atPath: retained.path))
        let complete = try PersistenceController.backupStoreFiles(at: main)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: complete.path)), Set(names))
        XCTAssertNoThrow(try PersistenceController.restoreInterruptedArchive(at: main))
        XCTAssertFalse(fm.fileExists(atPath: main.path))
    }

    func testTwoDeviceMergePreservesOrganizationAndRegeneratedAnswersOnRepeat() throws {
        let first = try database(), second = try database()
        let cards = FlashcardStore(fileURL: nil), bindings = PresetKnowledgeStore(fileURL: nil)
        let chat = Conversation(title: "游记")
        let answer = ChatMessage(role: .assistant, content: "第一版回答")
        first.mainContext.insert(chat)
        first.mainContext.insert(answer)
        answer.conversation = chat
        func transfer() throws -> ImportSummary {
            let archive = try BackupService.makeArchive(context: first.mainContext, flashcardStore: cards, knowledgeStore: bindings)
            return try BackupService.apply(BackupService.decode(BackupService.encode(archive)), to: second.mainContext,
                                           flashcardStore: cards, knowledgeStore: bindings)
        }
        try first.mainContext.save()
        _ = try transfer()
        let local = try XCTUnwrap(second.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        let reply = try XCTUnwrap(local.sortedMessages.first)
        var previous = ChatEngine.snapshotRevision(of: answer)
        // Older exports may know the historical model even when the active reply lacks attribution.
        previous.modelID = "a"
        answer.assistanceMetadata.revisions = [previous]
        answer.content = "第二版回答"
        answer.reasoningContent = "第二版推理"
        chat.updatedAt = Date().addingTimeInterval(3600)
        local.rename(to: "本机游记")
        local.setPinned(true)
        local.setFolderTag("旅行")
        local.temperature = 0.25
        try first.mainContext.save()
        XCTAssertEqual(try transfer().restoredConversations, 1)
        XCTAssertEqual(try transfer().restoredConversations, 0)
        XCTAssertEqual(local.title, "本机游记")
        XCTAssertTrue(local.isPinned)
        XCTAssertEqual(local.folderTag, "旅行")
        XCTAssertEqual(local.temperature, 0.25)
        XCTAssertEqual(reply.content, "第二版回答")
        XCTAssertEqual(reply.reasoningContent, "第二版推理")
        XCTAssertEqual(reply.assistanceMetadata.revisions.map(\.content), ["第一版回答"])
        // Independent regenerations and an incoming rename older than the latest chat activity.
        reply.assistanceMetadata.revisions.append(ChatEngine.snapshotRevision(of: reply))
        reply.content = "本机的第三版"
        answer.assistanceMetadata.revisions.append(ChatEngine.snapshotRevision(of: answer))
        answer.content = "另一设备的第三版"
        chat.rename(to: "两端的新标题")
        _ = try transfer()
        let revisions = reply.assistanceMetadata.revisions
        _ = try transfer()
        XCTAssertEqual(local.title, "两端的新标题")
        XCTAssertTrue(local.isPinned)
        XCTAssertEqual(reply.content, "本机的第三版")
        XCTAssertEqual(reply.assistanceMetadata.revisions, revisions)
        XCTAssertEqual(revisions.last?.content, "另一设备的第三版")
        ChatEngine().selectRevision(index: revisions.count - 1, for: reply, context: second.mainContext)
        XCTAssertEqual(reply.content, "另一设备的第三版")
    }

    func testBindingImportReportsWriteFailureAndRetriesAfterReopening() throws {
        let first = try database(), second = try database(), root = try directory()
        let source = PresetKnowledgeStore(fileURL: nil), cards = FlashcardStore(fileURL: nil)
        let book = try BookLibrary.store(PreparedBook(BookManuscript(title: "参考书", chapters: [.init(title: "一", text: "原文")])), in: first.mainContext)
        let preset = AssistantPreset(name: "助理")
        first.mainContext.insert(preset)
        try first.mainContext.save()
        try source.setVolumeIDs([book.id], for: preset.id)
        let archive = try BackupService.makeArchive(context: first.mainContext, flashcardStore: cards, knowledgeStore: source)
        let parent = root.appendingPathComponent("parent")
        try Data("occupied".utf8).write(to: parent)
        let file = parent.appendingPathComponent("bindings.json")
        let storage = PresetKnowledgeStore(fileURL: file)
        func restore() throws -> ImportSummary {
            try BackupService.apply(.full(archive), to: second.mainContext, flashcardStore: cards, knowledgeStore: storage)
        }
        let failure = try restore()
        XCTAssertEqual(failure.presets, 1)
        XCTAssertEqual(failure.books, 1)
        XCTAssertTrue(failure.hasWarnings)
        XCTAssertTrue(failure.knowledgeRestoreFailed)
        XCTAssertTrue(storage.volumeIDs(for: preset.id).isEmpty)
        try FileManager.default.removeItem(at: parent)
        let retry = try restore()
        XCTAssertFalse(retry.hasWarnings)
        XCTAssertEqual(retry.presets, 0)
        XCTAssertEqual(PresetKnowledgeStore(fileURL: file).volumeIDs(for: preset.id), [book.id])
        XCTAssertThrowsError(try storage.removeVolume(book.id) { throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertEqual(PresetKnowledgeStore(fileURL: file).volumeIDs(for: preset.id), [book.id])
        try storage.setVolumeIDs([], for: preset.id)
        XCTAssertFalse(try restore().knowledgeRestoreFailed)
        XCTAssertEqual(try storage.readableBindings()[preset.id.uuidString], [])
        let corrupt = Data("truncated{".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try storage.setVolumeIDs([], for: preset.id))
        XCTAssertThrowsError(try BackupService.makeArchive(context: second.mainContext, flashcardStore: cards, knowledgeStore: storage))
        XCTAssertFalse(try restore().knowledgeRestoreFailed)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        try storage.preserveDamagedLibrary()
        XCTAssertFalse(try restore().hasWarnings)
        let saved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("damaged") })
        XCTAssertEqual(try Data(contentsOf: saved), corrupt)
        XCTAssertTrue(try storage.readableBindings().isEmpty)
    }

    func testRepeatedLegacyImportsRecognizeExactPriorRandomIDsAndIntentionalCopies() throws {
        let db = try database(), now = Date(timeIntervalSince1970: 1780000000)
        let m = LegacyExportConversation.Message(role: "user", model: "", provider: "", reasoning: "", content: "同一句", createdAt: now)
        let legacy = LegacyExportConversation(title: "同名", systemPrompt: "", updatedAt: now, messages: [m, m])
        let old = Conversation(title: legacy.title)
        old.createdAt = now
        old.updatedAt = now
        db.mainContext.insert(old)
        for index in 0..<2 {
            let msg = ChatMessage(role: .user, content: m.content, sortIndex: index, createdAt: now)
            db.mainContext.insert(msg)
            msg.conversation = old
        }
        func restore(_ chats: [LegacyExportConversation], to destination: ModelContainer) throws -> ImportSummary {
            try BackupService.apply(.legacy(chats), to: destination.mainContext, flashcardStore: FlashcardStore(fileURL: nil), knowledgeStore: PresetKnowledgeStore(fileURL: nil))
        }
        XCTAssertEqual(try restore([legacy], to: db).conversations, 0)
        old.rename(to: "本机重命名")
        XCTAssertEqual(try restore([legacy, legacy], to: db).conversations, 1)
        XCTAssertEqual(try restore([legacy, legacy], to: db).conversations, 0)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<ChatMessage>()), 4)
        let fresh = try database()
        XCTAssertEqual(try restore([legacy], to: fresh).conversations, 1)
        XCTAssertEqual(try restore([legacy], to: fresh).conversations, 0)
        let imported = try XCTUnwrap(fresh.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(imported.id, old.backupState.legacyImportID)
        XCTAssertEqual(Set(imported.messages.map(\.id)).count, 2)
    }

    func testSameTitleMarkdownAndImageSharesKeepTheFirstFileIntact() throws {
        let db = try database()
        func chat(_ text: String) -> Conversation {
            let chat = Conversation(title: "行程")
            let message = ChatMessage(role: .user, content: text)
            db.mainContext.insert(chat)
            db.mainContext.insert(message)
            message.conversation = chat
            return chat
        }
        let first = chat("东京行程"), second = chat("杭州行程")
        try db.mainContext.save()
        for ext in ["md", "png"] {
            func export(_ chat: Conversation) throws -> URL {
                let url = try ext == "md" ? ConversationExporter.writeMarkdownFile(for: chat) : XCTUnwrap(ConversationExporter.writeShareImageFile(for: chat))
                addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                return url
            }
            let one = try export(first), initial = try Data(contentsOf: one)
            let two = try export(second)
            XCTAssertNotEqual(one, two)
            XCTAssertEqual(one.lastPathComponent, two.lastPathComponent)
            XCTAssertEqual(initial, try Data(contentsOf: one))
            XCTAssertNotEqual(initial, try Data(contentsOf: two))
        }
    }

    func testSystemModelListRequiresUsableConnectionAndGenerationProgressCountsOnlyFinishedTurns() throws {
        let remote = ProviderConfig(name: "Remote", protocolType: .openAICompatible, baseURL: "https://service.example/v1", models: [.init(id: "public")])
        let local = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "http://127.0.0.1/v1", models: [.init(id: "local")])
        XCTAssertEqual(SystemIntegration.publishableProviders([remote, local], optedIn: { _ in true }).map(\.id), [local.id])
        XCTAssertTrue(SystemIntegration.publishableProviders([local], optedIn: { _ in false }).isEmpty)
        let stopped = GenerationOutcome(statuses: [.succeeded, .cancelled], stopped: true)
        XCTAssertEqual(stopped.completedTurns, 1)
        XCTAssertEqual(stopped.phase, String(localized: "已停止生成"))
        let failed = GenerationOutcome(statuses: [.failed], stopped: false)
        XCTAssertEqual(failed.completedTurns, 0)
        XCTAssertEqual(failed.phase, String(localized: "生成失败"))
    }
}
