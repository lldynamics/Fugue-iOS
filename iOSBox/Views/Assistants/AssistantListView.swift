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

    var onStartChatWithPreset: (AssistantPreset) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]

    @State private var activeSection: WorkshopSection = .presets
    @State private var inviting: Conversation?
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("分类", selection: $activeSection) {
                        ForEach(WorkshopSection.allCases) { sec in
                            Text(sec.title).tag(sec)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                switch activeSection {
                case .presets:
                    presetsSection
                case .roundtables:
                    roundtablesSection
                case .books:
                    booksAndFriendsSection
                case .study:
                    studySection
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
                allowedContentTypes: [.plainText, .pdf] + ["epub", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }
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

    private var presetsSection: some View {
        Section {
            ForEach(presets) { preset in
                HStack(spacing: 12) {
                    Text(preset.iconEmoji)
                        .font(.system(size: 28))
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(preset.name)
                                .font(.body.weight(.semibold))
                            if preset.enableThinking {
                                Text("思考")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.purple)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.purple.opacity(0.12), in: Capsule())
                            }
                        }

                        Text(preset.subtitle.isEmpty ? preset.systemPrompt : preset.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Button {
                        onStartChatWithPreset(preset)
                    } label: {
                        Text("对话")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingPreset = preset
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        let deletedPresetID = preset.id
                        modelContext.delete(preset)
                        do {
                            try modelContext.save()
                            PresetKnowledgeStore.shared.removePreset(deletedPresetID)
                        } catch {
                            modelContext.rollback()
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
        HStack(spacing: 12) {
            Text(template.roomEmoji)
                .font(.system(size: 26))
                .frame(width: 44, height: 44)
                .background(Color.indigo.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(template.roomTitle)
                        .font(.body.weight(.semibold))
                    Text("\(template.seats.count) 人 · \(template.speakingMode.shortBadge)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.indigo.opacity(0.12), in: Capsule())
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func startGroupChat(from template: GroupRoomTemplate) {
        let ready = ProviderConfig.readyTargets(in: providers)
        guard !ready.isEmpty else {
            showGroupSetup = true
            return
        }
        let members = template.instantiate(using: ready)
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

            let bookChats = conversations.filter { $0.activeBookFriend != nil }
            ForEach(bookChats) { chat in
                if let friend = chat.activeBookFriend {
                    HStack {
                        Button { SystemEntryRouter.shared.conversationID = chat.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.square").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: friend.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(verbatim: "\(friend.bookTitle) · \(friend.progressLabel(in: books.first { $0.id == friend.bookID }))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button { inviting = chat } label: { Label("邀请进群", systemImage: "person.2.badge.plus") }
                        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("好友操作")
                    }
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

            ForEach(books) { book in
                HStack(spacing: 12) {
                    Image(systemName: "text.book.closed.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: book.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("共 \(book.chapterTitles.count) 节 · \(ByteCountFormatter.string(fromByteCount: Int64(book.displayByteCount), countStyle: .file))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Button {
                            startKnowledgeChat(with: book)
                        } label: {
                            Text("知识问答")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.teal)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.teal.opacity(0.13), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            preselectedBookID = book.id
                            showBookFriends = true
                        } label: {
                            Text("创建角色")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    studyMetricItem(title: String(localized: "待复习"), value: "\(dueList.count)", tint: .indigo)
                    Divider().frame(height: 28)
                    studyMetricItem(title: String(localized: "总卡片"), value: "\(flashcardStore.cards.count)", tint: .primary)
                    Divider().frame(height: 28)
                    studyMetricItem(title: String(localized: "已熟记"), value: "\(flashcardStore.masteredCount)", tint: .green)
                    Spacer()
                }

                HStack(spacing: 10) {
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
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(flashcardStore.cards.isEmpty ? Color.secondary.opacity(0.35) : Color.indigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let ankiExportURL {
                    ShareLink(item: ankiExportURL) {
                        Label("点击分享或保存导出的 Anki 卡包 (.tsv)", systemImage: "doc.badge.arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.indigo)
                    }
                }
            }
            .padding(.vertical, 4)
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

    private func studyMetricItem(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .foregroundStyle(selected ? .indigo : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selected ? Color.indigo.opacity(0.15) : Color(.secondarySystemBackground),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func startStudyCoachChat(mode: StudyCoachMode) {
        let ready = ProviderConfig.readyTargets(in: providers).first
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

    private func startKnowledgeChat(with book: BookVolume) {
        let ready = ProviderConfig.readyTargets(in: providers).first
        let chat = Conversation(
            title: String(localized: "《\(book.title)》知识问答"),
            assistantEmoji: "📚",
            primaryTarget: ready
        )
        chat.assistanceSettings.knowledgeVolumeIDs = [book.id]
        modelContext.insert(chat)
        try? modelContext.save()
        SystemEntryRouter.shared.conversationID = chat.id
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
