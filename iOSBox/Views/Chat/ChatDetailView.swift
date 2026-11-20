import SwiftUI
import SwiftData
import UIKit

struct ChatDetailView: View {
    @Bindable var conversation: Conversation
    var onOpenConversation: ((Conversation) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: ChatDraftState

    init(
        conversation: Conversation,
        initialMessageID: UUID? = nil,
        onOpenConversation: ((Conversation) -> Void)? = nil
    ) {
        self.conversation = conversation
        self.onOpenConversation = onOpenConversation
        _pendingScrollMessageID = State(initialValue: initialMessageID)
        _isPinnedToBottom = State(initialValue: initialMessageID == nil)
        _draft = State(initialValue: ChatDraftStore.shared.state(for: conversation.id))
    }

    private enum ComposerPanel: String, Identifiable {
        case options, model, arena, settings
        var id: Self { self }
    }
    @State private var composerPanel: ComposerPanel?
    @State private var modelDirectory = ChatModelDirectory()
    private enum BookPanel: String, Identifiable {
        case progress, invitation
        var id: Self { self }
    }
    @State private var bookPanel: BookPanel?
    @State private var showGroupSetup = false
    @State private var checkingFeeds = false
    @State private var feedReport: String?
    @State private var showSearchSheet = false
    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var sendBlockedReason: SendOutcome?
    @State private var sendingInterruption = false
    @State private var synthesisGroupID: IdentifiableUUID?
    @State private var pendingScrollMessageID: UUID?
    @State private var arenaSearchFocus: MessageSearchFocus?
    private struct AlertBanner: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @State private var shareFileURL: IdentifiableURL?
    @State private var actionAlert: AlertBanner?
    @State private var isGeneratingTitle = false
    @State private var confirmClear = false
    @State private var clearedHistory: ConversationBackup?
    @State private var historyError: String?
    @State private var showModelSetup = false
    @State private var consent = AIConsentGate()

    @State private var requestOptions = ComposerRequestOptions()
    @FocusState private var inputFocused: Bool

    @State private var isPinnedToBottom = true
    @State private var isUserScrolling = false

    private var engine: ChatEngine { ChatEngine.shared }

    private func openBookConversation(_ chat: Conversation) {
        if let onOpenConversation { onOpenConversation(chat) }
        else { SystemEntryRouter.shared.conversationID = chat.id }
    }

    private var activeMessages: [ChatMessage] {
        ConversationTree.activeMessages(in: conversation)
    }

    private var timelineItems: [TimelineEntry] {
        TimelineEntry.build(from: activeMessages)
    }

    private var availableTargets: [ResolvedModelTarget] {
        engine.availableTargets(from: providers)
    }

    private var needsAPIKeyBanner: Bool {
        let targets: [ResolvedModelTarget]
        if conversation.isGroupMode {
            targets = conversation.activeGroupMembers.map(\.target)
        } else if conversation.isArenaMode {
            targets = conversation.arenaTargets
        } else {
            let backups = conversation.assistanceSettings.fallbackEnabled ? conversation.assistanceSettings.fallbackTargets : []
            targets = ([requestOptions.temporaryTarget ?? conversation.primaryTarget].compactMap { $0 }) + backups
        }
        return !targets.contains(where: isReady)
    }

    private var unreadyPeerSummary: String? {
        guard !needsAPIKeyBanner else { return nil }
        if conversation.isGroupMode {
            let unready = conversation.activeGroupMembers.filter { !isReady($0.target) }
            guard !unready.isEmpty else { return nil }
            let labels = unready.map { "\($0.displayLabel)（\($0.target.providerName)）" }
                .joined(separator: String(localized: "、"))
            return String(localized: "部分群成员模型尚未就绪：\(labels)，轮到其发言时可能报错。")
        }
        if conversation.isArenaMode {
            let unready = conversation.arenaTargets.filter { !isReady($0) }
            guard !unready.isEmpty else { return nil }
            let labels = unready.map { "\($0.providerName) · \($0.modelDisplayName)" }
                .joined(separator: String(localized: "、"))
            return String(localized: "部分对比模型尚未就绪：\(labels)。")
        }
        return nil
    }

    private var hasActiveTopicAfterDivider: Bool {
        let slice: ArraySlice<ChatMessage>
        if let lastDiv = activeMessages.lastIndex(where: { $0.assistanceMetadata.isContextDivider }) {
            slice = activeMessages[activeMessages.index(after: lastDiv)...]
        } else {
            slice = activeMessages[...]
        }
        return slice.contains { ($0.role != .system || $0.assistanceMetadata.sourceNotice != nil) && !$0.assistanceMetadata.isExcludedFromContext && (!$0.content.isEmpty || !$0.attachments.isEmpty) }
    }

    private func isReady(_ target: ResolvedModelTarget) -> Bool {
        guard let provider = providers.first(where: { $0.id == target.providerID }) else { return false }
        return provider.isReadyForChat && provider.enabledModels.contains { $0.id == target.modelID }
    }

    private func prepareDraftModels(chooseInitial: Bool) {
        guard conversation.messages.isEmpty, !conversation.isGroupMode else { return }
        let configured = providers.filter(\.hasConfiguredChatAPI)
        let available = configured.flatMap { provider in provider.enabledModels.map { provider.makeTarget(for: $0) } }
        let legacyIDs = configured.flatMap { provider in
            provider.models.filter { $0.retiredStarterDefault == true && $0.catalogStatus == .unlisted }
                .map { provider.makeTarget(for: $0).id }
        }
        conversation.updateDraftModel(from: available, replacingLegacy: Set(legacyIDs))
        let selections = conversation.isArenaMode ? conversation.arenaTargets : [conversation.primaryTarget].compactMap { $0 }
        let ids = Set(selections.map(\.providerID))
        modelDirectory.update(configured: configured, automaticIDs: ids.isEmpty && chooseInitial ? nil : ids, in: modelContext)
    }

    private var timelineAndComposer: some View {
        let currentActiveMessages = activeMessages
        let items = TimelineEntry.build(from: currentActiveMessages)
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if needsAPIKeyBanner {
                            missingKeyCard
                        } else if let unreadyPeerSummary {
                            partialUnreadyCard(unreadyPeerSummary)
                        }

                        if items.isEmpty {
                            emptyWelcomeView
                                .padding(.top, 36)
                        } else {
                            let siblingsByID = ConversationTree.branchSiblingsMap(in: conversation)
                            ForEach(items) { entry in
                                switch entry {
                                case .single(let msg):
                                    MessageRowView(
                                        message: msg,
                                        branchSiblings: siblingsByID[msg.id] ?? [msg],
                                        availableCompareTargets: availableTargets,
                                        onSwitchBranch: { targetMsg in
                                            ConversationTree.switchBranch(to: targetMsg, in: conversation)
                                            try? modelContext.save()
                                        },
                                        onSelectRevision: msg.role == .assistant ? { revIndex in
                                            engine.selectRevision(index: revIndex, for: msg, context: modelContext)
                                        } : nil,
                                        onRegenerate: { retry(msg) },
                                        onRegenerateWithCurrentModel: conversation.isGroupMode ? nil : { retry(msg, override: conversation.primaryTarget) },
                                        onRegenerateWithOverride: msg.role == .assistant ? { chosen in retry(msg, override: chosen) } : nil,
                                        onContinueGeneration: msg.role == .assistant ? { continueReply(msg) } : nil,
                                        onEditAndResend: msg.role == .user ? { edited in editAndResend(msg, text: edited) } : nil,
                                        onQuote: msg.role == .system ? nil : { content in
                                            draft.quotedText = String(content.prefix(600))
                                            draft.save()
                                        },
                                        onToggleBookmark: msg.role == .system ? nil : {
                                            engine.toggleBookmark(for: msg, context: modelContext)
                                        },
                                        onToggleExcludeFromContext: msg.role == .system ? nil : {
                                            engine.toggleContextExclusion(for: msg, context: modelContext)
                                        },
                                        onForkConversation: msg.role == .system ? nil : {
                                            let forked = engine.forkConversation(upTo: msg, in: conversation, context: modelContext)
                                            onOpenConversation?(forked)
                                        },
                                        onCompareWithModel: (!conversation.isGroupMode && msg.role == .assistant && msg.comparisonGroupID == nil) ? { second in
                                            authorize([second]) {
                                                engine.compareWithAnotherModel(assistantMessage: msg, secondTarget: second,
                                                                               in: conversation, providers: providers, context: modelContext)
                                            }
                                        } : nil,
                                        onMentionMember: conversation.isGroupMode ? { mention in
                                            if !draft.text.isEmpty && !draft.text.hasSuffix(" ") {
                                                draft.text.append(" ")
                                            }
                                            draft.text.append(mention)
                                            draft.save()
                                        } : nil,
                                        onDeleteMessage: {
                                            Task {
                                                await engine.deleteSingleMessage(
                                                    msg,
                                                    in: conversation,
                                                    context: modelContext
                                                )
                                            }
                                        },
                                        studyDeckName: conversation.activeBookFriend.map { "《\($0.bookTitle)》" } ?? conversation.title,
                                        conversationID: conversation.id,
                                        isGeneratingStudy: engine.generatingStudyMessageIDs.contains(msg.id),
                                        onGenerateFlashcards: msg.role == .assistant ? {
                                            triggerStudyGeneration(for: msg, quiz: false)
                                        } : nil,
                                        onGenerateQuiz: msg.role == .assistant ? {
                                            triggerStudyGeneration(for: msg, quiz: true)
                                        } : nil,
                                        onExtractSchedule: msg.role == .assistant ? {
                                            triggerScheduleExtraction(for: msg)
                                        } : nil,
                                        onSelectQuizOption: msg.role == .assistant ? { qID, optIdx in
                                            engine.selectQuizOption(questionID: qID, optionIndex: optIdx, on: msg, context: modelContext)
                                        } : nil
                                    )
                                    .id(entry.id)

                                case .arenaGroup(let gid, let groupMsgs):
                                    ArenaComparisonGroupView(
                                        groupID: gid,
                                        messages: groupMsgs,
                                        isBlindMode: conversation.assistanceSettings.blindArenaMode,
                                        isGenerating: engine.isGenerating(in: conversation.id),
                                        onToggleBlindMode: {
                                            conversation.assistanceSettings.blindArenaMode.toggle()
                                            try? modelContext.save()
                                        },
                                        searchFocus: arenaSearchFocus?.groupID == gid ? arenaSearchFocus : nil,
                                        onVote: { winner in
                                            do { try engine.castBlindVote(for: winner, in: conversation, context: modelContext) }
                                            catch { historyError = error.localizedDescription }
                                        },
                                        onFollowUp: { reply in
                                            do {
                                                try engine.selectContextReply(reply, in: conversation, context: modelContext)
                                                inputFocused = true
                                            } catch { historyError = error.localizedDescription }
                                        },
                                        onRegenerateSingle: { retry($0) },
                                        onContinueSingle: { continueReply($0) },
                                        onSelectRevision: { single, idx in
                                            engine.selectRevision(index: idx, for: single, context: modelContext)
                                        },
                                        onQuote: { content in
                                            draft.quotedText = String(content.prefix(600))
                                            draft.save()
                                        },
                                        onToggleBookmark: { single in
                                            engine.toggleBookmark(for: single, context: modelContext)
                                        },
                                        onForkConversation: { single in
                                            let forked = engine.forkConversation(upTo: single, in: conversation, context: modelContext)
                                            onOpenConversation?(forked)
                                        },
                                        onSynthesize: {
                                            synthesisGroupID = IdentifiableUUID(id: gid)
                                        },
                                        onCrossCritique: {
                                            let sources = ArenaSynthesis.eligibleSources(in: groupMsgs, groupID: gid)
                                            let targets: [ResolvedModelTarget] = sources.compactMap { engine.replyTarget($0, in: conversation, providers: providers) }
                                            guard targets.count == sources.count else { sendBlockedReason = .noAvailableModel; return }
                                            authorize(targets) {
                                                isPinnedToBottom = true
                                                if engine.crossCritique(groupID: gid, in: conversation, providers: providers, context: modelContext) == .unavailableModel {
                                                    sendBlockedReason = .noAvailableModel
                                                }
                                            }
                                        }
                                    )
                                    .id(entry.id)
                                }
                            }
                        }

                        Color.clear
                            .frame(height: 4)
                            .id("BOTTOM_ANCHOR")
                    }
                    .frame(maxWidth: horizontalSizeClass == .regular && !conversation.isArenaMode ? 820 : .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 120
                } action: { _, nearBottom in
                    if isUserScrolling { isPinnedToBottom = nearBottom }
                }
                .onScrollPhaseChange { _, newPhase in
                    isUserScrolling = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
                }
                .background {
                    StreamingAutoScroller(conversation: conversation, proxy: proxy, isEnabled: isPinnedToBottom)
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    dismissUndoIfRestored()
                    guard isPinnedToBottom, pendingScrollMessageID == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                }
                    .task(id: pendingScrollMessageID) {
                        guard let id = pendingScrollMessageID,
                              let message = currentActiveMessages.first(where: { $0.id == id }) else { return }
                        let focus = MessageSearchFocus(messageID: id, groupID: message.comparisonGroupID)
                        arenaSearchFocus = focus
                        isPinnedToBottom = false
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(focus.anchorID, anchor: .top)
                        pendingScrollMessageID = nil
                    }

                if !isPinnedToBottom && !items.isEmpty {
                    Button {
                        isPinnedToBottom = true
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down")
                                .font(.caption.weight(.bold))
                            if engine.isGenerating(in: conversation.id) {
                                Text("最新输出")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if let clearedHistory { undoClearBar(clearedHistory) }
                    if conversation.isGroupMode {
                        groupDiscussionControlBar
                    }
                    RequestOptionsBar(
                        conversation: conversation,
                        providers: providers,
                        text: draft.text,
                        attachments: draft.attachments,
                        quotedText: draft.quotedText,
                        options: requestOptions,
                        onOpenOptions: { composerPanel = .options }
                    )
                    .disabled(engine.isGenerating(in: conversation.id))
                    .background(.ultraThinMaterial)

                    ComposerBarView(
                        conversation: conversation,
                        draft: draft,
                        providers: providers,
                        presets: presets,
                        isGenerating: engine.isGenerating(in: conversation.id),
                        requestOptions: $requestOptions,
                        onOpenModelPicker: { composerPanel = .model },
                        onOpenArenaPicker: { composerPanel = .arena },
                        onOpenGroupSetup: { showGroupSetup = true },
                        onOpenOptions: { composerPanel = .options },
                        inputFocus: $inputFocused,
                        onInsertContextDivider: {
                            engine.insertContextDivider(in: conversation, context: modelContext)
                        },
                        onSend: handleSend,
                        onStop: { engine.stopGeneration(for: conversation.id) }
                    )
                }
            }
        }
    }

