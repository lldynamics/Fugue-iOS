import Foundation
import SwiftData

// MARK: - Archive format

/// Full local backup. API keys are never included: they stay in the Keychain. On the same
/// device, restored providers keep their IDs and therefore find their keys again; on a new
/// device the keys (and secret header values) have to be entered once more.
struct BackupArchive: Codable {
    static let currentFormatVersion = 6

    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String
    var providers: [ProviderBackup]
    var presets: [PresetBackup]
    var conversations: [ConversationBackup]
    var requests: [RequestRecord.Snapshot]?
    var memories: [PersonalMemory.Snapshot]?
    var books: [BookVolume.Snapshot]? = nil
    var flashcards: [StudyFlashcard]? = nil
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
    var knowledgeVolumeIDs: [UUID]? = nil
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
    var assistanceSettings: AssistanceSettings?
    var activeLeafMessageID: UUID?
    var folderTag: String?
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
    var cachedTokens: Int?
    var latencyMs: Int?
    var thinkingDurationMs: Int?
    var synthesisSourceDigest: String?
    var latestRequestID: UUID?
    var assistanceMetadata: AssistanceMetadata?
    var parentMessageID: UUID?
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
    case storageUnavailable
    case conflictingIDs
    case unrecognizedFormat
    case newerFormat(Int)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return String(localized: "当前数据库无法持久保存。请检查设备存储空间，重启后再导入备份。")
        case .conflictingIDs:
            return String(localized: "备份包含冲突的标识，未导入任何数据。")
        case .unrecognizedFormat:
            return String(localized: "无法识别该文件，请选择由「夜奔」导出的 JSON 备份。")
        case .newerFormat(let version):
            return String(localized: "该备份来自更新版本的「夜奔」（格式 v\(version)），请先升级 App 再导入。")
        case .fileTooLarge:
            return String(localized: "备份文件超过 256 MB 安全上限，无法导入。")
        }
    }
}

struct ImportSummary: Equatable {
    var providers = 0
    var presets = 0
    var conversations = 0
    var messages = 0
    var restoredConversations = 0
    var requests = 0
    var memories = 0
    var books = 0
    var flashcards = 0
    /// Items already present (same ID) and therefore left untouched.
    var skipped = 0
    var credentialConflicts: [String] = []
    var confirmedCredentials = 0
    var failedCredentialWrites = 0
    var flashcardRestoreFailed = false

    var hasWarnings: Bool { !credentialConflicts.isEmpty || failedCredentialWrites > 0 || flashcardRestoreFailed }
    var title: String { hasWarnings ? String(localized: "备份需继续处理") : String(localized: "导入完成") }

