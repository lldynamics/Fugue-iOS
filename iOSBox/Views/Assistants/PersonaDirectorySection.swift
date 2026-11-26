import SwiftUI
import SwiftData

struct PersonaDirectorySection: View {
    let invite: (GroupMember) -> Void
    let allowsGroupInvitations: Bool
    var searchQuery: String = ""
    var triggerCreateCounter: Int = 0
    var onOpenMemory: ((FriendMemorySubject) -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \PersonaProfile.name) private var profiles: [PersonaProfile]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @State private var editing: GroupMember?
    @State private var fallbackMemorySubject: FriendMemorySubject?
    @State private var removing: PersonaProfile?
    @State private var connecting = false
    @State private var error: String?
    @State private var memoryStore = FriendMemoryStore.shared

    private var filteredProfiles: [PersonaProfile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { profile in
            let member = try? profile.member()
            return profile.name.localizedStandardContains(query)
                || (member?.title.localizedStandardContains(query) ?? false)
                || (member?.rolePrompt.localizedStandardContains(query) ?? false)
        }
    }

    var body: some View {
        Section("人物档案") {
            Button(action: startCreatingPersona) {
                Label("新建人物档案", systemImage: "person.crop.circle.badge.plus")
            }

            ForEach(filteredProfiles) { profile in
                let member = try? profile.member()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { openPrivateChat(profile) } label: {
                            HStack {
                                if let member { PersonaAvatar(identity: PersonaByline(member), size: 38) }
                                VStack(alignment: .leading) {
                                    Text(verbatim: profile.name).font(.headline)
                                    if let title = member?.title, !title.isEmpty {
                                        Text(verbatim: title).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: profile.name))
                        .accessibilityHint("私聊")
                        Spacer()
                        Menu {
                            Button("好友记忆") { presentMemory(.persona(profile)) }
                            Button("编辑人物档案") { do { editing = try profile.member() } catch { self.error = error.localizedDescription } }
                            Button("删除人物档案", role: .destructive) { removing = profile }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel(Text("\(profile.name) 的人物操作"))
                    }
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout { actions(for: profile) }
                }
            }
        }
        .sheet(item: $editing) { PersonaProfileEditor(draft: $0) }
        .sheet(item: $fallbackMemorySubject) { subject in FriendMemorySheet(subjects: [subject]) }
        .sheet(isPresented: $connecting) { FirstModelSetupSheet { target in connecting = false; create(using: target) } }
        .confirmationDialog("删除人物档案？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { profile in
            Button("删除人物档案", role: .destructive) {
                do {
                    let deletedProfileID = profile.id
                    try context.save()
                    try context.transaction { context.delete(profile); try context.save() }
                    if !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                        SyncTombstoneStore.shared.recordDeletion(kind: .personaProfile, id: deletedProfileID)
                        FriendMemoryStore.shared.removeMemoriesForPersona(profileID: deletedProfileID)
                    }
                } catch { context.rollback(); self.error = error.localizedDescription }
            }
        } message: { _ in Text("已有聊天会保留人物资料和历史回答。") }
        .alert("人物档案", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(verbatim: error ?? "") }
        .onChange(of: triggerCreateCounter) { _, _ in
            startCreatingPersona()
        }
    }

    private func startCreatingPersona() {
        let ready = ProviderConfig.readyTargets(in: providers)
        if let target = AppPreferences.shared.initialTarget(from: ready) ?? ready.first { create(using: target) }
        else { connecting = true }
    }

    private func create(using target: ResolvedModelTarget) {
        editing = GroupMember(name: "", rolePrompt: "", target: target)
    }

    private func openPrivateChat(_ profile: PersonaProfile) {
        do {
            SystemEntryRouter.shared.conversationID = try PersonaLibrary.privateChat(with: profile, in: context).id
        } catch { self.error = error.localizedDescription }
    }

    private func presentMemory(_ subject: FriendMemorySubject) {
        if let onOpenMemory {
            onOpenMemory(subject)
        } else {
            fallbackMemorySubject = subject
        }
    }

    @ViewBuilder
    private func actions(for profile: PersonaProfile) -> some View {
        let subject = FriendMemorySubject.persona(profile)
        let activeCount = memoryStore.activeVisibleEntryCount(for: subject)
        Button { openPrivateChat(profile) } label: {
            FriendActionLabel(title: "私聊", icon: "bubble.left")
        }.buttonStyle(.plain)
        .accessibilityLabel(Text("与 \(profile.name) 私聊"))
        Button { presentMemory(subject) } label: {
            FriendActionLabel(
                title: activeCount > 0 ? "记忆 \(activeCount)" : "记忆",
                icon: "brain.head.profile"
            )
        }.buttonStyle(.plain)
        .accessibilityLabel(Text("\(profile.name) 的好友记忆"))
        if allowsGroupInvitations {
            Button {
                do { invite(try profile.member()) } catch { self.error = error.localizedDescription }
            } label: {
                FriendActionLabel(title: "邀请进群", icon: "person.2.badge.plus")
            }.buttonStyle(.plain)
            .accessibilityLabel(Text("邀请 \(profile.name) 进群"))
        }
    }
}

struct FriendActionLabel: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        let theme = AppPreferences.shared.accentTheme
        return Label(title, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.readableText)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(theme.softFill, in: Capsule())
            .frame(minHeight: DS.TouchTarget.minimum)
            .contentShape(Rectangle())
    }
}

private struct PersonaProfileEditor: View {
    @State var draft: GroupMember
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("人物姓名", text: $draft.name)
                TextField("说话风格与关注点", text: $draft.rolePrompt, axis: .vertical)
                let targets = ProviderConfig.readyTargets(in: providers)
                Picker("人物使用的模型", selection: $draft.target) {
                    if !targets.contains(where: { $0.id == draft.target.id }) {
                        Text("原模型不可用").tag(draft.target)
                    }
                    ForEach(targets) { target in
                        Text(verbatim: "\(target.providerName) · \(target.modelDisplayName)").tag(target)
                    }
                }
                NavigationLink("人物资料与订阅来源") { PersonaEditorView(member: $draft, isProfile: true) }
                if let error { Text(verbatim: error).foregroundStyle(DS.StatusText.error) }
            }
            .navigationTitle("人物档案")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { _ = try PersonaLibrary.save(draft, in: context); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct PersonaInvitationView: View {
    let member: GroupMember
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Button("创建新群") { creating = true }
                ForEach(conversations.filter(\.isGroupMode)) { chat in
                    Button(chat.title) {
                        do {
                            try PersonaLibrary.invite(member, to: chat, in: context)
                            finish(chat)
                        } catch { self.error = error.localizedDescription }
                    }.disabled(chat.groupMembers.count >= 6 || chat.groupMembers.contains { $0.profileID == member.profileID })
                }
                if let error { Text(verbatim: error).foregroundStyle(DS.StatusText.error) }
            }
            .navigationTitle("邀请进群")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .sheet(isPresented: $creating) {
                GroupCreationFlow(providers: providers, presets: presets, invitedProfile: member, onCreated: finish)
            }
        }
    }

    private func finish(_ chat: Conversation) {
        dismiss()
        SystemEntryRouter.shared.conversationID = chat.id
    }
}
