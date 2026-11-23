import Foundation
import SwiftData

// MARK: - Archive format

/// Full local backup without account credentials. Recreated providers retain their IDs for
/// conversation references and start disabled with their own local Keychain accounts.
struct BackupArchive: Codable {
    static let currentFormatVersion = 7

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
    var personaProfiles: [GroupMember]? = nil
    var shelfPositions: [ShelfReadingState.Position]? = nil
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
    var organizationEdits: ConversationOrganizationEdits?
    var legacyImportID: UUID?

    mutating func resolveLinkedPersonas(_ profiles: [UUID: GroupMember]) {
        guard !profiles.isEmpty, var settings = assistanceSettings else { return }
        for i in settings.groupMembers.indices {
            let member = settings.groupMembers[i]
            if let id = member.profileID, let current = profiles[id] {
                settings.groupMembers[i] = current.inRoom(replacing: member)
            }
        }
        if let old = settings.privatePersona, let id = old.profileID, let current = profiles[id] {
            settings.privatePersona = current
            if primaryTarget?.id == old.target.id { primaryTarget = current.target }
            if title == old.name { title = current.name }
            assistantEmoji = current.avatarEmoji
        }
        assistanceSettings = settings
    }

    mutating func preserveLocalRecipients(from local: ConversationBackup) {
        isArenaMode = local.isArenaMode
        primaryTarget = local.primaryTarget
        arenaTargets = local.arenaTargets
        guard let localSettings = local.assistanceSettings, var settings = assistanceSettings else {
            assistanceSettings = local.assistanceSettings
            return
        }
        settings.usePersonalMemory = localSettings.usePersonalMemory
        settings.automaticRouting = localSettings.automaticRouting
        settings.imageTarget = localSettings.imageTarget
        settings.codeTarget = localSettings.codeTarget
        settings.fallbackEnabled = localSettings.fallbackEnabled
        settings.fallbackTargets = localSettings.fallbackTargets
        settings.autoGenerateTitle = localSettings.autoGenerateTitle
        settings.isGroupMode = localSettings.isGroupMode
        let importedMembers = settings.groupMembers
        let localMembers = localSettings.groupMembers
        settings.groupMembers = localMembers.map { member in
            guard var imported = importedMembers.first(where: {
                $0.id == member.id && $0.target.id == member.target.id && $0.isMuted == member.isMuted &&
                    $0.profileID == member.profileID
            }) else { return member }
            imported.target = member.target
            return imported.preservingFeedProgress(from: member, keepEnabled: true)
        }
        let approvedTargets = Dictionary(localMembers.filter { !$0.isMuted }.map { ($0.target.id, $0.target) },
                                         uniquingKeysWith: { first, _ in first })
        var memberIDs = Set(localMembers.map(\.id))
        for var member in importedMembers where memberIDs.insert(member.id).inserted {
            guard settings.groupMembers.count < 6 else { break }
            if let target = approvedTargets[member.target.id] {
                member.target = target
            } else {
                member.isMuted = true
            }
            let portableFeeds = member.portableProfile.persona?.feeds ?? []
            member.persona?.feeds = portableFeeds
            settings.groupMembers.append(member)
        }
        settings.privatePersona = localSettings.privatePersona
        assistanceSettings = settings
    }

    // Hash only portable configuration. Activity, organization, device cursors and history
    // have independent merge rules and must never make a settings edit appear newer.
    func configurationDigest() throws -> UUID {
        var config = self
        config.messages = []
        config.title = ""
        config.folderTag = nil
        config.isPinned = false
        config.activeLeafMessageID = nil
        config.createdAt = .distantPast
        config.updatedAt = .distantPast
        config.assistanceSettings = (assistanceSettings ?? AssistanceSettings()).forPersonaBackup
        config.legacyImportID = nil
        config.organizationEdits = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return UUID(contentOf: try encoder.encode(config))
    }

    var organization: ImportedOrganization {
        ImportedOrganization(title: title, isPinned: isPinned, folderTag: folderTag)
    }
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

