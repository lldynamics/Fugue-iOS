import SwiftData
import SwiftUI

struct BookFriendsDirectorySection: View {
    let conversations: [Conversation]
    let books: [BookVolume]
    let allowsGroupInvitations: Bool
    var searchQuery: String = ""
    let onCreateBookFriend: () -> Void
    let onInviteBookFriend: (Conversation) -> Void
    var onOpenMemory: ((FriendMemorySubject) -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fallbackMemorySubject: FriendMemorySubject?
    @State private var memoryStore = FriendMemoryStore.shared

    private var theme: DS.AccentTheme { AppPreferences.shared.accentTheme }

    private var filteredHistories: [BookFriendHistory] {
        let all = BookFriendHistory.grouped(conversations)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { history in
            let friend = history.friend
            let book = books.first { $0.id == friend.bookID }
            return friend.name.localizedStandardContains(query)
                || friend.bookTitle.localizedStandardContains(query)
                || friend.progressLabel(in: book).localizedStandardContains(query)
        }
    }

    var body: some View {
        Section("书中好友") {
            Button(action: onCreateBookFriend) {
                Label("从书中创建好友", systemImage: "book.pages")
            }

            ForEach(filteredHistories) { history in
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
                    let subject = FriendMemorySubject.bookFriend(friend)
                    let activeCount = memoryStore.activeVisibleEntryCount(for: subject)
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        Button { SystemEntryRouter.shared.conversationID = chat.id } label: {
                            FriendActionLabel(title: "私聊", icon: "bubble.left")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("与 \(friend.name) 私聊"))
                        Button {
                            if let onOpenMemory { onOpenMemory(subject) }
                            else { fallbackMemorySubject = subject }
                        } label: {
                            FriendActionLabel(
                                title: activeCount > 0 ? "记忆 \(activeCount)" : "记忆",
                                icon: "brain.head.profile"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(friend.name) 的好友记忆"))
                        if allowsGroupInvitations {
                            Button { onInviteBookFriend(chat) } label: {
                                FriendActionLabel(title: "邀请进群", icon: "person.2.badge.plus")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("邀请 \(friend.name) 进群"))
                            .accessibilityIdentifier("friend.invite.\(chat.id)")
                        }
                    }
                }
            }
        }
        .sheet(item: $fallbackMemorySubject) { subject in
            FriendMemorySheet(subjects: [subject])
        }
    }
}

struct PhoneFriendsView: View {
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]

    @State private var preferences = AppPreferences.shared
    @State private var searchText = ""
    @State private var createPersonaTrigger = 0
    @State private var showBookFriends = false
    @State private var preselectedBookID: UUID?
    @State private var showGroupSetup = false
    @State private var invitedProfile: GroupMember?
    @State private var inviting: Conversation?
    @State private var activeMemorySubject: FriendMemorySubject?
    @State private var createdChatID: UUID?

    private var filteredGroupChats: [Conversation] {
        let groups = conversations.filter(\.isGroupMode)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.filter { chat in
            chat.title.localizedStandardContains(query)
                || chat.groupMembers.contains { $0.name.localizedStandardContains(query) }
        }
    }

    var body: some View {
        List {
            PersonaDirectorySection(
                invite: { invitedProfile = $0 },
                allowsGroupInvitations: preferences.showsGroupChat,
                searchQuery: searchText,
                triggerCreateCounter: createPersonaTrigger,
                onOpenMemory: { activeMemorySubject = $0 }
            )

            BookFriendsDirectorySection(
                conversations: conversations,
                books: books,
                allowsGroupInvitations: preferences.showsGroupChat,
                searchQuery: searchText,
                onCreateBookFriend: {
                    preselectedBookID = books.first?.id
                    showBookFriends = true
                },
                onInviteBookFriend: { inviting = $0 },
                onOpenMemory: { activeMemorySubject = $0 }
            )

            if preferences.showsGroupChat {
                Section("圆桌群聊") {
                    Button { showGroupSetup = true } label: {
                        Label("发起圆桌群聊", systemImage: "person.3")
                    }

                    ForEach(filteredGroupChats) { group in
                        Button { SystemEntryRouter.shared.conversationID = group.id } label: {
                            PhoneWorkspaceRow(
                                title: group.title,
                                subtitle: group.groupMembers.map(\.name).joined(separator: " · "),
                                symbol: "person.3"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.Surface.canvas)
        .navigationTitle("好友")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "搜索好友或书名"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { createPersonaTrigger += 1 } label: {
                        Label("新建人物档案", systemImage: "person.crop.circle.badge.plus")
                    }
                    Button {
                        preselectedBookID = books.first?.id
                        showBookFriends = true
                    } label: {
                        Label("从书中创建好友", systemImage: "book.pages")
                    }
                    if preferences.showsGroupChat {
                        Button { showGroupSetup = true } label: {
                            Label("发起圆桌群聊", systemImage: "person.3")
                        }
                    }
                } label: {
                    Label("添加好友", systemImage: "plus")
                }
                .accessibilityIdentifier("friends.addMenu")
            }
        }
        .sheet(isPresented: $showBookFriends, onDismiss: routeCreatedChatIfNeeded) {
            BookFriendSetupSheet(initialBookID: preselectedBookID) { chat in
                createdChatID = chat.id
                showBookFriends = false
            }
        }
        .sheet(item: $invitedProfile) { PersonaInvitationView(member: $0) }
        .sheet(item: $activeMemorySubject) { subject in
            FriendMemorySheet(subjects: [subject])
        }
        .sheet(item: $inviting, onDismiss: routeCreatedChatIfNeeded) { chat in
            if let friend = chat.activeBookFriend {
                BookInvitationSheet(friend: friend) { opened in
                    createdChatID = opened.id
                    inviting = nil
                }
            }
        }
        .sheet(isPresented: $showGroupSetup, onDismiss: routeCreatedChatIfNeeded) {
            GroupCreationFlow(providers: providers, presets: presets) { created in
                createdChatID = created.id
                showGroupSetup = false
            }
        }
    }

    private func routeCreatedChatIfNeeded() {
        guard let id = createdChatID else { return }
        createdChatID = nil
        SystemEntryRouter.shared.conversationID = id
    }
}
