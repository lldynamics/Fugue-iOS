import SwiftUI
import UIKit

struct MarkdownContentView: View {
    let text: String
    var isStreaming: Bool = false
    @State private var preferences = AppPreferences.shared
    @ScaledMetric(relativeTo: .body) private var baseBodySize: CGFloat = 17

    var body: some View {
        let blocks = isStreaming ? MarkdownBlockParser.parse(text) : MarkdownBlockParser.parseCached(text)
        let lastIndex = blocks.count - 1
        let effectiveBodySize = baseBodySize * preferences.fontScale
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, isStreaming: isStreaming && index == lastIndex, bodySize: effectiveBodySize)
                    .equatable()
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    var isStreaming: Bool = false
    var bodySize: CGFloat = 17

    var body: some View {
        let bodyFont = Font.system(size: bodySize)
        switch block {
        case .heading(let level, let content):
            InlineMarkdownText(raw: content)
                .font(headingFont(for: level, baseSize: bodySize))
                .fontWeight(.bold)
                .padding(.top, level == 1 ? 6 : 3)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let content):
            InlineMarkdownText(raw: content)
                .font(bodyFont)
                .lineSpacing(4)

        case .codeBlock(let language, let code):
            CodeBlockCard(language: language, code: code, cacheable: !isStreaming)

        case .mathBlock(let tex):
            MathBlockCard(tex: tex, isStreaming: isStreaming)

        case .table(let table):
            MarkdownTableView(table: table)

        case .blockquote(let content):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3.5)
                InlineMarkdownText(raw: content)
                    .font(.system(size: max(13, bodySize - 1)))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

        case .listItem(let marker, let content, let level):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(bodyFont.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                InlineMarkdownText(raw: content)
                    .font(bodyFont)
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(level) * 18)

        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingFont(for level: Int, baseSize: CGFloat) -> Font {
        switch level {
        case 1: return .system(size: baseSize * 1.24, weight: .bold)
        case 2: return .system(size: baseSize * 1.12, weight: .bold)
        default: return .system(size: baseSize * 1.02, weight: .semibold)
        }
    }
}

private struct InlineMarkdownText: View {
    let raw: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let segments = InlineMathParser.split(raw)
        if segments.count == 1, case .text(let only) = segments[0] {
            Self.markdownText(only)
        } else {
            composedText(segments)
        }
    }

    private func composedText(_ segments: [InlineMathSegment]) -> Text {
        let fontSize = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        ).pointSize

        return segments.reduce(Text(verbatim: "")) { partial, segment in
            switch segment {
            case .text(let text):
                return partial + Self.markdownText(text)
            case .math(let tex, let display):
                if let rendered = MathRenderer.render(latex: tex, fontSize: fontSize, colorScheme: colorScheme, displayStyle: display) {
                    return partial + Text(Image(uiImage: rendered.image)).baselineOffset(-rendered.descent)
                }
                return partial + Text(verbatim: display ? "$$\(tex)$$" : "$\(tex)$")
            }
        }
    }

    static func markdownText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(verbatim: raw)
    }
}

private extension UIContentSizeCategory {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}

// MARK: - Cards

private struct CopyButton: View {
    let text: String
    let idleTitle: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
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
                Text(copied ? String(localized: "已复制") : idleTitle)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(copied ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct CardHeader: View {
    let title: String
    let copyText: String
    let copyTitle: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            CopyButton(text: copyText, idleTitle: copyTitle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05))
    }
}

private struct CodeBlockCard: View {
    let language: String
    let code: String
    var cacheable: Bool = true

    @State private var showLineNumbers = AppPreferences.shared.codeDefaultLineNumbers
    @State private var isExpanded = false
    @State private var showArtifactPreview = false
    @State private var showInlinePreview = false

    private var lines: [String] {
        code.components(separatedBy: "\n")
    }

    private var isLongCode: Bool {
        cacheable && lines.count > 30
    }

    private var displayCode: String {
        if isLongCode && !isExpanded {
            return lines.prefix(20).joined(separator: "\n")
        }
        return code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)

