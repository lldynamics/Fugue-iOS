import SwiftData
import SwiftUI

enum BackupDataGroup: String, CaseIterable, Identifiable {
    case conversations, books, people, memories, providers, requests, english, credentials, drafts
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .conversations: "对话与消息"
        case .books: "书架、进度与摘录"
        case .people: "助手与人物档案"
        case .memories: "个人长期记忆"
        case .providers: "服务商与模型"
        case .requests: "用量记录"
        case .english: "英语学习资料"
        case .credentials: "连接凭据"
        case .drafts: "未发送草稿"
        }
    }
}

@MainActor
struct BackupRecoveryPlan: Identifiable {
    enum Content {
        case plain(BackupService.DecodedBackup)
        case encrypted(EncryptedBackupService.FullPayload)
    }

    let id = UUID()
    let content: Content
    var counts: [BackupDataGroup: Int] = [:]
    var existingConversations = 0
    var existingProviders = 0
    var credentialConflicts: [String] = []
    var skippedCredentialCount = 0
    var annotationCount = 0
    var readingPositionCount = 0
    var memoryCollectionCount = 0
    var conflictingDrafts = 0
    var previouslyRecoveredDrafts = 0
    var unreadableDrafts = 0

    init(_ content: Content, in context: ModelContext, draftStore: ChatDraftStore? = nil) throws {
        self.content = content
        let archive: BackupArchive
        let localProviders = try context.fetch(FetchDescriptor<ProviderConfig>())
        switch content {
        case .plain(.legacy(let chats)):
            counts[.conversations] = chats.count
            return
        case .plain(.full(let full)):
            archive = full
        case .encrypted(let full):
            archive = full.archive
            let chatIDs = Set(archive.conversations.map(\.id))
            let drafts = (full.drafts ?? [:]).filter { chatIDs.contains($0.key) && !$0.value.isEmpty }
            counts[.drafts] = drafts.count
            let store = draftStore ?? (context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) ? nil : ChatDraftStore.shared)
            if let store {
                for (id, draft) in drafts {
                    do {
                        switch try EncryptedBackupService.draftRecoveryTarget(for: draft, id: id, store: store, in: context) {
                        case .separate: conflictingDrafts += 1
                        case .previouslyRecovered: previouslyRecoveredDrafts += 1
                        case .original, .unchanged: break
                        }
                    } catch { unreadableDrafts += 1 }
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: localProviders.map { ($0.id, $0) })
            let archived = Dictionary(archive.providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var credentialCount = full.tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
            for bundle in full.providerSecrets {
                let id = bundle.providerID
                let match = EncryptedBackupService.credentialMatch(bundle, source: archived[id], local: byID[id])
                credentialCount += match.totalCount
                if match.skippedCount > 0 {
                    skippedCredentialCount += match.skippedCount
                    credentialConflicts.append(byID[id]?.name ?? archived[id]?.name ?? id.uuidString)
                }
            }
            counts[.credentials] = credentialCount
        }
        counts[.conversations] = archive.conversations.count
        counts[.books] = archive.books?.count ?? 0
        annotationCount = archive.annotations?.count ?? 0
        readingPositionCount = archive.shelfPositions?.count ?? 0
        counts[.people] = archive.presets.count + (archive.personaProfiles?.count ?? 0)
        counts[.memories] = archive.memories?.count ?? 0
        memoryCollectionCount = archive.memoryCollections?.count ?? 0
        counts[.providers] = archive.providers.count
        counts[.requests] = archive.requests?.count ?? 0
        counts[.english] = archive.englishCoach == nil ? 0 : 1
        let existingIDs = Set(try context.fetch(FetchDescriptor<Conversation>()).map(\.id))
        existingConversations = archive.conversations.filter { existingIDs.contains($0.id) }.count
        let savedProviderIDs = Set(localProviders.map(\.id))
        existingProviders = archive.providers.filter { savedProviderIDs.contains($0.id) }.count
    }

    var groups: [BackupDataGroup] {
        BackupDataGroup.allCases.filter {
            (counts[$0] ?? 0) > 0 || ($0 == .books && (annotationCount > 0 || readingPositionCount > 0)) ||
            ($0 == .memories && memoryCollectionCount > 0)
        }
    }

    func apply(_ selected: Set<BackupDataGroup>, in context: ModelContext, knowledgeStore: PresetKnowledgeStore = .shared) throws -> ImportSummary {
        func filtered(_ archive: BackupArchive) -> BackupArchive {
            var copy = archive
            if !selected.contains(.conversations) { copy.conversations = [] }
            if !selected.contains(.books) { copy.books = nil; copy.annotations = nil; copy.shelfPositions = nil }
            if !selected.contains(.people) { copy.presets = []; copy.personaProfiles = nil }
            if !selected.contains(.memories) { copy.memories = nil; copy.memoryCollections = nil }
            if !selected.contains(.providers) { copy.providers = [] }
            if !selected.contains(.requests) { copy.requests = nil }
            if !selected.contains(.people) && !selected.contains(.books) && !selected.contains(.memories) {
                copy.friendMemories = nil
            }
            if !selected.contains(.english) { copy.englishCoach = nil }
            return copy
        }
        switch content {
        case .plain(.legacy(let chats)):
            return try BackupService.apply(.legacy(selected.contains(.conversations) ? chats : []), to: context, knowledgeStore: knowledgeStore)
        case .plain(.full(let archive)):
            return try BackupService.apply(.full(filtered(archive)), to: context, knowledgeStore: knowledgeStore)
        case .encrypted(var payload):
            payload.archive = filtered(payload.archive)
            if !selected.contains(.credentials) {
                payload.providerSecrets = []
                payload.tavilyAPIKey = ""
            } else if !selected.contains(.providers) {
                payload.providerSecrets = []
            }
            if !selected.contains(.drafts) || !selected.contains(.conversations) { payload.drafts = nil }
            return try EncryptedBackupService.applyDecryptedPayload(payload, to: context, knowledgeStore: knowledgeStore)
        }
    }
}

struct BackupRecoverySheet: View {
    let plan: BackupRecoveryPlan
    let onRestore: (Set<BackupDataGroup>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<BackupDataGroup>

    init(plan: BackupRecoveryPlan, onRestore: @escaping (Set<BackupDataGroup>) -> Void) {
        self.plan = plan
        self.onRestore = onRestore
        _selected = State(initialValue: Set(plan.groups))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(plan.groups) { group in
                        Toggle(isOn: Binding(get: { selected.contains(group) }, set: { enable in
                            if enable {
                                selected.insert(group)
                                if group == .drafts { selected.insert(.conversations) }
                                if group == .credentials, plan.groups.contains(.providers) { selected.insert(.providers) }
                            } else {
                                selected.remove(group)
                                if group == .conversations { selected.remove(.drafts) }
                                if group == .providers { selected.remove(.credentials) }
                            }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(group.title)
                                    if group != .books && (group != .memories || plan.memoryCollectionCount == 0) {
                                        Spacer()
                                        Text("\(plan.counts[group] ?? 0)").foregroundStyle(.secondary)
                                    }
                                }
                                if group == .books {
                                    Text("书籍 \(plan.counts[.books] ?? 0) 本 · 摘录 \(plan.annotationCount) 条 · 阅读位置 \(plan.readingPositionCount) 处")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if group == .memories && plan.memoryCollectionCount > 0 {
                                    Text("记忆 \(plan.counts[.memories] ?? 0) 条 · 集合 \(plan.memoryCollectionCount) 个")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if group == .drafts {
                                    if plan.conflictingDrafts > 0 {
                                        Text("与本机不同，将单独找回 \(plan.conflictingDrafts) 份").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if plan.previouslyRecoveredDrafts > 0 {
                                        Text("已有找回版本 \(plan.previouslyRecoveredDrafts) 份，将跳过").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if plan.unreadableDrafts > 0 {
                                        Text("暂时无法读取 \(plan.unreadableDrafts) 份本机草稿").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("选择要恢复的资料")
                } footer: {
                    Text("恢复会补回缺失项目。已有对话会合并缺少的消息和分支，已有草稿会保留。")
                }
                if plan.existingConversations > 0 || plan.existingProviders > 0 || (selected.contains(.credentials) && plan.skippedCredentialCount > 0) {
                    Section("与本机的重合项目") {
                        if plan.existingConversations > 0 { Text("可合并的已有对话：\(plan.existingConversations)") }
                        if plan.existingProviders > 0 { Text("将保留本机配置的服务商：\(plan.existingProviders)") }
                        if selected.contains(.credentials), plan.skippedCredentialCount > 0 {
                            Text("连接或私密请求头不匹配，将跳过 \(plan.skippedCredentialCount) 个凭据：\(plan.credentialConflicts.joined(separator: "、"))")
                        }
                    }
                }
                if plan.groups.isEmpty { Text("备份中没有需要导入的内容。") }
            }
            .navigationTitle("恢复预览")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认恢复") { onRestore(selected) }.disabled(selected.isEmpty)
                }
            }
        }
    }
}
