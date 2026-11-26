import Foundation
import SwiftData

// MARK: - Schema history
//
// Rules for future model changes:
// 1. Never edit a frozen `SchemaVn` snapshot.
// 2. Copy the current stored properties into a new frozen `SchemaVn` enum before changing
//    the live models, add a `SchemaVn+1` that lists the live models, and append a
//    `MigrationStage` to `IOSBoxMigrationPlan`.
// 3. Add a migration test (see `SchemaMigrationTests`).

/// V1: the schema shipped before versioning was introduced. Frozen snapshot — stored
/// properties only, matching the original on-disk entities exactly.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ProviderConfig.self, AssistantPreset.self, Conversation.self, ChatMessage.self]
    }

    @Model
    final class ProviderConfig {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var protocolRaw: String = ""
        var baseURL: String = ""
        var iconSymbol: String = ""
        var accentHex: String = ""
        var isEnabled: Bool = true
        var sortOrder: Int = 0
        var modelsData: Data = Data()
        var headersData: Data = Data()
        var notes: String = ""
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        init() {}
    }

    @Model
    final class AssistantPreset {
        @Attribute(.unique) var id: UUID = UUID()
        var name: String = ""
        var iconEmoji: String = ""
        var subtitle: String = ""
        var systemPrompt: String = ""
        var temperature: Double = 0.7
        var useCustomTemperature: Bool = true
        var topP: Double = 1.0
        var maxOutputTokens: Int = 0
        var contextMessageLimit: Int = 20
        var enableThinking: Bool = true
        var thinkingBudgetTokens: Int = 4096
        var isBuiltIn: Bool = false
        var sortOrder: Int = 0
        var createdAt: Date = Date()

        init() {}
    }

    @Model
    final class Conversation {
        @Attribute(.unique) var id: UUID = UUID()
        var title: String = ""
        var isPinned: Bool = false
        var assistantID: UUID?
        var assistantEmoji: String = ""
        var systemPrompt: String = ""
        var temperature: Double = 0.7
        var useCustomTemperature: Bool = true
        var topP: Double = 1.0
        var maxOutputTokens: Int = 0
        var contextMessageLimit: Int = 20
        var enableThinking: Bool = true
        var thinkingBudgetTokens: Int = 4096
        var isArenaMode: Bool = false
        var primaryTargetData: Data = Data()
        var arenaTargetsData: Data = Data()
        var createdAt: Date = Date()
        var updatedAt: Date = Date()

        @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
        var messages: [ChatMessage] = []

        init() {}
    }

    @Model
    final class ChatMessage {
        @Attribute(.unique) var id: UUID = UUID()
        var roleRaw: String = ""
        var content: String = ""
        var reasoningContent: String = ""
        var attachmentsData: Data = Data()
        var providerID: UUID?
        var providerName: String = ""
        var modelID: String = ""
        var modelDisplayName: String = ""
        var accentHex: String = ""
        var comparisonGroupID: UUID?
        var isSelectedInGroup: Bool = true
        var isStreaming: Bool = false
        var errorMessage: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var latencyMs: Int?
        var thinkingDurationMs: Int?
        var sortIndex: Int = 0
        var createdAt: Date = Date()

        var conversation: Conversation?

        init() {}
    }
}

/// V7 moves large JSON metadata/settings columns to external storage and caches book byte size.
/// NOTE: Non-ProviderConfig models below currently share identical stored properties across V7, V8, and V9.
/// Before adding, removing, or changing ANY stored property on those live models in a future V10 schema,
/// snapshot their V7–V9 stored properties into frozen nested `@Model` classes (matching `SchemaV6`).
enum SchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            SchemaV6.ProviderConfig.self,
            AssistantPreset.self,
            Conversation.self,
            ChatMessage.self,
            RequestRecord.self,
            PersonalMemory.self,
            BookVolume.self
        ]
    }
}

/// V8 adds independent saved people and personal bookshelf positions. V7 entities are unchanged.
/// See V7 freeze note above before altering any shared live model in a future V10 schema.
enum SchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] { SchemaV7.models + [PersonaProfile.self, ShelfReadingState.self] }
}

/// V9 isolates the Keychain accounts of providers recreated from backups.
enum SchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ProviderConfig.self, AssistantPreset.self, Conversation.self, ChatMessage.self,
         RequestRecord.self, PersonalMemory.self, BookVolume.self, PersonaProfile.self, ShelfReadingState.self]
    }
}

typealias CurrentSchema = SchemaV9

enum IOSBoxMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self, SchemaV6.self, SchemaV7.self, SchemaV8.self, SchemaV9.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7, migrateV7toV8, migrateV8toV9]
    }

    /// Additive optional column + external-storage flag: no data transformation needed.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self
    )
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SchemaV3.self,
        toVersion: SchemaV4.self
    )
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: SchemaV4.self,
        toVersion: SchemaV5.self
    )
    static let migrateV5toV6 = MigrationStage.lightweight(fromVersion: SchemaV5.self, toVersion: SchemaV6.self)
    static let migrateV6toV7 = MigrationStage.lightweight(fromVersion: SchemaV6.self, toVersion: SchemaV7.self)
    static let migrateV7toV8 = MigrationStage.lightweight(fromVersion: SchemaV7.self, toVersion: SchemaV8.self)
    static let migrateV8toV9 = MigrationStage.lightweight(fromVersion: SchemaV8.self, toVersion: SchemaV9.self)
}
