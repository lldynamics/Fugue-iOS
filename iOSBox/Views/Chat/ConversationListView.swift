import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Binding var pendingConversationToOpen: Conversation?
    @Binding var pendingMessageRoute: ConversationMessageRoute?

    init(
        pendingConversationToOpen: Binding<Conversation?>,
        pendingMessageRoute: Binding<ConversationMessageRoute?> = .constant(nil)
    ) {
        self._pendingConversationToOpen = pendingConversationToOpen
        self._pendingMessageRoute = pendingMessageRoute
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]

    @State private var navigationPath = NavigationPath()
    @State private var splitSelection: Conversation?
    @State private var splitSearchRoute: ConversationMessageRoute?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var historySearch = HistorySearchSession()
    @State private var searchRevision = 0

    private struct SearchRefresh: Equatable {
        let query: HistorySearchQuery
        let revision: Int
    }

    private var searchQuery: HistorySearchQuery {
        HistorySearchQuery(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                           tag: selectedFilterTag, bookmarkedChatsOnly: showOnlyBookmarked)
    }
    @State private var searchText: String = ""
    @State private var selectedFilterTag: String? = nil
    @State private var showOnlyBookmarked = false
    @State private var tagEditingConversation: Conversation?
    @State private var tagDraft: String = ""
    @State private var deletionError: String?
    @State private var showReader = false
    @State private var showModelSetup = false
    @State private var showGroupSetup = false
    @State private var showBookFriends = false
    @State private var readyModelCount = 0
    @State private var bookmarkedConversationIDs: Set<UUID> = []
    private var hasReadyModel: Bool { readyModelCount > 0 }

    private var availableTags: [String] {
        let tags = Set(conversations.compactMap { conv -> String? in
            let t = conv.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        })
        return tags.sorted()
    }

    private var filteredConversations: [Conversation] {
        return conversations.filter { conv in
            if showOnlyBookmarked {
                if !bookmarkedConversationIDs.contains(conv.id) { return false }
            }
            if let selectedFilterTag {
                if conv.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines) != selectedFilterTag {
                    return false
                }
            }
            return true
        }
    }

    private func refreshBookmarkedIndex() {
        let desc = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.assistanceMetadataData != nil })
        guard let msgs = try? modelContext.fetch(desc) else { return }
        var ids = Set<UUID>()
        for msg in msgs where msg.assistanceMetadata.isBookmarked {
            if let convID = msg.conversation?.id {
                ids.insert(convID)
            }
        }
        bookmarkedConversationIDs = ids
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    conversationSidebarContent(useSplitSelection: true)
                        .navigationTitle("夜奔")
                        .toolbar { listToolbarItems }
                } detail: {
                    NavigationStack {
                        if let route = splitSearchRoute {
                            ConversationSearchDestination(route: route) { next in
                                splitSearchRoute = nil
                                splitSelection = next
                            }
                            .id("\(route.conversation.id.uuidString)-\(route.messageID.uuidString)")
                        } else if let conv = splitSelection, !conv.isDeleted, conv.modelContext != nil {
                            ChatDetailView(
                                conversation: conv,
                                onOpenConversation: { next in
                                    splitSearchRoute = nil
                                    splitSelection = next
                                }
                            )
                            .id(conv.id)
                        } else {
                            emptyConversationsPlaceholder
                        }
                    }
                }
            } else {
                NavigationStack(path: $navigationPath) {
                    Group {
                        if conversations.isEmpty {
                            emptyConversationsPlaceholder
                        } else {
                            conversationSidebarContent(useSplitSelection: false)
                        }
                    }
                    .navigationTitle("夜奔")
                    .toolbar { listToolbarItems }
                    .navigationDestination(for: Conversation.self) { conv in
                        ChatDetailView(
                            conversation: conv,
                            onOpenConversation: { next in
                                navigationPath.append(next)
                            }
                        )
                    }
                    .navigationDestination(for: ConversationMessageRoute.self) { route in
                        ConversationSearchDestination(route: route) { next in navigationPath.append(next) }
                    }
                }
            }
        }
        .onAppear {
            updateReadiness()
            refreshBookmarkedIndex()
            if horizontalSizeClass == .regular && splitSelection == nil {
                splitSelection = conversations.first
            }
        }
        .onChange(of: SystemIntegration.fingerprint(providers)) { updateReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: .init("IOSBoxCredentialsChanged"))) { _ in updateReadiness() }
        .sheet(isPresented: $showModelSetup) {
            FirstModelSetupSheet { target in
                updateReadiness()
                createNewConversation(arenaMode: false, verified: target)
            }
        }
        .sheet(isPresented: $showReader) {
            ReaderSheet { id in SystemEntryRouter.shared.conversationID = id }
        }
        .sheet(isPresented: $showGroupSetup) {
            GroupCreationFlow(providers: providers, presets: presets) { created in
                openConversation(created)
            }
        }
        .sheet(isPresented: $showBookFriends) {
            BookFriendSetupSheet { openConversation($0) }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = SystemIntegration.shared.error {
                Text(error).font(.caption).foregroundStyle(.orange).padding(8)
            }
        }
        .alert("删除失败", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("确定", role: .cancel) { }
        } message: { Text(deletionError ?? "") }
        .alert("设置分组标签", isPresented: Binding(
            get: { tagEditingConversation != nil },
            set: { if !$0 { tagEditingConversation = nil } }
        )) {
            TextField("标签名称（留空清除）", text: $tagDraft)
            Button("取消", role: .cancel) { tagEditingConversation = nil }
            Button("保存") {
                if let conv = tagEditingConversation {
                    let cleaned = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    conv.folderTag = cleaned.isEmpty ? nil : cleaned
                    try? modelContext.save()
                }
                tagEditingConversation = nil
            }
        }
        .onChange(of: pendingConversationToOpen) { _, newValue in
            if let conv = newValue {
                openConversation(conv)
                pendingConversationToOpen = nil
            }
        }
        .onChange(of: pendingMessageRoute) { _, route in
            if let route {
                if horizontalSizeClass == .regular {
                    splitSelection = route.conversation
                    splitSearchRoute = route
                } else {
                    navigationPath = NavigationPath()
                    navigationPath.append(route)
                }
                pendingMessageRoute = nil
            }
        }
    }

    @ViewBuilder
    private func conversationSidebarContent(useSplitSelection: Bool) -> some View {
        let tags = availableTags
        let filtered = filteredConversations
        let pinned = filtered.filter(\.isPinned)
        let regular = filtered.filter { !$0.isPinned }

        List {
            if !hasReadyModel {
                Button { showModelSetup = true } label: {
                    Label("连接第一个模型", systemImage: "key")
                }
            }
            if !searchQuery.text.isEmpty || !tags.isEmpty || showOnlyBookmarked || !bookmarkedConversationIDs.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterChip(title: String(localized: "全部"), selected: selectedFilterTag == nil && !showOnlyBookmarked) {
                                selectedFilterTag = nil
                                showOnlyBookmarked = false
                            }
                            filterChip(title: String(localized: "含收藏"), selected: showOnlyBookmarked) {
                                showOnlyBookmarked.toggle()
                            }
                            ForEach(tags, id: \.self) { tag in
                                filterChip(title: tag, selected: selectedFilterTag == tag) {
                                    selectedFilterTag = (selectedFilterTag == tag) ? nil : tag
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowBackground(Color.clear)
            }

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !pinned.isEmpty {
                    Section("置顶对话") {
                        ForEach(pinned) { conv in conversationRow(conv, useSplitSelection: useSplitSelection) }
                    }
                }
                Section(pinned.isEmpty ? String(localized: "全部对话") : String(localized: "最近对话")) {
                    ForEach(regular) { conv in conversationRow(conv, useSplitSelection: useSplitSelection) }
                }
            } else if useSplitSelection {
                ConversationSearchResults(
                    conversations: conversations,
                    query: searchQuery, session: historySearch, retry: { searchRevision += 1 },
                    onSelectConversation: { conv in
                        splitSearchRoute = nil
                        splitSelection = conv
                    },
                    onSelectRoute: { route in
                        splitSearchRoute = route
                    }
                )
            } else {
                ConversationSearchResults(conversations: conversations, query: searchQuery, session: historySearch, retry: { searchRevision += 1 })
            }
        }
        .task(id: SearchRefresh(query: searchQuery, revision: searchRevision)) {
            await historySearch.update(searchQuery, in: modelContext.container)
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: modelContext)) { _ in
            refreshBookmarkedIndex()
            if !searchQuery.text.isEmpty { searchRevision += 1 }
        }
        .searchable(text: $searchText, prompt: "搜索标题、标签或聊天内容")
    }

    @ToolbarContentBuilder
    private var listToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showReader = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                .accessibilityLabel("网页精读")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { createNewConversation(arenaMode: false) } label: { Label("普通对话", systemImage: "bubble.left") }
                    .keyboardShortcut("n", modifiers: .command)
                Button { showGroupSetup = true } label: { Label("圆桌群聊", systemImage: "person.3.fill") }
                Button { showBookFriends = true } label: { Label("书中好友", systemImage: "book.pages") }
                Button { createNewConversation(arenaMode: true) } label: { Label("多模型对比", systemImage: "square.split.2x1") }
                    .disabled(readyModelCount < 2)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("新建")
                }
            }
            .accessibilityLabel("新建")
        }
    }

    private func openConversation(_ conv: Conversation) {
        if horizontalSizeClass == .regular {
            splitSearchRoute = nil
            splitSelection = conv
        } else {
            navigationPath = NavigationPath([conv])
        }
    }

    private func filterChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected ? Color.accentColor : Color(.secondarySystemBackground),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func conversationRow(_ conv: Conversation, useSplitSelection: Bool = false) -> some View {
        let isSelected = useSplitSelection && splitSelection?.id == conv.id && splitSearchRoute == nil
        let rowContent = HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 42, height: 42)
                Text(conv.assistantEmoji)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conv.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if conv.isGroupMode {
                        Text("群聊")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.indigo)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.indigo.opacity(0.14), in: Capsule())
                    } else if conv.isArenaMode {
                        Text("对比")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }

                    if let tag = conv.folderTag, !tag.isEmpty {
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }

                    Spacer()

                    Text(conv.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    if let lastMsg = latestPreviewMessage(in: conv) {
                        let basePreview = lastMsg.content.isEmpty
                            ? (lastMsg.isStreaming ? String(localized: "正在生成…") : String(localized: "[附件消息]"))
                            : lastMsg.content
                        let previewText: String = {
                            if lastMsg.assistanceMetadataData != nil,
                               let speaker = lastMsg.assistanceMetadata.groupMemberName, !speaker.isEmpty {
                                return "\(speaker)：\(basePreview)"
                            }
                            return basePreview
                        }()
                        Text(previewText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if conv.isGroupMode {
                        let members = conv.groupMembers
                        if !members.isEmpty {
                            let names = members.map(\.name).joined(separator: String(localized: "、"))
                            Text("\(members.count) 位成员：\(names)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("点击开始对话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if let target = conv.primaryTarget {
                        Text("\(target.providerName) · \(target.modelDisplayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("点击开始对话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)

        Group {
            if useSplitSelection {
                Button {
                    splitSearchRoute = nil
                    splitSelection = conv
                } label: {
                    rowContent
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : nil)
            } else {
                NavigationLink(value: conv) {
                    rowContent
                }
            }
        }
        .contextMenu {
            Button {
                conv.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(conv.isPinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: conv.isPinned ? "pin.slash" : "pin.fill")
            }

            Button {
                tagDraft = conv.folderTag ?? ""
                tagEditingConversation = conv
            } label: {
                Label("设置分组标签", systemImage: "tag")
            }

            Divider()

            Button(role: .destructive) {
                deleteConversation(conv)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                conv.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(conv.isPinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: conv.isPinned ? "pin.slash" : "pin.fill")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteConversation(conv)
            } label: {
                Label("删除", systemImage: "trash")
            }

            Button {
                tagDraft = conv.folderTag ?? ""
                tagEditingConversation = conv
            } label: {
                Label("标签", systemImage: "tag")
            }
            .tint(.indigo)
        }
    }

    private var emptyConversationsPlaceholder: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            Text("聚合你的所有 AI 模型")
                .font(.title3.weight(.bold))

            Text("自由接入 OpenAI 兼容中转、DeepSeek、OpenRouter、Claude 与 Gemini。\n既可单聊随时切换模型，也可一键开启多模型同屏对比。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            HStack(spacing: 12) {
                Button {
                    if hasReadyModel { createNewConversation(arenaMode: false) } else { showModelSetup = true }
                } label: {
                    Label(hasReadyModel ? String(localized: "新建对话") : String(localized: "连接第一个模型"),
                          systemImage: hasReadyModel ? "plus.bubble.fill" : "key")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    createNewConversation(arenaMode: hasReadyModel)
                } label: {
                    Label(hasReadyModel ? String(localized: "多模型对比") : String(localized: "先写草稿"),
                          systemImage: hasReadyModel ? "square.split.2x1" : "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(readyModelCount == 1)
            }

            if hasReadyModel {
                Button {
                    showGroupSetup = true
                } label: {
                    Label("发起多角色圆桌群聊", systemImage: "person.3.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Waits for any in-flight generation to fully stop before deleting,
    /// so streaming tasks never write into a deleted conversation.
    private func deleteConversation(_ conv: Conversation) {
        Task {
            await ChatEngine.shared.stopGenerationAndWait(for: conv.id)
            let id = conv.id
            if splitSelection?.id == id {
                splitSelection = conversations.first { $0.id != id }
            }
            if splitSearchRoute?.conversation.id == id {
                splitSearchRoute = nil
            }
            modelContext.delete(conv)
            do {
                try modelContext.save()
                try ChatDraftStore.shared.remove(id)
                SpotlightIndexService.shared.removeConversation(id: id)
            } catch { deletionError = error.localizedDescription }
        }
    }

    private func latestPreviewMessage(in conv: Conversation) -> ChatMessage? {
        guard !conv.messages.isEmpty else { return nil }
        if ConversationTree.usesTree(conv) {
            return ConversationTree.activeMessages(in: conv).last
        }
        return conv.messages.max { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.sortIndex < rhs.sortIndex
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func updateReadiness() {
        readyModelCount = ProviderConfig.readyTargets(in: providers).count
    }

    private func createNewConversation(arenaMode: Bool, verified: ResolvedModelTarget? = nil) {
        let ready = ProviderConfig.readyTargets(in: providers)
        let preferredPrimary = verified.flatMap { target in ready.first { $0.id == target.id } } ?? ready.first
        let arenaInitial = Array(ready.prefix(2))
        let conv = Conversation(
            title: Conversation.defaultTitle,
            isArenaMode: arenaMode && arenaInitial.count >= 2,
            primaryTarget: preferredPrimary,
            arenaTargets: arenaInitial
        )
        if let defaultPreset = presets.first {
            conv.applyPreset(defaultPreset)
        }
        modelContext.insert(conv)
        try? modelContext.save()
        openConversation(conv)
    }
}