                if ArtifactDocumentBuilder.isPreviewable(language: language) && cacheable {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            showInlinePreview.toggle()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: showInlinePreview ? "chevron.left.forwardslash.chevron.right" : "eye.fill")
                            Text(showInlinePreview ? String(localized: "源码") : String(localized: "内嵌预览"))
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showArtifactPreview = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                            Text("预览")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    showLineNumbers.toggle()
                } label: {
                    Image(systemName: showLineNumbers ? "list.number" : "number")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(showLineNumbers ? Color.accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("显示行号")

                CopyButton(text: code, idleTitle: String(localized: "复制代码"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05))

            Divider().opacity(0.4)

            if showInlinePreview && ArtifactDocumentBuilder.isPreviewable(language: language) && cacheable {
                SandboxedArtifactWebView(
                    html: ArtifactDocumentBuilder.htmlDocument(language: language, code: code),
                    allowsJavaScript: ArtifactDocumentBuilder.allowsJavaScript(for: language)
                )
                .frame(height: 230)
                .background(Color(.systemBackground))
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 10) {
                        if showLineNumbers {
                            let visibleLines = isLongCode && !isExpanded ? Array(lines.prefix(20)) : lines
                            Text((1...max(1, visibleLines.count)).map(String.init).joined(separator: "\n"))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.trailing)
                                .lineSpacing(3)
                        }

                        Text(SyntaxHighlighter.highlight(code: displayCode, cacheable: cacheable))
                            .font(.footnote.monospaced())
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                }

                if isLongCode {
                    Divider().opacity(0.4)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            Text(isExpanded
                                 ? String(localized: "收起代码（共 \(lines.count) 行）")
                                 : String(localized: "展开全部代码（共 \(lines.count) 行）"))
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.03))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .cardStyle()
        .sheet(isPresented: $showArtifactPreview) {
            ArtifactPreviewSheet(language: language, code: code)
        }
    }
}

private struct MathBlockCard: View {
    let tex: String
    var isStreaming: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 19

