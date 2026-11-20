import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

@MainActor
final class SpotlightIndexService {
    static let shared = SpotlightIndexService()
    static let domainIdentifier = "com.iosbox.spotlight.conversations"
    /// Defaults to `false` (opt-in) so private chat snippets are never written to system-wide Spotlight
    /// unless the user explicitly enables it in Settings.
    static let enabledKey = "com.iosbox.spotlightIndexingEnabled.v1"

    struct IndexedEntry: Equatable, Sendable {
        let identifier: String
        let title: String
        let contentDescription: String
        let keywords: [String]
    }

    private let defaults: UserDefaults
    /// Recorded snapshot of indexed entries for verification and testing.
    private(set) var recentIndexedEntries: [String: IndexedEntry] = [:]
    private var entryOrder: [String] = []
    private static let maxCachedSnapshotEntries = 400

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        handlePreferenceChange(enabled: enabled)
    }

    func handlePreferenceChange(enabled: Bool) {
        if !enabled {
            clearAllIndexedItems()
        } else {
            syncRecentConversations(in: AppRuntime.persistence.container.mainContext)
        }
    }

    func clearAllIndexedItems() {
        recentIndexedEntries.removeAll()
        entryOrder.removeAll()
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteAllSearchableItems(completionHandler: nil)
    }

    func indexConversation(_ conversation: Conversation) {
        guard isEnabled else { return }
        let (items, staleMessageKeys) = buildSearchableItems(for: conversation)
        guard !items.isEmpty || !staleMessageKeys.isEmpty else { return }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        if !staleMessageKeys.isEmpty {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: staleMessageKeys, completionHandler: nil)
        }
        if !items.isEmpty {
            CSSearchableIndex.default().indexSearchableItems(items, completionHandler: nil)
        }
    }

    func removeMessage(conversationID: UUID, messageID: UUID) {
        let key = Self.makeIdentifier(conversationID: conversationID, messageID: messageID)
        recentIndexedEntries.removeValue(forKey: key)
        entryOrder.removeAll { $0 == key }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [key], completionHandler: nil)
    }

    func removeConversation(id: UUID) {
        let prefix = "msg:\(id.uuidString):"
        let convKey = Self.makeIdentifier(conversationID: id, messageID: nil)
        let matchingKeys = recentIndexedEntries.keys.filter { $0 == convKey || $0.hasPrefix(prefix) }
        for k in matchingKeys {
            recentIndexedEntries.removeValue(forKey: k)
        }
        entryOrder.removeAll { $0 == convKey || $0.hasPrefix(prefix) }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [convKey], completionHandler: nil)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["\(Self.domainIdentifier).\(id.uuidString)"], completionHandler: nil)
    }

    func syncRecentConversations(in context: ModelContext, limit: Int = 80) {
        guard isEnabled else { return }
        var descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        guard let list = try? context.fetch(descriptor), !list.isEmpty else { return }
        var batchItems: [CSSearchableItem] = []
        var staleKeys: [String] = []
        for conv in list {
            let (items, stale) = buildSearchableItems(for: conv)
            batchItems.append(contentsOf: items)
            staleKeys.append(contentsOf: stale)
        }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        if !staleKeys.isEmpty {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: staleKeys, completionHandler: nil)
        }
        if !batchItems.isEmpty {
            CSSearchableIndex.default().indexSearchableItems(batchItems, completionHandler: nil)
        }
    }

    private func buildSearchableItems(for conversation: Conversation) -> (items: [CSSearchableItem], staleMessageKeys: [String]) {
        guard !conversation.isDeleted else { return ([], []) }
        let convID = conversation.id.uuidString
        let active = ConversationTree.activeMessages(in: conversation)
        let latestSnippet = active
            .reversed()
            .first(where: { $0.role != .system && !$0.content.isEmpty })?
            .content
            .prefix(240) ?? ""

        var keywords: [String] = ["AI", "夜奔", "Fugue"]
        if let tag = conversation.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            keywords.append(tag)
        }
        if !conversation.assistanceSettings.blindArenaMode,
           let model = conversation.primaryTarget?.modelDisplayName, !model.isEmpty {
            keywords.append(model)
        }

        var searchableItems: [CSSearchableItem] = []

        // 1. Index the conversation itself
        let convIdentifier = Self.makeIdentifier(conversationID: conversation.id, messageID: nil)
        let convDesc = String(latestSnippet)
        let convEntry = IndexedEntry(
            identifier: convIdentifier,
            title: "\(conversation.assistantEmoji) \(conversation.title)",
            contentDescription: convDesc,
            keywords: keywords
        )
        recordSnapshot(convEntry)

        let convAttr = CSSearchableItemAttributeSet(contentType: .text)
        convAttr.title = convEntry.title
        convAttr.contentDescription = convEntry.contentDescription
        convAttr.keywords = convEntry.keywords
        convAttr.contentModificationDate = conversation.updatedAt
        searchableItems.append(CSSearchableItem(
            uniqueIdentifier: convIdentifier,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: convAttr
        ))

        // 2. Index bookmarked highlight answers inside the conversation for direct deep-linking
        let blindMode = conversation.assistanceSettings.blindArenaMode
        let groupedArena = blindMode
            ? Dictionary(grouping: conversation.messages.filter { $0.comparisonGroupID != nil }, by: \.comparisonGroupID)
            : [:]
        var activeBookmarkKeys = Set<String>()
        for msg in conversation.messages where msg.assistanceMetadataData != nil && !msg.content.isEmpty && msg.assistanceMetadata.isBookmarked {
            let msgIdentifier = Self.makeIdentifier(conversationID: conversation.id, messageID: msg.id)
            activeBookmarkKeys.insert(msgIdentifier)
            let speakerLabel: String
            if blindMode, msg.comparisonGroupID != nil {
                speakerLabel = ArenaSynthesis.visibleSpeakerName(
                    for: msg,
                    in: groupedArena[msg.comparisonGroupID] ?? [],
                    blindArenaMode: true
                )
            } else {
                speakerLabel = msg.modelDisplayName
            }
            let titlePrefix = speakerLabel.isEmpty ? conversation.title : "\(conversation.title) · \(speakerLabel)"
            let snippet = String(msg.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(320))
            let msgEntry = IndexedEntry(
                identifier: msgIdentifier,
                title: "⭐️ \(titlePrefix)",
                contentDescription: snippet,
                keywords: keywords + [String(localized: "收藏")]
            )
            recordSnapshot(msgEntry)

            let msgAttr = CSSearchableItemAttributeSet(contentType: .text)
            msgAttr.title = msgEntry.title
            msgAttr.contentDescription = msgEntry.contentDescription
            msgAttr.keywords = msgEntry.keywords
            msgAttr.contentModificationDate = msg.createdAt
            searchableItems.append(CSSearchableItem(
                uniqueIdentifier: msgIdentifier,
                domainIdentifier: "\(Self.domainIdentifier).\(convID)",
                attributeSet: msgAttr
            ))
        }

        // Prune previously indexed message bookmarks that were un-bookmarked or deleted
        let prefix = "msg:\(convID):"
        let staleKeys = recentIndexedEntries.keys.filter { $0.hasPrefix(prefix) && !activeBookmarkKeys.contains($0) }
        for stale in staleKeys {
            recentIndexedEntries.removeValue(forKey: stale)
        }
        if !staleKeys.isEmpty {
            let staleSet = Set(staleKeys)
            entryOrder.removeAll { staleSet.contains($0) }
        }

        return (searchableItems, staleKeys)
    }

    private func recordSnapshot(_ entry: IndexedEntry) {
        if recentIndexedEntries[entry.identifier] == nil {
            entryOrder.append(entry.identifier)
        }
        recentIndexedEntries[entry.identifier] = entry
        while entryOrder.count > Self.maxCachedSnapshotEntries {
            let oldest = entryOrder.removeFirst()
            recentIndexedEntries.removeValue(forKey: oldest)
        }
    }

    nonisolated static func makeIdentifier(conversationID: UUID, messageID: UUID?) -> String {
        if let messageID {
            return "msg:\(conversationID.uuidString):\(messageID.uuidString)"
        }
        return "conv:\(conversationID.uuidString)"
    }

    nonisolated static func parseIdentifier(_ raw: String) -> (conversationID: UUID, messageID: UUID?)? {
        let parts = raw.split(separator: ":")
        if parts.count == 2, parts[0] == "conv", let convID = UUID(uuidString: String(parts[1])) {
            return (convID, nil)
        }
        if parts.count == 3, parts[0] == "msg",
           let convID = UUID(uuidString: String(parts[1])),
           let msgID = UUID(uuidString: String(parts[2])) {
            return (convID, msgID)
        }
        return nil
    }
}
