import SwiftUI
import UIKit

struct MessageRowView: View {
    let message: ChatMessage
    var isCompactCard: Bool = false
    var blindLabel: String? = nil
    var branchSiblings: [ChatMessage] = []
    var availableCompareTargets: [ResolvedModelTarget] = []
    var actions: MessageRowActions = .init()
    var studyDeckName: String = ""
    var conversationID: UUID = UUID()
    var isGeneratingStudy: Bool = false

    private var isReading: Bool { message.conversation?.readingVolumeID != nil }

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

    // MARK: - User Bubble

    private var userMessageView: some View {
        let attachments = message.attachments
        let meta = message.assistanceMetadata
        let currentBranchIdx = branchSiblings.firstIndex(where: { $0.id == message.id }) ?? 0
        let theme = preferences.accentTheme

        return HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                if !attachments.isEmpty {
                    attachmentGrid(attachments, alignment: .trailing)
                }

                if let quote = meta.quotedExcerpt, !quote.isEmpty {
                    HStack(spacing: DS.Spacing.xs) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(theme.tintColor.opacity(0.7))
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
                                .foregroundStyle(isReading ? Color.primary : theme.solidForeground)
                                .lineSpacing(3)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    (isReading ? theme.softFill : theme.solidFill).opacity(meta.isExcludedFromContext ? 0.55 : 1.0),
                                    in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
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
                            .foregroundStyle(.orange)
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

                    if actions.onEditAndResend != nil && (!message.content.isEmpty || !attachments.isEmpty) {
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
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                        }
                        .accessibilityLabel("更多消息操作")
                    }
                }
                .padding(.trailing, DS.Spacing.xxs)
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
        let groupPersona = blindLabel == nil ? meta.groupSpeakerDisplayTitle : nil
        let speaker = blindLabel == nil ? meta.speakerByline(privateProfile: message.conversation?.assistanceSettings.privatePersona,
                                                            accentHex: message.accentHex) : nil
        let references = blindLabel == nil && actions.onOpenCitation != nil
            ? ReadingReferences(knowledge: meta.knowledgeEvidence, book: meta.bookReply, friend: message.conversation?.activeBookFriend,
                                limits: message.conversation?.readingChapterLimits ?? [:])
            : ReadingReferences()
        let bodyText = MarkdownContentView(text: message.content, isStreaming: message.isStreaming,
                                           references: references, onOpenCitation: blindLabel == nil ? actions.onOpenCitation : nil)

