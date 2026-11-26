import Foundation
import SwiftUI
import UIKit

enum ConversationExporter {
    struct Options {
        var messageIDs: Set<UUID>?
        var includesReasoning = false
        var includesSystemPrompt = false
        var includesReferences = false

        // Keep the full transcript contract used by multi-conversation archives.
        static let archive = Options(includesReasoning: true, includesSystemPrompt: true, includesReferences: true)
    }

    static func messages(in conversation: Conversation, selectedIDs: Set<UUID>?) -> [ChatMessage] {
        let active = ConversationTree.activeMessages(in: conversation)
        return selectedIDs.map { ids in active.filter { ids.contains($0.id) } } ?? active
    }

    static func makeMarkdown(for conversation: Conversation, options: Options = .archive, forPDF: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        if !forPDF { lines.append("# \(conversation.title)") }
        lines.append("")
        lines.append("- \(String(localized: "更新时间：\(formatter.string(from: conversation.updatedAt))"))")
        if let target = conversation.primaryTarget, !conversation.isArenaMode {
            lines.append("- \(String(localized: "模型：\(target.providerName) · \(target.modelDisplayName)"))")
        }
        if options.includesSystemPrompt, !conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## \(String(localized: "系统提示词"))")
            lines.append("")
            lines.append("> \(conversation.systemPrompt.replacingOccurrences(of: "\n", with: "\n> "))")
        }
        lines.append("")
        lines.append("---")

