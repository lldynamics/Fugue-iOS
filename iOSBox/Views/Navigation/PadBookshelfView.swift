import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Full-stage iPad Bookshelf space with hero continue-reading banner, multi-column book cover grid,
/// drag-and-drop file import, background OCR progress, semantic search, and reading notes.
struct PadBookshelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query private var readingStates: [ShelfReadingState]

    @State private var searchText = ""
    @State private var pickingBookFile = false
    @State private var importingBook = false
    @State private var isDropTargeted = false
    @State private var startingLibraryDiscussion = false
    @State private var showingReadingNotes = false
    @State private var showBookFriends = false
    @State private var preselectedBookID: UUID?
    @State private var bookToRemove: BookVolume?
    @State private var bookError: String?
    @State private var createdLibraryChatID: UUID?
    @State private var preferences = AppPreferences.shared
    @State private var ocrQueue = BackgroundPDFOCRQueue.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var savedChapterMap: [UUID: Int] {
        Dictionary(readingStates.map { ($0.bookID, $0.chapter) }, uniquingKeysWith: { first, _ in first })
    }

    private var filteredBooks: [BookVolume] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return books }
        return books.filter { book in
            book.title.localizedStandardContains(query)
                || book.chapterTitles.contains(where: { $0.localizedStandardContains(query) })
        }
    }

    private var activeReadingSession: (book: BookVolume, chat: Conversation, chapterTitle: String?, chapterIndex: Int)? {
        guard !books.isEmpty else { return nil }
        for chat in conversations {
            guard let id = chat.readingVolumeID,
                  let book = books.first(where: { $0.id == id }),
                  chat.isCompanion(for: id) else { continue }
            let index = savedChapterMap[id] ?? 0
            let chapter = book.chapterTitles.indices.contains(index) ? book.chapterTitles[index] : nil
            return (book, chat, chapter, index)
        }
        return nil
    }

    private static let coverAccents: [DS.AccentTheme] = [.vermilion, .teal, .cobalt, .amber, .indigo, .graphite]

    private func coverColor(for book: BookVolume) -> Color {
        let hash = book.id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Self.coverAccents[abs(hash) % Self.coverAccents.count].solidFill
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                if let session = activeReadingSession, searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continueReadingBanner(session)
                }

                if !ocrQueue.orderedJobs.isEmpty {
                    ocrJobsSection
                }

                if books.isEmpty {
                    emptyShelfState
                } else if filteredBooks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("我的书架（\(filteredBooks.count)）")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("支持拖入 EPUB、PDF、TXT、Markdown、Office 文档")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        let columns = [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 228, maximum: 320), spacing: DS.Spacing.lg, alignment: .top)]
                        LazyVGrid(columns: columns, spacing: DS.Spacing.lg) {
                            ForEach(filteredBooks) { book in
                                bookCard(book, savedChapter: savedChapterMap[book.id])
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.vertical, DS.Spacing.lg)
        }
        .background(DS.Surface.canvas.ignoresSafeArea())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(theme.tintColor, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(theme.softFill.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                    .overlay {
                        Label("松开即可导入到书架", systemImage: "book.badge.plus")
                            .font(.headline)
                            .foregroundStyle(theme.readableText)
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.md)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(DS.Spacing.lg)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            importBookToShelf(first)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索书名或章节")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !books.isEmpty {
                    NavigationLink {
                        SemanticShelfView()
                    } label: {
                        Label("书架语义检索", systemImage: "sparkle.magnifyingglass")
                    }
                    .accessibilityIdentifier("bookshelf.semanticSearch")

                    Button {
                        startingLibraryDiscussion = true
                    } label: {
                        Label("用一组资料新建对话", systemImage: "books.vertical")
                    }
                }

                Button {
                    showingReadingNotes = true
                } label: {
                    Label("阅读笔记", systemImage: "book.and.pencil")
                }

                Button {
                    pickingBookFile = true
                } label: {
                    if importingBook {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("从文件导入书籍", systemImage: "plus")
                    }
                }
                .disabled(importingBook)
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
        .sheet(isPresented: $startingLibraryDiscussion, onDismiss: routeCreatedLibraryChatIfNeeded) {
            LibraryDiscussionSheet { chat in
                createdLibraryChatID = chat.id
                startingLibraryDiscussion = false
            }
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

    private func continueReadingBanner(_ session: (book: BookVolume, chat: Conversation, chapterTitle: String?, chapterIndex: Int)) -> some View {
        let total = max(session.book.chapterTitles.count, 1)
        let progress = Double(min(session.chapterIndex + 1, total)) / Double(total)
        let spineColor = coverColor(for: session.book)

        return HStack(spacing: DS.Spacing.lg) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(spineColor)
                    .frame(width: 54, height: 74)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.black.opacity(0.16))
                            .frame(width: 6)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    }
                Text(verbatim: String(session.book.title.prefix(4)))
                    .font(.system(.caption2, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(6)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("继续阅读")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.readableText)

                Text(verbatim: session.book.title)
                    .font(.system(.title3, design: .serif).weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let chapterTitle = session.chapterTitle, !chapterTitle.isEmpty {
                    Text("上次读到 \(chapterTitle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: progress)
                    .tint(spineColor)
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                Button {
                    SystemEntryRouter.shared.openOriginalForChatID = session.chat.id
                    SystemEntryRouter.shared.conversationID = session.chat.id
                } label: {
                    Text("继续阅读")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, DS.Spacing.lg)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .background(theme.solidFill, in: Capsule())
                        .foregroundStyle(theme.solidForeground)
                }
                .buttonStyle(.plain)
                .hoverEffect(.lift)
                .accessibilityIdentifier("workspace.workshop.resumeReading")
            }
        }
        .padding(DS.Spacing.lg)
        .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Surface.hairline, lineWidth: 1))
    }

    private var ocrJobsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
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
                .dsCard(cornerRadius: DS.Radius.md, fill: DS.Surface.card)
            }
        }
    }

    private var emptyShelfState: some View {
        VStack(spacing: DS.Spacing.lg) {
            ContentUnavailableView {
                Label("书架中暂无文档", systemImage: "books.vertical")
            } description: {
                Text("支持 EPUB、TXT、Markdown 和 PDF（含扫描版离线文字识别）。可直接把文件拖到这里，或先体验本地示例书摘。")
            } actions: {
                HStack(spacing: DS.Spacing.md) {
                    Button {
                        pickingBookFile = true
                    } label: {
                        Label("从文件导入书籍", systemImage: "book.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                    LocalReadingSampleButton()
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func bookCard(_ book: BookVolume, savedChapter: Int?) -> some View {
        let totalChapters = max(book.chapterTitles.count, 1)
        let currentIndex = savedChapter.map { min(max(0, $0), totalChapters - 1) }
        let progress = currentIndex.map { Double($0 + 1) / Double(totalChapters) } ?? 0
        let coverTint = coverColor(for: book)

        return VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // Literary cover header
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(coverTint)
                    .frame(height: 112)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.black.opacity(0.15))
                            .frame(width: 10)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                    }
                    .overlay(alignment: .topTrailing) {
                        Text("共 \(book.chapterTitles.count) 节")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.18), in: Capsule())
                            .padding(10)
                    }

                Text(verbatim: book.title)
                    .font(.system(.headline, design: .serif).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .contentShape(Rectangle())
            .onTapGesture { startKnowledgeChat(with: book) }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if let index = currentIndex, !book.chapterTitles.isEmpty {
                    let title = book.chapterTitles[index]
                    Text("上次读到 \(title.isEmpty ? String(localized: "第 \(index + 1) 节") : title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("shelf.progress")
                } else {
                    Text("尚未开始阅读")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: progress)
                    .tint(coverTint)
            }

            HStack(spacing: DS.Spacing.xs) {
                Button {
                    startKnowledgeChat(with: book)
                } label: {
                    Text(savedChapter == nil ? String(localized: "开始阅读") : String(localized: "继续阅读"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.readableText)
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                        .background(theme.softFill, in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel(savedChapter == nil ? Text("开始阅读《\(book.title)》") : Text("继续阅读《\(book.title)》"))

                Menu {
                    Button { startKnowledgeChat(with: book, newDiscussion: true) } label: {
                        Label("新开讨论", systemImage: "square.and.pencil")
                    }
                    Button {
                        preselectedBookID = book.id
                        showBookFriends = true
                    } label: {
                        Label("创建角色", systemImage: "person.badge.plus")
                    }
                    Divider()
                    Button(role: .destructive) {
                        bookToRemove = book
                    } label: {
                        Label("从书架移除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        .background(DS.Surface.subtle, in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel(Text("《\(book.title)》的书籍操作"))
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(DS.Surface.hairline, lineWidth: 1))
        .contextMenu {
            Button { startKnowledgeChat(with: book) } label: {
                Label(savedChapter == nil ? String(localized: "开始阅读") : String(localized: "继续阅读"), systemImage: "book")
            }
            Button { startKnowledgeChat(with: book, newDiscussion: true) } label: {
                Label("新开讨论", systemImage: "square.and.pencil")
            }
            Button {
                preselectedBookID = book.id
                showBookFriends = true
            } label: {
                Label("创建角色", systemImage: "person.badge.plus")
            }
            Divider()
            Button(role: .destructive) {
                bookToRemove = book
            } label: {
                Label("从书架移除", systemImage: "trash")
            }
        }
    }

    private func routeCreatedLibraryChatIfNeeded() {
        guard let id = createdLibraryChatID else { return }
        createdLibraryChatID = nil
        SystemEntryRouter.shared.conversationID = id
    }

    private func startKnowledgeChat(with book: BookVolume, newDiscussion: Bool = false) {
        do {
            let target = preferences.initialTarget(from: ProviderConfig.readyTargets(in: providers))
            let chat = try BookLibrary.companion(for: book, newDiscussion: newDiscussion, target: target, in: modelContext)
            SystemEntryRouter.shared.openOriginalForChatID = newDiscussion ? nil : chat.id
            SystemEntryRouter.shared.conversationID = chat.id
        } catch {
            bookError = error.localizedDescription
        }
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
}
