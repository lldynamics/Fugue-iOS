import Foundation
import SwiftData

/// Frozen V4 on-disk model definitions. Never change these stored properties.
enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ProviderConfig.self, AssistantPreset.self, Conversation.self, ChatMessage.self, RequestRecord.self, PersonalMemory.self]
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
        var assistanceSettingsData: Data?
        var createdAt: Date
        var updatedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
        var messages: [ChatMessage] = []

        init(
            id: UUID = UUID(),
            title: String = "",
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
        var finishReason: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var latencyMs: Int?
        var thinkingDurationMs: Int?
        var synthesisSourceDigest: String?
        var assistanceMetadataData: Data?
        @Relationship(deleteRule: .nullify) var latestRequest: RequestRecord?
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

    @Model
    final class RequestRecord {
        @Attribute(.unique) var id: UUID
        var operationID: UUID
        var attempt: Int
        var conversationID: UUID
        var messageID: UUID
        var providerID: UUID
        var providerName: String
        var modelID: String
        var modelDisplayName: String
        var protocolRaw: String
        var kindRaw: String
        var statusRaw: String
        var startedAt: Date
        var endedAt: Date?
        var firstReasoningMs: Int?
        var firstContentMs: Int?
        var lastOutputMs: Int?
        var durationMs: Int?
        var outputChunkCount: Int
        var isStreamed: Bool
        var promptTokens: Int?
        var completionTokens: Int?
        var httpStatus: Int?
        var inputPricePerMillion: Double?
        var outputPricePerMillion: Double?
        var currency: String?

        init(target: ResolvedModelTarget, spec: ModelSpec?, conversationID: UUID, messageID: UUID,
             kind: RequestKind, operationID: UUID = UUID(), attempt: Int = 1, now: Date = Date()) {
            id = UUID()
            self.operationID = operationID
            self.attempt = attempt
            self.conversationID = conversationID
            self.messageID = messageID
            providerID = target.providerID
            providerName = target.providerName
            modelID = target.modelID
            modelDisplayName = target.modelDisplayName
            protocolRaw = target.protocolType.rawValue
            kindRaw = kind.rawValue
            statusRaw = RequestStatus.running.rawValue
            startedAt = now
            outputChunkCount = 0
            isStreamed = true
            inputPricePerMillion = spec?.inputPricePerMillion
            outputPricePerMillion = spec?.outputPricePerMillion
            currency = spec?.priceCurrency
        }
    }

    @Model
    final class PersonalMemory {
        @Attribute(.unique) var id: UUID
        var content: String
        var isEnabled: Bool
        var createdAt: Date

        init(id: UUID = UUID(), content: String, isEnabled: Bool = true, createdAt: Date = Date()) {
            self.id = id
            self.content = content
            self.isEnabled = isEnabled
            self.createdAt = createdAt
        }
    }
}
