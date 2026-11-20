import Foundation
import SwiftData

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
    @Transient private var cachedSettingsDecoded: AssistanceSettings?
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

    var assistanceSettings: AssistanceSettings {
        get {
            guard let raw = assistanceSettingsData, !raw.isEmpty else {
                return AssistanceSettings()
            }
            if let cached = cachedSettingsDecoded, cachedSettingsSource == raw {
                return cached
            }
            let decoded = (try? JSONDecoder().decode(AssistanceSettings.self, from: raw)) ?? AssistanceSettings()
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

    var activeBookFriend: BookFriend? {
        let settings = assistanceSettings
        return !isArenaMode && !settings.isGroupMode ? settings.bookFriend : nil
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
        get { assistanceSettings.groupMembers }
        set {
            var s = assistanceSettings
            s.groupMembers = newValue
            assistanceSettings = s
        }
    }

    var activeGroupMembers: [GroupMember] {
        assistanceSettings.groupMembers.filter { !$0.isMuted }
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
    func updateDraftModel(from available: [ResolvedModelTarget], replacingLegacy legacyIDs: Set<String> = []) {
        guard messages.isEmpty, !isGroupMode else { return }
        if isArenaMode {
            let saved = arenaTargets
            let selectedIDs = Set(saved.map(\.id))
            var replacements = available.filter { !selectedIDs.contains($0.id) }
            let current = saved.compactMap { target -> ResolvedModelTarget? in
                if let live = available.first(where: { $0.id == target.id }) { return live }
                guard legacyIDs.contains(target.id),
                      let index = replacements.firstIndex(where: { $0.providerID == target.providerID }) else { return nil }
                return replacements.remove(at: index)
            }
            if current != saved { arenaTargets = current }
            return
        }
        guard let selected = primaryTarget else { return }
        let current = available.first { $0.id == selected.id }
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
