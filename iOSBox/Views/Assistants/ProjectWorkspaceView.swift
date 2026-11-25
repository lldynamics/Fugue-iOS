import SwiftUI
import SwiftData

struct ProjectWorkspaceListSection: View {
    let providers: [ProviderConfig]
    let books: [BookVolume]
    let conversations: [Conversation]
    @Binding var editingWorkspace: ProjectWorkspace?
    @Binding var showCreateWorkspace: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var store = ProjectWorkspaceStore.shared
    @State private var preferences = AppPreferences.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    var body: some View {
        Section {
            if store.workspaces.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label("创建你的第一个项目空间", systemImage: "folder.badge.gearshape")
                        .font(.headline)
                    Text("将专属提示词、默认模型、参考文档与定向记忆打包在一个项目中，一键开启上下文一致的专题对话。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("新建项目空间") { showCreateWorkspace = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.vertical, DS.Spacing.sm)
            } else {
                ForEach(store.workspaces) { workspace in
                    let linkedCount = conversations.filter {
                        $0.folderTag?.caseInsensitiveCompare(workspace.effectiveFolderTag) == .orderedSame
                    }.count
                    let docCount = workspace.knowledgeVolumeIDs.filter { id in
                        books.contains { $0.id == id }
                    }.count

                    HStack(spacing: DS.Spacing.md) {
                        NavigationLink {
                            ProjectWorkspaceDetailView(workspace: workspace)
                        } label: {
                            HStack(spacing: DS.Spacing.md) {
                                AssistantEmojiIcon(emoji: workspace.iconEmoji, font: .system(size: 24))
                                    .frame(width: 44, height: 44)
                                    .background(Color(hex: workspace.accentHex).opacity(0.14), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspace.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !workspace.summary.isEmpty {
                                        Text(workspace.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 8) {
                                        Label("\(linkedCount) 对话", systemImage: "bubble.left.and.bubble.right")
                                        if docCount > 0 {
                                            Label("\(docCount) 文档", systemImage: "book.closed")
                                        }
                                        if !workspace.memoryTags.isEmpty {
                                            Label(workspace.memoryTags.prefix(2).joined(separator: "·"), systemImage: "tag")
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            let chat = store.createConversation(in: workspace, providers: providers, context: modelContext)
                            SystemEntryRouter.shared.conversationID = chat.id
                        } label: {
                            Text("新对话")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(theme.readableText)
                                .background(theme.softFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(id: workspace.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            editingWorkspace = workspace
                        } label: {
                            Label("编辑", systemImage: "slider.horizontal.3")
                        }
                        .tint(.blue)
                    }
                }
            }
        } header: {
            Text("项目空间（\(store.workspaces.count)）")
        } footer: {
            Text("项目内的对话会自动关联同名的文件夹标签，并仅注入全局记忆与匹配项目标签的长期记忆。")
        }
    }
}

struct ProjectWorkspaceDetailView: View {
    let workspace: ProjectWorkspace

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var store = ProjectWorkspaceStore.shared
    @State private var showEditor = false

    private var current: ProjectWorkspace {
        store.workspaces.first { $0.id == workspace.id } ?? workspace
    }

    private var linkedConversations: [Conversation] {
        conversations.filter {
            $0.folderTag?.caseInsensitiveCompare(current.effectiveFolderTag) == .orderedSame
        }
    }

    private var boundBooks: [BookVolume] {
        let set = Set(current.knowledgeVolumeIDs)
        return books.filter { set.contains($0.id) }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AssistantEmojiIcon(emoji: current.iconEmoji, font: .system(size: 30))
                        .frame(width: 52, height: 52)
                        .background(Color(hex: current.accentHex).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(current.name)
                            .font(.headline)
                        if !current.summary.isEmpty {
                            Text(current.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("归档标签：\(current.effectiveFolderTag)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    let chat = store.createConversation(in: current, providers: providers, context: modelContext)
                    SystemEntryRouter.shared.conversationID = chat.id
                } label: {
                    Label("在此项目中新建对话", systemImage: "plus.bubble.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }

            if !current.systemPrompt.isEmpty {
                Section("项目指令 (System Prompt)") {
                    Text(current.systemPrompt)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
            }

            Section("项目上下文配置") {
                if let targetID = current.defaultTargetID,
                   let resolved = ProviderConfig.readyTargets(in: providers).first(where: { $0.id == targetID }) {
                    LabeledContent("默认模型", value: "\(resolved.providerName) · \(resolved.modelDisplayName)")
                } else {
                    LabeledContent("默认模型", value: String(localized: "跟随全局默认"))
                }

                LabeledContent("参考文档", value: boundBooks.isEmpty ? String(localized: "未绑定") : String(localized: "\(boundBooks.count) 本"))
                ForEach(boundBooks) { book in
                    Label(book.title, systemImage: "book.closed")
                        .font(.footnote)
                }

                LabeledContent(
                    "记忆分区标签",
                    value: current.memoryTags.isEmpty
                        ? String(localized: "全部全局记忆")
                        : current.memoryTags.joined(separator: "、")
                )
            }

            Section("项目对话（\(linkedConversations.count)）") {
                if linkedConversations.isEmpty {
                    Text("暂无关联对话，点击上方按钮即可开始。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(linkedConversations) { chat in
                        Button {
                            SystemEntryRouter.shared.conversationID = chat.id
                        } label: {
                            HStack {
                                Text(chat.assistantEmoji)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(chat.updatedAt, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            ProjectWorkspaceEditorSheet(existing: current)
        }
    }
}

struct ProjectWorkspaceEditorSheet: View {
    let existing: ProjectWorkspace?

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @State private var store = ProjectWorkspaceStore.shared

    @State private var name: String
    @State private var emoji: String
    @State private var summary: String
    @State private var systemPrompt: String
    @State private var folderTag: String
    @State private var memoryTagsText: String
    @State private var selectedTargetID: String
    @State private var selectedBookIDs: Set<UUID>
    @State private var enableThinking: Bool
    @State private var enableAgentTools: Bool

    init(existing: ProjectWorkspace?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _emoji = State(initialValue: existing?.iconEmoji ?? "🗂️")
        _summary = State(initialValue: existing?.summary ?? "")
        _systemPrompt = State(initialValue: existing?.systemPrompt ?? "")
        _folderTag = State(initialValue: existing?.folderTag ?? "")
        _memoryTagsText = State(initialValue: existing?.memoryTags.joined(separator: ", ") ?? "")
        _selectedTargetID = State(initialValue: existing?.defaultTargetID ?? "")
        _selectedBookIDs = State(initialValue: Set(existing?.knowledgeVolumeIDs ?? []))
        _enableThinking = State(initialValue: existing?.enableThinking ?? true)
        _enableAgentTools = State(initialValue: existing?.enableAgentTools ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    HStack {
                        TextField("图标", text: $emoji)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                        TextField("项目名称（如：论文润色、iOS 架构）", text: $name)
                    }
                    TextField("一句话简介（可选）", text: $summary)
                    TextField("对话归档标签（留空默认同项目名）", text: $folderTag)
                }

                Section("项目指令 (System Prompt)") {
                    TextField("输入此项目内所有对话共用的系统指令…", text: $systemPrompt, axis: .vertical)
                        .lineLimit(4...10)
                }

                Section("默认模型与能力") {
                    let ready = ProviderConfig.readyTargets(in: providers)
                    Picker("默认模型", selection: $selectedTargetID) {
                        Text("跟随全局默认").tag("")
                        ForEach(ready) { target in
                            Text("\(target.providerName) · \(target.modelDisplayName)").tag(target.id)
                        }
                    }
                    Toggle("默认开启深度思考", isOn: $enableThinking)
                    Toggle("默认开启 Agent 工具调用", isOn: $enableAgentTools)
                }

                Section {
                    TextField("记忆标签（逗号分隔，如：工程, 写作）", text: $memoryTagsText)
                } header: {
                    Text("记忆分区过滤")
                } footer: {
                    Text("填写标签后，该项目对话仅注入「未打标签的全局记忆」与「匹配标签的记忆」，避免不同项目间串味。")
                }

                if !books.isEmpty {
                    Section("绑定知识库文档") {
                        ForEach(books) { book in
                            let bound = selectedBookIDs.contains(book.id)
                            Button {
                                if bound { selectedBookIDs.remove(book.id) }
                                else { selectedBookIDs.insert(book.id) }
                            } label: {
                                HStack {
                                    Image(systemName: bound ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(bound ? Color.accentColor : Color.secondary)
                                    Text(book.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "新建项目空间" : "编辑项目空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let ws = ProjectWorkspace(
                            id: existing?.id ?? UUID(),
                            name: name,
                            iconEmoji: emoji,
                            accentHex: existing?.accentHex ?? "#4F46E5",
                            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                            defaultTargetID: selectedTargetID.isEmpty ? nil : selectedTargetID,
                            knowledgeVolumeIDs: Array(selectedBookIDs),
                            memoryTags: ProjectWorkspace.normalizedTags(from: memoryTagsText),
                            folderTag: folderTag.trimmingCharacters(in: .whitespacesAndNewlines),
                            enableThinking: enableThinking,
                            enableAgentTools: enableAgentTools,
                            createdAt: existing?.createdAt ?? Date(),
                            updatedAt: Date()
                        )
                        store.upsert(ws)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