    func matches(_ chat: Conversation) -> Bool {
        guard chat.title == title, chat.systemPrompt == systemPrompt, chat.messages.count == messages.count,
              chat.createdAt == (messages.first?.createdAt ?? updatedAt) else { return false }
        return zip(messages, chat.sortedMessages).allSatisfy { old, local in
            local.role == (MessageRole(rawValue: old.role) ?? .user) && local.content == old.content &&
            local.reasoningContent == old.reasoning && local.createdAt == old.createdAt &&
            local.modelID == old.model && local.providerName == old.provider
        }
    }

}

enum BackupError: LocalizedError {
    case storageUnavailable
    case conflictingIDs
    case unrecognizedFormat
    case newerFormat(Int)
    case fileTooLarge
    case conversationMessageLimit

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return String(localized: "请等本地数据库恢复后再备份或导入。")
        case .conflictingIDs:
            return String(localized: "备份包含冲突的标识，未导入任何数据。")
        case .unrecognizedFormat:
            return String(localized: "无法识别该文件，请选择由「夜奔」导出的 JSON 备份。")
        case .newerFormat(let version):
            return String(localized: "该备份来自更新版本的「夜奔」（格式 v\(version)），请先升级 App 再导入。")
        case .fileTooLarge:
            return String(localized: "备份文件超过 256 MiB 上限。")
        case .conversationMessageLimit:
            return String(localized: "单个对话超过 50,000 条消息的导入上限。")
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
    var restoredProfiles = 0
    var knowledgeRestoreFailed = false
    var flashcardRestoreFailed = false

    var hasWarnings: Bool { !credentialConflicts.isEmpty || failedCredentialWrites > 0 || flashcardRestoreFailed || knowledgeRestoreFailed }
    var title: String { hasWarnings ? String(localized: "备份需继续处理") : String(localized: "导入完成") }

    var description: String {
        var parts: [String] = []
        if restoredProfiles > 0 { parts.append(String(localized: "人物档案 \(restoredProfiles) 个")) }
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
        if providers > 0 {
            lines.append(String(localized: "请在服务商设置中核对导入的连接地址，再启用服务商。"))
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
        if knowledgeRestoreFailed {
            lines.append(String(localized: "助手知识库绑定未能保存。请在助手编辑页检查绑定文件和设备空间，然后重新导入此备份。"))
        }
        if flashcardRestoreFailed {
            lines.append(String(localized: "闪卡未能保存。请检查闪卡库和设备存储，再重新导入此备份。"))
        }
        return lines.isEmpty ? String(localized: "备份中没有需要导入的内容。") : lines.joined(separator: "\n")
    }
}

// MARK: - Service

enum BackupService {
    static let maximumFileBytes = 256 * 1024 * 1024
    private static let maximumImportedMessagesPerConversation = 50_000

    static func validateFileSize(_ bytes: Int) throws {
        guard bytes <= maximumFileBytes else { throw BackupError.fileTooLarge }
    }

    // These strings are present verbatim or escaped in JSON. Their UTF-8 lengths give a lower
    // bound before encoding the entire archive. The final size check includes all other fields.
    private struct ContentBudget {
        var remaining: Int

        mutating func count(_ value: String?) throws {
            let size = value?.utf8.count ?? 0
            guard size <= remaining else { throw BackupError.fileTooLarge }
            remaining -= size
        }

        mutating func count(_ chat: ConversationBackup) throws {
            for message in chat.messages {
                try count(message.content)
                try count(message.reasoningContent)
                for attachment in message.attachments {
                    try count(attachment.dataBase64)
                    try count(attachment.extractedText)
                }
            }
        }

        mutating func count(_ book: BookVolume.Snapshot) throws {
            for chapter in book.chapters { try count(chapter.text) }
        }
    }

