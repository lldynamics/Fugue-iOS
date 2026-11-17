import Foundation
import SwiftData

// MARK: - Archive format

/// Full local backup. API keys are never included: they stay in the Keychain. On the same
/// device, restored providers keep their IDs and therefore find their keys again; on a new
/// device the keys (and secret header values) have to be entered once more.
struct BackupArchive: Codable {
    static let currentFormatVersion = 2

    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String
    var providers: [ProviderBackup]
    var presets: [PresetBackup]
    var conversations: [ConversationBackup]
}

struct ProviderBackup: Codable {
    var id: UUID
    var name: String
    var protocolRaw: String
    var baseURL: String
    var iconSymbol: String
    var accentHex: String
    var isEnabled: Bool
    var sortOrder: Int
    var models: [ModelSpec]
    /// Secret headers are exported with an empty value (the value lives in the Keychain).
    var customHeaders: [CustomHeader]
    var notes: String
}

struct PresetBackup: Codable {
    var id: UUID
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
}

struct ConversationBackup: Codable {
    var id: UUID
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
    var primaryTarget: ResolvedModelTarget?
    var arenaTargets: [ResolvedModelTarget]
    var createdAt: Date
    var updatedAt: Date
    var messages: [MessageBackup]
}

struct MessageBackup: Codable {
    var id: UUID
    var role: String
    var content: String
    var reasoningContent: String
    var attachments: [MessageAttachment]
    var providerID: UUID?
    var providerName: String
    var modelID: String
    var modelDisplayName: String
    var accentHex: String
    var comparisonGroupID: UUID?
    var isSelectedInGroup: Bool
    var errorMessage: String?
    var finishReason: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var latencyMs: Int?
    var thinkingDurationMs: Int?
    var sortIndex: Int
    var createdAt: Date
}

/// The text-only export written by earlier versions (a bare array of conversations).
struct LegacyExportConversation: Codable {
    struct Message: Codable {
        let role: String
        let model: String
        let provider: String
        let reasoning: String
        let content: String
        let createdAt: Date
    }

    let title: String
    let systemPrompt: String
    let updatedAt: Date
    let messages: [Message]
}

enum BackupError: LocalizedError {
    case conflictingIDs
    case unrecognizedFormat
    case newerFormat(Int)

    var errorDescription: String? {
        switch self {
        case .conflictingIDs:
            return String(localized: "备份包含冲突的标识，未导入任何数据。")
        case .unrecognizedFormat:
            return String(localized: "无法识别该文件，请选择由 iOSBox 导出的 JSON 备份。")
        case .newerFormat(let version):
            return String(localized: "该备份来自更新版本的 iOSBox（格式 v\(version)），请先升级 App 再导入。")
        }
    }
}

struct ImportSummary: Equatable {
    var providers = 0
    var presets = 0
    var conversations = 0
    var messages = 0
    /// Items already present (same ID) and therefore left untouched.
    var skipped = 0

    var description: String {
        var parts = [String(localized: "对话 \(conversations) 个（消息 \(messages) 条）"), String(localized: "服务商 \(providers) 个"), String(localized: "助手 \(presets) 个")]
        if skipped > 0 {
            parts.append(String(localized: "跳过已存在的 \(skipped) 项"))
        }
        let list = parts.joined(separator: String(localized: "，"))
        return String(localized: "已导入：\(list)。")
    }
}

// MARK: - Service

enum BackupService {
    enum DecodedBackup {
        case full(BackupArchive)
        case legacy([LegacyExportConversation])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Export

