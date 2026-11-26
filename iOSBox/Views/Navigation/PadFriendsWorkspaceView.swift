import SwiftData
import SwiftUI

/// Full-stage iPad Friends & Roundtables workspace featuring a dual-column directory and rich
/// character/memory inspector pane when wide, adapting cleanly to stacked list when narrow.
struct PadFriendsWorkspaceView: View {
    private enum Selection: Hashable {
        case persona(UUID)
        case bookFriend(BookFriendHistory.ID)
        case group(UUID)
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \PersonaProfile.name) private var profiles: [PersonaProfile]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var books: [BookVolume]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]

    @State private var preferences = AppPreferences.shared
    @State private var memoryStore = FriendMemoryStore.shared
    @State private var searchText = ""
    @State private var selection: Selection?
    @State private var editingMember: GroupMember?
    @State private var connectingModelForNewPersona = false
    @State private var removingProfile: PersonaProfile?
    @State private var showBookFriends = false
    @State private var preselectedBookID: UUID?
    @State private var showGroupSetup = false
    @State private var invitedProfile: GroupMember?
    @State private var invitingBookChat: Conversation?
    @State private var activeMemorySubject: FriendMemorySubject?
    @State private var createdChatID: UUID?
    @State private var errorMessage: String?

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredProfiles: [PersonaProfile] {
        guard !trimmedQuery.isEmpty else { return profiles }
        return profiles.filter { profile in
            let member = try? profile.member()
            return profile.name.localizedStandardContains(trimmedQuery)
                || (member?.title.localizedStandardContains(trimmedQuery) ?? false)
                || (member?.rolePrompt.localizedStandardContains(trimmedQuery) ?? false)
        }
    }

    private var filteredBookFriends: [BookFriendHistory] {
        let all = BookFriendHistory.grouped(conversations)
        guard !trimmedQuery.isEmpty else { return all }
        return all.filter { history in
            let friend = history.friend
            let book = books.first { $0.id == friend.bookID }
            return friend.name.localizedStandardContains(trimmedQuery)
                || friend.bookTitle.localizedStandardContains(trimmedQuery)
                || friend.progressLabel(in: book).localizedStandardContains(trimmedQuery)
        }
    }

    private var filteredGroups: [Conversation] {
        let groups = conversations.filter(\.isGroupMode)
        guard !trimmedQuery.isEmpty else { return groups }
        return groups.filter { chat in
            chat.title.localizedStandardContains(trimmedQuery)
                || chat.groupMembers.contains { $0.name.localizedStandardContains(trimmedQuery) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    directoryColumn
                        .frame(width: min(320, max(255, geometry.size.width * 0.34)))
                        .background(DS.Surface.grouped)
                    Divider()
                    detailColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.Surface.canvas)
                }
            } else {
                PhoneFriendsView()
            }
        }
        .navigationTitle("好友")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索好友或书名")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { startCreatingPersona() } label: {
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
        .onAppear { ensureSelection() }
        .onChange(of: profiles.count) { ensureSelection() }
        .onChange(of: conversations.count) { ensureSelection() }
        .sheet(item: $editingMember) { PersonaProfileEditor(draft: $0) }
        .sheet(isPresented: $connectingModelForNewPersona) {
            FirstModelSetupSheet { target in
                connectingModelForNewPersona = false
                editingMember = GroupMember(name: "", rolePrompt: "", target: target)
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
        .sheet(item: $invitingBookChat, onDismiss: routeCreatedChatIfNeeded) { chat in
            if let friend = chat.activeBookFriend {
                BookInvitationSheet(friend: friend) { opened in
                    createdChatID = opened.id
                    invitingBookChat = nil
                }
            }
        }
        .sheet(isPresented: $showGroupSetup, onDismiss: routeCreatedChatIfNeeded) {
            GroupCreationFlow(providers: providers, presets: presets) { created in
                createdChatID = created.id
                showGroupSetup = false
            }
        }
        .confirmationDialog(
            "删除人物档案？",
            isPresented: Binding(get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } }),
            presenting: removingProfile
        ) { profile in
            Button("删除人物档案", role: .destructive) {
                deletePersona(profile)
            }
        } message: { _ in
            Text("已有聊天会保留人物资料和历史回答。")
        }
        .alert("人物档案", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
    }

    private var directoryColumn: some View {
        List {
            Section("人物档案") {
                Button(action: startCreatingPersona) {
                    Label("新建人物档案", systemImage: "person.crop.circle.badge.plus")
                }

                ForEach(filteredProfiles) { profile in
                    let member = try? profile.member()
                    let isSelected = selection == .persona(profile.id)
                    let subject = FriendMemorySubject.persona(profile)
                    let memCount = memoryStore.activeVisibleEntryCount(for: subject)

                    Button {
                        selection = .persona(profile.id)
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            if let member {
                                PersonaAvatar(identity: PersonaByline(member), size: 36)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: profile.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let title = member?.title, !title.isEmpty {
                                    Text(verbatim: title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else if memCount > 0 {
                                    Text("\(memCount) 条共同记忆")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: profile.name))
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(isSelected ? theme.softFill : DS.Surface.card)
                            .padding(.vertical, 1)
                    )
                }
            }

            Section("书中好友") {
                Button {
                    preselectedBookID = books.first?.id
                    showBookFriends = true
                } label: {
                    Label("从书中创建好友", systemImage: "book.pages")
                }

                ForEach(filteredBookFriends) { history in
                    let friend = history.friend
                    let book = books.first { $0.id == friend.bookID }
                    let isSelected = selection == .bookFriend(history.id)

                    Button {
                        selection = .bookFriend(history.id)
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            DSIconTile(systemImage: "book.pages", tint: theme.readableText, size: 36, cornerRadius: DS.Radius.sm)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: friend.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("《\(friend.bookTitle)》 · \(friend.progressLabel(in: book))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(isSelected ? theme.softFill : DS.Surface.card)
                            .padding(.vertical, 1)
                    )
                }
            }

            if preferences.showsGroupChat {
                Section("圆桌群聊") {
                    Button { showGroupSetup = true } label: {
                        Label("发起圆桌群聊", systemImage: "person.3")
                    }

                    ForEach(filteredGroups) { group in
                        let isSelected = selection == .group(group.id)
                        Button {
                            selection = .group(group.id)
                        } label: {
                            HStack(spacing: DS.Spacing.sm) {
                                DSIconTile(systemImage: "person.3", tint: .indigo, size: 36, cornerRadius: DS.Radius.sm)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: group.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(group.groupMembers.map(\.name).joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                            .frame(minHeight: DS.TouchTarget.minimum)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .fill(isSelected ? theme.softFill : DS.Surface.card)
                                .padding(.vertical, 1)
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch selection {
        case .persona(let id):
            if let profile = profiles.first(where: { $0.id == id }) {
                personaDetail(profile)
            } else {
                emptyDetailState
            }
        case .bookFriend(let id):
            if let history = filteredBookFriends.first(where: { $0.id == id }) ?? BookFriendHistory.grouped(conversations).first(where: { $0.id == id }) {
                bookFriendDetail(history)
            } else {
                emptyDetailState
            }
        case .group(let id):
            if let group = conversations.first(where: { $0.id == id && $0.isGroupMode }) {
                groupDetail(group)
            } else {
                emptyDetailState
            }
        case nil:
            emptyDetailState
        }
    }

    private func personaDetail(_ profile: PersonaProfile) -> some View {
        let member = try? profile.member()
        let subject = FriendMemorySubject.persona(profile)
        let summary = memoryStore.visibleSummary(for: subject)
        let entries = memoryStore.visibleEntries(for: subject, includeDisabled: false)

        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                HStack(alignment: .top, spacing: DS.Spacing.lg) {
                    if let member {
                        PersonaAvatar(identity: PersonaByline(member), size: 60)
                    }
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(verbatim: profile.name)
                            .font(.system(.title2, design: .serif).weight(.bold))
                        if let title = member?.title, !title.isEmpty {
                            Text(verbatim: title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let model = member?.target {
                            Text(verbatim: "\(model.providerName) · \(model.modelDisplayName)")
                                .font(.caption)
                                .foregroundStyle(theme.readableText)
                        }
                    }
                    Spacer()
                    Menu {
                        Button("编辑人物档案") {
                            do { editingMember = try profile.member() } catch { errorMessage = error.localizedDescription }
                        }
                        Button("删除人物档案", role: .destructive) { removingProfile = profile }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                    }
                    .accessibilityLabel(Text("\(profile.name) 的人物操作"))
                }

                // Action pills
                HStack(spacing: DS.Spacing.sm) {
                    Button { openPrivateChat(profile) } label: {
                        Label("私聊", systemImage: "bubble.left.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.solidForeground)
                            .padding(.horizontal, DS.Spacing.lg)
                            .frame(minHeight: DS.TouchTarget.minimum)
                            .background(theme.solidFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("与 \(profile.name) 私聊"))

                    Button { activeMemorySubject = subject } label: {
                        FriendActionLabel(
                            title: entries.isEmpty ? "记忆" : "记忆 \(entries.count)",
                            icon: "brain.head.profile"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(profile.name) 的好友记忆"))

                    if preferences.showsGroupChat {
                        Button {
                            do { invitedProfile = try profile.member() } catch { errorMessage = error.localizedDescription }
                        } label: {
                            FriendActionLabel(title: "邀请进群", icon: "person.2.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("邀请 \(profile.name) 进群"))
                    }
                }

                if let prompt = member?.rolePrompt, !prompt.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("人物设定与说话风格")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: prompt)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
                }

                memoryOverviewCard(subject: subject, summary: summary, entries: entries, name: profile.name)

                if let persona = member?.persona, (!persona.materials.isEmpty || !persona.feeds.isEmpty) {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("参考资料与订阅来源")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(persona.materials) { material in
                            Label(material.title, systemImage: "doc.text")
                                .font(.subheadline)
                        }
                        ForEach(persona.feeds) { feed in
                            Label(feed.address, systemImage: "dot.radiowaves.up.forward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(DS.Spacing.xl)
        }
    }

    private func bookFriendDetail(_ history: BookFriendHistory) -> some View {
        let chat = history.chats[0]
        let friend = history.friend
        let book = books.first { $0.id == friend.bookID }
        let subject = FriendMemorySubject.bookFriend(friend)
        let summary = memoryStore.visibleSummary(for: subject)
        let entries = memoryStore.visibleEntries(for: subject, includeDisabled: false)

        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                HStack(alignment: .top, spacing: DS.Spacing.lg) {
                    DSIconTile(systemImage: "book.pages", tint: theme.readableText, size: 58, cornerRadius: DS.Radius.lg)
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(verbatim: friend.name)
                            .font(.system(.title2, design: .serif).weight(.bold))
                        Text("来自《\(friend.bookTitle)》 · \(friend.progressLabel(in: book))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: DS.Spacing.sm) {
                    Button {
                        SystemEntryRouter.shared.conversationID = chat.id
                    } label: {
                        Label("私聊", systemImage: "bubble.left.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.solidForeground)
                            .padding(.horizontal, DS.Spacing.lg)
                            .frame(minHeight: DS.TouchTarget.minimum)
                            .background(theme.solidFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("与 \(friend.name) 私聊"))

                    Button { activeMemorySubject = subject } label: {
                        FriendActionLabel(
                            title: entries.isEmpty ? "记忆" : "记忆 \(entries.count)",
                            icon: "brain.head.profile"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(friend.name) 的好友记忆"))

                    if preferences.showsGroupChat {
                        Button { invitingBookChat = chat } label: {
                            FriendActionLabel(title: "邀请进群", icon: "person.2.badge.plus")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("邀请 \(friend.name) 进群"))
                        .accessibilityIdentifier("friend.invite.\(chat.id)")
                    }
                }

                memoryOverviewCard(subject: subject, summary: summary, entries: entries, name: friend.name)

                if history.chats.count > 1 {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("不同阅读进度的对话")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(history.chats) { thread in
                            if let scope = thread.activeBookFriend {
                                Button {
                                    SystemEntryRouter.shared.conversationID = thread.id
                                } label: {
                                    HStack {
                                        Text(verbatim: scope.progressLabel(in: book))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(thread.updatedAt, format: .dateTime.month().day().hour().minute())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(minHeight: DS.TouchTarget.minimum)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(DS.Spacing.xl)
        }
    }

    private func groupDetail(_ group: Conversation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                HStack(spacing: DS.Spacing.lg) {
                    DSIconTile(systemImage: "person.3.fill", tint: .indigo, size: 58, cornerRadius: DS.Radius.lg)
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(verbatim: group.title)
                            .font(.system(.title2, design: .serif).weight(.bold))
                        Text("\(group.activeGroupMembers.count) 位活跃成员 · \(group.messages.count) 条消息")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        SystemEntryRouter.shared.conversationID = group.id
                    } label: {
                        Text("进入群聊")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.solidForeground)
                            .padding(.horizontal, DS.Spacing.lg)
                            .frame(minHeight: DS.TouchTarget.minimum)
                            .background(theme.solidFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("群成员阵容")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.groupMembers) { member in
                        HStack(spacing: DS.Spacing.md) {
                            Text(member.avatarEmoji)
                                .font(.title3)
                                .frame(width: 36, height: 36)
                                .background(Color(hex: member.accentHex).opacity(0.14), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: member.displayLabel)
                                    .font(.subheadline.weight(.semibold))
                                Text(verbatim: "\(member.target.providerName) · \(member.target.modelDisplayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(DS.Spacing.xl)
        }
    }

    private func memoryOverviewCard(subject: FriendMemorySubject, summary: String?, entries: [FriendMemoryEntry], name: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Label("好友持续记忆", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button("管理记忆") { activeMemorySubject = subject }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.readableText)
            }

            if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(verbatim: summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(DS.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }

            if entries.isEmpty {
                Text("暂无已保存的共同记忆。私聊或群聊中可自动提炼，也可点击「管理记忆」手动添加。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries.prefix(5)) { item in
                    HStack(alignment: .top, spacing: DS.Spacing.xs) {
                        Circle()
                            .fill(theme.tintColor)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(verbatim: item.content)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                }
                if entries.count > 5 {
                    Text("共 \(entries.count) 条记忆，点击右上角查看全部")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)
    }

    private var emptyDetailState: some View {
        ContentUnavailableView {
            Label("选择一位好友或创建角色", systemImage: "person.2")
        } description: {
            Text("创建独立人物档案，或从书架书籍中生成按阅读进度防剧透的书中好友，并支持邀请加入圆桌群聊。")
        } actions: {
            HStack(spacing: DS.Spacing.md) {
                Button("新建人物档案", action: startCreatingPersona)
                    .buttonStyle(.borderedProminent)
                Button("从书中创建好友") {
                    preselectedBookID = books.first?.id
                    showBookFriends = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func ensureSelection() {
        if let selection {
            switch selection {
            case .persona(let id) where profiles.contains(where: { $0.id == id }): return
            case .bookFriend(let id) where BookFriendHistory.grouped(conversations).contains(where: { $0.id == id }): return
            case .group(let id) where conversations.contains(where: { $0.id == id && $0.isGroupMode }): return
            default: break
            }
        }
        if let first = profiles.first {
            selection = .persona(first.id)
        } else if let firstBookFriend = BookFriendHistory.grouped(conversations).first {
            selection = .bookFriend(firstBookFriend.id)
        } else if let firstGroup = conversations.first(where: \.isGroupMode) {
            selection = .group(firstGroup.id)
        } else {
            selection = nil
        }
    }

    private func startCreatingPersona() {
        let ready = ProviderConfig.readyTargets(in: providers)
        if let target = AppPreferences.shared.initialTarget(from: ready) ?? ready.first {
            editingMember = GroupMember(name: "", rolePrompt: "", target: target)
        } else {
            connectingModelForNewPersona = true
        }
    }

    private func openPrivateChat(_ profile: PersonaProfile) {
        do {
            SystemEntryRouter.shared.conversationID = try PersonaLibrary.privateChat(with: profile, in: context).id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePersona(_ profile: PersonaProfile) {
        do {
            let deletedProfileID = profile.id
            try context.save()
            try context.transaction { context.delete(profile); try context.save() }
            if !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                SyncTombstoneStore.shared.recordDeletion(kind: .personaProfile, id: deletedProfileID)
                FriendMemoryStore.shared.removeMemoriesForPersona(profileID: deletedProfileID)
            }
            removingProfile = nil
            ensureSelection()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }

    private func routeCreatedChatIfNeeded() {
        guard let id = createdChatID else { return }
        createdChatID = nil
        SystemEntryRouter.shared.conversationID = id
    }
}