    static func checkContentSize(_ archive: BackupArchive, limit: Int) throws {
        var budget = ContentBudget(remaining: limit)
        for chat in archive.conversations { try budget.count(chat) }
        for book in archive.books ?? [] { try budget.count(book) }
    }

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
        guard PersistenceController.canCommitUserData(in: context) else { throw BackupError.storageUnavailable }
        let resolvedFlashcards = flashcardStore ?? .shared
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        let presets = try context.fetch(FetchDescriptor<AssistantPreset>(sortBy: [SortDescriptor(\.sortOrder)]))
        let conversations = try context.fetch(
            FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        let requests = try context.fetch(FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.startedAt)]))
        let memories = try context.fetch(FetchDescriptor<PersonalMemory>(sortBy: [SortDescriptor(\.createdAt)]))
        let cards = try resolvedFlashcards.readableCards()
        let bindings = try knowledgeStore.readableBindings()
        var budget = ContentBudget(remaining: maximumFileBytes)

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
                let volumeIDs = bindings[p.id.uuidString] ?? []
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
            conversations: try conversations.map {
                let chat = snapshot($0, forExport: true)
                try budget.count(chat)
                return chat
            },
            requests: requests.map(\.snapshot),
            memories: memories.map(\.snapshot),
            books: try context.fetch(FetchDescriptor<BookVolume>()).map {
                let book = try $0.snapshot()
                try budget.count(book)
                return book
            },
            flashcards: cards.isEmpty ? nil : cards,
            personaProfiles: try context.fetch(FetchDescriptor<PersonaProfile>()).map { try $0.member().portableProfile },
            shelfPositions: try context.fetch(FetchDescriptor<ShelfReadingState>()).map(\.position)
        )
    }

    @MainActor
    private static func snapshot(_ c: Conversation, forExport: Bool = false, includeMessages: Bool = true) -> ConversationBackup {
        let messages = includeMessages ? c.sortedMessages : []
        let exportedError = String(localized: "请求失败，详细错误仅保留在原设备。")
        func diagnostic(_ message: ChatMessage) -> String? {
            forExport ? message.errorMessage.map { _ in exportedError } : message.errorMessage
        }
        var assistanceSettings = c.assistanceSettings
        if forExport {
            assistanceSettings.groupMembers = c.groupMembers
            assistanceSettings = assistanceSettings.forPersonaBackup
        }
        return ConversationBackup(
            id: c.id, title: c.title, isPinned: c.isPinned, assistantID: c.assistantID,
            assistantEmoji: c.assistantEmoji, systemPrompt: c.systemPrompt,
            temperature: c.temperature, useCustomTemperature: c.useCustomTemperature,
            topP: c.topP, maxOutputTokens: c.maxOutputTokens,
            contextMessageLimit: c.contextMessageLimit, enableThinking: c.enableThinking,
            thinkingBudgetTokens: c.thinkingBudgetTokens, isArenaMode: c.isArenaMode,
            primaryTarget: c.primaryTarget, arenaTargets: c.arenaTargets,
            assistanceSettings: assistanceSettings,
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
            },
            organizationEdits: c.backupState.organizationEdits, legacyImportID: c.backupState.legacyImportID
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
        try checkContentSize(archive, limit: maximumFileBytes)
        let data = try makeEncoder().encode(archive)
        try validateFileSize(data.count)
        return data
    }

    static func writeToTemporaryFile(_ data: Data, now: Date = Date()) throws -> URL {
        try validateFileSize(data.count)
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
        try validateFileSize(data.count)
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
        if case .full(let archive) = backup {
            do { try knowledgeStore.restoreNewBindings(sidecars.presetKnowledgeBindings, retrying: archive.presets.map(\.id)) }
            catch { summary.knowledgeRestoreFailed = true }
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
            guard archive.conversations.allSatisfy({ $0.messages.count <= maximumImportedMessagesPerConversation }) else {
                throw BackupError.conversationMessageLimit
            }
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
                  archive.conversations.allSatisfy({ unique($0.assistanceSettings?.groupMembers.map(\.id) ?? []) }),
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

            var chapterCounts = try Dictionary(uniqueKeysWithValues:
                txContext.fetch(FetchDescriptor<BookVolume>()).map { ($0.id, $0.chapterTitles.count) })
            func checkedProgress(_ friend: BookFriend?) -> BookFriend? {
                friend.map { $0.validatingRestoredProgress(chapterCount: chapterCounts[$0.bookID]) }
            }
            for book in incomingBooks {
                let prepared = try PreparedBook(BookManuscript(title: book.title, chapters: book.chapters))
                guard prepared.id == book.id else { throw BackupError.conflictingIDs }
                if try BookLibrary.find(book.id, in: txContext) == nil {
                    txContext.insert(BookVolume(id: book.id, title: book.title, chapterTitles: prepared.chapterTitles,
                                                manuscript: prepared.data, importedAt: book.importedAt))
                    chapterCounts[book.id] = prepared.chapterTitles.count
                    summary.books += 1
                }
            }

            let profiles = archive.personaProfiles ?? []
            let positions = archive.shelfPositions ?? []
            guard unique(profiles.map(\.id)), unique(positions.map(\.bookID)) else { throw BackupError.conflictingIDs }
            var linkedProfiles: [UUID: GroupMember] = [:]
            if !profiles.isEmpty || archive.conversations.contains(where: { chat in
                chat.assistanceSettings?.privatePersona?.profileID != nil ||
                    chat.assistanceSettings?.groupMembers.contains { $0.profileID != nil } == true
            }) {
                for saved in try txContext.fetch(FetchDescriptor<PersonaProfile>()) { linkedProfiles[saved.id] = try saved.member() }
                for var member in profiles where linkedProfiles[member.id] == nil {
                    guard member.profileID == member.id, !member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackupError.unrecognizedFormat }
                    member.bookFriend = checkedProgress(member.bookFriend)
                    let saved = try PersonaProfile(member)
                    txContext.insert(saved)
                    linkedProfiles[saved.id] = member.portableProfile
                    summary.restoredProfiles += 1
                }
            }
            for point in positions {
                guard let book = try BookLibrary.find(point.bookID, in: txContext),
                      book.chapterTitles.indices.contains(point.chapter), point.paragraph >= 0,
                      try ShelfReadingState.find(point.bookID, in: txContext) == nil else { continue }
                let state = ShelfReadingState(bookID: point.bookID)
                state.conversationID = point.conversationID
                state.chapter = point.chapter
                state.paragraph = point.paragraph
                txContext.insert(state)
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
                    isEnabled: false,
                    sortOrder: p.sortOrder, models: p.models,
                    customHeaders: p.customHeaders, notes: p.notes, isRestored: true
                )
                txContext.insert(provider)
                summary.providers += 1
            }

            for p in archive.presets {
                guard !existingPresets.contains(p.id) else { summary.skipped += 1; continue }
                sidecars.presetKnowledgeBindings[p.id] = p.knowledgeVolumeIDs ?? []
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

            for var c in archive.conversations {
                c.resolveLinkedPersonas(linkedProfiles)
                if var settings = c.assistanceSettings {
                    settings.bookFriend = checkedProgress(settings.bookFriend)
                    if var persona = settings.privatePersona {
                        persona.bookFriend = checkedProgress(persona.bookFriend)
                        settings.privatePersona = persona
                    }
                    for index in settings.groupMembers.indices {
                        settings.groupMembers[index].bookFriend = checkedProgress(settings.groupMembers[index].bookFriend)
                    }
                    c.assistanceSettings = settings
                }
                let missing = c.messages.filter { existingMessages[$0.id] == nil }
                var votedGroups = Set((existingConversations[c.id]?.messages ?? []).compactMap { message in
                    message.assistanceMetadata.blindArenaBallot == nil ? nil : message.comparisonGroupID
                })
                let conversation: Conversation
                let localIDs: Set<UUID>
                if let local = existingConversations[c.id] {
                    if !missing.isEmpty, missing.count > maximumImportedMessagesPerConversation - local.messages.count {
                        throw BackupError.conversationMessageLimit
                    }
                    var updatedExisting = mergeOrganization(c, into: local)
                    let version = local.backupState.lastImportedSettings
                    let localConfiguration = snapshot(local, includeMessages: false)
                    c.preserveLocalRecipients(from: localConfiguration)
                    let incomingDigest = try c.configurationDigest()
                    let currentDigest = try localConfiguration.configurationDigest()
                    let acceptConfiguration = version.map {
                        archive.exportedAt >= $0.exportedAt && currentDigest == $0.digest
                    } ?? (c.updatedAt > local.updatedAt)
                    if acceptConfiguration && incomingDigest != currentDigest {
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
                        if let incomingSettings = c.assistanceSettings {
                            local.assistanceSettings = incomingSettings
                        }
                        updatedExisting = true
                    }
                    if acceptConfiguration || currentDigest == incomingDigest,
                       archive.exportedAt >= (version?.exportedAt ?? .distantPast) {
                        local.backupState.lastImportedSettings = .init(digest: incomingDigest, exportedAt: archive.exportedAt)
                    }
                    if c.updatedAt > local.updatedAt { local.updatedAt = c.updatedAt; updatedExisting = true }
                    for incomingMsg in c.messages {
                        guard let localMsg = existingMessages[incomingMsg.id] else { continue }
                        let incomingMeta = incomingMsg.assistanceMetadata ?? AssistanceMetadata()
                        var localMeta = localMsg.assistanceMetadata
                        var metaMutated = mergeReplies(incomingMsg, into: localMsg, metadata: &localMeta,
                                                       requests: recordsByID)
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
                    c.assistanceSettings?.usePersonalMemory = false
                    c.assistanceSettings?.automaticRouting = false
                    c.assistanceSettings?.fallbackEnabled = false
                    c.assistanceSettings?.autoGenerateTitle = false
                    conversation = try restoredConversation(c, exportedAt: archive.exportedAt)
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
                        attachments: m.attachments.map(\.withBoundedImagePayload),
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
                    message.promptTokens = LLMUsage.valid(m.promptTokens)
                    message.completionTokens = LLMUsage.valid(m.completionTokens)
                    message.cachedTokens = LLMUsage.valid(m.cachedTokens)
                    message.latencyMs = LLMUsage.valid(m.latencyMs)
                    message.thinkingDurationMs = LLMUsage.valid(m.thinkingDurationMs)
                    message.synthesisSourceDigest = m.synthesisSourceDigest
                    message.parentMessageID = m.parentMessageID
                    if let originalMeta = m.assistanceMetadata {
                        var meta = sanitizedRestoredMetadata(originalMeta)
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
                conversation.normalizeMessageOrderIfNeeded()
                if needsTree {
                    let archiveOrder = c.messages.compactMap { restoredByID[$0.id] ?? existingMessages[$0.id] }
                    _ = ConversationTree.linkHistory(archiveOrder, preserving: localIDs)
                }
            }

        case .legacy(let conversations):
            guard conversations.allSatisfy({ $0.messages.count <= maximumImportedMessagesPerConversation }) else {
                throw BackupError.conversationMessageLimit
            }
            let existing = try txContext.fetch(FetchDescriptor<Conversation>())
            var importedIDs = Set(existing.map(\.id) + existing.compactMap { $0.backupState.legacyImportID })
            var recognized = Set<UUID>()
            // Text exports predate UUIDs. Recognize exact imports made by older versions too.
            let byDate = Dictionary(grouping: existing, by: \.updatedAt)
            var occurrences: [UUID: Int] = [:]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for legacy in conversations {
                let digest = UUID(contentOf: try encoder.encode(legacy))
                let ordinal = occurrences[digest, default: 0]
                occurrences[digest] = ordinal + 1
                let id = UUID(contentOf: Data("iosbox.legacy.chat/\(digest)/\(ordinal)".utf8))
                guard importedIDs.insert(id).inserted else { summary.skipped += 1; continue }
                if let prior = byDate[legacy.updatedAt]?.first(where: {
                    !recognized.contains($0.id) && $0.backupState.legacyImportID == nil &&
                    $0.id != id && legacy.matches($0)
                }) {
                    prior.backupState.legacyImportID = id
                    recognized.insert(prior.id)
                    summary.skipped += 1
                    continue
                }
                let conversation = Conversation(id: id, title: legacy.title, systemPrompt: legacy.systemPrompt)
                conversation.backupState.legacyImportID = id
                conversation.updatedAt = legacy.updatedAt
                conversation.createdAt = legacy.messages.first?.createdAt ?? legacy.updatedAt
                txContext.insert(conversation)
                for (index, m) in legacy.messages.enumerated() {
                    let message = ChatMessage(
                        id: UUID(contentOf: Data("iosbox.legacy.message/\(id)/\(index)".utf8)),
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

    private static func mergeOrganization(_ incoming: ConversationBackup, into local: Conversation) -> Bool {
        let remote = incoming.organizationEdits ?? .init()
        var edits = local.backupState.organizationEdits ?? .init()
        // Exports without per-field clocks can still be compared with the last common snapshot.
        // An untracked local edit wins a conflict; a newer remote edit wins if the field was untouched.
        let base = local.backupState.lastImportedOrganization
        let newer = incoming.updatedAt > local.updatedAt
        func accept(_ remote: TimeInterval?, _ localTime: TimeInterval?, unchanged: Bool) -> Bool {
            if let remote { return remote > (localTime ?? -.infinity) && (localTime != nil || base == nil || unchanged) }
            return localTime == nil && newer && unchanged
        }
        var changed = false
        if accept(remote.title, edits.title, unchanged: base.map { $0.title == local.title } ?? (local.messages.isEmpty || Conversation.isDefaultTitle(local.title))) {
            changed = local.title != incoming.title || edits.title != remote.title
            local.title = incoming.title
            edits.title = remote.title
        }
        if accept(remote.pin, edits.pin, unchanged: base.map { $0.isPinned == local.isPinned } ?? local.messages.isEmpty) {
            changed = changed || local.isPinned != incoming.isPinned || edits.pin != remote.pin
            local.isPinned = incoming.isPinned
            edits.pin = remote.pin
        }
        if accept(remote.tag, edits.tag, unchanged: base.map { $0.folderTag == local.folderTag } ?? local.messages.isEmpty) {
            changed = changed || local.folderTag != incoming.folderTag || edits.tag != remote.tag
            local.folderTag = incoming.folderTag
            edits.tag = remote.tag
        }
        if edits != .init(), edits != local.backupState.organizationEdits { local.backupState.organizationEdits = edits }
        if newer { local.backupState.lastImportedOrganization = incoming.organization }
        return changed
    }

    private static func sanitizedRestoredMetadata(_ source: AssistanceMetadata) -> AssistanceMetadata {
        var metadata = source
        metadata.knowledgeEvidence = sanitized(source.knowledgeEvidence)
        metadata.bookReply = sanitized(source.bookReply)
        metadata.revisions = source.revisions.map { item in
            var revision = item
            revision.knowledgeEvidence = sanitized(item.knowledgeEvidence)
            revision.bookReply = sanitized(item.bookReply)
            revision.attachments = item.attachments.map(\.withBoundedImagePayload)
            revision.promptTokens = LLMUsage.valid(item.promptTokens)
            revision.completionTokens = LLMUsage.valid(item.completionTokens)
            revision.cachedTokens = LLMUsage.valid(item.cachedTokens)
            revision.latencyMs = LLMUsage.valid(item.latencyMs)
            revision.thinkingDurationMs = LLMUsage.valid(item.thinkingDurationMs)
            return revision
        }
        if let index = source.activeRevisionIndex, !source.revisions.indices.contains(index) { metadata.activeRevisionIndex = nil }
        return metadata
    }

    private static func sanitized(_ source: KnowledgeEvidence?) -> KnowledgeEvidence? {
        guard var evidence = source else { return nil }
        for i in evidence.passages.indices {
            let original = evidence.passages[i]
            let location = ReadingCitation.validLocation(index: original.chapterIndex, offset: original.utf16Offset)
            evidence.passages[i].chapterIndex = location?.index
            evidence.passages[i].utf16Offset = location?.offset
        }
        return evidence
    }

    private static func sanitized(_ source: BookReplyEvidence?) -> BookReplyEvidence? {
        guard let source else { return nil }
        let excerpts = source.excerpts.map { original in
            let location = ReadingCitation.validLocation(index: original.chapterIndex, offset: original.utf16Offset)
            var excerpt = original
            excerpt.chapterIndex = location?.index
            excerpt.utf16Offset = location?.offset
            return excerpt
        }
        return BookReplyEvidence(name: source.name, title: source.title, excerpts: excerpts)
    }

    @MainActor
    private static func mergeReplies(_ incoming: MessageBackup, into local: ChatMessage,
                                     metadata: inout AssistanceMetadata, requests: [UUID: RequestRecord]) -> Bool {
        guard local.role == .assistant, incoming.role == local.roleRaw, !local.isStreaming else { return false }
        let remoteMeta = sanitizedRestoredMetadata(incoming.assistanceMetadata ?? AssistanceMetadata())
        let remote = MessageRevision(content: incoming.content, reasoningContent: incoming.reasoningContent,
                                     attachments: incoming.attachments.map(\.withBoundedImagePayload), providerID: incoming.providerID,
                                     providerName: incoming.providerName, modelID: incoming.modelID,
                                     modelDisplayName: incoming.modelDisplayName, accentHex: incoming.accentHex,
                                     promptTokens: LLMUsage.valid(incoming.promptTokens), completionTokens: LLMUsage.valid(incoming.completionTokens),
                                     cachedTokens: LLMUsage.valid(incoming.cachedTokens), latencyMs: LLMUsage.valid(incoming.latencyMs),
                                     thinkingDurationMs: LLMUsage.valid(incoming.thinkingDurationMs), finishReason: incoming.finishReason,
                                     isPersonaSimulation: remoteMeta.isPersonaSimulation, bookReply: remoteMeta.bookReply, personaExcerpts: remoteMeta.personaExcerpts,
                                     privateSpeaker: remoteMeta.privateSpeaker, knowledgeEvidence: remoteMeta.knowledgeEvidence,
                                     createdAt: incoming.createdAt)
        let current = ChatEngine.snapshotRevision(of: local)
        let history = remoteMeta.revisions
        let promote = metadata.activeRevisionIndex == nil && remoteMeta.activeRevisionIndex == nil &&
            remote.hasContent && !current.representsSameReply(as: remote) &&
            (!current.hasContent || history.contains { $0.representsSameReply(as: current) })
        var added = false
        if let index = metadata.activeRevisionIndex, !metadata.revisions.indices.contains(index) {
            metadata.activeRevisionIndex = nil
            added = true
        }
        let selected = metadata.activeRevisionIndex
        var insertAt = selected == nil ? metadata.revisions.count : max(0, metadata.revisions.count - 1)
        for version in history + [remote] {
            let isActive = (promote ? remote : current).representsSameReply(as: version)
            guard version.hasContent, !isActive, !metadata.revisions.contains(where: { $0.id == version.id || $0.representsSameReply(as: version) }) else { continue }
            metadata.revisions.insert(version, at: insertAt)
            if let index = metadata.activeRevisionIndex, index >= insertAt { metadata.activeRevisionIndex = index + 1 }
            insertAt += 1
            added = true
        }
        if promote {
            local.applyRevision(remote, metadata: &metadata)
            local.errorMessage = incoming.errorMessage
            local.latestRequest = incoming.latestRequestID.flatMap { requests[$0] }
            metadata.knowledgeEvidence = remoteMeta.knowledgeEvidence
            metadata.search = remoteMeta.search
            metadata.toolCalls = remoteMeta.toolCalls
        }
        return added || promote
    }

    private static func restoredConversation(_ c: ConversationBackup, exportedAt: Date) throws -> Conversation {
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
        conversation.backupState.organizationEdits = c.organizationEdits
        conversation.backupState.legacyImportID = c.legacyImportID
        conversation.backupState.lastImportedOrganization = c.organization
        conversation.backupState.lastImportedSettings = .init(digest: try c.configurationDigest(), exportedAt: exportedAt)
        conversation.activeLeafMessageID = c.activeLeafMessageID
        conversation.folderTag = c.folderTag
        conversation.createdAt = c.createdAt
        conversation.updatedAt = c.updatedAt
        return conversation
    }
}
