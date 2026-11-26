import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatModelPickerButton: View {
    var conversationTitle: String? = nil
    let modelName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if let conversationTitle {
                    Text(verbatim: conversationTitle).font(.headline).foregroundStyle(.primary)
                }
                HStack(spacing: 4) {
                    Text(verbatim: modelName)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .font(conversationTitle == nil ? .subheadline.weight(.medium) : .caption.weight(.medium))
                .foregroundStyle(AppPreferences.shared.accentTheme.readableText)
            }
            .lineLimit(1)
            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("选择模型")
        .accessibilityIdentifier("chatComposer.model")
    }
}

struct ChatStartModeMenu: View {
    let isGenerating: Bool
    let onOpenArena: () -> Void
    let onOpenGroup: (() -> Void)?
    let onOpenOptions: () -> Void

    @State private var preferences = AppPreferences.shared

    var body: some View {
        if preferences.simpleDailyMode && preferences.showsArena {
            Button(action: onOpenArena) {
                Label("多模型对比", systemImage: "square.split.2x1")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: DS.TouchTarget.minimum)
            }
            .accessibilityIdentifier("chatComposer.compareModels")
            .disabled(isGenerating)
        } else if !preferences.simpleDailyMode {
            Menu {
                if preferences.showsArena {
                    Button(action: onOpenArena) { Label("多模型对比", systemImage: "square.split.2x1") }
                        .disabled(isGenerating)
                }
                if preferences.showsGroupChat, let onOpenGroup {
                    Button(action: onOpenGroup) { Label("圆桌群聊", systemImage: "person.3") }
                }
                if !preferences.simpleDailyMode {
                    Button(action: onOpenOptions) { Label("请求选项", systemImage: "slider.horizontal.3") }
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Text("单聊")
                    Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, DS.Spacing.md)
                .frame(minHeight: DS.TouchTarget.minimum)
                .background(DS.Surface.subtle, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Surface.hairline).allowsHitTesting(false))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

struct ComposerBarView: View {
    @Bindable var conversation: Conversation
    @Bindable var draft: ChatDraftState
    let providers: [ProviderConfig]
    let presets: [AssistantPreset]
    let routedTarget: ResolvedModelTarget?
    let isGenerating: Bool
    @Binding var requestOptions: ComposerRequestOptions
    let onOpenModelPicker: () -> Void
    let onOpenArenaPicker: () -> Void
    var onOpenGroupSetup: (() -> Void)? = nil
    let onOpenOptions: () -> Void
    let onManageKnowledge: () -> Void
    var onOpenAudioTranscription: (() -> Void)? = nil
    var externalDocumentScanTrigger: Int = 0
    var writingFirst = false
    var needsModel = false
    var canChooseModel = false
    let inputFocus: FocusState<Bool>.Binding
    @Binding var phoneEntry: PhoneComposeEntry?
    let onInsertContextDivider: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.usesPhoneWorkspace) private var usesPhoneWorkspace
    @Environment(\.modelContext) private var modelContext
    @State private var isCapabilityDrawerOpen = false
    @State private var budgetEvaluation: MonthlyBudgetEvaluation?
    @State private var dismissedBudgetNotice = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showDocumentScanner = false
    @State private var showFileImporter = false
    @State private var attachmentReview: DraftAttachmentReview?
    @State private var searchQueryAutoSync = false
    @State private var speech = SpeechService.shared
    @State private var preferences = AppPreferences.shared
    @State private var dictationBaseText = ""
    @State private var debouncedEstimateText = ""

    private var theme: DS.AccentTheme { preferences.accentTheme }
    private var usesPhoneSingleComposer: Bool { usesPhoneWorkspace && !conversation.isArenaMode && !conversation.isGroupMode }

    private var temporaryTarget: ResolvedModelTarget? {
        get { requestOptions.temporaryTarget }
        nonmutating set { requestOptions.temporaryTarget = newValue }
    }

    private var canSend: Bool { draft.canSend }

    private var availableTargets: [ResolvedModelTarget] {
        ChatEngine.shared.availableTargets(from: providers)
    }

    private var hasDraftContent: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachments.isEmpty
            || (draft.quotedText?.isEmpty == false)
    }

    private var showSlashPopover: Bool {
        let t = draft.text
        return t.hasPrefix("/") && !t.contains("\n") && t.count <= 24
    }

    private var showMentionPopover: Bool {
        guard draft.text.hasSuffix("@") else { return false }
        if conversation.isGroupMode {
            return !conversation.activeGroupMembers.isEmpty
        }
        return !conversation.isArenaMode && !availableTargets.isEmpty
    }

    private var mentionOnlyHint: String? {
        guard conversation.isGroupMode,
              conversation.assistanceSettings.groupSpeakingMode == .mentionOnly,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.text.contains("@") else {
            return nil
        }
        return String(localized: "当前为「仅 @ 点名」模式，输入 @ 选择要回答的群成员")
    }

    private func refreshMonthlyBudgetNotice() {
        guard preferences.monthlyBudgetLimit > 0 else {
            budgetEvaluation = nil
            return
        }
        budgetEvaluation = MonthlyBudgetEvaluator.evaluateCurrentMonth(in: modelContext, preferences: preferences)
    }

