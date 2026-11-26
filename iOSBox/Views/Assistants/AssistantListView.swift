import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AssistantListView: View {
    enum WorkshopSection: String, CaseIterable, Identifiable {
        case friends
        case books
        case presets
        case roundtables
        case study

        var id: String { rawValue }

        var title: String {
            switch self {
            case .friends: return String(localized: "好友")
            case .presets: return String(localized: "助手预设")
            case .roundtables: return String(localized: "圆桌")
            case .books: return String(localized: "书架")
            case .study: return String(localized: "学习")
            }
        }
    }

    @Binding var activeSection: WorkshopSection
    var onClose: (() -> Void)? = nil
    var onStartChatWithPreset: (AssistantPreset) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query private var profiles: [PersonaProfile]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @Query private var readingStates: [ShelfReadingState]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var inviting: Conversation?
    @State private var invitedProfile: GroupMember?
    @State private var showBookFriends = false
    @State private var preselectedBookID: UUID?
    @State private var editingPreset: AssistantPreset?
    @State private var showCreateSheet = false
    @State private var showGroupSetup = false
    @State private var pickingBookFile = false
    @State private var importingBook = false
    @State private var startingLibraryDiscussion = false
    @State private var createdLibraryChatID: UUID?
    @State private var showingReadingNotes = false
    @State private var bookToRemove: BookVolume?
    @State private var bookError: String?
    @State private var preferences = AppPreferences.shared
    @State private var ocrQueue = BackgroundPDFOCRQueue.shared
    @State private var showEnglishCoach = false

    private var visibleSections: [WorkshopSection] {
        let sections = WorkshopSection.allCases.filter { section in
            switch section {
            case .friends: return preferences.showsBookFriends
            case .books: return true
            case .presets: return true
            case .roundtables: return preferences.showsGroupChat
            case .study: return preferences.showsEnglishCoach
            }
        }
        return sections.isEmpty ? [.presets, .books] : sections
    }

    private func reconcileVisibleSection() {
        if !visibleSections.contains(activeSection), let first = visibleSections.first {
            activeSection = first
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            sectionPicker.pickerStyle(.menu)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                sectionPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                                sectionPicker.pickerStyle(.menu)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                if preferences.showsArena {
                    NavigationLink { ArenaDecisionLibrary() } label: { Label("模型对比记录", systemImage: "checkmark.bubble") }
                }
                switch activeSection {
                case .friends:
                    PersonaDirectorySection(invite: { invitedProfile = $0 }, allowsGroupInvitations: preferences.showsGroupChat)
                    bookFriendsSection
                case .presets:
                    presetsSection
                case .roundtables:
                    roundtablesSection
                case .books:
                    bookshelfSection
                case .study:
                    if preferences.showsEnglishCoach {
                        Section {
                            Button { showEnglishCoach = true } label: {
                                Label("AI 英语私教", systemImage: "waveform.and.mic")
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Surface.grouped)
            .onAppear { reconcileVisibleSection() }
            .onChange(of: visibleSections) { _, _ in reconcileVisibleSection() }
            .safeAreaInset(edge: .bottom) {
                if UIDevice.current.userInterfaceIdiom != .phone { OptionalModuleControls() }
            }
            .navigationTitle(UIDevice.current.userInterfaceIdiom == .phone ? activeSection.title : String(localized: "工作台"))
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成", action: onClose)
                            .tint(.primary)
                    }
                } else if activeSection == .presets {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                            .accessibilityIdentifier("assistants.editPresets")
                    }
                }
                if onClose != nil && activeSection == .presets {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                            .accessibilityIdentifier("assistants.editPresets")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    switch activeSection {
                    case .friends: EmptyView()
                    case .presets:
                        Button { showCreateSheet = true } label: { Label("新建助手", systemImage: "plus") }
                    case .roundtables:
                        Button { showGroupSetup = true } label: { Label("发起圆桌群聊", systemImage: "plus") }
                    case .books:
                        Button { pickingBookFile = true } label: { Label("从文件导入书籍", systemImage: "plus") }
                            .disabled(importingBook)
                    case .study:
                        EmptyView()
                    }
                }
            }
            .sheet(isPresented: $showingReadingNotes, onDismiss: routeCreatedLibraryChatIfNeeded) {
                ShelfReadingNotesSheet { citation in
                    do {
                        guard let book = try BookLibrary.find(citation.volumeID, in: modelContext) else { throw BookImportError.unavailable }
                        let target = preferences.initialTarget(from: ProviderConfig.readyTargets(in: providers))
                        let chat = try BookLibrary.companion(for: book, newDiscussion: false, target: target, in: modelContext)
                        try ChatDraftStore.shared.state(for: chat.id).addReadingCitation(citation)
                        createdLibraryChatID = chat.id
                        showingReadingNotes = false
                    } catch { bookError = error.localizedDescription }
                }
            }
            .sheet(isPresented: $showBookFriends, onDismiss: routeCreatedLibraryChatIfNeeded) {
                BookFriendSetupSheet(initialBookID: preselectedBookID) { chat in
                    createdLibraryChatID = chat.id
                    showBookFriends = false
                }
            }
            .sheet(isPresented: $showGroupSetup, onDismiss: routeCreatedLibraryChatIfNeeded) {
                GroupCreationFlow(providers: providers, presets: presets) { created in
                    createdLibraryChatID = created.id
                    showGroupSetup = false
                }
            }
            .sheet(item: $invitedProfile) { PersonaInvitationView(member: $0) }
            .sheet(item: $inviting, onDismiss: routeCreatedLibraryChatIfNeeded) { chat in
                if let friend = chat.activeBookFriend {
                    BookInvitationSheet(friend: friend) { opened in
                        createdLibraryChatID = opened.id
                        inviting = nil
                    }
                }
            }
            .sheet(item: $editingPreset) { preset in
                AssistantEditorSheet(preset: preset)
            }
            .sheet(isPresented: $showCreateSheet) {
                AssistantEditorSheet(preset: nil)
            }
            .sheet(isPresented: $startingLibraryDiscussion, onDismiss: routeCreatedLibraryChatIfNeeded) {
                LibraryDiscussionSheet { chat in
                    createdLibraryChatID = chat.id
                    startingLibraryDiscussion = false
                }
            }
            .sheet(isPresented: $showEnglishCoach) {
                EnglishCoachHubView(onClose: { showEnglishCoach = false })
            }
            .confirmationDialog(
                "从书架移除这本书？",
                isPresented: Binding(get: { bookToRemove != nil }, set: { if !$0 { bookToRemove = nil } }),
                presenting: bookToRemove
            ) { volume in
                Button("从书架移除", role: .destructive) {
                    do {
                        try BookLibrary.remove(volume, in: modelContext)
                    } catch {
                        bookError = error.localizedDescription
                    }
                    bookToRemove = nil
                }
                Button("取消", role: .cancel) { bookToRemove = nil }
            } message: { _ in
                Text("已有聊天记录和引用会保留。继续与这本书的好友聊天时，需要重新导入同一版本。")
            }
            .fileImporter(
                isPresented: $pickingBookFile,
                allowedContentTypes: [.plainText, .pdf] + ["epub", "docx", "xlsx", "pptx", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }
            ) { result in
                switch result {
                case .success(let url):
                    importBookToShelf(url)
                case .failure(let failure):
                    if (failure as NSError).code != NSUserCancelledError {
                        bookError = failure.localizedDescription
                    }
                }
            }
            .alert("书籍提示", isPresented: Binding(get: { bookError != nil }, set: { if !$0 { bookError = nil } })) {
                Button("好", role: .cancel) { bookError = nil }
            } message: {
                Text(verbatim: bookError ?? "")
            }
        }
    }

    private var sectionPicker: some View {
        Picker("分类", selection: $activeSection) {
            ForEach(visibleSections) { section in Text(section.title).tag(section) }
        }
    }

    // MARK: - Section 1: Presets

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var presetsSection: some View {
        Section {
            if presets.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label("暂无助手预设", systemImage: "sparkles")
                        .font(.headline)
                    Text("创建助手预设后，可以从这里开始对话。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("新建助手") { showCreateSheet = true }
                }
                .padding(.vertical, DS.Spacing.sm)
                .accessibilityIdentifier("assistants.emptyPresets")
            }
            ForEach(presets) { preset in
                HStack(spacing: DS.Spacing.md) {
                    Button {
                        editingPreset = preset
                    } label: {
                        HStack(spacing: DS.Spacing.md) {
                            AssistantEmojiIcon(emoji: preset.iconEmoji, font: .system(size: 26))
                                .frame(width: 44, height: 44)
                                .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                HStack(spacing: DS.Spacing.xs) {
                                    Text(preset.name)
                                        .font(.body.weight(.semibold))
                                    if preset.enableThinking {
                                        DSBadge(text: String(localized: "思考"), style: .accent(theme))
                                    }
                                }
                                Text(preset.subtitle.isEmpty ? preset.systemPrompt : preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("编辑角色"))

                    Button {
                        onStartChatWithPreset(preset)
                    } label: {
                        Text("对话")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, 7)
                            .foregroundStyle(.primary)
                            .background(theme.softFill, in: Capsule())
                            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("与\(preset.name)对话"))
                }
                .padding(.vertical, 3)
                .contextMenu {
                    Button("设为默认助手") { preferences.defaultAssistantID = preset.id }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        let deletedPresetID = preset.id
                        do {
                            try modelContext.save()
                            try PresetKnowledgeStore.shared.setBindings(volumes: [], memories: nil, for: deletedPresetID) {
                                try modelContext.transaction { modelContext.delete(preset); try modelContext.save() }
                            }
                            if !modelContext.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                                SyncTombstoneStore.shared.recordDeletion(kind: .preset, id: deletedPresetID)
                            }
                        } catch {
                            modelContext.rollback()
                            bookError = error.localizedDescription
                        }
                    } label: {
                        Label("删除", systemImage: "trash")
                    }

                    Button {
                        editingPreset = preset
                    } label: {
                        Label("编辑", systemImage: "slider.horizontal.3")
                    }
                    .tint(.blue)
                }
            }
            .onMove(perform: movePresets)
        } header: {
            if !presets.isEmpty {
                Text("点击卡片可编辑提示词与采样参数，点击「对话」立即创建专属会话")
            }
        }
    }

    // MARK: - Section 2: Roundtable Templates

    @ViewBuilder
    private var roundtablesSection: some View {
        if !preferences.customGroupTemplates.isEmpty {
            Section("我的圆桌阵容") {
                ForEach(preferences.customGroupTemplates) { template in
                    roundtableRow(template)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                preferences.removeCustomGroupTemplate(id: template.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }

        Section {
            ForEach(GroupRoomTemplate.builtInTemplates) { template in
                roundtableRow(template)
            }
        } header: {
            Text("精选圆桌阵容")
        } footer: {
            Text("在任意圆桌群聊的设置页点击「保存为我的圆桌模板」，即可在此一键复用自定义角色组合。")
        }
    }

    private func roundtableRow(_ template: GroupRoomTemplate) -> some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: DS.Spacing.md))
        return layout {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                AssistantEmojiIcon(emoji: template.roomEmoji, font: .system(size: 26))
                    .frame(width: 44, height: 44)
                    .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    if large {
                        Text(template.roomTitle).font(.body.weight(.semibold))
                        Text("\(template.seats.count) 人 · \(template.speakingMode.shortBadge)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: DS.Spacing.xs) {
                            Text(template.roomTitle).font(.body.weight(.semibold))
                            DSBadge(text: String(localized: "\(template.seats.count) 人 · \(template.speakingMode.shortBadge)"), style: .neutral)
                        }
                    }
                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(large ? nil : 2)
                        .fixedSize(horizontal: false, vertical: large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                startGroupChat(from: template)
            } label: {
                Text("开聊")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, 7)
                    .foregroundStyle(.primary)
                    .background(theme.softFill, in: Capsule())
                    .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("开始 \(template.roomTitle) 圆桌对话"))
        }
        .padding(.vertical, 3)
    }

    private func startGroupChat(from template: GroupRoomTemplate) {
        let ready = ProviderConfig.readyTargets(in: providers)
        guard !ready.isEmpty else {
            showGroupSetup = true
            return
        }
        let members = template.instantiate(using: ready, profiles: profiles.compactMap { try? $0.member() })
        let conv = Conversation(
            title: template.roomTitle,
            assistantEmoji: template.roomEmoji,
            systemPrompt: template.sharedTopicPrompt,
            isArenaMode: false,
            primaryTarget: members.first?.target
        )
        var s = AssistanceSettings()
        s.isGroupMode = true
        s.groupMembers = members
        s.groupSpeakingMode = template.speakingMode
        s.groupSpeechStyle = template.speechStyle
        conv.assistanceSettings = s
        modelContext.insert(conv)
        try? modelContext.save()
        SystemEntryRouter.shared.conversationID = conv.id
    }

    // MARK: - Section 3: Book Friends & Local Bookshelf

    @ViewBuilder
    private var bookFriendsSection: some View {
        Section("书中好友") {
            Button {
                preselectedBookID = books.first?.id
                showBookFriends = true
            } label: {
                Label("从书中创建好友", systemImage: "book.pages")
            }

            ForEach(BookFriendHistory.grouped(conversations)) { history in
                let chat = history.chats[0]
                let friend = history.friend
                let book = books.first { $0.id == friend.bookID }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { SystemEntryRouter.shared.conversationID = chat.id } label: {
                            HStack {
                                DSIconTile(systemImage: "book.pages", tint: theme.readableText, size: 38)
                                VStack(alignment: .leading) {
                                    Text(verbatim: friend.name).font(.headline)
                                    Text("来自《\(friend.bookTitle)》 · \(friend.progressLabel(in: book))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("私聊")
                        if history.chats.count > 1 {
                            Menu {
                                ForEach(history.chats) { thread in
                                    if let scope = thread.activeBookFriend {
                                        Button { SystemEntryRouter.shared.conversationID = thread.id } label: {
                                            Text(verbatim: "\(scope.progressLabel(in: book)) · \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        }
                                    }
                                }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("不同进度的对话")
                        }
                    }
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        Button { SystemEntryRouter.shared.conversationID = chat.id } label: {
                            FriendActionLabel(title: "私聊", icon: "bubble.left")
                        }
                        .accessibilityLabel(Text("与 \(friend.name) 私聊"))
                        if preferences.showsGroupChat {
                            Button { inviting = chat } label: {
                                FriendActionLabel(title: "邀请进群", icon: "person.2.badge.plus")
                            }
                            .accessibilityLabel(Text("邀请 \(friend.name) 进群"))
                            .accessibilityIdentifier("friend.invite.\(chat.id)")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bookshelfSection: some View {
        Section {
            if books.isEmpty { LocalReadingSampleButton() }
            else {
                Button { startingLibraryDiscussion = true } label: { Label("用一组资料新建对话", systemImage: "books.vertical") }
            }
            Button {
                pickingBookFile = true
            } label: {
                if importingBook {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在读取书中资料…")
                    }
                } else {
                    Label("从文件导入书籍", systemImage: "book.badge.plus")
                }
            }
            .disabled(importingBook)
            Button { showingReadingNotes = true } label: { Label("阅读笔记", systemImage: "book.and.pencil") }

            ForEach(ocrQueue.orderedJobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: job.isFinished ? "checkmark.circle.fill" : "doc.text.viewfinder")
                            .foregroundStyle(job.isFinished ? .green : theme.readableText)
                        Text(verbatim: job.bookTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if job.isFinished {
                            Button("完成") { ocrQueue.dismissFinished(bookID: job.id) }
                                .font(.caption)
                        } else {
                            Button("取消") { ocrQueue.cancel(bookID: job.id) }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: job.fractionCompleted)
                        .tint(job.isFinished ? .green : theme.readableText)
                    Text(job.isFinished
                         ? String(localized: "后台 OCR 已完成，新增识别 \(job.recognizedNewPages) 页")
                         : String(localized: "后台渐进 OCR：\(job.completedPages)/\(job.totalPages) 页（可随时开始阅读）"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            let positions = Dictionary(readingStates.map { ($0.bookID, $0.chapter) }, uniquingKeysWith: { first, _ in first })
            ForEach(books) { book in
                shelfRow(book, savedChapter: positions[book.id])
                .padding(.vertical, 2)
                .contextMenu {
                    Button { startKnowledgeChat(with: book, newDiscussion: true) } label: {
                        Label("新开讨论", systemImage: "square.and.pencil")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { startKnowledgeChat(with: book, newDiscussion: true) } label: { Label("新开讨论", systemImage: "square.and.pencil") }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        bookToRemove = book
                    } label: {
                        Label("从书架移除", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("我的书架（\(books.count)）")
        } footer: {
            Text("支持 EPUB、TXT、Markdown 和 PDF（含扫描版离线文字识别）。正文保存在本机，并随完整备份导出。")
        }
    }

    private func shelfRow(_ book: BookVolume, savedChapter: Int?) -> some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: DS.Spacing.md) {
                DSIconTile(systemImage: "text.book.closed.fill", tint: theme.readableText, size: 38, cornerRadius: DS.Radius.sm)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: book.title).font(.headline).foregroundStyle(.primary)
                    if let chapter = savedChapter, !book.chapterTitles.isEmpty {
                        let index = min(max(0, chapter), book.chapterTitles.count - 1)
                        let title = book.chapterTitles[index]
                        Text("上次读到 \(title.isEmpty ? String(localized: "第 \(index + 1) 节") : title)")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("shelf.progress")
                    } else { Text("共 \(book.chapterTitles.count) 节").foregroundStyle(.secondary) }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                if large { shelfMenu(book) }
            }
            Button { startKnowledgeChat(with: book) } label: {
                Text(savedChapter == nil ? String(localized: "开始阅读") : String(localized: "继续阅读"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: large ? .infinity : nil)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(theme.softFill, in: Capsule())
                    .frame(minHeight: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(savedChapter == nil ? Text("开始阅读《\(book.title)》") : Text("继续阅读《\(book.title)》"))
            if !large { shelfMenu(book) }
        }
    }

    private func shelfMenu(_ book: BookVolume) -> some View {
        Menu {
            Button { startKnowledgeChat(with: book, newDiscussion: true) } label: {
                Label("新开讨论", systemImage: "square.and.pencil")
            }
            Button {
                preselectedBookID = book.id
                showBookFriends = true
            } label: { Label("创建角色", systemImage: "person.badge.plus") }
        } label: {
            Image(systemName: "ellipsis").frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
        }
        .accessibilityLabel(Text("《\(book.title)》的书籍操作"))
    }

    private func routeCreatedLibraryChatIfNeeded() {
        guard let id = createdLibraryChatID else { return }
        createdLibraryChatID = nil
        onClose?()
        SystemEntryRouter.shared.conversationID = id
    }

    private func startKnowledgeChat(with book: BookVolume, newDiscussion: Bool = false) {
        do {
            let target = preferences.initialTarget(from: ProviderConfig.readyTargets(in: providers))
            let chat = try BookLibrary.companion(for: book, newDiscussion: newDiscussion, target: target, in: modelContext)
            onClose?()
            SystemEntryRouter.shared.openOriginalForChatID = newDiscussion ? nil : chat.id
            SystemEntryRouter.shared.conversationID = chat.id
        } catch { bookError = error.localizedDescription }
    }

    private func importBookToShelf(_ url: URL) {
        importingBook = true
        Task { @MainActor in
            defer { importingBook = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BookImporter.readProgressive(url)
                }.value
                let stored = try BookLibrary.store(result.prepared, in: modelContext)
                preselectedBookID = stored.id
                if let pdfData = result.pdfDataForContinuation, !result.remainingPDFPageIndices.isEmpty {
                    ocrQueue.enqueue(
                        bookID: stored.id,
                        bookTitle: stored.title,
                        pdfData: pdfData,
                        remainingPageIndices: result.remainingPDFPageIndices,
                        totalPDFPages: result.totalPDFPages,
                        modelContext: modelContext
                    )
                }
            } catch {
                bookError = error.localizedDescription
            }
        }
    }

    /// Persists the new order (also used by the preset strip in chat settings).
    private func movePresets(from source: IndexSet, to destination: Int) {
        var reordered = presets
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, preset) in reordered.enumerated() where preset.sortOrder != index {
            preset.sortOrder = index
        }
        try? modelContext.save()
    }
}
