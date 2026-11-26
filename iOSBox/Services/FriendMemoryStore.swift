import Foundation
import Observation

struct FriendMemorySubject: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case persona
        case bookFriend
    }

    var kind: Kind
    var profileID: UUID?
    var bookID: UUID?
    var characterName: String
    var bookTitle: String?
    var avatarEmoji: String
    /// Only used when `kind == .bookFriend`. `nil` denotes full-book scope ("全书").
    var currentThroughChapter: Int?

    var id: String { friendKey }

    var friendKey: String {
        switch kind {
        case .persona:
            return "persona:\((profileID ?? UUID()).uuidString.lowercased())"
        case .bookFriend:
            let bid = (bookID ?? UUID()).uuidString.lowercased()
            return "book:\(bid):\(Self.normalizeCharacterName(characterName))"
        }
    }

    static func normalizeCharacterName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func persona(profileID: UUID, name: String, emoji: String = "🎭") -> FriendMemorySubject {
        FriendMemorySubject(
            kind: .persona,
            profileID: profileID,
            bookID: nil,
            characterName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            bookTitle: nil,
            avatarEmoji: emoji.isEmpty ? "🎭" : emoji,
            currentThroughChapter: nil
        )
    }

    @MainActor
    static func persona(_ profile: PersonaProfile) -> FriendMemorySubject {
        let member = try? profile.member()
        return .persona(
            profileID: profile.id,
            name: profile.name,
            emoji: member?.avatarEmoji ?? "🎭"
        )
    }

    static func bookFriend(_ friend: BookFriend) -> FriendMemorySubject {
        FriendMemorySubject(
            kind: .bookFriend,
            profileID: nil,
            bookID: friend.bookID,
            characterName: friend.name.trimmingCharacters(in: .whitespacesAndNewlines),
            bookTitle: friend.bookTitle,
            avatarEmoji: "📖",
            currentThroughChapter: friend.throughChapter
        )
    }

    static func from(member: GroupMember) -> FriendMemorySubject? {
        if let bf = member.bookFriend {
            return .bookFriend(bf)
        }
        if let pid = member.profileID {
            return .persona(profileID: pid, name: member.name, emoji: member.avatarEmoji)
        }
        return nil
    }

    @MainActor
    static func subjects(in conversation: Conversation) -> [FriendMemorySubject] {
        guard !conversation.isArenaMode else { return [] }
        if conversation.isGroupMode {
            var seen = Set<String>()
            var result: [FriendMemorySubject] = []
            for member in conversation.activeGroupMembers {
                guard let subject = Self.from(member: member) else { continue }
                if seen.insert(subject.friendKey).inserted {
                    result.append(subject)
                }
            }
            return result
        }
        if let bf = conversation.activeBookFriend {
            return [.bookFriend(bf)]
        }
        if let persona = conversation.assistanceSettings.privatePersona, let pid = persona.profileID {
            return [.persona(profileID: pid, name: persona.name, emoji: persona.avatarEmoji)]
        }
        return []
    }
}

struct FriendMemoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var content: String
    var isEnabled: Bool = true
    /// For `BookFriend`, records the reading chapter scope active when this memory was formed (`nil` = full book).
    var throughChapter: Int? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct FriendConversationCheckpoint: Codable, Equatable, Sendable {
    var lastProcessedMessageID: UUID
    var processedRelevantCount: Int
    var updatedAt: Date = Date()
}

struct FriendMemoryRecord: Codable, Equatable, Sendable {
    var friendKey: String
    var kind: FriendMemorySubject.Kind
    var profileID: UUID? = nil
    var bookID: UUID? = nil
    var displayName: String
    var bookTitle: String? = nil
    var isEnabled: Bool = true
    var autoExtractEnabled: Bool = true
    var relationshipSummary: String = ""
    var summaryThroughChapter: Int? = nil
    var summaryUpdatedAt: Date? = nil
    var entries: [FriendMemoryEntry] = []
    var deletedEntries: [UUID: Date] = [:]
    var conversationCheckpoints: [UUID: FriendConversationCheckpoint] = [:]
    var updatedAt: Date = Date()
    var deletedAllAt: Date? = nil

    var hasAnyStoredContent: Bool {
        !relationshipSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !entries.isEmpty
    }
}

