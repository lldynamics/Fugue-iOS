import SwiftUI
import SwiftData
import UIKit

struct ChatDetailView: View {
    @Bindable var conversation: Conversation
    let isLandingDraft: Bool
    var onOpenConversation: ((Conversation) -> Void)?
    var onToggleDrawer: (() -> Void)?
    @State private var pendingPhoneEntry: PhoneComposeEntry?

    @Environment(WorkspaceNavigation.self) private var workspaceNavigation: WorkspaceNavigation?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.usesPhoneWorkspace) private var usesPhoneWorkspace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]

    private enum ReadingSplitLayout: String, CaseIterable, Identifiable {
        case bookOnly
        case split
        case chatOnly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .bookOnly: return String(localized: "沉浸阅读")
            case .split: return String(localized: "书聊并排")
            case .chatOnly: return String(localized: "聚焦对话")
            }
        }
    }

    @State private var draft: ChatDraftState
    @State private var readingRequest: ReadingRequest?
    @State private var showsShelfReader = false
    @State private var showPadInspector = false
    @State private var readingSplitLayout: ReadingSplitLayout = .split
    @State private var readingSplitFraction: CGFloat = 0.56
    @State private var readingDragStartFraction: CGFloat?
    @State private var citationVolumeID: UUID?
    @State private var citationPlace = BookReadingPlace()
    @State private var readingPlace = BookReadingPlace()
    @State private var hasInlineBook = false
    @State private var sheetHandoff = SheetHandoffState<ChatActiveSheet>()
    @State private var pendingSheetDismissAction: (() -> Void)?
    @State private var pendingReaderCoverDismissAction: (() -> Void)?
    @State private var infoAlert: ChatAlertItem?
    @State private var modelDirectory = ChatModelDirectory()
    @State private var checkingFeeds = false
    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var sendBlockedReason: SendOutcome?
    @State private var sendingInterruption = false
    @State private var pendingScrollMessageID: UUID?
    @State private var questionNavigationAnchor: UUID?
    @State private var arenaSearchFocus: MessageSearchFocus?
    @State private var isGeneratingTitle = false
    @State private var confirmClear = false
    @State private var clearedHistory: ConversationBackup?
    @State private var consent = AIConsentGate()
    @State private var requestOptions = ComposerRequestOptions()
    @State private var sendReview: ChatSendReview?
    @State private var reviewedSend: (() -> Void)?
    @State private var preferences = AppPreferences.shared
    @State private var entryRouter = SystemEntryRouter.shared
    @State private var externalDocumentScanTrigger = 0
    @FocusState private var inputFocused: Bool

    @State private var isPinnedToBottom = true
    @State private var isUserScrolling = false

    init(
        conversation: Conversation,
        initialMessageID: UUID? = nil,
        isLandingDraft: Bool = false,
        onOpenConversation: ((Conversation) -> Void)? = nil,
        onToggleDrawer: (() -> Void)? = nil,
        phoneEntry: PhoneComposeEntry? = nil
    ) {
        self.isLandingDraft = isLandingDraft
        self.conversation = conversation
        self.onOpenConversation = onOpenConversation
        self.onToggleDrawer = onToggleDrawer
        _pendingPhoneEntry = State(initialValue: phoneEntry)
        _pendingScrollMessageID = State(initialValue: initialMessageID)
        _isPinnedToBottom = State(initialValue: initialMessageID == nil)
        _draft = State(initialValue: ChatDraftStore.shared.state(for: conversation.id))
    }

    private var engine: ChatEngine { ChatEngine.shared }
    private var theme: DS.AccentTheme { preferences.accentTheme }

    private func openBookConversation(_ chat: Conversation) {
        if let onOpenConversation { onOpenConversation(chat) }
        else { SystemEntryRouter.shared.conversationID = chat.id }
    }

    private var activeMessages: [ChatMessage] {
        ConversationTree.activeMessages(in: conversation)
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
        } else if let primary = requestOptions.temporaryTarget ?? conversation.primaryTarget {
            targets = [primary] + AssistancePolicy.fallbacks(after: primary, settings: conversation.assistanceSettings,
                providers: providers, requiresVision: draft.attachments.contains { $0.kind == .image })
        } else {
            return true
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
        let protected = [AppPreferences.shared.defaultTargetID, conversation.assistanceSettings.privatePersona?.target.id].compactMap { $0 }
        let awaitingActivation = Set(providers.filter { $0.isRestoredFromBackup && !$0.hasConfiguredChatAPI }.map(\.id))
        conversation.updateDraftModel(from: available, replacingLegacy: Set(legacyIDs).subtracting(protected),
                                      preservingUnavailableProviders: awaitingActivation)
        let selections = conversation.isArenaMode ? conversation.arenaTargets : [conversation.primaryTarget].compactMap { $0 }
        let ids = Set(selections.map(\.providerID))
        modelDirectory.update(configured: configured, automaticIDs: ids.isEmpty && chooseInitial ? nil : ids, in: modelContext)
    }

    private func quoteAndFocus(_ text: String) {
        draft.quotedText = String(text.prefix(600))
        draft.save()
        if usesPhoneWorkspace { inputFocused = true }
    }

    private func messageActions(for msg: ChatMessage) -> MessageRowActions {
        MessageRowActions(
            onOpenCitation: openCitation,
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
            onQuote: msg.role == .system ? nil : quoteAndFocus,
            onToggleBookmark: msg.role == .system ? nil : {
                engine.toggleBookmark(for: msg, context: modelContext)
            },
            onToggleExcludeFromContext: (!preferences.simpleDailyMode && msg.role != .system) ? {
                engine.toggleContextExclusion(for: msg, context: modelContext)
            } : nil,
            onForkConversation: (!preferences.simpleDailyMode && msg.role != .system) ? {
                let forked = engine.forkConversation(upTo: msg, in: conversation, context: modelContext)
                onOpenConversation?(forked)
            } : nil,
            onCompareWithModel: (preferences.showsArena && !conversation.isGroupMode && msg.role == .assistant && msg.comparisonGroupID == nil) ? { second in
                authorize([second]) {
                    engine.compareWithAnotherModel(assistantMessage: msg, secondTarget: second,
                                                   in: conversation, providers: providers, context: modelContext)
                }
            } : nil,
            onMentionMember: conversation.isGroupMode ? { memberID in
                guard let member = conversation.activeGroupMembers.first(where: { $0.id == memberID }) else { return }
                draft.insertGroupMention("@\(member.mentionToken)", memberID: member.id)
            } : nil,
            onDeleteMessage: {
                Task {
                    await engine.deleteSingleMessage(msg, in: conversation, context: modelContext)
                }
            },
            onToggleSpeak: msg.role == .assistant ? {
                toggleSpeechWithOptionalCloud(for: msg)
            } : nil
        )
    }

    private var timelineAndComposer: some View { conversationTimeline() }

    private func conversationTimeline(voice: LiveVoiceSession? = nil) -> some View {
        // Completed turns are already in SwiftData while their live captions are still visible.
        let callIDs = Set(voice?.lines.map(\.id) ?? [])
        let currentActiveMessages = activeMessages.filter { !callIDs.contains($0.id) }
        let items = TimelineEntry.build(from: currentActiveMessages)
        let promptMilestones = ChatTopicScrubberView.PromptMilestone.questions(in: currentActiveMessages)

        return ScrollViewReader { proxy in
            let timeline = ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        if voice == nil && needsAPIKeyBanner && conversation.readingVolumeID == nil && (!usesPhoneWorkspace || conversation.isGroupMode || conversation.isArenaMode) {
                            missingKeyCard
                        } else if let unreadyPeerSummary {
                            partialUnreadyCard(unreadyPeerSummary)
                        }

                        if items.isEmpty && voice != nil {
                            EmptyView()
                        } else if items.isEmpty && conversation.readingVolumeID != nil {
                            Text("可以就原文提问，也可以长按段落引用。")
                                .foregroundStyle(.secondary).padding()
                        } else if items.isEmpty {
                            emptyWelcomeView
                                .padding(.top, 36)
                        } else {
                            let siblingsByID = ConversationTree.branchSiblingsMap(in: conversation)
                            let latestPromptID = currentActiveMessages.last(where: { $0.role == .user })?.id
                            let compareTargets = availableTargets
                            ForEach(items) { entry in
                                switch entry {
                                case .single(let msg):
                                    MessageRowView(
                                        message: msg,
                                        branchSiblings: siblingsByID[msg.id] ?? [msg],
                                        availableCompareTargets: compareTargets,
                                        actions: messageActions(for: msg),
                                        conversationID: conversation.id,
                                        showsPromptActions: msg.role != .user || msg.id == latestPromptID
                                    )
                                    .id(entry.id)

                                case .arenaGroup(let gid, let groupMsgs):
                                    ArenaComparisonGroupView(
                                        groupID: gid,
                                        messages: groupMsgs,
                                        isGenerating: engine.isGenerating(in: conversation.id),
                                        searchFocus: arenaSearchFocus?.groupID == gid ? arenaSearchFocus : nil,
                                        onFollowUp: { reply in
                                            do {
                                                try engine.selectContextReply(reply, in: conversation, context: modelContext)
                                                inputFocused = true
                                            } catch { presentHistoryError(error.localizedDescription) }
                                        },
                                        onRegenerateSingle: { retry($0) },
                                        onContinueSingle: { continueReply($0) },
                                        onSelectRevision: { single, idx in
                                            engine.selectRevision(index: idx, for: single, context: modelContext)
                                        },
                                        onQuote: quoteAndFocus,
                                        onToggleBookmark: { single in
                                            engine.toggleBookmark(for: single, context: modelContext)
                                        },
                                        onForkConversation: { single in
                                            let forked = engine.forkConversation(upTo: single, in: conversation, context: modelContext)
                                            onOpenConversation?(forked)
                                        },
                                        onSynthesize: {
                                            presentSheet(.synthesis(gid))
                                        }
                                    )
                                    .id(entry.id)
                                }
                            }
                            .disabled(voice != nil)
                        }
                        if let voice {
                            LiveTranscriptSection(voice: voice)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Color.clear
                            .frame(height: 4)
                            .id("BOTTOM_ANCHOR")
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: horizontalSizeClass == .regular && !conversation.isArenaMode ? 820 : .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.md)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: voice?.lines.last?.text, initial: true) {
                    if voice != nil && isPinnedToBottom { proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom) }
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.1) { ids in
                    guard isUserScrolling else { return }
                    let visible = Set(ids)
                    if let first = items.first(where: { visible.contains($0.id) }) {
                        switch first {
                        case .single(let message): questionNavigationAnchor = message.id
                        case .arenaGroup(_, let messages): questionNavigationAnchor = messages.first?.id
                        }
                    }
                }
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
                    questionNavigationAnchor = id
                    isPinnedToBottom = false
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(focus.anchorID, anchor: .top)
                    pendingScrollMessageID = nil
                }

                if voice == nil && promptMilestones.count >= 3 {
                    ChatTopicScrubberView(milestones: promptMilestones, openDirectory: { presentSheet(.questionDirectory) }) { targetMessageID in
                        questionNavigationAnchor = targetMessageID
                        isPinnedToBottom = false
                        withAnimation(.snappy(duration: 0.22)) {
                            proxy.scrollTo(targetMessageID.uuidString, anchor: .top)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.trailing, 2)
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
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(DS.Surface.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, DS.Spacing.lg)
                    .padding(.bottom, 14)
                }
            }
            if voice != nil {
                timeline
            } else if usesPhoneWorkspace {
                VStack(spacing: 0) {
                    timeline
                    timelineFooter
                        .background(DS.Surface.canvas)
                        .overlay(alignment: .top) { Divider().accessibilityHidden(true) }
                }
            } else {
                timeline.safeAreaInset(edge: .bottom) { timelineFooter }
            }
        }
    }

    private var timelineFooter: some View {
        VStack(spacing: 0) {
            if let clearedHistory { undoClearBar(clearedHistory) }
            if let pending = engine.pendingWebpageApproval(in: conversation.id) { webpageApprovalBar(pending) }
            if conversation.isGroupMode { groupDiscussionControlBar }
            composer(writingFirst: false)
        }
    }

    private var writingFirst: Bool {
        conversation.messages.isEmpty && !conversation.isArenaMode && !conversation.isGroupMode &&
        conversation.activeBookFriend == nil && conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty &&
        clearedHistory == nil
    }

    private var routedTarget: ResolvedModelTarget? {
        let settings = conversation.assistanceSettings
        guard !conversation.isArenaMode, !conversation.isGroupMode, requestOptions.temporaryTarget == nil,
              settings.automaticRouting, let primary = conversation.primaryTarget else { return nil }
        return AssistancePolicy.route(primary: primary, settings: settings, text: draft.text,
                                      attachments: draft.attachments, providers: providers)
    }

    private func modelPickerButton(title: String? = nil) -> some View {
        let target = requestOptions.temporaryTarget ?? routedTarget ?? conversation.primaryTarget
        let actionTitle = canPickConnectedModel ? String(localized: "选择模型") : String(localized: "连接模型")
        return ChatModelPickerButton(conversationTitle: title,
                                     modelName: needsAPIKeyBanner ? actionTitle : (target?.modelDisplayName ?? actionTitle),
                                     action: beginModelSetup)
            .disabled(engine.isGenerating(in: conversation.id))
    }

    private func knowledgeMenu(compact: Bool = false) -> some View {
        BoundKnowledgeMenu(ids: conversation.assistanceSettings.knowledgeVolumeIDs,
                           omitted: $requestOptions.omitKnowledge, compact: compact,
                           canManage: !engine.isGenerating(in: conversation.id),
                           onManage: conversation.activeBookFriend == nil ? { presentSheet(.knowledge) } : nil)
    }

    private func composer(writingFirst: Bool) -> some View {
        ComposerBarView(
            conversation: conversation,
            draft: draft,
            providers: providers,
            presets: presets,
            routedTarget: routedTarget,
            isGenerating: engine.isGenerating(in: conversation.id),
            requestOptions: $requestOptions,
            onOpenModelPicker: beginModelSetup,
            onOpenArenaPicker: { presentSheet(.arena) },
            onOpenGroupSetup: { presentSheet(.groupSetup) },
            onOpenOptions: { presentSheet(.options) },
            onManageKnowledge: { presentSheet(.knowledge) },
            onOpenLiveCall: conversation.isGroupMode || conversation.isArenaMode ? nil : {
                inputFocused = false
                presentSheet(.liveCall)
            },
            onOpenAudioTranscription: { presentSheet(.audioTranscription) },
            externalDocumentScanTrigger: externalDocumentScanTrigger,
            writingFirst: writingFirst,
            needsModel: needsAPIKeyBanner,
            canChooseModel: canPickConnectedModel,
            inputFocus: $inputFocused,
            phoneEntry: $pendingPhoneEntry,
            onInsertContextDivider: {
                engine.insertContextDivider(in: conversation, context: modelContext)
            },
            onSend: { handleSend() },
            onStop: { engine.stopGeneration(for: conversation.id) }
        )
    }

    private var writingWorkspace: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    HStack(spacing: DS.Spacing.md) {
                        FugueSealMark(character: "夜", size: 42, theme: theme)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("今晚想推演什么问题？")
                                .font(.system(.title3, design: preferences.literarySerifBody ? .serif : .default).weight(.bold))
                                .foregroundStyle(.primary)
                            Text("支持拖入文档与图片提问 · ⌘K 快速切换对话与书架")
                                .font(.footnote)
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.top, DS.Spacing.xs)

                    composer(writingFirst: true)

                    if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if let workspaceNavigation, geometry.size.width >= 600 {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 190), spacing: DS.Spacing.sm)],
                                spacing: DS.Spacing.sm
                            ) {
                                padQuickEntryCard(
                                    title: String(localized: "打开书架精读"),
                                    subtitle: String(localized: "双栏原文伴读、批注与语义检索"),
                                    symbol: "books.vertical.fill"
                                ) {
                                    workspaceNavigation.openBookshelf()
                                }
                                if preferences.showsArena {
                                    padQuickEntryCard(
                                        title: String(localized: "开启多模型对比"),
                                        subtitle: String(localized: "并排比对思考链与裁判汇总"),
                                        symbol: "square.split.2x1.fill"
                                    ) {
                                        presentSheet(.arena)
                                    }
                                }
                                if preferences.showsBookFriends {
                                    padQuickEntryCard(
                                        title: String(localized: "好友与圆桌"),
                                        subtitle: String(localized: "书中好友伴读与持续记忆"),
                                        symbol: "person.2.fill"
                                    ) {
                                        workspaceNavigation.openFriends()
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text("推演灵感")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DS.Surface.inkSecondary)
                                .padding(.horizontal, 2)

                            quickSuggestionButton(String(localized: "帮我对比一下 Swift Actor 和传统锁的性能与适用场景"))
                            quickSuggestionButton(String(localized: "用通俗生动的语言解释 Transformer 的自注意力机制"))
                            quickSuggestionButton(String(localized: "帮我写一段高质量的 Python 异步并发请求模板"))
                        }
                        .padding(.top, DS.Spacing.xxs)
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, geometry.size.width >= 600 ? 36 : 16)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: geometry.size.width < 600 ? .top : .center)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func padQuickEntryCard(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            preferences.triggerSelectionHaptic()
            action()
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.readableText)
                    .frame(width: 28, height: 28)
                    .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(verbatim: subtitle)
                        .font(.caption2)
                        .foregroundStyle(DS.Surface.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.Surface.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private var phoneWritingWorkspace: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            composer(writingFirst: true).padding(.bottom, DS.Spacing.sm)
        }
    }

    private var phoneStartModeMenu: some View {
        ChatStartModeMenu(
            isGenerating: engine.isGenerating(in: conversation.id),
            onOpenArena: { presentSheet(.arena) },
            onOpenGroup: { presentSheet(.groupSetup) },
            onOpenOptions: { presentSheet(.options) }
        )
    }

    /// An untouched home has no history entry. Activate the same draft object on first use.
    private func activateLandingDraft() {
        guard isLandingDraft, conversation.modelContext == nil, !conversation.isDeleted else { return }
        modelContext.insert(conversation)
        do { try modelContext.save() }
        catch { presentHistoryError(error.localizedDescription) }
    }

    private var draftProviderFingerprint: [String] {
        conversation.messages.isEmpty ? SystemIntegration.fingerprint(providers) : []
    }

    private func webpageApprovalBar(_ request: ChatEngine.PendingWebpageApproval) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("确认读取外部网页？").font(.headline)
            ScrollView {
                Text("AI 请求访问你未直接输入的外部链接：\n\(request.url.absoluteString)")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 76)
            HStack {
                Button("允许本次") {
                    engine.resolvePendingWebpageApproval(id: request.id, decision: .allow, rememberHost: false)
                }
                Button("拒绝", role: .cancel) {
                    engine.resolvePendingWebpageApproval(id: request.id, decision: .deny, rememberHost: false)
                }
            }
            .buttonStyle(.bordered)
            if request.url.query == nil {
                Button("本对话始终允许 \(request.host)") {
                    engine.resolvePendingWebpageApproval(id: request.id, decision: .allow, rememberHost: true)
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if let volumeID = conversation.readingVolumeID {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 720
                let showBook = wide && readingSplitLayout != .chatOnly
                let showChat = !wide || readingSplitLayout != .bookOnly

                HStack(spacing: 0) {
                    if showBook {
                        VStack(spacing: 0) {
                            if readingSplitLayout == .bookOnly {
                                HStack {
                                    Spacer()
                                    readingLayoutPicker
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: DS.TouchTarget.minimum)
                                Divider()
                            }
                            originalBook(defaultID: volumeID)
                        }
                        .frame(
                            width: readingSplitLayout == .bookOnly
                                ? geometry.size.width
                                : max(300, min(geometry.size.width - 300, geometry.size.width * readingSplitFraction))
                        )
                    }

                    if showBook && showChat {
                        readingSplitDivider(totalWidth: geometry.size.width)
                    }

                    if showChat {
                        VStack(spacing: 0) {
                            HStack(spacing: DS.Spacing.sm) {
                                if !usesPhoneWorkspace && conversation.activeBookFriend != nil {
                                    modelPickerButton()
                                }
                                if !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty {
                                    knowledgeMenu(compact: conversation.activeBookFriend != nil && !wide)
                                }
                                Spacer(minLength: 0)
                                if wide {
                                    readingLayoutPicker
                                } else {
                                    Button {
                                        citationVolumeID = nil
                                        readingRequest = nil
                                        presentSheet(.originalBook)
                                    } label: {
                                        Label(dynamicTypeSize.isAccessibilitySize ? String(localized: "原文") : String(localized: "查看原文"),
                                              systemImage: "book")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                                    }
                                    .accessibilityLabel("查看原文")
                                        .tint(.primary)
                                        .accessibilityIdentifier("reading.open")
                                }
                            }
                            .padding(.horizontal, 16).frame(minHeight: DS.TouchTarget.minimum)
                            Divider()
                            timelineAndComposer
                        }
                    }
                }
                .onChange(of: SystemEntryRouter.shared.openOriginalForChatID, initial: true) { _, id in
                    guard id == conversation.id else { return }
                    SystemEntryRouter.shared.openOriginalForChatID = nil
                    citationVolumeID = nil
                    readingRequest = nil
                    if wide {
                        if readingSplitLayout == .chatOnly { readingSplitLayout = .split }
                        return
                    }
                    ModalPresentationGate.performWhenClear(
                        extraCheck: {
                            workspaceNavigation?.activeModal != nil || sheetHandoff.isPresentingOrDismissing
                        }
                    ) {
                        guard !hasInlineBook, !conversation.isDeleted, conversation.readingVolumeID != nil else { return }
                        showsShelfReader = true
                    }
                }
                .onChange(of: wide, initial: true) { _, value in
                    hasInlineBook = value
                    if value { showsShelfReader = false }
                }
            }
            .onDisappear { hasInlineBook = false }
        } else if writingFirst {
            if usesPhoneWorkspace { phoneWritingWorkspace } else { writingWorkspace }
        } else {
            timelineAndComposer
        }
    }

    private var readingLayoutPicker: some View {
        Picker("阅读布局", selection: $readingSplitLayout) {
            ForEach(ReadingSplitLayout.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 250)
        .accessibilityIdentifier("reading.layoutMode")
    }

    private func readingSplitDivider(totalWidth: CGFloat) -> some View {
        ZStack {
            Divider()
            Capsule()
                .fill(DS.Surface.strongBorder)
                .frame(width: 4, height: 36)
        }
        .frame(width: 14)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = readingDragStartFraction ?? readingSplitFraction
                    if readingDragStartFraction == nil { readingDragStartFraction = start }
                    let delta = value.translation.width / max(totalWidth, 1)
                    readingSplitFraction = min(max(start + delta, 0.36), 0.72)
                }
                .onEnded { _ in
                    readingDragStartFraction = nil
                }
        )
        .accessibilityLabel("调节原文与对话分栏宽度")
    }

    private func openCitation(_ citation: ReadingCitation) {
        if let friend = conversation.activeBookFriend, citation.volumeID != friend.bookID { return }
        citationVolumeID = citation.volumeID
        readingRequest = ReadingRequest(citation: citation)
        if hasInlineBook {
            if readingSplitLayout == .chatOnly {
                withAnimation(.snappy(duration: 0.22)) {
                    readingSplitLayout = .split
                }
            }
        } else {
            presentSheet(.originalBook)
        }
    }

    private func originalBook(defaultID: UUID) -> some View {
        let id = citationVolumeID ?? conversation.activeBookFriend?.bookID ?? defaultID
        let limit = conversation.readingChapterLimits[id]
        return BookOriginalView(volumeID: id, throughChapter: limit, request: $readingRequest,
                                place: citationVolumeID == nil ? $readingPlace : $citationPlace,
                                companionID: citationVolumeID == nil && conversation.isCompanion(for: id) ? conversation.id : nil,
                                openShelf: workspaceNavigation.map { navigation in
                                    {
                                        if showsShelfReader {
                                            pendingReaderCoverDismissAction = { navigation.openBookshelf() }
                                            showsShelfReader = false
                                        } else if sheetHandoff.active != nil || sheetHandoff.isPresentingOrDismissing {
                                            dismissActiveSheet { navigation.openBookshelf() }
                                        } else {
                                            navigation.openBookshelf()
                                        }
                                    }
                                }) { citation in
            do { try draft.addReadingCitation(citation) }
            catch { presentHistoryError(error.localizedDescription); return }
            if sheetHandoff.active == .originalBook { dismissActiveSheet() }
            showsShelfReader = false
            inputFocused = true
        }
        .id("\(id)-\(limit ?? -1)-\(citationVolumeID != nil)")
    }

    private func readerNavigation(for id: UUID, close: @escaping () -> Void) -> some View {
        NavigationStack {
            originalBook(defaultID: id)
                .navigationTitle("原文").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: close) } }
        }
    }

    private var chatWithToolbar: some View {
        HStack(spacing: 0) {
            workspaceContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if usesDockedInspector && showPadInspector {
                Divider()
                dockedInspectorPanel
                    .frame(width: 312)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: showPadInspector)
        .background(DS.Surface.canvas.ignoresSafeArea())
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let onToggleDrawer {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onToggleDrawer) {
                        Image(systemName: "line.3.horizontal")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("对话列表")
                    .accessibilityIdentifier("chat.history")
                }
            }
            ToolbarItem(placement: .principal) {
                if let friend = conversation.activeBookFriend {
                    BookChatHeading(friend: friend, title: conversation.title) { presentSheet(.bookProgress) }
                        .disabled(engine.isGenerating(in: conversation.id))
                } else if !conversation.isArenaMode && !conversation.isGroupMode {
                    if usesPhoneWorkspace || writingFirst {
                        Text(verbatim: conversation.title).font(.headline).lineLimit(1)
                    } else {
                        modelPickerButton(title: conversation.title)
                    }
                } else {
                    Button {
                        presentSheet(conversation.isGroupMode ? .groupSetup : .arena)
                    } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: conversation.title).font(.headline).lineLimit(1)
                            HStack(spacing: 4) {
                                if conversation.isGroupMode { Text("群聊 · \(conversation.activeGroupMembers.count) 人") }
                                else { Text("并发对比 · \(conversation.arenaTargets.count) 模型") }
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if (conversation.isGroupMode || conversation.isArenaMode) && !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { knowledgeMenu(compact: true) }
            }
            if usesPhoneWorkspace && writingFirst {
                ToolbarItem(placement: .topBarTrailing) { phoneStartModeMenu }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    preferences.triggerSelectionHaptic()
                    if usesDockedInspector {
                        withAnimation(.snappy(duration: 0.22)) {
                            showPadInspector.toggle()
                        }
                    } else {
                        presentSheet(.inspector)
                    }
                } label: {
                    Image(systemName: usesDockedInspector && showPadInspector ? "sidebar.right" : "sidebar.right")
                        .symbolVariant(usesDockedInspector && showPadInspector ? .fill : .none)
                }
                .accessibilityLabel("会话检视器")
                .accessibilityIdentifier("chat.inspector")
            }
            if !FriendMemorySubject.subjects(in: conversation).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentSheet(.friendMemory)
                    } label: {
                        Image(systemName: "brain.head.profile")
                    }
                    .accessibilityLabel("好友持续记忆")
                    .accessibilityIdentifier("chat.friendMemory")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        presentSheet(.settings)
                    } label: {
                        Label("系统提示词与参数", systemImage: "slider.horizontal.3")
                    }
                    .keyboardShortcut(",", modifiers: [.command, .shift])

                    if !FriendMemorySubject.subjects(in: conversation).isEmpty {
                        Button {
                            presentSheet(.friendMemory)
                        } label: {
                            Label("好友持续记忆", systemImage: "brain.head.profile")
                        }
                    }

                    if conversation.activeBookFriend != nil {
                        Divider()
                        if preferences.showsGroupChat {
                            Button { presentSheet(.bookInvitation) } label: { Label("邀请进群", systemImage: "person.2.badge.plus") }
                        }
                        Button { presentSheet(.bookProgress) } label: { Label("调整阅读进度", systemImage: "bookmark") }
                            .disabled(engine.isGenerating(in: conversation.id))
                    }

                    Divider()

                    Button {
                        presentSheet(.search)
                    } label: {
                        Label("会话内查找与收藏", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    if activeMessages.contains(where: { $0.role == .user }) {
                        Button { presentSheet(.questionDirectory) } label: { Label("问题目录", systemImage: "list.number") }
                            .accessibilityIdentifier("chat.questionDirectory")
                    }


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

                    if preferences.showsArena || conversation.isArenaMode {
                        Button {
                            presentSheet(.arena)
                        } label: {
                            Label("配置多模型并发对比", systemImage: "square.split.2x1")
                        }
                        .disabled(engine.isGenerating(in: conversation.id))
                    }

                    if conversation.isGroupMode || preferences.showsGroupChat {
                        Button { presentSheet(.groupSetup) } label: {
                            Label("配置圆桌群聊角色", systemImage: "person.3")
                        }
                    }

                    if PersonaFeedService.hasSubscriptions(conversation) {
                        Button {
                            checkingFeeds = true
                            Task {
                                let report = await PersonaFeedService.shared.refresh(in: modelContext, chatID: conversation.id, force: true)
                                infoAlert = ChatAlertItem(title: String(localized: "成员订阅动态"), message: report.message)
                                checkingFeeds = false
                            }
                        } label: { Label("检查成员动态", systemImage: "arrow.clockwise") }
                        .disabled(checkingFeeds)
                    }

                    Divider()

                    Button {
                        presentSheet(.conversationExport)
                    } label: {
                        Label("分享与导出", systemImage: "square.and.arrow.up")
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
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多操作")
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
        .onChange(of: conversation.id) { oldID, newID in
            guard oldID != newID else { return }
            SpeechService.shared.stopDictationIfActive()
            saveDraft()
            draft = ChatDraftStore.shared.state(for: newID)
            loadDraft()
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
        .alert(
            infoAlert?.title ?? String(localized: "操作失败"),
            isPresented: Binding(get: { infoAlert != nil }, set: { if !$0 { infoAlert = nil } })
        ) {
            Button("好", role: .cancel) { infoAlert = nil }
        } message: { Text(verbatim: infoAlert?.message ?? "") }
        .aiConsentSheet(consent)
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveDraft() } }
        .onChange(of: inputFocused) { _, focused in if focused && !usesPhoneWorkspace { activateLandingDraft() } }
        .onChange(of: sheetHandoff.active) { _, sheet in if sheet != nil { activateLandingDraft() } }
        .onChange(of: draft.processingAttachments) { _, count in if count > 0 { activateLandingDraft() } }
        .onChange(of: draft.attachments) { _, items in if !items.isEmpty { activateLandingDraft() } }
        .onChange(of: draft.text) { _, _ in
            activateLandingDraft()
            draft.scheduleAutosave()
        }
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
    }

    private var usesDockedInspector: Bool {
        !usesPhoneWorkspace && horizontalSizeClass == .regular
    }

    private var dockedInspectorPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话检视器")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        showPadInspector = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.Surface.inkSecondary)
                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("关闭")
            }
            .padding(.leading, DS.Spacing.lg)
            .padding(.trailing, DS.Spacing.xs)
            .frame(minHeight: DS.TouchTarget.minimum)
            .background(DS.Surface.grouped)

            Divider()

            ChatContextInspectorContent(
                conversation: conversation,
                providers: providers,
                omitKnowledgeOnce: $requestOptions.omitKnowledge,
                onOpenModelPicker: {
                    beginModelSetup()
                },
                onOpenKnowledgePicker: {
                    presentSheet(.knowledge)
                },
                onOpenFullSettings: {
                    presentSheet(.settings)
                },
                onOpenCitation: { citation in
                    openCitation(citation)
                }
            )
        }
        .background(DS.Surface.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.inspectorPanel")
    }

    var body: some View {
        chatWithDraftControls
        .onReceive(NotificationCenter.default.publisher(for: .fugueToggleInspector)) { _ in
            guard usesDockedInspector else { return }
            withAnimation(.snappy(duration: 0.22)) {
                showPadInspector.toggle()
            }
        }
        .onChange(of: conversation.readingVolumeID) { _, _ in
            readingRequest = nil
            citationVolumeID = nil
            citationPlace = BookReadingPlace()
            readingPlace = BookReadingPlace()
        }
        .sheet(item: $sheetHandoff.active, onDismiss: handleActiveSheetDismiss) { sheet in
            sheetContent(for: sheet)
        }
        .sheet(item: $sendReview, onDismiss: {
            let action = reviewedSend
            reviewedSend = nil
            action?()
        }) { review in
            ChatSendReviewSheet(review: review) { selected in
                reviewedSend = { review.send(selected) }
                sendReview = nil
            }
        }
        .onChange(of: entryRouter.pendingChatToolRequest, initial: true) { _, request in
            guard let request, request.conversationID == conversation.id else { return }
            entryRouter.pendingChatToolRequest = nil
            pendingReaderCoverDismissAction = nil
            showsShelfReader = false
            reviewedSend = nil
            sendReview = nil
            if request.tool == .scanDocument {
                dismissActiveSheet()
            } else if sheetHandoff.active != nil && sheetHandoff.active != .audioTranscription {
                dismissActiveSheet()
            }
            ModalPresentationGate.performWhenClear(
                extraCheck: {
                    workspaceNavigation?.activeModal != nil
                        || showsShelfReader
                        || sendReview != nil
                        || (request.tool == .scanDocument && sheetHandoff.isPresentingOrDismissing)
                }
            ) {
                guard !conversation.isDeleted else { return }
                switch request.tool {
                case .voiceNote:
                    presentSheet(.audioTranscription)
                case .scanDocument:
                    externalDocumentScanTrigger += 1
                }
            }
        }
        .fullScreenCover(isPresented: $showsShelfReader, onDismiss: handleReaderCoverDismiss) {
            if let id = conversation.readingVolumeID {
                readerNavigation(for: id) { showsShelfReader = false }
            }
        }
        .onChange(of: conversation.isArenaMode || conversation.isGroupMode) { _, multi in
            if multi {
                requestOptions.temporaryTarget = nil
            }
        }
        .alert("重命名对话", isPresented: $showRenameAlert) {
            TextField("对话标题", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let t = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    conversation.rename(to: t)
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

    private func presentSheet(_ sheet: ChatActiveSheet) {
        pendingSheetDismissAction = nil
        sheetHandoff.present(sheet)
    }

    private func dismissActiveSheet(then action: (() -> Void)? = nil) {
        if sheetHandoff.active != nil || sheetHandoff.isPresentingOrDismissing {
            pendingSheetDismissAction = action
            sheetHandoff.beginDismissal()
        } else {
            action?()
        }
    }

    private func handleActiveSheetDismiss() {
        if sheetHandoff.handleDismiss() == nil {
            let action = pendingSheetDismissAction
            pendingSheetDismissAction = nil
            action?()
        }
    }

    private func handleReaderCoverDismiss() {
        let action = pendingReaderCoverDismissAction
        pendingReaderCoverDismissAction = nil
        action?()
    }

    static func mergingComposerDraft(existing: String, incoming: String) -> String {
        let cleanIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIncoming.isEmpty else { return existing }
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cleanIncoming
        }
        let withoutTrailingWhitespace = existing.replacingOccurrences(
            of: "\\s+$",
            with: "",
            options: .regularExpression
        )
        return "\(withoutTrailingWhitespace)\n\n\(cleanIncoming)"
    }

    @ViewBuilder
    private func sheetContent(for sheet: ChatActiveSheet) -> some View {
        switch sheet {
        case .options:
            ComposerOptionsSheet(
                conversation: conversation,
                options: $requestOptions,
                targets: availableTargets,
                onOpenSettings: { presentSheet(.settings) }
            )
            .presentationDetents([.large])

        case .inspector:
            ChatContextInspectorSheet(
                conversation: conversation,
                providers: providers,
                omitKnowledgeOnce: $requestOptions.omitKnowledge,
                onOpenModelPicker: {
                    beginModelSetup()
                },
                onOpenKnowledgePicker: {
                    presentSheet(.knowledge)
                },
                onOpenFullSettings: {
                    presentSheet(.settings)
                },
                onOpenCitation: { citation in
                    openCitation(citation)
                }
            )
            .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])

        case .model, .arena:
            ModelPickerSheet(
                mode: sheet == .model ? .single : .arenaMulti,
                directory: modelDirectory,
                conversation: conversation, draftText: draft.text, draftAttachments: draft.attachments
            ) { target in
                try useModel(target, exitGroup: true)
            }
            .presentationDetents([.large])

        case .settings:
            ChatSettingsSheet(conversation: conversation)
                .presentationDetents([.medium, .large])

        case .knowledge:
            KnowledgeBindingSheet(selectedVolumeIDs: Binding(
                get: { conversation.assistanceSettings.knowledgeVolumeIDs },
                set: {
                    conversation.assistanceSettings.knowledgeVolumeIDs = $0
                    if $0.isEmpty { requestOptions.omitKnowledge = false }
                    try? modelContext.save()
                }
            ))

        case .groupSetup:
            GroupSetupSheet(
                existingConversation: conversation,
                providers: providers,
                presets: presets
            )

        case .originalBook:
            if let id = citationVolumeID ?? conversation.readingVolumeID {
                readerNavigation(for: id) { dismissActiveSheet() }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }

        case .bookProgress:
            if let friend = conversation.activeBookFriend {
                BookReadingProgressSheet(chat: conversation, friend: friend, onOpen: openBookConversation)
            }

        case .bookInvitation:
            if let friend = conversation.activeBookFriend {
                BookInvitationSheet(friend: friend, onOpen: openBookConversation)
            }

        case .questionDirectory:
            QuestionDirectorySheet(conversation: conversation) { messageID in pendingScrollMessageID = messageID }

        case .search:
            ConversationSearchSheet(
                conversation: conversation, messages: activeMessages,
                anchor: isPinnedToBottom ? nil : questionNavigationAnchor
            ) { messageID in
                pendingScrollMessageID = messageID
            }
            .presentationDetents([.medium, .large])

        case .modelSetup:
            FirstModelSetupSheet { target in
                do { try useModel(target, exitGroup: false) }
                catch { presentHistoryError(error.localizedDescription) }
            }

        case .liveCall:
            ConversationVoiceView(chat: conversation, omitMemory: requestOptions.omitMemory) { voice in
                conversationTimeline(voice: voice)
            }
                .id(conversation.id)
        case .audioTranscription:
            AudioTranscriptionSheet(providers: providers) { transcript, sourceLabel, mode in
                let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { return }
                activateLandingDraft()
                if mode == .insertRaw {
                    draft.text = Self.mergingComposerDraft(existing: draft.text, incoming: clean)
                    saveDraft()
                    return
                }
                let prompt = MeetingMinutesPromptBuilder.buildPrompt(
                    transcript: clean,
                    sourceLabel: sourceLabel,
                    mode: mode
                )
                guard !prompt.isEmpty else { return }
                draft.text = Self.mergingComposerDraft(existing: draft.text, incoming: prompt)
                saveDraft()
                dismissActiveSheet {
                    handleSend()
                }
            }

        case .synthesis(let groupID):
            SynthesisPickerSheet(
                conversation: conversation,
                groupID: groupID,
                providers: providers
            )
            .presentationDetents([.medium, .large])

        case .conversationExport:
            ConversationExportSheet(conversation: conversation)

        case .friendMemory:
            FriendMemorySheet(
                subjects: FriendMemorySubject.subjects(in: conversation),
                conversation: conversation
            )
            .presentationDetents([.large])
        }
    }

    private func presentHistoryError(_ message: String) {
        infoAlert = ChatAlertItem(title: String(localized: "无法更新对话记录"), message: message)
    }

    private func loadDraft() { draft.load() }

    private func saveDraft() { draft.save() }

    private func useModel(_ target: ResolvedModelTarget, exitGroup: Bool) throws {
        activateLandingDraft()
        try ModelSetup.use(target, in: conversation, context: modelContext, exitGroup: exitGroup)
        requestOptions.temporaryTarget = conversation.assistanceSettings.automaticRouting ? conversation.primaryTarget : nil
    }

    private var canPickConnectedModel: Bool {
        !conversation.isGroupMode && providers.contains(where: \.hasConfiguredChatAPI)
    }

    private func beginModelSetup() {
        activateLandingDraft()
        inputFocused = false
        saveDraft()
        if canPickConnectedModel { presentSheet(conversation.isArenaMode ? .arena : .model) }
        else { presentSheet(.modelSetup) }
    }

    private func handleSend(showReview: Bool = true) {
        guard draft.canSend, sendReview == nil else { return }
        activateLandingDraft()
        do { try AttachmentProcessor.validate(draft.attachments) }
        catch { draft.attachmentError = error.localizedDescription; return }

        var options = requestOptions.forSend(in: conversation, quote: draft.quotedText)
        options.pickedMentions = draft.pickedMentions
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
                                            providers: providers, override: options.overrideTarget, pickedMentions: options.pickedMentions) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        guard plan.candidates.contains(where: { $0.contains(where: isReady) }) else { beginModelSetup(); return }
        let targets = disclosureTargets(for: plan)
        let requestOptionsSnapshot = options
        options.authorizedGroupMentions = plan.mentionOnly ? plan.groupMentions : nil
        let usesTools = !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools
        let usesSearch = options.searchQuery != nil
        let searchConfigured = TavilySearchClient.isConfigured
        let recipientSnapshot = recipients(for: targets)
        let settingsSnapshot = conversation.assistanceSettingsData
        let memorySnapshot = engine.prepareMemory(conversation: conversation, omitMemory: options.omitMemory, context: modelContext)
        let isCurrent = {
            var latestOptions = requestOptions.forSend(in: conversation, quote: draft.quotedText)
            latestOptions.pickedMentions = draft.pickedMentions
            guard requestOptionsSnapshot == latestOptions,
                  text == draft.text, attachments == draft.attachments,
                  settingsSnapshot == conversation.assistanceSettingsData,
                  memorySnapshot == engine.prepareMemory(conversation: conversation, omitMemory: options.omitMemory, context: modelContext),
                  recipientSnapshot == recipients(for: targets),
                  !usesSearch || TavilySearchClient.isConfigured == searchConfigured,
                  usesTools == (!conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools),
                  let latest = engine.sendTargets(text: text, attachments: attachments, in: conversation,
                                                  providers: providers, override: options.overrideTarget,
                                                  pickedMentions: latestOptions.pickedMentions) else { return false }
            return disclosureTargets(for: latest) == targets && latest.mentionOnly == plan.mentionOnly
                && (!plan.mentionOnly || latest.groupMentions == plan.groupMentions)
        }
        let proceed: (Set<UUID>?) -> Void = { selected in
            guard isCurrent() else {
                infoAlert = ChatAlertItem(title: String(localized: "暂时无法发送"),
                                          message: AppCompliance.RequestChanged().localizedDescription)
                return
            }
            var approved = options
            approved.selectedMemoryIDs = selected ?? []
            authorize(targets, search: usesSearch, tools: usesTools, isCurrent: isCurrent) { sendDraft(approved) }
        }
        if showReview, let review = makeSendReview(plan: plan, options: options, memoryCount: memorySnapshot.count,
                                                  searchConfigured: searchConfigured, proceed: proceed) {
            inputFocused = false
            sendReview = review
        } else {
            proceed(nil)
        }
    }

    private func makeSendReview(plan: ChatEngine.SendTargets, options: GenerationOptions, memoryCount: Int,
                                searchConfigured: Bool,
                                proceed: @escaping (Set<UUID>?) -> Void) -> ChatSendReview? {
        var knowledgeIDs = Set(options.omitKnowledge ? [] : conversation.assistanceSettings.knowledgeVolumeIDs)
        if let friend = conversation.activeBookFriend { knowledgeIDs.insert(friend.bookID) }
        let knowledgeCount = knowledgeIDs.count
        let estimateRequests = conversation.isArenaMode || conversation.isGroupMode
        let nativeSearch = !conversation.isGroupMode && conversation.assistanceSettings.enableNativeGrounding
        guard estimateRequests || memoryCount > 0 || knowledgeCount > 0 ||
                !draft.attachments.isEmpty || options.searchQuery != nil || nativeSearch else { return nil }

        let title = titleDisclosureTarget(for: plan).map { recipients(for: [$0])[0] }
        let externalSearch = searchConfigured && options.searchQuery != nil
        var searchRecipients: [String] = []
        if externalSearch {
            searchRecipients.append("Tavily")
        } else if options.searchQuery != nil {
            searchRecipients.append(String(localized: "未配置外部搜索服务"))
        }
        if nativeSearch {
            searchRecipients.append(String(localized: "回答模型的原生联网"))
        }

        var requestCount: String?
        var inputEstimates: [ChatSendReview.InputEstimate] = []
        var budgetNotice: String?
        if estimateRequests {
            let opening = plannedOpening(for: plan)
            let counts = [opening.count, externalSearch ? String(localized: "最多 1 次外部搜索") : nil].compactMap { $0 }
            requestCount = counts.joined(separator: " · ")
            let estimates = opening.targets.map { item in
                TokenEstimator.estimateUpcomingInput(
                    conversation: conversation, providers: providers, draftText: draft.text, attachments: draft.attachments,
                    quotedText: draft.quotedText, target: item.target, omitMemory: options.omitMemory, omitKnowledge: options.omitKnowledge
                )
            }
            inputEstimates = opening.targets.enumerated().map { index, item in
                .init(id: String(index), name: item.name, cost: estimates[index].estimatedCostText)
            }
            budgetNotice = upcomingBudgetNotice(for: estimates)
        }
        var seen = Set<String>()
        let answerRecipients = recipients(for: plan.candidates.flatMap { $0 }.filter(isReady)).filter { seen.insert($0).inserted }
        let memories = (try? PersonalMemory.entries(in: modelContext, allowedIDs: conversation.assistanceSettings.scopedMemoryIDs)) ?? []
        return ChatSendReview(answerRecipients: answerRecipients, titleRecipient: title, attachmentCount: draft.attachments.count,
                              memoryCount: memoryCount, knowledgeCount: knowledgeCount,
                              searchRecipient: searchRecipients.isEmpty ? nil : searchRecipients.joined(separator: " · "),
                              searchQuery: options.searchQuery, requestCount: requestCount, inputEstimates: inputEstimates,
                              budgetNotice: budgetNotice, adjustModels: {
                                  reviewedSend = { presentSheet(conversation.isGroupMode ? .groupSetup : .arena) }
                                  sendReview = nil
                              }, memories: memoryCount > 0 ? memories.map { .init(id: $0.id, content: $0.content) } : [], send: proceed)
    }

    private func plannedOpening(for plan: ChatEngine.SendTargets) -> (targets: [(name: String, target: ResolvedModelTarget)], count: String) {
        let targets = plan.candidates.compactMap { $0.first(where: isReady) }
        guard conversation.isGroupMode else {
            return (targets.map { ($0.modelDisplayName, $0) }, String(localized: "约 \(targets.count) 次模型请求"))
        }
        let roster = conversation.activeGroupMembers.compactMap { member -> GroupMember? in
            guard let live = targets.first(where: { $0.id == member.target.id }) else { return nil }
            var copy = member
            copy.target = live
            return copy
        }
        let settings = conversation.assistanceSettings
        let planned = GroupDiscussionCoordinator.selectInitialPlan(userText: draft.text, activeMembers: roster,
            speakingMode: settings.groupSpeakingMode, maxRelayTurns: settings.groupMaxRelayTurns,
            priorMessages: activeMessages, resolvedMentions: plan.groupMentions)
        let explicit = planned.contains(where: \.explicitMention)
        let turns = GroupDiscussionCoordinator.maximumTurnsForUserMessage(speakingMode: settings.groupSpeakingMode,
            plannedCount: planned.count, explicitMentions: explicit, activeCount: roster.count, configuredLimit: settings.groupMaxRelayTurns)
        let opening = settings.groupSpeakingMode == .smartRelay && !explicit ? Array(planned.prefix(1)) : planned
        return (opening.map { ($0.member.displayLabel, $0.member.target) }, String(localized: "本次最多 \(turns) 轮发言"))
    }

    private func upcomingBudgetNotice(for estimates: [TokenEstimator.Estimate]) -> String? {
        guard preferences.monthlyBudgetLimit > 0,
              let month = Calendar.current.dateInterval(of: .month, for: Date()) else { return nil }
        let start = month.start, end = month.end
        let currency = preferences.monthlyBudgetCurrency
        let descriptor = FetchDescriptor<RequestRecord>(predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end })
        guard let records = try? modelContext.fetch(descriptor) else { return String(localized: "本月预算数据暂不可用。") }
        let totals = RequestLedger.costs(records.filter { $0.kind != .webSearch })
        let spent = totals[currency] ?? 0
        let knownInput = estimates.compactMap(\.cost).filter { $0.currency == currency }.reduce(0) { $0 + $1.amount }
        let projected = MonthlyBudgetEvaluator.evaluate(spentByCurrency: [currency: spent + knownInput],
            limit: preferences.monthlyBudgetLimit, currency: currency, alertRatio: preferences.monthlyBudgetAlertRatio)
        let current = RequestLedger.costText(spent, currency: currency)
        let limit = RequestLedger.costText(projected.limit, currency: currency)
        let estimate = RequestLedger.costText(knownInput, currency: currency)
        var notice = String(localized: "本月已知费用 \(current) / \(limit)，本次已知同币种输入约 \(estimate)。")
        if projected.level == .exceeded { notice += " " + String(localized: "已达或预计达到预算上限。") }
        else if projected.level == .warning { notice += " " + String(localized: "已达或预计达到预算预警线。") }
        return notice
    }

    private func disclosureTargets(for plan: ChatEngine.SendTargets) -> [ResolvedModelTarget] {
        var targets = plan.candidates.flatMap { $0 }
        if let title = titleDisclosureTarget(for: plan) { targets.append(title) }
        return targets
    }

    private func titleDisclosureTarget(for plan: ChatEngine.SendTargets) -> ResolvedModelTarget? {
        if !plan.mentionOnly, conversation.assistanceSettings.autoGenerateTitle,
           !conversation.messages.contains(where: { $0.role == .user }) {
            return engine.titleTarget(in: conversation, providers: providers)
        }
        return nil
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
        let backups = engine.replyFallbacks(for: message, after: target, in: conversation, providers: providers)
        let usesTools = message.comparisonGroupID == nil && !isGroupMsg && !message.isSynthesis && conversation.assistanceSettings.enableAgentTools
        let usesSearchOnRetry = message.assistanceMetadata.requestedSearchQuery != nil
        authorize([target] + backups, search: usesSearchOnRetry, tools: usesTools, isCurrent: {
            engine.replyFallbacks(for: message, after: target, in: conversation, providers: providers) == backups
        }) {
            engine.regenerate(assistantMessage: message, overrideTarget: override, in: conversation, providers: providers, context: modelContext)
        }
    }

    private func continueReply(_ message: ChatMessage) {
        guard let target = engine.replyTarget(message, in: conversation, providers: providers) else {
            sendBlockedReason = .noAvailableModel
            return
        }
        let backups = engine.replyFallbacks(for: message, after: target, in: conversation, providers: providers)
        authorize([target] + backups, isCurrent: {
            engine.replyFallbacks(for: message, after: target, in: conversation, providers: providers) == backups
        }) {
            isPinnedToBottom = true
            engine.continueGeneration(assistantMessage: message, in: conversation, providers: providers, context: modelContext)
        }
    }

    private func toggleSpeechWithOptionalCloud(for msg: ChatMessage) {
        if SpeechService.shared.speakingMessageID == msg.id {
            SpeechService.shared.stopSpeaking()
            return
        }
        guard !SpeechService.cleanForSpeech(msg.content).isEmpty else { return }
        let messageID = msg.id
        let messageContent = msg.content
        let personaID = msg.assistanceMetadata.groupMemberID
        ChatCloudTTSCoordinator.authorizeAndBuildTemplate(
            state: {
                ChatCloudTTSCoordinator.Configuration(
                    useCloudTTS: preferences.useCloudTTS,
                    providers: providers,
                    preferredProviderID: preferences.cloudTTSProviderID,
                    model: preferences.cloudTTSModel,
                    voice: preferences.cloudTTSVoice
                )
            },
            gate: consent
        ) { [weak msg] template in
            guard msg?.isDeleted != true else { return }
            if let tpl = template {
                SpeechService.shared.toggleSpeaking(
                    messageID: messageID,
                    text: messageContent,
                    personaID: personaID,
                    cloudSynthesizer: { [tpl] cleanedText in
                        try await CloudSpeechSynthesizer.synthesize(
                            CloudTTSRequest(
                                baseURL: tpl.baseURL,
                                apiKey: tpl.apiKey,
                                apiKeys: tpl.apiKeys,
                                customHeaders: tpl.customHeaders,
                                model: tpl.model,
                                voice: tpl.voice,
                                input: cleanedText
                            )
                        )
                    }
                )
            } else {
                SpeechService.shared.toggleSpeaking(
                    messageID: messageID,
                    text: messageContent,
                    personaID: personaID
                )
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
                                                                    providers: providers, context: modelContext, keepBranch: true,
                                                                    authorizedGroupMentions: plan.mentionOnly ? plan.groupMentions : nil)
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
                    && draft.quotedText == options.quotedExcerpt && draft.pickedMentions == options.pickedMentions
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
            if conversation.isGroupMode && conversation.assistanceSettings.groupSpeakingMode == .mentionOnly {
                return String(localized: "用 @ 点名至少一位可用的群成员。你输入的内容已保留。")
            }
            return conversation.assistanceSettings.automaticRouting
                ? String(localized: "请启用服务商和模型，并检查会话参数中的路由目标与识图能力。你输入的内容已保留。")
                : String(localized: "请先在「设置」页面启用服务商并添加模型。你输入的内容已保留。")
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
        } catch { presentHistoryError(error.localizedDescription) }
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
                } catch { presentHistoryError(error.localizedDescription) }
            }
            .disabled(engine.isGenerating(in: conversation.id))
            Button { clearedHistory = nil } label: { Image(systemName: "xmark") }
                .accessibilityLabel("关闭")
        }
        .padding(.horizontal)
        .padding(.vertical, DS.Spacing.xs)
        .background(.ultraThinMaterial)
    }

    private var missingKeyCard: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "key.fill")
                .foregroundStyle(DS.StatusText.warning)
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
        .dsCard(cornerRadius: DS.Radius.md, fill: Color.orange.opacity(0.10), borderColor: Color.orange.opacity(0.22), padding: DS.Spacing.md)
    }

    private func partialUnreadyCard(_ warning: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.StatusText.warning)
            Text(warning)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("调整") {
                if conversation.isGroupMode {
                    presentSheet(.groupSetup)
                } else {
                    beginModelSetup()
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .dsCard(cornerRadius: DS.Radius.md, fill: Color.orange.opacity(0.08), borderColor: Color.orange.opacity(0.20), padding: DS.Spacing.md)
    }

    @ViewBuilder
    private var groupDiscussionControlBar: some View {
        let generating = engine.isGenerating(in: conversation.id)
        if generating {
            HStack(spacing: DS.Spacing.sm) {
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
                HStack(spacing: DS.Spacing.sm) {
                    Button {
                        runAuthorizedGroupAction {
                            _ = engine.continueGroupDiscussion(in: conversation, providers: providers, context: modelContext)
                        }
                    } label: {
                        Label("继续聊一轮", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.readableText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(theme.softFill, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        runAuthorizedGroupAction {
                            _ = engine.startGroupVote(in: conversation, providers: providers, context: modelContext)
                        }
                    } label: {
                        Label("发起表决", systemImage: "hand.raised.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(DS.Surface.subtle, in: Capsule())
                            .overlay(Capsule().strokeBorder(DS.Surface.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Menu {
                        ForEach(conversation.activeGroupMembers) { member in
                            Button("\(member.avatarEmoji) 由 \(member.displayLabel) 总结") {
                                guard let target = engine.groupSummarizer(member, in: conversation, providers: providers)?.target else {
                                    sendBlockedReason = .noAvailableModel
                                    return
                                }
                                authorize([target], isCurrent: {
                                    engine.groupSummarizer(member, in: conversation, providers: providers)?.target == target
                                }) {
                                    isPinnedToBottom = true
                                    _ = engine.summarizeGroupDiscussion(by: member, in: conversation, providers: providers, context: modelContext)
                                }
                            }
                            .disabled(engine.groupSummarizer(member, in: conversation, providers: providers) == nil)
                        }
                    } label: {
                        Label("总结纪要", systemImage: "list.clipboard")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(DS.Surface.subtle, in: Capsule())
                            .overlay(Capsule().strokeBorder(DS.Surface.hairline, lineWidth: 1))
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
            }
            .background(.ultraThinMaterial)
        }
    }

    private func runAuthorizedGroupAction(_ action: @escaping () -> Void) {
        guard let plan = engine.sendTargets(text: "", attachments: [], in: conversation,
                                            providers: providers, forGroupAction: true) else {
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
        return VStack(spacing: DS.Spacing.lg) {
            if friend == nil && !conversation.isGroupMode && Conversation.isDefaultTitle(conversation.title) {
                FugueSealMark(character: "夜", size: 56, theme: theme)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                        .fill(theme.softFill)
                        .frame(width: 64, height: 64)
                    AssistantEmojiIcon(emoji: conversation.assistantEmoji, font: .system(size: 34))
                        .frame(width: 64, height: 64)
                }
                .accessibilityHidden(true)
            }

            VStack(spacing: DS.Spacing.xs) {
                Text(
                    friend?.byline ?? (conversation.isGroupMode
                        ? conversation.title
                        : (conversation.isArenaMode ? String(localized: "复调多模型对比已开启") : String(localized: "今晚想推演什么问题？")))
                )
                .font(.system(.title3, design: preferences.literarySerifBody ? .serif : .default).weight(.bold))

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
            }

            if conversation.isGroupMode && !conversation.groupMembers.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    FlowGroupRosterPreview(members: conversation.groupMembers)
                    Button {
                        presentSheet(.groupSetup)
                    } label: {
                        Label("调整群成员与发言规则", systemImage: "person.3.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            VStack(spacing: DS.Spacing.sm) {
                if friend != nil {
                    quickSuggestionButton(String(localized: "你好，可以讲讲你的故事吗？"))
                    quickSuggestionButton(String(localized: "遇到难以决定的事时，你会怎么做？"))
                } else if conversation.isGroupMode {
                    quickSuggestionButton(String(localized: "我想做一个面向独立开发者的订阅记账工具，大家觉得有戏吗？"))
                    quickSuggestionButton(String(localized: "手里有两个 Offer：大厂边缘部门涨薪 30% vs 明星创业公司早期期权，怎么选？"))
                    quickSuggestionButton(String(localized: "@所有人 帮我从各自角度挑一下这套新方案最容易翻车的风险点"))
                } else if preferences.simpleDailyMode {
                    quickSuggestionButton(String(localized: "帮我把这段零散会议记录整理成结论与待办行动项（含明确日期）"))
                    quickSuggestionButton(String(localized: "帮我针对这条工作消息起草正式、温和、简短 3 版纯文本回复"))
                    quickSuggestionButton(String(localized: "把本周工作碎片记录提炼成重点突出、带量化结果的周报"))
                    quickSuggestionButton(String(localized: "用大白话帮我审一下这份合同/账单里的费用、违约和避坑条款"))
                } else {
                    quickSuggestionButton(String(localized: "帮我对比一下 Swift Actor 和传统锁的性能与适用场景"))
                    quickSuggestionButton(String(localized: "用通俗生动的语言解释 Transformer 的自注意力机制"))
                    quickSuggestionButton(String(localized: "帮我写一段高质量的 Python 异步并发请求模板"))
                }
            }
            .padding(.top, DS.Spacing.xxs)
        }
    }

    private func quickSuggestionButton(_ prompt: String) -> some View {
        Button {
            draft.text = prompt
        } label: {
            HStack(spacing: DS.Spacing.sm) {
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
            .padding(.vertical, 11)
            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(DS.Surface.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FlowGroupRosterPreview: View {
    let members: [GroupMember]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(members) { member in
                    HStack(spacing: DS.Spacing.xs) {
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
                    .padding(.vertical, DS.Spacing.xs)
                    .background(Color(hex: member.accentHex).opacity(0.11), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
        }
    }
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

struct SheetHandoffState<Route: Equatable> {
    var active: Route? {
        didSet {
            if active != nil {
                isPresentingOrDismissing = true
            }
        }
    }
    private(set) var deferred: Route?
    private(set) var isPresentingOrDismissing = false

    mutating func present(_ route: Route) {
        if active == nil && !isPresentingOrDismissing {
            deferred = nil
            active = route
            isPresentingOrDismissing = true
            return
        }
        if active == route && deferred == nil {
            return
        }
        deferred = route
        active = nil
        isPresentingOrDismissing = true
    }

    mutating func beginDismissal() {
        deferred = nil
        if active != nil {
            active = nil
            isPresentingOrDismissing = true
        }
    }

    @discardableResult
    mutating func handleDismiss() -> Route? {
        if let next = deferred {
            deferred = nil
            active = next
            isPresentingOrDismissing = true
            return next
        }
        isPresentingOrDismissing = false
        return nil
    }
}

@MainActor
enum ModalPresentationGate {
    static func hasActiveOrDismissingModalInWindow() -> Bool {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.activationState == .foregroundActive || windowScene.activationState == .foregroundInactive else {
                continue
            }
            for window in windowScene.windows where !window.isHidden {
                if window.rootViewController?.presentedViewController != nil {
                    return true
                }
            }
        }
        return false
    }

    static func performWhenClear(
        extraCheck: @escaping @MainActor () -> Bool = { false },
        action: @escaping @MainActor () -> Void
    ) {
        if !extraCheck() && !hasActiveOrDismissingModalInWindow() {
            action()
            return
        }
        Task { @MainActor in
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                if !extraCheck() && !hasActiveOrDismissingModalInWindow() {
                    break
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled else { return }
            await Task.yield()
            action()
        }
    }
}

@MainActor
enum ChatCloudTTSCoordinator {
    struct Configuration {
        var useCloudTTS: Bool
        var providers: [ProviderConfig]
        var preferredProviderID: UUID?
        var model: String
        var voice: String
    }

    static func resolveCompatibleProvider(
        in providers: [ProviderConfig],
        preferredID: UUID?
    ) -> ProviderConfig? {
        guard let provider = AudioTranscriptionService.resolveAudioProvider(
            in: providers,
            preferredID: preferredID,
            capability: .speech
        ),
        AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: provider.baseURL) else {
            return nil
        }
        return provider
    }

    static func effectiveModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "tts-1" : trimmed
    }

    static func effectiveVoice(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "alloy" : trimmed
    }

    static func recipient(for provider: ProviderConfig, model: String) -> String {
        AppCompliance.recipient(
            provider: provider.name,
            model: effectiveModel(model),
            baseURL: provider.baseURL
        )
    }

    static func authorizeAndBuildTemplate(
        state: @escaping () -> Configuration,
        gate: AIConsentGate,
        completion: @escaping (CloudTTSRequest?) -> Void
    ) {
        let initial = state()
        guard initial.useCloudTTS,
              let provider = resolveCompatibleProvider(in: initial.providers, preferredID: initial.preferredProviderID) else {
            completion(nil)
            return
        }
        let expectedProviderID = provider.id
        let expectedModel = effectiveModel(initial.model)
        let expectedRecipient = recipient(for: provider, model: expectedModel)

        gate.perform(
            recipients: [expectedRecipient],
            isCurrent: {
                let current = state()
                guard current.useCloudTTS,
                      effectiveModel(current.model) == expectedModel,
                      let latest = resolveCompatibleProvider(in: current.providers, preferredID: current.preferredProviderID) else {
                    return false
                }
                return latest.id == expectedProviderID && recipient(for: latest, model: expectedModel) == expectedRecipient
            },
            send: {
                let current = state()
                guard current.useCloudTTS,
                      let latest = resolveCompatibleProvider(in: current.providers, preferredID: current.preferredProviderID) else {
                    completion(nil)
                    return
                }
                completion(
                    CloudTTSRequest(
                        baseURL: latest.baseURL,
                        apiKey: latest.apiKey,
                        apiKeys: latest.extraAPIKeys,
                        customHeaders: latest.resolvedCustomHeaders,
                        model: effectiveModel(current.model),
                        voice: effectiveVoice(current.voice),
                        input: ""
                    )
                )
            }
        )
    }
}