    var body: some View {
        if !isStreaming, let rendered = MathRenderer.render(latex: tex, fontSize: fontSize, colorScheme: colorScheme, displayStyle: true) {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: rendered.image)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = tex
                } label: {
                    Label("复制 LaTeX 源码", systemImage: "doc.on.doc")
                }
            }
            .accessibilityElement()
            .accessibilityLabel(String(localized: "公式：\(tex)"))
        } else {
            sourceCard
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: String(localized: "公式 · LaTeX"), copyText: tex, copyTitle: String(localized: "复制公式"))
            Divider().opacity(0.4)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: tex)
                    .font(.callout.monospaced())
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .cardStyle()
        .accessibilityLabel(String(localized: "公式：\(tex)"))
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        let widths = table.estimatedColumnWidths()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "tablecells")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: table.toTSV(), idleTitle: String(localized: "复制表格"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    row(table.header, widths: widths, isHeader: true)
                        .background(Color.primary.opacity(0.06))
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                        Divider().opacity(0.5)
                        row(cells, widths: widths, isHeader: false)
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    }
                }
            }
        }
        .cardStyle()
    }

    private func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(widths.indices, id: \.self) { column in
                let text = column < cells.count ? cells[column] : ""
                let alignment = table.alignment(of: column)
                InlineMarkdownText(raw: text)
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .multilineTextAlignment(alignment.textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: widths[column], alignment: alignment.frameAlignment)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                if column < widths.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

// MARK: - Block Model

struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case leading, center, trailing

        var textAlignment: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var frameAlignment: SwiftUI.Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]

    var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    func alignment(of column: Int) -> Alignment {
        column < alignments.count ? alignments[column] : .leading
    }

    func estimatedColumnWidths(minWidth: CGFloat = 44, maxWidth: CGFloat = 240) -> [CGFloat] {
        (0..<columnCount).map { column in
            let cells = ([header] + rows).compactMap { column < $0.count ? $0[column] : nil }
            let widest = cells.map(Self.estimatedWidth).max() ?? minWidth
            return min(max(widest, minWidth), maxWidth)
        }
    }

    func toTSV() -> String {
        ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    private static func estimatedWidth(_ text: String) -> CGFloat {
        text.unicodeScalars.reduce(0) { width, scalar in
            width + (scalar.value > 0x2E7F ? 16 : 8.5)
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case codeBlock(language: String, code: String)
    case mathBlock(String)
    case table(MarkdownTable)
    case blockquote(String)
    case listItem(marker: String, content: String, level: Int)
    case divider
}

// MARK: - Block Parser

private final class CachedBlocksBox: NSObject {
    let blocks: [MarkdownBlock]
    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
}

enum MarkdownBlockParser {
    private nonisolated(unsafe) static let parseCache: NSCache<NSString, CachedBlocksBox> = {
        let c = NSCache<NSString, CachedBlocksBox>()
        c.countLimit = 256
        return c
    }()

    static func parseCached(_ source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        let key = source as NSString
        if let hit = parseCache.object(forKey: key) {
            return hit.blocks
        }
        let parsed = parse(source)
        parseCache.setObject(CachedBlocksBox(parsed), forKey: key)
        return parsed
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraphBuffer: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(paragraphBuffer.joined(separator: "\n")))
            paragraphBuffer.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(language: language, code: codeLines.joined(separator: "\n")))
                index += 1
                continue
            }

            if let math = parseMathBlock(lines: lines, from: index) {
                flushParagraph()
                blocks.append(.mathBlock(math.tex))
                index = math.nextIndex
                continue
            }

            if let table = parseTable(lines: lines, from: index) {
                flushParagraph()
                blocks.append(.table(table.table))
                index = table.nextIndex
                continue
            }

            index += 1

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.level, heading.text))
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

            let level = indentLevel(of: line)

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                var body = String(trimmed.dropFirst(2))
                var marker = level == 0 ? "•" : "◦"
                if body.hasPrefix("[ ] ") {
                    marker = "☐"
                    body = String(body.dropFirst(4))
                } else if body.lowercased().hasPrefix("[x] ") {
                    marker = "☑"
                    body = String(body.dropFirst(4))
                }
                blocks.append(.listItem(marker: marker, content: body, level: level))
                continue
            }

            if let orderedMatch = parseOrderedList(trimmed) {
                flushParagraph()
                blocks.append(.listItem(marker: orderedMatch.marker, content: orderedMatch.body, level: level))
                continue
            }

            paragraphBuffer.append(line)
        }

        flushParagraph()
        return blocks
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func indentLevel(of line: String) -> Int {
        var width = 0
        for char in line {
            if char == " " { width += 1 } else if char == "\t" { width += 4 } else { break }
        }
        return min(width / 2, 4)
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" })
        let level = hashes.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()))
    }

    private static func parseOrderedList(_ trimmed: String) -> (marker: String, body: String)? {
        guard let dotIdx = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let prefix = trimmed[..<dotIdx]
        guard !prefix.isEmpty, prefix.count <= 3, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = trimmed.index(after: dotIdx)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        let bodyStart = trimmed.index(after: afterDot)
        return ("\(prefix).", String(trimmed[bodyStart...]))
    }

    // MARK: Math

    private static func parseMathBlock(lines: [String], from start: Int) -> (tex: String, nextIndex: Int)? {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let delimiters: [(open: String, close: String)] = [("$$", "$$"), ("\\[", "\\]")]

        for (open, close) in delimiters where first.hasPrefix(open) {
            let afterOpen = String(first.dropFirst(open.count))
            if afterOpen.hasSuffix(close), afterOpen.count >= close.count {
                let tex = String(afterOpen.dropLast(close.count)).trimmingCharacters(in: .whitespaces)
                if !tex.isEmpty { return (tex, start + 1) }
            }
            var body: [String] = afterOpen.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [afterOpen]
            var index = start + 1
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(close) {
                    let lastPart = String(trimmed.dropLast(close.count))
                    if !lastPart.trimmingCharacters(in: .whitespaces).isEmpty { body.append(lastPart) }
                    return (body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), index + 1)
                }
                body.append(lines[index])
                index += 1
            }
            if afterOpen.trimmingCharacters(in: .whitespaces).isEmpty {
                return (body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), index)
            }
        }
        return nil
    }

    // MARK: Tables

    private static func parseTable(lines: [String], from start: Int) -> (table: MarkdownTable, nextIndex: Int)? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start].trimmingCharacters(in: .whitespaces)
        guard headerLine.contains("|"),
              let alignments = parseDelimiterRow(lines[start + 1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let header = splitRow(headerLine)
        guard header.count == alignments.count, header.count >= 1 else { return nil }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            rows.append(splitRow(trimmed))
            index += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), index)
    }

    private static func parseDelimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
        guard line.contains("-") else { return nil }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            let starts = cell.hasPrefix(":")
            let ends = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 1, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(starts && ends ? .center : (ends ? .trailing : .leading))
        }
        return result
    }

    private static func splitRow(_ line: String) -> [String] {
        var content = Substring(line)
        if content.hasPrefix("|") { content = content.dropFirst() }
        if content.hasSuffix("|") && !content.hasSuffix("\\|") { content = content.dropLast() }

        var cells: [String] = []
        var current = ""
        var escaping = false
        for char in content {
            if escaping {
                current.append(char == "|" ? "|" : "\\\(char)")
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else if char == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        if escaping { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

// MARK: - Syntax Highlighter (with LRU Cache)

private final class HighlightedBox: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

enum SyntaxHighlighter {
    private nonisolated(unsafe) static let cache: NSCache<NSString, HighlightedBox> = {
        let c = NSCache<NSString, HighlightedBox>()
        c.countLimit = 180
        return c
    }()

    private static let keywords: Set<String> = [
        "func", "let", "var", "struct", "class", "enum", "protocol", "extension", "import",
        "return", "if", "else", "switch", "case", "default", "break", "continue", "for", "while",
        "in", "guard", "async", "await", "try", "catch", "throw", "throws", "defer", "do",
        "private", "public", "internal", "fileprivate", "open", "static", "final", "override",
        "def", "from", "as", "with", "yield", "lambda", "pass", "raise", "const", "function",
        "export", "interface", "type", "true", "false", "nil", "null", "None", "self", "Self",
        "super", "init", "some", "any", "View", "fn", "pub", "mut", "impl", "match", "use",
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN"
    ]

    private static let wordRegex = try? NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]*\\b")
    private static let numberRegex = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")
    private static let stringRegex = try? NSRegularExpression(
        pattern: "\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'"
    )
    private static let commentRegex = try? NSRegularExpression(
        pattern: "//.*$|(?:^|(?<=\\s))#(?=\\s|$).*$",
        options: [.anchorsMatchLines]
    )

    static func highlight(code: String, cacheable: Bool = true) -> AttributedString {
        guard code.count < 40_000 else { return AttributedString(code) }
        // Defer expensive multi-pass regex & AttributedString range conversion on large trailing blocks
        // while tokens are actively streaming; full highlighting runs as soon as the fence closes.
        if !cacheable && code.count > 1_200 {
            return AttributedString(code)
        }
        let cacheKey = code as NSString
        if cacheable, let hit = cache.object(forKey: cacheKey) {
            return hit.value
        }

        var result = AttributedString(code)
        let nsString = code as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        let stringRanges = stringRegex?.matches(in: code, range: fullRange).map(\.range) ?? []
        let commentRanges = commentRegex?.matches(in: code, range: fullRange).map(\.range).filter { range in
            !containsLocation(range.location, inSortedRanges: stringRanges)
        } ?? []

        if let numberRegex {
            for match in numberRegex.matches(in: code, range: fullRange) {
                let inside = containsLocation(match.range.location, inSortedRanges: stringRanges)
                    || containsLocation(match.range.location, inSortedRanges: commentRanges)
                if !inside, let swiftRange = Range(match.range, in: result) {
                    result[swiftRange].foregroundColor = .blue
                }
            }
        }

        if let wordRegex {
            for match in wordRegex.matches(in: code, range: fullRange) {
                let word = nsString.substring(with: match.range)
                guard keywords.contains(word) else { continue }
                let inside = containsLocation(match.range.location, inSortedRanges: stringRanges)
                    || containsLocation(match.range.location, inSortedRanges: commentRanges)
                if !inside, let swiftRange = Range(match.range, in: result) {
                    result[swiftRange].foregroundColor = .purple
                }
            }
        }

        for range in stringRanges {
            if let swiftRange = Range(range, in: result) {
                result[swiftRange].foregroundColor = Color(red: 0.80, green: 0.32, blue: 0.16)
            }
        }

        for range in commentRanges {
            if let swiftRange = Range(range, in: result) {
                result[swiftRange].foregroundColor = .secondary
            }
        }

        if cacheable {
            cache.setObject(HighlightedBox(result), forKey: cacheKey)
        }
        return result
    }

    private static func containsLocation(_ location: Int, inSortedRanges ranges: [NSRange]) -> Bool {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = ranges[mid]
            if location < r.location {
                high = mid - 1
            } else if location >= r.location + r.length {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }
}