@MainActor
@Observable
final class FriendMemoryStore {
    static let shared: FriendMemoryStore = {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ui-test-workspaces") {
            return FriendMemoryStore(fileURL: URL.temporaryDirectory.appendingPathComponent("ui-test-friend-memory-\(UUID().uuidString).json"))
        }
        #endif
        return FriendMemoryStore()
    }()

    static let maximumEntriesPerFriend = 25
    static let maximumEntryCharacters = 280
    static let maximumSummaryCharacters = 420
    static let autoExtractMinNewMessages = 4

    struct PersistedState: Codable, Equatable, Sendable {
        var formatVersion: Int = 1
        var records: [String: FriendMemoryRecord] = [:]
    }

    struct ExtractionPayload: Codable, Equatable, Sendable {
        var relationshipSummary: String?
        var upsertMemories: [String]?
        var obsoleteMemories: [String]?

        enum CodingKeys: String, CodingKey {
            case relationshipSummary = "relationship_summary"
            case upsertMemories = "upsert_memories"
            case obsoleteMemories = "obsolete_memories"
        }
    }

    private(set) var records: [String: FriendMemoryRecord] = [:]
    var storageError: String?

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let notifySyncChanges: Bool

    init(fileURL: URL? = FriendMemoryStore.defaultFileURL(), notifySyncChanges: Bool? = nil) {
        self.fileURL = fileURL
        self.notifySyncChanges = notifySyncChanges ?? (fileURL == FriendMemoryStore.defaultFileURL())
        reload()
    }

    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("friend-memory-store.json")
    }

    func reload() {
        guard let fileURL else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(PersistedState.self, from: data)
            self.records = decoded.records
            self.storageError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            self.records = [:]
            self.storageError = nil
        } catch {
            self.storageError = error.localizedDescription
        }
    }

    func save(markSyncDirty: Bool = true) {
        if markSyncDirty && notifySyncChanges {
            WebDAVAutoSyncCoordinator.shared.markLocalDataChanged()
        }
        guard let fileURL else { return }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(PersistedState(records: records))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            self.storageError = nil
        } catch {
            self.storageError = error.localizedDescription
        }
    }

    // MARK: - Spoiler & Visibility Gating

    /// Determines whether an item recorded at `itemChapter` may be surfaced when the active chat scope is `scopeChapter`.
    /// - For `.persona`: always visible.
    /// - For `.bookFriend`: `scopeChapter == nil` means full-book scope ("全书"), so all chapters are visible;
    ///   when `scopeChapter == k`, only items recorded at `<= k` are visible to prevent spoiling later chapters.
    nonisolated static func isVisible(
        kind: FriendMemorySubject.Kind,
        itemChapter: Int?,
        scopeChapter: Int?
    ) -> Bool {
        guard kind == .bookFriend else { return true }
        guard let limit = scopeChapter else { return true }
        guard let itemChapter else { return false }
        return itemChapter <= limit
    }

    func record(for subject: FriendMemorySubject) -> FriendMemoryRecord {
        if let existing = records[subject.friendKey] {
            return existing
        }
        return FriendMemoryRecord(
            friendKey: subject.friendKey,
            kind: subject.kind,
            profileID: subject.profileID,
            bookID: subject.bookID,
            displayName: subject.characterName,
            bookTitle: subject.bookTitle
        )
    }

    func visibleEntries(for subject: FriendMemorySubject, includeDisabled: Bool = true) -> [FriendMemoryEntry] {
        let rec = record(for: subject)
        return rec.entries.filter { entry in
            (includeDisabled || entry.isEnabled)
                && Self.isVisible(kind: subject.kind, itemChapter: entry.throughChapter, scopeChapter: subject.currentThroughChapter)
        }
    }

    func hiddenFutureEntryCount(for subject: FriendMemorySubject) -> Int {
        guard subject.kind == .bookFriend, subject.currentThroughChapter != nil else { return 0 }
        let rec = record(for: subject)
        return max(0, rec.entries.count - visibleEntries(for: subject, includeDisabled: true).count)
    }

    func visibleSummary(for subject: FriendMemorySubject) -> String? {
        let rec = record(for: subject)
        let trimmed = rec.relationshipSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              Self.isVisible(kind: subject.kind, itemChapter: rec.summaryThroughChapter, scopeChapter: subject.currentThroughChapter) else {
            return nil
        }
        return trimmed
    }

    func activeVisibleEntryCount(for subject: FriendMemorySubject) -> Int {
        let rec = record(for: subject)
        guard rec.isEnabled else { return 0 }
        return visibleEntries(for: subject, includeDisabled: false).count
    }

    func promptBlock(for subject: FriendMemorySubject, preferEnglish: Bool = false) -> (text: String, entryCount: Int)? {
        let rec = record(for: subject)
        guard rec.isEnabled else { return nil }
        let summary = visibleSummary(for: subject)
        let activeItems = visibleEntries(for: subject, includeDisabled: false)
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard summary != nil || !activeItems.isEmpty else { return nil }

        var lines: [String] = []
        if preferEnglish {
            lines.append("[Shared Memory with the User — weave naturally into your tone and continuity without parroting verbatim; if anything conflicts with the user's latest message, follow the latest message]")
            if let summary {
                lines.append("Relationship & recent context: \(summary)")
            }
            for item in activeItems {
                lines.append("- \(item)")
            }
        } else {
            lines.append("[你与这位用户的专属共同记忆（请在语气与对话延续中自然体现熟悉感，不要生硬逐字复述；若与用户最新表达冲突，以最新表达为准）]")
            if let summary {
                lines.append("关系与近期脉络：\(summary)")
            }
            for item in activeItems {
                lines.append("- \(item)")
            }
        }
        return (lines.joined(separator: "\n"), activeItems.count + (summary != nil ? 1 : 0))
    }

    // MARK: - User Mutations

    private func mutate(
        for subject: FriendMemorySubject,
        now: Date = Date(),
        _ block: (inout FriendMemoryRecord) -> Void
    ) {
        var rec = record(for: subject)
        rec.displayName = subject.characterName
        if let bookTitle = subject.bookTitle, !bookTitle.isEmpty {
            rec.bookTitle = bookTitle
        }
        block(&rec)
        rec.updatedAt = now
        records[subject.friendKey] = rec
        save()
    }

    func setEnabled(_ enabled: Bool, for subject: FriendMemorySubject) {
        mutate(for: subject) { $0.isEnabled = enabled }
    }

    func setAutoExtractEnabled(_ enabled: Bool, for subject: FriendMemorySubject) {
        mutate(for: subject) { $0.autoExtractEnabled = enabled }
    }

    func updateRelationshipSummary(_ summary: String, for subject: FriendMemorySubject, now: Date = Date()) {
        let cleaned = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumSummaryCharacters))
        mutate(for: subject, now: now) { rec in
            rec.relationshipSummary = cleaned
            rec.summaryThroughChapter = subject.kind == .bookFriend ? subject.currentThroughChapter : nil
            rec.summaryUpdatedAt = now
        }
    }

    @discardableResult
    func addEntry(_ content: String, for subject: FriendMemorySubject, now: Date = Date()) -> FriendMemoryEntry? {
        let cleaned = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumEntryCharacters))
        guard !cleaned.isEmpty else { return nil }
        var createdEntry: FriendMemoryEntry?
        mutate(for: subject, now: now) { rec in
            if let idx = rec.entries.firstIndex(where: { $0.content.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                rec.entries[idx].content = cleaned
                rec.entries[idx].isEnabled = true
                rec.entries[idx].updatedAt = now
                if subject.kind == .bookFriend {
                    rec.entries[idx].throughChapter = Self.minSpoilerChapter(rec.entries[idx].throughChapter, subject.currentThroughChapter)
                }
                createdEntry = rec.entries[idx]
            } else {
                let entry = FriendMemoryEntry(
                    content: cleaned,
                    isEnabled: true,
                    throughChapter: subject.kind == .bookFriend ? subject.currentThroughChapter : nil,
                    createdAt: now,
                    updatedAt: now
                )
                rec.entries.insert(entry, at: 0)
                Self.trimEntriesToCap(&rec)
                createdEntry = entry
            }
        }
        return createdEntry
    }

    func updateEntry(
        id: UUID,
        content: String? = nil,
        isEnabled: Bool? = nil,
        for subject: FriendMemorySubject,
        now: Date = Date()
    ) {
        mutate(for: subject, now: now) { rec in
            guard let idx = rec.entries.firstIndex(where: { $0.id == id }) else { return }
            if let content {
                let cleaned = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumEntryCharacters))
                if !cleaned.isEmpty {
                    rec.entries[idx].content = cleaned
                }
            }
            if let isEnabled {
                rec.entries[idx].isEnabled = isEnabled
            }
            rec.entries[idx].updatedAt = now
        }
    }

    func deleteEntry(id: UUID, for subject: FriendMemorySubject, now: Date = Date()) {
        mutate(for: subject, now: now) { rec in
            rec.entries.removeAll { $0.id == id }
            rec.deletedEntries[id] = now
        }
    }

    func clearMemories(for subject: FriendMemorySubject, now: Date = Date()) {
        mutate(for: subject, now: now) { rec in
            for entry in rec.entries {
                rec.deletedEntries[entry.id] = now
            }
            rec.entries.removeAll()
            rec.relationshipSummary = ""
            rec.summaryThroughChapter = nil
            rec.summaryUpdatedAt = now
            rec.conversationCheckpoints.removeAll()
            rec.deletedAllAt = now
        }
    }

    func removeMemoriesForPersona(profileID: UUID, at now: Date = Date()) {
        let key = "persona:\(profileID.uuidString.lowercased())"
        var rec = records[key] ?? FriendMemoryRecord(
            friendKey: key,
            kind: .persona,
            profileID: profileID,
            displayName: ""
        )
        for entry in rec.entries {
            rec.deletedEntries[entry.id] = now
        }
        rec.entries.removeAll()
        rec.relationshipSummary = ""
        rec.summaryThroughChapter = nil
        rec.summaryUpdatedAt = now
        rec.conversationCheckpoints.removeAll()
        rec.deletedAllAt = now
        rec.updatedAt = now
        records[key] = rec
        save()
    }

    func removeMemoriesForBook(bookID: UUID, at now: Date = Date()) {
        let prefix = "book:\(bookID.uuidString.lowercased()):"
        var changed = false
        for key in Array(records.keys) where key.hasPrefix(prefix) || records[key]?.bookID == bookID {
            guard var rec = records[key] else { continue }
            for entry in rec.entries {
                rec.deletedEntries[entry.id] = now
            }
            rec.entries.removeAll()
            rec.relationshipSummary = ""
            rec.summaryThroughChapter = nil
            rec.summaryUpdatedAt = now
            rec.conversationCheckpoints.removeAll()
            rec.deletedAllAt = now
            rec.updatedAt = now
            records[key] = rec
            changed = true
        }
        if changed {
            save()
        }
    }

    // MARK: - Extraction Parsing & Incremental Consolidation

    nonisolated static func parseExtractionPayload(from rawOutput: String) -> ExtractionPayload? {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidates: [String] = [trimmed]
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}"),
           firstBrace <= lastBrace {
            candidates.insert(String(trimmed[firstBrace...lastBrace]), at: 0)
        }

        let decoder = JSONDecoder()
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let payload = try? decoder.decode(ExtractionPayload.self, from: data) {
                return payload
            }
        }
        return nil
    }

    @discardableResult
    func applyExtraction(
        _ payload: ExtractionPayload,
        for subject: FriendMemorySubject,
        conversationID: UUID? = nil,
        checkpoint: FriendConversationCheckpoint? = nil,
        now: Date = Date()
    ) -> Bool {
        var didChangeContent = false
        mutate(for: subject, now: now) { rec in
            if let rawSummary = payload.relationshipSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawSummary.isEmpty {
                let boundedSummary = String(rawSummary.prefix(Self.maximumSummaryCharacters))
                let canOverwriteSummary: Bool
                if subject.kind == .bookFriend {
                    // Do not overwrite a later-chapter summary with an earlier-chapter rewind unless visible at current scope.
                    canOverwriteSummary = rec.relationshipSummary.isEmpty
                        || Self.isVisible(kind: .bookFriend, itemChapter: rec.summaryThroughChapter, scopeChapter: subject.currentThroughChapter)
                } else {
                    canOverwriteSummary = true
                }
                if canOverwriteSummary && rec.relationshipSummary != boundedSummary {
                    rec.relationshipSummary = boundedSummary
                    rec.summaryThroughChapter = subject.kind == .bookFriend
                        ? Self.maxSpoilerChapter(rec.summaryThroughChapter, subject.currentThroughChapter, allowRestrictingFromNil: rec.summaryUpdatedAt == nil)
                        : nil
                    rec.summaryUpdatedAt = now
                    didChangeContent = true
                }
            }

            if let obsoleteList = payload.obsoleteMemories {
                for rawObs in obsoleteList {
                    let obs = rawObs.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !obs.isEmpty else { continue }
                    let matchingIndices = rec.entries.indices.filter { idx in
                        let entry = rec.entries[idx]
                        guard Self.isVisible(kind: subject.kind, itemChapter: entry.throughChapter, scopeChapter: subject.currentThroughChapter) else {
                            return false
                        }
                        return entry.content.caseInsensitiveCompare(obs) == .orderedSame
                    }
                    for idx in matchingIndices.reversed() {
                        let removed = rec.entries.remove(at: idx)
                        rec.deletedEntries[removed.id] = now
                        didChangeContent = true
                    }
                }
            }

            if let upserts = payload.upsertMemories {
                for rawFact in upserts.reversed() {
                    let cleaned = String(rawFact.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumEntryCharacters))
                    guard !cleaned.isEmpty else { continue }
                    if let existingIdx = rec.entries.firstIndex(where: { $0.content.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                        rec.entries[existingIdx].updatedAt = now
                        if subject.kind == .bookFriend {
                            rec.entries[existingIdx].throughChapter = Self.minSpoilerChapter(
                                rec.entries[existingIdx].throughChapter,
                                subject.currentThroughChapter
                            )
                        }
                    } else {
                        let entry = FriendMemoryEntry(
                            content: cleaned,
                            isEnabled: true,
                            throughChapter: subject.kind == .bookFriend ? subject.currentThroughChapter : nil,
                            createdAt: now,
                            updatedAt: now
                        )
                        rec.entries.insert(entry, at: 0)
                        didChangeContent = true
                    }
                }
            }

            Self.trimEntriesToCap(&rec, now: now)
            if let conversationID, let checkpoint {
                rec.conversationCheckpoints[conversationID] = checkpoint
            }
        }
        return didChangeContent
    }

    func updateCheckpoint(_ checkpoint: FriendConversationCheckpoint, conversationID: UUID, for subject: FriendMemorySubject) {
        var rec = record(for: subject)
        rec.conversationCheckpoints[conversationID] = checkpoint
        records[subject.friendKey] = rec
        save(markSyncDirty: false)
    }

    // MARK: - Backup & Multi-Device Sync

    func exportState() -> PersistedState? {
        guard !records.isEmpty else { return nil }
        return PersistedState(records: records)
    }

    func mergeImported(
        _ incoming: PersistedState,
        deletedPersonaIDs: Set<UUID> = [],
        deletedBookIDs: Set<UUID> = [],
        enforcingTombstones: Bool = false
    ) {
        var mutated = false
        let now = Date()

        for (key, remote) in incoming.records {
            if enforcingTombstones {
                if let pid = remote.profileID, deletedPersonaIDs.contains(pid) { continue }
                if let bid = remote.bookID, deletedBookIDs.contains(bid) { continue }
            }

            guard var local = records[key] else {
                var imported = remote
                Self.trimEntriesToCap(&imported, now: now)
                records[key] = imported
                mutated = true
                continue
            }

            // Merge full-clear / cascade tombstones
            let effectiveClearDate: Date? = {
                switch (local.deletedAllAt, remote.deletedAllAt) {
                case let (l?, r?): return max(l, r)
                case let (l?, nil): return enforcingTombstones ? l : nil
                case let (nil, r?): return enforcingTombstones ? r : nil
                case (nil, nil): return nil
                }
            }()

            if let clearDate = effectiveClearDate {
                local.deletedAllAt = clearDate
            }

            // Merge per-entry deletion tombstones
            var mergedDeleted = local.deletedEntries
            for (entryID, delAt) in remote.deletedEntries {
                if let existing = mergedDeleted[entryID] {
                    if delAt > existing { mergedDeleted[entryID] = delAt }
                } else if enforcingTombstones {
                    mergedDeleted[entryID] = delAt
                }
            }
            local.deletedEntries = mergedDeleted

            // Settings & metadata follow newer `updatedAt`
            if remote.updatedAt > local.updatedAt {
                local.isEnabled = remote.isEnabled
                local.autoExtractEnabled = remote.autoExtractEnabled
                if !remote.displayName.isEmpty { local.displayName = remote.displayName }
                if let bt = remote.bookTitle, !bt.isEmpty { local.bookTitle = bt }
            }

            // Merge relationship summary
            let localSummaryTime = local.summaryUpdatedAt ?? local.updatedAt
            let remoteSummaryTime = remote.summaryUpdatedAt ?? remote.updatedAt
            if let clearDate = effectiveClearDate, max(localSummaryTime, remoteSummaryTime) <= clearDate {
                local.relationshipSummary = ""
                local.summaryThroughChapter = nil
                local.summaryUpdatedAt = clearDate
            } else if remoteSummaryTime > localSummaryTime {
                let remoteTrimmed = remote.relationshipSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !remoteTrimmed.isEmpty || enforcingTombstones {
                    local.relationshipSummary = remote.relationshipSummary
                    local.summaryThroughChapter = remote.summaryThroughChapter
                    local.summaryUpdatedAt = remote.summaryUpdatedAt ?? remote.updatedAt
                }
            }

            // Merge entries by ID and deduplicate identical content
            var byID: [UUID: FriendMemoryEntry] = Dictionary(
                local.entries.map { ($0.id, $0) },
                uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b }
            )
            for entry in remote.entries {
                if let existing = byID[entry.id] {
                    if entry.updatedAt > existing.updatedAt {
                        byID[entry.id] = entry
                    }
                } else {
                    byID[entry.id] = entry
                }
            }

            var filteredEntries = byID.values.filter { entry in
                if let clearDate = effectiveClearDate, entry.updatedAt <= clearDate {
                    return false
                }
                if enforcingTombstones, let delDate = mergedDeleted[entry.id], entry.updatedAt <= delDate {
                    return false
                }
                return !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            filteredEntries.sort { $0.updatedAt > $1.updatedAt }

            var deduped: [FriendMemoryEntry] = []
            for entry in filteredEntries {
                if let dupIdx = deduped.firstIndex(where: { $0.content.caseInsensitiveCompare(entry.content) == .orderedSame }) {
                    if local.kind == .bookFriend {
                        deduped[dupIdx].throughChapter = Self.minSpoilerChapter(deduped[dupIdx].throughChapter, entry.throughChapter)
                    }
                } else {
                    deduped.append(entry)
                }
            }
            local.entries = deduped

            for (convID, remoteCP) in remote.conversationCheckpoints {
                if let localCP = local.conversationCheckpoints[convID] {
                    if remoteCP.updatedAt > localCP.updatedAt {
                        local.conversationCheckpoints[convID] = remoteCP
                    }
                } else {
                    local.conversationCheckpoints[convID] = remoteCP
                }
            }

            Self.trimEntriesToCap(&local, now: now)
            local.updatedAt = max(local.updatedAt, remote.updatedAt)
            if records[key] != local {
                records[key] = local
                mutated = true
            }
        }

        if enforcingTombstones {
            for pid in deletedPersonaIDs {
                let key = "persona:\(pid.uuidString.lowercased())"
                if let existing = records[key], existing.hasAnyStoredContent {
                    var cleared = existing
                    cleared.entries.removeAll()
                    cleared.relationshipSummary = ""
                    cleared.deletedAllAt = now
                    cleared.updatedAt = now
                    records[key] = cleared
                    mutated = true
                }
            }
            for bid in deletedBookIDs {
                let prefix = "book:\(bid.uuidString.lowercased()):"
                for key in Array(records.keys) where key.hasPrefix(prefix) || records[key]?.bookID == bid {
                    if let existing = records[key], existing.hasAnyStoredContent {
                        var cleared = existing
                        cleared.entries.removeAll()
                        cleared.relationshipSummary = ""
                        cleared.deletedAllAt = now
                        cleared.updatedAt = now
                        records[key] = cleared
                        mutated = true
                    }
                }
            }
        }

        if mutated {
            save(markSyncDirty: false)
        }
    }

    // MARK: - Internal Helpers

    private static func minSpoilerChapter(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case let (x?, y?): return min(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    private static func maxSpoilerChapter(_ a: Int?, _ b: Int?, allowRestrictingFromNil: Bool) -> Int? {
        if allowRestrictingFromNil { return b }
        switch (a, b) {
        case (nil, _), (_, nil): return nil
        case let (x?, y?): return max(x, y)
        }
    }

    private static func trimEntriesToCap(_ rec: inout FriendMemoryRecord, now: Date = Date()) {
        guard rec.entries.count > maximumEntriesPerFriend else { return }
        // Sort enabled before disabled, then newest updatedAt first, keeping top `maximumEntriesPerFriend`.
        let sorted = rec.entries.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        let kept = Array(sorted.prefix(maximumEntriesPerFriend))
        let keptIDs = Set(kept.map(\.id))
        for dropped in rec.entries where !keptIDs.contains(dropped.id) {
            rec.deletedEntries[dropped.id] = now
        }
        rec.entries = kept.sorted { $0.updatedAt > $1.updatedAt }
    }
}
