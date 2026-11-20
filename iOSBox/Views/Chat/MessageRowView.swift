import SwiftUI
import UIKit

struct MessageRowView: View {
    let message: ChatMessage
    var isCompactCard: Bool = false
    var blindLabel: String? = nil
    var branchSiblings: [ChatMessage] = []
    var availableCompareTargets: [ResolvedModelTarget] = []
    var onSwitchBranch: ((ChatMessage) -> Void)?
    var onSelectRevision: ((Int) -> Void)?
    var onRegenerate: (() -> Void)?
    var onRegenerateWithCurrentModel: (() -> Void)?
    var onRegenerateWithOverride: ((ResolvedModelTarget) -> Void)?
    var onContinueGeneration: (() -> Void)?
    var onEditAndResend: ((String) -> Void)?
    var onQuote: ((String) -> Void)?
    var onToggleBookmark: (() -> Void)?
    var onToggleExcludeFromContext: (() -> Void)?
    var onForkConversation: (() -> Void)?
    var onCompareWithModel: ((ResolvedModelTarget) -> Void)?
    var onMentionMember: ((String) -> Void)?
    var onDeleteMessage: (() -> Void)?
    var studyDeckName: String = ""
    var conversationID: UUID = UUID()
    var isGeneratingStudy: Bool = false
    var onGenerateFlashcards: (() -> Void)?
    var onGenerateQuiz: (() -> Void)?
    var onExtractSchedule: (() -> Void)?
    var onSelectQuizOption: ((UUID, Int) -> Void)?

    @State private var copiedToast = false
    @State private var previewImage: UIImage?
    @State private var showEditSheet = false
    @State private var showTextSelectionSheet = false
    @State private var showExpandedMetrics = false
    @State private var editDraftText = ""
    @State private var speech = SpeechService.shared
    @State private var preferences = AppPreferences.shared
    @ScaledMetric(relativeTo: .body) private var baseBodySize: CGFloat = 17

    var body: some View {
        if message.role == .system, message.assistanceMetadataData != nil, let notice = message.assistanceMetadata.sourceNotice {
            sourceCard(notice)
        } else if message.role == .system {
            systemDividerView
        } else if message.role == .user {
            userMessageView
        } else {
            assistantMessageView
        }
    }

