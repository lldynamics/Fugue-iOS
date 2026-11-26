import SwiftData
import SwiftUI

@MainActor
enum LibraryDiscussion {
    static func create(bookIDs: [UUID], preset: AssistantPreset?, target: ResolvedModelTarget?, context: ModelContext) throws -> Conversation {
        guard PersistenceController.canCommitUserData(in: context) else { throw BookImportError.cannotSave }
        var seen = Set<UUID>()
        let ids = bookIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty, ids.count <= 12 else { throw BookImportError.invalidBook }
        let books = try ids.map { id in
            guard let book = try BookLibrary.find(id, in: context) else { throw BookImportError.invalidBook }
            return book
        }
        let chat = Conversation(title: books.map(\.title).joined(separator: " · "), primaryTarget: target)
        if let preset { chat.applyPreset(preset) }
        chat.assistanceSettings.knowledgeVolumeIDs = ids
        context.insert(chat)
        do { try context.save() }
        catch { context.delete(chat); throw error }
        return chat
    }
}

struct LibraryDiscussionSheet: View {
    @Query(sort: \BookVolume.title) private var books: [BookVolume]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var chats: [Conversation]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var ids = Set<UUID>()
    @State private var presetID: UUID?
    @State private var error: String?
    let onCreate: (Conversation) -> Void

    private var previousSets: [Conversation] {
        var seen = Set<Set<UUID>>()
        let available = Set(books.map(\.id))
        return Array(chats.filter { chat in
            let set = Set(chat.assistanceSettings.knowledgeVolumeIDs)
            return set.count > 1 && set.isSubset(of: available) && seen.insert(set).inserted
        }.prefix(5))
    }

    var body: some View {
        NavigationStack {
            Form {
                if !previousSets.isEmpty {
                    Section("复用最近的书目") {
                        ForEach(previousSets) { chat in
                            Button(chat.title) {
                                ids = Set(chat.assistanceSettings.knowledgeVolumeIDs)
                                presetID = presets.first { $0.id == chat.assistantID }?.id
                            }
                        }
                    }
                }
                Picker("助手预设", selection: $presetID) {
                    Text("不使用助手").tag(UUID?.none)
                    ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Section("参考资料（最多 12 本）") {
                    ForEach(books) { book in
                        Button {
                            if !ids.insert(book.id).inserted { ids.remove(book.id) }
                        } label: {
                            HStack {
                                Text(verbatim: book.title)
                                Spacer()
                                Image(systemName: ids.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(ids.contains(book.id) ? .isSelected : [])
                        .disabled(!ids.contains(book.id) && ids.count >= 12)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("用一组资料新建对话")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("新建对话") {
                        do {
                            let target = AppPreferences.shared.initialTarget(from: ProviderConfig.readyTargets(in: providers))
                            let chat = try LibraryDiscussion.create(bookIDs: books.map(\.id).filter(ids.contains), preset: presets.first { $0.id == presetID }, target: target, context: context)
                            onCreate(chat)
                        } catch { self.error = error.localizedDescription }
                    }.disabled(ids.isEmpty)
                    .accessibilityIdentifier("library.createDiscussion")
                }
            }
        }
    }
}

struct LocalReadingSampleButton: View {
    @Environment(\.modelContext) private var context
    @State private var error: String?
    var body: some View {
        Button {
            do {
                let manuscript = BookManuscript(title: String(localized: "示例 · 雨后巡查"), chapters: [
                    BookChapter(title: String(localized: "现场观察"), text: String(localized: "雨停后，观察员沿溪向上走。桥下水位已经回落，东岸的石阶还湿着。\n\n她在记录里区分了亲眼看到的水痕和村民回忆的最高水位。")),
                    BookChapter(title: String(localized: "复核记录"), text: String(localized: "第二天复核时，观察员在同一位置拍照，并在照片背面记下日期与朝向。"))
                ])
                let book = try BookLibrary.store(PreparedBook(manuscript), in: context)
                let chat = try BookLibrary.companion(for: book, target: nil, in: context)
                SystemEntryRouter.shared.openOriginalForChatID = chat.id
                SystemEntryRouter.shared.conversationID = chat.id
            } catch { self.error = error.localizedDescription }
        } label: { Label("体验本地示例书摘", systemImage: "book.pages") }
        .accessibilityIdentifier("library.sample")
        .alert("无法打开原文", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
}
