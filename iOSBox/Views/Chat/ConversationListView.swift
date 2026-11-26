import SwiftUI
import SwiftData
import UIKit

struct ConversationListView: View {
    @Binding var pendingConversationToOpen: Conversation?
    @Binding var pendingMessageRoute: ConversationMessageRoute?

    var selectSection: ((Int) -> Void)?
    var onStartChatWithPreset: ((AssistantPreset) -> Void)?

    init(
        pendingConversationToOpen: Binding<Conversation?>,
        pendingMessageRoute: Binding<ConversationMessageRoute?> = .constant(nil),
        selectSection: ((Int) -> Void)? = nil,
        onStartChatWithPreset: ((AssistantPreset) -> Void)? = nil
    ) {
        self.selectSection = selectSection
        self.onStartChatWithPreset = onStartChatWithPreset
        self._pendingConversationToOpen = pendingConversationToOpen
        self._pendingMessageRoute = pendingMessageRoute
    }

    @Environment(WorkspaceNavigation.self) private var workspaceNavigation: WorkspaceNavigation?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @Query(sort: \RequestRecord.startedAt, order: .reverse) private var records: [RequestRecord]

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
        HistorySearchQuery(
            text: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            tag: selectedFilterTag,
            bookmarkedChatsOnly: showOnlyBookmarked,
            scope: searchScope,
            includeReasoning: searchIncludeReasoning
        )
    }

    @State private var searchText: String = ""
    @State private var searchScope: GlobalSearchScope = .all
    @State private var searchIncludeReasoning = true
    @State private var selectedBookSearchHit: BookSearchHit?
    @State private var pendingSearchHitRoute: (chat: Conversation, onPhone: Bool)?
    @State private var selectedFilterTag: String? = nil
    @State private var showOnlyBookmarked = false
    @State private var tagEditingConversation: Conversation?
    @State private var tagDraft: String = ""
    @State private var pendingDeletion: Conversation?
    @State private var deletionError: String?
    @State private var deletionUndo: ConversationDeletionUndo?
    @State private var showGroupSetup = false
    @State private var showBookmarksHub = false
    @State private var showQuickKeySetup = false
    @State private var readyModelCount = 0
    @State private var bookmarkedConversationIDs: Set<UUID> = []
    @State private var postSaveRefreshTask: Task<Void, Never>?
    @State private var isBatchSelecting = false
    @State private var batchSelectedIDs: Set<UUID> = []
    @State private var showBatchDeleteConfirm = false
    @State private var showBatchTagAlert = false
    @State private var batchTagDraft = ""
    @State private var batchExportItem: BatchExportSharePayload?
    @State private var landingDraft: Conversation?
    @State private var phoneTab: PhoneWorkspaceTab = .conversation
    private enum PhoneDestination: Hashable { case archive, chat }
    @State private var phonePath: [PhoneDestination] = []
    @State private var phoneComposeEntry: PhoneComposeEntry?
    @State private var historySearchPresented = false
    @State private var isPhoneKeyboardVisible = false
    @State private var hasAppliedInitialPadVisibility = false
    @State private var localPadSpace: WorkspaceNavigation.PadSpace = .chat
    @State private var localCommandPalettePresented = false
    @State private var preferences = AppPreferences.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var usesPhoneWorkspace: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var activePadSpace: WorkspaceNavigation.PadSpace {
        get { workspaceNavigation?.padSpace ?? localPadSpace }
        nonmutating set {
            if let workspaceNavigation {
                workspaceNavigation.padSpace = newValue
            } else {
                localPadSpace = newValue
            }
        }
    }

    private var commandPaletteBinding: Binding<Bool> {
        Binding(
            get: { workspaceNavigation?.isCommandPalettePresented ?? localCommandPalettePresented },
            set: { value in
                if let workspaceNavigation {
                    workspaceNavigation.isCommandPalettePresented = value
                } else {
                    localCommandPalettePresented = value
                }
            }
        )
    }

    private var showsPhoneTabBar: Bool {
        !isPhoneKeyboardVisible && (phoneTab != .conversation || phonePath.last != .chat)
    }

    private var availableTags: [String] {
        let tags = Set(conversations.compactMap { conv -> String? in
            let t = conv.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        })
        return tags.sorted()
    }

    private var filteredConversations: [Conversation] {
        conversations.filter { conv in
            if showOnlyBookmarked && !bookmarkedConversationIDs.contains(conv.id) {
                return false
            }
            if let selectedFilterTag {
                if conv.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines) != selectedFilterTag {
                    return false
                }
            }
            return true
        }
    }

    private var readyProviderCount: Int {
        providers.filter(\.isReadyForChat).count
    }

    private var monthlySpendSummary: String? {
        let monthRecords = records.filter { $0.kind != .webSearch && LedgerPeriod.month.includes($0.startedAt) }
        guard !monthRecords.isEmpty else { return nil }
        let totals = RequestLedger.costs(monthRecords)
        let summary = RequestLedger.costOverviewText(totals: totals, modelRecords: monthRecords, requestCount: monthRecords.count)
        return String(localized: "本月 \(summary)")
    }

    @discardableResult
    private func refreshBookmarkedIndex() -> Int {
        let desc = FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.assistanceMetadataData != nil })
        guard let msgs = try? modelContext.fetch(desc) else { return 0 }
        var ids = Set<UUID>()
        var totalBookmarked = 0
        for msg in msgs where msg.assistanceMetadata.isBookmarked {
            totalBookmarked += 1
            if let convID = msg.conversation?.id {
                ids.insert(convID)
            }
        }
        bookmarkedConversationIDs = ids
        return totalBookmarked
    }

    private func schedulePostSaveRefresh(immediate: Bool = false) {
        postSaveRefreshTask?.cancel()
        postSaveRefreshTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            guard ChatEngine.shared.activeConversationIDs.isEmpty else { return }
            let count = refreshBookmarkedIndex()
            WidgetSnapshotService.shared.sync(context: modelContext, bookmarkedCount: count)
            if !searchQuery.text.isEmpty { searchRevision += 1 }
        }
    }

    private var baseWorkspaceView: some View {
        Group {
            if usesPhoneWorkspace {
                phoneWorkspace
            } else {
                GeometryReader { proxy in
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        padSidebarColumn
                            .navigationSplitViewColumnWidth(min: 256, ideal: 296, max: 350)
                    } detail: {
                        padDetailColumn
                    }
                    .navigationSplitViewStyle(.balanced)
                    .onAppear {
                        if !hasAppliedInitialPadVisibility {
                            hasAppliedInitialPadVisibility = true
                            columnVisibility = proxy.size.width >= 900 ? .all : .detailOnly
                        }
                    }
                }
            }
        }
        .background(DS.Surface.canvas.ignoresSafeArea())
        .onChange(of: splitSearchRoute?.conversation.readingVolumeID ?? splitSelection?.readingVolumeID) { _, bookID in
            if bookID != nil && !usesPhoneWorkspace {
                columnVisibility = .detailOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fugueCreateNewChat)) { _ in
            if usesPhoneWorkspace {
                startPhoneChat(.writing)
            } else {
                activePadSpace = .chat
                createNewConversation(arenaMode: false)
            }
        }
        .onAppear {
            updateReadiness()
            refreshBookmarkedIndex()
            if !usesPhoneWorkspace && landingDraft == nil {
                landingDraft = conversations.first {
                    Conversation.isDefaultTitle($0.title) && $0.messages.isEmpty && !$0.isArenaMode &&
                    !$0.isGroupMode && $0.activeBookFriend == nil && $0.assistanceSettings.knowledgeVolumeIDs.isEmpty
                } ?? newDraft(arenaMode: false)
            }
            handleQuickActionIfNeeded()
        }
        .onChange(of: SystemEntryRouter.shared.pendingQuickAction, initial: true) { _, action in
            if action != nil {
                handleQuickActionIfNeeded()
            }
        }
        .onChange(of: preferences.defaultTargetID) { refreshUntouchedLanding() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: modelContext)) { _ in
            if usesPhoneWorkspace && landingDraft?.modelContext != nil { landingDraft = nil }
            WebDAVAutoSyncCoordinator.shared.markLocalDataChanged()
            if ChatEngine.shared.activeConversationIDs.isEmpty {
                schedulePostSaveRefresh()
            }
        }
        .onChange(of: ChatEngine.shared.activeConversationIDs.isEmpty) { _, isIdle in
            if isIdle {
                schedulePostSaveRefresh(immediate: true)
            }
        }
        .onDisappear {
            postSaveRefreshTask?.cancel()
            postSaveRefreshTask = nil
        }
        .onChange(of: preferences.defaultAssistantID) { refreshUntouchedLanding() }
        .onChange(of: SystemIntegration.fingerprint(providers)) { updateReadiness(); refreshUntouchedLanding() }
        .onReceive(NotificationCenter.default.publisher(for: .init("IOSBoxCredentialsChanged"))) { _ in updateReadiness() }
    }

    var body: some View {
        baseWorkspaceView
        .sheet(isPresented: $showGroupSetup) {
            GroupCreationFlow(providers: providers, presets: presets) { created in
                openConversation(created)
            }
        }
        .sheet(isPresented: $showQuickKeySetup) {
            QuickKeySetupSheet()
        }
        .sheet(isPresented: commandPaletteBinding) {
            PadCommandPaletteSheet(
                conversations: conversations,
                books: books,
                onSelectSpace: { space in
                    selectPadSpace(space)
                },
                onSelectConversation: { conv in
                    openConversation(conv)
                },
                onOpenBook: { book in
                    openBookFromPalette(book)
                },
                onCreateNewChat: {
                    activePadSpace = .chat
                    createNewConversation(arenaMode: false)
                },
                onCreateArenaChat: {
                    activePadSpace = .chat
                    createNewConversation(arenaMode: true)
                },
                onToggleInspector: {
                    activePadSpace = .chat
                    NotificationCenter.default.post(name: .fugueToggleInspector, object: nil)
                }
            )
            .tint(theme.tintColor)
        }
        .sheet(isPresented: $showBookmarksHub) {
            BookmarksHubSheet(
                onJumpToRoute: openSearchRoute,
                onBookmarksChanged: {
                    let count = refreshBookmarkedIndex()
                    WidgetSnapshotService.shared.sync(context: modelContext, bookmarkedCount: count)
                }
            )
        }
        .sheet(item: $batchExportItem) { item in
            BatchExportShareSheet(items: [item.url])
        }
        .sheet(item: $selectedBookSearchHit, onDismiss: {
            guard let route = pendingSearchHitRoute else { return }
            pendingSearchHitRoute = nil
            if route.onPhone { openPhoneChat(route.chat, entry: .writing) }
            else { openConversation(route.chat) }
        }) { hit in
            BookSearchHitReaderSheet(hit: hit) { citation, existing in
                let chat = existing ?? newDraft(arenaMode: false)
                let draft = ChatDraftStore.shared.state(for: chat.id)
                if existing == nil {
                    do {
                        try draft.addReadingCitation(citation)
                        modelContext.insert(chat)
                        try modelContext.save()
                    } catch {
                        if chat.modelContext != nil { modelContext.delete(chat) }
                        try? ChatDraftStore.shared.remove(chat.id)
                        throw error
                    }
                } else { try draft.addReadingCitation(citation) }
                pendingSearchHitRoute = (chat, usesPhoneWorkspace)
                selectedBookSearchHit = nil
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let undo = deletionUndo {
                HStack {
                    Text("已删除 \(undo.snapshots.count) 段对话")
                    Spacer()
                    Button("撤销删除") {
                        do {
                            try undo.restore(in: modelContext, drafts: .shared, summaries: .shared)
                            deletionUndo = nil
                        } catch { deletionError = error.localizedDescription }
                    }
                    .accessibilityIdentifier("history.undoDeletion")
                }
                .padding()
                .background(.regularMaterial)
                .task(id: undo.id) {
                    try? await Task.sleep(for: .seconds(15))
                    if !Task.isCancelled, deletionUndo?.id == undo.id { deletionUndo = nil }
                }
            }
            if let error = SystemIntegration.shared.error {
                Text(error).font(.caption).foregroundStyle(DS.StatusText.warning).padding(8)
            }
        }
        .alert("删除这段对话？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
               presenting: pendingDeletion) { chat in
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { deleteConversations([chat], allowUndo: true) }
            Button("立即永久删除", role: .destructive) { deleteConversations([chat], allowUndo: false) }
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
                openSearchRoute(route)
                pendingMessageRoute = nil
            }
        }
    }

    private var phoneWorkspace: some View {
        VStack(spacing: 0) {
            TabView(selection: $phoneTab) {
                Tab("对话", systemImage: "bubble.left", value: .conversation) {
                    phoneInboxStack.toolbar(.hidden, for: .tabBar)
                }
                if preferences.showsBookFriends {
                    Tab("好友", systemImage: "person.2", value: .friends) {
                        phoneFriendsStack.toolbar(.hidden, for: .tabBar)
                    }
                }
                Tab("资料库", systemImage: "book", value: .library) {
                    phoneLibraryStack.toolbar(.hidden, for: .tabBar)
                }
            }

            if showsPhoneTabBar {
                PhoneWorkspaceTabBar(
                    selection: phoneTab,
                    accent: theme,
                    showsFriends: preferences.showsBookFriends
                ) { tab in
                    if tab == .conversation && tab == phoneTab { phonePath.removeAll() }
                    else { selectPhoneTab(tab) }
                }
            }
        }
        .environment(\.usesPhoneWorkspace, true)
        .tint(theme.tintColor)
        .background(DS.Surface.canvas.ignoresSafeArea())
        .onChange(of: preferences.showsBookFriends) { _, shows in
            if !shows && phoneTab == .friends {
                phoneTab = .conversation
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isPhoneKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isPhoneKeyboardVisible = false
        }
    }

    private var phoneFriendsStack: some View {
        NavigationStack {
            PhoneFriendsView()
                .toolbar(.hidden, for: .tabBar)
        }
    }

    private var phoneLibraryStack: some View {
        NavigationStack {
            PhoneLibraryView(
                books: books,
                onOpenSection: { section in
                    if let workspaceNavigation { workspaceNavigation.openWorkshop(section) }
                    else { selectSection?(1) }
                },
                onResumeReading: { chat in
                    SystemEntryRouter.shared.openOriginalForChatID = chat.id
                    openConversation(chat)
                },
                onOpenSettings: {
                    if let workspaceNavigation { workspaceNavigation.openSettings() }
                    else { selectSection?(2) }
                },
                onOpenUsage: {
                    if let workspaceNavigation { workspaceNavigation.openUsage() }
                    else { selectSection?(3) }
                }
            )
            .toolbar(.hidden, for: .tabBar)
        }
    }

    private var phoneInboxStack: some View {
        NavigationStack(path: $phonePath) {
            PhoneInboxView(
                conversations: conversations, theme: theme,
                preview: { conversationPreview($0, font: .subheadline) },
                openConversation: openConversation,
                resumeDraft: { openPhoneChat($0, entry: .writing) },
                compose: startPhoneChat,
                openArchive: { phonePath.append(.archive) },
                search: {
                    phonePath.append(.archive)
                    historySearchPresented = true
                }
            )
            .navigationDestination(for: PhoneDestination.self) { destination in
                switch destination {
                case .archive:
                    conversationSidebarContent(compact: true)
                        .navigationTitle("历史")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("新对话") { startPhoneChat(.writing) }
                                    .keyboardShortcut("n", modifiers: .command)
                                    .accessibilityIdentifier("workspace.history.newChat")
                            }
                        }
                case .chat:
                    stageDetailContent
                }
            }
        }
        .onChange(of: phonePath) { _, path in
            if !path.contains(.chat) {
                splitSelection = nil
                splitSearchRoute = nil
                phoneComposeEntry = nil
                landingDraft = nil
            }
            if !path.contains(.archive) {
                historySearchPresented = false
                searchText = ""
                isBatchSelecting = false
                batchSelectedIDs.removeAll()
            }
        }
    }

    private func startPhoneChat(_ entry: PhoneComposeEntry) {
        let draft = newDraft(arenaMode: false)
        landingDraft = draft
        openPhoneChat(draft, entry: entry)
    }

    private func openPhoneChat(_ chat: Conversation, entry: PhoneComposeEntry) {
        openConversation(chat)
        phoneComposeEntry = entry
    }

    private func selectPhoneTab(_ selection: PhoneWorkspaceTab) {
        guard selection != phoneTab else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        phoneTab = selection
    }

    private var toggleDrawer: (() -> Void)? {
        nil
    }

    private func closeDrawerAnimated() {
        workspaceNavigation?.isDrawerPresented = false
    }

    private func selectPadSpace(_ space: WorkspaceNavigation.PadSpace) {
        preferences.triggerSelectionHaptic()
        switch space {
        case .chat:
            if let workspaceNavigation { workspaceNavigation.openChat() } else { localPadSpace = .chat }
        case .bookshelf:
            if let workspaceNavigation { workspaceNavigation.openBookshelf() } else { localPadSpace = .bookshelf }
        case .friends:
            if let workspaceNavigation { workspaceNavigation.openFriends() } else { localPadSpace = .friends }
        case .workshop:
            if let workspaceNavigation { workspaceNavigation.openWorkshop() } else { localPadSpace = .workshop }
        case .settings:
            if let workspaceNavigation { workspaceNavigation.openSettings() } else { localPadSpace = .settings }
        case .usage:
            if let workspaceNavigation { workspaceNavigation.openUsage() } else { localPadSpace = .usage }
        }
    }

    private func openBookFromPalette(_ book: BookVolume) {
        do {
            let target = preferences.initialTarget(from: ProviderConfig.readyTargets(in: providers))
            let chat = try BookLibrary.companion(for: book, newDiscussion: false, target: target, in: modelContext)
            SystemEntryRouter.shared.openOriginalForChatID = chat.id
            openConversation(chat)
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func startChatFromWorkshopPreset(_ preset: AssistantPreset) {
        if let onStartChatWithPreset {
            onStartChatWithPreset(preset)
            return
        }
        let ready = ProviderConfig.readyTargets(in: providers)
        let conv = Conversation(
            title: preset.name,
            primaryTarget: preferences.initialTarget(from: ready),
            arenaTargets: Array(ready.prefix(2))
        )
        conv.applyPreset(preset)
        modelContext.insert(conv)
        try? modelContext.save()
        openConversation(conv)
    }

    // MARK: - Stage & Sidebar Columns

    private var stageDetailStack: some View {
        NavigationStack { stageDetailContent }
    }

    @ViewBuilder
    private var padDetailColumn: some View {
        switch activePadSpace {
        case .chat:
            stageDetailStack
        case .bookshelf:
            NavigationStack {
                PadBookshelfView()
            }
        case .friends:
            NavigationStack {
                PadFriendsWorkspaceView()
            }
        case .workshop:
            AssistantListView(
                activeSection: Binding(
                    get: { workspaceNavigation?.assistantSection ?? .presets },
                    set: { workspaceNavigation?.assistantSection = $0 }
                ),
                onClose: nil
            ) { preset in
                startChatFromWorkshopPreset(preset)
            }
        case .settings:
            PadSettingsSplitView()
        case .usage:
            NavigationStack {
                RequestLedgerView(onClose: nil)
            }
        }
    }

    @ViewBuilder
    private var stageDetailContent: some View {
        if let route = splitSearchRoute {
            ConversationSearchDestination(route: route, onOpenConversation: openConversation)
                .id("\(route.conversation.id.uuidString)-\(route.messageID.uuidString)")
        } else if let conv = splitSelection, !conv.isDeleted, conv.modelContext != nil || (usesPhoneWorkspace && conv === landingDraft) {
            ChatDetailView(conversation: conv, isLandingDraft: conv.modelContext == nil,
                           onOpenConversation: openConversation, onToggleDrawer: toggleDrawer,
                           phoneEntry: phoneComposeEntry)
                .id(conv.id)
        } else if !usesPhoneWorkspace {
            landingEditor
        } else {
            ContentUnavailableView("未找到对话", systemImage: "bubble.left")
        }
    }

    private var padSidebarColumn: some View {
        conversationSidebarContent()
            .safeAreaInset(edge: .bottom) {
                if !isBatchSelecting {
                    PadSidebarFooterView(
                        readyProviderCount: readyProviderCount,
                        monthlySpendText: monthlySpendSummary,
                        showsUsage: preferences.showsUsageTab,
                        activeSpace: activePadSpace,
                        onOpenQuickKeySetup: {
                            showQuickKeySetup = true
                        },
                        onOpenUsage: {
                            if let workspaceNavigation {
                                workspaceNavigation.openUsage()
                            } else {
                                selectSection?(3)
                            }
                        },
                        onOpenSettings: {
                            if let workspaceNavigation {
                                workspaceNavigation.openSettings()
                            } else {
                                selectSection?(2)
                            }
                        }
                    )
                }
            }
            .navigationTitle("夜奔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { listToolbarItems }
    }

    @ViewBuilder
    private func padSpaceSidebarRow(
        _ space: WorkspaceNavigation.PadSpace,
        badge: String? = nil,
        accessibilityID: String
    ) -> some View {
        let isSelected = activePadSpace == space
        Button {
            selectPadSpace(space)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: space.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? theme.readableText : DS.Surface.inkSecondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(verbatim: space.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? theme.readableText : .primary)
                Spacer(minLength: 0)
                if let badge, !badge.isEmpty {
                    Text(verbatim: badge)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(isSelected ? theme.readableText : DS.Surface.inkSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(isSelected ? theme.softFill : DS.Surface.neutralChipFill, in: Capsule())
                }
            }
            .padding(.horizontal, DS.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(Text(verbatim: space.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityID)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .listRowBackground(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(isSelected ? theme.softFill : Color.clear)
                .padding(.vertical, 1)
        )
    }

    @ViewBuilder
    private func conversationSidebarContent(compact: Bool = false) -> some View {
        let tags = availableTags
        let filtered = filteredConversations
        let store = ChatDraftStore.shared
        let drafts = filtered.filter { store.previews[$0.id]?.summary != nil }.sorted {
            store.draftDates[$0.id, default: $0.updatedAt] > store.draftDates[$1.id, default: $1.updatedAt]
        }
        let draftIDs = Set(drafts.map(\.id))
        let pinned = filtered.filter { $0.isPinned && !draftIDs.contains($0.id) }
        let regular = filtered.filter { !$0.isPinned && !draftIDs.contains($0.id) }

        let list = List {
            if !compact && searchQuery.text.isEmpty {
                Section {
                    padSpaceSidebarRow(.chat, badge: conversations.isEmpty ? nil : "\(conversations.count)", accessibilityID: "pad.space.chat")
                    padSpaceSidebarRow(.bookshelf, badge: books.isEmpty ? nil : String(localized: "\(books.count) 本"), accessibilityID: "pad.space.bookshelf")
                    if preferences.showsBookFriends {
                        padSpaceSidebarRow(.friends, accessibilityID: "pad.space.friends")
                    }
                    padSpaceSidebarRow(.workshop, accessibilityID: "工作台")
                } header: {
                    Text("工作空间")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Surface.inkSecondary)
                }
            }

            if !searchQuery.text.isEmpty || !tags.isEmpty || showOnlyBookmarked || !bookmarkedConversationIDs.isEmpty || !conversations.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if !searchQuery.text.isEmpty {
                                ForEach(GlobalSearchScope.allCases) { scope in
                                    filterChip(title: scope.label, selected: searchScope == scope) {
                                        searchScope = scope
                                    }
                                }
                                if searchScope == .all || searchScope == .conversations {
                                    filterChip(title: String(localized: "含思考"), selected: searchIncludeReasoning) {
                                        searchIncludeReasoning.toggle()
                                    }
                                }
                            } else {
                                filterChip(title: String(localized: "全部"), selected: selectedFilterTag == nil && !showOnlyBookmarked) {
                                    selectedFilterTag = nil
                                    showOnlyBookmarked = false
                                }
                            }
                            if showOnlyBookmarked || !bookmarkedConversationIDs.isEmpty {
                                filterChip(title: String(localized: "含收藏"), selected: showOnlyBookmarked) {
                                    showOnlyBookmarked.toggle()
                                }
                            }
                            if !conversations.isEmpty && searchQuery.text.isEmpty {
                                filterChip(title: String(localized: "收藏夹"), selected: false) {
                                    showBookmarksHub = true
                                }
                            }
                            ForEach(tags, id: \.self) { tag in
                                filterChip(title: tag, selected: selectedFilterTag == tag) {
                                    selectedFilterTag = (selectedFilterTag == tag) ? nil : tag
                                }
                            }
                            if !conversations.isEmpty && searchQuery.text.isEmpty {
                                filterChip(
                                    title: isBatchSelecting ? String(localized: "完成") : String(localized: "批量管理"),
                                    selected: isBatchSelecting
                                ) {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        isBatchSelecting.toggle()
                                        batchSelectedIDs.removeAll()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 4, trailing: 14))
                .listRowBackground(Color.clear)
            }

            if searchQuery.text.isEmpty {
                if !drafts.isEmpty {
                    Section("草稿") {
                        ForEach(drafts) { conv in conversationRow(conv, compact: compact) }
                    }
                }
                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { conv in conversationRow(conv, compact: compact) }
                    } header: {
                        Text("置顶对话")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.Surface.inkSecondary)
                    }
                }
                ForEach(ConversationTimeBucket.group(regular, date: \.updatedAt), id: \.bucket) { group in
                    Section {
                        ForEach(group.items) { conv in conversationRow(conv, compact: compact) }
                    } header: {
                        Text(group.bucket.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.Surface.inkSecondary)
                    }
                }
            } else {
                ConversationSearchResults(
                    conversations: conversations,
                    query: searchQuery,
                    session: historySearch,
                    retry: { searchRevision += 1 },
                    onSelectConversation: { conv in
                        openConversation(conv)
                    },
                    onSelectRoute: openSearchRoute,
                    onSelectBookHit: { hit in
                        selectedBookSearchHit = hit
                    }
                )
            }
        }
        Group {
            if compact { list.listStyle(.plain) }
            else { list.listStyle(.sidebar) }
        }
        .scrollContentBackground(.hidden)
        .background(compact ? DS.Surface.canvas : DS.Surface.drawer)
        .task(id: SearchRefresh(query: searchQuery, revision: searchRevision)) {
            await historySearch.update(searchQuery, in: modelContext.container)
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await store.loadInboxPreviews() }
        }
        .searchable(text: $searchText, isPresented: $historySearchPresented,
                    placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索对话与书架")
        .safeAreaInset(edge: .bottom) {
            if isBatchSelecting {
                batchActionBar
            }
        }
        .alert("批量设置标签", isPresented: $showBatchTagAlert) {
            TextField("标签名称（留空清除）", text: $batchTagDraft)
            Button("取消", role: .cancel) { batchTagDraft = "" }
            Button("应用") { applyBatchTag() }
        } message: {
            Text("将为已选择的 \(batchSelectedIDs.count) 段对话设置分组标签。")
        }
        .confirmationDialog(
            "确定删除已选择的 \(batchSelectedIDs.count) 段对话？",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("全部删除", role: .destructive) { deleteBatchSelected() }
            Button("立即永久删除", role: .destructive) { deleteBatchSelected(allowUndo: false) }
            Button("取消", role: .cancel) {}
        }
    }

    @ToolbarContentBuilder
    private var listToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                FugueSealMark(character: "奔", size: 22, theme: theme)
                Text("夜奔")
                    .font(.system(.headline, design: .serif).weight(.bold))
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                commandPaletteBinding.wrappedValue = true
            } label: {
                Image(systemName: "command")
            }
            .accessibilityLabel("快速跳转")
            .accessibilityIdentifier("workspace.commandPalette")

            if preferences.simpleDailyMode && !preferences.showsArena {
                Button {
                    createNewConversation(arenaMode: false)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel("新建")
            } else {
                Menu {
                    Button { createNewConversation(arenaMode: false) } label: { Label("普通对话", systemImage: "bubble.left") }
                        .keyboardShortcut("n", modifiers: .command)
                    if preferences.showsArena {
                        Button { createNewConversation(arenaMode: true) } label: { Label("多模型对比", systemImage: "square.split.2x1") }
                            .disabled(readyModelCount < 2)
                    }
                    if preferences.showsGroupChat {
                        Button {
                            closeDrawerAnimated()
                            showGroupSetup = true
                        } label: { Label("圆桌群聊", systemImage: "person.3.fill") }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新建")
            }
        }
    }

    private func openConversation(_ conv: Conversation) {
        splitSearchRoute = nil
        splitSelection = conv
        presentSelectedChat()
    }

    private func openSearchRoute(_ route: ConversationMessageRoute) {
        splitSelection = route.conversation
        splitSearchRoute = route
        presentSelectedChat()
    }

    private func presentSelectedChat() {
        if usesPhoneWorkspace {
            phoneComposeEntry = nil
            selectPhoneTab(.conversation)
            if phonePath.last != .chat { phonePath.append(.chat) }
        } else {
            if let workspaceNavigation {
                workspaceNavigation.openChat()
            } else {
                localPadSpace = .chat
            }
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
                    selected ? theme.solidFill : DS.Surface.card,
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

    private func conversationPreview(_ conv: Conversation, font: Font = .caption) -> some View {
        HStack(spacing: 6) {
            if let summary = ChatDraftStore.shared.previews[conv.id]?.summary {
                Text("草稿").fontWeight(.semibold).foregroundStyle(theme.readableText).fixedSize()
                Text(verbatim: summary).foregroundStyle(DS.Surface.inkSecondary)
            } else if let lastMsg = latestPreviewMessage(in: conv) {
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
                    .foregroundStyle(DS.Surface.inkSecondary)
            } else if conv.isGroupMode {
                let members = conv.groupMembers
                if !members.isEmpty {
                    let names = members.map(\.name).joined(separator: String(localized: "、"))
                    Text("\(members.count) 位成员：\(names)")
                        .foregroundStyle(DS.Surface.inkSecondary)
                } else {
                    Text("点击开始对话")
                        .foregroundStyle(DS.Surface.inkSecondary)
                }
            } else if let target = conv.primaryTarget {
                Text("\(target.providerName) · \(target.modelDisplayName)")
                    .foregroundStyle(DS.Surface.inkSecondary)
            } else {
                Text("点击开始对话")
                    .foregroundStyle(DS.Surface.inkSecondary)
            }
        }
        .font(font)
        .lineLimit(1)
    }

    @ViewBuilder
    private func conversationRow(_ conv: Conversation, compact: Bool = false) -> some View {
        let isSelected = (usesPhoneWorkspace || activePadSpace == .chat) && (splitSelection ?? landingDraft)?.id == conv.id && splitSearchRoute == nil
        let rowBody = HStack(spacing: DS.Spacing.sm) {
            if compact {
                let symbol = conv.isArenaMode ? "arrow.left.arrow.right" : (conv.isGroupMode ? "person.2" : "doc.text")
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.readableText)
                    .frame(width: 30)
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isSelected ? theme.solidFill : Color.clear)
                    .frame(width: 3, height: 28)
                    .accessibilityHidden(true)
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(isSelected ? theme.softFill : DS.Surface.subtle)
                        .frame(width: 36, height: 36)
                    AssistantEmojiIcon(emoji: conv.assistantEmoji, font: .subheadline)
                        .frame(width: 36, height: 36)
                }
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(conv.title)
                        .font(.body.weight(isSelected ? .semibold : .medium))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if conv.isGroupMode || conv.isArenaMode || !(conv.folderTag ?? "").isEmpty {
                        HStack(spacing: DS.Spacing.xs) { conversationBadges(conv) }
                    }
                    Text(conv.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(DS.Surface.inkSecondary)
                } else {
                    HStack(spacing: DS.Spacing.xs) {
                        Text(conv.title)
                            .font((compact ? Font.body : .subheadline).weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        conversationBadges(conv)
                        Spacer(minLength: 4)
                        if conv.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(theme.readableText)
                        } else {
                            Text(conv.updatedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(DS.Surface.inkSecondary)
                        }
                    }
                }

                conversationPreview(conv)
            }
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            if compact && !isBatchSelecting {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, compact ? DS.Spacing.xs : 0)
        .frame(minHeight: DS.TouchTarget.minimum)
        .contentShape(Rectangle())

        Group {
            if isBatchSelecting {
                let checked = batchSelectedIDs.contains(conv.id)
                Button {
                    if checked {
                        batchSelectedIDs.remove(conv.id)
                    } else {
                        batchSelectedIDs.insert(conv.id)
                    }
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(checked ? theme.readableText : .secondary)
                        rowBody
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    preferences.triggerSelectionHaptic()
                    openConversation(conv)
                } label: {
                    rowBody
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(isSelected ? theme.softFill : (compact ? DS.Surface.canvas : DS.Surface.card))
                        .padding(.vertical, compact ? 0 : 2)
                )
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await ChatDraftStore.shared.loadPreview(for: conv.id) }
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
    private func conversationBadges(_ conv: Conversation) -> some View {
        if conv.isGroupMode {
            DSBadge(text: String(localized: "群聊"), style: .tinted(.indigo))
        } else if conv.isArenaMode {
            DSBadge(text: String(localized: "对比"), style: .accent(theme))
        }
        if let tag = conv.folderTag, !tag.isEmpty {
            DSBadge(text: tag, style: .neutral)
        }
    }

    @ViewBuilder
    private var landingEditor: some View {
        if let chat = landingDraft {
            ChatDetailView(
                conversation: chat,
                isLandingDraft: true,
                onOpenConversation: openConversation,
                onToggleDrawer: toggleDrawer
            )
            .id(chat.id)
        }
    }

    private var batchActionBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("已选 \(batchSelectedIDs.count) 项")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("批量标签") {
                batchTagDraft = ""
                showBatchTagAlert = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(batchSelectedIDs.isEmpty)

            Menu("批量导出") {
                Button {
                    exportBatchSelected(asPDF: false)
                } label: {
                    Label("导出为 Markdown", systemImage: "doc.text")
                }

                Button {
                    exportBatchSelected(asPDF: true)
                } label: {
                    Label("导出为 PDF", systemImage: "doc.richtext")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(batchSelectedIDs.isEmpty)

            Button("删除 (\(batchSelectedIDs.count))", role: .destructive) {
                showBatchDeleteConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
            .disabled(batchSelectedIDs.isEmpty)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Surface.drawer)
    }

    private func exportBatchSelected(asPDF: Bool) {
        let targets = conversations.filter { batchSelectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        do {
            let url = asPDF
                ? try BatchArchiveExporter.writeConversationsPDFFile(conversations: targets)
                : try BatchArchiveExporter.writeConversationsMarkdownFile(conversations: targets)
            batchExportItem = BatchExportSharePayload(url: url)
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func applyBatchTag() {
        let cleaned = batchTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = batchSelectedIDs
        for conv in conversations where ids.contains(conv.id) {
            conv.setFolderTag(cleaned.isEmpty ? nil : cleaned)
        }
        try? modelContext.save()
        batchTagDraft = ""
        isBatchSelecting = false
        batchSelectedIDs.removeAll()
    }

    private func deleteBatchSelected(allowUndo: Bool = true) {
        let targets = conversations.filter { batchSelectedIDs.contains($0.id) }
        isBatchSelecting = false
        batchSelectedIDs.removeAll()
        deleteConversations(targets, allowUndo: allowUndo)
    }

    private func deleteConversations(_ selected: [Conversation], allowUndo: Bool) {
        let ids = Set(selected.map(\.id))
        Task { @MainActor in
            for id in ids { await ChatEngine.shared.stopGenerationAndWait(for: id) }
            do {
                try modelContext.save()
                let remaining = try modelContext.fetch(FetchDescriptor<Conversation>())
                let targets = remaining.filter { ids.contains($0.id) }
                guard !targets.isEmpty else { return }
                let undo = allowUndo ? try ConversationDeletionUndo(chats: targets, drafts: .shared, summaries: .shared) : nil
                if let current = splitSelection, ids.contains(current.id) {
                    splitSelection = remaining.first { !ids.contains($0.id) }
                }
                if let id = splitSearchRoute?.conversation.id, ids.contains(id) { splitSearchRoute = nil }
                if let id = landingDraft?.id, ids.contains(id) { landingDraft = newDraft(arenaMode: false) }
                let removed = targets.map(\.id)
                try modelContext.transaction {
                    for chat in targets { modelContext.delete(chat) }
                    try modelContext.save()
                }
                deletionUndo = undo
                if !modelContext.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                    SyncTombstoneStore.shared.recordDeletions(kind: .conversation, ids: removed)
                }
                WebDAVAutoSyncCoordinator.shared.markWorkspaceChanged(in: modelContext)
                for id in removed {
                    RollingContextSummaryStore.shared.remove(for: id)
                    SpotlightIndexService.shared.removeConversation(id: id)
                    do { try ChatDraftStore.shared.remove(id) } catch { deletionError = error.localizedDescription }
                }
            } catch {
                modelContext.rollback()
                deletionError = error.localizedDescription
            }
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
        if !usesPhoneWorkspace, let draft = landingDraft, draft.modelContext == nil, draft.messages.isEmpty {
            landingDraft = newDraft(arenaMode: false)
        }
    }

    private func updateReadiness() {
        readyModelCount = ProviderConfig.readyTargets(in: providers).count
    }

    private func newDraft(arenaMode: Bool) -> Conversation {
        preferences.newChat(providers: providers, presets: presets, arena: arenaMode)
    }

    private func createNewConversation(arenaMode: Bool) {
        let conv = newDraft(arenaMode: arenaMode)
        modelContext.insert(conv)
        do {
            try modelContext.save()
            openConversation(conv)
        } catch { deletionError = error.localizedDescription }
    }

    private var hasActiveLocalSheet: Bool {
        showGroupSetup || showQuickKeySetup || showBookmarksHub || batchExportItem != nil || selectedBookSearchHit != nil
    }

    private func dismissLocalSheets(keepingBookmarks: Bool = false) {
        showGroupSetup = false
        showQuickKeySetup = false
        batchExportItem = nil
        pendingSearchHitRoute = nil
        selectedBookSearchHit = nil
        if !keepingBookmarks {
            showBookmarksHub = false
        }
    }

    private func handleQuickActionIfNeeded() {
        guard let action = SystemEntryRouter.shared.pendingQuickAction else { return }
        SystemEntryRouter.shared.pendingQuickAction = nil

        let hadPresentedModal = workspaceNavigation?.activeModal != nil
            || hasActiveLocalSheet
            || ModalPresentationGate.hasActiveOrDismissingModalInWindow()

        workspaceNavigation?.closeModal()
        closeDrawerAnimated()

        switch action {
        case .newChat:
            dismissLocalSheets()
            let openFreshChat = { @MainActor in
                if usesPhoneWorkspace { startPhoneChat(.writing) }
                else { _ = openOrCreateFreshQuickChat() }
            }
            if hadPresentedModal {
                ModalPresentationGate.performWhenClear(
                    extraCheck: { workspaceNavigation?.activeModal != nil || hasActiveLocalSheet },
                    action: openFreshChat
                )
            } else {
                openFreshChat()
            }
        case .voiceNote:
            dismissLocalSheets()
            if let conv = openOrCreateFreshQuickChat() {
                SystemEntryRouter.shared.pendingChatToolRequest = ChatToolLaunchRequest(conversationID: conv.id, tool: .voiceNote)
            }
        case .scanDocument:
            dismissLocalSheets()
            if let conv = openOrCreateFreshQuickChat() {
                SystemEntryRouter.shared.pendingChatToolRequest = ChatToolLaunchRequest(conversationID: conv.id, tool: .scanDocument)
            }
        case .bookmarks:
            if showBookmarksHub && workspaceNavigation?.activeModal == nil {
                dismissLocalSheets(keepingBookmarks: true)
                return
            }
            dismissLocalSheets()
            ModalPresentationGate.performWhenClear(
                extraCheck: {
                    workspaceNavigation?.activeModal != nil
                        || showGroupSetup
                        || showQuickKeySetup
                        || batchExportItem != nil
                        || selectedBookSearchHit != nil
                }
            ) {
                showBookmarksHub = true
            }
        }
    }

    private func openOrCreateFreshQuickChat() -> Conversation? {
        let conv: Conversation
        if !usesPhoneWorkspace, let existing = conversations.first(where: {
            Conversation.isDefaultTitle($0.title) && $0.messages.isEmpty && !$0.isArenaMode &&
            !$0.isGroupMode && $0.activeBookFriend == nil && $0.assistanceSettings.knowledgeVolumeIDs.isEmpty
        }) {
            conv = existing
        } else {
            let fresh = newDraft(arenaMode: false)
            modelContext.insert(fresh)
            do {
                try modelContext.save()
            } catch {
                deletionError = error.localizedDescription
                return nil
            }
            conv = fresh
        }
        openConversation(conv)
        return conv
    }
}

private struct BatchExportSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct BatchExportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
