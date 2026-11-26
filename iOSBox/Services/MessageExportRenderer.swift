import Foundation
import SwiftUI
import UIKit

enum MessageExportBlock: Equatable {
    case heading(level: Int, text: String)
    case codeBlock(language: String, code: String)
    case quote(text: String)
    case bullet(marker: String, text: String)
    case divider
    case paragraph(text: String)
}

enum MessageExportRenderer {
    static let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    static let shareCardCharacterCap = 3600
    static let pdfTraitCollection = UITraitCollection(userInterfaceStyle: .light)

    static func pdfColor(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: pdfTraitCollection)
    }

    static func parseBlocks(from markdown: String) -> [MessageExportBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MessageExportBlock] = []
        var paragraphBuffer: [String] = []
        var quoteBuffer: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(text: cleanInline(joined)))
            }
            paragraphBuffer.removeAll()
        }

        func flushQuote() {
            let joined = quoteBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.quote(text: cleanInline(joined)))
            }
            quoteBuffer.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                flushQuote()
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(.codeBlock(language: lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let (level, text) = parseHeading(trimmed) {
                flushParagraph()
                flushQuote()
                blocks.append(.heading(level: level, text: cleanInline(text)))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var body = String(trimmed.dropFirst())
                if body.hasPrefix(" ") { body.removeFirst() }
                quoteBuffer.append(body)
                index += 1
                continue
            } else if !quoteBuffer.isEmpty {
                flushQuote()
            }

            if let (marker, body) = parseBullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(marker: marker, text: cleanInline(body)))
                index += 1
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }

        flushParagraph()
        flushQuote()
        return blocks
    }

    static func makePDFData(
        title: String,
        speaker: String,
        date: Date = Date(),
        markdown: String
    ) -> Data {
        let blocks = parseBlocks(from: markdown)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let marginX: CGFloat = 44
        let topMargin: CGFloat = 44
        let bottomLimit: CGFloat = pageRect.height - 48
        let contentWidth: CGFloat = pageRect.width - marginX * 2

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateText = dateFormatter.string(from: date)

        return renderer.pdfData { ctx in
            pdfTraitCollection.performAsCurrent {
                var pageNumber = 0
                var cursorY: CGFloat = topMargin

                func beginPageOnly() {
                    if pageNumber > 0 {
                        drawFooter(pageNumber: pageNumber, in: ctx.cgContext, marginX: marginX, contentWidth: contentWidth)
                    }
                    ctx.beginPage()
                    pageNumber += 1
                }

                func ensureSpace(_ height: CGFloat) {
                    if cursorY + height > bottomLimit && cursorY > topMargin + 8 {
                        beginPageOnly()
                        cursorY = topMargin
                    }
                }

                beginPageOnly()
                cursorY = topMargin

                // Header Block
                let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: "夜奔 · 对话记录")
                    : title
                let titleAttr = NSAttributedString(
                    string: titleText,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 18, weight: .bold),
                        .foregroundColor: pdfColor(.label)
                    ]
                )
                let titleRect = titleAttr.boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                titleAttr.draw(with: CGRect(x: marginX, y: cursorY, width: contentWidth, height: ceil(titleRect.height)),
                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                cursorY += ceil(titleRect.height) + 4

                let subtitleParts = [speaker.trimmingCharacters(in: .whitespacesAndNewlines), dateText].filter { !$0.isEmpty }
                if !subtitleParts.isEmpty {
                    let subAttr = NSAttributedString(
                        string: subtitleParts.joined(separator: "  ·  "),
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 10.5, weight: .medium),
                            .foregroundColor: pdfColor(.secondaryLabel)
                        ]
                    )
                    let subRect = subAttr.boundingRect(
                        with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        context: nil
                    )
                    subAttr.draw(with: CGRect(x: marginX, y: cursorY, width: contentWidth, height: ceil(subRect.height)),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    cursorY += ceil(subRect.height) + 8
                }

                ctx.cgContext.saveGState()
                ctx.cgContext.setStrokeColor(pdfColor(.separator).cgColor)
                ctx.cgContext.setLineWidth(0.75)
                ctx.cgContext.move(to: CGPoint(x: marginX, y: cursorY))
                ctx.cgContext.addLine(to: CGPoint(x: marginX + contentWidth, y: cursorY))
                ctx.cgContext.strokePath()
                ctx.cgContext.restoreGState()
                cursorY += 14

                for block in blocks {
                    switch block {
                    case .heading(let level, let text):
                        let size: CGFloat = level == 1 ? 15.5 : (level == 2 ? 13.8 : 12.2)
                        let para = NSMutableParagraphStyle()
                        para.lineSpacing = 3
                        let attr = NSAttributedString(
                            string: text,
                            attributes: [
                                .font: UIFont.systemFont(ofSize: size, weight: .bold),
                                .foregroundColor: pdfColor(.label),
                                .paragraphStyle: para
                            ]
                        )
                        let h = measureHeight(attr, width: contentWidth)
                        ensureSpace(h + 8)
                        cursorY += 4
                        attr.draw(with: CGRect(x: marginX, y: cursorY, width: contentWidth, height: h),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                        cursorY += h + 6

                    case .paragraph(let text):
                        let para = NSMutableParagraphStyle()
                        para.lineSpacing = 4
                        let attr = NSAttributedString(
                            string: text,
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 11.5),
                                .foregroundColor: pdfColor(.label),
                                .paragraphStyle: para
                            ]
                        )
                        drawPaginatedText(attr, startX: marginX, width: contentWidth,
                                          cursorY: &cursorY, topMargin: topMargin,
                                          bottomLimit: bottomLimit, newPage: beginPageOnly)
                        cursorY += 8

                    case .bullet(let marker, let text):
                        let indent: CGFloat = 18
                        let para = NSMutableParagraphStyle()
                        para.lineSpacing = 3.5
                        let markerAttr = NSAttributedString(
                            string: marker,
                            attributes: [
                                .font: UIFont.monospacedDigitSystemFont(ofSize: 11.2, weight: .semibold),
                                .foregroundColor: pdfColor(.secondaryLabel)
                            ]
                        )
                        let bodyAttr = NSAttributedString(
                            string: text,
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 11.5),
                                .foregroundColor: pdfColor(.label),
                                .paragraphStyle: para
                            ]
                        )
                        let h = measureHeight(bodyAttr, width: contentWidth - indent)
                        ensureSpace(min(h + 4, 48))
                        markerAttr.draw(at: CGPoint(x: marginX + 2, y: cursorY))
                        drawPaginatedText(bodyAttr, startX: marginX + indent, width: contentWidth - indent,
                                          cursorY: &cursorY, topMargin: topMargin,
                                          bottomLimit: bottomLimit, newPage: beginPageOnly)
                        cursorY += 5

                    case .quote(let text):
                        let padX: CGFloat = 12
                        let padY: CGFloat = 8
                        let innerWidth = contentWidth - padX - 8
                        let para = NSMutableParagraphStyle()
                        para.lineSpacing = 3.5
                        let attr = NSAttributedString(
                            string: text,
                            attributes: [
                                .font: UIFont.systemFont(ofSize: 11),
                                .foregroundColor: pdfColor(.secondaryLabel),
                                .paragraphStyle: para
                            ]
                        )
                        let textHeight = measureHeight(attr, width: innerWidth)
                        let totalHeight = textHeight + padY * 2
                        if totalHeight <= (bottomLimit - topMargin) {
                            ensureSpace(totalHeight + 6)
                            let box = CGRect(x: marginX, y: cursorY, width: contentWidth, height: totalHeight)
                            ctx.cgContext.saveGState()
                            let bgPath = UIBezierPath(roundedRect: box, cornerRadius: 6)
                            pdfColor(.secondarySystemFill).setFill()
                            bgPath.fill()
                            pdfColor(.systemBlue).withAlphaComponent(0.7).setFill()
                            UIBezierPath(roundedRect: CGRect(x: marginX, y: cursorY, width: 3.5, height: totalHeight), cornerRadius: 1.75).fill()
                            ctx.cgContext.restoreGState()
                            attr.draw(with: CGRect(x: marginX + padX, y: cursorY + padY, width: innerWidth, height: textHeight),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                            cursorY += totalHeight + 8
                        } else {
                            drawPaginatedText(attr, startX: marginX + padX, width: innerWidth,
                                              cursorY: &cursorY, topMargin: topMargin,
                                              bottomLimit: bottomLimit, newPage: beginPageOnly)
                            cursorY += 8
                        }

                    case .codeBlock(let language, let code):
                        let pad: CGFloat = 10
                        let headerHeight: CGFloat = language.isEmpty ? 0 : 16
                        let para = NSMutableParagraphStyle()
                        para.lineSpacing = 2.5
                        let codeAttr = NSAttributedString(
                            string: code,
                            attributes: [
                                .font: UIFont.monospacedSystemFont(ofSize: 9.8, weight: .regular),
                                .foregroundColor: pdfColor(.label),
                                .paragraphStyle: para
                            ]
                        )
                        let codeHeight = measureHeight(codeAttr, width: contentWidth - pad * 2)
                        let boxHeight = headerHeight + codeHeight + pad * 2
                        if boxHeight <= (bottomLimit - topMargin) {
                            ensureSpace(boxHeight + 8)
                            let box = CGRect(x: marginX, y: cursorY, width: contentWidth, height: boxHeight)
                            ctx.cgContext.saveGState()
                            pdfColor(.tertiarySystemFill).setFill()
                            UIBezierPath(roundedRect: box, cornerRadius: 7).fill()
                            ctx.cgContext.restoreGState()
                            var textY = cursorY + pad
                            if !language.isEmpty {
                                let langAttr = NSAttributedString(
                                    string: language.uppercased(),
                                    attributes: [
                                        .font: UIFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold),
                                        .foregroundColor: pdfColor(.secondaryLabel)
                                    ]
                                )
                                langAttr.draw(at: CGPoint(x: marginX + pad, y: textY - 2))
                                textY += headerHeight
                            }
                            codeAttr.draw(with: CGRect(x: marginX + pad, y: textY, width: contentWidth - pad * 2, height: codeHeight),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                            cursorY += boxHeight + 8
                        } else {
                            drawPaginatedText(codeAttr, startX: marginX + pad, width: contentWidth - pad * 2,
                                              cursorY: &cursorY, topMargin: topMargin,
                                              bottomLimit: bottomLimit, newPage: beginPageOnly)
                            cursorY += 8
                        }

                    case .divider:
                        ensureSpace(14)
                        cursorY += 4
                        ctx.cgContext.saveGState()
                        ctx.cgContext.setStrokeColor(pdfColor(.separator).cgColor)
                        ctx.cgContext.setLineWidth(0.5)
                        ctx.cgContext.move(to: CGPoint(x: marginX, y: cursorY))
                        ctx.cgContext.addLine(to: CGPoint(x: marginX + contentWidth, y: cursorY))
                        ctx.cgContext.strokePath()
                        ctx.cgContext.restoreGState()
                        cursorY += 10
                    }
                }

                if pageNumber > 0 {
                    drawFooter(pageNumber: pageNumber, in: ctx.cgContext, marginX: marginX, contentWidth: contentWidth)
                }
            }
        }
    }

    static func writePDFFile(
        title: String,
        speaker: String,
        date: Date = Date(),
        markdown: String
    ) throws -> URL {
        let data = makePDFData(title: title, speaker: speaker, date: date, markdown: markdown)
        let dir = try exportDirectory()
        let base = sanitizedFileName(title.isEmpty ? speaker : title)
        let url = dir.appendingPathComponent("\(base).pdf")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    @MainActor
    static func writeShareCardFile(
        title: String,
        speaker: String,
        date: Date = Date(),
        markdown: String,
        accentHex: String = "#3F6EF6",
        colorScheme: ColorScheme = .light
    ) throws -> URL? {
        let capped = markdown.count > shareCardCharacterCap
            ? String(markdown.prefix(shareCardCharacterCap)) + "\n\n…"
            : markdown
        let blocks = parseBlocks(from: capped)
        guard !blocks.isEmpty else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let cardView = SingleMessageShareCardView(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "夜奔 · 精选回复")
                : title,
            speaker: speaker,
            dateText: dateFormatter.string(from: date),
            accentHex: accentHex,
            blocks: blocks
        )
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 2.0
        guard let image = renderer.uiImage, let data = image.pngData() else {
            return nil
        }
        let dir = try exportDirectory()
        let base = sanitizedFileName(title.isEmpty ? speaker : title)
        let url = dir.appendingPathComponent("\(base).png")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    // MARK: - Helpers

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
        return cleaned.isEmpty ? "Fugue-Export" : String(cleaned.prefix(48))
    }

    private static func measureHeight(_ attr: NSAttributedString, width: CGFloat) -> CGFloat {
        let rect = attr.boundingRect(
            with: CGSize(width: max(40, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(rect.height)
    }

    private static func drawPaginatedText(
        _ attr: NSAttributedString,
        startX: CGFloat,
        width: CGFloat,
        cursorY: inout CGFloat,
        topMargin: CGFloat,
        bottomLimit: CGFloat,
        newPage: () -> Void
    ) {
        let storage = NSTextStorage(attributedString: attr)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var glyphIndex = 0
        let totalGlyphs = layoutManager.numberOfGlyphs
        if totalGlyphs == 0 { return }

        while glyphIndex < totalGlyphs {
            var remaining = bottomLimit - cursorY
            if remaining < 18 {
                newPage()
                cursorY = topMargin
                remaining = bottomLimit - cursorY
            }
            let container = NSTextContainer(size: CGSize(width: max(40, width), height: remaining))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)

            let range = layoutManager.glyphRange(for: container)
            if range.length == 0 {
                layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
                if cursorY > topMargin + 8 {
                    newPage()
                    cursorY = topMargin
                    continue
                } else {
                    break
                }
            }
            layoutManager.drawBackground(forGlyphRange: range, at: CGPoint(x: startX, y: cursorY))
            layoutManager.drawGlyphs(forGlyphRange: range, at: CGPoint(x: startX, y: cursorY))
            let usedRect = layoutManager.usedRect(for: container)
            cursorY += ceil(usedRect.height)
            glyphIndex = NSMaxRange(range)
        }
    }

    private static func drawFooter(
        pageNumber: Int,
        in cgContext: CGContext,
        marginX: CGFloat,
        contentWidth: CGFloat
    ) {
        let footer = NSAttributedString(
            string: String(localized: "夜奔 (Fugue) · 第 \(pageNumber) 页"),
            attributes: [
                .font: UIFont.systemFont(ofSize: 9),
                .foregroundColor: pdfColor(.tertiaryLabel)
            ]
        )
        let size = footer.size()
        footer.draw(at: CGPoint(x: marginX + contentWidth - size.width, y: pageRect.height - 30))
        _ = cgContext
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    private static func parseBullet(_ line: String) -> (String, String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return ("•", String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        if let dotIdx = line.firstIndex(of: "."), dotIdx > line.startIndex {
            let prefix = String(line[..<dotIdx])
            let after = line[line.index(after: dotIdx)...]
            if prefix.allSatisfy(\.isNumber), after.first == " " {
                return ("\(prefix).", String(after.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { !$0.isWhitespace }
        guard chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == "-" } || chars.allSatisfy { $0 == "*" } || chars.allSatisfy { $0 == "_" }
    }

    private static func cleanInline(_ raw: String) -> String {
        let formatted = PlainTextFormatter.format(raw)
        return formatted.isEmpty ? raw : formatted
    }
}

private struct SingleMessageShareCardView: View {
    let title: String
    let speaker: String
    let dateText: String
    let accentHex: String
    let blocks: [MessageExportBlock]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let paperBg = isDark
            ? Color(red: 0.067, green: 0.075, blue: 0.094)
            : Color(red: 0.980, green: 0.969, blue: 0.941)
        let subtleBg = isDark
            ? Color(red: 0.102, green: 0.114, blue: 0.141)
            : Color(red: 0.945, green: 0.929, blue: 0.894)
        let vermilion = isDark
            ? Color(red: 0.886, green: 0.494, blue: 0.369)
            : Color(red: 0.737, green: 0.243, blue: 0.141)
        let accent = accentHex.isEmpty ? vermilion : Color(hex: accentHex)
        let border = isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.09)

        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 10) {
                FugueSealMark(character: "奔", size: 28, theme: .vermilion)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16.5, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text([speaker, dateText].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider().overlay(border)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let level, let text):
                        Text(text)
                            .font(.system(size: level == 1 ? 17 : (level == 2 ? 15.5 : 14.5), weight: .bold, design: .serif))
                            .foregroundStyle(.primary)
                            .padding(.top, 2)
                    case .paragraph(let text):
                        Text(text)
                            .font(.system(size: 14.5, design: .serif))
                            .foregroundStyle(.primary)
                            .lineSpacing(5)
                    case .bullet(let marker, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(marker)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accent)
                            Text(text)
                                .font(.system(size: 14.5, design: .serif))
                                .foregroundStyle(.primary)
                                .lineSpacing(4.5)
                        }
                    case .quote(let text):
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(vermilion.opacity(0.8))
                                .frame(width: 3)
                            Text(text)
                                .font(.system(size: 13.5, design: .serif))
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(subtleBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    case .codeBlock(let language, let code):
                        VStack(alignment: .leading, spacing: 4) {
                            if !language.isEmpty {
                                Text(language.uppercased())
                                    .font(.caption2.monospaced().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(code)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(subtleBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(border, lineWidth: 1)
                        )
                    case .divider:
                        Divider().overlay(border).padding(.vertical, 2)
                    }
                }
            }

            Divider().overlay(border)

            HStack(spacing: 8) {
                FugueSealMark(character: "夜", size: 16, theme: .vermilion)
                Text("夜奔 (Fugue) · 本地直连 AI 书笺")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
        .background(paperBg)
        .overlay(alignment: .top) {
            Rectangle().fill(vermilion).frame(height: 3.5)
        }
    }
}