    private func sourceCard(_ notice: GroupSourceNotice) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(notice.byline, systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: notice.title).font(.subheadline.weight(.semibold)).textSelection(.enabled)
            if let excerpt = notice.excerpt, !excerpt.isEmpty { Text(verbatim: excerpt).font(.callout).textSelection(.enabled) }
            if let date = notice.published { Text(date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary) }
            if (try? URLReader.validate(notice.url)) != nil {
                Link(destination: notice.url) { Label("打开原文", systemImage: "arrow.up.right") }.font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let onDeleteMessage { Button("删除此条消息", role: .destructive, action: onDeleteMessage) }
        }
    }

    // MARK: - System Context Divider

    private var systemDividerView: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)

            HStack(spacing: 5) {
                Image(systemName: "scissors")
                    .font(.caption2)
                Text(message.content.isEmpty ? String(localized: "已清除上文，以下开启新话题") : message.content)
                    .font(.caption2.weight(.medium))
                if let onDeleteMessage {
                    Button(role: .destructive) {
                        onDeleteMessage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除此条消息")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: Capsule())

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
    }

    // MARK: - User Bubble

    private var userMessageView: some View {
        let attachments = message.attachments
        let meta = message.assistanceMetadata
        let currentBranchIdx = branchSiblings.firstIndex(where: { $0.id == message.id }) ?? 0

        return HStack {
            Spacer(minLength: 42)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    attachmentGrid(attachments, alignment: .trailing)
                }

                if let quote = meta.quotedExcerpt, !quote.isEmpty {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 2.5)
                        Text(quote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if !message.content.isEmpty {
                    Group {
                        if message.content.contains("```") {
                            MarkdownContentView(text: message.content, isStreaming: false)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(
                                    Color.accentColor.opacity(meta.isExcludedFromContext ? 0.07 : 0.13),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(Color.accentColor.opacity(0.24), lineWidth: 1)
                                )
                        } else {
                            Text(message.content)
                                .font(.system(size: baseBodySize * preferences.fontScale))
                                .foregroundStyle(.white)
                                .lineSpacing(3)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    Color.accentColor.opacity(meta.isExcludedFromContext ? 0.52 : 1.0),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("复制提问", systemImage: "doc.on.doc")
                        }

                        Button {
                            showTextSelectionSheet = true
                        } label: {
                            Label("选择文本", systemImage: "selection.pin.in.out")
                        }

                        if let onQuote {
                            Button {
                                onQuote(message.content)
                            } label: {
                                Label("引用追问", systemImage: "quote.opening")
                            }
                        }

                        if onEditAndResend != nil {
                            Button {
                                editDraftText = message.content
                                showEditSheet = true
                            } label: {
                                Label("编辑重发", systemImage: "pencil")
                            }
                        }

                        if let onToggleBookmark {
                            Button {
                                onToggleBookmark()
                            } label: {
                                Label(
                                    meta.isBookmarked ? String(localized: "取消收藏") : String(localized: "收藏消息"),
                                    systemImage: meta.isBookmarked ? "bookmark.slash" : "bookmark"
                                )
                            }
                        }

                        if let onToggleExcludeFromContext {
                            Button {
                                onToggleExcludeFromContext()
                            } label: {
                                Label(
                                    meta.isExcludedFromContext ? String(localized: "恢复携带上下文") : String(localized: "移出上下文"),
                                    systemImage: meta.isExcludedFromContext ? "eye" : "eye.slash"
                                )
                            }
                        }

                        if let onForkConversation {
                            Button {
                                onForkConversation()
                            } label: {
                                Label("从此处分叉新对话", systemImage: "arrow.triangle.branch")
                            }
                        }

                        if let onDeleteMessage {
                            Divider()
                            Button(role: .destructive) {
                                onDeleteMessage()
                            } label: {
                                Label("删除此条消息", systemImage: "trash")
                            }
                        }
                    }
                }

                if !meta.groupReactions.isEmpty {
                    groupReactionsStrip(meta.groupReactions)
                }

                HStack(spacing: 10) {
                    if meta.isExcludedFromContext {
                        Text("已移出上下文")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if meta.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if branchSiblings.count > 1, let onSwitchBranch {
                        branchPager(
                            current: currentBranchIdx,
                            total: branchSiblings.count,
                            onPrev: {
                                if currentBranchIdx > 0 {
                                    onSwitchBranch(branchSiblings[currentBranchIdx - 1])
                                }
                            },
                            onNext: {
                                if currentBranchIdx + 1 < branchSiblings.count {
                                    onSwitchBranch(branchSiblings[currentBranchIdx + 1])
                                }
                            }
                        )
                    }

                    if let onQuote, !message.content.isEmpty {
                        Button {
                            onQuote(message.content)
                        } label: {
                            Image(systemName: "quote.opening")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("引用追问")
                    }

                    if onEditAndResend != nil && (!message.content.isEmpty || !attachments.isEmpty) {
                        Button {
                            editDraftText = message.content
                            showEditSheet = true
                        } label: {
                            Label("编辑重发", systemImage: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    if let onDeleteMessage {
                        Button(role: .destructive) {
                            onDeleteMessage()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除此条消息")
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .sheet(item: Binding(
            get: { previewImage.map { IdentifiableImage(image: $0) } },
            set: { if $0 == nil { previewImage = nil } }
        )) { wrapper in
            ImageFullScreenSheet(image: wrapper.image)
        }
        .sheet(isPresented: $showEditSheet) {
            NavigationStack {
                VStack(spacing: 12) {
                    TextEditor(text: $editDraftText)
                        .font(.body)
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .padding()

                    Text("保存后将生成新的对话分支并保留原有历史记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
                .navigationTitle("编辑提问并重发")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showEditSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        let canResend = !editDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
                        Button("重新发送") {
                            let updated = editDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !updated.isEmpty || !attachments.isEmpty else { return }
                            showEditSheet = false
                            onEditAndResend?(updated)
                        }
                        .fontWeight(.semibold)
                        .disabled(!canResend)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTextSelectionSheet) {
            TextSelectionSheet(text: message.content)
        }
    }

    @ViewBuilder
    private func groupReactionsStrip(_ reactions: [GroupReaction]) -> some View {
            HStack(spacing: 6) {
            ForEach(reactions) { item in
                HStack(spacing: 3) {
                    Text(item.emoji)
                        .font(.caption)
                    Text(item.memberName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "\(item.memberName) 回应了 \(item.emoji)"))
            }
        }
    }

    @ViewBuilder
    private func attachmentGrid(_ items: [MessageAttachment], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            let images = items.filter { $0.kind == .image }
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images) { att in
                        if let uiImg = att.cachedImage {
                            Button {
                                previewImage = uiImg
                            } label: {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 112, height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看图片 \(att.fileName)")
                        }
                    }
                }
            }

            ForEach(items.filter { $0.kind == .document }) { doc in
                HStack(spacing: 8) {
                    Image(systemName: doc.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.fileName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(doc.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Assistant Card

    private var assistantMessageView: some View {
        let meta = message.assistanceMetadataData != nil ? message.assistanceMetadata : AssistanceMetadata()
        let attachments = message.attachments
        let totalRevisions = meta.activeRevisionIndex == nil ? (meta.revisions.count + 1) : meta.revisions.count
        let currentRevision = meta.activeRevisionIndex ?? (totalRevisions - 1)
        let isSpeaking = speech.speakingMessageID == message.id
        let groupPersona = blindLabel == nil ? meta.groupSpeakerDisplayTitle : nil

        return VStack(alignment: .leading, spacing: groupPersona != nil ? 7 : 10) {
            if !isCompactCard {
                if let groupPersona {
                    HStack(spacing: 8) {
                        Button {
                            if let name = meta.groupMemberName, !name.isEmpty {
                                onMentionMember?("@\(name) ")
                            }
                        } label: {
                            HStack(spacing: 7) {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: message.accentHex).opacity(0.18))
                                        .frame(width: 28, height: 28)
                                    Text(meta.groupMemberEmoji ?? "🤖")
                                        .font(.footnote)
                                }

                                Text(groupPersona)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "点名 \(groupPersona)"))

                        if !message.modelDisplayName.isEmpty {
                            Text(message.modelDisplayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.11), in: Capsule())
                        }

                        if let intent = meta.groupSpeechIntent,
                           let badge = intent.badgeTitle {
                            HStack(spacing: 3) {
                                if let icon = intent.badgeIcon {
                                    Image(systemName: icon)
                                        .font(.system(size: 9, weight: .bold))
                                }
                                Text(badge)
                                    .font(.caption2.weight(.medium))
                            }
                            .foregroundStyle(Color(hex: message.accentHex))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: message.accentHex).opacity(0.12), in: Capsule())
                        }

                        if meta.isExcludedFromContext {
                            Text("已移出上下文")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if meta.isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if message.isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(blindLabel != nil ? Color.secondary : Color(hex: message.accentHex))
                            .frame(width: 9, height: 9)

                        Text(blindLabel ?? meta.bookReply?.byline ?? (message.modelDisplayName.isEmpty ? String(localized: "AI 助手") : message.modelDisplayName))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)

                        if blindLabel == nil, !message.providerName.isEmpty {
                            Text(message.providerName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }

                        if meta.isExcludedFromContext {
                            Text("已移出上下文")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }

                        Spacer()

                        if meta.isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if message.isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }
            }

            if message.assistanceMetadataData != nil {
                AssistanceEvidenceView(metadata: meta, message: message)
            }

            if !message.reasoningContent.isEmpty {
                ReasoningCardView(
                    reasoning: message.reasoningContent,
                    isActivelyThinking: message.isStreaming && message.content.isEmpty,
                    durationMs: message.thinkingDurationMs
                )
            }

            if !attachments.isEmpty {
                attachmentGrid(attachments, alignment: .leading)
            }

            if let book = meta.bookReply, blindLabel == nil {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(book.excerpts) { part in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: part.chapter).fontWeight(.semibold)
                                Text(verbatim: part.text).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                } label: {
                    Label("本次参考 · 《\(book.title)》", systemImage: "book")
                }.font(.caption).foregroundStyle(.secondary)
            }

            if let replyExcerpt = meta.groupReplyToExcerpt, !replyExcerpt.isEmpty {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: message.accentHex).opacity(0.65))
                        .frame(width: 2.5)
                    Text(
                        meta.groupReplyToSpeaker.map { String(localized: "回复 \($0)：\(replyExcerpt)") }
                            ?? replyExcerpt
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if !message.content.isEmpty {
                if groupPersona != nil && !isCompactCard {
                    MarkdownContentView(text: message.content, isStreaming: message.isStreaming)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .opacity(meta.isExcludedFromContext ? 0.65 : 1.0)
                } else {
                    MarkdownContentView(text: message.content, isStreaming: message.isStreaming)
                        .opacity(meta.isExcludedFromContext ? 0.65 : 1.0)
                }
            } else if message.isStreaming && message.reasoningContent.isEmpty && attachments.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(meta.requestedSearchQuery != nil && meta.search == nil
                         ? String(localized: "正在搜索网页…")
                         : (groupPersona != nil ? String(localized: "正在组织发言…") : String(localized: "正在连接模型生成回复…")))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if meta.groupAskedHost && !message.isStreaming {
                Label("向你抛出了问题，等你拍板回应", systemImage: "mic.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            if !meta.groupReactions.isEmpty {
                groupReactionsStrip(meta.groupReactions)
            }

            if !isCompactCard && (isGeneratingStudy || !meta.generatedFlashcards.isEmpty || meta.generatedQuiz != nil) {
                MessageStudyDeckView(
                    deckName: studyDeckName,
                    conversationID: conversationID,
                    messageID: message.id,
                    flashcards: meta.generatedFlashcards,
                    quiz: meta.generatedQuiz,
                    isGenerating: isGeneratingStudy,
                    onSelectQuizOption: onSelectQuizOption,
                    onFollowUpQuestion: onQuote
                )
            }

            if !message.isStreaming, !message.content.isEmpty, let reason = message.finishReasonValue {
                VStack(alignment: .leading, spacing: 8) {
                    Label(reason.userNotice, systemImage: reason == .length ? "scissors" : "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    if reason == .length, let onContinueGeneration {
                        Button {
                            onContinueGeneration()
                        } label: {
                            Label("继续生成", systemImage: "text.append")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let err = message.errorMessage, !err.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        if let onRegenerate {
                            Button("重试请求") {
                                onRegenerate()
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            if !message.isStreaming && (!message.content.isEmpty || !attachments.isEmpty || message.errorMessage != nil) {
                HStack(spacing: 11) {
                    if !message.content.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.content
                            preferences.triggerLightHaptic()
                            copiedToast = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                await MainActor.run { copiedToast = false }
                            }
                        } label: {
                            Label(copiedToast ? String(localized: "已复制") : String(localized: "复制"), systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(copiedToast ? .green : .secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            speech.toggleSpeaking(messageID: message.id, text: message.content, personaID: meta.groupMemberID)
                        } label: {
                            Image(systemName: isSpeaking ? "speaker.wave.2.circle.fill" : "speaker.wave.2")
                                .font(.caption)
                                .foregroundStyle(isSpeaking ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSpeaking ? String(localized: "停止朗读") : String(localized: "朗读回复"))
                    }

                    if let onRegenerate {
                        Menu {
                            Button {
                                onRegenerate()
                            } label: {
                                Label(
                                    blindLabel != nil
                                        ? String(localized: "使用原模型重答")
                                        : String(localized: "使用原模型重答 (\(message.modelDisplayName))"),
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            if let onRegenerateWithCurrentModel {
                                Button {
                                    onRegenerateWithCurrentModel()
                                } label: {
                                    Label("使用当前顶部所选模型重答", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                            if let onRegenerateWithOverride, groupPersona != nil, !availableCompareTargets.isEmpty {
                                let others = availableCompareTargets.filter {
                                    $0.modelID != message.modelID || $0.providerID != message.providerID
                                }
                                if !others.isEmpty {
                                    Menu("换用其他模型重答此条") {
                                        ForEach(others) { target in
                                            Button("\(target.providerName) · \(target.modelDisplayName)") {
                                                onRegenerateWithOverride(target)
                                            }
                                        }
                                    }
                                }
                            }
                            if !isCompactCard, let onCompareWithModel, !availableCompareTargets.isEmpty {
                                let others = availableCompareTargets.filter {
                                    $0.modelID != message.modelID || $0.providerID != message.providerID
                                }
                                if !others.isEmpty {
                                    Menu("与另一模型并排对比") {
                                        ForEach(others) { target in
                                            Button("\(target.providerName) · \(target.modelDisplayName)") {
                                                onCompareWithModel(target)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("重答", systemImage: "arrow.clockwise")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !isCompactCard, !message.content.isEmpty, !message.isStreaming, (onGenerateFlashcards != nil || onGenerateQuiz != nil || onExtractSchedule != nil) {
                        Menu {
                            if let onGenerateFlashcards {
                                Button {
                                    onGenerateFlashcards()
                                } label: {
                                    Label("生成记忆闪卡", systemImage: "rectangle.stack.badge.plus")
                                }
                            }
                            if let onGenerateQuiz {
                                Button {
                                    onGenerateQuiz()
                                } label: {
                                    Label("生成随堂测验", systemImage: "checklist")
                                }
                            }
                            if let onExtractSchedule {
                                Divider()
                                Button {
                                    onExtractSchedule()
                                } label: {
                                    Label("提取待办与日程", systemImage: "calendar.badge.plus")
                                }
                            }
                        } label: {
                            Label("助学", systemImage: "graduationcap")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(isGeneratingStudy)
                    }

                    if totalRevisions > 1, let onSelectRevision {
                        branchPager(
                            current: currentRevision,
                            total: totalRevisions,
                            onPrev: {
                                if currentRevision > 0 {
                                    onSelectRevision(currentRevision - 1)
                                }
                            },
                            onNext: {
                                if currentRevision + 1 < totalRevisions {
                                    onSelectRevision(currentRevision + 1)
                                }
                            }
                        )
                    }

                    let hasSecondaryActions = !message.content.isEmpty || onQuote != nil || onToggleBookmark != nil || onForkConversation != nil || onToggleExcludeFromContext != nil || onDeleteMessage != nil
                    if hasSecondaryActions {
                        Menu {
                            if !message.content.isEmpty {
                                Button {
                                    showTextSelectionSheet = true
                                } label: {
                                    Label("选择文本", systemImage: "selection.pin.in.out")
                                }
                            }
                            if let onQuote, !message.content.isEmpty {
                                Button {
                                    onQuote(message.content)
                                } label: {
                                    Label("引用追问", systemImage: "quote.opening")
                                }
                            }
                            if let onToggleBookmark {
                                Button {
                                    onToggleBookmark()
                                } label: {
                                    Label(
                                        meta.isBookmarked ? String(localized: "取消收藏") : String(localized: "收藏消息"),
                                        systemImage: meta.isBookmarked ? "bookmark.slash" : "bookmark"
                                    )
                                }
                            }
                            if let onForkConversation {
                                Button {
                                    onForkConversation()
                                } label: {
                                    Label("从此处分叉新对话", systemImage: "arrow.triangle.branch")
                                }
                            }
                            if let onToggleExcludeFromContext {
                                Button {
                                    onToggleExcludeFromContext()
                                } label: {
                                    Label(
                                        meta.isExcludedFromContext ? String(localized: "恢复携带上下文") : String(localized: "移出上下文"),
                                        systemImage: meta.isExcludedFromContext ? "eye" : "eye.slash"
                                    )
                                }
                            }
                            if let onDeleteMessage {
                                Divider()
                                Button(role: .destructive) {
                                    onDeleteMessage()
                                } label: {
                                    Label("删除此条消息", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("更多消息操作")
                    }

                    Spacer(minLength: 4)

                    metricsBadge
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: Binding(
            get: { previewImage.map { IdentifiableImage(image: $0) } },
            set: { if $0 == nil { previewImage = nil } }
        )) { wrapper in
            ImageFullScreenSheet(image: wrapper.image)
        }
        .sheet(isPresented: $showTextSelectionSheet) {
            TextSelectionSheet(text: message.content)
        }
    }

    @ViewBuilder
    private func branchPager(
        current: Int,
        total: Int,
        onPrev: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(current <= 0)

            Text("\(current + 1)/\(total)")
                .font(.caption2.monospacedDigit())

            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(current + 1 >= total)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    @ViewBuilder
    private var metricsBadge: some View {
        let hasExtra = (message.latestRequest?.firstOutputMs ?? 0) > 0 || (message.cachedTokens ?? 0) > 0
        Button {
            if hasExtra {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showExpandedMetrics.toggle()
                }
            }
        } label: {
            HStack(spacing: 6) {
                if showExpandedMetrics, let ttft = message.latestRequest?.firstOutputMs, ttft > 0 {
                    Text("首段 \(RequestLedger.seconds(ttft))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if let prompt = message.promptTokens, let comp = message.completionTokens {
                    Text("\(prompt + comp) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else if let comp = message.completionTokens {
                    Text("\(comp) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                if showExpandedMetrics, let cached = message.cachedTokens, cached > 0 {
                    Text("缓存 \(cached)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.green.opacity(0.85))
                } else if let cached = message.cachedTokens, cached > 0 {
                    Circle()
                        .fill(Color.green.opacity(0.75))
                        .frame(width: 5, height: 5)
                }

                if let ms = message.latencyMs, ms > 0 {
                    Text(String(format: "%.1fs", Double(ms) / 1000.0))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SelectableTextRepresentable: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.textColor = .label
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 20, right: 12)
        tv.text = text
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}

private struct TextSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextRepresentable(text: text)
                .navigationTitle("选择文本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("复制全文") {
                            UIPasteboard.general.string = text
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ImageFullScreenSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    let swiftUIImage = Image(uiImage: image)
                    ShareLink(item: swiftUIImage, preview: SharePreview(String(localized: "图片"), image: swiftUIImage)) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }
}
