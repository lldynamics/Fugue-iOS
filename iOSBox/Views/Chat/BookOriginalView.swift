import SwiftData
import SwiftUI

struct BookOriginalView: View {
    let volumeID: UUID
    let throughChapter: Int?
    let companionID: UUID?
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var savedState: ShelfReadingState?
    @Binding var request: ReadingRequest?
    @Binding var place: BookReadingPlace
    let openShelf: (() -> Void)?
    let quote: (ReadingCitation) -> Void

    @Query private var books: [BookVolume]
    @ScaledMetric(relativeTo: .body) private var readingSize: CGFloat = 25
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showNotes = false
    @State private var noteDraft: ReadingNoteDraft?
    @State private var selectionDraft: ReadingNoteDraft?
    @State private var chapters: [BookChapter] = []
    @State private var page: BookReadingPage?
    @State private var error: String?
    @State private var scrollID: Int?
    @State private var scrollRevision = 0
    @State private var restoring = false

    init(volumeID: UUID, throughChapter: Int?, request: Binding<ReadingRequest?>,
         place: Binding<BookReadingPlace>, companionID: UUID? = nil, openShelf: (() -> Void)?, quote: @escaping (ReadingCitation) -> Void) {
        self.volumeID = volumeID
        self.throughChapter = throughChapter
        self.companionID = companionID
        _request = request
        _place = place
        self.openShelf = openShelf
        self.quote = quote
        _books = Query(filter: #Predicate<BookVolume> { $0.id == volumeID })
    }

    private struct LoadKey: Equatable {
        let available: Bool
        let requestID: UUID?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let book = books.first {
                HStack {
                    if let openShelf {
                        Button(action: openShelf) { Label("书架", systemImage: "book") }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("reading.bookshelf")
                    } else {
                        if page == nil {
                            Label(book.title, systemImage: "book.pages").lineLimit(1)
                        } else {
                            Image(systemName: "book.pages").accessibilityHidden(true)
                        }
                    }
                    Spacer()
                    Button { showNotes = true } label: {
                        Label("阅读笔记", systemImage: "note.text")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("reading.notes")
                    if !chapters.isEmpty {
                        Menu {
                            Picker("章节", selection: Binding(get: { page?.chapterIndex ?? 0 },
                                                           set: { request = ReadingRequest(chapter: $0) })) {
                                ForEach(chapters.indices, id: \.self) { i in Text(verbatim: chapters[i].title).tag(i) }
                            }
                        } label: { Label("章节", systemImage: "list.bullet") }
                        .accessibilityIdentifier("reading.chapters")
                    }
                }
                .font(.subheadline.weight(.medium)).padding(.horizontal, 20).frame(minHeight: 48)
                if let page, chapters.indices.contains(page.chapterIndex) {
                    Text(verbatim: "\(book.title) · \(chapters[page.chapterIndex].title)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                        .accessibilityIdentifier("reading.location")
                }
                Divider()
            }
            if let error {
                ContentUnavailableView { Label("无法打开原文", systemImage: "book.closed") }
                    description: {
                        VStack(spacing: 12) {
                            Text(verbatim: error)
                            if let savedExcerpt { Text(verbatim: savedExcerpt).textSelection(.enabled) }
                        }
                    }
            } else if let page, chapters.indices.contains(page.chapterIndex) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            Text(verbatim: chapters[page.chapterIndex].title)
                                .font(.system(.largeTitle, design: .serif).weight(.bold))
                                .accessibilityAddTraits(.isHeader)
                                .id("reading.chapterStart")
                            if request?.citation != nil, !page.located {
                                Text("无法在当前阅读范围内定位这段引文。").font(.footnote).foregroundStyle(.secondary)
                                if let savedExcerpt { Text(verbatim: savedExcerpt).font(.callout).textSelection(.enabled) }
                            }
                            ForEach(page.paragraphs) { paragraph in
                                Text(formatted(paragraph))
                                    .font(widthClass == .regular ? .system(size: readingSize, design: .serif) : .system(.title3, design: .serif))
                                    .lineSpacing(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        if let citation = source(for: paragraph, chapter: page.chapterIndex) {
                                            Button("引用这段") { quote(citation) }
                                            Button("摘录与批注") { noteDraft = ReadingNoteDraft(citation: citation) }
                                            Button("选择文本") { selectionDraft = ReadingNoteDraft(citation: citation) }
                                        }
                                    }
                                    .id(paragraph.id)
                                    .accessibilityIdentifier(paragraph.highlight == nil ? "reading.paragraph.\(paragraph.id)" : "reading.highlight")
                            }
                            chapterFooter(at: page.chapterIndex)
                        }
                        .scrollTargetLayout()
                        .padding(widthClass == .regular ? 36 : 20)
                    }
                    .scrollPosition(id: $scrollID, anchor: .top)
                    .onChange(of: scrollID) { _, id in
                        if !restoring, let id, place.volumeID == volumeID { place.paragraph = id }
                    }
                    .task(id: scrollRevision) {
                        let target = place.paragraph ?? 0
                        await Task.yield()
                        if target > 0 || page.located {
                            proxy.scrollTo(target, anchor: .top)
                        } else {
                            proxy.scrollTo("reading.chapterStart", anchor: .top)
                        }
                        restoring = false
                    }
                }
                if page.located, let citation = request?.citation {
                    Button { quote(citation) } label: {
                        Label("就这段提问", systemImage: "text.quote").frame(minHeight: 44)
                    }
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("reading.quote")
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.Surface.canvas)
        .sheet(item: $noteDraft) { ReadingNoteEditor(draft: $0) }
        .sheet(item: $selectionDraft) { ReadingPassageSelection(source: $0.citation) }
        .sheet(isPresented: $showNotes) {
            NavigationStack {
                ReadingNotesView(volumeID: volumeID, throughChapter: throughChapter) { citation in
                    request = ReadingRequest(chapter: citation.chapterIndex, citation: citation)
                    showNotes = false
                }
            }
        }
        .onChange(of: place.paragraph) { _, _ in recordPosition() }
        .onChange(of: place.chapter) { _, _ in recordPosition() }
        .onDisappear { flushPosition() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { flushPosition() } }
        .task(id: LoadKey(available: !books.isEmpty, requestID: request?.id)) { await load() }
    }

