import SwiftUI
import UIKit

struct MessageRowView: View {
    let message: ChatMessage
    var isCompactCard: Bool = false
    var branchSiblings: [ChatMessage] = []
    var availableCompareTargets: [ResolvedModelTarget] = []
    var actions: MessageRowActions = .init()
    var conversationID: UUID = UUID()
    /// Inline "edit & resend" controls are shown on the latest prompt only; older prompts keep them in the long-press menu.
    var showsPromptActions: Bool = true

    private var isReading: Bool { message.conversation?.readingVolumeID != nil }

    private struct WorkshopLaunch: Identifiable {
        let id = UUID()
        let mode: LabMode
        let text: String
    }
    private struct ClaimLaunch: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var workshop: WorkshopLaunch?
    @State private var editingImage: MessageAttachment?
    @State private var checkingClaim: ClaimLaunch?
    @State private var copiedToastText: String?
    @State private var copyToastToken = UUID()
    @State private var exportShareItem: ExportSharePayload?
    @State private var exportErrorMessage: String?
    @State private var previewImage: UIImage?
    @State private var showEditSheet = false
    @State private var showTextSelectionSheet = false
    @State private var pendingSelectedQuote: String?
    @State private var inlineSelection = ReplyTextSelection()
    @State private var showExpandedMetrics = false
    @State private var editDraftText = ""
    @State private var speech = SpeechService.shared
    @State private var preferences = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.usesPhoneWorkspace) private var usesPhoneWorkspace
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

    // MARK: - Feed Source Card

    private func sourceCard(_ notice: GroupSourceNotice) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(notice.byline, systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: notice.title)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
            if let excerpt = notice.excerpt, !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let date = notice.published {
                Text(date, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if (try? URLReader.validate(notice.url)) != nil {
                Link(destination: notice.url) {
                    Label("打开原文", systemImage: "arrow.up.right")
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(cornerRadius: DS.Radius.md, fill: DS.Surface.subtle, padding: DS.Spacing.md)
        .contextMenu {
            if let onDeleteMessage = actions.onDeleteMessage {
                Button("删除此条消息", role: .destructive, action: onDeleteMessage)
            }
        }
    }

    // MARK: - System Context Divider

    private var systemDividerView: some View {
        HStack(spacing: DS.Spacing.sm) {
            Rectangle()
                .fill(DS.Surface.hairline)
                .frame(height: 1)

            HStack(spacing: 5) {
                Image(systemName: "scissors")
                    .font(.caption2)
                Text(message.content.isEmpty ? String(localized: "已清除上文，以下开启新话题") : message.content)
                    .font(.caption2.weight(.medium))
                if let onDeleteMessage = actions.onDeleteMessage {
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
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(DS.Surface.subtle, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Surface.hairline, lineWidth: 1))

            Rectangle()
                .fill(DS.Surface.hairline)
                .frame(height: 1)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    // MARK: - User Prompt (Editorial Section Heading or Soft Micro-Bubble)

    private var userMessageView: some View {
        let attachments = message.attachments
        let meta = message.assistanceMetadata
        let currentBranchIdx = branchSiblings.firstIndex(where: { $0.id == message.id }) ?? 0
        let theme = preferences.accentTheme
        let useEditorial = preferences.chatMessageStyle == .editorial && !isCompactCard

        return Group {
            if useEditorial {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    if !attachments.isEmpty {
                        attachmentGrid(attachments, alignment: .leading)
                    }

                    if let quote = meta.quotedExcerpt, !quote.isEmpty {
                        quotedExcerptBox(quote, theme: theme)
                    }

                    HStack(alignment: .top, spacing: DS.Spacing.md) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(theme.solidFill.opacity(meta.isExcludedFromContext ? 0.45 : 1.0))
                            .frame(width: 2.5)
                            .padding(.vertical, 2)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            HStack(spacing: DS.Spacing.xs) {
                                Text("提问")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(theme.readableText)

                                if meta.isExcludedFromContext {
                                    Text("· 已移出上下文")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                if meta.isBookmarked {
                                    Image(systemName: "bookmark.fill")
                                        .font(.caption2)
                                        .foregroundStyle(DS.StatusText.warning)
                                }

                                Spacer(minLength: 4)

                                if branchSiblings.count > 1, let onSwitchBranch = actions.onSwitchBranch {
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
                            }

                            if !message.content.isEmpty {
                                Group {
                                    if message.content.contains("```") {
                                        MarkdownContentView(text: message.content, isStreaming: false)
                                            .opacity(meta.isExcludedFromContext ? 0.65 : 1.0)
                                    } else {
                                        Text(message.content)
                                            .font(DS.Typography.prose(
                                                size: baseBodySize * preferences.fontScale * 1.03,
                                                serif: preferences.literarySerifBody,
                                                weight: .semibold
                                            ))
                                            .foregroundStyle(.primary)
                                            .lineSpacing(4)
                                            .opacity(meta.isExcludedFromContext ? 0.65 : 1.0)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contextMenu { userMessageContextMenu(meta: meta) }
                            }
                        }
                    }

                    if !meta.groupReactions.isEmpty {
                        groupReactionsStrip(meta.groupReactions)
                    }

                    if showsPromptActions {
                        HStack(spacing: DS.Spacing.xs) {
                            Spacer(minLength: 0)
                            userActionButtons(meta: meta, attachments: attachments)
                        }
                    }
                }
            } else {
                HStack {
                    Spacer(minLength: 44)
                    VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                        if !attachments.isEmpty {
                            attachmentGrid(attachments, alignment: .trailing)
                        }

                        if let quote = meta.quotedExcerpt, !quote.isEmpty {
                            quotedExcerptBox(quote, theme: theme)
                        }

                        if !message.content.isEmpty {
                            Group {
                                if message.content.contains("```") {
                                    MarkdownContentView(text: message.content, isStreaming: false)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            DS.Surface.subtle,
                                            in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                                .strokeBorder(theme.tintColor.opacity(meta.isExcludedFromContext ? 0.16 : 0.30), lineWidth: 1)
                                        )
                                        .opacity(meta.isExcludedFromContext ? 0.65 : 1.0)
                                } else {
                                    Text(message.content)
                                        .font(.system(size: baseBodySize * preferences.fontScale))
                                        .foregroundStyle(.primary)
                                        .lineSpacing(3.5)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            theme.softFill.opacity(meta.isExcludedFromContext ? 0.55 : 1.0),
                                            in: UnevenRoundedRectangle(
                                                topLeadingRadius: DS.Radius.lg,
                                                bottomLeadingRadius: DS.Radius.lg,
                                                bottomTrailingRadius: DS.Radius.lg,
                                                topTrailingRadius: 6,
                                                style: .continuous
                                            )
                                        )
                                        .overlay(
                                            UnevenRoundedRectangle(
                                                topLeadingRadius: DS.Radius.lg,
                                                bottomLeadingRadius: DS.Radius.lg,
                                                bottomTrailingRadius: DS.Radius.lg,
                                                topTrailingRadius: 6,
                                                style: .continuous
                                            )
                                            .strokeBorder(theme.tintColor.opacity(meta.isExcludedFromContext ? 0.18 : 0.34), lineWidth: 1)
                                        )
                                }
                            }
                            .contextMenu { userMessageContextMenu(meta: meta) }
                        }

                        if !meta.groupReactions.isEmpty {
                            groupReactionsStrip(meta.groupReactions)
                        }

                        HStack(spacing: DS.Spacing.sm) {
                            if meta.isExcludedFromContext {
                                Text("已移出上下文")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if meta.isBookmarked {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2)
                                    .foregroundStyle(DS.StatusText.warning)
                            }

                            if branchSiblings.count > 1, let onSwitchBranch = actions.onSwitchBranch {
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

                            if showsPromptActions {
                                userActionButtons(meta: meta, attachments: attachments)
                            }
                        }
                        .padding(.trailing, DS.Spacing.xxs)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { previewImage.map { IdentifiableImage(image: $0) } },
            set: { if $0 == nil { previewImage = nil } }
        )) { wrapper in
            ImageFullScreenSheet(image: wrapper.image)
        }
        .sheet(item: $workshop) { item in NavigationStack { ModelWorkshop(mode: item.mode, initialAttachments: message.attachments, input: item.text) } }
        .sheet(isPresented: $showEditSheet) {
            NavigationStack {
                VStack(spacing: DS.Spacing.md) {
                    TextEditor(text: $editDraftText)
                        .font(.body)
                        .padding(DS.Spacing.sm)
                        .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                        .padding()

                    Text("保存后将生成新的对话分支并保留原有历史记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, DS.Spacing.md)
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
                            actions.onEditAndResend?(updated)
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

    private func quotedExcerptBox(_ quote: String, theme: DS.AccentTheme) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(theme.tintColor.opacity(0.75))
                .frame(width: 2.5)
            Text(quote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .strokeBorder(DS.Surface.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func userMessageContextMenu(meta: AssistanceMetadata) -> some View {
        Button("存入盲测题库") { workshop = .init(mode: .blind, text: message.content) }
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

        if let onQuote = actions.onQuote {
            Button {
                onQuote(message.content)
            } label: {
                Label("引用追问", systemImage: "quote.opening")
            }
        }

        if actions.onEditAndResend != nil {
            Button {
                editDraftText = message.content
                showEditSheet = true
            } label: {
                Label("编辑重发", systemImage: "pencil")
            }
        }

        if let onToggleBookmark = actions.onToggleBookmark {
            Button {
                onToggleBookmark()
            } label: {
                Label(
                    meta.isBookmarked ? String(localized: "取消收藏") : String(localized: "收藏消息"),
                    systemImage: meta.isBookmarked ? "bookmark.slash" : "bookmark"
                )
            }
        }

        if let onToggleExcludeFromContext = actions.onToggleExcludeFromContext {
            Button {
                onToggleExcludeFromContext()
            } label: {
                Label(
                    meta.isExcludedFromContext ? String(localized: "恢复携带上下文") : String(localized: "移出上下文"),
                    systemImage: meta.isExcludedFromContext ? "eye" : "eye.slash"
                )
            }
        }

        if let onForkConversation = actions.onForkConversation {
            Button {
                onForkConversation()
            } label: {
                Label("从此处分叉新对话", systemImage: "arrow.triangle.branch")
            }
        }

        if let onDeleteMessage = actions.onDeleteMessage {
            Divider()
            Button(role: .destructive) {
                onDeleteMessage()
            } label: {
                Label("删除此条消息", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func userActionButtons(meta: AssistanceMetadata, attachments: [MessageAttachment]) -> some View {
        if actions.onEditAndResend != nil && (!message.content.isEmpty || !attachments.isEmpty) {
            Button {
                editDraftText = message.content
                showEditSheet = true
            } label: {
                Label("编辑重发", systemImage: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: DS.TouchTarget.minimum + 2, minHeight: DS.TouchTarget.minimum + 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        if actions.onQuote != nil || actions.onDeleteMessage != nil {
            Menu {
                if let onQuote = actions.onQuote, !message.content.isEmpty {
                    Button {
                        onQuote(message.content)
                    } label: {
                        Label("引用追问", systemImage: "quote.opening")
                    }
                }
                if let onToggleBookmark = actions.onToggleBookmark {
                    Button {
                        onToggleBookmark()
                    } label: {
                        Label(
                            meta.isBookmarked ? String(localized: "取消收藏") : String(localized: "收藏消息"),
                            systemImage: meta.isBookmarked ? "bookmark.slash" : "bookmark"
                        )
                    }
                }
                if let onDeleteMessage = actions.onDeleteMessage {
                    Divider()
                    Button(role: .destructive) {
                        onDeleteMessage()
                    } label: {
                        Label("删除此条消息", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: DS.TouchTarget.minimum + 2, height: DS.TouchTarget.minimum + 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多消息操作")
        }
    }

    @ViewBuilder
    private func groupReactionsStrip(_ reactions: [GroupReaction]) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(reactions) { item in
                HStack(spacing: 3) {
                    Text(item.emoji)
                        .font(.caption)
                    Text(item.memberName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 3)
                .background(DS.Surface.subtle, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Surface.hairline, lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "\(item.memberName) 回应了 \(item.emoji)"))
            }
        }
    }

    @ViewBuilder
    private func attachmentGrid(_ items: [MessageAttachment], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: DS.Spacing.xs) {
            let images = items.filter { $0.kind == .image }
            if !images.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(images) { att in
                        if let uiImg = att.cachedImage {
                            Button {
                                previewImage = uiImg
                            } label: {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 112, height: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                            .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看图片 \(att.fileName)")
                            if message.role == .assistant {
                                Button("选区改图") { editingImage = att }.font(.caption)
                            }
                        }
                    }
                }
            }

            ForEach(items.filter { $0.kind == .document }) { doc in
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: doc.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill")
                        .foregroundStyle(preferences.accentTheme.readableText)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(doc.fileName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(doc.formattedSize)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                )
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
        let groupPersona = meta.groupSpeakerDisplayTitle
        let speaker = meta.speakerByline(privateProfile: message.conversation?.assistanceSettings.privatePersona,
                                         accentHex: message.accentHex)
        let references = actions.onOpenCitation != nil
            ? ReadingReferences(knowledge: meta.knowledgeEvidence, book: meta.bookReply, friend: message.conversation?.activeBookFriend,
                                limits: message.conversation?.readingChapterLimits ?? [:])
            : ReadingReferences()
        let claimSources: [ReadingCitation] = {
            if !references.sources.isEmpty { return references.sources }
            guard message.isSynthesis, let group = message.comparisonGroupID, let conversation = message.conversation else { return [] }
            var sources: [ReadingCitation] = []
            for candidate in ArenaSynthesis.eligibleSources(in: conversation.messages, groupID: group) {
                let info = candidate.assistanceMetadata
                let refs = ReadingReferences(knowledge: info.knowledgeEvidence, book: info.bookReply,
                                             friend: conversation.activeBookFriend, limits: conversation.readingChapterLimits)
                for source in refs.sources where !sources.contains(where: { $0.volumeID == source.volumeID && $0.excerpt == source.excerpt }) {
                    sources.append(source)
                }
            }
            return sources
        }()
        let bodyText = MarkdownContentView(text: message.content, isStreaming: message.isStreaming,
                                           references: references, onOpenCitation: actions.onOpenCitation,
                                           replySelection: replySelectionContext)

        return VStack(alignment: .leading, spacing: speaker != nil ? DS.Spacing.sm : 10) {
            if !isCompactCard {
                assistantHeader(meta: meta, speaker: speaker)
            }
            if speaker == nil, meta.isPersonaSimulation, meta.bookReply == nil {
                Label("AI 模拟", systemImage: "person.crop.circle").font(.footnote)
            }

            if speaker == nil, message.assistanceMetadataData != nil {
                AssistanceEvidenceView(metadata: meta, message: message, showsKnowledge: actions.onOpenCitation == nil)
            }

            if speaker == nil || (message.isStreaming && message.content.isEmpty) {
                reasoningCard
            }

            if !attachments.isEmpty {
                attachmentGrid(attachments, alignment: .leading)
            }

            if let replyExcerpt = meta.groupReplyToExcerpt, !replyExcerpt.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
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
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 5)
                .background(DS.Surface.neutralChipFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }

            if !message.content.isEmpty {
                if ((isReading && !usesPhoneWorkspace) || speaker != nil) && !isCompactCard {
                    bodyText
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                        )
                        .opacity(meta.isExcludedFromContext ? 0.65 : 1.0)
                } else {
                    bodyText
                        .opacity(meta.isExcludedFromContext ? 0.65 : 1.0)
                }
            } else if message.isStreaming && message.reasoningContent.isEmpty && attachments.isEmpty {
                let loadingLabel: String = {
                    if meta.requestedSearchQuery != nil && meta.search == nil {
                        return String(localized: "正在搜索网页…")
                    }
                    return groupPersona != nil ? String(localized: "正在组织发言…") : String(localized: "正在连接模型生成回复…")
                }()
                HStack(spacing: DS.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loadingLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.Spacing.xxs)
            }

            // When every retrieved passage is already linked inline, the list would only repeat the footnotes.
            if let open = actions.onOpenCitation, !references.sources.isEmpty,
               message.isStreaming || !references.citesAllSources(in: message.content) {
                DisclosureGroup {
                    ForEach(Array(references.sources.enumerated()), id: \.offset) { _, source in
                        ReadingCitationButton(citation: source, open: open)
                    }
                } label: {
                    Label("找到 \(references.sources.count) 段相关原文", systemImage: "books.vertical")
                        .foregroundStyle(DS.Surface.inkSecondary)
                }
                .font(.subheadline)
                .tint(DS.Surface.inkSecondary)
            }

            if speaker != nil {
                if message.assistanceMetadataData != nil {
                    AssistanceEvidenceView(metadata: meta, message: message, showsKnowledge: actions.onOpenCitation == nil)
                }
                DisclosureGroup("回复详情") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: [message.providerName, message.modelDisplayName].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                        if !(message.isStreaming && message.content.isEmpty) { reasoningCard }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline)
            }

            if let samples = meta.personaExcerpts, !samples.isEmpty {
                DisclosureGroup("本次参考的人物资料") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                            Text(verbatim: sample.source).font(.footnote.bold())
                            Text(verbatim: sample.excerpt).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
            if let book = meta.bookReply, actions.onOpenCitation == nil || message.conversation?.activeBookFriend == nil {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(book.excerpts) { part in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: part.chapter).fontWeight(.semibold)
                                Text(verbatim: part.text).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Spacing.xxs)
                } label: {
                    Label("本次参考 · 《\(book.title)》", systemImage: "book")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if meta.groupAskedHost && !message.isStreaming {
                DSBadge(
                    text: String(localized: "向你抛出了问题，等你拍板回应"),
                    icon: "mic.fill",
                    style: .accent(preferences.accentTheme)
                )
            }

            if !meta.groupReactions.isEmpty {
                groupReactionsStrip(meta.groupReactions)
            }

            if !message.isStreaming, !message.content.isEmpty, let reason = message.finishReasonValue {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label(reason.userNotice, systemImage: reason == .length ? "scissors" : "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(DS.StatusText.warning)

                    if reason == .length, let onContinueGeneration = actions.onContinueGeneration {
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
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }

            if let err = message.errorMessage, !err.isEmpty {
                let canContinueFromInterruption = !message.content.isEmpty && actions.onContinueGeneration != nil
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.StatusText.warning)
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        if canContinueFromInterruption {
                            Text("已保留已生成内容，可从断点续写或重新请求。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: DS.Spacing.sm) {
                            if canContinueFromInterruption, let onContinueGeneration = actions.onContinueGeneration {
                                Button {
                                    onContinueGeneration()
                                } label: {
                                    Label("从断句处继续", systemImage: "text.append")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                            }
                            if let onRegenerate = actions.onRegenerate {
                                if canContinueFromInterruption {
                                    Button("重试请求") {
                                        onRegenerate()
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                } else {
                                    Button("重试请求") {
                                        onRegenerate()
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.mini)
                                }
                            }
                        }
                    }
                }
                .padding(DS.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }

            if !message.isStreaming && (!message.content.isEmpty || !attachments.isEmpty || message.errorMessage != nil) {
                assistantFooter(
                    meta: meta,
                    totalRevisions: totalRevisions,
                    currentRevision: currentRevision,
                    isSpeaking: isSpeaking,
                    groupPersona: groupPersona,
                    canCheckClaim: !message.content.isEmpty
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: Binding(
            get: { previewImage.map { IdentifiableImage(image: $0) } },
            set: { if $0 == nil { previewImage = nil } }
        )) { wrapper in
            ImageFullScreenSheet(image: wrapper.image)
        }
        .sheet(isPresented: $showTextSelectionSheet, onDismiss: {
            if let quote = pendingSelectedQuote {
                pendingSelectedQuote = nil
                actions.onQuote?(quote)
            }
        }) {
            TextSelectionSheet(text: message.content, onQuote: prioritizesFollowUp && actions.onQuote != nil ? { pendingSelectedQuote = $0 } : nil)
        }
        .sheet(item: $workshop) { item in NavigationStack { ModelWorkshop(mode: item.mode, initialAttachments: message.attachments, input: item.text) } }
        .sheet(item: $editingImage) { item in NavigationStack { RegionImageEditor(message: message, attachmentID: item.id) } }
        .sheet(item: $checkingClaim) { item in
            ClaimCheckSheet(sources: claimSources, open: actions.onOpenCitation, allowedBook: message.conversation?.activeBookFriend?.bookID, chapterLimits: message.conversation?.readingChapterLimits ?? [:], claim: item.text)
        }
        .sheet(item: $exportShareItem) { payload in
            ReplyActivityShareSheet(items: [payload.url])
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private func triggerCopiedToast(_ label: String) {
        let token = UUID()
        copyToastToken = token
        copiedToastText = label
        preferences.triggerLightHaptic()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                if copyToastToken == token {
                    copiedToastText = nil
                }
            }
        }
    }

    private func exportSinglePDF(speaker: String) {
        let title = message.conversation?.title ?? speaker
        do {
            let url = try MessageExportRenderer.writePDFFile(
                title: title,
                speaker: speaker,
                date: message.createdAt,
                markdown: message.content
            )
            exportShareItem = ExportSharePayload(url: url)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func exportSingleShareCard(speaker: String) {
        let title = message.conversation?.title ?? speaker
        do {
            if let url = try MessageExportRenderer.writeShareCardFile(
                title: title,
                speaker: speaker,
                date: message.createdAt,
                markdown: message.content,
                accentHex: message.accentHex,
                colorScheme: colorScheme
            ) {
                exportShareItem = ExportSharePayload(url: url)
            } else {
                exportErrorMessage = String(localized: "当前消息暂无可导出的文本内容。")
            }
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var reasoningCard: some View {
        if !message.reasoningContent.isEmpty {
            ReasoningCardView(reasoning: message.reasoningContent,
                              isActivelyThinking: message.isStreaming && message.content.isEmpty,
                              durationMs: message.thinkingDurationMs)
        }
    }

    @ViewBuilder
    private func assistantHeader(meta: AssistanceMetadata, speaker: PersonaByline?) -> some View {
        if let speaker {
            let identity = HStack(spacing: DS.Spacing.sm) {
                PersonaAvatar(identity: speaker)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: speaker.label).font(.subheadline.weight(.semibold))
                    if meta.isPersonaSimulation {
                        Text("AI 模拟").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: DS.Spacing.sm) {
                if let mention = actions.onMentionMember, let memberID = meta.groupMemberID, let name = meta.groupMemberName {
                    Button { mention(memberID) } label: { identity }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "点名 \(meta.groupSpeakerDisplayTitle ?? name)"))
                } else {
                    identity.accessibilityElement(children: .combine)
                }

                if let intent = meta.groupSpeechIntent,
                   let badge = intent.badgeTitle {
                    DSBadge(text: badge, icon: intent.badgeIcon, style: .tinted(Color(hex: message.accentHex)))
                }

                if meta.isExcludedFromContext {
                    DSBadge(text: String(localized: "已移出上下文"), style: .neutral)
                }

                Spacer()

                if meta.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(DS.StatusText.warning)
                }

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        } else {
            HStack(spacing: DS.Spacing.xs) {
                // A model color only helps tell speakers apart in comparisons and group chats.
                let distinguishesModels = message.conversation?.isArenaMode == true || message.conversation?.isGroupMode == true
                Circle()
                    .fill(distinguishesModels ? Color(hex: message.accentHex) : DS.Surface.inkSecondary.opacity(0.55))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(meta.bookReply?.byline ?? (message.modelDisplayName.isEmpty ? String(localized: "AI 助手") : message.modelDisplayName))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)

                if !message.providerName.isEmpty {
                    Text("· \(message.providerName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if meta.isExcludedFromContext {
                    DSBadge(text: String(localized: "已移出上下文"), style: .neutral)
                }

                Spacer()

                if meta.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(DS.StatusText.warning)
                }

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private func assistantFooter(
        meta: AssistanceMetadata,
        totalRevisions: Int,
        currentRevision: Int,
        isSpeaking: Bool,
        groupPersona: String?, canCheckClaim: Bool
    ) -> some View {
        let exportSpeaker = meta.groupSpeakerDisplayTitle
            ?? (message.modelDisplayName.isEmpty ? String(localized: "AI 助手") : message.modelDisplayName)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !message.content.isEmpty {
                    Button {
                        UIPasteboard.general.string = PlainTextFormatter.format(message.content)
                        triggerCopiedToast(String(localized: "已复制纯文本"))
                    } label: {
                        replyActionLabel(copiedToastText == nil ? "复制" : "已复制",
                                         icon: copiedToastText == nil ? "doc.on.doc" : "checkmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制纯文本")
                    .accessibilityIdentifier("reply.copy")
                }

                if prioritizesFollowUp, let quote = actions.onQuote, !message.content.isEmpty {
                    Button { quote(inlineSelection.text ?? message.content) } label: {
                        replyActionLabel("追问", icon: "quote.opening")
                            .foregroundStyle(preferences.accentTheme.readableText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("引用追问")
                    .accessibilityIdentifier("reply.followUp")
                    .contextMenu {
                        Button("选择文本") { showTextSelectionSheet = true }
                    }
                }
                if !prioritizesFollowUp, let retry = actions.onRegenerate {
                    regenerateMenu(retry, groupPersona: groupPersona)
                }

                let hasSecondaryActions = !message.content.isEmpty || actions.onQuote != nil || actions.onToggleBookmark != nil || actions.onForkConversation != nil || actions.onToggleExcludeFromContext != nil || actions.onDeleteMessage != nil
                if hasSecondaryActions || (prioritizesFollowUp && actions.onRegenerate != nil) {
                    Menu {
                        if canCheckClaim {
                            Button("逐条核对出处") { checkingClaim = .init(text: inlineSelection.text ?? message.content) }
                        }
                        Button("在本机处理选文") { workshop = .init(mode: .local, text: inlineSelection.text ?? message.content) }
                        // Frequent, non-destructive actions sit in one compact row at the top of the menu.
                        if !message.content.isEmpty || actions.onToggleBookmark != nil {
                            ControlGroup {
                                if !message.content.isEmpty {
                                    Button {
                                        if let onToggleSpeak = actions.onToggleSpeak {
                                            onToggleSpeak()
                                        } else {
                                            speech.toggleSpeaking(messageID: message.id, text: message.content, personaID: meta.groupMemberID)
                                        }
                                    } label: {
                                        Label(isSpeaking ? String(localized: "停止朗读") : String(localized: "朗读回复"),
                                              systemImage: isSpeaking ? "stop.fill" : "speaker.wave.2")
                                    }
                                }
                                if let onToggleBookmark = actions.onToggleBookmark {
                                    Button {
                                        onToggleBookmark()
                                    } label: {
                                        Label(
                                            meta.isBookmarked ? String(localized: "取消收藏") : String(localized: "收藏消息"),
                                            systemImage: meta.isBookmarked ? "bookmark.slash" : "bookmark"
                                        )
                                    }
                                }
                                if !message.content.isEmpty {
                                    Button {
                                        showTextSelectionSheet = true
                                    } label: {
                                        Label("选择文本", systemImage: "selection.pin.in.out")
                                    }
                                }
                            }
                            .controlGroupStyle(.compactMenu)
                        }

                        Section {
                            if prioritizesFollowUp, let retry = actions.onRegenerate {
                                regenerateMenu(retry, groupPersona: groupPersona)
                            }
                            if !message.content.isEmpty, !message.isStreaming, let onContinueGeneration = actions.onContinueGeneration {
                                Button {
                                    onContinueGeneration()
                                } label: {
                                    Label("从末尾继续生成", systemImage: "text.append")
                                }
                            }
                            if !prioritizesFollowUp, let onQuote = actions.onQuote, !message.content.isEmpty {
                                Button {
                                    onQuote(message.content)
                                } label: {
                                    Label("引用追问", systemImage: "quote.opening")
                                }
                            }
                        }

                        if !message.content.isEmpty {
                            Section {
                                Button {
                                    UIPasteboard.general.string = message.content
                                    triggerCopiedToast(String(localized: "已复制 Markdown"))
                                } label: {
                                    Label("复制 Markdown 原文", systemImage: "doc.on.doc")
                                }
                                if !isCompactCard {
                                    Menu {
                                        Button {
                                            exportSinglePDF(speaker: exportSpeaker)
                                        } label: {
                                            Label("导出 PDF 文档", systemImage: "doc.richtext")
                                        }
                                        Button {
                                            exportSingleShareCard(speaker: exportSpeaker)
                                        } label: {
                                            Label("导出分享长图", systemImage: "photo")
                                        }
                                    } label: {
                                        Label("导出此回复", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                        }

                        Section {
                            if let onForkConversation = actions.onForkConversation {
                                Button {
                                    onForkConversation()
                                } label: {
                                    Label("从此处分叉新对话", systemImage: "arrow.triangle.branch")
                                }
                            }
                            if let onToggleExcludeFromContext = actions.onToggleExcludeFromContext {
                                Button {
                                    onToggleExcludeFromContext()
                                } label: {
                                    Label(
                                        meta.isExcludedFromContext ? String(localized: "恢复携带上下文") : String(localized: "移出上下文"),
                                        systemImage: meta.isExcludedFromContext ? "eye" : "eye.slash"
                                    )
                                }
                            }
                        }

                        if let onDeleteMessage = actions.onDeleteMessage {
                            Section {
                                Button(role: .destructive) {
                                    onDeleteMessage()
                                } label: {
                                    Label("删除此条消息", systemImage: "trash")
                                }
                            }
                        }
                    } label: {
                        replyActionLabel("更多", icon: "ellipsis")
                    }
                    .accessibilityLabel("更多消息操作")
                    .accessibilityIdentifier("reply.more")
                }
            }
            .foregroundStyle(.secondary)

            if totalRevisions > 1 || message.completionTokens != nil || (message.latencyMs ?? 0) > 0
                || (message.latestRequest?.firstOutputMs ?? 0) > 0 || (message.cachedTokens ?? 0) > 0 {
                HStack {
                    if totalRevisions > 1, let onSelectRevision = actions.onSelectRevision {
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
                    Spacer(minLength: 4)
                    metricsBadge
                }
            }
        }
        .padding(.top, 2)
    }

    private var prioritizesFollowUp: Bool {
        usesPhoneWorkspace && !isCompactCard && message.conversation?.isArenaMode != true && message.conversation?.isGroupMode != true
    }

    private var replySelectionContext: ReplySelectionContext? {
        guard prioritizesFollowUp, !message.isStreaming, let quote = actions.onQuote else { return nil }
        return ReplySelectionContext(selection: inlineSelection, quote: quote)
    }

    private func regenerateMenu(_ onRegenerate: @escaping () -> Void, groupPersona: String?) -> some View {
        Menu {
            Button {
                onRegenerate()
            } label: {
                Label(
                    String(localized: "使用原模型重答 (\(message.modelDisplayName))"),
                    systemImage: "arrow.clockwise"
                )
            }
            if let onRegenerateWithCurrentModel = actions.onRegenerateWithCurrentModel {
                Button {
                    onRegenerateWithCurrentModel()
                } label: {
                    Label("使用当前所选模型重答", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let onRegenerateWithOverride = actions.onRegenerateWithOverride, groupPersona != nil, !availableCompareTargets.isEmpty {
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
            if !isCompactCard, let onCompareWithModel = actions.onCompareWithModel, !availableCompareTargets.isEmpty {
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
            if prioritizesFollowUp {
                Label("重答", systemImage: "arrow.clockwise")
            } else {
                replyActionLabel("重答", icon: "arrow.clockwise")
            }
        }
        .accessibilityIdentifier("reply.regenerate")
    }

    private func replyActionLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: icon).fixedSize()
            Text(title).fixedSize()
            Image(systemName: icon).accessibilityLabel(Text(title))
        }
        .font(.footnote.weight(.medium))
        .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
        .contentShape(Rectangle())
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
        .background(DS.Surface.neutralChipFill, in: Capsule())
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
            HStack(spacing: 5) {
                if showExpandedMetrics, let ttft = message.latestRequest?.firstOutputMs, ttft > 0 {
                    Text("首段 \(RequestLedger.seconds(ttft))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let prompt = message.promptTokens, let comp = message.completionTokens {
                    Text("\(prompt + comp) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if let comp = message.completionTokens {
                    Text("\(comp) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if showExpandedMetrics, let cached = message.cachedTokens, cached > 0 {
                    Text("缓存 \(cached)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.StatusText.success)
                } else if let cached = message.cachedTokens, cached > 0 {
                    Circle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: 5, height: 5)
                }

                if let ms = message.latencyMs, ms > 0 {
                    Text(String(format: "%.1fs", Double(ms) / 1000.0))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct SelectableTextRepresentable: UIViewRepresentable {
    let text: String
    @Binding var selection: String?
    var selectedRange: Binding<NSRange?>? = nil
    var identifier = "reply.selectText"

    final class Coordinator: NSObject, UITextViewDelegate {
        let selection: Binding<String?>
        var selectedRange: Binding<NSRange?>?
        init(_ selection: Binding<String?>, _ selectedRange: Binding<NSRange?>?) {
            self.selection = selection
            self.selectedRange = selectedRange
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            selection.wrappedValue = textView.selectedTextRange.flatMap { $0.isEmpty ? nil : textView.text(in: $0) }
            selectedRange?.wrappedValue = textView.selectedRange.length > 0 ? textView.selectedRange : nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator($selection, selectedRange) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.accessibilityIdentifier = identifier
        tv.adjustsFontForContentSizeCategory = true
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
    var onQuote: ((String) -> Void)? = nil
    @State private var selection: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextRepresentable(text: text, selection: $selection)
                .navigationTitle("选择文本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button("复制原文") {
                            UIPasteboard.general.string = text
                            dismiss()
                        }
                        Button("复制纯文本") {
                            UIPasteboard.general.string = PlainTextFormatter.format(text)
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                    if let onQuote {
                        ToolbarItem(placement: .bottomBar) {
                            Button("引用选中文字追问") {
                                guard let selection, !selection.isEmpty else { return }
                                onQuote(selection)
                                dismiss()
                            }
                            .disabled(selection?.isEmpty != false)
                            .accessibilityIdentifier("reply.quoteSelection")
                        }
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

struct ExportSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ReplyActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
