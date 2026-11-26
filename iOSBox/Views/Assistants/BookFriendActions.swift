import SwiftData
import SwiftUI

struct BookChapterPicker: View {
    let book: BookVolume
    var minimum = 0
    @Binding var selection: Int?

    var body: some View {
        Picker("阅读进度", selection: $selection) {
            Text("全书").tag(nil as Int?)
            ForEach(book.chapterTitles.indices.dropFirst(max(0, minimum)), id: \.self) { i in
                Text(verbatim: book.chapterTitles[i]).tag(Optional(i))
            }
        }
        .pickerStyle(.navigationLink)
        .accessibilityIdentifier("book.chapterPicker")
    }
}

struct BookChatHeading: View {
    let friend: BookFriend
    let title: String
    let action: () -> Void
    @Query private var books: [BookVolume]

    init(friend: BookFriend, title: String, action: @escaping () -> Void) {
        self.friend = friend
        self.title = title
        self.action = action
        let id = friend.bookID
        _books = Query(filter: #Predicate<BookVolume> { $0.id == id })
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(verbatim: title).font(.headline)
                HStack(spacing: 3) {
                    Text(verbatim: "《\(friend.bookTitle)》 · \(friend.progressLabel(in: books.first))")
                    Image(systemName: "chevron.down")
                }.font(.caption).foregroundStyle(.secondary)
            }.lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bookChat.progress")
        .accessibilityHint("调整阅读进度")
    }
}

