import SwiftUI
import SwiftData

@MainActor
enum GroupSetupDraftPolicy {
    static func existingMembers(_ members: [GroupMember], providers: [ProviderConfig]) -> [GroupMember] {
        members.map { member in
            var copy = member
            if let refreshed = AssistancePolicy.resolve(member.target, providers: providers) {
                copy.target = refreshed
            }
            return copy
        }
    }
}

struct GroupSetupSheet: View {
    var existingConversation: Conversation? = nil
    var invitedFriend: BookFriend? = nil
    var invitedProfile: GroupMember? = nil
    let providers: [ProviderConfig]
    let presets: [AssistantPreset]
    var onCreated: ((Conversation) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query private var books: [BookVolume]
    @Query(sort: \PersonaProfile.name) private var profiles: [PersonaProfile]

    @State private var roomTitle: String = ""
    @State private var roomEmoji: String = "👥"
    @State private var sharedPrompt: String = ""
    @State private var members: [GroupMember] = []
    @State private var originalMembers: [GroupMember] = []
    @State private var speakingMode: GroupSpeakingMode = .smartRelay
    @State private var speechStyle: GroupSpeechStyle = .naturalShort
    @State private var maxRelayTurns: Int = 3
    @State private var splitShortBubbles: Bool = true
    @State private var expandedMemberID: UUID?
    @State private var editingPersonaID: UUID?
    @State private var didInitialize = false
    @State private var saveError: String?
    @State private var pickingFriend = false
    @State private var templateToApply: GroupRoomTemplate?
    @State private var savedTemplateToast = false
    @State private var preferences = AppPreferences.shared

    private var availableTargets: [ResolvedModelTarget] {
        ProviderConfig.readyTargets(in: providers)
    }

    private var activeUnmutedCount: Int {
        members.filter { !$0.isMuted && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var canConfirm: Bool {
        guard activeUnmutedCount >= 1 else { return false }
        return existingConversation?.isGroupMode == true || members.filter { !$0.isMuted }.allSatisfy { member in
            availableTargets.contains { $0.id == member.target.id }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                templateStripSection

                Section("群聊信息") {
                    HStack(spacing: 12) {
                        TextField("图标", text: $roomEmoji)
                            .font(.title2)
                            .multilineTextAlignment(.center)
                            .frame(width: 46, height: 42)
                            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onChange(of: roomEmoji) { _, newValue in
                                if let first = newValue.first {
                                    let single = String(first)
                                    if newValue != single { roomEmoji = single }
                                }
                            }

                        TextField("群聊名称（如：创业点子审委会）", text: $roomTitle)
                            .font(.body.weight(.medium))
                    }

                    TextField("群公共背景或讨论议题（可选，对全员生效）", text: $sharedPrompt, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.footnote)

                    if !members.isEmpty {
                        Button {
                            let custom = GroupRoomTemplate.custom(
                                roomTitle: roomTitle,
                                roomEmoji: roomEmoji,
                                sharedTopicPrompt: sharedPrompt,
                                speakingMode: speakingMode,
                                speechStyle: speechStyle,
                                members: members
                            )
                            preferences.addCustomGroupTemplate(custom)
                            preferences.triggerLightHaptic()
                            savedTemplateToast = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.6))
                                await MainActor.run { savedTemplateToast = false }
                            }
                        } label: {
                            Label(
                                savedTemplateToast ? String(localized: "已保存为圆桌模板") : String(localized: "保存为我的圆桌模板"),
                                systemImage: savedTemplateToast ? "checkmark.circle.fill" : "bookmark.square"
                            )
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(savedTemplateToast ? .green : Color.accentColor)
                        }
                    }
                }

                Section {
                    if existingConversation != nil && members.isEmpty {
                        Text("该群暂无成员，请选择上方模板或手动添加成员。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if availableTargets.isEmpty && members.isEmpty {
                        Label("请先在「设置」页面启用至少一个模型后再配置群成员。", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(DS.StatusText.warning)
                    } else {
                        ForEach($members) { $member in
                            memberEditorCard(member: $member)
                        }
                        .onDelete { offsets in
                            members.remove(atOffsets: offsets)
                        }

                        if !profiles.isEmpty {
                            Menu("从人物档案邀请") {
                                ForEach(profiles) { profile in
                                    Button(profile.name) {
                                        do {
                                            let member = try profile.member().inRoom()
                                            members.append(member)
                                            expandedMemberID = member.id
                                        } catch { saveError = error.localizedDescription }
                                    }
                                    .disabled(members.contains { $0.profileID == profile.id })
                                }
                            }
                            .disabled(members.count >= 6)
                        }
                        Button { pickingFriend = true } label: { Label("从好友选择", systemImage: "book.pages") }
                            .disabled(members.count >= 6 || availableTargets.isEmpty)

                        HStack(spacing: 12) {
                            Button {
                                addBlankMember()
                            } label: {
                                Label("自定义新角色", systemImage: "person.badge.plus")
                                    .font(.subheadline.weight(.medium))
                            }
                            .disabled(members.count >= 6)

                            Spacer()

                            if !presets.isEmpty {
                                Menu {
                                    ForEach(presets) { preset in
                                        Button("\(preset.iconEmoji) \(preset.name)") {
                                            addMemberFromPreset(preset)
                                        }
                                    }
                                } label: {
                                    Label("从助手拉人", systemImage: "sparkles")
                                        .font(.subheadline.weight(.medium))
                                }
                                .disabled(members.count >= 6)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("群成员与模型分配（\(members.count)/6）")
                        Spacer()
                        if availableTargets.count >= 2 {
                            Button {
                                distributeDistinctModels()
                            } label: {
                                Text("一键混搭模型")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(preferences.accentTheme.readableText)
                                    .frame(minHeight: DS.TouchTarget.minimum + 2)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text("不同角色可绑定不同服务商的模型同群碰撞；点击成员可展开修改人设、头像色与底层模型。")
                }

                ForEach(books.filter { book in members.contains { $0.bookFriend?.bookID == book.id } }) { book in
                    Section {
                        let original = existingConversation?.groupMembers.compactMap(\.bookFriend).first { $0.bookID == book.id }
                        let minimum = original.map { $0.throughChapter ?? book.chapterTitles.count - 1 } ?? 0
                        BookChapterPicker(book: book, minimum: existingConversation?.messages.isEmpty == false ? minimum : 0,
                                          selection: Binding(get: {
                            members.compactMap(\.bookFriend).first(where: { $0.bookID == book.id })?.throughChapter
                        }, set: { BookGroupRoster.setProgress(for: book.id, through: $0, in: &members) }))
                    } header: { Text(verbatim: book.title) } footer: { Text("本群中来自这本书的好友共用此阅读进度。") }
                }

                Section {
                    Picker("发言调度", selection: $speakingMode) {
                        ForEach(GroupSpeakingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Text(speakingMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("表达语感", selection: $speechStyle) {
                        ForEach(GroupSpeechStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }

                    Text(speechStyle.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if speakingMode == .smartRelay {
                        Stepper(value: $maxRelayTurns, in: 1...10) {
                            HStack {
                                Text("单轮自动接力上限")
                                Spacer()
                                Text("\(maxRelayTurns) 条")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    if speechStyle == .naturalShort {
                        Toggle("自动拆分为连发短气泡", isOn: $splitShortBubbles)
                    }
                } header: {
                    Text("讨论节奏与规则")
                }

                if let existing = existingConversation, existing.isGroupMode {
                    Section {
                        Button(role: .destructive) {
                            let previous = existing.assistanceSettingsData
                            existing.isGroupMode = false
                            do {
                                try modelContext.save()
                                PersonaRefreshDelegate.schedule(in: modelContext)
                                dismiss()
                            } catch {
                                existing.assistanceSettingsData = previous
                                saveError = error.localizedDescription
                            }
                        } label: {
                            Label("退出群聊模式（切回普通单聊）", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .navigationTitle(existingConversation == nil ? String(localized: "发起圆桌群聊") : String(localized: "群聊成员与规则"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $pickingFriend) {
                BookGroupFriendPicker(conversations: conversations, books: books, members: members) { addBookFriend($0, confirmedProgress: $1) }
            }
            .confirmationDialog("如何套用这个模板？", isPresented: Binding(get: { templateToApply != nil }, set: { if !$0 { templateToApply = nil } }), presenting: templateToApply) { template in
                Button("只应用发言规则") { speakingMode = template.speakingMode; speechStyle = template.speechStyle }
                Button("替换群成员与设置", role: .destructive) { applyTemplate(template) }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("替换将移除当前成员及其人物资料。保存群设置后生效。") }
            .navigationDestination(item: $editingPersonaID) { id in
                if let index = members.firstIndex(where: { $0.id == id }) {
                    PersonaEditorView(member: $members[index])
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existingConversation == nil ? String(localized: "创建群聊") : String(localized: "保存")) {
                        saveGroupConfiguration()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canConfirm)
                }
            }
            .alert("群聊设置保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(verbatim: saveError ?? "") }
            .onAppear {
                initializeIfNeeded()
            }
        }
    }

    // MARK: - Subviews

    private var templateStripSection: some View {
        let allTemplates = preferences.customGroupTemplates + GroupRoomTemplate.builtInTemplates
        return Section("一键套用圆桌模板") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(allTemplates) { template in
                        Button {
                            if existingConversation != nil || members.contains(where: \.isSimulatedPersona) { templateToApply = template }
                            else { applyTemplate(template) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(template.roomEmoji)
                                        .font(.title3)
                                    Text(template.roomTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if template.isCustom {
                                        Text("自定义")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    }
                                }
                                Text(template.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(width: 210, alignment: .leading)
                            .padding(11)
                            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if template.isCustom {
                                Button(role: .destructive) {
                                    preferences.removeCustomGroupTemplate(id: template.id)
                                } label: {
                                    Label("删除模板", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func memberEditorCard(member: Binding<GroupMember>) -> some View {
        let m = member.wrappedValue
        let isExpanded = expandedMemberID == m.id

        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    expandedMemberID = isExpanded ? nil : m.id
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color(hex: m.accentHex).opacity(0.18))
                            .frame(width: 36, height: 36)
                        Text(m.avatarEmoji)
                            .font(.body)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(m.displayLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(m.isMuted ? .secondary : .primary)
                            if m.isMuted {
                                Text("潜水禁言")
                                    .font(.caption2)
                                    .foregroundStyle(DS.StatusText.warning)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                            }
                        }
                        Text("\(m.target.providerName) · \(m.target.modelDisplayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !availableTargets.contains(where: { $0.id == m.target.id }) {
                            Text("模型待连接").font(.caption).foregroundStyle(DS.StatusText.warning)
                        }
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                if profiles.contains(where: { $0.id == m.profileID }) {
                    Text("人物资料和模型可在「助手」中的人物档案编辑。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach((m.persona?.feeds ?? []).filter { $0.kind == .blog }) { feed in
                        Toggle(isOn: Binding(get: {
                            member.wrappedValue.persona?.feeds.first { $0.id == feed.id }?.enabled ?? false
                        }, set: { enabled in
                            if let i = member.wrappedValue.persona?.feeds.firstIndex(where: { $0.id == feed.id }) {
                                member.wrappedValue.persona?.feeds[i].enabled = enabled
                            }
                        })) {
                            VStack(alignment: .leading) {
                                Text("自动分享到本群")
                                Text(verbatim: feed.displayName).font(.caption).foregroundStyle(.secondary)
                                if let error = feed.lastError { Text(verbatim: error).font(.caption).foregroundStyle(DS.StatusText.warning) }
                            }
                        }
                    }
                } else {
                    roleSettings(member)
                }

                HStack {
                    Toggle("暂时静音（只旁观不发言）", isOn: member.isMuted)
                        .font(.caption)
                    if members.count > 1 {
                        Spacer()
                        Button(role: .destructive) {
                            let removingID = m.id
                            members.removeAll { $0.id == removingID }
                        } label: {
                            Label("移出群聊", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func roleSettings(_ member: Binding<GroupMember>) -> some View {
        let m = member.wrappedValue
        HStack(spacing: 8) {
            TextField("头像", text: member.avatarEmoji)
                .frame(width: 40)
                .multilineTextAlignment(.center)
                .padding(.vertical, 6)
                .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: member.wrappedValue.avatarEmoji) { _, val in
                    if let first = val.first {
                        let single = String(first)
                        if val != single { member.wrappedValue.avatarEmoji = single }
                    }
                }

            TextField("昵称（必填，用于 @点名）", text: member.name)
                .textFieldStyle(.roundedBorder)

            TextField("头衔（如：架构师）", text: member.title)
                .textFieldStyle(.roundedBorder)
        }
        .font(.footnote)

        Button {
            editingPersonaID = m.id
        } label: {
            HStack {
                Label("人物资料与动态", systemImage: "person.text.rectangle")
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)

        if m.bookFriend == nil {
            Button("保存为独立人物档案") {
                do {
                    let profile = try PersonaLibrary.save(m, in: modelContext)
                    member.wrappedValue.profileID = profile.id
                } catch { saveError = error.localizedDescription }
            }.disabled(m.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Picker("底层模型", selection: member.target) {
            if !availableTargets.contains(where: { $0.id == m.target.id }) {
                Text("不可用 · \(m.target.modelDisplayName)").tag(m.target)
            }
            ForEach(availableTargets) { target in
                Text("\(target.providerName) · \(target.modelDisplayName)")
                    .tag(target)
            }
        }
        .font(.footnote)

        VStack(alignment: .leading, spacing: 0) {
            Text("角色色标")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.TouchTarget.minimum + 2), spacing: 0)], alignment: .leading, spacing: 0) {
                ForEach(Array(GroupMember.paletteHexes.enumerated()), id: \.element) { idx, hex in
                    let isChosen = m.accentHex.uppercased() == hex.uppercased()
                    Button {
                        member.wrappedValue.accentHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if isChosen {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: DS.TouchTarget.minimum + 2, height: DS.TouchTarget.minimum + 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "颜色方案 \(idx + 1)"))
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                }
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("角色立场与性格提示词")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("描述该角色的思考视角、说话风格与关注重点…", text: member.rolePrompt, axis: .vertical)
                .lineLimit(2...5)
                .font(.footnote)
                .padding(8)
                .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: 8))
        }

        HStack {
            Text("性格发散度 \(String(format: "%.2f", m.temperature))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Slider(value: member.temperature, in: 0.1...1.2, step: 0.05)
        }
    }

    // MARK: - Actions

    private func initializeIfNeeded() {
        guard !didInitialize else { return }
        didInitialize = true

        if let conv = existingConversation {
            let s = conv.assistanceSettings
            originalMembers = s.groupMembers
            roomTitle = Conversation.isDefaultTitle(conv.title) ? "" : conv.title
            roomEmoji = conv.assistantEmoji.isEmpty ? "👥" : conv.assistantEmoji
            sharedPrompt = conv.systemPrompt
            speakingMode = s.groupSpeakingMode
            speechStyle = s.groupSpeechStyle
            maxRelayTurns = s.groupMaxRelayTurns
            splitShortBubbles = s.groupSplitShortBubbles

            members = GroupSetupDraftPolicy.existingMembers(s.groupMembers, providers: providers)
        } else if let invitedProfile {
            members = [invitedProfile.inRoom()]
            roomTitle = invitedProfile.name
        } else if let invitedFriend {
            roomTitle = String(localized: "《\(invitedFriend.bookTitle)》读书群")
            roomEmoji = "📚"
            addBookFriend(invitedFriend)
        } else if let defaultTemplate = GroupRoomTemplate.builtInTemplates.first {
            applyTemplate(defaultTemplate)
        }
    }

    private func addBookFriend(_ friend: BookFriend, confirmedProgress: BookFriend? = nil) {
        do {
            _ = try BookLibrary.source(for: friend, in: modelContext)
            members = try BookGroupRoster.inviting(friend, into: members, target: availableTargets.first, confirmedProgress: confirmedProgress)
        } catch { saveError = error.localizedDescription }
    }

    private func applyTemplate(_ template: GroupRoomTemplate) {
        roomTitle = template.roomTitle
        roomEmoji = template.roomEmoji
        sharedPrompt = template.sharedTopicPrompt
        speakingMode = template.speakingMode
        speechStyle = template.speechStyle
        members = template.instantiate(using: availableTargets, profiles: profiles.compactMap { try? $0.member() })
        expandedMemberID = nil
    }

    private func distributeDistinctModels() {
        let pool = availableTargets
        guard !pool.isEmpty else { return }
        for idx in members.indices {
            members[idx].target = pool[idx % pool.count]
        }
    }

    private func addBlankMember() {
        guard let target = availableTargets.first else { return }
        let idx = members.count
        let hex = GroupMember.paletteHexes[idx % GroupMember.paletteHexes.count]
        let created = GroupMember(
            name: String(localized: "成员\(idx + 1)"),
            title: String(localized: "讨论嘉宾"),
            avatarEmoji: ["🦊", "🦉", "🐼", "🦁", "🐙", "🦄"][idx % 6],
            accentHex: hex,
            rolePrompt: String(localized: "请结合你的独立专业判断参与讨论，有不同意见直接指出。"),
            target: availableTargets[idx % availableTargets.count]
        )
        _ = target
        members.append(created)
        expandedMemberID = created.id
    }

    private func addMemberFromPreset(_ preset: AssistantPreset) {
        let pool = availableTargets
        guard !pool.isEmpty else { return }
        let idx = members.count
        let hex = GroupMember.paletteHexes[idx % GroupMember.paletteHexes.count]
        let created = GroupMember(
            name: preset.name,
            title: "",
            avatarEmoji: preset.iconEmoji,
            accentHex: hex,
            rolePrompt: preset.systemPrompt,
            target: pool[idx % pool.count],
            temperature: preset.temperature
        )
        members.append(created)
        expandedMemberID = created.id
    }

    private func saveGroupConfiguration() {
        guard canConfirm else { return }
        let sanitizedMembers: [GroupMember] = members.enumerated().compactMap { idx, m in
            if let profile = profiles.first(where: { $0.id == m.profileID }), let shared = try? profile.member() {
                return shared.inRoom(replacing: m)
            }
            var copy = m
            copy.name = m.name.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.title = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if copy.name.isEmpty {
                copy.name = String(localized: "成员\(idx + 1)")
            }
            if copy.avatarEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                copy.avatarEmoji = "🤖"
            }
            return copy
        }
        guard sanitizedMembers.contains(where: { !$0.isMuted }) else { return }

        let finalTitle = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = finalTitle.isEmpty ? String(localized: "圆桌群聊") : finalTitle
        let effectiveEmoji = roomEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "👥" : roomEmoji

        if let conv = existingConversation {
            guard conv.isGroupMode, conv.groupMembers.map(\.id) == originalMembers.map(\.id),
                  conv.groupMembers.map(\.bookFriend) == originalMembers.map(\.bookFriend) else {
                saveError = String(localized: "群成员或阅读进度已更新，请重新打开群设置。")
                return
            }
            let previous = (conv.title, conv.assistantEmoji, conv.systemPrompt, conv.isArenaMode,
                            conv.primaryTargetData, conv.assistanceSettingsData, conv.updatedAt)
            conv.rename(to: effectiveTitle)
            conv.assistantEmoji = effectiveEmoji
            conv.systemPrompt = sharedPrompt
            conv.isArenaMode = false
            if conv.primaryTarget == nil {
                conv.primaryTarget = sanitizedMembers.first?.target
            }
            var s = conv.assistanceSettings
            s.isGroupMode = true
            s.groupMembers = sanitizedMembers.map { member in
                member.preservingFeedProgress(from: conv.groupMembers.first { $0.id == member.id })
            }
            s.groupSpeakingMode = speakingMode
            s.groupSpeechStyle = speechStyle
            s.groupMaxRelayTurns = maxRelayTurns
            s.groupSplitShortBubbles = splitShortBubbles
            conv.assistanceSettings = s
            conv.updatedAt = Date()
            do { try modelContext.save() } catch {
                (conv.title, conv.assistantEmoji, conv.systemPrompt, conv.isArenaMode,
                 conv.primaryTargetData, conv.assistanceSettingsData, conv.updatedAt) = previous
                saveError = error.localizedDescription
                return
            }
            startSubscriptions(for: conv)
            dismiss()
        } else {
            let conv = Conversation(
                title: effectiveTitle,
                assistantEmoji: effectiveEmoji,
                systemPrompt: sharedPrompt,
                isArenaMode: false,
                primaryTarget: sanitizedMembers.first?.target
            )
            var s = AssistanceSettings()
            s.isGroupMode = true
            s.groupMembers = sanitizedMembers
            s.groupSpeakingMode = speakingMode
            s.groupSpeechStyle = speechStyle
            s.groupMaxRelayTurns = maxRelayTurns
            s.groupSplitShortBubbles = splitShortBubbles
            conv.assistanceSettings = s
            modelContext.insert(conv)
            do { try modelContext.save() } catch {
                modelContext.delete(conv)
                saveError = error.localizedDescription
                return
            }
            startSubscriptions(for: conv)
            dismiss()
            onCreated?(conv)
        }
    }
    private func startSubscriptions(for conversation: Conversation) {
        PersonaRefreshDelegate.schedule(in: modelContext)
        guard PersonaFeedService.hasSubscriptions(conversation) else { return }
        let id = conversation.id
        Task { await PersonaFeedService.shared.refresh(in: modelContext, chatID: id) }
    }
}
