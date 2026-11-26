import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BookFriendSetupSheet: View {
    var initialBookID: UUID? = nil
    let onOpen: (Conversation) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @State private var scope = BookFriendReadingScope()
    @State private var name = ""
    @State private var aliases = ""
    @State private var pickingFile = false
    @State private var removing = false
    @State private var working = false
    @State private var task: Task<Void, Never>?
    @State private var evidence: BookReplyEvidence?
    @State private var error: String?
    @State private var suggestionScope: BookFriendReadingScope?
    @State private var suggestions: [BookCharacterSuggestion] = []
    private var book: BookVolume? { books.first { $0.id == scope.bookID } }
    private var friend: BookFriend? { book.flatMap { try? BookFriend.make(book: $0, name: name, aliases: aliases, throughChapter: scope.throughChapter) } }

    var body: some View {
        NavigationStack {
            Form {
                if let book {
                    Section {
                        HStack {
                            Picker("书籍", selection: Binding(get: { scope.bookID }, set: selectBook)) {
                                ForEach(books) { book in Text(verbatim: book.title).tag(Optional(book.id)) }
                            }
                            Menu {
                                Button { pickingFile = true } label: { Label("从文件导入书籍", systemImage: "book.badge.plus") }
                                Button("从书架移除", role: .destructive) { removing = true }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel(Text("《\(book.title)》的书籍操作"))
                        }
                    }
                    Section {
                        TextField("角色姓名", text: $name)
                        TextField("其他称呼（可选）", text: $aliases)
                        BookChapterPicker(book: book, selection: $scope.throughChapter)
                    } header: { Text("创建书中好友") } footer: {
                        Text("可用逗号分隔别名。选定阅读进度后，只从该章及之前的正文查找人物。")
                    }
                    if suggestionScope == scope, !suggestions.isEmpty, evidence == nil {
                        Section("候选人物") {
                            ForEach(suggestions) { person in
                                Button { name = person.name; aliases = "" } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: person.name).font(.body.weight(.medium)).foregroundStyle(Color.accentColor)
                                            Text(verbatim: "\(person.chapter) · \(person.excerpt)")
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength: 4)
                                        Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    Section {
                        Button { pickingFile = true } label: { Label("从文件导入书籍", systemImage: "book.badge.plus") }
                    } header: { Text("我的书架") } footer: {
                        Text("支持 EPUB、TXT、Markdown 和带文字的 PDF。正文保存在本机，也会随完整备份导出。")
                    }
                }
                if let evidence {
                    Section {
                        ForEach(evidence.excerpts) { excerpt in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(verbatim: excerpt.chapter).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(verbatim: excerpt.text).font(.callout).lineLimit(5)
                            }
                        }
                    } header: { Text("找到的人物片段") } footer: {
                        Text("聊天时按话题选取最多三段原文，随消息发送给对话所用的模型。")
                    }
                }
                if working { ProgressView("正在读取书中资料…") }
                if let error { Text(verbatim: error).font(.callout).foregroundStyle(DS.StatusText.error) }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(working)
            .navigationTitle("书中好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(evidence == nil ? String(localized: "查找人物") : String(localized: "开始对话")) {
                        if evidence == nil { preview() } else { openChat() }
                    }.disabled(working || book == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("从书架移除这本书？", isPresented: $removing) {
                Button("从书架移除", role: .destructive) { removeBook() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已有聊天记录和引用会保留。继续与这本书的好友聊天时，需要重新导入同一版本。")
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.plainText, .pdf] +
                          ["epub", "docx", "xlsx", "pptx", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }) { result in
                switch result {
                case .success(let url): importBook(url)
                case .failure(let failure): if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
                }
            }
            .onAppear { if scope.bookID == nil { selectBook(initialBookID ?? books.first?.id) } }
            .onChange(of: friend) { _, _ in evidence = nil; error = nil }
            .task(id: scope) {
                let requested = scope
                guard let book, book.id == requested.bookID else { return }
                let data = book.manuscript
                let scan = Task.detached(priority: .utility) { try BookCharacterSuggestions.find(in: data, through: requested.throughChapter) }
                let result = try? await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                if !Task.isCancelled, scope == requested {
                    suggestions = result ?? []
                    suggestionScope = requested
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func selectBook(_ id: UUID?) {
        guard id != scope.bookID else { return }
        scope.select(id)
        name = ""
        aliases = ""
        evidence = nil
        error = nil
        suggestions = []
        suggestionScope = nil
    }

    private func importBook(_ url: URL) {
        perform {
            let reader = Task.detached(priority: .userInitiated) { try BookImporter.read(url) }
            let prepared = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            try Task.checkCancellation()
            let stored = try BookLibrary.store(prepared, in: context)
            selectBook(stored.id)
        }
    }

    private func preview() {
        guard let book else { return }
        perform {
            let identity = try BookFriend.make(book: book, name: name, aliases: aliases, throughChapter: scope.throughChapter)
            let preview = try await BookReferenceSearch.shared.reference(for: identity, manuscript: book.manuscript, question: "")
            try Task.checkCancellation()
            if friend == identity { evidence = preview }
        }
    }

    private func openChat() {
        guard let friend, evidence != nil else { return }
        do {
            let target = AppPreferences.shared.initialTarget(from: ProviderConfig.readyTargets(in: providers))
            let chat = try BookLibrary.open(friend, target: target, in: context)
            dismiss()
            onOpen(chat)
        } catch { self.error = error.localizedDescription }
    }

    private func removeBook() {
        guard let book else { return }
        do {
            let next = books.first(where: { $0.id != book.id })?.id
            try BookLibrary.remove(book, in: context)
            selectBook(next)
        } catch { self.error = error.localizedDescription }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil
        working = true
        task = Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
