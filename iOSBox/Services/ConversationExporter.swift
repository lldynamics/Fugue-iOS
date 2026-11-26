import Foundation
import SwiftUI
import UIKit

enum ConversationExporter {
    static func makeMarkdown(for conversation: Conversation) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = []
        lines.append("# \(conversation.title)")
        lines.append("")
        lines.append("- \(String(localized: "更新时间：\(formatter.string(from: conversation.updatedAt))"))")
        if let target = conversation.primaryTarget, !conversation.isArenaMode {
            lines.append("- \(String(localized: "模型：\(target.providerName) · \(target.modelDisplayName)"))")
        }
        if !conversation.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## \(String(localized: "系统提示词"))")
            lines.append("")
            lines.append("> \(conversation.systemPrompt.replacingOccurrences(of: "\n", with: "\n> "))")
        }
        lines.append("")
        lines.append("---")

        let messages = ConversationTree.activeMessages(in: conversation)
        for msg in messages {
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
                if let quote = msg.assistanceMetadata.quotedExcerpt, !quote.isEmpty {
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

                if let replyExcerpt = meta.groupReplyToExcerpt, !replyExcerpt.isEmpty {
                    let quoteLine = meta.groupReplyToSpeaker.map { String(localized: "回复 \($0)：\(replyExcerpt)") } ?? replyExcerpt
                    lines.append("")
                    lines.append("> \(quoteLine)")
                }

                if !msg.reasoningContent.isEmpty {
                    lines.append("")
                    lines.append("<details><summary>\(String(localized: "思考过程"))</summary>")
                    lines.append("")
                    lines.append(msg.reasoningContent)
                    lines.append("")
                    lines.append("</details>")
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

    static func writeMarkdownFile(for conversation: Conversation) throws -> URL {
        let markdown = makeMarkdown(for: conversation)
        let sanitized = sanitizedFileName(conversation.title)
        let url = try exportDirectory()
            .appendingPathComponent("\(sanitized).md")
        try Data(markdown.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static let shareCardCharacterCap = 900

    @MainActor
    static func renderShareImage(for conversation: Conversation, colorScheme: ColorScheme = .light) -> UIImage? {
        let active = ConversationTree.activeMessages(in: conversation)
        var collapsed: [ChatMessage] = []
        var visitedGroups = Set<UUID>()

        for msg in active {
            if let gid = msg.comparisonGroupID {
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

        let messages = Array(collapsed.suffix(12))
        guard !messages.isEmpty else { return nil }

        let card = ShareConversationCardView(
            title: conversation.title,
            emoji: conversation.assistantEmoji,
            messages: messages,
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
    static func writeShareImageFile(for conversation: Conversation, colorScheme: ColorScheme = .light) throws -> URL? {
        guard let image = renderShareImage(for: conversation, colorScheme: colorScheme),
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
    let messages: [ChatMessage]
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

            ForEach(messages) { msg in
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
                                Text(cardBodyText(for: msg))
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

                            if let replyExcerpt = meta.groupReplyToExcerpt, !replyExcerpt.isEmpty {
                                let quoteLine = meta.groupReplyToSpeaker.map { String(localized: "回复 \($0)：\(replyExcerpt)") } ?? replyExcerpt
                                Text(quoteLine)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(cardFill, in: RoundedRectangle(cornerRadius: 7))
                            }

                            Text(cardBodyText(for: msg))
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

    private func cardBodyText(for msg: ChatMessage) -> String {
        let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let names = msg.attachments.map(\.fileName).joined(separator: ", ")
            return names.isEmpty ? String(localized: "[附件消息]") : String(localized: "附件：\(names)")
        }
        if trimmed.count > ConversationExporter.shareCardCharacterCap {
            return String(trimmed.prefix(ConversationExporter.shareCardCharacterCap)) + "…"
        }
        return trimmed
    }
}