    /// Snapshots all models into plain values. Must run on the main actor (model access);
    /// the expensive JSON encoding can then happen off the main thread.
    @MainActor
    static func makeArchive(context: ModelContext) throws -> BackupArchive {
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        let presets = try context.fetch(FetchDescriptor<AssistantPreset>(sortBy: [SortDescriptor(\.sortOrder)]))
        let conversations = try context.fetch(
            FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )

        return BackupArchive(
            formatVersion: BackupArchive.currentFormatVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            providers: providers.map { p in
                ProviderBackup(
                    id: p.id, name: p.name, protocolRaw: p.protocolRaw, baseURL: p.baseURL,
                    iconSymbol: p.iconSymbol, accentHex: p.accentHex, isEnabled: p.isEnabled,
                    sortOrder: p.sortOrder, models: p.models,
                    customHeaders: p.customHeaders.map { header in
                        var copy = header
                        if copy.isSecret { copy.value = "" }
                        return copy
                    },
                    notes: p.notes
                )
            },
            presets: presets.map { p in
                PresetBackup(
                    id: p.id, name: p.name, iconEmoji: p.iconEmoji, subtitle: p.subtitle,
                    systemPrompt: p.systemPrompt, temperature: p.temperature,
                    useCustomTemperature: p.useCustomTemperature, topP: p.topP,
                    maxOutputTokens: p.maxOutputTokens, contextMessageLimit: p.contextMessageLimit,
                    enableThinking: p.enableThinking, thinkingBudgetTokens: p.thinkingBudgetTokens,
                    isBuiltIn: p.isBuiltIn, sortOrder: p.sortOrder
                )
            },
            conversations: conversations.map { c in
                ConversationBackup(
                    id: c.id, title: c.title, isPinned: c.isPinned, assistantID: c.assistantID,
                    assistantEmoji: c.assistantEmoji, systemPrompt: c.systemPrompt,
                    temperature: c.temperature, useCustomTemperature: c.useCustomTemperature,
                    topP: c.topP, maxOutputTokens: c.maxOutputTokens,
                    contextMessageLimit: c.contextMessageLimit, enableThinking: c.enableThinking,
                    thinkingBudgetTokens: c.thinkingBudgetTokens, isArenaMode: c.isArenaMode,
                    primaryTarget: c.primaryTarget, arenaTargets: c.arenaTargets,
                    createdAt: c.createdAt, updatedAt: c.updatedAt,
                    messages: c.sortedMessages.map { m in
                        MessageBackup(
                            id: m.id, role: m.roleRaw, content: m.content,
                            reasoningContent: m.reasoningContent, attachments: m.attachments,
                            providerID: m.providerID, providerName: m.providerName,
                            modelID: m.modelID, modelDisplayName: m.modelDisplayName,
                            accentHex: m.accentHex, comparisonGroupID: m.comparisonGroupID,
                            isSelectedInGroup: m.isSelectedInGroup, errorMessage: m.errorMessage,
                            finishReason: m.finishReason, promptTokens: m.promptTokens,
                            completionTokens: m.completionTokens, latencyMs: m.latencyMs,
                            thinkingDurationMs: m.thinkingDurationMs, sortIndex: m.sortIndex,
                            createdAt: m.createdAt
                        )
                    }
                )
            }
        )
    }

    static func encode(_ archive: BackupArchive) throws -> Data {
        try makeEncoder().encode(archive)
    }

