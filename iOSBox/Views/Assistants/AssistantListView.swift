import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AssistantListView: View {
    enum WorkshopSection: String, CaseIterable, Identifiable {
        case projects
        case friends
        case books
        case presets
        case roundtables
        case study

        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: return String(localized: "项目")
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
    @State private var editingWorkspace: ProjectWorkspace?
    @State private var showCreateWorkspace = false
    @State private var showGroupSetup = false
    @State private var pickingBookFile = false
    @State private var importingBook = false
    @State private var bookToRemove: BookVolume?
    @State private var bookError: String?
    @State private var preferences = AppPreferences.shared
    @State private var ocrQueue = BackgroundPDFOCRQueue.shared
    @State private var cardError: String?
    @State private var confirmRebuildCards = false
    @State private var flashcardStore = FlashcardStore.shared
    @State private var selectedStudyDeck: String = ""
    @State private var studySearchQuery: String = ""
    @State private var activeReviewBatch: IdentifiableCardBatch?
    @State private var editingFlashcard: StudyFlashcard?
    @State private var showCreateFlashcard = false
    @State private var showEnglishCoach = false
    @State private var ankiExportURL: URL?

    private struct IdentifiableCardBatch: Identifiable {
        let id = UUID()
        let title: String
        let cards: [StudyFlashcard]
    }

    private var visibleSections: [WorkshopSection] {
        let sections = WorkshopSection.allCases.filter { section in
            switch section {
            case .projects: return preferences.showsProjects
            case .friends: return preferences.showsBookFriends
            case .books: return true
            case .presets: return true
            case .roundtables: return preferences.showsGroupChat
            case .study: return preferences.showsStudyFlashcards || preferences.showsEnglishCoach
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

                switch activeSection {
                case .projects:
                    ProjectWorkspaceListSection(
                        providers: providers,
                        books: books,
                        conversations: conversations,
                        editingWorkspace: $editingWorkspace,
                        showCreateWorkspace: $showCreateWorkspace
                    )
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
                    if preferences.showsStudyFlashcards { studySection }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Surface.grouped)
            .onAppear { reconcileVisibleSection() }
            .onChange(of: visibleSections) { _, _ in reconcileVisibleSection() }
            .navigationTitle("工作台")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成", action: onClose)
                            .tint(.primary)
                    }
                } else if activeSection == .presets {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    switch activeSection {
                    case .projects:
                        Button { showCreateWorkspace = true } label: { Label("新建项目空间", systemImage: "plus") }
                    case .friends: EmptyView()
                    case .presets:
                        Button { showCreateSheet = true } label: { Label("新建助手", systemImage: "plus") }
                    case .roundtables:
                        Button { showGroupSetup = true } label: { Label("发起圆桌群聊", systemImage: "plus") }
                    case .books:
                        Button { pickingBookFile = true } label: { Label("从文件导入书籍", systemImage: "plus") }
                            .disabled(importingBook)
                    case .study:
                        if preferences.showsStudyFlashcards {
                            Button { showCreateFlashcard = true } label: { Label("新建闪卡", systemImage: "plus") }
                        }
                    }
                }
            }
            .sheet(item: $editingWorkspace) { workspace in
                ProjectWorkspaceEditorSheet(existing: workspace)
            }
            .sheet(isPresented: $showCreateWorkspace) {
                ProjectWorkspaceEditorSheet(existing: nil)
            }
            .sheet(isPresented: $showBookFriends) {
                BookFriendSetupSheet(initialBookID: preselectedBookID) { chat in
                    SystemEntryRouter.shared.conversationID = chat.id
                }
            }
            .sheet(isPresented: $showGroupSetup) {
                GroupCreationFlow(providers: providers, presets: presets) { created in
                    SystemEntryRouter.shared.conversationID = created.id
                }
            }
            .sheet(item: $invitedProfile) { PersonaInvitationView(member: $0) }
            .sheet(item: $inviting) { chat in
                if let friend = chat.activeBookFriend {
                    BookInvitationSheet(friend: friend) { SystemEntryRouter.shared.conversationID = $0.id }
                }
            }
            .sheet(item: $editingPreset) { preset in
                AssistantEditorSheet(preset: preset)
            }
            .sheet(isPresented: $showCreateSheet) {
                AssistantEditorSheet(preset: nil)
            }
            .sheet(item: $activeReviewBatch) { batch in
                FlashcardReviewSheet(
                    initialCards: batch.cards,
                    sessionTitle: batch.title,
                    onJumpToConversation: { convID, msgID in
                        SystemEntryRouter.shared.messageID = msgID
                        SystemEntryRouter.shared.conversationID = convID
                    }
                )
            }
            .sheet(item: $editingFlashcard) { card in
                FlashcardEditorSheet(existingCard: card, defaultDeckName: selectedStudyDeck)
            }
            .sheet(isPresented: $showCreateFlashcard) {
                FlashcardEditorSheet(existingCard: nil, defaultDeckName: selectedStudyDeck)
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
                            try PresetKnowledgeStore.shared.setVolumeIDs([], for: deletedPresetID) {
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
                            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
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
                        if !preferences.simpleDailyMode {
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
            Image(systemName: "ellipsis.circle").frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
        }
        .accessibilityLabel(Text("《\(book.title)》的书籍操作"))
    }

    // MARK: - Section 4: Study Coach & Spaced-Repetition Flashcards

    @ViewBuilder
    private var studySection: some View {
        let deckFilter: String? = selectedStudyDeck.isEmpty ? nil : selectedStudyDeck
        let dueList = flashcardStore.dueCards(inDeck: deckFilter)
        let visibleCards = flashcardStore.filteredCards(deck: deckFilter, query: studySearchQuery)

        if let issue = flashcardStore.loadIssue {
            Section {
                Text(verbatim: issue.localizedDescription).foregroundStyle(.red)
                if issue == .damaged {
                    Button("保留损坏副本并重建卡库") { confirmRebuildCards = true }
                        .confirmationDialog("保留原文件并新建空卡库？", isPresented: $confirmRebuildCards) {
                            Button("重建卡库") {
                                do { try flashcardStore.preserveDamagedLibrary(); cardError = nil }
                                catch { cardError = error.localizedDescription }
                            }
                            Button("取消", role: .cancel) {}
                        } message: { Text("原文件将另存为副本。重建后可重新导入备份中的闪卡。") }
                } else {
                    Button("重新读取") { flashcardStore.reload() }
                }
            }
        }
        if let cardError { Text(verbatim: cardError).foregroundStyle(.red) }

        Section {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack(spacing: DS.Spacing.sm) {
                    DSMetricTile(title: String(localized: "待复习"), value: "\(dueList.count)", valueTint: theme.readableText)
                    DSMetricTile(title: String(localized: "总卡片"), value: "\(flashcardStore.cards.count)")
                    DSMetricTile(title: String(localized: "已熟记"), value: "\(flashcardStore.masteredCount)", valueTint: DS.StatusText.success)
                }

                HStack(spacing: DS.Spacing.sm) {
                    let hasCards = !flashcardStore.cards.isEmpty
                    let canUsePrimary = hasCards ? (!dueList.isEmpty || !visibleCards.isEmpty) : flashcardStore.loadIssue == nil
                    Button {
                        if !hasCards {
                            showCreateFlashcard = true
                            return
                        }
                        let targetCards = dueList.isEmpty ? Array(visibleCards.shuffled().prefix(15)) : dueList
                        guard !targetCards.isEmpty else { return }
                        activeReviewBatch = IdentifiableCardBatch(
                            title: dueList.isEmpty ? String(localized: "随机巩固复习") : String(localized: "今日到期复习"),
                            cards: targetCards
                        )
                    } label: {
                        Label(
                            !hasCards ? String(localized: "手动创建闪卡") : (dueList.isEmpty ? String(localized: "随机抽查巩固") : String(localized: "开始今日复习 (\(dueList.count))")),
                            systemImage: hasCards ? "play.fill" : "plus"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.solidForeground)
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                        .background(canUsePrimary ? theme.solidFill : Color.secondary.opacity(0.35), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canUsePrimary)

                    if !visibleCards.isEmpty {
                        Button {
                            let tsv = flashcardStore.exportAnkiTSV(deckFilter: deckFilter)
                            if let url = try? FlashcardStore.writeTemporaryTSVFile(tsv) {
                                ankiExportURL = url
                            }
                        } label: {
                            Label("导出 Anki", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, DS.Spacing.md)
                                .frame(minHeight: DS.TouchTarget.minimum)
                                .background(DS.Surface.neutralChipFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let ankiExportURL {
                    ShareLink(item: ankiExportURL) {
                        Label("点击分享或保存导出的 Anki 卡包 (.tsv)", systemImage: "doc.badge.arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.readableText)
                    }
                }
            }
            .padding(.vertical, DS.Spacing.xxs)
        } header: {
            Text("间隔重复记忆舱")
        } footer: {
            Text("在助手回复下选择「更多 → 助学」即可提炼闪卡与随堂测验；导出的 .tsv 文件可直接导入 Anki。")
        }

        Section {
            Button {
                startStudyCoachChat(mode: .socratic)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb.max.fill")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                        .frame(width: 36, height: 36)
                        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启苏格拉底启发导师")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("不直接给答案，通过递进追问帮你定位盲区并独立推导")
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

            Button {
                startStudyCoachChat(mode: .feynman)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                        .frame(width: 36, height: 36)
                        .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启费曼挑刺学生演练")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("由你用白话讲解概念，AI 追问逻辑漏洞并输出掌握度评分卡")
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

            Button {
                startStudyCoachChat(mode: .drill)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "flag.checkered")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .frame(width: 36, height: 36)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启闯关实战特训")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Lv.1 → Lv.3 逐级出题实战批改，练透编程、算法或外语技能")
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
        } header: {
            Text("互动导师工作流")
        }

        Section {
            if !flashcardStore.deckNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        deckChip(title: String(localized: "全部卡组"), tag: "")
                        ForEach(flashcardStore.deckNames, id: \.self) { deck in
                            deckChip(title: deck, tag: deck)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !flashcardStore.cards.isEmpty {
                TextField("搜索卡片问题或解析…", text: $studySearchQuery)
                    .font(.subheadline)
            }

            if visibleCards.isEmpty {
                if flashcardStore.cards.isEmpty {
                    Text("暂无闪卡。可在助手回复下选择「更多 → 助学 → 生成记忆闪卡」，或手动创建。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("没有匹配的闪卡，请调整搜索或卡组。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(visibleCards) { card in
                    Button {
                        editingFlashcard = card
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(card.deckName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.indigo)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.indigo.opacity(0.11), in: Capsule())

                                Spacer()

                                Text(card.isDue() ? String(localized: "待复习") : String(localized: "间隔 \(max(1, Int(card.intervalDays.rounded()))) 天"))
                                    .font(.caption2)
                                    .foregroundStyle(card.isDue() ? .orange : .secondary)
                            }

                            Text(card.front)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            Text(card.back)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            do { try flashcardStore.deleteCard(id: card.id); cardError = nil }
                            catch { cardError = error.localizedDescription }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("我的闪卡库（\(visibleCards.count)）")
        }
    }

    private func deckChip(title: String, tag: String) -> some View {
        let selected = selectedStudyDeck == tag
        return Button {
            selectedStudyDeck = tag
            ankiExportURL = nil
        } label: {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.readableText : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    selected ? theme.softFill : DS.Surface.subtle,
                    in: Capsule()
                )
                .frame(minHeight: DS.TouchTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func startStudyCoachChat(mode: StudyCoachMode) {
        let ready = preferences.initialTarget(from: ProviderConfig.readyTargets(in: providers))
        let emoji: String
        switch mode {
        case .socratic: emoji = "💡"
        case .feynman: emoji = "🧑‍🏫"
        case .drill: emoji = "🎯"
        case .off: emoji = "🎓"
        }
        let chat = Conversation(
            title: mode.displayName,
            assistantEmoji: emoji,
            primaryTarget: ready
        )
        chat.assistanceSettings.studyCoachMode = mode
        modelContext.insert(chat)
        try? modelContext.save()
        SystemEntryRouter.shared.conversationID = chat.id
    }

    private func startKnowledgeChat(with book: BookVolume, newDiscussion: Bool = false) {
        do {
            let target = preferences.initialTarget(from: ProviderConfig.readyTargets(in: providers))
            let chat = try BookLibrary.companion(for: book, newDiscussion: newDiscussion, target: target, in: modelContext)
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
