import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class WorkspaceUpgradeTests: XCTestCase {
    private func workspace() throws -> ModelContainer {
        try ModelContainer(for: Schema(versionedSchema: CurrentSchema.self),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testSharedMaterialBecomesOneUnsentDraftAndRetryKeepsEdits() throws {
        let container = try workspace()
        let context = container.mainContext
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = SystemEntryStore(directory: folder)
        let drafts = ChatDraftStore(directory: folder.appendingPathComponent("local"))
        let deletions = SyncTombstoneStore(fileURL: nil)
        let doc = MessageAttachment(kind: .document, fileName: "notes.txt", mimeType: "text/plain", extractedText: "observations", byteSize: 12)
        let input = ReadingInput(text: "selection", title: "Research", attachments: [doc])
        let entry = try SharedDraftEntry(input: input, link: "https://example.org/page", question: "Compare")
        try inbox.saveDraft(entry)
        let file = try XCTUnwrap(inbox.draftFiles().first)
        let stored = try inbox.readDraft(file)
        try ExternalReceiptImporter.importDraft(stored, context: context, drafts: drafts, tombstones: deletions)
        XCTAssertEqual(try drafts.load(entry.id).text, "Compare\n\nhttps://example.org/page\n\nselection")
        XCTAssertEqual(try drafts.load(entry.id).attachments, [doc])
        try drafts.save(ChatDraft(text: "edited offline"), for: entry.id)
        try ExternalReceiptImporter.importDraft(stored, context: context, drafts: drafts, tombstones: deletions)
        XCTAssertEqual(try drafts.load(entry.id).text, "edited offline")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Conversation>()).map(\.id), [entry.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestRecord>()), 0)
        let deleted = try SharedDraftEntry(input: input, link: "", question: "")
        deletions.recordDeletion(kind: .conversation, id: deleted.id)
        try ExternalReceiptImporter.importDraft(deleted, context: context, drafts: drafts, tombstones: deletions)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
    }

    func testMemorySelectionIntersectsScopeAndPersistsExplicitEmptyChoices() throws {
        let container = try workspace()
        let context = container.mainContext
        let work = PersonalMemory(content: "work-only"), writing = PersonalMemory(content: "writing-only")
        let hidden = PersonalMemory(content: "disabled", isEnabled: false)
        for item in [work, writing, hidden] { context.insert(item) }
        let chat = Conversation(title: "Selection")
        chat.assistanceSettings.usePersonalMemory = true
        context.insert(chat)
        try context.save()
        let engine = ChatEngine()
        XCTAssertEqual(engine.prepareMemory(conversation: chat, omitMemory: false, context: context).count, 2)
        chat.assistanceSettings.scopedMemoryIDs = [work.id, hidden.id]
        let result = engine.prepareMemory(conversation: chat, omitMemory: false,
                                          selectedIDs: [work.id, writing.id, hidden.id], context: context)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.systemPrompt.contains(work.content))
        XCTAssertFalse(result.systemPrompt.contains(writing.content))
        XCTAssertFalse(result.systemPrompt.contains(hidden.content))
        XCTAssertEqual(engine.prepareMemory(conversation: chat, omitMemory: false, selectedIDs: [], context: context).count, 0)
        let entry = ChatMessage(role: .user, content: "question", sortIndex: 0)
        entry.assistanceMetadata.selectedMemoryIDs = []
        XCTAssertEqual(entry.assistanceMetadata.selectedMemoryIDs, [])
        let preset = AssistantPreset(name: "writing")
        context.insert(preset)
        let bindings = PresetKnowledgeStore(fileURL: nil)
        try bindings.setBindings(volumes: [], memories: [], for: preset.id) { try context.save() }
        let archive = try BackupService.makeArchive(context: context, knowledgeStore: bindings)
        XCTAssertEqual(archive.presets.first?.memoryIDs, [])
    }

    func testLibraryDiscussionReusesBooksAndAssistantWithoutDuplicatingMaterials() throws {
        let container = try workspace()
        let context = container.mainContext
        func store(_ title: String) throws -> BookVolume {
            try BookLibrary.store(PreparedBook(BookManuscript(title: title, chapters: [BookChapter(title: "1", text: title)])), in: context)
        }
        let first = try store("first"), second = try store("second")
        let preset = AssistantPreset(name: "Editor", systemPrompt: "Review sources.")
        context.insert(preset)
        let chat = try LibraryDiscussion.create(bookIDs: [second.id, first.id, second.id], preset: preset, target: nil, context: context)
        XCTAssertEqual(chat.assistanceSettings.knowledgeVolumeIDs, [second.id, first.id])
        XCTAssertEqual(chat.assistantID, preset.id)
        XCTAssertEqual(chat.systemPrompt, preset.systemPrompt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookVolume>()), 2)
        XCTAssertThrowsError(try LibraryDiscussion.create(bookIDs: [UUID()], preset: nil, target: nil, context: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
    }

    func testOptionalModulesKeepExistingInstallationAndRememberOptInOnFreshInstall() throws {
        let domain = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let fresh = AppPreferences(defaults: defaults)
        XCTAssertFalse(fresh.showsGroupChat)
        XCTAssertFalse(fresh.showsEnglishCoach)
        defaults.set(true, forKey: "com.iosbox.hasSeededPresets.v1")
        fresh.moduleGroupChatEnabled = true
        let next = AppPreferences(defaults: defaults)
        XCTAssertTrue(next.showsGroupChat)
        XCTAssertFalse(next.showsEnglishCoach)
        defaults.removePersistentDomain(forName: domain)
        defaults.set(true, forKey: "com.iosbox.hasSeededPresets.v1")
        let upgraded = AppPreferences(defaults: defaults)
        XCTAssertTrue(upgraded.showsGroupChat)
        XCTAssertTrue(upgraded.showsEnglishCoach)
    }
}