    var description: String {
        var parts: [String] = []
        if restoredConversations > 0 {
            parts.append(String(localized: "已恢复 \(restoredConversations) 个原对话"))
        }
        if conversations > 0 { parts.append(String(localized: "新建对话 \(conversations) 个")) }
        if messages > 0 { parts.append(String(localized: "消息 \(messages) 条")) }
        if providers > 0 { parts.append(String(localized: "服务商 \(providers) 个")) }
        if presets > 0 { parts.append(String(localized: "助手 \(presets) 个")) }
        if requests > 0 { parts.append(String(localized: "请求记录 \(requests) 条")) }
        if books > 0 { parts.append(String(localized: "书籍 \(books) 本")) }
        if flashcards > 0 { parts.append(String(localized: "闪卡 \(flashcards) 张")) }
        if memories > 0 {
            parts.append(String(localized: "记忆 \(memories) 条"))
        }
        if skipped > 0 {
            parts.append(String(localized: "跳过已存在的 \(skipped) 项"))
        }
        var lines: [String] = []
        if !parts.isEmpty {
            let list = parts.joined(separator: String(localized: "，"))
            lines.append(String(localized: "已导入：\(list)。"))
        }
        if confirmedCredentials > 0 {
            lines.append(String(localized: "已确认 \(confirmedCredentials) 项凭据保存在钥匙串中。"))
        }
        if !credentialConflicts.isEmpty {
            let names = credentialConflicts.joined(separator: String(localized: "，"))
            lines.append(String(localized: "以下服务商的连接或请求头与备份不一致，请在服务商设置中核对并重新填写凭据：\(names)。"))
        }
        if failedCredentialWrites > 0 {
            lines.append(String(localized: "有 \(failedCredentialWrites) 项凭据未能存入钥匙串。请解锁设备后重新导入此备份。"))
        }
        if flashcardRestoreFailed {
            lines.append(String(localized: "闪卡未能保存。请检查闪卡库和设备存储，再重新导入此备份。"))
        }
        return lines.isEmpty ? String(localized: "备份中没有需要导入的内容。") : lines.joined(separator: "\n")
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

    /// Only conventional API paths can be carried verbatim. A custom relay can put a
    /// credential anywhere in its path, even without a recognizable key prefix.
    private static func portableBaseURL(_ raw: String) -> String {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: address),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil || url.fragment == "" else { return "" }
        let paths: Set<String> = ["", "v1", "v2", "v3", "v4", "v1beta", "api/v1",
                                  "openai/v1", "anthropic/v1", "chat/completions", "v1/chat/completions",
                                  "messages", "v1/messages"]
        let path = url.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return paths.contains(path) ? address : ""
    }

