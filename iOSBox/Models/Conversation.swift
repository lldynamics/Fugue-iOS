import Foundation
import SwiftData

struct ImportedOrganization: Codable, Equatable {
    var title: String
    var isPinned: Bool
    var folderTag: String?
}

struct ImportedSettingsVersion: Codable, Equatable {
    let digest: UUID
    let exportedAt: Date
}

struct ConversationOrganizationEdits: Codable, Equatable {
    var title: TimeInterval?
    var pin: TimeInterval?
    var tag: TimeInterval?
}

struct ConversationBackupState: Codable, Equatable {
    var lastImportedOrganization: ImportedOrganization?
    var lastImportedSettings: ImportedSettingsVersion?
    var legacyImportID: UUID?
    var organizationEdits: ConversationOrganizationEdits?
}

// Keep the original settings keys at the top level for old databases and older app versions.
private struct StoredConversationSettings: Codable {
    var settings = AssistanceSettings()
    var backupState = ConversationBackupState()

    private enum CodingKeys: String, CodingKey { case backupState }
    init() {}
    init(from decoder: Decoder) throws {
        settings = try AssistanceSettings(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backupState = try container.decodeIfPresent(ConversationBackupState.self, forKey: .backupState) ?? .init()
    }
    func encode(to encoder: Encoder) throws {
        try settings.encode(to: encoder)
        if backupState != .init() {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(backupState, forKey: .backupState)
        }
    }
}

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var isPinned: Bool
    var assistantID: UUID?
    var assistantEmoji: String
    var systemPrompt: String
    var temperature: Double
    var useCustomTemperature: Bool
    var topP: Double
    var maxOutputTokens: Int
    var contextMessageLimit: Int
    var enableThinking: Bool
    var thinkingBudgetTokens: Int
    var isArenaMode: Bool
    var primaryTargetData: Data
    var arenaTargetsData: Data
    @Attribute(.externalStorage) var assistanceSettingsData: Data?
    var activeLeafMessageID: UUID?
    var folderTag: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    @Transient private var cachedSettingsSource: Data?
    @Transient private var cachedSettingsDecoded: StoredConversationSettings?
    @Transient private var cachedPrimarySource: Data?
    @Transient private var cachedPrimaryDecoded: ResolvedModelTarget??
    @Transient private var cachedArenaSource: Data?
    @Transient private var cachedArenaDecoded: [ResolvedModelTarget]?

    /// Localized placeholder title; replaced by the first message once the user sends one.
    static var defaultTitle: String { String(localized: "新对话") }

    /// True for the placeholder title in any language the app has run in.
    static func isDefaultTitle(_ title: String) -> Bool {
        title == defaultTitle || title == "新对话" || title == "New Chat"
    }

