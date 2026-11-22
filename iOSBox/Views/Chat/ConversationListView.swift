import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Binding var pendingConversationToOpen: Conversation?
    @Binding var pendingMessageRoute: ConversationMessageRoute?

    var selectSection: ((Int) -> Void)?
    @State private var showsCompactLanding = false
    @State private var landingDraft: Conversation?

    init(
        pendingConversationToOpen: Binding<Conversation?>,
        pendingMessageRoute: Binding<ConversationMessageRoute?> = .constant(nil),
        selectSection: ((Int) -> Void)? = nil
    ) {
        self.selectSection = selectSection
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
    @State private var pendingDeletion: Conversation?
    @State private var deletionError: String?
    @State private var showReader = false
    @State private var showGroupSetup = false
    @State private var showBookFriends = false
    @State private var readyModelCount = 0
    @State private var bookmarkedConversationIDs: Set<UUID> = []
    @State private var preferences = AppPreferences.shared
    private var theme: DS.AccentTheme { preferences.accentTheme }

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
                        .safeAreaInset(edge: .bottom) { sidebarDestinations }
                        .navigationSplitViewColumnWidth(min: 235, ideal: 320, max: 360)
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
                            landingEditor
                        }
                    }
                }
            } else {
                NavigationStack(path: $navigationPath) {
                    Group {
                        if showsCompactLanding {
                            landingEditor
                                .toolbar {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button { showsCompactLanding = false } label: {
                                            Label("对话列表", systemImage: "list.bullet")
                                        }
                                        .accessibilityIdentifier("chat.history")
                                    }
                                }
                        } else {
                            conversationSidebarContent(useSplitSelection: false)
                                .navigationTitle("夜奔")
                                .toolbar { listToolbarItems }
                        }
                    }
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
        .onChange(of: splitSearchRoute?.conversation.readingVolumeID ?? splitSelection?.readingVolumeID) { _, bookID in
            if bookID != nil { columnVisibility = .detailOnly }
        }
        .onAppear {
            updateReadiness()
            refreshBookmarkedIndex()
            if landingDraft == nil {
                landingDraft = conversations.first {
                    Conversation.isDefaultTitle($0.title) && $0.messages.isEmpty && !$0.isArenaMode &&
                    !$0.isGroupMode && $0.activeBookFriend == nil && $0.assistanceSettings.knowledgeVolumeIDs.isEmpty
                } ?? newDraft(arenaMode: false)
                if horizontalSizeClass != .regular && conversations.isEmpty && navigationPath.isEmpty {
                    showsCompactLanding = true
                }
            }
        }
        .onChange(of: preferences.defaultTargetID) { refreshUntouchedLanding() }
        .onChange(of: preferences.defaultAssistantID) { refreshUntouchedLanding() }
        .onChange(of: SystemIntegration.fingerprint(providers)) { updateReadiness(); refreshUntouchedLanding() }
        .onReceive(NotificationCenter.default.publisher(for: .init("IOSBoxCredentialsChanged"))) { _ in updateReadiness() }
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
        .alert("删除这段对话？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
               presenting: pendingDeletion) { chat in
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { deleteConversation(chat) }
        } message: { chat in
            Text("将删除「\(chat.title)」及其所有消息和草稿。")
        }
        .alert("无法更新对话记录", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
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
                    conv.setFolderTag(cleaned.isEmpty ? nil : cleaned)
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
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索对话")
    }

    @ToolbarContentBuilder
    private var listToolbarItems: some ToolbarContent {
        if horizontalSizeClass == .regular {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill").foregroundStyle(theme.readableText)
                    Text("夜奔").font(.title3.bold())
                }
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button { showReader = true } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .accessibilityLabel("网页精读")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if preferences.simpleDailyMode {
                Button {
                    createNewConversation(arenaMode: false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                        if horizontalSizeClass != .regular { Text("新建") }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("新建")
            } else {
                Menu {
                    Button { createNewConversation(arenaMode: false) } label: { Label("普通对话", systemImage: "bubble.left") }
                        .keyboardShortcut("n", modifiers: .command)
                    Button { createNewConversation(arenaMode: true, blind: true) } label: { Label("双盲对比", systemImage: "eye.slash") }
                        .disabled(readyModelCount < 2)
                    Button { showGroupSetup = true } label: { Label("圆桌群聊", systemImage: "person.3.fill") }
                    if horizontalSizeClass == .regular {
                        Button { showReader = true } label: { Label("网页精读", systemImage: "doc.text.magnifyingglass") }
                    }
                    Button { showBookFriends = true } label: { Label("书中好友", systemImage: "book.pages") }
                    Button { createNewConversation(arenaMode: true) } label: { Label("多模型对比", systemImage: "square.split.2x1") }
                        .disabled(readyModelCount < 2)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                        if horizontalSizeClass != .regular { Text("新建") }
                    }
                }
                .accessibilityLabel("新建")
            }
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
                .foregroundStyle(selected ? theme.solidForeground : .primary)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, 7)
                .background(
                    selected ? theme.solidFill : DS.Surface.subtle,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(selected ? Color.clear : DS.Surface.hairline, lineWidth: 1)
                )
                .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func conversationRow(_ conv: Conversation, useSplitSelection: Bool = false) -> some View {
        let isSelected = useSplitSelection && (splitSelection ?? landingDraft)?.id == conv.id && splitSearchRoute == nil
        let rowContent = HStack(spacing: DS.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(theme.softFill)
                    .frame(width: 42, height: 42)
                AssistantEmojiIcon(emoji: conv.assistantEmoji, font: .title3)
                    .frame(width: 42, height: 42)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(conv.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if conv.isGroupMode {
                        DSBadge(text: String(localized: "群聊"), style: .tinted(.indigo))
                    } else if conv.isArenaMode {
                        DSBadge(text: String(localized: "对比"), style: .accent(theme))
                    }

                    if let tag = conv.folderTag, !tag.isEmpty {
                        DSBadge(text: tag, style: .neutral)
                    }

                    Spacer()

                    Text(conv.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    HStack(spacing: 12) {
                        Image(systemName: conv.readingVolumeID != nil ? "book" : (conv.isArenaMode ? "rectangle.split.2x1" : "bubble.left"))
                            .foregroundStyle(isSelected ? theme.readableText : .secondary)
                        Text(verbatim: conv.title).lineLimit(1)
                        Spacer()
                        if conv.isPinned { Image(systemName: "pin.fill").font(.caption) }
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
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
                conv.setPinned(!conv.isPinned)
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
                pendingDeletion = conv
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                conv.setPinned(!conv.isPinned)
                try? modelContext.save()
            } label: {
                Label(conv.isPinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: conv.isPinned ? "pin.slash" : "pin.fill")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                pendingDeletion = conv
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

    @ViewBuilder
    private var landingEditor: some View {
        if let chat = landingDraft {
            ChatDetailView(conversation: chat, isLandingDraft: true, onOpenConversation: openConversation)
                .id(chat.id)
        }
    }

    @ViewBuilder
    private var sidebarDestinations: some View {
        if let selectSection {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Button { selectSection(1) } label: { Label("助手与书架", systemImage: "books.vertical").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                Menu {
                    Button { selectSection(2) } label: { Label("服务商与设置", systemImage: "server.rack") }
                    Button { selectSection(3) } label: { Label("用量与测速", systemImage: "chart.bar") }
                } label: { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.plain)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
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
            if landingDraft?.id == id { landingDraft = newDraft(arenaMode: false) }
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

    private func refreshUntouchedLanding() {
        if let draft = landingDraft, draft.modelContext == nil, draft.messages.isEmpty {
            landingDraft = newDraft(arenaMode: false)
        }
    }

    private func updateReadiness() {
        readyModelCount = ProviderConfig.readyTargets(in: providers).count
    }

    private func newDraft(arenaMode: Bool) -> Conversation {
        preferences.newChat(providers: providers, presets: presets, arena: arenaMode)
    }

    private func createNewConversation(arenaMode: Bool, blind: Bool = false) {
        let conv = newDraft(arenaMode: arenaMode)
        if blind { conv.assistanceSettings.blindArenaMode = true }
        modelContext.insert(conv)
        do {
            try modelContext.save()
            openConversation(conv)
        } catch { deletionError = error.localizedDescription }
    }
}