        for msg in messages(in: conversation, selectedIDs: options.messageIDs) {
            if msg.assistanceMetadata.isContextDivider {
                lines.append("")
                lines.append("--- *\(msg.content)* ---")
                continue
            }

            lines.append("")
            if let notice = msg.assistanceMetadata.sourceNotice {
                lines.append("### \(notice.byline)")
                lines.append("")
                lines.append(notice.body)
                continue
            }
            switch msg.role {
            case .user:
                lines.append("### \(String(localized: "提问"))")
                if options.includesReferences, let quote = msg.assistanceMetadata.quotedExcerpt, !quote.isEmpty {
                    lines.append("")
                    lines.append("> \(quote.replacingOccurrences(of: "\n", with: "\n> "))")
                }
                if !msg.attachments.isEmpty {
                    let names = msg.attachments.map(\.fileName).joined(separator: ", ")
                    lines.append("")
                    lines.append("*\(String(localized: "附件：\(names)"))*")
                }
                if !msg.content.isEmpty {
                    lines.append("")
                    lines.append(msg.content)
                }
                let userReactions = msg.assistanceMetadata.groupReactions
                if !userReactions.isEmpty {
                    let summary = userReactions.map { "\($0.emoji) \($0.memberName)" }.joined(separator: " · ")
                    lines.append("")
                    lines.append("*\(summary)*")
                }

            case .assistant:
                let meta = msg.assistanceMetadata
                let speaker = ArenaSynthesis.visibleSpeakerName(for: msg)
                let title: String
                if msg.isSynthesis || speaker != msg.modelDisplayName || msg.providerName.isEmpty {
                    title = speaker
                } else {
                    title = "\(speaker) (\(msg.providerName))"
                }
                let marker = msg.comparisonGroupID != nil && msg.isSelectedInGroup
                    ? " [\(String(localized: "上下文主回复"))]"
                    : ""
                lines.append("### \(title)\(marker)")

                if options.includesReferences, let replyExcerpt = meta.groupReplyToExcerpt, !replyExcerpt.isEmpty {
                    let quoteLine = meta.groupReplyToSpeaker.map { String(localized: "回复 \($0)：\(replyExcerpt)") } ?? replyExcerpt
                    lines.append("")
                    lines.append("> \(quoteLine)")
                }

                if options.includesReasoning, !msg.reasoningContent.isEmpty {
                    lines.append("")
                    lines.append(forPDF ? "#### " + String(localized: "思考过程") : "<details><summary>\(String(localized: "思考过程"))</summary>")
                    lines.append("")
                    lines.append(msg.reasoningContent)
                    lines.append("")
                    if !forPDF { lines.append("</details>") }
                }

                if !msg.content.isEmpty {
                    lines.append("")
                    lines.append(msg.content)
                }

                if !meta.groupReactions.isEmpty {
                    let summary = meta.groupReactions.map { "\($0.emoji) \($0.memberName)" }.joined(separator: " · ")
                    lines.append("")
                    lines.append("*\(summary)*")
                }

                guard options.includesReferences else { continue }
                if let search = msg.assistanceMetadata.search, !search.sources.isEmpty {
                    lines.append("")
                    lines.append("**\(String(localized: "参考来源（\(search.query)）"))**")
                    for src in search.sources {
                        lines.append("- [\(src.title)](\(src.url.absoluteString))")
                    }
                }

                let references = ReadingReferences(knowledge: meta.knowledgeEvidence, book: meta.bookReply,
                                                   friend: conversation.activeBookFriend, limits: conversation.readingChapterLimits)
                if !references.sources.isEmpty {
                    lines.append("")
                    lines.append("**\(String(localized: "知识库引用"))**")
                    for source in references.sources {
                        lines.append("")
                        lines.append("[\(source.number)] \(source.documentTitle) · \(source.chapter)")
                        lines.append("> \(source.excerpt.replacingOccurrences(of: "\n", with: "\n> "))")
                    }
                }

            case .system, .tool:
                break
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static let exportsSubdirectoryName = "iOSBoxExports"

    private static func exportDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(exportsSubdirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeMarkdownFile(for conversation: Conversation, options: Options = .archive) throws -> URL {
        let markdown = makeMarkdown(for: conversation, options: options)
        let sanitized = sanitizedFileName(conversation.title)
        let url = try exportDirectory()
            .appendingPathComponent("\(sanitized).md")
        try Data(markdown.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    @MainActor
    static func writePDFFile(for conversation: Conversation, options: Options) async throws -> URL {
        let transcript = makeMarkdown(for: conversation, options: options, forPDF: true)
        let title = conversation.title, date = conversation.updatedAt
        return try await Task.detached(priority: .userInitiated) {
            try MessageExportRenderer.writePDFFile(title: title, speaker: String(localized: "对话"), date: date, markdown: transcript)
        }.value
    }

    static let shareCardCharacterCap = 900
    static let shareCardMessageCap = 12

    struct ShareCardContent {
        struct Entry {
            let message: ChatMessage
            let text: String
            let truncated: Bool

            init(_ message: ChatMessage) {
                self.message = message
                var body = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty {
                    let names = message.attachments.map(\.fileName).joined(separator: ", ")
                    body = names.isEmpty ? String(localized: "[附件消息]") : String(localized: "附件：\(names)")
                }
                let prefix = body.prefix(shareCardCharacterCap)
                truncated = prefix.endIndex != body.endIndex
                text = truncated ? String(prefix) + "…" : body
            }
        }

        let entries: [Entry]
        let omittedEarlier: Int
        var truncatedCount: Int { entries.filter(\.truncated).count }
        var notice: String? {
            var lines: [String] = []
            if omittedEarlier > 0 { lines.append(String(localized: "已省略选区中较早的 \(omittedEarlier) 条消息。")) }
            if truncatedCount > 0 { lines.append(String(localized: "图中有 \(truncatedCount) 条消息仅展示前 \(shareCardCharacterCap) 字。")) }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    static func shareCardContent(for conversation: Conversation, selectedIDs: Set<UUID>?) -> ShareCardContent {
        let active = messages(in: conversation, selectedIDs: selectedIDs)
        var collapsed: [ChatMessage] = []
        var visitedGroups = Set<UUID>()

        for msg in active {
            if selectedIDs == nil, let gid = msg.comparisonGroupID {
                guard visitedGroups.insert(gid).inserted else { continue }
                let group = active.filter { $0.comparisonGroupID == gid && !$0.content.isEmpty }
                if let chosen = group.first(where: \.isSelectedInGroup) ?? group.first {
                    collapsed.append(chosen)
                }
            } else if msg.role == .user && (!msg.content.isEmpty || !msg.attachments.isEmpty) {
                collapsed.append(msg)
            } else if (msg.role == .assistant || msg.assistanceMetadata.sourceNotice != nil) && (!msg.content.isEmpty || !msg.attachments.isEmpty) {
                collapsed.append(msg)
            }
        }

        let entries = collapsed.suffix(shareCardMessageCap).map(ShareCardContent.Entry.init)
        return ShareCardContent(entries: entries, omittedEarlier: collapsed.count - entries.count)
    }

    @MainActor
    static func renderShareImage(for conversation: Conversation, colorScheme: ColorScheme = .light, selectedIDs: Set<UUID>? = nil) -> UIImage? {
        let content = shareCardContent(for: conversation, selectedIDs: selectedIDs)
        guard !content.entries.isEmpty else { return nil }

        let card = ShareConversationCardView(
            title: conversation.title,
            emoji: conversation.assistantEmoji,
            content: content,
            includesReplyExcerpt: selectedIDs == nil,
            speakerResolver: { msg in
                ArenaSynthesis.visibleSpeakerName(for: msg)
            }
        )
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2.0
        return renderer.uiImage
    }

    @MainActor
    static func writeShareImageFile(for conversation: Conversation, colorScheme: ColorScheme = .light, selectedIDs: Set<UUID>? = nil) throws -> URL? {
        guard let image = renderShareImage(for: conversation, colorScheme: colorScheme, selectedIDs: selectedIDs),
              let data = image.pngData() else {
            return nil
        }
        let sanitized = sanitizedFileName(conversation.title)
        let url = try exportDirectory()
            .appendingPathComponent("\(sanitized).png")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Fugue-Chat" : String(cleaned.prefix(48))
    }
}

private struct ShareConversationCardView: View {
    let title: String
    let emoji: String
    let content: ConversationExporter.ShareCardContent
    let includesReplyExcerpt: Bool
    let speakerResolver: (ChatMessage) -> String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let paperBg = isDark
            ? Color(red: 0.067, green: 0.075, blue: 0.094)
            : Color(red: 0.980, green: 0.969, blue: 0.941)
        let cardFill = isDark
            ? Color(red: 0.102, green: 0.114, blue: 0.141)
            : Color(red: 0.996, green: 0.992, blue: 0.980)
        let vermilion = isDark
            ? Color(red: 0.886, green: 0.494, blue: 0.369)
            : Color(red: 0.737, green: 0.243, blue: 0.141)
        let border = isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                FugueSealMark(character: "奔", size: 34, theme: .vermilion)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("夜奔 Fugue · 对话书笺")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(emoji)
                    .font(.title3)
            }

            Divider().overlay(border)

            if let notice = content.notice {
                Text(verbatim: notice).font(.footnote).foregroundStyle(.secondary)
            }

            ForEach(content.entries, id: \.message.id) { entry in
                let msg = entry.message
                let meta = msg.assistanceMetadata
                VStack(alignment: .leading, spacing: 6) {
                    if msg.role == .user {
                        HStack(alignment: .top, spacing: 10) {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(vermilion)
                                .frame(width: 2.5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("提问")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(vermilion)
                                Text(verbatim: entry.text)
                                    .font(.system(size: 14.5, weight: .semibold, design: .serif))
                                    .foregroundStyle(.primary)
                                    .lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 2)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(vermilion)
                                Text(speakerResolver(msg))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            if includesReplyExcerpt, let replyExcerpt = meta.groupReplyToExcerpt, !replyExcerpt.isEmpty {
                                let quoteLine = meta.groupReplyToSpeaker.map { String(localized: "回复 \($0)：\(replyExcerpt)") } ?? replyExcerpt
                                Text(quoteLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(cardFill, in: RoundedRectangle(cornerRadius: 7))
                            }

                            Text(verbatim: entry.text)
                                .font(.system(size: 14, design: .serif))
                                .lineSpacing(4.5)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(border, lineWidth: 1)
                        )
                    }

                    if !meta.groupReactions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(meta.groupReactions) { item in
                                Text("\(item.emoji) \(item.memberName)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(cardFill, in: Capsule())
                            }
                        }
                    }
                }
            }

            Divider().overlay(border)

            HStack(spacing: 8) {
                FugueSealMark(character: "夜", size: 18, theme: .vermilion)
                Text("夜奔 (Fugue) · 本地直连多模型推演")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 430, alignment: .leading)
        .background(paperBg)
        .overlay(alignment: .top) {
            Rectangle().fill(vermilion).frame(height: 3.5)
        }
    }

}
