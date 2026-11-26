import SwiftData
import SwiftUI

struct FriendMemorySheet: View {
    let subjects: [FriendMemorySubject]
    let conversation: Conversation?
    var store: FriendMemoryStore = .shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query private var books: [BookVolume]

    @State private var selectedFriendKey: String
    @State private var editingSummaryText: String = ""
    @State private var showingSummaryEditor = false
    @State private var addingEntryText: String = ""
    @State private var showingAddEntry = false
    @State private var editingEntry: FriendMemoryEntry?
    @State private var editingEntryText: String = ""
    @State private var confirmClearAll = false
    @State private var statusBanner: String?
    @State private var errorMessage: String?
    @State private var consent = AIConsentGate()

    private let engine = ChatEngine.shared

    init(
        subjects: [FriendMemorySubject],
        initialSubject: FriendMemorySubject? = nil,
        conversation: Conversation? = nil,
        store: FriendMemoryStore = .shared
    ) {
        self.subjects = subjects
        self.conversation = conversation
        self.store = store
        let firstKey = initialSubject?.friendKey ?? subjects.first?.friendKey ?? ""
        _selectedFriendKey = State(initialValue: firstKey)
    }

    private var activeSubject: FriendMemorySubject? {
        subjects.first(where: { $0.friendKey == selectedFriendKey }) ?? subjects.first
    }

    private var theme: DS.AccentTheme {
        AppPreferences.shared.accentTheme
    }

