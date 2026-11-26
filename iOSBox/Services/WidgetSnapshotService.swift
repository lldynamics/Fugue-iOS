import Foundation
import SwiftData
import WidgetKit

@MainActor
final class WidgetSnapshotService {
    static let shared = WidgetSnapshotService()
    static let showRecentTitlesKey = "com.iosbox.widgetShowRecentTitles.v1"

    private var lastSyncedSnapshot: WidgetSnapshot?

    var showsRecentTitles: Bool {
        UserDefaults.standard.bool(forKey: Self.showRecentTitlesKey)
    }

    static func makeSnapshot(
        conversations: [Conversation],
        providers: [ProviderConfig],
        bookmarkedCount: Int,
        showsRecentTitles: Bool,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let readyCount = ProviderConfig.readyTargets(in: providers).count
        let recent: [WidgetRecentConversation]
        if showsRecentTitles {
            let sorted = conversations
                .filter { !$0.isDeleted && !$0.messages.isEmpty }
                .sorted { lhs, rhs in
                    if lhs.isPinned != rhs.isPinned {
                        return lhs.isPinned && !rhs.isPinned
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }
            recent = sorted.prefix(3).map { conv in
                WidgetRecentConversation(
                    id: conv.id,
                    title: conv.title,
                    updatedAt: conv.updatedAt,
                    isPinned: conv.isPinned
                )
            }
        } else {
            recent = []
        }
        return WidgetSnapshot(
            updatedAt: now,
            readyModelCount: readyCount,
            bookmarkedCount: max(0, bookmarkedCount),
            showRecentTitles: showsRecentTitles,
            recentConversations: recent
        )
    }

    func sync(context: ModelContext, forceReload: Bool = false, bookmarkedCount suppliedBookmarkedCount: Int? = nil) {
        guard PersistenceController.canCommitUserData(in: context) else { return }
        guard context.container.configurations.allSatisfy({ !$0.isStoredInMemoryOnly }) else { return }

        let conversations = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let providers = (try? context.fetch(FetchDescriptor<ProviderConfig>())) ?? []
        let bookmarkedCount: Int
        if let suppliedBookmarkedCount {
            bookmarkedCount = suppliedBookmarkedCount
        } else {
            let metadataMessages = (try? context.fetch(
                FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.assistanceMetadataData != nil })
            )) ?? []
            bookmarkedCount = metadataMessages.reduce(into: 0) { count, message in
                if message.assistanceMetadata.isBookmarked {
                    count += 1
                }
            }
        }

        let snapshot = Self.makeSnapshot(
            conversations: conversations,
            providers: providers,
            bookmarkedCount: bookmarkedCount,
            showsRecentTitles: showsRecentTitles
        )
        if !forceReload, let last = lastSyncedSnapshot, last.samePayload(as: snapshot) {
            return
        }
        try? WidgetSnapshotStore().save(snapshot)
        lastSyncedSnapshot = snapshot
        WidgetCenter.shared.reloadTimelines(ofKind: QuickEntryWidgetKind.quickLaunch)
    }

    func setShowsRecentTitles(_ enabled: Bool, context: ModelContext) {
        UserDefaults.standard.set(enabled, forKey: Self.showRecentTitlesKey)
        sync(context: context, forceReload: true)
    }
}
