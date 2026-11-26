import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ReadingNoteDraft: Identifiable {
    let id: UUID
    let citation: ReadingCitation
    let original: ReadingAnnotation.Snapshot?

    init(citation: ReadingCitation, original: ReadingAnnotation.Snapshot? = nil) {
        id = original?.id ?? UUID()
        self.citation = citation
        self.original = original
    }
}

struct ReadingPassageSelection: View {
    let source: ReadingCitation
    @Environment(\.dismiss) private var dismiss
    @State private var offlineText: String?
    @State private var selectedRange: NSRange?
    @State private var note: ReadingNoteDraft?

    var body: some View {
        if let offlineText {
            NavigationStack { ModelWorkshop(mode: .local, input: offlineText) }
        } else if let note {
            ReadingNoteEditor(draft: note)
        } else {
            NavigationStack {
                SelectableTextRepresentable(text: source.excerpt, selection: .constant(nil),
                    selectedRange: $selectedRange, identifier: "reading.selectText")
                    .navigationTitle("选择文本")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                        ToolbarItem(placement: .bottomBar) {
                            Button("本机处理") { offlineText = source.selecting(selectedRange)?.excerpt }.disabled(source.selecting(selectedRange) == nil)
                        }
                        ToolbarItem(placement: .bottomBar) {
                            Button("摘录与批注") {
                                if let citation = source.selecting(selectedRange) { note = ReadingNoteDraft(citation: citation) }
                            }
                            .disabled(source.selecting(selectedRange) == nil)
                            .accessibilityIdentifier("reading.saveSelection")
                        }
                    }
            }
        }
    }
}

struct ReadingNoteEditor: View {
    let draft: ReadingNoteDraft
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?

    init(draft: ReadingNoteDraft) {
        self.draft = draft
        _text = State(initialValue: draft.original?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: draft.citation.excerpt).textSelection(.enabled)
                        .accessibilityIdentifier("reading.noteExcerpt")
                } header: { Text(verbatim: "《\(draft.citation.documentTitle)》 · \(draft.citation.chapter)") }
                Section("批注") {
                    TextField("可选，写下你的想法", text: $text, axis: .vertical).lineLimit(4...12)
                        .accessibilityIdentifier("reading.noteText")
                }
                if let error { Text(verbatim: error).foregroundStyle(.red) }
            }
            .navigationTitle("摘录与批注")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(text.count > 16_000)
                }
            }
        }
    }

    private func save() {
        let citation = draft.citation
        guard let chapter = citation.chapterIndex, let offset = citation.utf16Offset else { return }
        let saved = ReadingAnnotation.Snapshot(id: draft.id, volumeID: citation.volumeID, bookTitle: citation.documentTitle,
            chapterTitle: citation.chapter, chapterIndex: chapter, utf16Offset: offset, excerpt: citation.excerpt,
            note: text.trimmingCharacters(in: .whitespacesAndNewlines), updatedAt: Date())
        do {
            guard saved.isValid, PersistenceController.canCommitUserData(in: context) else { throw BookImportError.cannotSave }
            let id = saved.id
            try context.transaction {
                if draft.original != nil {
                    guard let latest = try context.fetch(FetchDescriptor<ReadingAnnotation>(predicate: #Predicate { $0.id == id })).first,
                          latest.snapshot == draft.original else { throw BookImportError.cannotSave }
                    latest.apply(saved)
                } else {
                    context.insert(ReadingAnnotation(saved))
                }
                try context.save()
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ReadingNotesView: View {
    var volumeID: UUID?
    var throughChapter: Int?
    let openOriginal: (ReadingCitation) -> Void
    @Query(sort: [SortDescriptor(\ReadingAnnotation.bookTitle), SortDescriptor(\ReadingAnnotation.chapterIndex),
                  SortDescriptor(\ReadingAnnotation.utf16Offset)]) private var notes: [ReadingAnnotation]
    @Query private var books: [BookVolume]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var edit: ReadingNoteDraft?
    @State private var removal: ReadingAnnotation.Snapshot?
    @State private var error: String?
    @State private var exportDocument: ReadingNotesDocument?

    private var visible: [ReadingAnnotation] {
        notes.filter { item in
            (volumeID == nil || item.volumeID == volumeID) && (throughChapter.map { item.chapterIndex <= $0 } ?? true)
        }
    }

    var body: some View {
        let entries = visible
        let sections = Dictionary(grouping: entries, by: \.volumeID).values.sorted {
            ($0[0].bookTitle, $0[0].volumeID.uuidString) < ($1[0].bookTitle, $1[0].volumeID.uuidString)
        }
        List {
            if entries.isEmpty {
                ContentUnavailableView("暂无摘录", systemImage: "book.pages", description: Text("在书中长按段落，选择「摘录与批注」。"))
            }
            ForEach(sections, id: \.first?.volumeID) { group in
                Section {
                    ForEach(group) { entry in
                        let snapshot = entry.snapshot
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: entry.chapterTitle).font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: entry.excerpt).textSelection(.enabled)
                            if !entry.note.isEmpty { Text(verbatim: entry.note).font(.callout).foregroundStyle(.secondary) }
                            HStack {
                                if books.contains(where: { $0.id == entry.volumeID }) {
                                    Button("回到原文") { openOriginal(snapshot.citation) }
                                } else { Text("原书已移除").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Button("编辑批注") { edit = .init(citation: snapshot.citation, original: snapshot) }
                            }
                            .buttonStyle(.borderless)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { removal = snapshot }
                        }
                    }
                } header: { Text(verbatim: group[0].bookTitle) }
            }
        }
        .navigationTitle("阅读笔记")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportDocument = ReadingNotesDocument(markdown: ReadingAnnotation.markdown(entries.map(\.snapshot)))
                } label: { Label("导出 Markdown", systemImage: "square.and.arrow.up") }
                .disabled(entries.isEmpty)
            }
        }
        .sheet(item: $edit) { ReadingNoteEditor(draft: $0) }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: ReadingNotesDocument.markdownType,
                      defaultFilename: String(localized: "阅读笔记") + ".md") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .confirmationDialog("删除这条摘录及批注？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                            presenting: removal) { item in
            Button("删除", role: .destructive) {
                do {
                    let id = item.id
                    try context.transaction {
                        if let note = try context.fetch(FetchDescriptor<ReadingAnnotation>(predicate: #Predicate { $0.id == id })).first {
                            context.delete(note)
                            try context.save()
                        }
                    }
                    if !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                        SyncTombstoneStore.shared.recordDeletion(kind: .readingAnnotation, id: id)
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
        .alert("无法更新阅读笔记", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { }
        } message: { Text(error ?? "") }
    }
}

private struct ReadingNotesDocument: FileDocument {
    static let markdownType = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [markdownType] }
    let markdown: String
    init(markdown: String) { self.markdown = markdown }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        markdown = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(markdown.utf8))
    }
}

struct ShelfReadingNotesSheet: View {
    let quote: (ReadingCitation) -> Void
    @State private var source: ReadingCitation?
    @State private var request: ReadingRequest?
    @State private var place = BookReadingPlace()

    var body: some View {
        NavigationStack {
            ReadingNotesView { citation in
                request = ReadingRequest(chapter: citation.chapterIndex, citation: citation)
                source = citation
            }
            .navigationDestination(isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } })) {
                if let source {
                    BookOriginalView(volumeID: source.volumeID, throughChapter: nil, request: $request, place: $place,
                                     openShelf: nil, quote: quote)
                }
            }
        }
    }
}
