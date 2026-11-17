import SwiftUI
import SwiftData

struct ChatDetailView: View {
    @Bindable var conversation: Conversation
    var onNavigateToProviders: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var draftText: String = ""
    @State private var pendingAttachments: [MessageAttachment] = []
    @State private var activePickerMode: ModelPickerSheet.Mode?
    @State private var showChatSettings = false
    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var sendBlockedReason: SendOutcome?
    /// True while the user is at (or near) the bottom; streaming output only auto-scrolls then,
    /// so scrolling up to re-read earlier content isn't interrupted.
    @State private var isPinnedToBottom = true
    @State private var isUserScrolling = false

    private var engine: ChatEngine { ChatEngine.shared }

    private var timelineItems: [TimelineEntry] {
        TimelineEntry.build(from: conversation.sortedMessages)
    }

    private var needsAPIKeyBanner: Bool {
        if conversation.isArenaMode {
            return false
        }
        guard let target = conversation.primaryTarget else { return true }
        guard let provider = providers.first(where: { $0.id == target.providerID }) else { return true }
        let isLocal = NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)
        return !isLocal && !KeychainService.shared.hasAPIKey(for: provider.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if needsAPIKeyBanner {
                        missingKeyCard
                    }

                    if timelineItems.isEmpty {
                        emptyWelcomeView
                            .padding(.top, 36)
                    } else {
                        ForEach(timelineItems) { entry in
                            switch entry {
                            case .single(let msg):
                                MessageRowView(
                                    message: msg,
                                    onRegenerate: {
                                        engine.regenerate(
                                            assistantMessage: msg,
                                            in: conversation,
                                            providers: providers,
                                            context: modelContext
                                        )
                                    },
                                    onRegenerateWithCurrentModel: {
                                        engine.regenerate(
                                            assistantMessage: msg,
                                            overrideTarget: conversation.primaryTarget,
                                            in: conversation,
                                            providers: providers,
                                            context: modelContext
                                        )
                                    }
                                )
                            case .arenaGroup(_, let groupMsgs):
                                ArenaComparisonGroupView(
                                    messages: groupMsgs,
                                    onSelectWinner: { winner in
                                        engine.selectWinnerInGroup(winner, in: conversation, context: modelContext)
                                    },
                                    onRegenerateSingle: { single in
                                        engine.regenerate(
                                            assistantMessage: single,
                                            in: conversation,
                                            providers: providers,
                                            context: modelContext
                                        )
                                    }
                                )
                            }
                        }
                    }

                    Color.clear
                        .frame(height: 4)
                        .id("BOTTOM_ANCHOR")
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // "Near bottom" = the visible area reaches within ~120pt of the content end.
                geometry.visibleRect.maxY >= geometry.contentSize.height - 120
            } action: { _, nearBottom in
                if nearBottom {
                    isPinnedToBottom = true
                } else if isUserScrolling {
                    // Only the user scrolling away unpins; a big streamed chunk growing the
                    // content past the threshold must not stop the follow.
                    isPinnedToBottom = false
                }
            }
            .onScrollPhaseChange { _, newPhase in
                isUserScrolling = newPhase == .tracking || newPhase == .interacting || newPhase == .decelerating
            }
            .background {
                // Isolated child so per-token content changes don't re-evaluate this whole view.
                StreamingAutoScroller(conversation: conversation, proxy: proxy, isEnabled: isPinnedToBottom)
            }
            .onChange(of: conversation.messages.count) { _, _ in
                isPinnedToBottom = true
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ComposerBarView(
                    conversation: conversation,
                    draftText: $draftText,
                    pendingAttachments: $pendingAttachments,
                    isGenerating: engine.isGenerating(in: conversation.id),
                    onOpenModelPicker: { activePickerMode = .single },
                    onOpenArenaPicker: { activePickerMode = .arenaMulti },
                    onOpenSettings: { showChatSettings = true },
                    onSend: handleSend,
                    onStop: { engine.stopGeneration(for: conversation.id) }
                )
            }
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameDraft = conversation.title
                        showRenameAlert = true
                    } label: {
                        Label("重命名对话", systemImage: "pencil")
                    }

                    Button {
                        activePickerMode = .single
                    } label: {
                        Label("切换单聊模型", systemImage: "cpu")
                    }

                    Button {
                        activePickerMode = .arenaMulti
                    } label: {
                        Label("配置多模型并发对比", systemImage: "square.split.2x1")
                    }

                    Button {
                        showChatSettings = true
                    } label: {
                        Label("系统提示词与参数", systemImage: "slider.horizontal.3")
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task { await clearAllMessages() }
                    } label: {
                        Label("清空当前消息记录", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
            }
        }
        .onAppear {
            ensureDefaultModelSelected()
        }
        .sheet(item: $activePickerMode) { mode in
            ModelPickerSheet(
                mode: mode,
                providers: providers,
                conversation: conversation
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showChatSettings) {
            ChatSettingsSheet(conversation: conversation)
                .presentationDetents([.medium, .large])
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
            if sendBlockedReason == .noAvailableModel, let onNavigateToProviders {
                Button("去配置") { onNavigateToProviders() }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(sendBlockedMessage)
        }
    }

    private func handleSend() {
        let outcome = engine.sendUserMessage(
            text: draftText,
            attachments: pendingAttachments,
            in: conversation,
            providers: providers,
            context: modelContext
        )
        switch outcome {
        case .sent:
            // Only clear the composer once the message is actually in the conversation.
            draftText = ""
            pendingAttachments = []
        case .noAvailableModel, .busy:
            sendBlockedReason = outcome
        case .emptyInput:
            break
        }
    }

    private var sendBlockedTitle: String {
        sendBlockedReason == .noAvailableModel ? String(localized: "还没有可用的模型") : String(localized: "暂时无法发送")
    }

    private var sendBlockedMessage: String {
        switch sendBlockedReason {
        case .noAvailableModel:
            return String(localized: "请先在「服务商」页面启用服务商并添加模型。你输入的内容已保留。")
        case .busy:
            return String(localized: "上一条回复仍在生成或正在停止，请稍候再发送。你输入的内容已保留。")
        default:
            return ""
        }
    }

    /// Stops any in-flight generation and waits for it to unwind before deleting,
    /// so no streaming task writes into deleted messages.
    private func clearAllMessages() async {
        await engine.stopGenerationAndWait(for: conversation.id)
        for msg in conversation.messages {
            modelContext.delete(msg)
        }
        conversation.messages.removeAll()
        try? modelContext.save()
    }

    private func ensureDefaultModelSelected() {
        guard conversation.primaryTarget == nil else { return }
        // Prefer a provider that already has an API key configured
        for provider in providers where provider.isEnabled && KeychainService.shared.hasAPIKey(for: provider.id) {
            if let firstSpec = provider.enabledModels.first {
                conversation.primaryTarget = provider.makeTarget(for: firstSpec)
                return
            }
        }
        if let fallback = engine.availableTargets(from: providers).first {
            conversation.primaryTarget = fallback
        }
    }

    private var missingKeyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("当前模型尚未填入 API Key")
                    .font(.footnote.weight(.semibold))
                Text("前往「服务商」页面配置自有 API Key 后即可直接流式对话")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onNavigateToProviders {
                Button("去配置") {
                    onNavigateToProviders()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyWelcomeView: some View {
        VStack(spacing: 16) {
            Text(conversation.assistantEmoji)
                .font(.system(size: 46))

            Text(conversation.isArenaMode ? String(localized: "多模型并发对比已开启") : String(localized: "开始自由 AI 对话"))
                .font(.title3.weight(.bold))

            Text(
                conversation.isArenaMode
                    ? String(localized: "发送一条提问，同时请求多个服务商模型并排比对思考链与答案质量。")
                    : String(localized: "支持随时在底部切换不同服务商的模型接力回答，也可发送图片与 PDF 文档。")
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            VStack(spacing: 8) {
                quickSuggestionButton(String(localized: "帮我对比一下 Swift Actor 和传统锁的性能与适用场景"))
                quickSuggestionButton(String(localized: "用通俗生动的语言解释 Transformer 的自注意力机制"))
                quickSuggestionButton(String(localized: "帮我写一段高质量的 Python 异步并发请求模板"))
            }
            .padding(.top, 6)
        }
    }

    private func quickSuggestionButton(_ prompt: String) -> some View {
        Button {
            draftText = prompt
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

extension ModelPickerSheet.Mode: Identifiable {
    var id: String {
        switch self {
        case .single: return "single"
        case .arenaMulti: return "arena"
        }
    }
}

/// Keeps the newest streamed tokens in view. Lives in its own tiny view so that observing the
/// streaming text (which changes many times per second) only re-evaluates this view.
private struct StreamingAutoScroller: View {
    let conversation: Conversation
    let proxy: ScrollViewProxy
    let isEnabled: Bool

    private var streamedLength: Int {
        conversation.messages.reduce(0) { total, message in
            message.isStreaming
                ? total + message.content.utf8.count + message.reasoningContent.utf8.count
                : total
        }
    }

    var body: some View {
        Color.clear
            .onChange(of: streamedLength) { _, _ in
                guard isEnabled else { return }
                proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
            }
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
