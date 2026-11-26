import Foundation
import SwiftData

// MARK: - Archive format

/// Full local backup without account credentials. Recreated providers retain their IDs for
/// conversation references and start disabled with their own local Keychain accounts.
struct BackupArchive: Codable {
    static let currentFormatVersion = 8

    var formatVersion: Int
    var exportedAt: Date
    var appVersion: String
    var providers: [ProviderBackup]
    var presets: [PresetBackup]
    var conversations: [ConversationBackup]
    var requests: [RequestRecord.Snapshot]?
    var memories: [PersonalMemory.Snapshot]?
    var books: [BookVolume.Snapshot]? = nil
    var personaProfiles: [GroupMember]? = nil
    var shelfPositions: [ShelfReadingState.Position]? = nil
    var tombstones: [SyncTombstone]? = nil
    var englishCoach: EnglishCoachStore.PersistedState? = nil
    var annotations: [ReadingAnnotation.Snapshot]? = nil
    var memoryCollections: [NamedMemoryCollection]? = nil
    var friendMemories: FriendMemoryStore.PersistedState? = nil
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
    var updatedAt: Date? = nil
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
    var memoryIDs: [UUID]? = nil
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
    var messageChanges: [UUID: MessagePresenceChange]? = nil

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
        config.messageChanges = nil
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
    var deleted = 0
    /// Items already present (same ID) and therefore left untouched.
    var skipped = 0
    var credentialConflicts: [String] = []
    var confirmedCredentials = 0
    var failedCredentialWrites = 0
    var restoredProfiles = 0
    var knowledgeRestoreFailed = false
    var memoryCollections = 0
    var memoryCollectionWriteFailed = false
    var annotations = 0
    var drafts = 0
    var conflictingDrafts = 0
    var draftFailures = 0

    var hasWarnings: Bool {
        !credentialConflicts.isEmpty || failedCredentialWrites > 0 || knowledgeRestoreFailed || memoryCollectionWriteFailed || draftFailures > 0
    }
    var title: String { hasWarnings ? String(localized: "备份需继续处理") : String(localized: "导入完成") }

