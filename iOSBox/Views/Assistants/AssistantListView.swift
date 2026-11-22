import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AssistantListView: View {
    enum WorkshopSection: String, CaseIterable, Identifiable {
        case presets
        case roundtables
        case books
        case study

        var id: String { rawValue }

        var title: String {
            switch self {
            case .presets: return String(localized: "助手预设")
            case .roundtables: return String(localized: "圆桌阵容")
            case .books: return String(localized: "好友与书架")
            case .study: return String(localized: "助学闪卡")
            }
        }
    }

    @Binding var activeSection: WorkshopSection
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
    @State private var bookToRemove: BookVolume?
    @State private var bookError: String?
    @State private var preferences = AppPreferences.shared
    @State private var cardError: String?
    @State private var confirmRebuildCards = false
    @State private var flashcardStore = FlashcardStore.shared
    @State private var selectedStudyDeck: String = ""
    @State private var studySearchQuery: String = ""
    @State private var activeReviewBatch: IdentifiableCardBatch?
    @State private var editingFlashcard: StudyFlashcard?
    @State private var showCreateFlashcard = false
    @State private var ankiExportURL: URL?

    private struct IdentifiableCardBatch: Identifiable {
        let id = UUID()
        let title: String
        let cards: [StudyFlashcard]
    }

    private var visibleSections: [WorkshopSection] {
        preferences.simpleDailyMode
            ? WorkshopSection.allCases.filter { $0 != .roundtables }
            : WorkshopSection.allCases
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("分类", selection: $activeSection) {
                        ForEach(visibleSections) { sec in
                            Text(sec.title).tag(sec)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                switch activeSection {
                case .presets:
                    if !preferences.simpleDailyMode {
                        PersonaDirectorySection { invitedProfile = $0 }
                    }
                    presetsSection
                case .roundtables:
                    roundtablesSection
                case .books:
                    booksAndFriendsSection
                case .study:
                    studySection
                }
            }
            .onAppear {
                if preferences.simpleDailyMode && activeSection == .roundtables {
                    activeSection = .presets
                }
            }
            .onChange(of: preferences.simpleDailyMode) { _, isSimple in
                if isSimple && activeSection == .roundtables {
                    activeSection = .presets
                }
            }
            .navigationTitle("角色与书架")
            .toolbar {
                if activeSection == .presets {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        switch activeSection {
                        case .presets:
                            showCreateSheet = true
                        case .roundtables:
                            showGroupSetup = true
                        case .books:
                            preselectedBookID = books.first?.id
                            showBookFriends = true
                        case .study:
                            showCreateFlashcard = true
                        }
                    } label: {
                        switch activeSection {
                        case .presets:
                            Label("新建助手", systemImage: "plus")
                        case .roundtables:
                            Label("发起圆桌群聊", systemImage: "plus")
                        case .books:
                            Label("创建书中好友", systemImage: "plus")
                        case .study:
                            Label("新建闪卡", systemImage: "plus")
                        }
                    }
                }
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

    // MARK: - Section 1: Presets

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var presetsSection: some View {
        Section {
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
            Text("点击卡片可编辑提示词与采样参数，点击「对话」立即创建专属会话")
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
        HStack(spacing: DS.Spacing.md) {
            AssistantEmojiIcon(emoji: template.roomEmoji, font: .system(size: 26))
                .frame(width: 44, height: 44)
                .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(template.roomTitle)
                        .font(.body.weight(.semibold))
                    DSBadge(text: String(localized: "\(template.seats.count) 人 · \(template.speakingMode.shortBadge)"), style: .neutral)
                }
                Text(template.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

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
    private var booksAndFriendsSection: some View {
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
                HStack {
                    Button { SystemEntryRouter.shared.conversationID = chat.id } label: {
                        VStack(alignment: .leading) {
                            Label(friend.name, systemImage: "person.crop.square")
                            Text(verbatim: "\(friend.bookTitle) · \(friend.progressLabel(in: books.first { $0.id == friend.bookID }))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    Menu {
                        if history.chats.count > 1 {
                            Section("不同进度的对话") {
                                ForEach(history.chats) { thread in
                                    if let scope = thread.activeBookFriend {
                                        Button { SystemEntryRouter.shared.conversationID = thread.id } label: {
                                            Text(verbatim: "\(scope.progressLabel(in: books.first { $0.id == scope.bookID })) · \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        }
                                    }
                                }
                            }
                        }
                        Button { inviting = chat } label: { Label("邀请进群", systemImage: "person.2.badge.plus") }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("好友操作")
                }
            }
        }

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
                            .accessibilityIdentifier("shelf.progress")
                    } else { Text("共 \(book.chapterTitles.count) 节") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
        .accessibilityLabel("书籍操作")
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
                    DSMetricTile(title: String(localized: "已熟记"), value: "\(flashcardStore.masteredCount)", valueTint: .green)
                }

                HStack(spacing: DS.Spacing.sm) {
                    Button {
                        let targetCards = dueList.isEmpty ? Array(visibleCards.shuffled().prefix(15)) : dueList
                        guard !targetCards.isEmpty else { return }
                        activeReviewBatch = IdentifiableCardBatch(
                            title: dueList.isEmpty ? String(localized: "随机巩固复习") : String(localized: "今日到期复习"),
                            cards: targetCards
                        )
                    } label: {
                        Label(
                            dueList.isEmpty ? String(localized: "随机抽查巩固") : String(localized: "开始今日复习 (\(dueList.count))"),
                            systemImage: "play.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.solidForeground)
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                        .background(flashcardStore.cards.isEmpty ? Color.secondary.opacity(0.35) : theme.solidFill, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(flashcardStore.cards.isEmpty)

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
            Text("在任意对话消息底部点击「助学」即可一键提炼闪卡与随堂测验；导出的 .tsv 文件可直接导入 Anki。")
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
                Text("暂无闪卡。可在任意对话回复底部点按「助学 → 生成记忆闪卡」，或点击右上角 + 手动创建。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
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
                let prepared = try await Task.detached(priority: .userInitiated) { try BookImporter.read(url) }.value
                let stored = try BookLibrary.store(prepared, in: modelContext)
                preselectedBookID = stored.id
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