    @MainActor
    static func makeArchive(
        context: ModelContext,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) throws -> BackupArchive {
        let resolvedFlashcards = flashcardStore ?? .shared
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        let presets = try context.fetch(FetchDescriptor<AssistantPreset>(sortBy: [SortDescriptor(\.sortOrder)]))
        let conversations = try context.fetch(
            FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        let requests = try context.fetch(FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.startedAt)]))
        let memories = try context.fetch(FetchDescriptor<PersonalMemory>(sortBy: [SortDescriptor(\.createdAt)]))
        let cards = try resolvedFlashcards.readableCards()

        return BackupArchive(
            formatVersion: BackupArchive.currentFormatVersion,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            providers: providers.map { p in
                ProviderBackup(
                    id: p.id, name: p.name, protocolRaw: p.protocolRaw, baseURL: portableBaseURL(p.baseURL),
                    iconSymbol: p.iconSymbol, accentHex: p.accentHex, isEnabled: p.isEnabled,
                    sortOrder: p.sortOrder, models: p.models,
                    customHeaders: p.customHeaders.map { header in
                        var copy = header
                        if copy.isSecret || CustomHeader.looksSensitive(copy.key) {
                            copy.isSecret = true
                            copy.value = ""
                        }
                        return copy
                    },
                    notes: p.notes
                )
            },
            presets: presets.map { p in
                let volumeIDs = knowledgeStore.volumeIDs(for: p.id)
                return PresetBackup(
                    id: p.id, name: p.name, iconEmoji: p.iconEmoji, subtitle: p.subtitle,
                    systemPrompt: p.systemPrompt, temperature: p.temperature,
                    useCustomTemperature: p.useCustomTemperature, topP: p.topP,
                    maxOutputTokens: p.maxOutputTokens, contextMessageLimit: p.contextMessageLimit,
                    enableThinking: p.enableThinking, thinkingBudgetTokens: p.thinkingBudgetTokens,
                    isBuiltIn: p.isBuiltIn, sortOrder: p.sortOrder,
                    knowledgeVolumeIDs: volumeIDs.isEmpty ? nil : volumeIDs
                )
            },
            conversations: conversations.map { snapshot($0, forExport: true) },
            requests: requests.map(\.snapshot),
            memories: memories.map(\.snapshot),
            books: try context.fetch(FetchDescriptor<BookVolume>()).map { try $0.snapshot() },
            flashcards: cards.isEmpty ? nil : cards
        )
    }

    @MainActor
    private static func snapshot(_ c: Conversation, forExport: Bool = false) -> ConversationBackup {
        let messages = c.sortedMessages
        let exportedError = String(localized: "请求失败，详细错误仅保留在原设备。")
        func diagnostic(_ message: ChatMessage) -> String? {
            forExport ? message.errorMessage.map { _ in exportedError } : message.errorMessage
        }
        return ConversationBackup(
            id: c.id, title: c.title, isPinned: c.isPinned, assistantID: c.assistantID,
            assistantEmoji: c.assistantEmoji, systemPrompt: c.systemPrompt,
            temperature: c.temperature, useCustomTemperature: c.useCustomTemperature,
            topP: c.topP, maxOutputTokens: c.maxOutputTokens,
            contextMessageLimit: c.contextMessageLimit, enableThinking: c.enableThinking,
            thinkingBudgetTokens: c.thinkingBudgetTokens, isArenaMode: c.isArenaMode,
            primaryTarget: c.primaryTarget, arenaTargets: c.arenaTargets,
            assistanceSettings: forExport ? c.assistanceSettings.forPersonaBackup : c.assistanceSettings,
            activeLeafMessageID: c.activeLeafMessageID,
            folderTag: c.folderTag,
            createdAt: c.createdAt, updatedAt: c.updatedAt,
            messages: messages.map { m in
                var metadata = m.assistanceMetadataData != nil ? m.assistanceMetadata : nil
                if forExport, var value = metadata {
                    for index in value.toolCalls.indices where !value.toolCalls[index].succeeded {
                        value.toolCalls[index].resultSummary = exportedError
                    }
                    metadata = value
                }
                var digest = m.synthesisSourceDigest
                if forExport, let groupID = m.comparisonGroupID, digest != nil, ArenaSynthesis.isCurrent(m, in: messages) {
                    digest = ArenaSynthesis.digest(of: ArenaSynthesis.sources(in: messages, groupID: groupID), errorDescription: diagnostic)
                }
                return MessageBackup(
                    id: m.id, role: m.roleRaw, content: m.content,
                    reasoningContent: m.reasoningContent, attachments: m.attachments,
                    providerID: m.providerID, providerName: m.providerName,
                    modelID: m.modelID, modelDisplayName: m.modelDisplayName,
                    accentHex: m.accentHex, comparisonGroupID: m.comparisonGroupID,
                    isSelectedInGroup: m.isSelectedInGroup, errorMessage: diagnostic(m),
                    finishReason: m.finishReason, promptTokens: m.promptTokens,
                    completionTokens: m.completionTokens, cachedTokens: m.cachedTokens,
                    latencyMs: m.latencyMs,
                    thinkingDurationMs: m.thinkingDurationMs,
                    synthesisSourceDigest: digest,
                    latestRequestID: m.latestRequest?.id,
                    assistanceMetadata: metadata,
                    parentMessageID: m.parentMessageID,
                    sortIndex: m.sortIndex,
                    createdAt: m.createdAt
                )
            }
        )
    }

    /// The caller waits for streaming to stop before taking this one-conversation undo snapshot.
    @MainActor
    static func clearMessages(in conversation: Conversation, context: ModelContext) throws -> ConversationBackup {
        try context.save()
        let saved = snapshot(conversation)
        do {
            for message in conversation.messages { context.delete(message) }
            conversation.messages.removeAll()
            conversation.activeLeafMessageID = nil
            try context.save()
            return saved
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor
    static func undoClear(_ saved: ConversationBackup, in context: ModelContext) throws {
        let archive = BackupArchive(formatVersion: BackupArchive.currentFormatVersion, exportedAt: Date(),
                                    appVersion: "", providers: [], presets: [], conversations: [saved])
        try apply(.full(archive), to: context)
    }

    static func encode(_ archive: BackupArchive) throws -> Data {
        try makeEncoder().encode(archive)
    }

    static func writeToTemporaryFile(_ data: Data, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fugue_Backup_\(formatter.string(from: now)).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: Import

    static func decode(_ data: Data) throws -> DecodedBackup {
        let decoder = makeDecoder()
        if var archive = try? decoder.decode(BackupArchive.self, from: data) {
            guard archive.formatVersion <= BackupArchive.currentFormatVersion else {
                throw BackupError.newerFormat(archive.formatVersion)
            }
            for index in archive.conversations.indices {
                archive.conversations[index].assistanceSettings = archive.conversations[index].assistanceSettings?.forPersonaBackup
            }
            return .full(archive)
        }
        if let legacy = try? decoder.decode([LegacyExportConversation].self, from: data) {
            return .legacy(legacy)
        }
        if let header = try? decoder.decode(FormatProbe.self, from: data),
           header.formatVersion > BackupArchive.currentFormatVersion {
            throw BackupError.newerFormat(header.formatVersion)
        }
        throw BackupError.unrecognizedFormat
    }

    private struct FormatProbe: Decodable {
        let formatVersion: Int
    }

    private struct PostCommitSidecarUpdates {
        var cachePrices: [UUID: CachePriceSnapshotStore.Pair] = [:]
        var presetKnowledgeBindings: [UUID: [UUID]] = [:]
        var flashcards: [StudyFlashcard] = []
    }

    @MainActor
    @discardableResult
    static func apply(
        _ backup: DecodedBackup,
        to context: ModelContext,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) throws -> ImportSummary {
        guard PersistenceController.canCommitUserData(in: context) else { throw BackupError.storageUnavailable }
        let resolvedFlashcards = flashcardStore ?? .shared
        try context.save()
        // All import work is synchronous on the main actor. Preserve earlier edits before
        // the transaction so a rollback affects only the incoming backup.
        var summary = ImportSummary()
        var sidecars = PostCommitSidecarUpdates()
        do {
            try context.transaction {
                summary = try importData(backup, in: context, sidecars: &sidecars)
            }
        } catch {
            context.rollback()
            throw error
        }

        // Only mutate sidecar stores after the SwiftData transaction has committed cleanly.
        if !sidecars.cachePrices.isEmpty {
            CachePriceSnapshotStore.shared.setBatch(sidecars.cachePrices)
        }
        for (presetID, volumeIDs) in sidecars.presetKnowledgeBindings {
            if knowledgeStore.volumeIDs(for: presetID).isEmpty {
                knowledgeStore.setVolumeIDs(volumeIDs, for: presetID)
            }
        }
        if !sidecars.flashcards.isEmpty {
            do { summary.flashcards = try resolvedFlashcards.mergeImported(sidecars.flashcards) }
            catch { summary.flashcardRestoreFailed = true }
        }
        return summary
    }

    @MainActor
    private static func importData(
        _ backup: DecodedBackup,
        in txContext: ModelContext,
        sidecars: inout PostCommitSidecarUpdates
    ) throws -> ImportSummary {
        var summary = ImportSummary()

        switch backup {
        case .full(let archive):
            let existingProviders = Set(try txContext.fetch(FetchDescriptor<ProviderConfig>()).map(\.id))
            let existingPresets = Set(try txContext.fetch(FetchDescriptor<AssistantPreset>()).map(\.id))
            let existingConversations = Dictionary(uniqueKeysWithValues:
                try txContext.fetch(FetchDescriptor<Conversation>()).map { ($0.id, $0) })
            let existingRequestList = try txContext.fetch(FetchDescriptor<RequestRecord>())
            var recordsByID = Dictionary(uniqueKeysWithValues: existingRequestList.map { ($0.id, $0) })
            let existingMemories = Set(try txContext.fetch(FetchDescriptor<PersonalMemory>()).map(\.id))

            func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }
            let incomingMessages = archive.conversations.flatMap(\.messages)
            let incomingRequests = archive.requests ?? []
            let latestByMessage = Dictionary(grouping: incomingRequests, by: \.messageID)
                .compactMapValues { $0.max(by: { $0.attempt < $1.attempt })?.id }
            let incomingMemories = archive.memories ?? []
            let incomingBooks = archive.books ?? []
            let incomingFlashcards = archive.flashcards ?? []

            guard unique(archive.providers.map(\.id)),
                  unique(archive.presets.map(\.id)),
                  unique(archive.conversations.map(\.id)),
                  unique(incomingMessages.map(\.id)),
                  unique(incomingRequests.map(\.id)),
                  unique(incomingMemories.map(\.id)),
                  unique(incomingBooks.map(\.id)),
                  unique(incomingFlashcards.map(\.id)) else {
                throw BackupError.conflictingIDs
            }

            // Validate personal memory bounds atomically before mutating anything.
            for mem in incomingMemories {
                let trimmed = mem.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, mem.content.count <= PersonalMemory.maximumCharacters else {
                    throw BackupError.unrecognizedFormat
                }
            }

            let existingMessages = Dictionary(uniqueKeysWithValues:
                try txContext.fetch(FetchDescriptor<ChatMessage>()).map { ($0.id, $0) })
            for conversation in archive.conversations {
                for incoming in conversation.messages {
                    if let local = existingMessages[incoming.id], local.conversation?.id != conversation.id {
                        throw BackupError.conflictingIDs
                    }
                }
            }

            for book in incomingBooks {
                let prepared = try PreparedBook(BookManuscript(title: book.title, chapters: book.chapters))
                guard prepared.id == book.id else { throw BackupError.conflictingIDs }
                if try BookLibrary.find(book.id, in: txContext) == nil {
                    txContext.insert(BookVolume(id: book.id, title: book.title, chapterTitles: prepared.chapterTitles,
                                                manuscript: prepared.data, importedAt: book.importedAt))
                    summary.books += 1
                }
            }

            for snapshot in incomingRequests where recordsByID[snapshot.id] == nil {
                let record = RequestRecord(snapshot: snapshot, persistCachePrices: false)
                txContext.insert(record)
                recordsByID[record.id] = record
                let validRead = RequestRecord.validPrice(snapshot.cacheReadPricePerMillion)
                let validWrite = RequestRecord.validPrice(snapshot.cacheWritePricePerMillion)
                if validRead != nil || validWrite != nil {
                    sidecars.cachePrices[snapshot.id] = .init(read: validRead, write: validWrite)
                }
                summary.requests += 1
            }

            for mem in incomingMemories where !existingMemories.contains(mem.id) {
                txContext.insert(PersonalMemory(
                    id: mem.id,
                    content: mem.content,
                    isEnabled: mem.isEnabled,
                    createdAt: mem.createdAt
                ))
                summary.memories += 1
            }

            for p in archive.providers {
                guard !existingProviders.contains(p.id) else { summary.skipped += 1; continue }
                let provider = ProviderConfig(
                    id: p.id, name: p.name,
                    protocolType: APIProtocolType(rawValue: p.protocolRaw) ?? .openAICompatible,
                    baseURL: p.baseURL, iconSymbol: p.iconSymbol, accentHex: p.accentHex,
                    isEnabled: p.isEnabled && !p.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    sortOrder: p.sortOrder, models: p.models,
                    customHeaders: p.customHeaders, notes: p.notes
                )
                txContext.insert(provider)
                summary.providers += 1
            }

            for p in archive.presets {
                if let volumeIDs = p.knowledgeVolumeIDs, !volumeIDs.isEmpty {
                    sidecars.presetKnowledgeBindings[p.id] = volumeIDs
                }
                guard !existingPresets.contains(p.id) else { summary.skipped += 1; continue }
                txContext.insert(AssistantPreset(
                    id: p.id, name: p.name, iconEmoji: p.iconEmoji, subtitle: p.subtitle,
                    systemPrompt: p.systemPrompt, temperature: p.temperature,
                    useCustomTemperature: p.useCustomTemperature, topP: p.topP,
                    maxOutputTokens: p.maxOutputTokens, contextMessageLimit: p.contextMessageLimit,
                    enableThinking: p.enableThinking, thinkingBudgetTokens: p.thinkingBudgetTokens,
                    isBuiltIn: p.isBuiltIn, sortOrder: p.sortOrder
                ))
                summary.presets += 1
            }

            sidecars.flashcards = incomingFlashcards

            for c in archive.conversations {
                let missing = c.messages.filter { existingMessages[$0.id] == nil }
                var votedGroups = Set((existingConversations[c.id]?.messages ?? []).compactMap { message in
                    message.assistanceMetadata.blindArenaBallot == nil ? nil : message.comparisonGroupID
                })
                let conversation: Conversation
                let localIDs: Set<UUID>
                if let local = existingConversations[c.id] {
                    var updatedExisting = false
                    if c.updatedAt > local.updatedAt {
                        local.title = c.title
                        local.isPinned = c.isPinned
                        local.folderTag = c.folderTag
                        local.assistantID = c.assistantID
                        local.assistantEmoji = c.assistantEmoji
                        local.systemPrompt = c.systemPrompt
                        local.temperature = c.temperature
                        local.useCustomTemperature = c.useCustomTemperature
                        local.topP = c.topP
                        local.maxOutputTokens = c.maxOutputTokens
                        local.contextMessageLimit = c.contextMessageLimit
                        local.enableThinking = c.enableThinking
                        local.thinkingBudgetTokens = c.thinkingBudgetTokens
                        local.isArenaMode = c.isArenaMode
                        local.primaryTarget = c.primaryTarget
                        local.arenaTargets = c.arenaTargets
                        if var incomingSettings = c.assistanceSettings {
                            let current = local.groupMembers
                            incomingSettings.groupMembers = incomingSettings.groupMembers.map { member in
                                member.preservingFeedProgress(from: current.first { $0.id == member.id }, keepEnabled: true)
                            }
                            local.assistanceSettings = incomingSettings
                        }
                        local.updatedAt = c.updatedAt
                        updatedExisting = true
                    }
                    for incomingMsg in c.messages {
                        guard let localMsg = existingMessages[incomingMsg.id],
                              let incomingMeta = incomingMsg.assistanceMetadata else { continue }
                        var localMeta = localMsg.assistanceMetadata
                        var metaMutated = false
                        if let group = localMsg.comparisonGroupID, incomingMsg.comparisonGroupID == group {
                            if incomingMeta.blindArenaRevealed && !localMeta.blindArenaRevealed {
                                localMeta.blindArenaRevealed = true
                                metaMutated = true
                            }
                            if let ballot = incomingMeta.blindArenaBallot, ballot.winnerID == localMsg.id,
                               votedGroups.insert(group).inserted {
                                localMeta.blindArenaBallot = ballot
                                localMeta.blindArenaRevealed = true
                                metaMutated = true
                            }
                        }
                        if incomingMeta.isBookmarked && !localMeta.isBookmarked {
                            localMeta.isBookmarked = true
                            metaMutated = true
                        }
                        for reaction in incomingMeta.groupReactions where !localMeta.groupReactions.contains(where: { $0.id == reaction.id }) {
                            localMeta.groupReactions.append(reaction)
                            metaMutated = true
                        }
                        if metaMutated {
                            localMsg.assistanceMetadata = localMeta
                            updatedExisting = true
                        }
                    }

                    if missing.isEmpty {
                        if updatedExisting {
                            summary.restoredConversations += 1
                        } else {
                            summary.skipped += 1
                        }
                        continue
                    }
                    conversation = local
                    localIDs = Set(local.messages.map(\.id))
                    summary.restoredConversations += 1
                } else {
                    conversation = restoredConversation(c)
                    txContext.insert(conversation)
                    localIDs = []
                    summary.conversations += 1
                }

                // Local and archived turns may diverge after a shared prefix, or after a clear.
                // Keep the locally continued branch active when both sides have unique turns.
                let archiveIDs = Set(c.messages.map(\.id))
                let divergentTails = c.messages.last.map { !localIDs.contains($0.id) } == true
                    && conversation.sortedMessages.last.map { !archiveIDs.contains($0.id) } == true
                let needsTree = !localIDs.isEmpty && (ConversationTree.usesTree(conversation)
                    || c.messages.contains { $0.parentMessageID != nil }
                    || divergentTails)
                if needsTree { ConversationTree.ensureExplicitParentLinks(in: conversation) }
                if localIDs.isEmpty { conversation.activeLeafMessageID = c.activeLeafMessageID }
                let groupsWithLocalSelection = Set(conversation.messages.filter(\.isSelectedInGroup).compactMap(\.comparisonGroupID))
                var restoredByID: [UUID: ChatMessage] = [:]

                for m in missing {
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
                    message.cachedTokens = m.cachedTokens
                    message.latencyMs = m.latencyMs
                    message.thinkingDurationMs = m.thinkingDurationMs
                    message.synthesisSourceDigest = m.synthesisSourceDigest
                    message.parentMessageID = m.parentMessageID
                    if var meta = m.assistanceMetadata {
                        if let ballot = meta.blindArenaBallot {
                            if let group = m.comparisonGroupID, ballot.winnerID == m.id, votedGroups.insert(group).inserted {
                                meta.blindArenaRevealed = true
                            } else {
                                meta.blindArenaBallot = nil
                            }
                        }
                        message.assistanceMetadata = meta
                    }
                    if let reqID = m.latestRequestID, let linked = recordsByID[reqID] {
                        message.latestRequest = linked
                    } else if let latestID = latestByMessage[m.id], let fallbackLinked = recordsByID[latestID] {
                        message.latestRequest = fallbackLinked
                    }
                    if let group = m.comparisonGroupID, groupsWithLocalSelection.contains(group) {
                        message.isSelectedInGroup = false
                    }
                    message.conversation = conversation
                    txContext.insert(message)
                    restoredByID[m.id] = message
                    summary.messages += 1
                }
                if needsTree {
                    let archiveOrder = c.messages.compactMap { restoredByID[$0.id] ?? existingMessages[$0.id] }
                    _ = ConversationTree.linkHistory(archiveOrder, preserving: localIDs)
                }
            }

        case .legacy(let conversations):
            for legacy in conversations {
                let conversation = Conversation(title: legacy.title, systemPrompt: legacy.systemPrompt)
                conversation.updatedAt = legacy.updatedAt
                conversation.createdAt = legacy.messages.first?.createdAt ?? legacy.updatedAt
                txContext.insert(conversation)
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
                    txContext.insert(message)
                    summary.messages += 1
                }
                summary.conversations += 1
            }
        }

        return summary
    }

    private static func restoredConversation(_ c: ConversationBackup) -> Conversation {
        let conversation = Conversation(
            id: c.id, title: c.title, isPinned: c.isPinned, assistantID: c.assistantID,
            assistantEmoji: c.assistantEmoji, systemPrompt: c.systemPrompt,
            temperature: c.temperature, useCustomTemperature: c.useCustomTemperature,
            topP: c.topP, maxOutputTokens: c.maxOutputTokens,
            contextMessageLimit: c.contextMessageLimit, enableThinking: c.enableThinking,
            thinkingBudgetTokens: c.thinkingBudgetTokens, isArenaMode: c.isArenaMode,
            primaryTarget: c.primaryTarget, arenaTargets: c.arenaTargets
        )
        if let settings = c.assistanceSettings {
            conversation.assistanceSettings = settings
        }
        conversation.activeLeafMessageID = c.activeLeafMessageID
        conversation.folderTag = c.folderTag
        conversation.createdAt = c.createdAt
        conversation.updatedAt = c.updatedAt
        return conversation
    }
}