    /// Writes the archive to a temporary file suitable for `ShareLink`.
    static func writeToTemporaryFile(_ data: Data, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSBox_Backup_\(formatter.string(from: now)).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: Import

    /// Pure decoding; safe to run off the main thread.
    static func decode(_ data: Data) throws -> DecodedBackup {
        let decoder = makeDecoder()
        if let archive = try? decoder.decode(BackupArchive.self, from: data) {
            guard archive.formatVersion <= BackupArchive.currentFormatVersion else {
                throw BackupError.newerFormat(archive.formatVersion)
            }
            return .full(archive)
        }
        if let legacy = try? decoder.decode([LegacyExportConversation].self, from: data) {
            return .legacy(legacy)
        }
        // A newer archive may fail full decoding; report the version if we can read it.
        if let header = try? decoder.decode(FormatProbe.self, from: data),
           header.formatVersion > BackupArchive.currentFormatVersion {
            throw BackupError.newerFormat(header.formatVersion)
        }
        throw BackupError.unrecognizedFormat
    }

    private struct FormatProbe: Decodable {
        let formatVersion: Int
    }

    /// Merges a decoded backup into the store. Items whose ID already exists are skipped,
    /// so importing the same backup twice doesn't create duplicates.
    @MainActor
    @discardableResult
    static func apply(_ backup: DecodedBackup, to context: ModelContext) throws -> ImportSummary {
        // Save pending user edits first; the import owns an isolated transaction context.
        try context.save()
        let context = ModelContext(context.container)
        context.autosaveEnabled = false
        defer { context.rollback() }
        var summary = ImportSummary()

        switch backup {
        case .full(let archive):
            let existingProviders = Set(try context.fetch(FetchDescriptor<ProviderConfig>()).map(\.id))
            let existingPresets = Set(try context.fetch(FetchDescriptor<AssistantPreset>()).map(\.id))
            let existingConversations = Set(try context.fetch(FetchDescriptor<Conversation>()).map(\.id))

            func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }
            let incomingMessages = archive.conversations.flatMap(\.messages)
            guard unique(archive.providers.map(\.id)), unique(archive.presets.map(\.id)),
                  unique(archive.conversations.map(\.id)), unique(incomingMessages.map(\.id)) else {
                throw BackupError.conflictingIDs
            }
            let existingMessages = Set(try context.fetch(FetchDescriptor<ChatMessage>()).map(\.id))
            for conversation in archive.conversations where !existingConversations.contains(conversation.id) {
                guard conversation.messages.allSatisfy({ !existingMessages.contains($0.id) }) else {
                    throw BackupError.conflictingIDs
                }
            }

            for p in archive.providers {
                guard !existingProviders.contains(p.id) else { summary.skipped += 1; continue }
                let provider = ProviderConfig(
                    id: p.id, name: p.name,
                    protocolType: APIProtocolType(rawValue: p.protocolRaw) ?? .openAICompatible,
                    baseURL: p.baseURL, iconSymbol: p.iconSymbol, accentHex: p.accentHex,
                    isEnabled: p.isEnabled, sortOrder: p.sortOrder, models: p.models,
                    customHeaders: p.customHeaders, notes: p.notes
                )
                context.insert(provider)
                summary.providers += 1
            }

            for p in archive.presets {
                guard !existingPresets.contains(p.id) else { summary.skipped += 1; continue }
                context.insert(AssistantPreset(
                    id: p.id, name: p.name, iconEmoji: p.iconEmoji, subtitle: p.subtitle,
                    systemPrompt: p.systemPrompt, temperature: p.temperature,
                    useCustomTemperature: p.useCustomTemperature, topP: p.topP,
                    maxOutputTokens: p.maxOutputTokens, contextMessageLimit: p.contextMessageLimit,
                    enableThinking: p.enableThinking, thinkingBudgetTokens: p.thinkingBudgetTokens,
                    isBuiltIn: p.isBuiltIn, sortOrder: p.sortOrder
                ))
                summary.presets += 1
            }

            for c in archive.conversations {
                guard !existingConversations.contains(c.id) else { summary.skipped += 1; continue }
                let conversation = Conversation(
                    id: c.id, title: c.title, isPinned: c.isPinned, assistantID: c.assistantID,
                    assistantEmoji: c.assistantEmoji, systemPrompt: c.systemPrompt,
                    temperature: c.temperature, useCustomTemperature: c.useCustomTemperature,
                    topP: c.topP, maxOutputTokens: c.maxOutputTokens,
                    contextMessageLimit: c.contextMessageLimit, enableThinking: c.enableThinking,
                    thinkingBudgetTokens: c.thinkingBudgetTokens, isArenaMode: c.isArenaMode,
                    primaryTarget: c.primaryTarget, arenaTargets: c.arenaTargets
                )
                conversation.createdAt = c.createdAt
                conversation.updatedAt = c.updatedAt
                context.insert(conversation)

                for m in c.messages {
                    let message = ChatMessage(
                        id: m.id,
                        role: MessageRole(rawValue: m.role) ?? .user,
                        content: m.content,
                        reasoningContent: m.reasoningContent,
                        attachments: m.attachments,
                        comparisonGroupID: m.comparisonGroupID,
                        isSelectedInGroup: m.isSelectedInGroup,
                        isStreaming: false,
                        sortIndex: m.sortIndex,
                        createdAt: m.createdAt
                    )
                    message.providerID = m.providerID
                    message.providerName = m.providerName
                    message.modelID = m.modelID
                    message.modelDisplayName = m.modelDisplayName
                    message.accentHex = m.accentHex
                    message.errorMessage = m.errorMessage
                    message.finishReason = m.finishReason
                    message.promptTokens = m.promptTokens
                    message.completionTokens = m.completionTokens
                    message.latencyMs = m.latencyMs
                    message.thinkingDurationMs = m.thinkingDurationMs
                    message.conversation = conversation
                    context.insert(message)
                    summary.messages += 1
                }
                summary.conversations += 1
            }

        case .legacy(let conversations):
            // Old exports carry no IDs, so each import creates new conversations.
            for legacy in conversations {
                let conversation = Conversation(title: legacy.title, systemPrompt: legacy.systemPrompt)
                conversation.updatedAt = legacy.updatedAt
                conversation.createdAt = legacy.messages.first?.createdAt ?? legacy.updatedAt
                context.insert(conversation)
                for (index, m) in legacy.messages.enumerated() {
                    let message = ChatMessage(
                        role: MessageRole(rawValue: m.role) ?? .user,
                        content: m.content,
                        reasoningContent: m.reasoning,
                        sortIndex: index,
                        createdAt: m.createdAt
                    )
                    message.modelID = m.model
                    message.modelDisplayName = m.model
                    message.providerName = m.provider
                    message.conversation = conversation
                    context.insert(message)
                    summary.messages += 1
                }
                summary.conversations += 1
            }
        }

        try context.save()
        return summary
    }
}