    var description: String {
        var parts: [String] = []
        if restoredProfiles > 0 { parts.append(String(localized: "人物档案 \(restoredProfiles) 个")) }
        if memoryCollections > 0 { parts.append(String(localized: "记忆集合 \(memoryCollections) 个")) }
        if annotations > 0 { parts.append(String(localized: "读书摘录 \(annotations) 条")) }
        if drafts > 0 { parts.append(String(localized: "未发送草稿 \(drafts) 份")) }
        if conflictingDrafts > 0 { parts.append(String(localized: "\(conflictingDrafts) 份不同版本已另存至「找回的草稿」分组")) }
        if draftFailures > 0 { parts.append(String(localized: "有 \(draftFailures) 份草稿未能写入，可以重新导入")) }
        if restoredConversations > 0 {
            parts.append(String(localized: "已恢复 \(restoredConversations) 个原对话"))
        }
        if conversations > 0 { parts.append(String(localized: "新建对话 \(conversations) 个")) }
        if messages > 0 { parts.append(String(localized: "消息 \(messages) 条")) }
        if providers > 0 { parts.append(String(localized: "服务商 \(providers) 个")) }
        if presets > 0 { parts.append(String(localized: "助手 \(presets) 个")) }
        if requests > 0 { parts.append(String(localized: "请求记录 \(requests) 条")) }
        if books > 0 { parts.append(String(localized: "书籍 \(books) 本")) }
        if memories > 0 {
            parts.append(String(localized: "记忆 \(memories) 条"))
        }
        if deleted > 0 {
            parts.append(String(localized: "同步移除 \(deleted) 项"))
        }
        if skipped > 0 {
            parts.append(String(localized: "跳过已存在的 \(skipped) 项"))
        }
        var lines: [String] = []
        if !parts.isEmpty {
            let list = parts.joined(separator: String(localized: "，"))
            lines.append(String(localized: "已导入：\(list)。"))
        }
        if memoryCollectionWriteFailed { lines.append(String(localized: "记忆集合未能写入，可重新导入备份。")) }
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
                for decision in message.assistanceMetadata?.arenaDecisions ?? [] {
                    try count(decision.question)
                    try count(decision.reason)
                    for tag in decision.tags { try count(tag) }
                    for answer in decision.answers {
                        try count(answer.content)
                        for attachment in answer.attachments {
                            try count(attachment.dataBase64)
                            try count(attachment.extractedText)
                        }
                    }
                }
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
        knowledgeStore: PresetKnowledgeStore = .shared,
        tombstoneStore: SyncTombstoneStore? = nil,
        friendMemoryStore: FriendMemoryStore? = nil
    ) throws -> BackupArchive {
        guard PersistenceController.canCommitUserData(in: context) else { throw BackupError.storageUnavailable }
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        let presets = try context.fetch(FetchDescriptor<AssistantPreset>(sortBy: [SortDescriptor(\.sortOrder)]))
        let conversations = try context.fetch(
            FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        let requests = try context.fetch(FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.startedAt)]))
        let memories = try context.fetch(FetchDescriptor<PersonalMemory>(sortBy: [SortDescriptor(\.createdAt)]))
        let bindings = try knowledgeStore.readableBindings()
        let memoryIDs = Set(memories.map(\.id))
        let collections: [NamedMemoryCollection] = tombstoneStore == nil ? NamedMemoryCollection.read(bindings).map { group in
            var snapshot = group
            snapshot.memoryIDs = group.memoryIDs.filter { memoryIDs.contains($0) }
            return snapshot
        } : []
        let tombstones = tombstoneStore?.allTombstones() ?? []
        let isPersistent = !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly)
        let englishSnapshot = isPersistent ? EnglishCoachStore.shared.snapshotForBackup() : nil
        let effectiveFriendStore = friendMemoryStore ?? (isPersistent ? FriendMemoryStore.shared : nil)
        let friendMemoriesSnapshot = effectiveFriendStore?.exportState()
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
                    notes: p.notes,
                    updatedAt: p.updatedAt
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
                    knowledgeVolumeIDs: volumeIDs.isEmpty ? nil : volumeIDs, memoryIDs: bindings[PresetKnowledgeStore.memoryKey(p.id)]
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
            personaProfiles: try context.fetch(FetchDescriptor<PersonaProfile>()).map { try $0.member().portableProfile },
            shelfPositions: try context.fetch(FetchDescriptor<ShelfReadingState>()).map(\.position),
            tombstones: tombstones.isEmpty ? nil : tombstones,
            englishCoach: englishSnapshot,
            annotations: try context.fetch(FetchDescriptor<ReadingAnnotation>()).map(\.snapshot),
            memoryCollections: collections.isEmpty ? nil : collections,
            friendMemories: friendMemoriesSnapshot
        )
    }

    @MainActor
    static func snapshot(_ c: Conversation, forExport: Bool = false, includeMessages: Bool = true) -> ConversationBackup {
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
            organizationEdits: c.backupState.organizationEdits, legacyImportID: c.backupState.legacyImportID,
            messageChanges: c.backupState.messageChanges
        )
    }

    /// The caller waits for streaming to stop before taking this one-conversation undo snapshot.
    @MainActor
    static func clearMessages(in conversation: Conversation, context: ModelContext) throws -> ConversationBackup {
        try context.save()
        let saved = snapshot(conversation)
        do {
            var changes = conversation.backupState.messageChanges ?? [:]
            MessagePresenceChange.record(saved.messages.map(\.id), deleted: true, in: &changes)
            conversation.backupState.messageChanges = changes
            for message in conversation.messages { context.delete(message) }
            conversation.messages.removeAll()
            conversation.activeLeafMessageID = nil
            try context.save()
            WebDAVAutoSyncCoordinator.shared.markWorkspaceChanged(in: context)
            if !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                RollingContextSummaryStore.shared.remove(for: conversation.id)
            }
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
        WebDAVAutoSyncCoordinator.shared.markWorkspaceChanged(in: context)
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
        var presetMemoryBindings: [UUID: [UUID]] = [:]
        var updatedPresetKnowledgeBindings: [UUID: [UUID]] = [:]
        var updatedPresetMemoryBindings: [UUID: Set<UUID>?] = [:]
        var deletedConversationIDs: [UUID] = []
        var clearedHistoryIDs: [UUID] = []
        var enrichedBookIDs: [UUID] = []
        var deletedBookIDs: [UUID] = []
        var deletedPresetIDs: [UUID] = []
        var deletedMemoryIDs: [UUID] = []
        var survivingMemoryIDs = Set<UUID>()
        var deletedKeychainAccounts: [String] = []
        var incomingTombstones: [SyncTombstone] = []
        var clearedTombstones: [SyncTombstoneKey] = []
        var mergedTombstoneMap: [SyncTombstoneKey: Date] = [:]
        var manuallyRestoredItems: [(SyncEntityKind, UUID)] = []
    }

    @MainActor
    @discardableResult
    static func apply(
        _ backup: DecodedBackup,
        to context: ModelContext,
        knowledgeStore: PresetKnowledgeStore = .shared,
        tombstonePolicy: SyncTombstonePolicy = .ignore,
        friendMemoryStore: FriendMemoryStore? = nil
    ) throws -> ImportSummary {
        guard PersistenceController.canCommitUserData(in: context) else { throw BackupError.storageUnavailable }
        let isPersistent = !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly)
        try context.save()
        // All import work is synchronous on the main actor. Preserve earlier edits before
        // the transaction so a rollback affects only the incoming backup.
        var summary = ImportSummary()
        var sidecars = PostCommitSidecarUpdates()
        do {
            try context.transaction {
                summary = try importData(backup, in: context, sidecars: &sidecars, tombstonePolicy: tombstonePolicy)
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
            let survivingPresetIDs = archive.presets.map(\.id).filter { !sidecars.deletedPresetIDs.contains($0) }
            do {
                for (presetID, volumes) in sidecars.updatedPresetKnowledgeBindings {
                    let memories = sidecars.updatedPresetMemoryBindings[presetID] ?? nil
                    try knowledgeStore.setBindings(volumes: volumes, memories: memories, for: presetID) {}
                }
                try knowledgeStore.restoreNewBindings(sidecars.presetKnowledgeBindings, memories: sidecars.presetMemoryBindings, retrying: survivingPresetIDs)
            }
            catch { summary.knowledgeRestoreFailed = true }
            do {
                try knowledgeStore.removeFromMemoryCollections(Set(sidecars.deletedMemoryIDs))
                if case .ignore = tombstonePolicy {
                    summary.memoryCollections = try knowledgeStore.restoreMemoryCollections(archive.memoryCollections ?? [],
                                                                                           survivingIDs: sidecars.survivingMemoryIDs)
                }
            } catch { summary.memoryCollectionWriteFailed = true }
        }
        for presetID in sidecars.deletedPresetIDs {
            try? knowledgeStore.setBindings(volumes: [], memories: nil, for: presetID) {}
        }
        for bookID in sidecars.deletedBookIDs {
            try? knowledgeStore.removeVolume(bookID)
            Task {
                await ProjectKnowledgeSearch.shared.invalidate(volumeID: bookID)
                if isPersistent {
                    try? await FullTextSearchIndex.shared.invalidateBookVolume(bookID)
                }
            }
        }
        for bookID in sidecars.enrichedBookIDs where isPersistent {
            Task {
                await ProjectKnowledgeSearch.shared.invalidate(volumeID: bookID)
                await BookReferenceSearch.shared.invalidate(bookID: bookID)
                try? await FullTextSearchIndex.shared.invalidateBookVolume(bookID)
            }
        }
        for id in sidecars.clearedHistoryIDs where isPersistent {
            RollingContextSummaryStore.shared.remove(for: id)
            SpotlightIndexService.shared.removeConversation(id: id)
        }
        for convID in sidecars.deletedConversationIDs {
            try? ChatDraftStore.shared.remove(convID)
            SpotlightIndexService.shared.removeConversation(id: convID)
        }
        for account in sidecars.deletedKeychainAccounts {
            KeychainService.shared.deleteSecret(account: account)
        }
        if case .full(let archive) = backup,
           let incomingEnglish = archive.englishCoach,
           !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
            EnglishCoachStore.shared.mergeImported(incomingEnglish)
        }
        if case .full(let archive) = backup,
           let targetFriendStore = friendMemoryStore ?? (isPersistent ? FriendMemoryStore.shared : nil) {
            let enforcing: Bool
            if case .enforce = tombstonePolicy { enforcing = true } else { enforcing = false }
            let deletedPersonaIDs = Set(
                sidecars.mergedTombstoneMap.keys
                    .filter { $0.kind == .personaProfile }
                    .map(\.id)
            )
            let deletedBookIDs = Set(sidecars.deletedBookIDs).union(
                sidecars.mergedTombstoneMap.keys
                    .filter { $0.kind == .book }
                    .map(\.id)
            )
            if let incomingFriendMemories = archive.friendMemories {
                targetFriendStore.mergeImported(
                    incomingFriendMemories,
                    deletedPersonaIDs: deletedPersonaIDs,
                    deletedBookIDs: deletedBookIDs,
                    enforcingTombstones: enforcing
                )
            } else if enforcing && (!deletedPersonaIDs.isEmpty || !deletedBookIDs.isEmpty) {
                targetFriendStore.mergeImported(
                    FriendMemoryStore.PersistedState(),
                    deletedPersonaIDs: deletedPersonaIDs,
                    deletedBookIDs: deletedBookIDs,
                    enforcingTombstones: true
                )
            }
        }

        switch tombstonePolicy {
        case .enforce(let tombstoneStore):
            tombstoneStore.merge(sidecars.incomingTombstones, removing: sidecars.clearedTombstones)

        case .ignore:
            // Manual backup restore: clear stale local tombstones for items explicitly restored on persistent stores.
            if isPersistent && !sidecars.manuallyRestoredItems.isEmpty {
                SyncTombstoneStore.shared.removeTombstones(sidecars.manuallyRestoredItems)
            }
        }
        return summary
    }

    @MainActor
    private static func importData(
        _ backup: DecodedBackup,
        in txContext: ModelContext,
        sidecars: inout PostCommitSidecarUpdates,
        tombstonePolicy: SyncTombstonePolicy = .ignore
    ) throws -> ImportSummary {
        var summary = ImportSummary()

        switch backup {
        case .full(let archive):
            guard archive.formatVersion <= BackupArchive.currentFormatVersion else { throw BackupError.newerFormat(archive.formatVersion) }
            let localProviders = try txContext.fetch(FetchDescriptor<ProviderConfig>())
            let localPresets = try txContext.fetch(FetchDescriptor<AssistantPreset>())
            var existingConversations = Dictionary(uniqueKeysWithValues:
                try txContext.fetch(FetchDescriptor<Conversation>()).map { ($0.id, $0) })
            let existingRequestList = try txContext.fetch(FetchDescriptor<RequestRecord>())
            var recordsByID = Dictionary(uniqueKeysWithValues: existingRequestList.map { ($0.id, $0) })
            let localMemories = try txContext.fetch(FetchDescriptor<PersonalMemory>())

            var mergedTombstones: [SyncTombstoneKey: Date] = [:]
            let enforcingTombstones: Bool
            if case .enforce(let store) = tombstonePolicy {
                enforcingTombstones = true
                mergedTombstones = store.tombstoneMap()
                let incoming = archive.tombstones ?? []
                sidecars.incomingTombstones = incoming
                for mark in incoming {
                    if let existing = mergedTombstones[mark.key], existing >= mark.deletedAt { continue }
                    mergedTombstones[mark.key] = mark.deletedAt
                }
                sidecars.mergedTombstoneMap = mergedTombstones
            } else {
                enforcingTombstones = false
            }

            func isBlockedByTombstone(kind: SyncEntityKind, id: UUID, timestamp: Date?) -> Bool {
                guard enforcingTombstones,
                      let deletedAt = mergedTombstones[SyncTombstoneKey(kind: kind, id: id)] else {
                    return false
                }
                if let timestamp, timestamp > deletedAt {
                    sidecars.clearedTombstones.append(SyncTombstoneKey(kind: kind, id: id))
                    return false
                }
                return true
            }

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
            let collections = archive.memoryCollections ?? []
            guard unique(collections.map(\.id)), collections.allSatisfy(\.isValid) else { throw BackupError.unrecognizedFormat }
            let annotations = archive.annotations ?? []
            guard unique(annotations.map(\.id)), annotations.allSatisfy(\.isValid) else { throw BackupError.unrecognizedFormat }

            guard unique(archive.providers.map(\.id)),
                  unique(archive.presets.map(\.id)),
                  unique(archive.conversations.map(\.id)),
                  archive.conversations.allSatisfy({ unique($0.assistanceSettings?.groupMembers.map(\.id) ?? []) }),
                  unique(incomingMessages.map(\.id)),
                  unique(incomingRequests.map(\.id)),
                  unique(incomingMemories.map(\.id)),
                  unique(incomingBooks.map(\.id)) else {
                throw BackupError.conflictingIDs
            }

            // Validate personal memory bounds atomically before mutating anything.
            for mem in incomingMemories {
                let trimmed = mem.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, mem.content.count <= PersonalMemory.maximumCharacters else {
                    throw BackupError.unrecognizedFormat
                }
            }

            var existingMessages = Dictionary(uniqueKeysWithValues:
                try txContext.fetch(FetchDescriptor<ChatMessage>()).map { ($0.id, $0) })
            for conversation in archive.conversations {
                for incoming in conversation.messages {
                    if let local = existingMessages[incoming.id], local.conversation?.id != conversation.id {
                        throw BackupError.conflictingIDs
                    }
                }
            }

            // Propagate remote deletions to locally existing entities when syncing.
            var existingProviders = Set(localProviders.map(\.id))
            var existingPresets = Set(localPresets.map(\.id))
            var existingMemories = Set(localMemories.map(\.id))
            let memoriesByID = Dictionary(uniqueKeysWithValues: localMemories.map { ($0.id, $0) })

            if enforcingTombstones && !mergedTombstones.isEmpty {
                for localBook in try txContext.fetch(FetchDescriptor<BookVolume>()) {
                    if isBlockedByTombstone(kind: .book, id: localBook.id, timestamp: localBook.importedAt) {
                        if let state = try ShelfReadingState.find(localBook.id, in: txContext) {
                            txContext.delete(state)
                        }
                        txContext.delete(localBook)
                        sidecars.deletedBookIDs.append(localBook.id)
                        summary.deleted += 1
                    }
                }
                for savedProfile in try txContext.fetch(FetchDescriptor<PersonaProfile>()) {
                    if isBlockedByTombstone(kind: .personaProfile, id: savedProfile.id, timestamp: nil) {
                        txContext.delete(savedProfile)
                        summary.deleted += 1
                    }
                }
                for localMem in localMemories {
                    if isBlockedByTombstone(kind: .memory, id: localMem.id, timestamp: localMem.updatedTimestamp.map(Date.init(timeIntervalSince1970:)) ?? localMem.createdAt) {
                        txContext.delete(localMem)
                        existingMemories.remove(localMem.id)
                        sidecars.deletedMemoryIDs.append(localMem.id)
                        summary.deleted += 1
                    }
                }
                for localProvider in localProviders {
                    if isBlockedByTombstone(kind: .provider, id: localProvider.id, timestamp: localProvider.updatedAt) {
                        let credID = localProvider.credentialID
                        sidecars.deletedKeychainAccounts.append(credID.uuidString)
                        sidecars.deletedKeychainAccounts.append(KeychainService.extraKeysAccount(providerID: credID))
                        for header in localProvider.customHeaders where header.isSecret {
                            sidecars.deletedKeychainAccounts.append(
                                KeychainService.headerAccount(providerID: credID, headerID: header.id)
                            )
                        }
                        txContext.delete(localProvider)
                        existingProviders.remove(localProvider.id)
                        summary.deleted += 1
                    }
                }
                for localPreset in localPresets {
                    if isBlockedByTombstone(kind: .preset, id: localPreset.id, timestamp: nil) {
                        txContext.delete(localPreset)
                        existingPresets.remove(localPreset.id)
                        sidecars.deletedPresetIDs.append(localPreset.id)
                        summary.deleted += 1
                    }
                }
                for (convID, localConv) in existingConversations {
                    if isBlockedByTombstone(kind: .conversation, id: convID, timestamp: localConv.updatedAt) {
                        txContext.delete(localConv)
                        existingConversations.removeValue(forKey: convID)
                        sidecars.deletedConversationIDs.append(convID)
                        summary.deleted += 1
                    }
                }
            }

            var chapterCounts = try Dictionary(uniqueKeysWithValues:
                txContext.fetch(FetchDescriptor<BookVolume>()).map { ($0.id, $0.chapterTitles.count) })
            if !annotations.isEmpty || mergedTombstones.keys.contains(where: { $0.kind == .readingAnnotation }) {
                var saved = Dictionary(uniqueKeysWithValues: try txContext.fetch(FetchDescriptor<ReadingAnnotation>()).map { ($0.id, $0) })
                for (id, item) in saved where isBlockedByTombstone(kind: .readingAnnotation, id: id, timestamp: item.updatedAt) {
                    saved.removeValue(forKey: id)
                    txContext.delete(item)
                    summary.deleted += 1
                }
                for item in annotations {
                    if isBlockedByTombstone(kind: .readingAnnotation, id: item.id, timestamp: item.effectiveUpdatedAt) { continue }
                    if let local = saved[item.id] {
                        guard enforcingTombstones && item.effectiveUpdatedAt > local.updatedAt else { continue }
                        local.apply(item)
                    } else {
                        txContext.insert(ReadingAnnotation(item))
                    }
                    if !enforcingTombstones { sidecars.manuallyRestoredItems.append((.readingAnnotation, item.id)) }
                    summary.annotations += 1
                }
            }
            func checkedProgress(_ friend: BookFriend?) -> BookFriend? {
                friend.map { $0.validatingRestoredProgress(chapterCount: chapterCounts[$0.bookID]) }
            }
            for book in incomingBooks {
                let prepared = try book.validatedManuscript()
                if isBlockedByTombstone(kind: .book, id: book.id, timestamp: book.importedAt) {
                    continue
                }
                if let local = try BookLibrary.find(book.id, in: txContext) {
                    if let updated = try mergePDFPages(book, into: local) {
                        chapterCounts[book.id] = updated
                        sidecars.enrichedBookIDs.append(book.id)
                    }
                } else {
                    txContext.insert(BookVolume(id: book.id, title: book.title, chapterTitles: prepared.chapterTitles,
                                                manuscript: prepared.data, importedAt: book.importedAt))
                    chapterCounts[book.id] = prepared.chapterTitles.count
                    summary.books += 1
                    if !enforcingTombstones { sidecars.manuallyRestoredItems.append((.book, book.id)) }
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
                var savedProfilesByID: [UUID: PersonaProfile] = [:]
                for saved in try txContext.fetch(FetchDescriptor<PersonaProfile>()) {
                    savedProfilesByID[saved.id] = saved
                    linkedProfiles[saved.id] = try saved.member()
                }
                for var member in profiles {
                    guard member.profileID == member.id, !member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackupError.unrecognizedFormat }
                    if isBlockedByTombstone(kind: .personaProfile, id: member.id, timestamp: nil) { continue }
                    member.bookFriend = checkedProgress(member.bookFriend)
                    let portable = member.portableProfile
                    if let existingSaved = savedProfilesByID[member.id] {
                        if enforcingTombstones, linkedProfiles[member.id]?.portableProfile != portable {
                            existingSaved.name = portable.name
                            existingSaved.memberData = try JSONEncoder().encode(portable)
                            linkedProfiles[member.id] = portable
                            summary.restoredProfiles += 1
                        }
                        continue
                    }
                    let saved = try PersonaProfile(member)
                    txContext.insert(saved)
                    savedProfilesByID[saved.id] = saved
                    linkedProfiles[saved.id] = portable
                    summary.restoredProfiles += 1
                    if !enforcingTombstones { sidecars.manuallyRestoredItems.append((.personaProfile, member.id)) }
                }
            }
            for point in positions {
                guard let book = try BookLibrary.find(point.bookID, in: txContext),
                      book.chapterTitles.indices.contains(point.chapter), point.paragraph >= 0 else { continue }
                let existing = try ShelfReadingState.find(point.bookID, in: txContext)
                if let existing {
                    guard enforcingTombstones, let timestamp = point.updatedTimestamp,
                          timestamp > (existing.updatedTimestamp ?? 0) else { continue }
                }
                let state = existing ?? ShelfReadingState(bookID: point.bookID)
                state.conversationID = point.conversationID
                state.chapter = point.chapter
                state.paragraph = point.paragraph
                state.updatedTimestamp = point.updatedTimestamp
                if existing == nil { txContext.insert(state) }
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

            for mem in incomingMemories {
                if isBlockedByTombstone(kind: .memory, id: mem.id, timestamp: mem.updatedTimestamp.map(Date.init(timeIntervalSince1970:)) ?? mem.createdAt) { continue }
                if existingMemories.contains(mem.id), let local = memoriesByID[mem.id] {
                    guard enforcingTombstones, let timestamp = mem.updatedTimestamp,
                          timestamp > (local.updatedTimestamp ?? 0) else { continue }
                    local.content = mem.content
                    local.isEnabled = mem.isEnabled
                    local.updatedTimestamp = timestamp
                    continue
                }
                let memory = PersonalMemory(
                    id: mem.id,
                    content: mem.content,
                    isEnabled: mem.isEnabled,
                    createdAt: mem.createdAt
                )
                memory.updatedTimestamp = mem.updatedTimestamp
                txContext.insert(memory)
                existingMemories.insert(mem.id)
                summary.memories += 1
                if !enforcingTombstones { sidecars.manuallyRestoredItems.append((.memory, mem.id)) }
            }
            sidecars.survivingMemoryIDs = existingMemories

            let localProvidersByID = Dictionary(uniqueKeysWithValues:
                localProviders.filter { existingProviders.contains($0.id) }.map { ($0.id, $0) })
            let localPresetsByID = Dictionary(uniqueKeysWithValues:
                localPresets.filter { existingPresets.contains($0.id) }.map { ($0.id, $0) })

            for p in archive.providers {
                if isBlockedByTombstone(kind: .provider, id: p.id, timestamp: p.updatedAt) { continue }
                if existingProviders.contains(p.id) {
                    if let local = localProvidersByID[p.id],
                       mergeExistingProvider(p, into: local, enforcingTombstones: enforcingTombstones) {
                        summary.providers += 1
                    } else {
                        summary.skipped += 1
                    }
                    continue
                }
                let provider = ProviderConfig(
                    id: p.id, name: p.name,
                    protocolType: APIProtocolType(rawValue: p.protocolRaw) ?? .openAICompatible,
                    baseURL: p.baseURL, iconSymbol: p.iconSymbol, accentHex: p.accentHex,
                    isEnabled: false,
                    sortOrder: p.sortOrder, models: p.models,
                    customHeaders: p.customHeaders, notes: p.notes, isRestored: true
                )
                if let incomingUpdated = p.updatedAt {
                    provider.updatedAt = incomingUpdated
                }
                txContext.insert(provider)
                existingProviders.insert(p.id)
                summary.providers += 1
                if !enforcingTombstones { sidecars.manuallyRestoredItems.append((.provider, p.id)) }
            }

            for p in archive.presets {
                if isBlockedByTombstone(kind: .preset, id: p.id, timestamp: nil) { continue }
                if existingPresets.contains(p.id) {
                    if enforcingTombstones,
                       let local = localPresetsByID[p.id],
                       mergeExistingPreset(p, into: local) {
                        sidecars.updatedPresetKnowledgeBindings[p.id] = p.knowledgeVolumeIDs ?? []
                        sidecars.updatedPresetMemoryBindings[p.id] = p.memoryIDs.map(Set.init)
                        summary.presets += 1
                    } else {
                        summary.skipped += 1
                    }
                    continue
                }
                sidecars.presetKnowledgeBindings[p.id] = p.knowledgeVolumeIDs ?? []
                sidecars.presetMemoryBindings[p.id] = p.memoryIDs
                txContext.insert(AssistantPreset(
                    id: p.id, name: p.name, iconEmoji: p.iconEmoji, subtitle: p.subtitle,
                    systemPrompt: p.systemPrompt, temperature: p.temperature,
                    useCustomTemperature: p.useCustomTemperature, topP: p.topP,
                    maxOutputTokens: p.maxOutputTokens, contextMessageLimit: p.contextMessageLimit,
                    enableThinking: p.enableThinking, thinkingBudgetTokens: p.thinkingBudgetTokens,
                    isBuiltIn: p.isBuiltIn, sortOrder: p.sortOrder
                ))
                existingPresets.insert(p.id)
                summary.presets += 1
                if !enforcingTombstones { sidecars.manuallyRestoredItems.append((.preset, p.id)) }
            }

            for var c in archive.conversations {
                if isBlockedByTombstone(kind: .conversation, id: c.id, timestamp: c.updatedAt) {
                    continue
                }
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
                let localChat = existingConversations[c.id]
                var changes = localChat?.backupState.messageChanges ?? [:]
                if enforcingTombstones || localChat == nil {
                    for (id, remote) in c.messageChanges ?? [:] where remote.supersedes(changes[id]) {
                        changes[id] = remote
                    }
                }
                if enforcingTombstones {
                    c.messages.removeAll { changes[$0.id]?.deleted == true }
                    if let leaf = c.activeLeafMessageID, changes[leaf]?.deleted == true { c.activeLeafMessageID = nil }
                    if let localChat {
                        let removed = localChat.messages.filter { changes[$0.id]?.deleted == true }
                        let removedIDs = Set(removed.map(\.id))
                        if !removed.isEmpty {
                            for message in localChat.messages {
                                if let parent = message.parentMessageID, removedIDs.contains(parent) {
                                    message.parentMessageID = ConversationTree.virtualRootID
                                }
                            }
                            localChat.messages.removeAll { removedIDs.contains($0.id) }
                            if let leaf = localChat.activeLeafMessageID, removedIDs.contains(leaf) {
                                localChat.activeLeafMessageID = localChat.sortedMessages.last?.id
                            }
                            for message in removed {
                                existingMessages.removeValue(forKey: message.id)
                                txContext.delete(message)
                            }
                            sidecars.clearedHistoryIDs.append(localChat.id)
                            summary.deleted += removed.count
                        }
                    }
                    for index in c.messages.indices {
                        if let parent = c.messages[index].parentMessageID, changes[parent]?.deleted == true {
                            c.messages[index].parentMessageID = ConversationTree.virtualRootID
                        }
                    }
                } else {
                    let restoredIDs = c.messages.map(\.id).filter { changes[$0]?.deleted == true }
                    MessagePresenceChange.record(restoredIDs, deleted: false, in: &changes)
                }
                c.messageChanges = changes.isEmpty ? nil : changes
                if let localChat, localChat.backupState.messageChanges != c.messageChanges {
                    localChat.backupState.messageChanges = c.messageChanges
                }
                let missing = c.messages.filter { existingMessages[$0.id] == nil }
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
                        if enforcingTombstones, let timestamp = incomingMeta.bookmarkUpdatedTimestamp,
                           timestamp > (localMeta.bookmarkUpdatedTimestamp ?? 0) {
                            localMeta.isBookmarked = incomingMeta.isBookmarked
                            localMeta.bookmarkUpdatedTimestamp = timestamp
                            metaMutated = true
                        } else if incomingMeta.isBookmarked && !localMeta.isBookmarked &&
                                    localMeta.bookmarkUpdatedTimestamp == nil && incomingMeta.bookmarkUpdatedTimestamp == nil {
                            localMeta.isBookmarked = true
                            metaMutated = true
                        }
                        if let incoming = incomingMeta.arenaDecisions, !incoming.isEmpty {
                            let decisions = ArenaDecision.merged(localMeta.arenaDecisions ?? [], incoming)
                            if decisions != localMeta.arenaDecisions {
                                localMeta.arenaDecisions = decisions
                                metaMutated = true
                            }
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
                    if !enforcingTombstones { sidecars.manuallyRestoredItems.append((.conversation, c.id)) }
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
                        message.assistanceMetadata = sanitizedRestoredMetadata(originalMeta)
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

    private static func mergeExistingProvider(
        _ incoming: ProviderBackup,
        into local: ProviderConfig,
        enforcingTombstones: Bool
    ) -> Bool {
        var changed = false
        // Never overwrite baseURL, protocolRaw, or customHeaders on an existing local provider so
        // local Keychain credentials stay bound to their approved destination.
        if enforcingTombstones, let incomingUpdated = incoming.updatedAt, incomingUpdated > local.updatedAt {
            if local.name != incoming.name { local.name = incoming.name; changed = true }
            if local.iconSymbol != incoming.iconSymbol { local.iconSymbol = incoming.iconSymbol; changed = true }
            if local.accentHex != incoming.accentHex { local.accentHex = incoming.accentHex; changed = true }
            if local.sortOrder != incoming.sortOrder { local.sortOrder = incoming.sortOrder; changed = true }
            if local.notes != incoming.notes { local.notes = incoming.notes; changed = true }
            let deduplicatedIncoming = ProviderConfig.deduplicated(incoming.models)
            if local.models != deduplicatedIncoming {
                local.models = deduplicatedIncoming
                changed = true
            }
            if !incoming.isEnabled && local.isEnabled {
                local.isEnabled = false
                changed = true
            }
            local.updatedAt = incomingUpdated
            return changed
        }

        // Backfill missing pricing on matching models (and missing model entries during sync) non-destructively.
        let incomingByID = Dictionary(ProviderConfig.deduplicated(incoming.models).map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        var updatedModels = local.models
        var modelsMutated = false
        for idx in updatedModels.indices {
            guard let remoteSpec = incomingByID[updatedModels[idx].id] else { continue }
            if updatedModels[idx].inputPricePerMillion == nil, let price = remoteSpec.inputPricePerMillion {
                updatedModels[idx].inputPricePerMillion = price
                updatedModels[idx].priceCurrency = remoteSpec.priceCurrency
                modelsMutated = true
            }
            if updatedModels[idx].outputPricePerMillion == nil, let price = remoteSpec.outputPricePerMillion {
                updatedModels[idx].outputPricePerMillion = price
                updatedModels[idx].priceCurrency = remoteSpec.priceCurrency
                modelsMutated = true
            }
        }
        if enforcingTombstones {
            let knownIDs = Set(updatedModels.map(\.id))
            for spec in ProviderConfig.deduplicated(incoming.models) where !knownIDs.contains(spec.id) {
                updatedModels.append(spec)
                modelsMutated = true
            }
        }
        if modelsMutated {
            let previousUpdatedAt = local.updatedAt
            local.models = updatedModels
            if !enforcingTombstones {
                local.updatedAt = previousUpdatedAt
            }
            changed = true
        }
        return changed
    }

    private static func mergeExistingPreset(_ incoming: PresetBackup, into local: AssistantPreset) -> Bool {
        var changed = false
        if local.name != incoming.name { local.name = incoming.name; changed = true }
        if local.iconEmoji != incoming.iconEmoji { local.iconEmoji = incoming.iconEmoji; changed = true }
        if local.subtitle != incoming.subtitle { local.subtitle = incoming.subtitle; changed = true }
        if local.systemPrompt != incoming.systemPrompt { local.systemPrompt = incoming.systemPrompt; changed = true }
        if local.temperature != incoming.temperature { local.temperature = incoming.temperature; changed = true }
        if local.useCustomTemperature != incoming.useCustomTemperature { local.useCustomTemperature = incoming.useCustomTemperature; changed = true }
        if local.topP != incoming.topP { local.topP = incoming.topP; changed = true }
        if local.maxOutputTokens != incoming.maxOutputTokens { local.maxOutputTokens = incoming.maxOutputTokens; changed = true }
        if local.contextMessageLimit != incoming.contextMessageLimit { local.contextMessageLimit = incoming.contextMessageLimit; changed = true }
        if local.enableThinking != incoming.enableThinking { local.enableThinking = incoming.enableThinking; changed = true }
        if local.thinkingBudgetTokens != incoming.thinkingBudgetTokens { local.thinkingBudgetTokens = incoming.thinkingBudgetTokens; changed = true }
        if local.sortOrder != incoming.sortOrder { local.sortOrder = incoming.sortOrder; changed = true }
        return changed
    }

    private static func mergePDFPages(_ incoming: BookVolume.Snapshot, into local: BookVolume) throws -> Int? {
        guard BookVolume.Snapshot.isPDFManuscript(incoming.chapters) else { return nil }
        let existing = try JSONDecoder().decode([BookChapter].self, from: local.manuscript)
        guard BookVolume.Snapshot.isPDFManuscript(existing) else { return nil }
        let prefersEnglish = existing.first.map { $0.title.hasPrefix("Page ") } ?? false
        var pages: [Int: BookChapter] = [:]
        for chapter in existing {
            if let page = BackgroundPDFOCRQueue.extractPageNumber(from: chapter.title), pages[page] == nil {
                pages[page] = chapter
            }
        }
        for chapter in incoming.chapters {
            guard let page = BackgroundPDFOCRQueue.extractPageNumber(from: chapter.title) else { continue }
            if pages[page] == nil {
                var normalized = chapter
                normalized.title = prefersEnglish ? "Page \(page)" : "第 \(page) 页"
                pages[page] = normalized
            }
        }
        guard pages.count != existing.count else { return nil }
        let merged = pages.sorted { $0.key < $1.key }.map(\.value)
        let data = try BookManuscript(title: local.title, chapters: merged).encoded()
        local.manuscript = data
        local.manuscriptByteCount = data.count
        local.chapterTitles = merged.map(\.title)
        return merged.count
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
        conversation.backupState.messageChanges = c.messageChanges
        conversation.backupState.lastImportedOrganization = c.organization
        conversation.backupState.lastImportedSettings = .init(digest: try c.configurationDigest(), exportedAt: exportedAt)
        conversation.activeLeafMessageID = c.activeLeafMessageID
        conversation.folderTag = c.folderTag
        conversation.createdAt = c.createdAt
        conversation.updatedAt = c.updatedAt
        return conversation
    }
}