    /// Images attached while the target model(s) aren't flagged as vision-capable.
    private var visionWarning: String? {
        guard draft.attachments.contains(where: { $0.kind == .image }) else { return nil }
        if conversation.isGroupMode {
            let names = conversation.activeGroupMembers
                .filter { !$0.target.supportsVision }
                .map(\.displayLabel)
            guard !names.isEmpty else { return nil }
            let joined = names.joined(separator: String(localized: "、"))
            return String(localized: "\(joined) 绑定的模型未标记支持识图，图片可能被忽略或导致报错。")
        }
        if conversation.isArenaMode && conversation.arenaTargets.count >= 2 {
            let names = conversation.arenaTargets.filter { !$0.supportsVision }.map(\.modelDisplayName)
            guard !names.isEmpty else { return nil }
            let joined = names.joined(separator: String(localized: "、"))
            return String(localized: "\(joined) 未标记支持识图，图片可能被忽略或导致报错。")
        }
        if let temp = temporaryTarget {
            guard !temp.supportsVision else { return nil }
            return String(localized: "当前模型「\(temp.modelDisplayName)」未标记支持识图，图片可能被忽略或导致报错（可在服务商页修改「识图」标记）。")
        }
        if conversation.assistanceSettings.automaticRouting { return nil }
        guard let target = conversation.primaryTarget, !target.supportsVision else { return nil }
        return String(localized: "当前模型「\(target.modelDisplayName)」未标记支持识图，图片可能被忽略或导致报错（可在服务商页修改「识图」标记）。")
    }

    private var routingUnavailable: Bool {
        !conversation.isArenaMode && !conversation.isGroupMode && requestOptions.temporaryTarget == nil
            && conversation.assistanceSettings.automaticRouting && conversation.primaryTarget != nil && routedTarget == nil
    }

    private var effectiveTarget: ResolvedModelTarget? {
        if let target = requestOptions.forSend(in: conversation, quote: draft.quotedText).overrideTarget { return target }
        guard let primary = conversation.primaryTarget else { return nil }
        if conversation.assistanceSettings.automaticRouting {
            return routedTarget ?? primary
        }
        return primary
    }

    private enum WebMode {
        case off, search
    }

    private var webMode: WebMode {
        if requestOptions.useSearch || (!conversation.isGroupMode && conversation.assistanceSettings.enableNativeGrounding) {
            return .search
        }
        return .off
    }

    private var webModeTitle: String {
        if requestOptions.useSearch && !conversation.isGroupMode && conversation.assistanceSettings.enableNativeGrounding {
            return String(localized: "联网搜索 · 本次 + 原生联网 · 本会话")
        }
        if requestOptions.useSearch { return String(localized: "联网搜索 · 本次") }
        if !conversation.isGroupMode && conversation.assistanceSettings.enableNativeGrounding {
            return String(localized: "原生联网 · 本会话")
        }
        return String(localized: "联网")
    }

    private var showSessionStatusChips: Bool {
        !isCapabilityDrawerOpen || preferences.simpleDailyMode
    }

    private var hasActiveStatusChips: Bool {
        (!conversation.isGroupMode && requestOptions.temporaryTarget != nil)
            || (!isCapabilityDrawerOpen && webMode != .off)
            || (showSessionStatusChips && !conversation.isGroupMode && conversation.enableThinking)
            || (showSessionStatusChips && !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools)
            || (requestOptions.omitMemory && conversation.assistanceSettings.usePersonalMemory)
            || routingUnavailable
            || (routedTarget != nil && routedTarget?.id != conversation.primaryTarget?.id)
            || (conversation.isGroupMode && !conversation.activeGroupMembers.isEmpty)
    }

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            if showSlashPopover {
                SlashCommandPopover(
                    query: draft.text,
                    presets: conversation.isGroupMode ? [] : presets,
                    onSelectCommand: { cmd in
                        if cmd.id == "clear-context" {
                            draft.text = ""
                            onInsertContextDivider()
                        } else {
                            draft.text = cmd.templatePrefix
                        }
                    },
                    onSelectPreset: { preset in
                        conversation.applyPreset(preset)
                        draft.text = ""
                    }
                )
            } else if showMentionPopover {
                mentionPopover
            }

