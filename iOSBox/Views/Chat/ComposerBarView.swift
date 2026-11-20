import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ComposerBarView: View {
    @Bindable var conversation: Conversation
    @Bindable var draft: ChatDraftState
    let providers: [ProviderConfig]
    let presets: [AssistantPreset]
    let isGenerating: Bool
    @Binding var requestOptions: ComposerRequestOptions
    let onOpenModelPicker: () -> Void
    let onOpenArenaPicker: () -> Void
    var onOpenGroupSetup: (() -> Void)? = nil
    let onOpenOptions: () -> Void
    let inputFocus: FocusState<Bool>.Binding
    let onInsertContextDivider: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showFileImporter = false
    @State private var showMentionSheet = false
    @State private var showKnowledgeSheet = false
    @State private var searchQueryAutoSync = false
    @State private var speech = SpeechService.shared
    @State private var preferences = AppPreferences.shared
    @State private var dictationBaseText = ""

    private var temporaryTarget: ResolvedModelTarget? {
        get { requestOptions.temporaryTarget }
        nonmutating set { requestOptions.temporaryTarget = newValue }
    }

    private var canSend: Bool { draft.canSend }

    private var availableTargets: [ResolvedModelTarget] {
        ChatEngine.shared.availableTargets(from: providers)
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

    var body: some View {
        VStack(spacing: 8) {
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

            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            if conversation.isGroupMode {
                                onOpenGroupSetup?()
                            } else if conversation.isArenaMode {
                                onOpenArenaPicker()
                            } else {
                                onOpenModelPicker()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if conversation.isGroupMode {
                                    Image(systemName: "person.3.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                    Text("群聊 · \(conversation.activeGroupMembers.count) 人 · \(conversation.assistanceSettings.groupSpeakingMode.shortBadge)")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                } else if conversation.isArenaMode {
                                    Image(systemName: "square.split.2x1.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                    Text("并发对比 · \(max(conversation.arenaTargets.count, 0)) 模型")
                                        .font(.caption.weight(.semibold))
                                } else if let target = requestOptions.temporaryTarget ?? conversation.primaryTarget {
                                    Circle()
                                        .fill(Color(hex: target.accentHex))
                                        .frame(width: 7, height: 7)
                                    Text(requestOptions.temporaryTarget != nil ? String(localized: "本次 · \(target.modelDisplayName)") : target.modelDisplayName)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                } else {
                                    Image(systemName: "cpu")
                                        .font(.caption2)
                                    Text("选择模型")
                                        .font(.caption.weight(.semibold))
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                (requestOptions.temporaryTarget != nil || conversation.isGroupMode)
                                    ? Color.accentColor.opacity(0.14)
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)

                        if !conversation.isGroupMode && requestOptions.temporaryTarget != nil {
                            Button {
                                requestOptions.temporaryTarget = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("取消临时指定模型")
                        }

                        // Quick Web Search toggle pill (uses Tavily when configured, otherwise toggles provider-native grounding)
                        let nativeOn = !conversation.isGroupMode && conversation.assistanceSettings.enableNativeGrounding
                        let searchActive = requestOptions.useSearch || nativeOn
                        Button {
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
                                onOpenOptions()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                    .font(.caption2.weight(.semibold))
                                Text("联网")
                                    .font(.caption.weight(searchActive ? .semibold : .medium))
                            }
                            .foregroundStyle(searchActive ? Color.accentColor : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                searchActive ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isGenerating)

                        // Quick Thinking tier menu pill
                        if !conversation.isGroupMode {
                            Menu {
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
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.caption2.weight(.semibold))
                                    Text(conversation.enableThinking ? String(localized: "思考 · \(max(1, conversation.thinkingBudgetTokens / 1024))K") : String(localized: "思考"))
                                        .font(.caption.weight(conversation.enableThinking ? .semibold : .medium))
                                }
                                .foregroundStyle(conversation.enableThinking ? .purple : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    conversation.enableThinking ? Color.purple.opacity(0.14) : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                            }
                            .disabled(isGenerating)
                        }

                        // Quick Agent Tools toggle pill (single chat)
                        if !conversation.isArenaMode && !conversation.isGroupMode {
                            let toolsOn = conversation.assistanceSettings.enableAgentTools
                            Button {
                                preferences.triggerSelectionHaptic()
                                conversation.assistanceSettings.enableAgentTools.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "wrench.and.screwdriver")
                                        .font(.caption2.weight(.semibold))
                                    Text("工具")
                                        .font(.caption.weight(toolsOn ? .semibold : .medium))
                                }
                                .foregroundStyle(toolsOn ? Color.accentColor : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    toolsOn ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isGenerating)

                            // Socratic / Feynman Study Coach mode menu pill
                            let coachMode = conversation.assistanceSettings.studyCoachMode
                            Menu {
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
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: coachMode == .off ? "graduationcap" : coachMode.symbol)
                                        .font(.caption2.weight(.semibold))
                                    Text(coachMode.shortBadge)
                                        .font(.caption.weight(coachMode != .off ? .semibold : .medium))
                                }
                                .foregroundStyle(coachMode != .off ? .indigo : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    coachMode != .off ? Color.indigo.opacity(0.15) : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                            }
                            .disabled(isGenerating)
                        }

                        // Project Knowledge Base pill (works across Single Chat, Arena & Group Roundtable!)
                        if conversation.activeBookFriend == nil {
                            let kbCount = conversation.assistanceSettings.knowledgeVolumeIDs.count
                            Button {
                                preferences.triggerSelectionHaptic()
                                showKnowledgeSheet = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: kbCount > 0 ? "books.vertical.fill" : "books.vertical")
                                        .font(.caption2.weight(.semibold))
                                    Text(kbCount > 0 ? String(localized: "知识库 · \(kbCount)") : String(localized: "知识库"))
                                        .font(.caption.weight(kbCount > 0 ? .semibold : .medium))
                                }
                                .foregroundStyle(kbCount > 0 ? .teal : .secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(
                                    kbCount > 0 ? Color.teal.opacity(0.14) : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isGenerating)
                        }
                    }
                }

                if conversation.isGroupMode && !conversation.activeGroupMembers.isEmpty {
                    Menu {
                        Button("📣 @所有人") {
                            insertGroupMention(String(localized: "@所有人 "))
                        }
                        Divider()
                        ForEach(conversation.activeGroupMembers) { member in
                            Button("\(member.avatarEmoji) \(member.displayLabel) · \(member.target.modelDisplayName)") {
                                insertGroupMention("@\(member.mentionToken) ")
                            }
                        }
                    } label: {
                        Text("@")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .accessibilityLabel("点名群成员")
                }

                Button(action: onOpenOptions) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
                .accessibilityLabel("发送选项")
            }
            .padding(.horizontal, 12)
            .onChange(of: draft.text) { _, newText in
                if requestOptions.useSearch && searchQueryAutoSync {
                    requestOptions.searchQuery = String(newText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
                }
            }
            .onChange(of: requestOptions.useSearch) { _, enabled in
                if !enabled { searchQueryAutoSync = false }
            }

            if !conversation.isGroupMode && !conversation.isArenaMode
                && conversation.assistanceSettings.studyCoachMode != .off
                && !isGenerating
                && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let chips = conversation.assistanceSettings.studyCoachMode.quickChips
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips) { chip in
                                Button {
                                    preferences.triggerSelectionHaptic()
                                    draft.text = chip.prompt
                                    onSend()
                                } label: {
                                    Text(chip.label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.indigo)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.indigo.opacity(0.11), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }

            if requestOptions.useSearch {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
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
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
            }

            if speech.isRecording {
                HStack(spacing: 8) {
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
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
            }

            if let quoted = draft.quotedText, !quoted.isEmpty {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                    Text(quoted)
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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
            }

            if draft.processingAttachments > 0 {
                ProgressView().accessibilityLabel("正在处理附件")
            }

            // Pending attachments preview strip
            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.attachments) { item in
                            pendingAttachmentChip(item)
                        }
                    }
                    .padding(.horizontal, 12)
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
                HStack(spacing: 8) {
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
                .padding(.vertical, 6)
            }

            // Input row
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("从相册选择图片", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showCameraPicker = true
                    } label: {
                        Label("拍照识图", systemImage: "camera")
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("上传文档或代码文件", systemImage: "doc.badge.plus")
                    }

                    Divider()

                    Button {
                        onInsertContextDivider()
                    } label: {
                        Label("插入清除上下文分割线", systemImage: "scissors")
                    }
                    .disabled(isGenerating)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!draft.isLoaded || draft.processingAttachments > 0)
                .accessibilityLabel("添加附件")
                .accessibilityHint("从相册、相机或文件中添加图片与文档")

                TextField(composerPlaceholder, text: $draft.text, axis: .vertical)
                    .accessibilityIdentifier("chatComposer.input")
                    .focused(inputFocus)
                    .disabled(!draft.isLoaded)
                    .lineLimit(1...6)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

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
                    Image(systemName: speech.isRecording ? "mic.circle.fill" : "mic.circle")
                        .font(.system(size: 27))
                        .foregroundStyle(speech.isRecording ? .red : .secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!draft.isLoaded || isGenerating)
                .accessibilityLabel(speech.isRecording ? String(localized: "停止语音输入") : String(localized: "语音输入"))

                if isGenerating {
                    HStack(spacing: 6) {
                        Button(action: onStop) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 31))
                                .foregroundStyle(.red)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("停止生成")

                        if conversation.isGroupMode && canSend {
                            Button {
                                if speech.isRecording {
                                    speech.stopDictation()
                                }
                                onSend()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 31))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("插话发送")
                        }
                    }
                } else {
                    Button {
                        if speech.isRecording {
                            speech.stopDictation()
                        }
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 31))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .text, .json, .commaSeparatedText, .xml, .sourceCode, .image],
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
        .onDisappear {
            if speech.isRecording {
                speech.stopDictation()
            }
        }
        .sheet(isPresented: $showKnowledgeSheet) {
            KnowledgeBindingSheet(
                selectedVolumeIDs: Binding(
                    get: { conversation.assistanceSettings.knowledgeVolumeIDs },
                    set: {
                        conversation.assistanceSettings.knowledgeVolumeIDs = $0
                        try? conversation.modelContext?.save()
                    }
                )
            )
        }
    }

    private var composerPlaceholder: String {
        if conversation.isGroupMode {
            return isGenerating
                ? String(localized: "讨论进行中，可直接输入插话打断…")
                : String(localized: "发消息进群讨论，输入 @ 点名角色…")
        }
        return String(localized: "输入消息，支持 / 指令、@ 模型或发图…")
    }

    private func insertGroupMention(_ token: String) {
        if draft.text.hasSuffix("@") {
            draft.text.removeLast()
        } else if !draft.text.isEmpty && !draft.text.hasSuffix(" ") {
            draft.text.append(" ")
        }
        draft.text.append(token)
        draft.save()
    }

    private var mentionPopover: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if conversation.isGroupMode {
                    Button {
                        insertGroupMention(String(localized: "@所有人 "))
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
                            insertGroupMention("@\(member.mentionToken) ")
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
            .padding(.horizontal, 12)
        }
    }

    private func appendAttachment(_ attachment: MessageAttachment) { draft.append(attachment) }

    @ViewBuilder
    private func pendingAttachmentChip(_ item: MessageAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            if let uiImg = item.cachedImage {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: item.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                        .foregroundStyle(Color.accentColor)
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
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