    private var draftProviderFingerprint: [String] {
        conversation.messages.isEmpty ? SystemIntegration.fingerprint(providers) : []
    }

    private var chatWithToolbar: some View {
        timelineAndComposer
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(horizontalSizeClass == .regular ? .automatic : .hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let friend = conversation.activeBookFriend {
                    BookChatHeading(friend: friend, title: conversation.title) { bookPanel = .progress }
                        .disabled(engine.isGenerating(in: conversation.id))
                } else {
                    Button {
                        if conversation.isGroupMode {
                            showGroupSetup = true
                        } else if conversation.isArenaMode {
                            composerPanel = .arena
                        } else {
                            composerPanel = .model
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Text(conversation.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if conversation.isGroupMode {
                                    Text("群聊 · \(conversation.activeGroupMembers.count) 人")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if conversation.isArenaMode {
                                    Text("并发对比 · \(max(conversation.arenaTargets.count, 0)) 模型")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if let target = requestOptions.temporaryTarget ?? conversation.primaryTarget {
                                    Circle()
                                        .fill(Color(hex: target.accentHex))
                                        .frame(width: 6, height: 6)
                                    Text(target.modelDisplayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if conversation.assistanceSettings.studyCoachMode != .off {
                                        Text("· \(conversation.assistanceSettings.studyCoachMode.shortBadge)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.indigo)
                                    }
                                } else {
                                    Text("选择模型")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        composerPanel = .settings
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                    .accessibilityLabel("系统提示词与参数")

                    Menu {
                        if conversation.activeBookFriend != nil {
                            Button { bookPanel = .invitation } label: { Label("邀请进群", systemImage: "person.2.badge.plus") }
                            Button { bookPanel = .progress } label: { Label("调整阅读进度", systemImage: "bookmark") }
                                .disabled(engine.isGenerating(in: conversation.id))
                            Divider()
                        }
                        Button {
                            showSearchSheet = true
                        } label: {
                            Label("会话内查找与收藏", systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)

                        Button {
                            renameDraft = conversation.title
                            showRenameAlert = true
                        } label: {
                            Label("重命名对话", systemImage: "pencil")
                        }

                        Button {
                            if let target = engine.titleTarget(in: conversation, providers: providers) {
                                authorize([target]) {
                                    isGeneratingTitle = true
                                    Task {
                                        defer { isGeneratingTitle = false }
                                        _ = await engine.generateSmartTitle(for: conversation, providers: providers, context: modelContext)
                                    }
                                }
                            }
                        } label: {
                            Label("AI 智能生成标题", systemImage: "sparkles")
                        }
                        .disabled(isGeneratingTitle || activeMessages.count < 2)

                        Divider()

                        Button {
                            composerPanel = .arena
                        } label: {
                            Label("配置多模型并发对比", systemImage: "square.split.2x1")
                        }

                        Button {
                            showGroupSetup = true
                        } label: {
                            Label("配置圆桌群聊角色", systemImage: "person.3")
                        }

                        if PersonaFeedService.hasSubscriptions(conversation) {
                            Button {
                                checkingFeeds = true
                                Task {
                                    let report = await PersonaFeedService.shared.refresh(in: modelContext, chatID: conversation.id, force: true)
                                    feedReport = report.message
                                    checkingFeeds = false
                                }
                            } label: { Label("检查成员动态", systemImage: "arrow.clockwise") }
                            .disabled(checkingFeeds)
                        }

                        Divider()

                        Button {
                            exportMarkdown()
                        } label: {
                            Label("导出 Markdown", systemImage: "doc.text")
                        }
                        .disabled(activeMessages.isEmpty)

                        Button {
                            exportShareImage()
                        } label: {
                            Label("生成分享长图", systemImage: "photo.on.rectangle")
                        }
                        .disabled(activeMessages.isEmpty)

                        Divider()

                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label("清空当前消息记录", systemImage: "trash")
                        }
                        .disabled(conversation.messages.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .onChange(of: engine.isGenerating(in: conversation.id)) { wasGenerating, isNowGenerating in
            if wasGenerating && !isNowGenerating {
                AppPreferences.shared.triggerLightHaptic()
            }
        }
    }

    private var chatWithDraftControls: some View {
        chatWithToolbar
        .onAppear {
            prepareDraftModels(chooseInitial: true)
            loadDraft()
            dismissUndoIfRestored()
        }
        .onChange(of: draftProviderFingerprint) { prepareDraftModels(chooseInitial: false) }
        .onReceive(NotificationCenter.default.publisher(for: .init("IOSBoxCredentialsChanged"))) { _ in prepareDraftModels(chooseInitial: false) }
        .onDisappear {
            modelDirectory.reset()
            saveDraft()
        }
        .confirmationDialog("清空整个对话？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空全部分支", role: .destructive) { Task { await clearAllMessages() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除所有分支中的 \(conversation.messages.count) 条消息及其附件。可以在此页面撤销，也可以从已有备份恢复。")
        }
        .alert("成员订阅动态", isPresented: Binding(get: { feedReport != nil }, set: { if !$0 { feedReport = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(verbatim: feedReport ?? "") }
        .alert("无法更新对话记录", isPresented: Binding(get: { historyError != nil }, set: { if !$0 { historyError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(historyError ?? "") }
        .aiConsentSheet(consent)
        .sheet(isPresented: $showModelSetup) {
            FirstModelSetupSheet { target in
                do { try useModel(target, exitGroup: false) } catch { historyError = error.localizedDescription }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveDraft() } }
        .onChange(of: draft.text) { _, _ in draft.scheduleAutosave() }
        .alert(
            draft.isLoaded ? String(localized: "草稿保存失败") : String(localized: "草稿读取失败"),
            isPresented: Binding(get: { draft.persistenceError != nil }, set: { if !$0 { draft.persistenceError = nil } })
        ) {
            Button("重试") {
                if draft.isLoaded { saveDraft() } else { loadDraft() }
            }
            if !draft.isLoaded {
                Button("重置草稿", role: .destructive) {
                    draft.discardUnreadableDraft()
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text(draft.persistenceError ?? "") }
        .alert(
            String(localized: "确认读取外部网页？"),
            isPresented: Binding(
                get: { engine.pendingWebpageApproval?.conversationID == conversation.id },
                set: { isPresented in
                    if !isPresented,
                       let pending = engine.pendingWebpageApproval,
                       pending.conversationID == conversation.id {
                        engine.resolvePendingWebpageApproval(id: pending.id, decision: .deny, rememberHost: false)
                    }
                }
            )
        ) {
            if let pending = engine.pendingWebpageApproval, pending.conversationID == conversation.id {
                Button("允许本次") {
                    engine.resolvePendingWebpageApproval(id: pending.id, decision: .allow, rememberHost: false)
                }
                if pending.url.query == nil {
                    Button("本对话始终允许 \(pending.host)") {
                        engine.resolvePendingWebpageApproval(id: pending.id, decision: .allow, rememberHost: true)
                    }
                }
                Button("拒绝", role: .cancel) {
                    engine.resolvePendingWebpageApproval(id: pending.id, decision: .deny, rememberHost: false)
                }
            }
        } message: {
            if let pending = engine.pendingWebpageApproval {
                Text("AI 请求访问你未直接输入的外部链接：\n\(pending.url.absoluteString)")
            }
        }
        .alert(
            actionAlert?.title ?? String(localized: "操作失败"),
            isPresented: Binding(get: { actionAlert != nil }, set: { if !$0 { actionAlert = nil } })
        ) {
            Button("确定", role: .cancel) { }
        } message: { Text(actionAlert?.message ?? "") }
    }

    var body: some View {
        chatWithDraftControls
        .sheet(item: $composerPanel) { panel in
            Group {
                switch panel {
                case .options:
                    ComposerOptionsSheet(conversation: conversation, options: $requestOptions, draftText: draft.text,
                                         targets: availableTargets, onOpenArena: { composerPanel = .arena },
                                         onOpenSettings: { composerPanel = .settings })
                case .model, .arena:
                    ModelPickerSheet(mode: panel == .model ? .single : .arenaMulti,
                                     directory: modelDirectory, conversation: conversation) { target in
                        try useModel(target, exitGroup: true)
                    }
                case .settings:
                    ChatSettingsSheet(conversation: conversation)
                }
            }
            .presentationDetents(panel == .options ? [.large] : [.medium, .large])
        }
        .onChange(of: conversation.isArenaMode || conversation.isGroupMode) { _, multi in
            if multi { requestOptions.temporaryTarget = nil }
        }
        .sheet(isPresented: $showGroupSetup) {
            GroupSetupSheet(
                existingConversation: conversation,
                providers: providers,
                presets: presets
            )
        }
        .sheet(item: $bookPanel) { panel in
            if let friend = conversation.activeBookFriend {
                switch panel {
                case .progress: BookReadingProgressSheet(chat: conversation, friend: friend, onOpen: openBookConversation)
                case .invitation: BookInvitationSheet(friend: friend, onOpen: openBookConversation)
                }
            }
        }
        .sheet(isPresented: $showSearchSheet) {
            ConversationSearchSheet(
                messages: activeMessages,
                isBlindMode: conversation.assistanceSettings.blindArenaMode
            ) { messageID in
                pendingScrollMessageID = messageID
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $synthesisGroupID) { wrapper in
            SynthesisPickerSheet(
                conversation: conversation,
                groupID: wrapper.id,
                providers: providers
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $shareFileURL) { item in
            ActivityShareSheet(url: item.url)
        }
        .alert("重命名对话", isPresented: $showRenameAlert) {
            TextField("对话标题", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let t = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    conversation.title = t
                    try? modelContext.save()
                }
            }
        }
        .alert(
            sendBlockedTitle,
            isPresented: Binding(
                get: { sendBlockedReason != nil },
                set: { if !$0 { sendBlockedReason = nil } }
            )
        ) {
            if sendBlockedReason == .noAvailableModel {
                Button(canPickConnectedModel ? String(localized: "选择模型") : String(localized: "去配置")) { beginModelSetup() }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(sendBlockedMessage)
        }
    }

    private func exportMarkdown() {
        do {
            let url = try ConversationExporter.writeMarkdownFile(for: conversation)
            shareFileURL = IdentifiableURL(url: url)
        } catch {
            actionAlert = AlertBanner(title: String(localized: "导出失败"), message: error.localizedDescription)
        }
    }

    private func exportShareImage() {
        do {
            if let url = try ConversationExporter.writeShareImageFile(for: conversation, colorScheme: colorScheme) {
                shareFileURL = IdentifiableURL(url: url)
            } else {
                actionAlert = AlertBanner(title: String(localized: "导出失败"), message: String(localized: "当前对话暂无可生成分享图的消息内容。"))
            }
        } catch {
            actionAlert = AlertBanner(title: String(localized: "导出失败"), message: error.localizedDescription)
        }
    }

    private func loadDraft() { draft.load() }

    private func saveDraft() { draft.save() }

    private func useModel(_ target: ResolvedModelTarget, exitGroup: Bool) throws {
        try ModelSetup.use(target, in: conversation, context: modelContext, exitGroup: exitGroup)
        requestOptions.temporaryTarget = conversation.assistanceSettings.automaticRouting ? conversation.primaryTarget : nil
    }

    private var canPickConnectedModel: Bool {
        !conversation.isGroupMode && !availableTargets.isEmpty
    }

    private func beginModelSetup() {
        saveDraft()
        if canPickConnectedModel { composerPanel = conversation.isArenaMode ? .arena : .model }
        else { showModelSetup = true }
    }

    private func handleSend() {
        guard draft.canSend else { return }
        do { try AttachmentProcessor.validate(draft.attachments) }
        catch { draft.attachmentError = error.localizedDescription; return }

        let options = requestOptions.forSend(in: conversation, quote: draft.quotedText)
        if let query = options.searchQuery {
            let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= TavilySearchClient.maximumQueryCharacters else {
                sendBlockedReason = .invalidSearch
                return
            }
        }
        let text = draft.text
        let attachments = draft.attachments
        guard let plan = engine.sendTargets(text: text, attachments: attachments, in: conversation,
                                            providers: providers, override: options.overrideTarget) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        guard plan.candidates.contains(where: { $0.contains(where: isReady) }) else { beginModelSetup(); return }
        let targets = disclosureTargets(for: plan)
        let usesTools = !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools
        authorize(targets, search: options.searchQuery != nil, tools: usesTools, isCurrent: {
            guard options == requestOptions.forSend(in: conversation, quote: draft.quotedText),
                  text == draft.text, attachments == draft.attachments,
                  usesTools == (!conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools),
                  let latest = engine.sendTargets(text: text, attachments: attachments, in: conversation,
                                                  providers: providers, override: options.overrideTarget) else { return false }
            return disclosureTargets(for: latest) == targets
        }) { sendDraft(options) }
    }

    private func disclosureTargets(for plan: ChatEngine.SendTargets) -> [ResolvedModelTarget] {
        var targets = plan.candidates.flatMap { $0 }
        if conversation.assistanceSettings.autoGenerateTitle, !conversation.messages.contains(where: { $0.role == .user }),
           let title = engine.titleTarget(in: conversation, providers: providers) { targets.append(title) }
        return targets
    }

    private func authorize(_ targets: [ResolvedModelTarget], search: Bool = false, tools: Bool = false,
                           isCurrent: @escaping () -> Bool = { true },
                           send: @escaping () -> Void) {
        let shown = recipients(for: targets)
        consent.perform(recipients: shown, search: search, tools: tools,
                        isCurrent: { recipients(for: targets) == shown && isCurrent() }, send: send)
    }

    private func recipients(for targets: [ResolvedModelTarget]) -> [String] {
        targets.map { target in
            let provider = providers.first { $0.id == target.providerID }
            return AppCompliance.recipient(provider: provider?.name ?? target.providerName, model: target.modelDisplayName,
                                           baseURL: provider?.baseURL ?? "")
        }
    }

    private func retry(_ message: ChatMessage, override: ResolvedModelTarget? = nil) {
        let requested = override ?? engine.replyTarget(message, in: conversation, providers: providers)
        guard let requested, let target = AssistancePolicy.resolve(requested, providers: providers) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        let isGroupMsg = message.assistanceMetadata.groupMemberID != nil || conversation.isGroupMode
        let backups = (message.comparisonGroupID == nil && !isGroupMsg)
            ? AssistancePolicy.fallbacks(after: target, settings: conversation.assistanceSettings, providers: providers, requiresVision: false) : []
        let usesTools = message.comparisonGroupID == nil && !isGroupMsg && !message.isSynthesis && conversation.assistanceSettings.enableAgentTools
        authorize([target] + backups, search: message.assistanceMetadata.requestedSearchQuery != nil, tools: usesTools) {
            engine.regenerate(assistantMessage: message, overrideTarget: override, in: conversation, providers: providers, context: modelContext)
        }
    }

    private func continueReply(_ message: ChatMessage) {
        guard let target = engine.replyTarget(message, in: conversation, providers: providers) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        authorize([target]) {
            isPinnedToBottom = true
            engine.continueGeneration(assistantMessage: message, in: conversation, providers: providers, context: modelContext)
        }
    }

    private func triggerStudyGeneration(for message: ChatMessage, quiz: Bool) {
        guard let resolved = engine.studyTarget(for: message, in: conversation, providers: providers) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        authorize([resolved.target]) {
            Task { @MainActor in
                do {
                    if quiz {
                        try await engine.generateStudyQuiz(for: message, in: conversation, providers: providers, context: modelContext)
                    } else {
                        try await engine.generateStudyFlashcards(for: message, in: conversation, providers: providers, context: modelContext)
                    }
                    AppPreferences.shared.triggerLightHaptic()
                } catch {
                    actionAlert = AlertBanner(title: String(localized: "生成失败"), message: error.localizedDescription)
                }
            }
        }
    }

    private func triggerScheduleExtraction(for message: ChatMessage) {
        guard let resolved = engine.studyTarget(for: message, in: conversation, providers: providers) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        authorize([resolved.target]) {
            Task { @MainActor in
                do {
                    try await engine.extractScheduleItems(for: message, in: conversation, providers: providers, context: modelContext)
                    AppPreferences.shared.triggerLightHaptic()
                } catch {
                    actionAlert = AlertBanner(title: String(localized: "日程提取失败"), message: error.localizedDescription)
                }
            }
        }
    }

    private func editAndResend(_ message: ChatMessage, text: String) {
        guard let index = activeMessages.firstIndex(where: { $0.id == message.id }) else { return }
        guard let plan = engine.sendTargets(text: text, attachments: message.attachments, in: conversation, providers: providers) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        let previousAnswer = activeMessages.dropFirst(index + 1).first { $0.role == .assistant }
        authorize(plan.candidates.flatMap { $0 }, search: previousAnswer?.assistanceMetadata.requestedSearchQuery != nil,
                  tools: !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools) {
            isPinnedToBottom = true
            Task {
                let outcome = await engine.editUserMessageAndResend(userMessage: message, newText: text, in: conversation,
                                                                    providers: providers, context: modelContext, keepBranch: true)
                if outcome != .sent { sendBlockedReason = outcome }
            }
        }
    }

    private func sendDraft(_ options: GenerationOptions) {
        guard draft.canSend, !sendingInterruption else { return }
        if conversation.isGroupMode && engine.isGenerating(in: conversation.id) {
            let textSnapshot = draft.text
            let attachmentsSnapshot = draft.attachments
            sendingInterruption = true
            isPinnedToBottom = true
            Task {
                defer { sendingInterruption = false }
                let outcome = await engine.bargeInGroupMessage(
                    text: textSnapshot,
                    attachments: attachmentsSnapshot,
                    in: conversation,
                    providers: providers,
                    context: modelContext,
                    options: options
                )
                let sameDraft = draft.text == textSnapshot && draft.attachments == attachmentsSnapshot
                    && draft.quotedText == options.quotedExcerpt
                handleSendOutcome(outcome, clearDraft: sameDraft)
            }
            return
        }

        let outcome = engine.sendUserMessage(
            text: draft.text,
            attachments: draft.attachments,
            in: conversation,
            providers: providers,
            context: modelContext,
            options: options
        )
        handleSendOutcome(outcome, clearDraft: true)
    }

    private func handleSendOutcome(_ outcome: SendOutcome, clearDraft: Bool) {
        let usedTarget = requestOptions.temporaryTarget ?? conversation.primaryTarget
        requestOptions.finishSend(outcome, draftUnchanged: clearDraft)
        switch outcome {
        case .sent:
            isPinnedToBottom = true
            if let usedTarget {
                AppPreferences.shared.recordRecentModel(usedTarget)
            }
            guard clearDraft else { return }
            draft.text = ""
            draft.attachments = []
            draft.quotedText = nil
            saveDraft()
        case .noAvailableModel, .busy, .invalidSearch, .saveFailed:
            sendBlockedReason = outcome
        case .emptyInput:
            break
        }
    }

    private var sendBlockedTitle: String {
        switch sendBlockedReason {
        case .noAvailableModel:
            return String(localized: "还没有可用的模型")
        default:
            return String(localized: "暂时无法发送")
        }
    }

    private var sendBlockedMessage: String {
        switch sendBlockedReason {
        case .noAvailableModel:
            return conversation.assistanceSettings.automaticRouting
                ? String(localized: "请启用服务商和模型，并检查会话参数中的路由目标与识图能力。你输入的内容已保留。")
                : String(localized: "请先在「服务商」页面启用服务商并添加模型。你输入的内容已保留。")
        case .busy:
            return String(localized: "上一条回复仍在生成或正在停止，请稍候再发送。你输入的内容已保留。")
        case .invalidSearch:
            return SearchError.invalidQuery.localizedDescription
        case .saveFailed:
            return String(localized: "无法保存消息。请检查设备存储空间后重试。")
        default:
            return ""
        }
    }

    private func clearAllMessages() async {
        await engine.stopGenerationAndWait(for: conversation.id)
        do {
            clearedHistory = try BackupService.clearMessages(in: conversation, context: modelContext)
            SpotlightIndexService.shared.removeConversation(id: conversation.id)
        } catch { historyError = error.localizedDescription }
    }

    private func dismissUndoIfRestored() {
        guard let saved = clearedHistory, conversation.messages.count >= saved.messages.count else { return }
        let currentIDs = Set(conversation.messages.map(\.id))
        if saved.messages.allSatisfy({ currentIDs.contains($0.id) }) { clearedHistory = nil }
    }

    private func undoClearBar(_ saved: ConversationBackup) -> some View {
        HStack {
            Text("已清空 \(saved.messages.count) 条消息").font(.footnote)
            Spacer()
            Button("撤销清空") {
                do {
                    try BackupService.undoClear(saved, in: modelContext)
                    clearedHistory = nil
                    SpotlightIndexService.shared.indexConversation(conversation)
                } catch { historyError = error.localizedDescription }
            }
            .disabled(engine.isGenerating(in: conversation.id))
            Button { clearedHistory = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("关闭")
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private var missingKeyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("尚未连接可用于本次对话的模型")
                    .font(.footnote.weight(.semibold))
                Text(canPickConnectedModel ? String(localized: "请选择用于本次对话的已启用模型。") : String(localized: "选择服务商并验证模型连接，完成后可以继续编辑这份草稿。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(canPickConnectedModel ? String(localized: "选择模型") : String(localized: "去配置")) { beginModelSetup() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
        }
        .padding(12)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func partialUnreadyCard(_ warning: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(warning)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("调整") {
                if conversation.isGroupMode {
                    showGroupSetup = true
                } else {
                    beginModelSetup()
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(11)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var groupDiscussionControlBar: some View {
        let generating = engine.isGenerating(in: conversation.id)
        if generating {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(
                    engine.activeGroupSpeaker(in: conversation.id).map { String(localized: "\($0) 正在发言…") }
                        ?? String(localized: "群成员正在接力讨论…")
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

                Spacer()

                Text("可直接输入插话")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
        } else if hasActiveTopicAfterDivider {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        runAuthorizedGroupAction {
                            _ = engine.continueGroupDiscussion(in: conversation, providers: providers, context: modelContext)
                        }
                    } label: {
                        Label("继续聊一轮", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.13), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        runAuthorizedGroupAction {
                            _ = engine.startGroupVote(in: conversation, providers: providers, context: modelContext)
                        }
                    } label: {
                        Label("发起表决", systemImage: "hand.raised.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        ForEach(conversation.activeGroupMembers) { member in
                            Button("\(member.avatarEmoji) 由 \(member.displayLabel) 总结") {
                                runAuthorizedGroupAction {
                                    _ = engine.summarizeGroupDiscussion(by: member, in: conversation, providers: providers, context: modelContext)
                                }
                            }
                        }
                    } label: {
                        Label("总结纪要", systemImage: "list.clipboard")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.ultraThinMaterial)
        }
    }

    private func runAuthorizedGroupAction(_ action: @escaping () -> Void) {
        guard let plan = engine.sendTargets(text: "", attachments: [], in: conversation, providers: providers) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        guard plan.candidates.compactMap(\.first).contains(where: isReady) else {
            beginModelSetup()
            return
        }
        authorize(plan.candidates.flatMap { $0 }) {
            isPinnedToBottom = true
            action()
        }
    }

    private var emptyWelcomeView: some View {
        let friend = conversation.activeBookFriend
        return VStack(spacing: 16) {
            Text(conversation.assistantEmoji)
                .font(.system(size: 46))

            Text(
                friend?.byline ?? (conversation.isGroupMode
                    ? conversation.title
                    : (conversation.isArenaMode ? String(localized: "多模型并发对比已开启") : String(localized: "开始自由 AI 对话")))
            )
            .font(.title3.weight(.bold))

            Text(
                friend.map { String(localized: "和《\($0.bookTitle)》中的\($0.name)聊聊天。") } ?? (conversation.isGroupMode
                    ? String(localized: "像真人群聊一样抛出一句话，不同模型扮演的角色会互相接话、挑刺反驳或向你反问；你也可以随时输入 @ 点名或插话打断。")
                    : (conversation.isArenaMode
                        ? String(localized: "发送一条提问，同时请求多个服务商模型并排比对思考链与答案质量。")
                        : String(localized: "支持随时在底部切换不同服务商的模型接力回答，也可发送图片与 PDF 文档。")))
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            if conversation.isGroupMode && !conversation.groupMembers.isEmpty {
                VStack(spacing: 8) {
                    FlowGroupRosterPreview(members: conversation.groupMembers)
                    Button {
                        showGroupSetup = true
                    } label: {
                        Label("调整群成员与发言规则", systemImage: "person.3.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(spacing: 8) {
                if friend != nil {
                    quickSuggestionButton(String(localized: "你好，可以讲讲你的故事吗？"))
                    quickSuggestionButton(String(localized: "遇到难以决定的事时，你会怎么做？"))
                } else if conversation.isGroupMode {
                    quickSuggestionButton(String(localized: "我想做一个面向独立开发者的订阅记账工具，大家觉得有戏吗？"))
                    quickSuggestionButton(String(localized: "手里有两个 Offer：大厂边缘部门涨薪 30% vs 明星创业公司早期期权，怎么选？"))
                    quickSuggestionButton(String(localized: "@所有人 帮我从各自角度挑一下这套新方案最容易翻车的风险点"))
                } else if conversation.assistanceSettings.studyCoachMode == .socratic {
                    quickSuggestionButton(String(localized: "我想真正吃透 Swift Concurrency 的 Actor 隔离机制，请用苏格拉底式提问引导我。"))
                    quickSuggestionButton(String(localized: "请帮我循序渐进掌握动态规划的状态转移推导方法。"))
                } else if conversation.assistanceSettings.studyCoachMode == .feynman {
                    quickSuggestionButton(String(localized: "下面我用自己的话给你讲一遍 HTTPS 握手流程，请你扮演挑刺学生追问漏洞。"))
                    quickSuggestionButton(String(localized: "我来试着解释 Transformer 的注意力机制，请指出我没讲透的地方。"))
                } else if conversation.assistanceSettings.studyCoachMode == .drill {
                    quickSuggestionButton(String(localized: "给我开启 SQL 窗口函数实战闯关特训（从 Lv.1 开始出题）。"))
                    quickSuggestionButton(String(localized: "考考我正则表达式进阶语法，每次出一道实战题等我作答。"))
                } else {
                    quickSuggestionButton(String(localized: "帮我对比一下 Swift Actor 和传统锁的性能与适用场景"))
                    quickSuggestionButton(String(localized: "用通俗生动的语言解释 Transformer 的自注意力机制"))
                    quickSuggestionButton(String(localized: "帮我写一段高质量的 Python 异步并发请求模板"))
                }
            }
            .padding(.top, 6)
        }
    }

    private func quickSuggestionButton(_ prompt: String) -> some View {
        Button {
            draft.text = prompt
        } label: {
            HStack {
                Text(prompt)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FlowGroupRosterPreview: View {
    let members: [GroupMember]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(members) { member in
                    HStack(spacing: 6) {
                        Text(member.avatarEmoji)
                            .font(.subheadline)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.displayLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(member.isMuted ? .secondary : .primary)
                            Text(member.target.modelDisplayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: member.accentHex).opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct IdentifiableUUID: Identifiable {
    let id: UUID
}

private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct StreamingAutoScroller: View {
    let conversation: Conversation
    let proxy: ScrollViewProxy
    let isEnabled: Bool

    @State private var lastScrollTime: ContinuousClock.Instant = .now - .seconds(1)
    @State private var trailingTask: Task<Void, Never>?

    private var streamedLength: Int {
        conversation.messages.reduce(0) { total, message in
            message.isStreaming
                ? total + message.content.utf8.count + message.reasoningContent.utf8.count
                : total
        }
    }

    var body: some View {
        Color.clear
            .onChange(of: streamedLength) { _, newValue in
                guard isEnabled else {
                    trailingTask?.cancel()
                    return
                }
                let now = ContinuousClock.now
                if newValue == 0 || lastScrollTime.duration(to: now) >= .milliseconds(75) {
                    trailingTask?.cancel()
                    lastScrollTime = now
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                } else if trailingTask == nil {
                    trailingTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(75))
                        defer { trailingTask = nil }
                        guard !Task.isCancelled, isEnabled else { return }
                        lastScrollTime = .now
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                }
            }
            .onDisappear { trailingTask?.cancel() }
    }
}

private enum TimelineEntry: Identifiable {
    case single(ChatMessage)
    case arenaGroup(UUID, [ChatMessage])

    var id: String {
        switch self {
        case .single(let m): return m.id.uuidString
        case .arenaGroup(let gid, _): return "group-\(gid.uuidString)"
        }
    }

    static func build(from sorted: [ChatMessage]) -> [TimelineEntry] {
        var result: [TimelineEntry] = []
        var index = 0
        while index < sorted.count {
            let current = sorted[index]
            if let gid = current.comparisonGroupID {
                var group: [ChatMessage] = [current]
                var lookahead = index + 1
                while lookahead < sorted.count, sorted[lookahead].comparisonGroupID == gid {
                    group.append(sorted[lookahead])
                    lookahead += 1
                }
                result.append(.arenaGroup(gid, group))
                index = lookahead
            } else {
                result.append(.single(current))
                index += 1
            }
        }
        return result
    }
}