        return VStack(alignment: .leading, spacing: speaker != nil ? DS.Spacing.sm : 10) {
            if !isCompactCard {
                assistantHeader(meta: meta, speaker: speaker)
            }
            if blindLabel == nil, speaker == nil, meta.isPersonaSimulation, meta.bookReply == nil {
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
                if (isReading || speaker != nil) && !isCompactCard {
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
                HStack(spacing: DS.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(meta.requestedSearchQuery != nil && meta.search == nil
                         ? String(localized: "正在搜索网页…")
                         : (groupPersona != nil ? String(localized: "正在组织发言…") : String(localized: "正在连接模型生成回复…")))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.Spacing.xxs)
            }

            if let open = actions.onOpenCitation, !references.sources.isEmpty {
                DisclosureGroup {
                    ForEach(Array(references.sources.enumerated()), id: \.offset) { _, source in
                        ReadingCitationButton(citation: source, open: open)
                    }
                } label: {
                    Label("找到 \(references.sources.count) 段相关原文", systemImage: "books.vertical")
                }
                .font(.subheadline)
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

            if blindLabel == nil, let samples = meta.personaExcerpts, !samples.isEmpty {
                DisclosureGroup("本次参考的人物资料") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                            Text(verbatim: sample.source).font(.footnote.bold())
                            Text(verbatim: sample.excerpt).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
            if let book = meta.bookReply, blindLabel == nil, actions.onOpenCitation == nil || message.conversation?.activeBookFriend == nil {
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

            if !isCompactCard && (isGeneratingStudy || !meta.generatedFlashcards.isEmpty || meta.generatedQuiz != nil) {
                MessageStudyDeckView(
                    deckName: studyDeckName,
                    conversationID: conversationID,
                    messageID: message.id,
                    flashcards: meta.generatedFlashcards,
                    quiz: meta.generatedQuiz,
                    isGenerating: isGeneratingStudy,
                    onSelectQuizOption: actions.onSelectQuizOption,
                    onFollowUpQuestion: actions.onQuote
                )
            }

            if !message.isStreaming, !message.content.isEmpty, let reason = message.finishReasonValue {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label(reason.userNotice, systemImage: reason == .length ? "scissors" : "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.orange)

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
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        if let onRegenerate = actions.onRegenerate {
                            Button("重试请求") {
                                onRegenerate()
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
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
                    groupPersona: groupPersona
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
        .sheet(isPresented: $showTextSelectionSheet) {
            TextSelectionSheet(text: message.content)
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
                        .foregroundStyle(.orange)
                }

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        } else {
            HStack(spacing: DS.Spacing.xs) {
                Circle()
                    .fill(blindLabel != nil ? Color.secondary : Color(hex: message.accentHex))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(blindLabel ?? meta.bookReply?.byline ?? (message.modelDisplayName.isEmpty ? String(localized: "AI 助手") : message.modelDisplayName))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)

                if blindLabel == nil, !message.providerName.isEmpty {
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
                        .foregroundStyle(.orange)
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
        groupPersona: String?
    ) -> some View {
        HStack(spacing: 14) {
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
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(copiedToast ? .green : .secondary)
                }
                .buttonStyle(.plain)

                if isSpeaking {
                    Button {
                        if let onToggleSpeak = actions.onToggleSpeak {
                            onToggleSpeak()
                        } else {
                            speech.toggleSpeaking(messageID: message.id, text: message.content, personaID: meta.groupMemberID)
                        }
                    } label: {
                        Label(
                            speech.isSynthesizingCloudSpeech ? String(localized: "合成语音中…") : String(localized: "停止朗读"),
                            systemImage: "speaker.wave.2.circle.fill"
                        )
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(preferences.accentTheme.readableText)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let onRegenerate = actions.onRegenerate {
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
                    if let onRegenerateWithCurrentModel = actions.onRegenerateWithCurrentModel {
                        Button {
                            onRegenerateWithCurrentModel()
                        } label: {
                            Label("使用当前顶部所选模型重答", systemImage: "arrow.triangle.2.circlepath")
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
                    Label("重答", systemImage: "arrow.clockwise")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

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

            let canStudy = !isCompactCard && !message.content.isEmpty && !message.isStreaming && (actions.onGenerateFlashcards != nil || actions.onGenerateQuiz != nil || actions.onExtractSchedule != nil)
            let hasSecondaryActions = !message.content.isEmpty || canStudy || actions.onQuote != nil || actions.onToggleBookmark != nil || actions.onForkConversation != nil || actions.onToggleExcludeFromContext != nil || actions.onDeleteMessage != nil
            if hasSecondaryActions {
                Menu {
                    if !message.content.isEmpty {
                        Button {
                            UIPasteboard.general.string = PlainTextFormatter.format(message.content)
                            preferences.triggerLightHaptic()
                            copiedToast = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                await MainActor.run { copiedToast = false }
                            }
                        } label: {
                            Label("复制纯文本（去格式）", systemImage: "doc.plaintext")
                        }

                        Button {
                            if let onToggleSpeak = actions.onToggleSpeak {
                                onToggleSpeak()
                            } else {
                                speech.toggleSpeaking(messageID: message.id, text: message.content, personaID: meta.groupMemberID)
                            }
                        } label: {
                            Label(
                                isSpeaking ? String(localized: "停止朗读") : String(localized: "朗读回复"),
                                systemImage: isSpeaking ? "speaker.slash" : "speaker.wave.2"
                            )
                        }
                    }

                    if canStudy {
                        Menu {
                            if let onGenerateFlashcards = actions.onGenerateFlashcards {
                                Button {
                                    onGenerateFlashcards()
                                } label: {
                                    Label("生成记忆闪卡", systemImage: "rectangle.stack.badge.plus")
                                }
                            }
                            if let onGenerateQuiz = actions.onGenerateQuiz {
                                Button {
                                    onGenerateQuiz()
                                } label: {
                                    Label("生成随堂测验", systemImage: "checklist")
                                }
                            }
                            if let onExtractSchedule = actions.onExtractSchedule {
                                Divider()
                                Button {
                                    onExtractSchedule()
                                } label: {
                                    Label("提取待办与日程", systemImage: "calendar.badge.plus")
                                }
                            }
                        } label: {
                            Label("助学", systemImage: "graduationcap")
                        }
                        .disabled(isGeneratingStudy)
                    }

                    if !message.content.isEmpty {
                        Divider()
                        Button {
                            showTextSelectionSheet = true
                        } label: {
                            Label("选择文本", systemImage: "selection.pin.in.out")
                        }
                    }

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
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .accessibilityLabel("更多消息操作")
            }

            Spacer(minLength: 4)

            metricsBadge
        }
        .padding(.top, 2)
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
                        .foregroundStyle(.green)
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