    private func source(for paragraph: BookReadingPage.Paragraph, chapter: Int) -> ReadingCitation? {
        guard let book = books.first, chapters.indices.contains(chapter) else { return nil }
        return ReadingCitation(KnowledgePassage(id: 1, volumeID: book.id, documentTitle: book.title,
            sectionTitle: chapters[chapter].title, excerpt: paragraph.text,
            chapterIndex: chapter, utf16Offset: paragraph.utf16Offset))
    }

    private func chapterFooter(at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("第 \(index + 1) / \(chapters.count) 章")
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("reading.progress")
            let next = index + 1
            if chapters.indices.contains(next) {
                Button {
                    request = ReadingRequest(chapter: next)
                } label: {
                    HStack {
                        Text("下一章 · \(chapters[next].title)").multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "chevron.forward").accessibilityHidden(true)
                    }
                    .font(.headline)
                    .frame(minHeight: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("reading.nextChapter")
            }
        }
        .padding(.top, 8)
    }

    private var savedExcerpt: String? {
        guard let source = request?.citation else { return nil }
        if let throughChapter {
            guard let chapter = source.chapterIndex, chapter >= 0, chapter <= throughChapter else { return nil }
        }
        return source.excerpt
    }

    private func recordPosition() {
        guard let savedState, let companionID, savedState.conversationID == companionID,
              place.volumeID == volumeID, let paragraph = place.paragraph else { return }
        savedState.setPosition(chapter: place.chapter, paragraph: paragraph)
    }

    private func flushPosition() {
        recordPosition()
        guard savedState?.hasChanges == true else { return }
        do { try context.save() } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        guard let book = books.first else {
            chapters = []; page = nil; error = BookImportError.unavailable.localizedDescription
            return
        }
        do {
            if chapters.isEmpty {
                let data = book.manuscript, limit = throughChapter
                let decoded = try await Task.detached(priority: .userInitiated) {
                    try BookReadingPage.chapters(from: data, through: limit)
                }.value
                try Task.checkCancellation()
                chapters = decoded
            }
            if let companionID, savedState == nil {
                savedState = try BookLibrary.readingState(for: book, companionID: companionID, in: context)
                if place.volumeID != volumeID, request == nil, let state = savedState {
                    place = BookReadingPlace(volumeID: volumeID, chapter: state.chapter, paragraph: state.paragraph)
                }
            }
            let sameBook = place.volumeID == volumeID
            let newRequest = request != nil && (!sameBook || place.lastRequest != request?.id)
            let preferred = request?.chapter ?? (sameBook ? place.chapter : 0)
            let savedParagraph = sameBook ? place.paragraph : 0
            let allowed = chapters, citation = request?.citation
            let result = try await Task.detached(priority: .userInitiated) {
                try BookReadingPage.make(chapters: allowed, preferred: preferred, citation: citation)
            }.value
            try Task.checkCancellation()
            restoring = true
            let matched = result.paragraphs.first { $0.highlight != nil }?.id
            place = BookReadingPlace(volumeID: volumeID, chapter: result.chapterIndex,
                                     paragraph: result.clampedParagraph(newRequest ? matched : savedParagraph), lastRequest: request?.id)
            error = nil
            page = result
            scrollRevision += 1
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; page = nil }
    }

    private func formatted(_ paragraph: BookReadingPage.Paragraph) -> AttributedString {
        var text = AttributedString(paragraph.text)
        if let highlight = paragraph.highlight, let range = Range(highlight, in: paragraph.text),
           let start = AttributedString.Index(range.lowerBound, within: text), let end = AttributedString.Index(range.upperBound, within: text) {
            text[start..<end].backgroundColor = .orange.opacity(scheme == .dark ? 0.46 : 0.24)
            if paragraph.endsCitation, let number = request?.citation?.number {
                var marker = AttributedString(" [\(number)]")
                marker.font = .caption.weight(.semibold)
                marker.foregroundColor = DS.AccentTheme.amber.readableText
                text.insert(marker, at: end)
            }
        }
        return text
    }
}

struct ReadingCitationButton: View {
    let citation: ReadingCitation
    let open: (ReadingCitation) -> Void

    var body: some View {
        Button { open(citation) } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "\(citation.documentTitle) · \(citation.chapter) [\(citation.number)]").lineLimit(2)
                    Text(verbatim: citation.excerpt).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.forward").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(DS.AccentTheme.amber.readableText)
            .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 44)
            .background(DS.AccentTheme.amber.softFill, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reading.citation.\(citation.number)")
    }
}