    var body: some View {
        NavigationStack {
            Group {
                if let subject = activeSubject {
                    contentList(for: subject)
                } else {
                    ContentUnavailableView(
                        "暂无可管理的好友记忆",
                        systemImage: "brain.head.profile",
                        description: Text("请先从「好友」页选择一位人物档案或书中好友。")
                    )
                }
            }
            .navigationTitle("好友持续记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .tint(.primary)
                }
            }
            .aiConsentSheet(consent)
            .alert(
                "好友记忆提示",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(verbatim: errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func contentList(for subject: FriendMemorySubject) -> some View {
        let record = store.record(for: subject)
        let visibleSummary = store.visibleSummary(for: subject)
        let visibleEntries = store.visibleEntries(for: subject, includeDisabled: true)
        let hiddenFutureCount = store.hiddenFutureEntryCount(for: subject)
        let isExtracting = engine.extractingFriendKeys.contains(subject.friendKey)

        List {
            if subjects.count > 1 {
                Section("选择群内好友") {
                    Picker("好友角色", selection: $selectedFriendKey) {
                        ForEach(subjects) { item in
                            Text(verbatim: "\(item.avatarEmoji) \(item.characterName)")
                                .tag(item.friendKey)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section {
                HStack(spacing: DS.Spacing.md) {
                    Text(verbatim: subject.avatarEmoji)
                        .font(.system(size: 28))
                        .frame(width: 46, height: 46)
                        .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: subject.characterName)
                            .font(.headline)
                        Text(subtitleText(for: subject))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isExtracting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)

                Toggle(
                    "启用好友持续记忆",
                    isOn: Binding(
                        get: { record.isEnabled },
                        set: { store.setEnabled($0, for: subject) }
                    )
                )
                .accessibilityIdentifier("friendMemory.enableToggle")

                Toggle(
                    "对话中自动提炼更新",
                    isOn: Binding(
                        get: { record.autoExtractEnabled },
                        set: { store.setAutoExtractEnabled($0, for: subject) }
                    )
                )
                .disabled(!record.isEnabled)
                .accessibilityIdentifier("friendMemory.autoExtractToggle")

                if let conversation {
                    Button {
                        triggerManualExtraction(for: subject, in: conversation)
                    } label: {
                        HStack(spacing: 8) {
                            if isExtracting {
                                ProgressView().controlSize(.small)
                                Text("正在从对话提炼记忆…")
                            } else {
                                Label("立即从当前对话提炼记忆", systemImage: "sparkles")
                            }
                        }
                    }
                    .disabled(isExtracting || !canExtractFromConversation(subject: subject, in: conversation))
                    .accessibilityIdentifier("friendMemory.extractNow")
                }

                if let statusBanner {
                    Label(statusBanner, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开启后，这位好友会在私聊与圆桌群聊中持续记住你们的共同话题、近况与约定（群聊中仅注入给该好友自身模型，不泄露给其他成员）。")
                    if hiddenFutureCount > 0 {
                        Text("防剧透保护：另有 \(hiddenFutureCount) 条在后续章节产生的记忆已按当前阅读进度自动隐藏。")
                    }
                }
            }

            Section {
                if let visibleSummary, !visibleSummary.isEmpty {
                    Text(verbatim: visibleSummary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 2)
                } else {
                    Text("暂无关系近况小结。随着对话深入会自动凝练，也可以手动编写。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    editingSummaryText = visibleSummary ?? ""
                    showingSummaryEditor = true
                } label: {
                    Label("编辑关系小结", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("friendMemory.editSummary")
            } header: {
                Text("关系与近况小结")
            }

            Section {
                Button {
                    addingEntryText = ""
                    showingAddEntry = true
                } label: {
                    Label("手动添加共同记忆", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("friendMemory.addEntry")

                if visibleEntries.isEmpty {
                    Text("还没有记录具体记忆条目。聊过几轮后系统会自动沉淀，也可点击上方手动补充。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(visibleEntries) { entry in
                        entryRow(entry, for: subject)
                    }
                }
            } header: {
                Text("共同记忆条目（\(visibleEntries.count)/\(FriendMemoryStore.maximumEntriesPerFriend)）")
            } footer: {
                Text("单个好友最多保留 \(FriendMemoryStore.maximumEntriesPerFriend) 条记忆，超出时后台提炼会自动合并去重并淘汰陈旧琐碎细节。左滑可删除单条记忆。")
            }

            if record.hasAnyStoredContent {
                Section {
                    Button(role: .destructive) {
                        confirmClearAll = true
                    } label: {
                        Label("清空这位好友的全部记忆", systemImage: "trash")
                    }
                    .accessibilityIdentifier("friendMemory.clearAll")
                }
            }
        }
        .sheet(isPresented: $showingSummaryEditor) {
            summaryEditorSheet(for: subject)
        }
        .sheet(isPresented: $showingAddEntry) {
            addEntrySheet(for: subject)
        }
        .sheet(item: $editingEntry) { entry in
            editEntrySheet(entry, for: subject)
        }
        .confirmationDialog(
            "清空这位好友的全部记忆？",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("清空全部记忆", role: .destructive) {
                store.clearMemories(for: subject)
                statusBanner = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空与「\(subject.characterName)」的关系小结及所有记忆条目（已有聊天消息不会删除）。")
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: FriendMemoryEntry, for subject: FriendMemorySubject) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Button {
                store.updateEntry(id: entry.id, isEnabled: !entry.isEnabled, for: subject)
            } label: {
                Image(systemName: entry.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(entry.isEnabled ? theme.readableText : .secondary)
                    .font(.body)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isEnabled ? String(localized: "停用此条记忆") : String(localized: "启用此条记忆"))

            Button {
                editingEntryText = entry.content
                editingEntry = entry
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.content)
                        .font(.subheadline)
                        .foregroundStyle(entry.isEnabled ? .primary : .secondary)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        if subject.kind == .bookFriend, let chapter = entry.throughChapter {
                            Text(chapterBadgeText(chapter, bookID: subject.bookID))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: entry.updatedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.deleteEntry(id: entry.id, for: subject)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func summaryEditorSheet(for subject: FriendMemorySubject) -> some View {
        NavigationStack {
            Form {
                Section("关系与近况小结") {
                    TextField("例如：常一起讨论产品设计与读书心得，近期正在筹备新项目…", text: $editingSummaryText, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("friendMemory.summaryInput")
                }
                if !editingSummaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Button("清空小结", role: .destructive) {
                            editingSummaryText = ""
                        }
                    }
                }
            }
            .navigationTitle("编辑关系小结")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingSummaryEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateRelationshipSummary(editingSummaryText, for: subject)
                        showingSummaryEditor = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addEntrySheet(for subject: FriendMemorySubject) -> some View {
        NavigationStack {
            Form {
                Section("新增共同记忆") {
                    TextField("记录希望这位好友一直记住的共同经历、你的近况或约定…", text: $addingEntryText, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("friendMemory.newEntryInput")
                }
            }
            .navigationTitle("添加共同记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showingAddEntry = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        _ = store.addEntry(addingEntryText, for: subject)
                        showingAddEntry = false
                    }
                    .disabled(addingEntryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("friendMemory.confirmAddEntry")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func editEntrySheet(_ entry: FriendMemoryEntry, for subject: FriendMemorySubject) -> some View {
        NavigationStack {
            Form {
                Section("编辑共同记忆") {
                    TextField("记忆内容", text: $editingEntryText, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle("编辑记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingEntry = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.updateEntry(id: entry.id, content: editingEntryText, for: subject)
                        editingEntry = nil
                    }
                    .disabled(editingEntryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func subtitleText(for subject: FriendMemorySubject) -> String {
        switch subject.kind {
        case .persona:
            return String(localized: "人物档案 · 跨私聊与圆桌群聊共享")
        case .bookFriend:
            let bookTitle = subject.bookTitle ?? ""
            let scopeLabel: String
            if let ch = subject.currentThroughChapter {
                scopeLabel = chapterBadgeText(ch, bookID: subject.bookID)
            } else {
                scopeLabel = String(localized: "全书范围")
            }
            if bookTitle.isEmpty {
                return scopeLabel
            }
            return "《\(bookTitle)》 · \(scopeLabel)"
        }
    }

    private func chapterBadgeText(_ chapterIndex: Int, bookID: UUID?) -> String {
        if let bookID,
           let book = books.first(where: { $0.id == bookID }),
           book.chapterTitles.indices.contains(chapterIndex) {
            let title = book.chapterTitles[chapterIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return String(localized: "读至第 \(chapterIndex + 1) 节")
    }

    private func canExtractFromConversation(subject: FriendMemorySubject, in conversation: Conversation) -> Bool {
        let relevant = engine.relevantMessagesForFriendMemory(subject: subject, in: conversation)
        return relevant.contains(where: { $0.role == .user }) && relevant.contains(where: { $0.role == .assistant })
    }

    private func triggerManualExtraction(for subject: FriendMemorySubject, in conversation: Conversation) {
        statusBanner = nil
        guard let target = engine.resolveFriendTarget(for: subject, in: conversation, providers: providers),
              let provider = providers.first(where: { $0.id == target.providerID && $0.isEnabled && !$0.isDeleted }) else {
            errorMessage = LLMError.unavailableModel.localizedDescription
            return
        }
        let runExtraction: () -> Void = {
            Task { @MainActor in
                do {
                    let updated = try await engine.extractFriendMemoryNow(
                        for: subject,
                        in: conversation,
                        providers: providers,
                        context: modelContext,
                        store: store
                    )
                    statusBanner = updated
                        ? String(localized: "已根据当前对话更新好友记忆")
                        : String(localized: "已检查当前对话，暂无需要新增的长期记忆")
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        if NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL) {
            runExtraction()
        } else {
            let recipient = AppCompliance.recipient(
                provider: provider.name,
                model: target.modelDisplayName,
                baseURL: provider.baseURL
            )
            consent.perform(
                recipients: [recipient],
                isCurrent: { [weak conversation] in
                    guard let conversation, !conversation.isDeleted else { return false }
                    return engine.resolveFriendTarget(for: subject, in: conversation, providers: providers)?.id == target.id
                },
                send: runExtraction
            )
        }
    }
}
