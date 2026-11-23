import Foundation

enum BatchArchiveExporter {
    static func makeBookmarksMarkdown(
        entries: [BookmarkedMessageEntry],
        title: String? = nil,
        filterDescription: String? = nil,
        groupByTag: Bool = true,
        exportedAt: Date = Date()
    ) -> String {
        let resolvedTitle = {
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? String(localized: "夜奔 · 收藏知识库归档") : trimmed
        }()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = [
            "# \(resolvedTitle)",
            "",
            "- \(String(localized: "导出时间：\(formatter.string(from: exportedAt))"))",
            "- \(String(localized: "共 \(entries.count) 条精选片段"))"
        ]
        if let filter = filterDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty {
            lines.append("- \(String(localized: "筛选条件：\(filter)"))")
        }

        guard !entries.isEmpty else {
            lines.append("")
            lines.append(String(localized: "暂无收藏内容。"))
            return lines.joined(separator: "\n") + "\n"
        }

        if groupByTag {
            let untaggedKey = String(localized: "未分组")
            var grouped: [String: [BookmarkedMessageEntry]] = [:]
            for entry in entries {
                let tag = entry.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let key = tag.isEmpty ? untaggedKey : tag
                grouped[key, default: []].append(entry)
            }
            let sortedGroupKeys = grouped.keys.sorted { lhs, rhs in
                if lhs == untaggedKey { return false }
                if rhs == untaggedKey { return true }
                return lhs.localizedCompare(rhs) == .orderedAscending
            }
            for key in sortedGroupKeys {
                lines.append("")
                if key == untaggedKey {
                    lines.append("## \(untaggedKey)")
                } else {
                    lines.append("## \(String(localized: "分组：\(key)"))")
                }
                let items = (grouped[key] ?? []).sorted { $0.createdAt > $1.createdAt }
                appendBookmarkEntries(items, to: &lines, formatter: formatter)
            }
        } else {
            let sorted = entries.sorted { $0.createdAt > $1.createdAt }
            appendBookmarkEntries(sorted, to: &lines, formatter: formatter)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func writeBookmarksMarkdownFile(
        entries: [BookmarkedMessageEntry],
        title: String? = nil,
        filterDescription: String? = nil,
        groupByTag: Bool = true,
        exportedAt: Date = Date()
    ) throws -> URL {
        let resolvedTitle = nonEmptyTitle(title, fallback: String(localized: "夜奔-收藏知识库归档"))
        let markdown = makeBookmarksMarkdown(
            entries: entries,
            title: title,
            filterDescription: filterDescription,
            groupByTag: groupByTag,
            exportedAt: exportedAt
        )
        let url = try exportDirectory()
            .appendingPathComponent("\(sanitizedFileName(resolvedTitle)).md")
        try Data(markdown.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func writeBookmarksPDFFile(
        entries: [BookmarkedMessageEntry],
        title: String? = nil,
        filterDescription: String? = nil,
        groupByTag: Bool = true,
        exportedAt: Date = Date()
    ) throws -> URL {
        let resolvedTitle = nonEmptyTitle(title, fallback: String(localized: "夜奔 · 收藏知识库归档"))
        let markdown = makeBookmarksMarkdown(
            entries: entries,
            title: resolvedTitle,
            filterDescription: filterDescription,
            groupByTag: groupByTag,
            exportedAt: exportedAt
        )
        let body = strippingLeadingTitleLine(markdown)
        let pdfData = MessageExportRenderer.makePDFData(
            title: resolvedTitle,
            speaker: String(localized: "共 \(entries.count) 条精选片段"),
            date: exportedAt,
            markdown: body
        )
        let url = try exportDirectory()
            .appendingPathComponent("\(sanitizedFileName(resolvedTitle)).pdf")
        try pdfData.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func makeConversationsMarkdown(
        conversations: [Conversation],
        title: String? = nil,
        exportedAt: Date = Date()
    ) -> String {
        let sorted = sortedConversations(conversations)
        let resolvedTitle = nonEmptyTitle(title, fallback: String(localized: "夜奔 · 多会话归档汇总"))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = [
            "# \(resolvedTitle)",
            "",
            "- \(String(localized: "导出时间：\(formatter.string(from: exportedAt))"))",
            "- \(String(localized: "共 \(sorted.count) 段对话"))"
        ]

        guard !sorted.isEmpty else {
            lines.append("")
            lines.append(String(localized: "未选择可导出的对话。"))
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("")
        lines.append("## \(String(localized: "目录"))")
        lines.append("")
        for (index, conv) in sorted.enumerated() {
            let activeCount = ConversationTree.activeMessages(in: conv).filter {
                !$0.assistanceMetadata.isContextDivider && (!$0.content.isEmpty || !$0.attachments.isEmpty)
            }.count
            var details: [String] = []
            if let tag = conv.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
                details.append(tag)
            }
            details.append(String(localized: "\(activeCount) 条消息"))
            details.append(formatter.string(from: conv.updatedAt))
            lines.append("\(index + 1). \(conv.title)（\(details.joined(separator: " · "))）")
        }

        for (index, conv) in sorted.enumerated() {
            lines.append("")
            lines.append("---")
            lines.append("")
            let nested = shiftHeadingsOutsideCodeBlocks(
                ConversationExporter.makeMarkdown(for: conv),
                numberingPrefix: "\(index + 1)."
            )
            lines.append(nested.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func writeConversationsMarkdownFile(
        conversations: [Conversation],
        title: String? = nil,
        exportedAt: Date = Date()
    ) throws -> URL {
        let resolvedTitle = nonEmptyTitle(title, fallback: String(localized: "夜奔-多会话归档汇总"))
        let markdown = makeConversationsMarkdown(
            conversations: conversations,
            title: title,
            exportedAt: exportedAt
        )
        let url = try exportDirectory()
            .appendingPathComponent("\(sanitizedFileName(resolvedTitle)).md")
        try Data(markdown.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func writeConversationsPDFFile(
        conversations: [Conversation],
        title: String? = nil,
        exportedAt: Date = Date()
    ) throws -> URL {
        let sorted = sortedConversations(conversations)
        let resolvedTitle = nonEmptyTitle(title, fallback: String(localized: "夜奔 · 多会话归档汇总"))
        let markdown = makeConversationsMarkdown(
            conversations: sorted,
            title: resolvedTitle,
            exportedAt: exportedAt
        )
        let body = strippingLeadingTitleLine(markdown)
        let pdfData = MessageExportRenderer.makePDFData(
            title: resolvedTitle,
            speaker: String(localized: "共 \(sorted.count) 段对话"),
            date: exportedAt,
            markdown: body
        )
        let url = try exportDirectory()
            .appendingPathComponent("\(sanitizedFileName(resolvedTitle)).pdf")
        try pdfData.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    // MARK: - Helpers

    private static func appendBookmarkEntries(
        _ entries: [BookmarkedMessageEntry],
        to lines: inout [String],
        formatter: DateFormatter
    ) {
        for entry in entries {
            lines.append("")
            lines.append("### \(entry.conversationTitle)")
            lines.append("")
            lines.append("*\(entry.speaker) · \(formatter.string(from: entry.createdAt))*")
            lines.append("")
            lines.append(entry.content.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
            lines.append("---")
        }
    }

    private static func sortedConversations(_ conversations: [Conversation]) -> [Conversation] {
        conversations
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned {
                    return lhs.isPinned && !rhs.isPinned
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private static func shiftHeadingsOutsideCodeBlocks(
        _ markdown: String,
        numberingPrefix: String
    ) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var activeFence: String?
        var replacedTopTitle = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                activeFence = (activeFence == "```") ? nil : (activeFence ?? "```")
                result.append(line)
                continue
            }
            if trimmed.hasPrefix("~~~") {
                activeFence = (activeFence == "~~~") ? nil : (activeFence ?? "~~~")
                result.append(line)
                continue
            }
            if activeFence != nil {
                result.append(line)
                continue
            }

            if !replacedTopTitle && line.hasPrefix("# ") {
                replacedTopTitle = true
                result.append("## \(numberingPrefix) \(line.dropFirst(2))")
            } else if line.hasPrefix("#") {
                var count = 0
                for ch in line {
                    if ch == "#" { count += 1 } else { break }
                }
                if (1...5).contains(count), line.dropFirst(count).first == " " {
                    result.append("#" + line)
                } else {
                    result.append(line)
                }
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    private static func strippingLeadingTitleLine(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
            if lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func nonEmptyTitle(_ raw: String?, fallback: String) -> String {
        let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? fallback : clean
    }

    private static func exportDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(ConversationExporter.exportsSubdirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Fugue-Archive" : String(cleaned.prefix(48))
    }
}
