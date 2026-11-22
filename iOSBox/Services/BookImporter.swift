import CoreFoundation
import Foundation
import PDFKit

enum BookImporter {
    static let maximumFileBytes = 64 * 1_024 * 1_024

    static func read(_ url: URL) throws -> PreparedBook {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= maximumFileBytes else { throw BookImportError.fileLimit }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let part = try file.read(upToCount: 256 * 1_024), !part.isEmpty {
            try Task.checkCancellation()
            guard data.count <= maximumFileBytes - part.count else { throw BookImportError.fileLimit }
            data.append(part)
        }
        return try PreparedBook(parse(data, filename: url.lastPathComponent))
    }

    static func parse(_ data: Data, filename: String) throws -> BookManuscript {
        guard data.count <= maximumFileBytes else { throw BookImportError.fileLimit }
        let file = URL(fileURLWithPath: filename)
        let title = String(file.deletingPathExtension().lastPathComponent.prefix(300))
        switch file.pathExtension.lowercased() {
        case "epub": return try EPUBBookReader.read(data, fallbackTitle: title)
        case "docx", "xlsx", "pptx":
            return try OfficeDocumentReader.extractChapters(from: data, ext: file.pathExtension, fallbackTitle: title)
        case "pdf":
            guard let pdf = PDFDocument(data: data) else { throw BookImportError.invalidBook }
            guard !pdf.isLocked, pdf.allowsCopying else { throw BookImportError.locked }
            guard pdf.pageCount <= BookManuscript.maximumChapters else { throw BookImportError.textLimit }
            var pages: [BookChapter] = [], size = 0, ocrPagesUsed = 0
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let pageText: String = autoreleasepool {
                    guard let pdfPage = pdf.page(at: index) else { return "" }
                    var text = pdfPage.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty && ocrPagesUsed < 120 {
                        ocrPagesUsed += 1
                        text = PDFOCRService.recognizeText(on: pdfPage)
                    }
                    return text
                }
                guard !pageText.isEmpty else { continue }
                size += pageText.utf8.count
                guard size <= BookManuscript.maximumTextBytes else { throw BookImportError.textLimit }
                pages.append(BookChapter(title: String(localized: "第 \(index + 1) 页"), text: pageText))
            }
            guard !pages.isEmpty else { throw BookImportError.noText }
            return BookManuscript(title: title, chapters: pages)
        case "txt", "md", "markdown", "text":
            guard let raw = decodeText(data), !raw.contains("\0") else { throw BookImportError.noText }
            let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw BookImportError.noText }
            guard text.utf8.count <= BookManuscript.maximumTextBytes else { throw BookImportError.textLimit }
            return try BookManuscript(title: title, chapters: splitChapters(text))
        default: throw BookImportError.fileType
        }
    }

    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16) }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }

    static func splitChapters(_ text: String) throws -> [BookChapter] {
        let heading = try NSRegularExpression(pattern: #"^(?:#{1,4}\s+\S|第[〇零一二三四五六七八九十百千万两\d壹贰叁肆伍陆柒捌玖拾佰仟]+[章节回卷部篇]|(?:chapter|part|book)\s+(?:\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\b|序章$|楔子$|尾声$|后记$)"#, options: .caseInsensitive)
        var result: [BookChapter] = [], title = String(localized: "正文"), body = ""
        func flush() {
            let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { result.append(BookChapter(title: title, text: cleaned)) }
            body.removeAll(keepingCapacity: true)
        }
        var start = text.startIndex
        while start < text.endIndex {
            try Task.checkCancellation()
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let raw = text[start..<end]
            start = end == text.endIndex ? end : text.index(after: end)
            if raw.utf8.count <= 300 {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    flush()
                    title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    guard result.count < BookManuscript.maximumChapters else { throw BookImportError.textLimit }
                    continue
                }
            }
            body.append(contentsOf: raw)
            body.append("\n")
        }
        flush()
        guard !result.isEmpty else { throw BookImportError.noText }
        return result
    }
}
