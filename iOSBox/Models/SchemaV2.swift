import Foundation
import SwiftData

/// Frozen V2 on-disk model definitions. Never change these stored properties.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ProviderConfig.self, AssistantPreset.self, Conversation.self, ChatMessage.self]
    }

    @Model
    final class ProviderConfig {
        @Attribute(.unique) var id: UUID
        var name: String
        var protocolRaw: String
        var baseURL: String
        var iconSymbol: String
        var accentHex: String
        var isEnabled: Bool
        var sortOrder: Int
        var modelsData: Data
        var headersData: Data
        var notes: String
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            protocolType: APIProtocolType,
            baseURL: String,
            iconSymbol: String = "server.rack",
            accentHex: String = "#3F6EF6",
            isEnabled: Bool = true,
            sortOrder: Int = 0,
            models: [ModelSpec] = [],
            customHeaders: [CustomHeader] = [],
            notes: String = ""
        ) {
            self.id = id
            self.name = name
            self.protocolRaw = protocolType.rawValue
            self.baseURL = baseURL
            self.iconSymbol = iconSymbol
            self.accentHex = accentHex
            self.isEnabled = isEnabled
            self.sortOrder = sortOrder
            self.modelsData = (try? JSONEncoder().encode(models)) ?? Data()
            self.headersData = (try? JSONEncoder().encode(customHeaders)) ?? Data()
            self.notes = notes
            self.createdAt = Date()
            self.updatedAt = Date()
        }
    }

    @Model
    final class AssistantPreset {
        @Attribute(.unique) var id: UUID
        var name: String
        var iconEmoji: String
        var subtitle: String
        var systemPrompt: String
        var temperature: Double
        var useCustomTemperature: Bool
        var topP: Double
        var maxOutputTokens: Int
        var contextMessageLimit: Int
        var enableThinking: Bool
        var thinkingBudgetTokens: Int
        var isBuiltIn: Bool
        var sortOrder: Int
        var createdAt: Date

        init(
            id: UUID = UUID(),
            name: String,
            iconEmoji: String = "🤖",
            subtitle: String = "",
            systemPrompt: String = "",
            temperature: Double = 0.7,
            useCustomTemperature: Bool = true,
            topP: Double = 1.0,
            maxOutputTokens: Int = 0,
            contextMessageLimit: Int = 20,
            enableThinking: Bool = true,
            thinkingBudgetTokens: Int = 4096,
            isBuiltIn: Bool = false,
            sortOrder: Int = 0
        ) {
            self.id = id
            self.name = name
            self.iconEmoji = iconEmoji
            self.subtitle = subtitle
            self.systemPrompt = systemPrompt
            self.temperature = temperature
            self.useCustomTemperature = useCustomTemperature
            self.topP = topP
            self.maxOutputTokens = maxOutputTokens
            self.contextMessageLimit = contextMessageLimit
            self.enableThinking = enableThinking
            self.thinkingBudgetTokens = thinkingBudgetTokens
            self.isBuiltIn = isBuiltIn
            self.sortOrder = sortOrder
            self.createdAt = Date()
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
        var createdAt: Date
        var updatedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
        var messages: [ChatMessage] = []

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
    }

    @Model
    final class ChatMessage {
        @Attribute(.unique) var id: UUID
        var roleRaw: String
        var content: String
        var reasoningContent: String
        /// JSON-encoded attachments (images / PDFs as base64). Large values are stored outside
        /// the SQLite table so conversation lists and queries don't drag megabytes of blobs along.
        @Attribute(.externalStorage) var attachmentsData: Data
        var providerID: UUID?
        var providerName: String
        var modelID: String
        var modelDisplayName: String
        var accentHex: String
        var comparisonGroupID: UUID?
        var isSelectedInGroup: Bool
        var isStreaming: Bool
        var errorMessage: String?
        /// Raw `LLMFinishReason` when the reply ended abnormally (truncated / filtered). Added in schema V2.
        var finishReason: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var latencyMs: Int?
        var thinkingDurationMs: Int?
        var sortIndex: Int
        var createdAt: Date

        var conversation: Conversation?

        init(
            id: UUID = UUID(),
            role: MessageRole,
            content: String = "",
            reasoningContent: String = "",
            attachments: [MessageAttachment] = [],
            target: ResolvedModelTarget? = nil,
            comparisonGroupID: UUID? = nil,
            isSelectedInGroup: Bool = true,
            isStreaming: Bool = false,
            sortIndex: Int = 0,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.roleRaw = role.rawValue
            self.content = content
            self.reasoningContent = reasoningContent
            self.attachmentsData = (try? JSONEncoder().encode(attachments)) ?? Data()
            self.providerID = target?.providerID
            self.providerName = target?.providerName ?? ""
            self.modelID = target?.modelID ?? ""
            self.modelDisplayName = target?.modelDisplayName ?? ""
            self.accentHex = target?.accentHex ?? "#3F6EF6"
            self.comparisonGroupID = comparisonGroupID
            self.isSelectedInGroup = isSelectedInGroup
            self.isStreaming = isStreaming
            self.sortIndex = sortIndex
            self.createdAt = createdAt
        }
    }
}