    init(
        id: UUID = UUID(),
        title: String = Conversation.defaultTitle,
        isPinned: Bool = false,
        assistantID: UUID? = nil,
        assistantEmoji: String = "✨",
        systemPrompt: String = "",
        temperature: Double = 0.7,
        useCustomTemperature: Bool = true,
        topP: Double = 1.0,
        maxOutputTokens: Int = 0,
        contextMessageLimit: Int = 20,
        enableThinking: Bool = true,
        thinkingBudgetTokens: Int = 4096,
        isArenaMode: Bool = false,
        primaryTarget: ResolvedModelTarget? = nil,
        arenaTargets: [ResolvedModelTarget] = []
    ) {
        self.id = id
        self.title = title
        self.isPinned = isPinned
        self.assistantID = assistantID
        self.assistantEmoji = assistantEmoji
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.useCustomTemperature = useCustomTemperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.contextMessageLimit = contextMessageLimit
        self.enableThinking = enableThinking
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.isArenaMode = isArenaMode
        self.primaryTargetData = (try? JSONEncoder().encode(primaryTarget)) ?? Data()
        self.arenaTargetsData = (try? JSONEncoder().encode(arenaTargets)) ?? Data()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    private var storedSettings: StoredConversationSettings {
        get {
            guard let raw = assistanceSettingsData, !raw.isEmpty else {
                return StoredConversationSettings()
            }
            if let cached = cachedSettingsDecoded, cachedSettingsSource == raw {
                return cached
            }
            let decoded = (try? JSONDecoder().decode(StoredConversationSettings.self, from: raw)) ?? StoredConversationSettings()
            cachedSettingsSource = raw
            cachedSettingsDecoded = decoded
            return decoded
        }
        set {
            let encoded = try? JSONEncoder().encode(newValue)
            assistanceSettingsData = encoded
            cachedSettingsSource = encoded
            cachedSettingsDecoded = newValue
        }
    }

    var assistanceSettings: AssistanceSettings {
        get { storedSettings.settings }
        set { storedSettings.settings = newValue }
    }

    var backupState: ConversationBackupState {
        get { storedSettings.backupState }
        set { storedSettings.backupState = newValue }
    }

    func rename(to value: String) {
        guard title != value else { return }
        title = value
        recordOrganizationEdit(\.title)
    }

    func setPinned(_ value: Bool) {
        guard isPinned != value else { return }
        isPinned = value
        recordOrganizationEdit(\.pin)
    }

    func setFolderTag(_ value: String?) {
        guard folderTag != value else { return }
        folderTag = value
        recordOrganizationEdit(\.tag)
    }

    private func recordOrganizationEdit(_ field: WritableKeyPath<ConversationOrganizationEdits, TimeInterval?>) {
        var edits = backupState.organizationEdits ?? .init()
        edits[keyPath: field] = Date().timeIntervalSince1970
        backupState.organizationEdits = edits
    }

    var readingVolumeID: UUID? {
        guard !isArenaMode, !isGroupMode else { return nil }
        return activeBookFriend?.bookID ?? assistanceSettings.knowledgeVolumeIDs.first
    }

    var activeBookFriend: BookFriend? {
        let settings = assistanceSettings
        return !isArenaMode && !settings.isGroupMode ? settings.bookFriend : nil
    }

    /// A shared knowledge document obeys the tightest reading boundary for that book in this chat.
    var readingChapterLimits: [UUID: Int] {
        let friends = isGroupMode ? groupMembers.compactMap(\.bookFriend) : [activeBookFriend].compactMap { $0 }
        var limits: [UUID: Int] = [:]
        for friend in friends {
            if let end = friend.throughChapter {
                let limit = (0..<BookManuscript.maximumChapters).contains(end) ? end : -1
                limits[friend.bookID] = min(limits[friend.bookID] ?? limit, limit)
            }
        }
        return limits
    }

    var isGroupMode: Bool {
        get { assistanceSettings.isGroupMode }
        set {
            var s = assistanceSettings
            s.isGroupMode = newValue
            assistanceSettings = s
            if newValue {
                isArenaMode = false
            }
        }
    }

    var groupMembers: [GroupMember] {
        get {
            var seen = Set<UUID>()
            return assistanceSettings.groupMembers.filter { seen.insert($0.id).inserted }
        }
        set {
            var s = assistanceSettings
            s.groupMembers = newValue
            assistanceSettings = s
        }
    }

    var activeGroupMembers: [GroupMember] {
        groupMembers.filter { !$0.isMuted }
    }

    var primaryTarget: ResolvedModelTarget? {
        get {
            let raw = primaryTargetData
            guard !raw.isEmpty else { return nil }
            if let cached = cachedPrimaryDecoded, cachedPrimarySource == raw {
                return cached
            }
            let decoded = try? JSONDecoder().decode(ResolvedModelTarget.self, from: raw)
            cachedPrimarySource = raw
            cachedPrimaryDecoded = decoded
            return decoded
        }
        set {
            let encoded = (try? JSONEncoder().encode(newValue)) ?? Data()
            primaryTargetData = encoded
            cachedPrimarySource = encoded
            cachedPrimaryDecoded = newValue
        }
    }

    var arenaTargets: [ResolvedModelTarget] {
        get {
            let raw = arenaTargetsData
            guard !raw.isEmpty else { return [] }
            if let cached = cachedArenaDecoded, cachedArenaSource == raw {
                return cached
            }
            let decoded = (try? JSONDecoder().decode([ResolvedModelTarget].self, from: raw)) ?? []
            cachedArenaSource = raw
            cachedArenaDecoded = decoded
            return decoded
        }
        set {
            let encoded = (try? JSONEncoder().encode(newValue)) ?? Data()
            arenaTargetsData = encoded
            cachedArenaSource = encoded
            cachedArenaDecoded = newValue
        }
    }

    /// Refresh an unsent chat's selection within its chosen API account. Sent messages retain their model snapshots.
    func updateDraftModel(from available: [ResolvedModelTarget], replacingLegacy legacyIDs: Set<String> = [],
                          preservingUnavailableProviders providerIDs: Set<UUID> = []) {
        guard messages.isEmpty, !isGroupMode else { return }
        if isArenaMode {
            let saved = arenaTargets
            let selectedIDs = Set(saved.map(\.id))
            var replacements = available.filter { !selectedIDs.contains($0.id) }
            let current = saved.compactMap { target -> ResolvedModelTarget? in
                if let live = available.first(where: { $0.id == target.id }) { return live }
                if providerIDs.contains(target.providerID) { return target }
                guard legacyIDs.contains(target.id),
                      let index = replacements.firstIndex(where: { $0.providerID == target.providerID }) else { return nil }
                return replacements.remove(at: index)
            }
            if current != saved { arenaTargets = current }
            return
        }
        guard let selected = primaryTarget else { return }
        let current = available.first { $0.id == selected.id }
        if current == nil && providerIDs.contains(selected.providerID) { return }
        let next = current ?? (legacyIDs.contains(selected.id) ? available.first { $0.providerID == selected.providerID } : nil)
        if selected != next { primaryTarget = next }
    }

    var sortedMessages: [ChatMessage] {
        messages.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func normalizeMessageOrderIfNeeded() {
        guard messages.contains(where: { !(0...Int(Int32.max)).contains($0.sortIndex) }) else { return }
        for (index, message) in sortedMessages.enumerated() {
            message.sortIndex = index
        }
    }

    func nextMessageSortIndex() -> Int {
        normalizeMessageOrderIfNeeded()
        return (sortedMessages.last?.sortIndex ?? 0) + 1
    }

    func applyPreset(_ preset: AssistantPreset) {
        assistantID = preset.id
        if !isGroupMode {
            assistantEmoji = preset.iconEmoji
            systemPrompt = preset.systemPrompt
            temperature = preset.temperature
            useCustomTemperature = preset.useCustomTemperature
        }
        topP = preset.topP
        maxOutputTokens = preset.maxOutputTokens
        contextMessageLimit = preset.contextMessageLimit
        enableThinking = preset.enableThinking
        thinkingBudgetTokens = preset.thinkingBudgetTokens
        let boundVolumes = preset.knowledgeVolumeIDs
        if !boundVolumes.isEmpty {
            var s = assistanceSettings
            s.knowledgeVolumeIDs = boundVolumes
            assistanceSettings = s
        }
    }
}
