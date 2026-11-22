import Foundation

/// Converts Markdown responses into clean plain text suited for WeChat, Feishu, emails, and notes.
enum PlainTextFormatter {
    private static let headingRegex = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.*)$"#)
    private static let blockquotePrefixRegex = try! NSRegularExpression(pattern: #"^\s{0,3}>\s?"#)
    private static let dividerLineRegex = try! NSRegularExpression(pattern: #"^\s{0,3}(?:[-*_]\s*){3,}$"#)
    private static let tableDividerRegex = try! NSRegularExpression(pattern: #"^\|?\s*:?-{2,}:?(?:\s*\|\s*:?-{2,}:?)*\s*\|?$"#)
    private static let unorderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)[-*+]\s+(.*)$"#)
    private static let orderedListRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+\.)\s+(.*)$"#)
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let autoLinkRegex = try! NSRegularExpression(pattern: #"<(https?://[^>]+)>"#)
    private static let boldDoubleStarRegex = try! NSRegularExpression(pattern: #"\*\*([^\n*]+?)\*\*"#)
    private static let boldDoubleUnderscoreRegex = try! NSRegularExpression(pattern: #"__([^\n_]+?)__"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"~~([^\n~]+?)~~"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`([^`\n]+?)`"#)
    private static let italicStarRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*([^\s*](?:[^*\n]*?[^\s*])?)\*(?!\*)"#)
    private static let italicWordSafeUnderscoreRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])_([^\s_](?:[^_\n]*?[^\s_])?)_(?![\p{L}\p{N}_])"#)
    private static let inlineMathRegex = try! NSRegularExpression(pattern: #"(?<!\w)\$([^\s$](?:[^$\n]*?[^\s$])?)\$(?!\d)"#)
    private static let cjkRegex = try! NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#)
    private static let multiBlankLineRegex = try! NSRegularExpression(pattern: #"\n{3,}"#)

    static func format(_ markdown: String) -> String {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var outLines: [String] = []
        var inCodeFence = false
        var fenceToken = ""

        for rawSub in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let rawLine = String(rawSub)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let fenceCandidate: String? = if trimmed.hasPrefix("```") {
                "```"
            } else if trimmed.hasPrefix("~~~") {
                "~~~"
            } else {
                nil
            }
            if let fence = fenceCandidate {
                if !inCodeFence {
                    inCodeFence = true
                    fenceToken = fence
                    continue
                } else if fence == fenceToken {
                    inCodeFence = false
                    fenceToken = ""
                    continue
                }
            }

            if inCodeFence {
                outLines.append(rawLine)
                continue
            }

            if let formatted = formatMarkdownLine(rawLine) {
                outLines.append(formatted)
            }
        }

        let joined = outLines.joined(separator: "\n")
        return replaceMatches(multiBlankLineRegex, in: joined) { _ in "\n\n" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMarkdownLine(_ rawLine: String) -> String? {
        var line = rawLine
        while firstMatch(blockquotePrefixRegex, in: line) != nil {
            line = replaceFirst(blockquotePrefixRegex, in: line, with: "")
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if firstMatch(dividerLineRegex, in: trimmed) != nil { return "" }

        if trimmed.contains("|"), trimmed.hasPrefix("|") || trimmed.hasSuffix("|") || firstMatch(tableDividerRegex, in: trimmed) != nil {
            if firstMatch(tableDividerRegex, in: trimmed) != nil {
                return nil
            }
            let bordered = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            let nonEmpty = bordered
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { cleanInline(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            if nonEmpty.isEmpty { return nil }
            if nonEmpty.count == 2 {
                let sep = firstMatch(cjkRegex, in: trimmed) != nil ? "：" : ": "
                return "\(nonEmpty[0])\(sep)\(nonEmpty[1])"
            }
            return nonEmpty.joined(separator: " | ")
        }

        if let match = firstMatch(headingRegex, in: trimmed) {
            return cleanInline(group(1, in: trimmed, match: match).trimmingCharacters(in: .whitespaces))
        }
        if let match = firstMatch(unorderedListRegex, in: line) {
            let indent = group(1, in: line, match: match)
            let body = cleanInline(group(2, in: line, match: match).trimmingCharacters(in: .whitespaces))
            return "\(indent)• \(body)"
        }
        if let match = firstMatch(orderedListRegex, in: line) {
            let indent = group(1, in: line, match: match)
            let num = group(2, in: line, match: match)
            let body = cleanInline(group(3, in: line, match: match).trimmingCharacters(in: .whitespaces))
            return "\(indent)\(num) \(body)"
        }

        return cleanInline(line)
    }

    private static func cleanInline(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var text = replaceMatches(imageRegex, in: raw) { groups in groups[1] }
        text = replaceMatches(linkRegex, in: text) { groups in
            let label = groups[1].trimmingCharacters(in: .whitespaces)
            let url = groups[2].trimmingCharacters(in: .whitespaces)
            return (label.isEmpty || label == url) ? url : "\(label) (\(url))"
        }
        text = replaceMatches(autoLinkRegex, in: text) { $0[1] }
        text = text
            .replacingOccurrences(of: "$$", with: "")
            .replacingOccurrences(of: "\\[", with: "")
            .replacingOccurrences(of: "\\]", with: "")
            .replacingOccurrences(of: "\\(", with: "")
            .replacingOccurrences(of: "\\)", with: "")
        text = replaceMatches(inlineMathRegex, in: text) { $0[1] }
        text = replaceMatches(inlineCodeRegex, in: text) { $0[1] }
        text = replaceMatches(boldDoubleStarRegex, in: text) { $0[1] }
        text = replaceMatches(boldDoubleUnderscoreRegex, in: text) { $0[1] }
        text = replaceMatches(strikeRegex, in: text) { $0[1] }
        text = replaceMatches(italicStarRegex, in: text) { $0[1] }
        text = replaceMatches(italicWordSafeUnderscoreRegex, in: text) { $0[1] }
        return text
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range)
    }

    private static func replaceFirst(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        guard let match = firstMatch(regex, in: text), let r = Range(match.range, in: text) else { return text }
        var copy = text
        copy.replaceSubrange(r, with: template)
        return copy
    }

    private static func group(_ index: Int, in text: String, match: NSTextCheckingResult) -> String {
        guard index < match.numberOfRanges, let r = Range(match.range(at: index), in: text) else { return "" }
        return String(text[r])
    }

    private static func replaceMatches(
        _ regex: NSRegularExpression,
        in text: String,
        transform: ([String]) -> String
    ) -> String {
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: text) else { continue }
            result.append(contentsOf: text[cursor..<fullRange.lowerBound])
            var groups: [String] = []
            for idx in 0..<match.numberOfRanges {
                if let gr = Range(match.range(at: idx), in: text) {
                    groups.append(String(text[gr]))
                } else {
                    groups.append("")
                }
            }
            result.append(contentsOf: transform(groups))
            cursor = fullRange.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }
}
