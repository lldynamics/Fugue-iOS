import SwiftUI
import UIKit

struct MarkdownContentView: View {
    let text: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    inlineMarkdownText(content)
                        .font(headingFont(for: level))
                        .fontWeight(.bold)
                        .padding(.top, level == 1 ? 6 : 3)

                case .paragraph(let content):
                    inlineMarkdownText(content)
                        .font(.body)
                        .lineSpacing(4)

                case .codeBlock(let language, let code):
                    CodeBlockCard(language: language, code: code)

                case .blockquote(let content):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.65))
                            .frame(width: 3.5)
                        inlineMarkdownText(content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                case .listItem(let marker, let content):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        inlineMarkdownText(content)
                            .font(.body)
                            .lineSpacing(3)
                    }

                case .divider:
                    Divider()
                        .padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func inlineMarkdownText(_ raw: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(raw)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .subheadline
        }
    }
}

private struct CodeBlockCard: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    UIPasteboard.general.string = code
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copied = true
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(1.8))
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                copied = false
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制代码")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(copied ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05))

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(SyntaxHighlighter.highlight(code: code))
                    .font(.system(size: 13.5, design: .monospaced))
                    .lineSpacing(3)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Block Parser & Syntax Highlighter

private enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case codeBlock(language: String, code: String)
    case blockquote(String)
    case listItem(marker: String, content: String)
    case divider
}

private enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var inCodeFence = false
        var codeLang = ""
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(paragraphBuffer.joined(separator: "\n")))
            paragraphBuffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.codeBlock(language: codeLang, code: codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    codeLang = ""
                    inCodeFence = false
                } else {
                    flushParagraph()
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeFence = true
                }
                continue
            }

            if inCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if trimmed.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(1, String(trimmed.dropFirst(2))))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                let quoteBody = trimmed.count > 2 ? String(trimmed.dropFirst(2)) : ""
                if case .blockquote(let prev) = blocks.last {
                    blocks[blocks.count - 1] = .blockquote(prev + "\n" + quoteBody)
                } else {
                    blocks.append(.blockquote(quoteBody))
                }
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.listItem(marker: "•", content: String(trimmed.dropFirst(2))))
                continue
            }

            if let orderedMatch = parseOrderedList(trimmed) {
                flushParagraph()
                blocks.append(.listItem(marker: orderedMatch.marker, content: orderedMatch.body))
                continue
            }

            paragraphBuffer.append(line)
        }

        if inCodeFence {
            blocks.append(.codeBlock(language: codeLang, code: codeLines.joined(separator: "\n")))
        } else {
            flushParagraph()
        }

        return blocks
    }

    private static func parseOrderedList(_ trimmed: String) -> (marker: String, body: String)? {
        guard let dotIdx = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[..<dotIdx]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = trimmed.index(after: dotIdx)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        let bodyStart = trimmed.index(after: afterDot)
        return ("\(prefix).", String(trimmed[bodyStart...]))
    }
}

private enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "struct", "class", "enum", "protocol", "extension", "import",
        "return", "if", "else", "switch", "case", "for", "while", "in", "guard", "async",
        "await", "try", "catch", "throw", "throws", "private", "public", "static", "final",
        "def", "from", "const", "function", "export", "interface", "type", "true", "false",
        "nil", "null", "None", "self", "init", "some", "View"
    ]

    static func highlight(code: String) -> AttributedString {
        var result = AttributedString(code)
        guard code.count < 12_000 else { return result }

        let nsString = code as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // Highlight keywords
        if let wordRegex = try? NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*\\b") {
            for match in wordRegex.matches(in: code, range: fullRange) {
                let word = nsString.substring(with: match.range)
                if keywords.contains(word),
                   let swiftRange = Range(match.range, in: result) {
                    result[swiftRange].foregroundColor = .purple
                }
            }
        }

        // Highlight string literals
        if let strRegex = try? NSRegularExpression(pattern: "\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*'") {
            for match in strRegex.matches(in: code, range: fullRange) {
                if let swiftRange = Range(match.range, in: result) {
                    result[swiftRange].foregroundColor = Color(red: 0.80, green: 0.32, blue: 0.16)
                }
            }
        }

        // Highlight single-line comments (// or #)
        if let commentRegex = try? NSRegularExpression(pattern: "(//|#).*$", options: [.anchorsMatchLines]) {
            for match in commentRegex.matches(in: code, range: fullRange) {
                if let swiftRange = Range(match.range, in: result) {
                    result[swiftRange].foregroundColor = .secondary
                }
            }
        }

        return result
    }
}
