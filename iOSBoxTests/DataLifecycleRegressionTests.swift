import Foundation
import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class DataLifecycleRegressionTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: CurrentSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testOCRPageEnrichmentRoundTripsForCurrentAndLegacyBackups() throws {
        let source = try container()
        let control = try container()
        let target = try container()
        let bindings = PresetKnowledgeStore(fileURL: nil)
        let initial = [BookChapter(title: "Page 1", text: "Previously recognized text")]
        let prepared = try PreparedBook(BookManuscript(title: "Scanned book", chapters: initial))
        let book = try BookLibrary.store(prepared, in: source.mainContext)
        let chat = Conversation(title: "Independent conversation")
        source.mainContext.insert(chat)
        try source.mainContext.save()

        func encodedSourceBackup() throws -> Data {
            try BackupService.encode(BackupService.makeArchive(context: source.mainContext, knowledgeStore: bindings))
        }
        let before = try BackupService.decode(encodedSourceBackup())
        let baseline = try BackupService.apply(before, to: control.mainContext, knowledgeStore: bindings)
        XCTAssertEqual(baseline.books, 1)
        XCTAssertEqual(baseline.conversations, 1)

        // Supply deterministic text in lieu of Vision. The page-order merge and manuscript
        // encoding are production code. These three field assignments mirror the queue's
        // private mergeIntoStoredBook writeback, including retaining the original book ID.
        let afterOCR = BackgroundPDFOCRQueue.mergeChaptersInPageOrder(
            existing: initial,
            additions: [BookChapter(title: "Page 2", text: "Text recognized later")]
        )
        book.manuscript = try BookManuscript(title: book.title, chapters: afterOCR).encoded()
        book.chapterTitles = afterOCR.map(\.title)
        book.manuscriptByteCount = book.manuscript.count
        try source.mainContext.save()

        let after = try BackupService.decode(encodedSourceBackup())
        guard case .full(let archive) = after else { return XCTFail("Expected a full archive") }
        let snapshot = try XCTUnwrap(archive.books?.first)
        XCTAssertEqual(snapshot.id, prepared.id)
        XCTAssertEqual(snapshot.chapters, afterOCR)
        XCTAssertNotEqual(try PreparedBook(BookManuscript(title: snapshot.title, chapters: snapshot.chapters)).id, snapshot.id)
        _ = try BackupService.apply(after, to: target.mainContext, knowledgeStore: bindings)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<Conversation>()), 1)
        let restored = try XCTUnwrap(BookLibrary.find(book.id, in: target.mainContext))
        XCTAssertEqual(try restored.snapshot().chapters, afterOCR)
        var legacy = archive
        legacy.formatVersion = 7
        legacy.books?[0].manuscriptID = nil
        _ = try BackupService.apply(.full(legacy), to: control.mainContext, knowledgeStore: bindings)
        let enriched = try XCTUnwrap(BookLibrary.find(book.id, in: control.mainContext))
        XCTAssertEqual(try enriched.snapshot().chapters, afterOCR)
        var corrupted = archive
        corrupted.books?[0].manuscriptID = UUID()
        XCTAssertThrowsError(try BackupService.apply(.full(corrupted), to: target.mainContext, knowledgeStore: bindings))
    }

    func testSyncKeepsClearedMessagesDeletedUntilExplicitRestore() throws {
        let device = try container()
        let context = device.mainContext
        let bindings = PresetKnowledgeStore(fileURL: nil)
        let deletions = SyncTombstoneStore(fileURL: nil)
        let chat = Conversation(title: "History to clear")
        let message = ChatMessage(role: .user, content: "Old synchronized text", sortIndex: 0)
        let oldMessageID = message.id
        context.insert(chat)
        message.conversation = chat
        context.insert(message)
        try context.save()

        // This is the archive content that the WebDAV coordinator normally obtains by
        // decrypting a previous upload. No server, credentials or device storage are used.
        let oldCloudData = try BackupService.encode(BackupService.makeArchive(
            context: context, knowledgeStore: bindings, tombstoneStore: deletions
        ))
        let undo = try BackupService.clearMessages(in: chat, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
        let summary = try BackupService.apply(
            BackupService.decode(oldCloudData),
            to: context,
            knowledgeStore: bindings,
            tombstonePolicy: .enforce(deletions)
        )
        XCTAssertEqual(summary.messages, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
        let oldDevice = try container()
        _ = try BackupService.apply(BackupService.decode(oldCloudData), to: oldDevice.mainContext, knowledgeStore: bindings)
        let clearSnapshot = try BackupService.makeArchive(context: context, knowledgeStore: bindings)
        _ = try BackupService.apply(.full(clearSnapshot), to: oldDevice.mainContext, knowledgeStore: bindings,
                                    tombstonePolicy: .enforce(SyncTombstoneStore(fileURL: nil)))
        XCTAssertEqual(try oldDevice.mainContext.fetchCount(FetchDescriptor<ChatMessage>()), 0)

        try BackupService.undoClear(undo, in: context)
        _ = try BackupService.apply(.full(clearSnapshot), to: context, knowledgeStore: bindings,
                                    tombstonePolicy: .enforce(deletions))
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<ChatMessage>()).first)
        XCTAssertEqual(restored.id, oldMessageID)
        let restoredSnapshot = try BackupService.makeArchive(context: context, knowledgeStore: bindings)
        _ = try BackupService.apply(.full(restoredSnapshot), to: oldDevice.mainContext, knowledgeStore: bindings,
                                    tombstonePolicy: .enforce(SyncTombstoneStore(fileURL: nil)))
        XCTAssertEqual(try oldDevice.mainContext.fetch(FetchDescriptor<ChatMessage>()).first?.id, oldMessageID)
    }

    func testLatestReadingMemoryAndBookmarkEditsPropagateInBothDirections() throws {
        let source = try container()
        let destination = try container()
        let bindings = PresetKnowledgeStore(fileURL: nil)
        func snapshot(_ container: ModelContainer) throws -> BackupService.DecodedBackup {
            try BackupService.decode(BackupService.encode(BackupService.makeArchive(context: container.mainContext, knowledgeStore: bindings)))
        }
        func sync(_ archive: BackupService.DecodedBackup, to device: ModelContainer) throws {
            try BackupService.apply(archive, to: device.mainContext, knowledgeStore: bindings,
                                    tombstonePolicy: .enforce(SyncTombstoneStore(fileURL: nil)))
        }
        let book = try BookLibrary.store(PreparedBook(BookManuscript(title: "Book", chapters: [
            BookChapter(title: "One", text: "First"), BookChapter(title: "Two", text: "Second")
        ])), in: source.mainContext)
        let position = ShelfReadingState(bookID: book.id)
        position.chapter = 1
        position.updatedTimestamp = 20
        let memory = PersonalMemory(content: "Earlier preference")
        memory.updatedTimestamp = 20
        let chat = Conversation(title: "Bookmarked message")
        let msg = ChatMessage(role: .assistant, content: "Answer")
        msg.conversation = chat
        var meta = msg.assistanceMetadata
        meta.isBookmarked = true
        meta.bookmarkUpdatedTimestamp = 20
        msg.assistanceMetadata = meta
        source.mainContext.insert(position)
        source.mainContext.insert(memory)
        source.mainContext.insert(chat)
        source.mainContext.insert(msg)
        try source.mainContext.save()
        let original = try snapshot(source)
        try sync(original, to: destination)
        let remotePos = try XCTUnwrap(ShelfReadingState.find(book.id, in: destination.mainContext))
        let remoteMem = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<PersonalMemory>()).first)
        let remoteMsg = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<ChatMessage>()).first)
        remotePos.setPosition(chapter: 0, paragraph: 4)
        remoteMem.content = "Edited on tablet"
        remoteMem.isEnabled = false
        remoteMem.updatedTimestamp = 30
        var remoteMeta = remoteMsg.assistanceMetadata
        remoteMeta.isBookmarked = false
        remoteMeta.bookmarkUpdatedTimestamp = 30
        remoteMsg.assistanceMetadata = remoteMeta
        try destination.mainContext.save()
        try sync(snapshot(destination), to: source)
        XCTAssertEqual(position.chapter, 0)
        XCTAssertEqual(position.paragraph, 4)
        XCTAssertFalse(memory.isEnabled)
        XCTAssertEqual(memory.content, "Edited on tablet")
        XCTAssertFalse(msg.assistanceMetadata.isBookmarked)
        try sync(original, to: destination)
        XCTAssertEqual(remotePos.chapter, 0)
        XCTAssertFalse(remoteMem.isEnabled)
        XCTAssertFalse(remoteMsg.assistanceMetadata.isBookmarked)
    }

    func testEncryptedDraftTransferPreservesConflictingAttachmentsAndHonorsSelection() throws {
        let source = try container()
        let destination = try container()
        let bindings = PresetKnowledgeStore(fileURL: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let localDrafts = ChatDraftStore(directory: root.appendingPathComponent("source"))
        let restoredDrafts = ChatDraftStore(directory: root.appendingPathComponent("destination"))
        let a = Conversation(title: "Saved draft")
        let b = Conversation(title: "Locally edited draft")
        source.mainContext.insert(a)
        source.mainContext.insert(b)
        source.mainContext.insert(PersonalMemory(content: "Excluded from selective restoration"))
        try source.mainContext.save()
        let attachment = MessageAttachment(kind: .document, fileName: "Note.txt", mimeType: "text/plain",
                                          extractedText: "An original attachment", byteSize: 22)
        let conflict = ChatDraft(text: "Old draft", attachments: [attachment], quotedText: "A quotation")
        try localDrafts.save(ChatDraft(text: "First draft"), for: a.id)
        try localDrafts.save(conflict, for: b.id)
        try restoredDrafts.save(ChatDraft(text: "New local draft"), for: b.id)
        let archive = try BackupService.makeArchive(context: source.mainContext, knowledgeStore: bindings)
        let payload = EncryptedBackupService.FullPayload(archive: archive, providerSecrets: [], tavilyAPIKey: "",
                                                        drafts: try localDrafts.snapshots(for: [a.id, b.id]))
        let bytes = try EncryptedBackupService.encryptPayload(payload, password: "example-pass")
        let decoded = try EncryptedBackupService.decryptPayload(data: bytes, password: "example-pass")
        let plan = try BackupRecoveryPlan(.encrypted(decoded), in: destination.mainContext, draftStore: restoredDrafts)
        XCTAssertEqual(plan.counts[.drafts], 2)
        XCTAssertEqual(plan.conflictingDrafts, 1)
        XCTAssertEqual(plan.previouslyRecoveredDrafts, 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<Conversation>()), 0)
        _ = try plan.apply([.conversations], in: destination.mainContext)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<Conversation>()), 2)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<PersonalMemory>()), 0)
        XCTAssertTrue(try restoredDrafts.load(a.id).isEmpty)
        let summary = try EncryptedBackupService.applyDecryptedPayload(decoded, to: destination.mainContext,
            knowledgeStore: bindings, draftStore: restoredDrafts, restoreSecret: { _, _ in false })
        XCTAssertEqual(summary.drafts, 1)
        XCTAssertEqual(summary.conflictingDrafts, 1)
        XCTAssertEqual(try restoredDrafts.load(a.id).text, "First draft")
        XCTAssertEqual(try restoredDrafts.load(b.id).text, "New local draft")
        let recoveredID = try conflict.recoveryConversationID(for: b.id)
        XCTAssertEqual(try restoredDrafts.load(recoveredID), conflict)
        let secondPreview = try BackupRecoveryPlan(.encrypted(decoded), in: destination.mainContext, draftStore: restoredDrafts)
        XCTAssertEqual(secondPreview.conflictingDrafts, 0)
        XCTAssertEqual(secondPreview.previouslyRecoveredDrafts, 1)
        let retry = try EncryptedBackupService.applyDecryptedPayload(decoded, to: destination.mainContext,
            knowledgeStore: bindings, draftStore: restoredDrafts, restoreSecret: { _, _ in false })
        XCTAssertEqual(retry.drafts, 0)
        XCTAssertEqual(retry.conflictingDrafts, 0)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<Conversation>()), 3)
        try restoredDrafts.remove(b.id)
        let afterClearingOriginal = try BackupRecoveryPlan(.encrypted(decoded), in: destination.mainContext, draftStore: restoredDrafts)
        XCTAssertEqual(afterClearingOriginal.previouslyRecoveredDrafts, 1)
        _ = try EncryptedBackupService.applyDecryptedPayload(decoded, to: destination.mainContext,
            knowledgeStore: bindings, draftStore: restoredDrafts, restoreSecret: { _, _ in false })
        XCTAssertTrue(try restoredDrafts.load(b.id).isEmpty)
        XCTAssertEqual(try restoredDrafts.load(recoveredID), conflict)
    }

    func testRecoveryPreviewCountsBooksExcerptsAndPositionsIndividually() throws {
        let source = try container()
        let context = source.mainContext
        let book = try BookLibrary.store(PreparedBook(BookManuscript(title: "Indexed book", chapters: [
            BookChapter(title: "Part one", text: "An excerpt from the book")
        ])), in: context)
        context.insert(ShelfReadingState(bookID: book.id))
        for id in [book.id, UUID()] {
            context.insert(ReadingAnnotation(.init(id: UUID(), volumeID: id, bookTitle: "Indexed book",
                chapterTitle: "Part one", chapterIndex: 0, utf16Offset: 0, excerpt: "An excerpt", note: "", updatedAt: .now)))
        }
        try context.save()
        var archive = try BackupService.makeArchive(context: context, knowledgeStore: PresetKnowledgeStore(fileURL: nil))
        var plan = try BackupRecoveryPlan(.plain(.full(archive)), in: context)
        XCTAssertEqual(plan.counts[.books], 1)
        XCTAssertEqual(plan.annotationCount, 2)
        XCTAssertEqual(plan.readingPositionCount, 1)
        archive.books = nil
        archive.shelfPositions = nil
        plan = try BackupRecoveryPlan(.plain(.full(archive)), in: context)
        XCTAssertEqual(plan.counts[.books], 0)
        XCTAssertTrue(plan.groups.contains(.books))
    }

    func testCredentialPreviewMatchesImportWhenOnlyOneSecretHeaderChanged() throws {
        let source = try container()
        let target = try container()
        let matching = CustomHeader(key: "X-API-A", value: "", isSecret: true)
        let changed = CustomHeader(key: "X-API-B", value: "", isSecret: true)
        let provider = ProviderConfig(name: "Same address", protocolType: .openAICompatible, baseURL: "https://example.org/v1",
                                      customHeaders: [matching, changed])
        let other = ProviderConfig(name: "New address", protocolType: .openAICompatible, baseURL: "https://example.com/v1")
        source.mainContext.insert(provider)
        source.mainContext.insert(other)
        try source.mainContext.save()
        var renamed = changed
        renamed.key = "X-Different"
        let local = ProviderConfig(id: provider.id, name: provider.name, protocolType: .openAICompatible, baseURL: provider.baseURL,
                                   customHeaders: [matching, renamed])
        target.mainContext.insert(local)
        target.mainContext.insert(ProviderConfig(id: other.id, name: other.name, protocolType: .openAICompatible, baseURL: "https://elsewhere.example/v1"))
        try target.mainContext.save()
        let archive = try BackupService.makeArchive(context: source.mainContext, knowledgeStore: PresetKnowledgeStore(fileURL: nil))
        let bundles: [EncryptedBackupService.ProviderSecretBundle] = [
            .init(providerID: provider.id, rawBaseURL: provider.baseURL, isEnabled: false, apiKey: "main", extraAPIKeys: ["", "extra", "extra"],
                  secretHeaders: [matching.id.uuidString: "first", changed.id.uuidString: "second"]),
            .init(providerID: other.id, rawBaseURL: other.baseURL, isEnabled: false, apiKey: "other", secretHeaders: [:])
        ]
        let payload = EncryptedBackupService.FullPayload(archive: archive, providerSecrets: bundles, tavilyAPIKey: "search")
        let plan = try BackupRecoveryPlan(.encrypted(payload), in: target.mainContext)
        XCTAssertEqual(plan.counts[.credentials], 6)
        XCTAssertEqual(plan.skippedCredentialCount, 2)
        XCTAssertEqual(Set(plan.credentialConflicts), [provider.name, other.name])
        var accounts: [String] = []
        let result = try EncryptedBackupService.applyDecryptedPayload(payload, to: target.mainContext,
            knowledgeStore: PresetKnowledgeStore(fileURL: nil), restoreSecret: { _, account in accounts.append(account); return true })
        XCTAssertEqual(Set(result.credentialConflicts), Set(plan.credentialConflicts))
        XCTAssertEqual(result.confirmedCredentials, 4)
        XCTAssertFalse(accounts.contains(KeychainService.headerAccount(providerID: local.credentialID, headerID: renamed.id)))
    }

    func testNamedMemoryCollectionsSnapshotSelectionsAndKeepIndependentBindings() throws {
        let database = try container()
        let context = database.mainContext
        let first = PersonalMemory(content: "For work")
        let second = PersonalMemory(content: "Writing style")
        context.insert(first)
        context.insert(second)
        try context.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bindings.json")
        let store = PresetKnowledgeStore(fileURL: url)
        let preset = UUID()
        let volume = UUID()
        try store.setBindings(volumes: [volume], memories: [first.id], for: preset) {}
        let group = try store.saveMemoryCollection(name: " Work.写作 ", memoryIDs: [first.id, second.id])
        let reopened = PresetKnowledgeStore(fileURL: url)
        XCTAssertEqual(try reopened.memoryCollections(), [group])
        XCTAssertEqual(group.name, "Work.写作")
        let appliedScope = group.selection(among: [second.id])
        XCTAssertEqual(appliedScope, [second.id])
        try reopened.renameMemoryCollection(group.id, to: "Writing")
        XCTAssertEqual(try store.memoryCollections().first?.id, group.id)
        XCTAssertEqual(try store.memoryCollections().first?.name, "Writing")
        try reopened.removeFromMemoryCollections([second.id])
        XCTAssertEqual(try store.memoryCollections().first?.memoryIDs, [first.id])
        XCTAssertEqual(appliedScope, [second.id])
        try reopened.deleteMemoryCollection(group.id)
        XCTAssertTrue(try store.memoryCollections().isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalMemory>()), 2)
        XCTAssertEqual(store.volumeIDs(for: preset), [volume])
        XCTAssertEqual(try store.readableBindings()[PresetKnowledgeStore.memoryKey(preset)], [first.id])
    }

    func testManualMemoryCollectionBackupIsSelectiveAndIdempotent() throws {
        let source = try container()
        let target = try container()
        let origin = PresetKnowledgeStore(fileURL: nil)
        let restored = PresetKnowledgeStore(fileURL: nil)
        let item = PersonalMemory(content: "For work")
        source.mainContext.insert(item)
        try source.mainContext.save()
        let group = try origin.saveMemoryCollection(name: "Work", memoryIDs: [item.id, UUID()])
        let archive = try BackupService.makeArchive(context: source.mainContext, knowledgeStore: origin)
        XCTAssertEqual(archive.memoryCollections?.first?.memoryIDs, [item.id])
        let cloud = try BackupService.makeArchive(context: source.mainContext, knowledgeStore: origin, tombstoneStore: SyncTombstoneStore(fileURL: nil))
        XCTAssertNil(cloud.memoryCollections)
        let decoded = try BackupService.decode(BackupService.encode(archive))
        let preview = try BackupRecoveryPlan(.plain(decoded), in: target.mainContext)
        XCTAssertEqual(preview.memoryCollectionCount, 1)
        _ = try preview.apply([.conversations], in: target.mainContext, knowledgeStore: restored)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<PersonalMemory>()), 0)
        XCTAssertTrue(try restored.memoryCollections().isEmpty)
        let initial = try preview.apply([.memories], in: target.mainContext, knowledgeStore: restored)
        XCTAssertEqual(initial.memoryCollections, 1)
        XCTAssertEqual(try restored.memoryCollections().first?.memoryIDs, [item.id])
        try restored.renameMemoryCollection(group.id, to: "My local name")
        let full = EncryptedBackupService.FullPayload(archive: archive, providerSecrets: [], tavilyAPIKey: "")
        let encrypted = try EncryptedBackupService.encryptPayload(full, password: "group-test-pass")
        let decrypted = try EncryptedBackupService.decryptPayload(data: encrypted, password: "group-test-pass")
        let retry = try BackupRecoveryPlan(.encrypted(decrypted), in: target.mainContext)
        XCTAssertEqual(try retry.apply([.memories], in: target.mainContext, knowledgeStore: restored).memoryCollections, 0)
        XCTAssertEqual(try restored.memoryCollections().map(\.name), ["My local name"])
        var old = archive
        old.formatVersion = 7
        old.memoryCollections = nil
        _ = try BackupService.apply(BackupService.decode(BackupService.encode(old)), to: target.mainContext, knowledgeStore: restored)
        XCTAssertEqual(try restored.memoryCollections().count, 1)
        let deleted = SyncTombstoneStore(fileURL: nil)
        deleted.recordDeletion(kind: .memory, id: item.id, at: Date(timeIntervalSinceNow: 1))
        _ = try BackupService.apply(.full(cloud), to: target.mainContext, knowledgeStore: restored, tombstonePolicy: .enforce(deleted))
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<PersonalMemory>()), 0)
        XCTAssertEqual(try restored.memoryCollections().first?.memoryIDs, [])
    }

    func testOlderEncryptedReaderRejectsNewPayloadAndNewReaderStillOpensV7() throws {
        struct OldReader: Decodable { let archive: BackupArchive }
        let current = try container()
        var archive = try BackupService.makeArchive(context: current.mainContext, knowledgeStore: PresetKnowledgeStore(fileURL: nil))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let new = EncryptedBackupService.FullPayload(archive: archive, providerSecrets: [], tavilyAPIKey: "")
        let bytes = try encoder.encode(new)
        XCTAssertThrowsError(try decoder.decode(OldReader.self, from: bytes))
        archive.formatVersion = 7
        let old = EncryptedBackupService.FullPayload(archive: archive, providerSecrets: [], tavilyAPIKey: "")
        let oldBytes = try encoder.encode(old)
        XCTAssertEqual(try decoder.decode(OldReader.self, from: oldBytes).archive.formatVersion, 7)
        XCTAssertEqual(try decoder.decode(EncryptedBackupService.FullPayload.self, from: oldBytes).archive.formatVersion, 7)
        archive.formatVersion = BackupArchive.currentFormatVersion + 1
        let future = EncryptedBackupService.FullPayload(archive: archive, providerSecrets: [], tavilyAPIKey: "")
        XCTAssertThrowsError(try decoder.decode(EncryptedBackupService.FullPayload.self, from: encoder.encode(future))) {
            guard case BackupError.newerFormat = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testBatchUndoRetainsBothConversationsAndTheirUnsentDrafts() throws {
        let device = try container()
        let context = device.mainContext
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = ChatDraftStore(directory: root)
        let summaries = RollingContextSummaryStore(fileURL: nil)
        let a = Conversation(title: "One"), b = Conversation(title: "Two")
        let aid = a.id, bid = b.id
        a.assistanceSettings.usePersonalMemory = true
        context.insert(a)
        context.insert(b)
        try context.save()
        try drafts.save(ChatDraft(text: "Unsent"), for: aid)
        let undo = try ConversationDeletionUndo(chats: [a, b], drafts: drafts, summaries: summaries)
        context.delete(a)
        context.delete(b)
        try context.save()
        try drafts.remove(aid)
        try undo.restore(in: context, drafts: drafts, summaries: summaries)
        let chats = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(Set(chats.map(\.id)), [aid, bid])
        XCTAssertEqual(chats.first { $0.id == aid }?.assistanceSettings.usePersonalMemory, true)
        XCTAssertEqual(try drafts.load(aid).text, "Unsent")
    }
}
