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
    static let persistedIdentifiersKey = "com.iosbox.spotlightPersistedIdentifiers.v1"
    private static let conversationIndexVersionKey = "com.iosbox.spotlightConversationIndexVersion"
    private var removingPreviewRecords = false

    struct IndexedEntry: Equatable, Sendable {
        let identifier: String
        let title: String
        let contentDescription: String
        let keywords: [String]
    }

    private let defaults: UserDefaults
    private let preferences: AppPreferences?
    /// Recorded snapshot of indexed entries for verification and testing.
    private(set) var recentIndexedEntries: [String: IndexedEntry] = [:]
    /// Persisted identifier set across app restarts so unbookmarked items are reliably deleted.
    private(set) var persistedIdentifiers: Set<String>
    private(set) var lastDeletedIdentifiers: [String] = []
    private var entryOrder: [String] = []
    private static let maxCachedSnapshotEntries = 400
    private static let maxPersistedIdentifiers = 5000

    init(defaults: UserDefaults = .standard, preferences: AppPreferences? = nil) {
        self.defaults = defaults
        self.preferences = preferences
        let stored = defaults.stringArray(forKey: Self.persistedIdentifiersKey) ?? []
        self.persistedIdentifiers = Set(stored)
    }

    var isAppLockActive: Bool {
        (preferences ?? .shared).appLockEnabled
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey) && !isAppLockActive
    }

    var needsLegacyPreviewPurge: Bool {
        CSSearchableIndex.isIndexingAvailable() && defaults.integer(forKey: Self.conversationIndexVersionKey) < 1
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        handlePreferenceChange(enabled: enabled)
    }

    func handlePreferenceChange(enabled: Bool) {
        if !enabled || isAppLockActive {
            clearAllIndexedItems()
        } else {
            syncRecentConversations(in: AppRuntime.persistence.container.mainContext)
        }
    }

    func handleAppLockChange(lockEnabled: Bool, in context: ModelContext? = nil) {
        if lockEnabled {
            clearAllIndexedItems()
        } else if defaults.bool(forKey: Self.enabledKey), let context {
            syncRecentConversations(in: context)
        }
    }

    func clearAllIndexedItems() {
        recentIndexedEntries.removeAll()
        entryOrder.removeAll()
        persistedIdentifiers.removeAll()
        defaults.removeObject(forKey: Self.persistedIdentifiersKey)
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteAllSearchableItems(completionHandler: nil)
    }

    func indexConversation(_ conversation: Conversation) {
        if isAppLockActive {
            if !persistedIdentifiers.isEmpty || !recentIndexedEntries.isEmpty {
                clearAllIndexedItems()
            }
            return
        }
        guard isEnabled else { return }
        let (items, staleMessageKeys) = buildSearchableItems(for: conversation)
        if !staleMessageKeys.isEmpty {
            lastDeletedIdentifiers = staleMessageKeys
        }
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
        if persistedIdentifiers.remove(key) != nil {
            savePersistedIdentifiers()
        }
        lastDeletedIdentifiers = [key]
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [key], completionHandler: nil)
    }

    func removeConversation(id: UUID) {
        let prefix = "msg:\(id.uuidString):"
        let convKey = Self.makeIdentifier(conversationID: id, messageID: nil)
        let knownKeys = Set(recentIndexedEntries.keys).union(persistedIdentifiers)
        let matchingKeys = knownKeys.filter { $0 == convKey || $0.hasPrefix(prefix) }.sorted()
        for k in matchingKeys {
            recentIndexedEntries.removeValue(forKey: k)
            persistedIdentifiers.remove(k)
        }
        if !matchingKeys.isEmpty {
            savePersistedIdentifiers()
            lastDeletedIdentifiers = matchingKeys
        }
        entryOrder.removeAll { $0 == convKey || $0.hasPrefix(prefix) }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let identifiersToDelete = matchingKeys.isEmpty ? [convKey] : matchingKeys
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiersToDelete, completionHandler: nil)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["\(Self.domainIdentifier).\(id.uuidString)"], completionHandler: nil)
    }

    func syncRecentConversations(in context: ModelContext, limit: Int = 80) {
        if isAppLockActive {
            clearAllIndexedItems()
            return
        }
        if needsLegacyPreviewPurge {
            guard !removingPreviewRecords else { return }
            removingPreviewRecords = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.removingPreviewRecords = false }
                do {
                    try await Self.removeLegacyConversationEntries()
                    self.defaults.set(1, forKey: Self.conversationIndexVersionKey)
                    self.syncRecentConversations(in: context, limit: limit)
                } catch { return }
            }
            return
        }
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
        if !staleKeys.isEmpty {
            lastDeletedIdentifiers = staleKeys
        }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        if !staleKeys.isEmpty {
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: staleKeys, completionHandler: nil)
        }
        if !batchItems.isEmpty {
            CSSearchableIndex.default().indexSearchableItems(batchItems, completionHandler: nil)
        }
    }

    private static func removeLegacyConversationEntries() async throws {
        // Deleting a domain also removes its child domains, including bookmarked messages.
        let query = CSSearchQuery(queryString: "title == '*'", queryContext: CSSearchQueryContext())
        var conversationKeys: [String] = []
        for try await result in query.results {
            let key = result.item.uniqueIdentifier
            if let route = parseIdentifier(key), route.messageID == nil {
                conversationKeys.append(key)
            }
        }
        let index = CSSearchableIndex.default()
        for start in stride(from: 0, to: conversationKeys.count, by: 256) {
            let batch = conversationKeys[start..<min(start + 256, conversationKeys.count)]
            try await index.deleteSearchableItems(withIdentifiers: Array(batch))
        }
    }

    private func buildSearchableItems(for conversation: Conversation) -> (items: [CSSearchableItem], staleMessageKeys: [String]) {
        guard !conversation.isDeleted else { return ([], []) }
        let convID = conversation.id.uuidString
        var keywords: [String] = ["AI", "夜奔", "Fugue"]
        if let tag = conversation.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            keywords.append(tag)
        }
        if let model = conversation.primaryTarget?.modelDisplayName, !model.isEmpty {
            keywords.append(model)
        }

        var searchableItems: [CSSearchableItem] = []

        // 1. Index the conversation itself
        let convIdentifier = Self.makeIdentifier(conversationID: conversation.id, messageID: nil)
        let convEntry = IndexedEntry(
            identifier: convIdentifier,
            title: "\(conversation.assistantEmoji) \(conversation.title)",
            contentDescription: "",
            keywords: keywords
        )
        recordSnapshot(convEntry)

        let convAttr = CSSearchableItemAttributeSet(contentType: .text)
        convAttr.title = convEntry.title
        convAttr.keywords = convEntry.keywords
        convAttr.contentModificationDate = conversation.updatedAt
        searchableItems.append(CSSearchableItem(
            uniqueIdentifier: convIdentifier,
            domainIdentifier: Self.domainIdentifier,
            attributeSet: convAttr
        ))

        // 2. Index bookmarked highlight answers inside the conversation for direct deep-linking
        var activeBookmarkKeys = Set<String>()
        for msg in conversation.messages where msg.assistanceMetadataData != nil && !msg.content.isEmpty && msg.assistanceMetadata.isBookmarked {
            let msgIdentifier = Self.makeIdentifier(conversationID: conversation.id, messageID: msg.id)
            activeBookmarkKeys.insert(msgIdentifier)
            let speakerLabel = msg.modelDisplayName
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

        // Prune previously indexed message bookmarks that were un-bookmarked or deleted (including across restarts)
        let prefix = "msg:\(convID):"
        let knownKeys = Set(recentIndexedEntries.keys).union(persistedIdentifiers)
        let staleKeys = knownKeys.filter { $0.hasPrefix(prefix) && !activeBookmarkKeys.contains($0) }.sorted()
        for stale in staleKeys {
            recentIndexedEntries.removeValue(forKey: stale)
            persistedIdentifiers.remove(stale)
        }
        if !staleKeys.isEmpty {
            let staleSet = Set(staleKeys)
            entryOrder.removeAll { staleSet.contains($0) }
        }
        savePersistedIdentifiers()

        return (searchableItems, staleKeys)
    }

    private func recordSnapshot(_ entry: IndexedEntry) {
        if recentIndexedEntries[entry.identifier] == nil {
            entryOrder.append(entry.identifier)
        }
        recentIndexedEntries[entry.identifier] = entry
        persistedIdentifiers.insert(entry.identifier)
        while entryOrder.count > Self.maxCachedSnapshotEntries {
            let oldest = entryOrder.removeFirst()
            recentIndexedEntries.removeValue(forKey: oldest)
        }
    }

    private func savePersistedIdentifiers() {
        var ordered = persistedIdentifiers.sorted()
        if ordered.count > Self.maxPersistedIdentifiers {
            let msgKeys = ordered.filter { $0.hasPrefix("msg:") }
            let convKeys = ordered.filter { !$0.hasPrefix("msg:") }
            ordered = Array((msgKeys + convKeys).prefix(Self.maxPersistedIdentifiers))
            persistedIdentifiers = Set(ordered)
        }
        defaults.set(ordered, forKey: Self.persistedIdentifiersKey)
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
