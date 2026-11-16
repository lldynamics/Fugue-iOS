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
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []

    init(
        id: UUID = UUID(),
        title: String = "新对话",
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

    var primaryTarget: ResolvedModelTarget? {
        get {
            guard !primaryTargetData.isEmpty else { return nil }
            return try? JSONDecoder().decode(ResolvedModelTarget.self, from: primaryTargetData)
        }
        set {
            primaryTargetData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var arenaTargets: [ResolvedModelTarget] {
        get {
            guard !arenaTargetsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([ResolvedModelTarget].self, from: arenaTargetsData)) ?? []
        }
        set {
            arenaTargetsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
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
        assistantEmoji = preset.iconEmoji
        systemPrompt = preset.systemPrompt
        temperature = preset.temperature
        useCustomTemperature = preset.useCustomTemperature
        topP = preset.topP
        maxOutputTokens = preset.maxOutputTokens
        contextMessageLimit = preset.contextMessageLimit
        enableThinking = preset.enableThinking
        thinkingBudgetTokens = preset.thinkingBudgetTokens
    }
}