            // Inline capability & attachment drawer (expanded via '+')
            if isCapabilityDrawerOpen {
                capabilityDrawer
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Slim status strip: appears only when capabilities are active, group @ is needed, or draft estimate exists
            // The phone single composer renders these chips inside its own header row.
            if !usesPhoneSingleComposer,
               (isCapabilityDrawerOpen || (!writingFirst && (conversation.readingVolumeID == nil || hasDraftContent))) && (hasActiveStatusChips || hasDraftContent) {
                activeStatusStrip
            }

            if requestOptions.useSearch {
                searchQueryRow
            }

            if speech.isRecording {
                recordingBanner
            }

            if !usesPhoneSingleComposer, let quoted = draft.quotedText, !quoted.isEmpty {
                quotedPreviewBanner(quoted)
            }

            if draft.processingAttachments > 0 {
                ProgressView().accessibilityLabel("正在处理附件")
            }

            if !draft.attachments.isEmpty {
                pendingAttachments.padding(.horizontal, DS.Spacing.md)

                if draft.attachments.contains(where: { $0.kind == .image }) {
                    HStack(spacing: DS.Spacing.sm) {
                        Button {
                            attachmentReview = DraftAttachmentReview(sources: draft.attachments.filter { $0.kind == .image }, recognize: true)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.viewfinder").font(.caption.weight(.semibold))
                                Text("本地 OCR 转文字（免识图 / 省 Token）")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(theme.readableText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.softFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(draft.processingAttachments > 0)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Spacing.md)
                }
            }

            if let mentionOnlyHint {
                Label(mentionOnlyHint, systemImage: "at")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }

            if let visionWarning {
                Label(visionWarning, systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(DS.StatusText.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }

            if !dismissedBudgetNotice,
               let eval = budgetEvaluation,
               (eval.level == .warning || eval.level == .exceeded) {
                HStack(spacing: 8) {
                    Button {
                        onOpenModelPicker()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: eval.level == .exceeded ? "exclamationmark.octagon.fill" : "gauge.with.dots.needle.67percent")
                                .font(.caption2)
                            Text(
                                eval.level == .exceeded
                                    ? String(localized: "已达本月预算上限（\(RequestLedger.costText(eval.spent, currency: eval.currency))）· 点此切换轻量模型")
                                    : String(localized: "已用本月预算 \(Int((eval.ratio * 100).rounded()))% · 剩余 \(RequestLedger.costText(eval.remaining, currency: eval.currency))")
                            )
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                        }
                        .foregroundStyle(eval.level == .exceeded ? DS.StatusText.error : DS.StatusText.warning)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        dismissedBudgetNotice = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭预算提示")
                }
                .padding(.horizontal, 14)
                .accessibilityIdentifier("chatComposer.budgetBanner")
            }

            if !draft.isLoaded {
                draftRecoveryBanner
            }

            // Main single-row minimal input bar (Floating Glass Pill Island)
            if usesPhoneSingleComposer {
                phoneSingleComposer
            } else if writingFirst {
                writingEditor
            } else {
                let messageInput = inputRow.padding(.horizontal, 8).padding(.vertical, 6)
                Group {
                    if usesPhoneWorkspace {
                        messageInput
                            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.xl))
                            .overlay {
                                RoundedRectangle(cornerRadius: DS.Radius.xl)
                                    .strokeBorder(DS.Surface.strongBorder)
                                    .allowsHitTesting(false)
                            }
                    } else {
                        messageInput.dsFloatingIsland(cornerRadius: DS.Radius.island)
                    }
                }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.bottom, DS.Spacing.xs)
            }
        }
        .padding(.top, DS.Spacing.xs)
        .onAppear {
            refreshMonthlyBudgetNotice()
            guard let entry = phoneEntry else { return }
            phoneEntry = nil
            switch entry {
            case .writing: inputFocus.wrappedValue = true
            case .attachments: isCapabilityDrawerOpen = true
            }
        }
        .onChange(of: isGenerating) { wasGen, isGen in
            if wasGen && !isGen {
                refreshMonthlyBudgetNotice()
            }
        }
        .onChange(of: preferences.monthlyBudgetLimit) { _, _ in
            dismissedBudgetNotice = false
            refreshMonthlyBudgetNotice()
        }
        .onChange(of: preferences.monthlyBudgetCurrency) { _, _ in
            refreshMonthlyBudgetNotice()
        }
        .onChange(of: draft.text) { _, newText in
            if requestOptions.useSearch && searchQueryAutoSync {
                requestOptions.searchQuery = String(newText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            }
        }
        .onChange(of: requestOptions.useSearch) { _, enabled in
            if !enabled { searchQueryAutoSync = false }
        }
        .onChange(of: isGenerating) { _, generating in
            if generating && isCapabilityDrawerOpen {
                withAnimation(.snappy(duration: 0.2)) {
                    isCapabilityDrawerOpen = false
                }
            }
        }
        .task(id: draft.text) {
            if draft.text.count <= 96 {
                debouncedEstimateText = draft.text
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            if !Task.isCancelled {
                debouncedEstimateText = draft.text
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 4,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            draft.processingAttachments += 1
            Task {
                defer { draft.processingAttachments -= 1 }
                for item in newItems {
                    if let imported = try? await item.loadTransferable(type: ImportedPhoto.self) {
                        let attachment = imported.attachment
                        await MainActor.run {
                            appendAttachment(attachment)
                        }
                    } else {
                        draft.attachmentError = String(localized: "无法读取图片，或图片超过 20 MB 限制。")
                    }
                }
                await MainActor.run {
                    selectedPhotoItems.removeAll()
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPickerView { image in
                draft.processingAttachments += 1
                Task {
                    defer { draft.processingAttachments -= 1 }
                    if let attachment = await Task.detached(operation: { AttachmentProcessor.processImage(image) }).value {
                        appendAttachment(attachment)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showDocumentScanner) {
            DocumentScannerView(
                onScan: { pages in
                    let remainingSlots = max(0, AttachmentProcessor.maximumAttachmentCount - draft.attachments.count)
                    let limitedPages = Array(pages.prefix(remainingSlots))
                    if limitedPages.count < pages.count {
                        draft.attachmentError = AttachmentError.limit.localizedDescription
                    }
                    guard !limitedPages.isEmpty else { return }
                    draft.processingAttachments += 1
                    Task {
                        defer { draft.processingAttachments -= 1 }
                        let processed = await Task.detached(priority: .userInitiated) {
                            limitedPages.enumerated().compactMap { index, image in
                                AttachmentProcessor.processImage(image, fileName: "scan-\(index + 1).jpg")
                            }
                        }.value
                        for item in processed {
                            appendAttachment(item)
                        }
                    }
                },
                onError: { message in
                    draft.attachmentError = message
                }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .text, .json, .commaSeparatedText, .xml, .sourceCode, .image]
                + ["docx", "xlsx", "pptx", "md", "markdown"].compactMap { UTType(filenameExtension: $0) },
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if urls.count > AttachmentProcessor.maximumAttachmentCount {
                    draft.attachmentError = AttachmentError.limit.localizedDescription
                    return
                }
                draft.processingAttachments += 1
                Task {
                    defer { draft.processingAttachments -= 1 }
                    for url in urls {
                        do {
                            let att = try await Task.detached { try AttachmentProcessor.processFileURL(url) }.value
                            appendAttachment(att)
                        } catch {
                            draft.attachmentError = String(localized: "读取文件失败：\(error.localizedDescription)")
                        }
                    }
                }
            case .failure(let error):
                draft.attachmentError = error.localizedDescription
            }
        }
        .sheet(item: $attachmentReview) { review in
            DraftAttachmentReviewSheet(review: review) { format, text, coverage in
                guard draft.isLoaded, !draft.isDeleted else { throw DraftAttachmentReview.ReviewError.changed }
                let updated = try review.applying(format, text: text, coverage: coverage, to: draft.attachments)
                if updated != draft.attachments {
                    draft.attachments = updated
                    draft.save()
                }
            }
        }
        .alert("附件提示", isPresented: Binding(
            get: { draft.attachmentError != nil },
            set: { if !$0 { draft.attachmentError = nil } }
        )) {
            Button("确定", role: .cancel) { draft.attachmentError = nil }
        } message: {
            Text(draft.attachmentError ?? "")
        }
        .alert("语音输入提示", isPresented: Binding(
            get: { speech.speechError != nil },
            set: { if !$0 { speech.speechError = nil } }
        )) {
            Button("确定", role: .cancel) { speech.speechError = nil }
        } message: {
            Text(speech.speechError ?? "")
        }
        .onChange(of: externalDocumentScanTrigger) { _, newValue in
            guard newValue > 0 else { return }
            isCapabilityDrawerOpen = false
            if DocumentScannerView.isSupported {
                showDocumentScanner = true
            } else {
                draft.attachmentError = String(localized: "当前设备不支持文档相机扫描，可通过「相册」或「拍照」导入图片后点击本地 OCR 转文字。")
            }
        }
        .onChange(of: conversation.id) { oldID, newID in
            if Self.handleConversationSwitch(
                from: oldID,
                to: newID,
                speech: speech,
                dictationBaseText: &dictationBaseText
            ) {
                isCapabilityDrawerOpen = false
                debouncedEstimateText = draft.text
            }
        }
        .onDisappear {
            speech.stopDictationIfActive()
        }
    }

    // MARK: - Active Status Strip (Slim, State-Driven)

    private var skippingMemory: Bool {
        requestOptions.omitMemory && conversation.assistanceSettings.usePersonalMemory
    }

    private var activeStatusStrip: some View {
        HStack(spacing: DS.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) { statusChips }
            }
            if hasDraftContent { tokenMeter }
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    @ViewBuilder
    private var statusChips: some View {
                    if !conversation.isGroupMode, let temp = requestOptions.temporaryTarget {
                        removableChip(
                            title: String(localized: "本次 · \(temp.modelDisplayName)"),
                            systemImage: "cpu",
                            tint: theme.readableText
                        ) {
                            requestOptions.temporaryTarget = nil
                        }
                    }

                    if routingUnavailable {
                        Text("路由模型不可用")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(DS.StatusText.warning)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    } else if let target = routedTarget, target.id != conversation.primaryTarget?.id {
                        Text("本次模型：\(target.modelDisplayName)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(DS.Surface.subtle, in: Capsule())
                    }

                    if webMode != .off && !isCapabilityDrawerOpen {
                        removableChip(
                            title: webModeTitle,
                            systemImage: "globe",
                            tint: theme.readableText
                        ) {
                            setWebMode(.off)
                        }
                        .disabled(isGenerating)
                    }

                    if showSessionStatusChips && !conversation.isGroupMode && conversation.enableThinking {
                        Menu {
                            thinkingMenuItems
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .font(.caption2.weight(.semibold))
                                Text("思考 · \(max(1, conversation.thinkingBudgetTokens / 1024))K")
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(theme.readableText)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(theme.softFill, in: Capsule())
                        }
                        .disabled(isGenerating)
                    }

                    if showSessionStatusChips && !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools {
                        removableChip(
                            title: String(localized: "工具"),
                            systemImage: "wrench.and.screwdriver",
                            tint: theme.readableText
                        ) {
                            conversation.assistanceSettings.enableAgentTools = false
                        }
                        .disabled(isGenerating)
                    }

                    if skippingMemory {
                        removableChip(
                            title: String(localized: "本次不使用记忆"),
                            systemImage: "brain.head.profile",
                            tint: theme.readableText
                        ) {
                            requestOptions.omitMemory = false
                        }
                        .disabled(isGenerating)
                    }

                    if conversation.isGroupMode && !conversation.activeGroupMembers.isEmpty {
                        Menu {
                            Button("📣 @所有人") {
                                draft.insertGroupMention(String(localized: "@所有人 ").trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            Divider()
                            ForEach(conversation.activeGroupMembers) { member in
                                Button("\(member.avatarEmoji) \(member.displayLabel) · \(member.target.modelDisplayName)") {
                                    draft.insertGroupMention("@\(member.mentionToken)", memberID: member.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("@")
                                    .font(.caption2.weight(.bold))
                                Text("点名")
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(theme.readableText)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(theme.softFill, in: Capsule())
                        }
                        .accessibilityLabel("点名群成员")
                    }
    }

    /// Estimated context use. Neutral until it is worth a warning, so the accent color never reads as an alert.
    private var tokenMeter: some View {
        let textForEstimate = draft.text.count <= 96 ? draft.text : (debouncedEstimateText.isEmpty ? draft.text : debouncedEstimateText)
        let estimate = TokenEstimator.estimateUpcomingInput(
            conversation: conversation,
            providers: providers,
            draftText: textForEstimate,
            attachments: draft.attachments,
            quotedText: draft.quotedText,
            target: effectiveTarget,
            omitMemory: skippingMemory, omitKnowledge: requestOptions.omitKnowledge
        )
        let windowLimit = ContextWindowCatalog.contextLimit(for: effectiveTarget?.modelID)
        let fillRatio = ContextWindowCatalog.fillRatio(inputTokens: estimate.inputTokens, modelID: effectiveTarget?.modelID)
        let levelColor: Color = fillRatio >= 0.85 ? DS.StatusText.error
            : (fillRatio >= 0.65 ? DS.StatusText.warning : DS.Surface.inkSecondary)

        return HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Surface.strongBorder)
                    .frame(width: 26, height: 4)
                Capsule()
                    .fill(levelColor)
                    .frame(width: max(3, 26 * CGFloat(fillRatio)), height: 4)
            }
            .accessibilityHidden(true)

            HStack(spacing: 3) {
                Text(verbatim: "~\(estimate.inputTokens) / \(ContextWindowCatalog.formattedWindow(windowLimit))")
                if let cost = estimate.estimatedCostText {
                    Text("· \(cost)")
                }
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(fillRatio >= 0.65 ? levelColor : Color.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "上下文占用约 \(estimate.inputTokens) Token，窗口上限 \(ContextWindowCatalog.formattedWindow(windowLimit))"))
    }

    // MARK: - Expandable Capability & Attachment Drawer

    private var capabilityDrawer: some View {
        let kbCount = conversation.assistanceSettings.knowledgeVolumeIDs.count
        let toolsOn = conversation.assistanceSettings.enableAgentTools

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("添加内容")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: DS.Spacing.sm) {
                    drawerTile(title: String(localized: "相册"), systemImage: "photo.on.rectangle") {
                        isCapabilityDrawerOpen = false
                        showPhotoPicker = true
                    }
                    .disabled(!draft.isLoaded || draft.processingAttachments > 0)

                    drawerTile(title: String(localized: "拍照"), systemImage: "camera") {
                        isCapabilityDrawerOpen = false
                        showCameraPicker = true
                    }
                    .disabled(!draft.isLoaded || draft.processingAttachments > 0)

                    drawerTile(title: String(localized: "扫描文档"), systemImage: "doc.viewfinder") {
                        isCapabilityDrawerOpen = false
                        if DocumentScannerView.isSupported {
                            showDocumentScanner = true
                        } else {
                            draft.attachmentError = String(localized: "当前设备不支持文档相机扫描，可通过「相册」或「拍照」导入图片后点击本地 OCR 转文字。")
                        }
                    }
                    .disabled(!draft.isLoaded || draft.processingAttachments > 0)

                    drawerTile(title: String(localized: "文件"), systemImage: "doc.badge.plus") {
                        isCapabilityDrawerOpen = false
                        showFileImporter = true
                    }
                    .disabled(!draft.isLoaded || draft.processingAttachments > 0)
                }
            }

            Divider().opacity(0.45)

            Text("对话与发送设置")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: DS.Spacing.sm) {
                    Menu {
                        webModeButton("关闭搜索", mode: .off)
                        webModeButton("搜索", mode: .search)
                    } label: {
                        drawerPillLabel(title: webModeTitle, systemImage: "globe", isActive: webMode != .off)
                    }
                    .accessibilityIdentifier("chatComposer.webMode")
                    .disabled(isGenerating)

                    if !preferences.simpleDailyMode && !conversation.isGroupMode {
                        Menu {
                            thinkingMenuItems
                        } label: {
                            drawerPillLabel(
                                title: conversation.enableThinking ? String(localized: "思考 · \(max(1, conversation.thinkingBudgetTokens / 1024))K") : String(localized: "思考"),
                                systemImage: "brain",
                                isActive: conversation.enableThinking
                            )
                        }
                        .disabled(isGenerating)
                    }

                    drawerTogglePill(
                        title: String(localized: "开始新话题"),
                        systemImage: "scissors",
                        isActive: false
                    ) {
                        isCapabilityDrawerOpen = false
                        onInsertContextDivider()
                    }
                    .disabled(isGenerating)
                    .accessibilityHint("保留历史消息，后续请求不再携带分割线之前的上下文。")

                    if !preferences.simpleDailyMode {
                        if !conversation.isArenaMode && !conversation.isGroupMode {
                            drawerTogglePill(
                                title: String(localized: "工具"),
                                systemImage: "wrench.and.screwdriver",
                                isActive: toolsOn
                            ) {
                                preferences.triggerSelectionHaptic()
                                conversation.assistanceSettings.enableAgentTools.toggle()
                            }
                            .disabled(isGenerating)
                        }

                        if conversation.activeBookFriend == nil {
                            drawerTogglePill(
                                title: kbCount > 0 ? String(localized: "知识库 · \(kbCount)") : String(localized: "知识库"),
                                systemImage: kbCount > 0 ? "books.vertical.fill" : "books.vertical",
                                isActive: kbCount > 0
                            ) {
                                preferences.triggerSelectionHaptic()
                                isCapabilityDrawerOpen = false
                                onManageKnowledge()
                            }
                            .disabled(isGenerating)
                        }

                        drawerTogglePill(
                            title: String(localized: "发送选项"),
                            systemImage: "slider.horizontal.3",
                            isActive: false
                        ) {
                            isCapabilityDrawerOpen = false
                            onOpenOptions()
                        }
                        .disabled(isGenerating)
                    }
                }
            }
            .accessibilityIdentifier("composer.tools.settings")
            Text("联网搜索仅本次；原生联网、思考与工具用于本会话。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("新话题保留历史，后续请求不携带分割线前的上下文。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .dsCard(cornerRadius: DS.Radius.xl, fill: DS.Surface.card, borderColor: DS.Surface.strongBorder, padding: DS.Spacing.md)
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 4)
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Main Single Input Row

    private var modelActionTitle: String {
        canChooseModel ? String(localized: "选择模型") : String(localized: "连接模型")
    }

    private var pendingAttachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(draft.attachments) { item in pendingAttachmentChip(item) }
            }
        }
    }

    /// One card: model, session chips and context use share a single header row; a quote sits right above
    /// the text it is quoted for. Keeps the conversation visible above the keyboard.
    private var phoneSingleComposer: some View {
        VStack(alignment: .leading, spacing: 0) {
            let target = needsModel ? nil : effectiveTarget
            let modelTitle = target?.modelDisplayName ?? modelActionTitle
            HStack(spacing: DS.Spacing.sm) {
                Button {
                    isCapabilityDrawerOpen = false
                    onOpenModelPicker()
                } label: {
                    HStack(spacing: DS.Spacing.xxs) {
                        Text(verbatim: modelTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(target == nil ? theme.readableText : Color.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
                .layoutPriority(1)
                .accessibilityLabel(Text(verbatim: [modelTitle, target?.providerName ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")))
                .accessibilityHint("选择模型")
                .accessibilityIdentifier("chatComposer.model")

                if hasActiveStatusChips {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.xs) { statusChips }
                    }
                } else {
                    Spacer(minLength: 0)
                }

                if hasDraftContent { tokenMeter }
            }
            .padding(.horizontal, DS.Spacing.md)

            Divider().accessibilityHidden(true)
            if let quoted = draft.quotedText, !quoted.isEmpty {
                inlineQuoteRow(quoted)
            }
            inputRow.padding(.horizontal, DS.Spacing.xs).padding(.vertical, DS.Spacing.xxs)
            if writingFirst && !inputFocus.wrappedValue && hasDraftContent {
                draftStatus.padding(.horizontal, DS.Spacing.md).padding(.bottom, DS.Spacing.xs)
            }
        }
        .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.xl)
                .strokeBorder(DS.Surface.strongBorder)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    private func inlineQuoteRow(_ quoted: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Capsule()
                .fill(theme.tintColor.opacity(0.7))
                .frame(width: 2.5, height: 18)
                .accessibilityHidden(true)
            Text(verbatim: quoted)
                .accessibilityIdentifier("chatComposer.quote")
                .font(.footnote)
                .foregroundStyle(DS.Surface.inkSecondary)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                draft.quotedText = nil
                draft.save()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除引用")
        }
        .padding(.leading, DS.Spacing.md)
        .padding(.top, DS.Spacing.xxs)
    }

    private var writingEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack {
                    ChatStartModeMenu(isGenerating: isGenerating, onOpenArena: onOpenArenaPicker,
                                      onOpenGroup: onOpenGroupSetup, onOpenOptions: onOpenOptions)
                    Spacer()
                    if !needsModel {
                        ChatModelPickerButton(modelName: effectiveTarget?.modelDisplayName ?? modelActionTitle, action: onOpenModelPicker)
                            .disabled(isGenerating)
                    }
                }
                TextField("写下你的问题…", text: $draft.text, axis: .vertical)
                    .font(widthClass == .regular ? .title : .title3)
                    .lineLimit(3...7)
                    .frame(minHeight: widthClass == .regular ? 118 : nil, alignment: .topLeading)
                    .focused(inputFocus)
                    .disabled(!draft.isLoaded)
                    .accessibilityIdentifier("chatComposer.input")
                HStack {
                    attachmentButton
                    Spacer()
                    microphoneButton
                }
            }
            .padding(widthClass == .regular ? 24 : DS.Spacing.lg)
            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.island, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.island, style: .continuous)
                    .strokeBorder(DS.Surface.strongBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)

            if widthClass == .compact || typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 6) {
                    draftStatus.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    writingAction.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack {
                    draftStatus
                    Spacer(minLength: 12)
                    writingAction
                }
            }
        }
    }

    @ViewBuilder private var draftStatus: some View {
        if hasDraftContent && draft.persistenceError == nil {
            Text(draft.savedText == draft.text ? String(localized: "草稿已保存在本机") : String(localized: "正在保存草稿…"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var writingAction: some View {
        HStack(spacing: DS.Spacing.sm) {
            if needsModel {
                if !canChooseModel {
                    Text("首次发送前，先连接一个模型。").font(.footnote).foregroundStyle(.secondary)
                }
                Button(modelActionTitle, action: onOpenModelPicker)
                    .accessibilityIdentifier("chatComposer.model")
            } else {
                Button("发送") {
                    speech.stopDictationIfActive()
                    onSend()
                }
                .disabled(!canSend)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var attachmentButton: some View {
        Button {
            preferences.triggerSelectionHaptic()
            withAnimation(.snappy(duration: 0.22)) {
                isCapabilityDrawerOpen.toggle()
            }
        } label: {
            Image(systemName: isCapabilityDrawerOpen ? "xmark" : "plus")
                .font(.title3.weight(.medium))
                .foregroundStyle(isCapabilityDrawerOpen ? Color.secondary : Color.primary)
                .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCapabilityDrawerOpen ? String(localized: "收起工具面板") : String(localized: "添加附件与能力"))
        .accessibilityHint("展开相册、相机、文件与联网思考等发送增强选项")
    }

    private var microphoneButton: some View {
        Group {
            if speech.isRecording {
                Button { speech.stopDictation() } label: { microphoneIcon }
                    .accessibilityLabel("停止语音输入")
            } else {
                Menu {
                    Button { startDictation() } label: { Label("语音输入", systemImage: "mic") }
                    if let onOpenAudioTranscription {
                        Button {
                            isCapabilityDrawerOpen = false
                            onOpenAudioTranscription()
                        } label: { Label("音频纪要", systemImage: "waveform") }
                    }
                } label: { microphoneIcon }
                .accessibilityLabel("语音")
            }
        }
        .buttonStyle(.plain)
        .disabled(!speech.isRecording && (!draft.isLoaded || isGenerating))
        .accessibilityIdentifier("chatComposer.voice")
    }

    private var microphoneIcon: some View {
        Image(systemName: speech.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(speech.isRecording ? .red : .secondary)
            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
            .contentShape(Rectangle())
    }

    private func startDictation() {
        let targetConversationID = conversation.id
        let targetDraft = draft
        let baseText = targetDraft.text
        dictationBaseText = baseText
        speech.startDictation { transcript in
            guard conversation.id == targetConversationID else { return }
            targetDraft.text = Self.applyingDictationTranscript(transcript, toBase: baseText)
        }
    }

    @MainActor
    @discardableResult
    static func handleConversationSwitch(
        from oldID: UUID,
        to newID: UUID,
        speech: SpeechService,
        dictationBaseText: inout String
    ) -> Bool {
        guard oldID != newID else { return false }
        speech.stopDictationIfActive()
        dictationBaseText = ""
        return true
    }

    static func applyingDictationTranscript(_ transcript: String, toBase baseText: String) -> String {
        let prefix = baseText.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? transcript : "\(prefix) \(transcript)"
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.sm) {
            attachmentButton

            HStack(alignment: .bottom, spacing: DS.Spacing.xxs) {
                TextField(composerPlaceholder, text: $draft.text, axis: .vertical)
                    .accessibilityIdentifier("chatComposer.input")
                    .focused(inputFocus)
                    .disabled(!draft.isLoaded)
                    .lineLimit(1...6)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)

                microphoneButton
                .padding(.trailing, 4)
                .padding(.bottom, 1)
            }
            .background(usesPhoneWorkspace ? DS.Surface.canvas : DS.Surface.subtle,
                        in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                    .strokeBorder(DS.Surface.hairline, lineWidth: 1)
            )

            if isGenerating {
                HStack(spacing: DS.Spacing.xs) {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 31))
                            .foregroundStyle(DS.StatusText.error)
                            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("停止生成")

                    if conversation.isGroupMode && canSend {
                        Button {
                            speech.stopDictationIfActive()
                            onSend()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 31))
                                .foregroundStyle(theme.solidFill)
                                .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("插话发送")
                    }
                }
            } else if !writingFirst || !needsModel {
                Button {
                    speech.stopDictationIfActive()
                    if isCapabilityDrawerOpen {
                        withAnimation(.snappy(duration: 0.18)) {
                            isCapabilityDrawerOpen = false
                        }
                    }
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 31))
                        .foregroundStyle(canSend ? theme.solidFill : Color.secondary.opacity(0.32))
                        .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
                .accessibilityIdentifier("chatComposer.send")
            }
        }
    }

    // MARK: - Subcomponents & Menus

    @ViewBuilder
    private var thinkingMenuItems: some View {
        Button {
            conversation.enableThinking = false
        } label: {
            Label("关闭思考", systemImage: conversation.enableThinking ? "circle" : "checkmark.circle.fill")
        }
        Divider()
        ForEach([
            (2048, String(localized: "轻量思考 (2K)")),
            (8192, String(localized: "均衡思考 (8K)")),
            (16384, String(localized: "深度思考 (16K)")),
            (32768, String(localized: "极限推理 (32K)"))
        ], id: \.0) { budget, title in
            Button {
                conversation.enableThinking = true
                conversation.thinkingBudgetTokens = budget
                preferences.triggerSelectionHaptic()
            } label: {
                let selected = conversation.enableThinking && conversation.thinkingBudgetTokens == budget
                Label(title, systemImage: selected ? "checkmark.circle.fill" : "brain")
            }
        }
    }

    private func webModeButton(_ title: LocalizedStringKey, mode: WebMode) -> some View {
        Button {
            setWebMode(mode)
        } label: {
            if webMode == mode { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private func setWebMode(_ mode: WebMode) {
        preferences.triggerSelectionHaptic()
        if mode != .search && searchQueryAutoSync {
            requestOptions.searchQuery = ""
            searchQueryAutoSync = false
        }
        switch mode {
        case .off:
            requestOptions.setSearch(false, draft: "")
            if !conversation.isGroupMode { conversation.assistanceSettings.enableNativeGrounding = false }
        case .search:
            if TavilySearchClient.isConfigured || conversation.isGroupMode || requestOptions.useSearch {
                let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !requestOptions.useSearch { searchQueryAutoSync = requestOptions.searchQuery.isEmpty }
                requestOptions.setSearch(true, draft: trimmed)
            } else {
                conversation.assistanceSettings.enableNativeGrounding = true
            }
        }
    }

    private func removableChip(title: String, systemImage: String, tint: Color, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.75)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 4)
            .background(theme.softFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func drawerTile(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.xxs) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: typeSize.isAccessibilitySize ? 105 : 68)
            .frame(minHeight: typeSize.isAccessibilitySize ? 66 : 52)
            .background(DS.Surface.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .strokeBorder(DS.Surface.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func drawerTogglePill(title: String, systemImage: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            drawerPillLabel(title: title, systemImage: systemImage, isActive: isActive)
        }
        .buttonStyle(.plain)
    }

    private func drawerPillLabel(title: String, systemImage: String, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(isActive ? theme.readableText : .primary)
        .padding(.horizontal, 11)
        .frame(minHeight: DS.TouchTarget.minimum)
        .background(isActive ? theme.softFill : DS.Surface.canvas, in: Capsule())
        .overlay(
            Capsule().strokeBorder(isActive ? theme.tintColor.opacity(0.4) : DS.Surface.hairline, lineWidth: 1)
        )
    }

    private var searchQueryRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.readableText)
            TextField(
                "搜索词（发送给 \(TavilySearchClient.ledgerTarget.providerName)）",
                text: Binding(
                    get: { requestOptions.searchQuery },
                    set: {
                        searchQueryAutoSync = false
                        requestOptions.searchQuery = String($0.prefix(400))
                    }
                )
            )
            .font(.caption)
            Button {
                setWebMode(.off)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 7)
        .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .padding(.horizontal, DS.Spacing.md)
    }

    private var recordingBanner: some View {
        HStack(spacing: DS.Spacing.sm) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text("正在聆听，请直接说话…")
                .font(.caption.weight(.medium))
                .foregroundStyle(DS.StatusText.error)
            Spacer()
            Button("完成") {
                speech.stopDictation()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.readableText)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .padding(.horizontal, DS.Spacing.md)
    }

    private func quotedPreviewBanner(_ quoted: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Capsule()
                .fill(theme.tintColor.opacity(0.7))
                .frame(width: 2.5, height: 18)
                .accessibilityHidden(true)
            Text(verbatim: quoted)
                .accessibilityIdentifier("chatComposer.quote")
                .font(.footnote)
                .foregroundStyle(DS.Surface.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                draft.quotedText = nil
                draft.save()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除引用")
        }
        .padding(.leading, DS.Spacing.md)
        .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .padding(.horizontal, DS.Spacing.md)
    }

    private var draftRecoveryBanner: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.StatusText.warning)
                .font(.caption)
            Text("草稿暂未读取成功")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("重试") {
                draft.load()
            }
            .font(.caption.weight(.semibold))
            Button("重置草稿", role: .destructive) {
                draft.discardUnreadableDraft()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, DS.Spacing.xs)
    }

    private var composerPlaceholder: String {
        if writingFirst { return String(localized: "写下你的问题…") }
        if conversation.isGroupMode {
            return isGenerating
                ? String(localized: "讨论进行中，可直接输入插话打断…")
                : String(localized: "发消息进群讨论，输入 @ 点名角色…")
        }
        if conversation.readingVolumeID != nil { return String(localized: "就这段继续提问…") }
        return String(localized: "输入消息，支持 / 指令、@ 模型或发图…")
    }

    private var mentionPopover: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                if conversation.isGroupMode {
                    Button {
                        draft.insertGroupMention(String(localized: "@所有人 ").trimmingCharacters(in: .whitespacesAndNewlines))
                    } label: {
                        Text("📣 所有人")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    ForEach(conversation.activeGroupMembers) { member in
                        Button {
                            draft.insertGroupMention("@\(member.mentionToken)", memberID: member.id)
                        } label: {
                            HStack(spacing: 5) {
                                Text(member.avatarEmoji)
                                    .font(.caption)
                                Text(member.displayLabel)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(availableTargets) { target in
                        Button {
                            temporaryTarget = target
                            if draft.text.hasSuffix("@") {
                                draft.text.removeLast()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(hex: target.accentHex))
                                    .frame(width: 7, height: 7)
                                Text(target.modelDisplayName)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    private func appendAttachment(_ attachment: MessageAttachment) { draft.append(attachment) }

    @ViewBuilder
    private func pendingAttachmentChip(_ item: MessageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                attachmentReview = DraftAttachmentReview(sources: [item], recognize: false)
            } label: {
                if let uiImg = item.cachedImage {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                } else {
                    HStack(spacing: DS.Spacing.xs) {
                        Image(systemName: item.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                            .foregroundStyle(theme.readableText)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.fileName)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                            Text(item.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 48)
                    .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览附件 \(item.fileName)")

            Button {
                draft.attachments.removeAll { $0.id == item.id }
                draft.save()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.68))
            }
            .offset(x: 5, y: -5)
            .accessibilityLabel("移除附件 \(item.fileName)")
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}
