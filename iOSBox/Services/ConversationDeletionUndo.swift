import Foundation
import SwiftData

/// Kept in memory only for the short undo window, with no second persistent copy of deleted chats.
@MainActor
struct ConversationDeletionUndo: Identifiable {
    let id = UUID()
    let snapshots: [ConversationBackup]
    let settings: [UUID: Data]
    let drafts: [UUID: ChatDraft]
    let summaries: [RollingContextSummary]

    init(chats: [Conversation], drafts store: ChatDraftStore, summaries summaryStore: RollingContextSummaryStore) throws {
        snapshots = chats.map { BackupService.snapshot($0) }
        settings = Dictionary(uniqueKeysWithValues: chats.compactMap { chat in chat.assistanceSettingsData.map { (chat.id, $0) } })
        var unsent: [UUID: ChatDraft] = [:]
        for chat in chats {
            let draft = try store.draftForRecovery(chat.id)
            if !draft.isEmpty { unsent[chat.id] = draft }
        }
        drafts = unsent
        summaries = chats.compactMap { summaryStore.summary(for: $0.id) }
    }

    func restore(in context: ModelContext, drafts store: ChatDraftStore, summaries summaryStore: RollingContextSummaryStore) throws {
        let existing = Set(try context.fetch(FetchDescriptor<Conversation>()).map(\.id))
        let archive = BackupArchive(formatVersion: BackupArchive.currentFormatVersion, exportedAt: Date(), appVersion: "",
                                    providers: [], presets: [], conversations: snapshots)
        try BackupService.apply(.full(archive), to: context)
        let ids = Set(snapshots.map(\.id))
        for chat in try context.fetch(FetchDescriptor<Conversation>()) where ids.contains(chat.id) {
            if !existing.contains(chat.id) { chat.assistanceSettingsData = settings[chat.id] }
            chat.updatedAt = Date()
        }
        try context.save()
        for summary in summaries where summaryStore.summary(for: summary.conversationID) == nil { summaryStore.save(summary) }
        for (id, draft) in drafts { _ = try store.restoreIfEmpty(draft, for: id) }
        WebDAVAutoSyncCoordinator.shared.markWorkspaceChanged(in: context)
    }
}