struct BookReadingProgressSheet: View {
    let chat: Conversation
    let onOpen: (Conversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selected: Int?
    @State private var error: String?
    @Query private var books: [BookVolume]

    init(chat: Conversation, friend: BookFriend, onOpen: @escaping (Conversation) -> Void) {
        self.chat = chat
        self.onOpen = onOpen
        _selected = State(initialValue: friend.throughChapter)
        let id = friend.bookID
        _books = Query(filter: #Predicate<BookVolume> { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let book = books.first, let friend = chat.activeBookFriend {
                    let last = book.chapterTitles.count - 1
                    let rewind = (selected ?? last) < (friend.throughChapter ?? last)
                    Section {
                        BookChapterPicker(book: book, selection: $selected)
                    } header: { Text(verbatim: book.title) } footer: {
                        if rewind { Text("较晚章节可能已出现在原聊天。新对话将从空白记录开始，原聊天会保留。") }
                    }
                    Button(rewind ? String(localized: "从该章另开对话") : String(localized: "更新阅读进度")) {
                        do {
                            let result = try BookLibrary.changeProgress(in: chat, through: selected, context: context)
                            dismiss()
                            if result.id != chat.id { onOpen(result) }
                        } catch { self.error = error.localizedDescription }
                    }.disabled(selected == friend.throughChapter)
                } else { Text(verbatim: BookImportError.unavailable.localizedDescription) }
                if let error { Text(verbatim: error).foregroundStyle(DS.StatusText.error) }
            }
            .navigationTitle("阅读进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct BookInvitationButton<Content: View>: View {
    let friend: BookFriend
    let members: [GroupMember]
    let book: BookVolume?
    let invite: (BookFriend?) -> Void
    @ViewBuilder let label: (BookFriend) -> Content
    @State private var pending: BookFriend?

    var body: some View {
        let group = BookGroupRoster.groupVersion(of: friend, in: members)
        Button {
            if BookGroupRoster.expandsProgress(from: friend, to: group) { pending = group }
            else { invite(nil) }
        } label: { label(group) }
        .confirmationDialog("使用群内阅读进度？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { accepted in
            Button("按此进度邀请") { invite(accepted) }
            Button("取消", role: .cancel) {}
        } message: { accepted in
            Text("个人对话：\(friend.progressLabel(in: book))。群聊：\(accepted.progressLabel(in: book))。群内回复可能提到后续情节。")
        }
    }
}

struct BookGroupFriendPicker: View {
    let conversations: [Conversation]
    let books: [BookVolume]
    let members: [GroupMember]
    let onPick: (BookFriend, BookFriend?) -> Void
    @Environment(\.dismiss) private var dismiss

    private var choices: [Conversation] {
        var seen: [UUID: Set<String>] = [:]
        return conversations.filter { chat in
            guard let friend = chat.activeBookFriend, books.contains(where: { $0.id == friend.bookID }) else { return false }
            return seen[friend.bookID, default: []].insert(friend.name.lowercased()).inserted
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if choices.isEmpty {
                    Text("先在「书中好友」导入书籍并创建一个人物。")
                }
                ForEach(choices) { chat in
                    if let friend = chat.activeBookFriend {
                        let joined = members.contains { $0.bookFriend?.isSameCharacter(as: friend) == true }
                        let book = books.first { $0.id == friend.bookID }
                        BookInvitationButton(friend: friend, members: members, book: book) { accepted in
                            onPick(friend, accepted)
                            dismiss()
                        } label: { group in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(verbatim: friend.name)
                                    Text(verbatim: "\(friend.bookTitle) · \(group.progressLabel(in: book))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if joined { Image(systemName: "checkmark").accessibilityLabel("已在群中") }
                            }
                        }.disabled(joined)
                    }
                }
            }
            .navigationTitle("从好友选择")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct GroupModelGate<Content: View>: View {
    @State private var needsConnection: Bool
    let content: Content
    init(providers: [ProviderConfig], @ViewBuilder content: () -> Content) {
        _needsConnection = State(initialValue: ProviderConfig.readyTargets(in: providers).isEmpty)
        self.content = content()
    }
    var body: some View {
        if needsConnection { FirstModelSetupSheet(continuesToGroup: true) { _ in needsConnection = false } }
        else { content }
    }
}

struct GroupCreationFlow: View {
    let providers: [ProviderConfig]
    let presets: [AssistantPreset]
    var invitedFriend: BookFriend? = nil
    var invitedProfile: GroupMember? = nil
    let onCreated: (Conversation) -> Void

    var body: some View {
        GroupModelGate(providers: providers) {
            GroupSetupSheet(invitedFriend: invitedFriend, invitedProfile: invitedProfile, providers: providers, presets: presets, onCreated: onCreated)
        }
    }
}

struct BookInvitationSheet: View {
    let friend: BookFriend
    let onOpen: (Conversation) -> Void
    @Query private var books: [BookVolume]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var chats: [Conversation]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var created: Conversation?
    @State private var error: String?

    var body: some View {
        GroupModelGate(providers: providers) {
            NavigationStack {
                List {
                    Button { creating = true } label: { Label("创建读书群", systemImage: "person.2.badge.plus") }
                    Section {
                        ForEach(chats.filter(\.isGroupMode)) { group in
                            let joined = group.groupMembers.contains { $0.bookFriend?.isSameCharacter(as: friend) == true }
                            let full = group.groupMembers.count >= 6
                            let book = books.first { $0.id == friend.bookID }
                            BookInvitationButton(friend: friend, members: group.groupMembers, book: book) { accepted in
                                do {
                                    try BookLibrary.invite(friend, to: group, providers: providers, in: context, confirmedProgress: accepted)
                                    finish(group)
                                } catch { self.error = error.localizedDescription }
                            } label: { projected in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(verbatim: group.title)
                                        Text(verbatim: projected.progressLabel(in: book)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if joined { Text("已在群中").font(.caption) }
                                    else if full { Text("群成员已满").font(.caption) }
                                }
                            }.disabled(joined || full)
                        }
                    } header: { Text("邀请到已有群聊") } footer: {
                        Text("只带入人物和原书资料。群聊单独保存阅读进度和聊天记录。")
                    }
                    if let error { Text(verbatim: error).foregroundStyle(DS.StatusText.error) }
                }
                .navigationTitle("邀请进群")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .sheet(isPresented: $creating, onDismiss: { if let created { finish(created) } }) {
                    GroupCreationFlow(providers: providers, presets: presets, invitedFriend: friend) { created = $0 }
                }
            }
        }
    }

    private func finish(_ chat: Conversation) {
        dismiss()
        onOpen(chat)
    }
}
