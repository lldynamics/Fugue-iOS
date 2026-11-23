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
    let onOpenBlindPicker: () -> Void
    var onOpenGroupSetup: (() -> Void)? = nil
    let onOpenOptions: () -> Void
    let onManageKnowledge: () -> Void
    var onOpenAudioTranscription: (() -> Void)? = nil
    var onOpenVoiceConversation: (() -> Void)? = nil
    var externalDocumentScanTrigger: Int = 0
    var writingFirst = false
    var needsModel = false
    var canChooseModel = false
    let inputFocus: FocusState<Bool>.Binding
    let onInsertContextDivider: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isCapabilityDrawerOpen = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showDocumentScanner = false
    @State private var showFileImporter = false
    @State private var isRunningLocalOCR = false
    @State private var searchQueryAutoSync = false
    @State private var speech = SpeechService.shared
    @State private var preferences = AppPreferences.shared
    @State private var dictationBaseText = ""
    @State private var debouncedEstimateText = ""

    private var theme: DS.AccentTheme { preferences.accentTheme }

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

    private var isSearchActive: Bool {
        requestOptions.useSearch || (!conversation.isGroupMode && conversation.assistanceSettings.enableNativeGrounding)
    }

    private var hasActiveStatusChips: Bool {
        (!conversation.isGroupMode && requestOptions.temporaryTarget != nil)
            || isSearchActive
            || (!conversation.isGroupMode && conversation.enableThinking)
            || (!conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools)
            || (!conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.studyCoachMode != .off)
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
                            if cmd.id == "socratic-coach" && !conversation.isGroupMode {
                                conversation.assistanceSettings.studyCoachMode = .socratic
                            } else if cmd.id == "feynman-coach" && !conversation.isGroupMode {
                                conversation.assistanceSettings.studyCoachMode = .feynman
                            }
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
            if (isCapabilityDrawerOpen || (!writingFirst && (conversation.readingVolumeID == nil || hasDraftContent))) && (hasActiveStatusChips || hasDraftContent) {
                activeStatusStrip
            }

            if !conversation.isGroupMode && !conversation.isArenaMode
                && conversation.assistanceSettings.studyCoachMode != .off
                && !isGenerating
                && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let chips = conversation.assistanceSettings.studyCoachMode.quickChips
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Spacing.xs) {
                            ForEach(chips) { chip in
                                Button {
                                    preferences.triggerSelectionHaptic()
                                    draft.text = chip.prompt
                                    onSend()
                                } label: {
                                    Text(chip.label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(theme.readableText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(theme.softFill, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, DS.Spacing.md)
                    }
                }
            }

            if requestOptions.useSearch {
                searchQueryRow
            }

            if speech.isRecording {
                recordingBanner
            }

            if let quoted = draft.quotedText, !quoted.isEmpty {
                quotedPreviewBanner(quoted)
            }

            if draft.processingAttachments > 0 {
                ProgressView().accessibilityLabel("正在处理附件")
            }

            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(draft.attachments) { item in
                            pendingAttachmentChip(item)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.md)
                }

                if draft.attachments.contains(where: { $0.kind == .image }) {
                    HStack(spacing: DS.Spacing.sm) {
                        Button {
                            convertPendingImagesWithLocalOCR()
                        } label: {
                            HStack(spacing: 6) {
                                if isRunningLocalOCR {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "doc.text.viewfinder")
                                        .font(.caption.weight(.semibold))
                                }
                                Text(isRunningLocalOCR ? "正在本地识别文字…" : "本地 OCR 转文字（免识图 / 省 Token）")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(theme.readableText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.softFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunningLocalOCR || draft.processingAttachments > 0)

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
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }

            if !draft.isLoaded {
                draftRecoveryBanner
            }

            // Main single-row minimal input bar
            if writingFirst {
                writingEditor
            } else {
                inputRow
            }
        }
        .padding(.top, DS.Spacing.sm)
        .background { if !writingFirst { Rectangle().fill(.ultraThinMaterial) } }
        .overlay(alignment: .top) { if !writingFirst { Divider().opacity(0.45) } }
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
        .onDisappear {
            if speech.isRecording {
                speech.stopDictation()
            }
        }
    }

    // MARK: - Active Status Strip (Slim, State-Driven)

    private var activeStatusStrip: some View {
        let skippingMemory = requestOptions.omitMemory && conversation.assistanceSettings.usePersonalMemory

        return HStack(spacing: DS.Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.xs) {
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
                            .foregroundStyle(.orange)
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

                    if isSearchActive {
                        removableChip(
                            title: String(localized: "联网"),
                            systemImage: "globe",
                            tint: theme.readableText
                        ) {
                            if requestOptions.useSearch {
                                requestOptions.setSearch(false, draft: "")
                                searchQueryAutoSync = false
                            } else {
                                conversation.assistanceSettings.enableNativeGrounding = false
                            }
                        }
                        .disabled(isGenerating)
                    }

                    if !conversation.isGroupMode && conversation.enableThinking {
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

                    if !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools {
                        removableChip(
                            title: String(localized: "工具"),
                            systemImage: "wrench.and.screwdriver",
                            tint: theme.readableText
                        ) {
                            conversation.assistanceSettings.enableAgentTools = false
                        }
                        .disabled(isGenerating)
                    }

                    if !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.studyCoachMode != .off {
                        let coachMode = conversation.assistanceSettings.studyCoachMode
                        Menu {
                            studyCoachMenuItems
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: coachMode.symbol)
                                    .font(.caption2.weight(.semibold))
                                Text(coachMode.shortBadge)
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(theme.readableText)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(theme.softFill, in: Capsule())
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
            }

            if hasDraftContent {
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
                HStack(spacing: 3) {
                    Text("~\(estimate.inputTokens) tok")
                    if let cost = estimate.estimatedCostText {
                        Text("· \(cost)")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Expandable Capability & Attachment Drawer

    private var capabilityDrawer: some View {
        let kbCount = conversation.assistanceSettings.knowledgeVolumeIDs.count
        let toolsOn = conversation.assistanceSettings.enableAgentTools
        let coachMode = conversation.assistanceSettings.studyCoachMode

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Row 1: Attachments & Context
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

                if let onOpenAudioTranscription {
                    drawerTile(title: String(localized: "音频纪要"), systemImage: "waveform") {
                        isCapabilityDrawerOpen = false
                        onOpenAudioTranscription()
                    }
                    .disabled(isGenerating)
                } else {
                    drawerTile(title: String(localized: "清上文"), systemImage: "scissors") {
                        isCapabilityDrawerOpen = false
                        onInsertContextDivider()
                    }
                    .disabled(isGenerating)
                }
            }

            Divider().opacity(0.45)

            // Row 2: Model & Capability Controls
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.sm) {
                    if onOpenAudioTranscription != nil {
                        drawerTogglePill(
                            title: String(localized: "清上文"),
                            systemImage: "scissors",
                            isActive: false
                        ) {
                            isCapabilityDrawerOpen = false
                            onInsertContextDivider()
                        }
                        .disabled(isGenerating)
                    }

                    if let onOpenVoiceConversation {
                        drawerTogglePill(
                            title: String(localized: "语音对谈"),
                            systemImage: "headphones",
                            isActive: false
                        ) {
                            isCapabilityDrawerOpen = false
                            onOpenVoiceConversation()
                        }
                        .disabled(isGenerating)
                    }

                    drawerTogglePill(
                        title: String(localized: "联网"),
                        systemImage: "globe",
                        isActive: isSearchActive
                    ) {
                        toggleWebSearch()
                    }
                    .disabled(isGenerating)

                    if !preferences.simpleDailyMode {
                        if !conversation.isGroupMode {
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

                            Menu {
                                studyCoachMenuItems
                            } label: {
                                drawerPillLabel(
                                    title: coachMode.shortBadge,
                                    systemImage: coachMode == .off ? "graduationcap" : coachMode.symbol,
                                    isActive: coachMode != .off
                                )
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
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.subtle, padding: DS.Spacing.md)
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: - Main Single Input Row

    private var modelActionTitle: String {
        canChooseModel ? String(localized: "选择模型") : String(localized: "连接模型")
    }

    private var writingEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                HStack {
                    if !preferences.simpleDailyMode {
                        Menu {
                            Button(action: onOpenBlindPicker) { Label("双盲对比", systemImage: "eye.slash") }
                            Button(action: onOpenArenaPicker) { Label("多模型对比", systemImage: "square.split.2x1") }
                            if let onOpenGroupSetup {
                                Button(action: onOpenGroupSetup) { Label("圆桌群聊", systemImage: "person.3") }
                            }
                            Button(action: onOpenOptions) { Label("请求选项", systemImage: "slider.horizontal.3") }
                        } label: {
                            HStack(spacing: 6) {
                                Text("单聊")
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(DS.Surface.subtle, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
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
            .background(DS.Surface.canvas, in: RoundedRectangle(cornerRadius: DS.Radius.xl))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.xl).strokeBorder(DS.Surface.hairline) }

            if widthClass == .compact || typeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 6) {
                    draftStatus.frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    writingAction
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
                    if speech.isRecording { speech.stopDictation() }
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
            Image(systemName: isCapabilityDrawerOpen ? "xmark.circle" : (writingFirst ? "paperclip" : "plus.circle.fill"))
                .font(.system(size: 27))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isCapabilityDrawerOpen ? .secondary : theme.readableText)
                .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCapabilityDrawerOpen ? String(localized: "收起工具面板") : String(localized: "添加附件与能力"))
        .accessibilityHint("展开相册、相机、文件与联网思考等发送增强选项")
    }

    private var microphoneButton: some View {
        Button {
            if speech.isRecording {
                speech.stopDictation()
            } else {
                dictationBaseText = draft.text
                speech.startDictation { transcript in
                    let prefix = dictationBaseText.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.text = prefix.isEmpty ? transcript : "\(prefix) \(transcript)"
                }
            }
        } label: {
            Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(speech.isRecording ? .red : .secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!draft.isLoaded || isGenerating)
        .accessibilityLabel(speech.isRecording ? String(localized: "停止语音输入") : String(localized: "语音输入"))
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
            .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                    .strokeBorder(DS.Surface.hairline, lineWidth: 1)
            )

            if isGenerating {
                HStack(spacing: DS.Spacing.xs) {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 31))
                            .foregroundStyle(.red)
                            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("停止生成")

                    if conversation.isGroupMode && canSend {
                        Button {
                            if speech.isRecording { speech.stopDictation() }
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
            } else {
                Button {
                    if speech.isRecording { speech.stopDictation() }
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
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.bottom, DS.Spacing.sm)
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

    @ViewBuilder
    private var studyCoachMenuItems: some View {
        let coachMode = conversation.assistanceSettings.studyCoachMode
        ForEach(StudyCoachMode.allCases) { mode in
            Button {
                conversation.assistanceSettings.studyCoachMode = mode
                preferences.triggerSelectionHaptic()
            } label: {
                Label(
                    mode.displayName,
                    systemImage: coachMode == mode ? "checkmark.circle.fill" : mode.symbol
                )
            }
        }
    }

    private func toggleWebSearch() {
        preferences.triggerSelectionHaptic()
        let hasTavily = !KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount).isEmpty
        if hasTavily || requestOptions.useSearch {
            let next = !requestOptions.useSearch
            let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            searchQueryAutoSync = next && requestOptions.searchQuery.isEmpty
            requestOptions.setSearch(next, draft: trimmed)
        } else if !conversation.isGroupMode {
            conversation.assistanceSettings.enableNativeGrounding.toggle()
        } else {
            isCapabilityDrawerOpen = false
            onOpenOptions()
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
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
        .padding(.vertical, 8)
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
                "搜索词（仅发送此内容给 Tavily）",
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
                requestOptions.setSearch(false, draft: "")
                searchQueryAutoSync = false
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
                .foregroundStyle(.red)
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
            RoundedRectangle(cornerRadius: 1.5)
                .fill(theme.tintColor)
                .frame(width: 3)
            Text(quoted)
                .accessibilityIdentifier("chatComposer.quote")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button {
                draft.quotedText = nil
                draft.save()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除引用")
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .padding(.horizontal, DS.Spacing.md)
    }

    private var draftRecoveryBanner: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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

    private func convertPendingImagesWithLocalOCR() {
        guard !isRunningLocalOCR else { return }
        let snapshot = draft.attachments
        guard snapshot.contains(where: { $0.kind == .image }) else { return }
        isRunningLocalOCR = true
        draft.attachmentError = nil
        Task {
            let result = await DocumentOCRService.convertImageAttachmentsToOCRDocument(snapshot)
            await MainActor.run {
                isRunningLocalOCR = false
                if let doc = result.document, !result.convertedIDs.isEmpty {
                    let convertedSet = Set(result.convertedIDs)
                    draft.attachments.removeAll { convertedSet.contains($0.id) }
                    appendAttachment(doc)
                } else {
                    draft.attachmentError = String(localized: "未从所选图片中识别出可读文字，可直接保留原图发送。")
                }
            }
        }
    }

    @ViewBuilder
    private func pendingAttachmentChip(_ item: MessageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
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
