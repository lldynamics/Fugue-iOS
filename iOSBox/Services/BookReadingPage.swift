import Foundation

struct ReadingCitation: Equatable, Sendable {
    let volumeID: UUID
    let documentTitle: String
    let chapter: String
    let chapterIndex: Int?
    let utf16Offset: Int?
    let excerpt: String
    var number: Int

    init(_ passage: KnowledgePassage) {
        volumeID = passage.volumeID
        documentTitle = passage.documentTitle
        chapter = passage.sectionTitle
        chapterIndex = passage.chapterIndex
        utf16Offset = passage.utf16Offset
        excerpt = passage.excerpt
        number = passage.id
    }

    init(_ part: BookExcerpt, in volumeID: UUID, number: Int, documentTitle: String = "") {
        self.volumeID = volumeID
        self.documentTitle = documentTitle
        chapter = part.chapter
        chapterIndex = part.chapterIndex
        utf16Offset = part.utf16Offset
        excerpt = part.text
        self.number = number
    }

    var marker: String {
        Self.marker(document: documentTitle, chapter: chapter, index: chapterIndex, offset: utf16Offset)
    }

    static func validLocation(index: Int?, offset: Int?) -> (index: Int, offset: Int)? {
        guard let index, let offset, (0..<BookManuscript.maximumChapters).contains(index),
              (0..<BookManuscript.maximumTextBytes).contains(offset) else { return nil }
        return (index, offset)
    }

    /// The location still identifies the same passage if a later tool call reorders search results.
    static func marker(document: String, chapter: String, index: Int?, offset: Int?) -> String {
        let location = validLocation(index: index, offset: offset).map { " #\($0.index + 1).\($0.offset)" } ?? ""
        func label(_ title: String) -> String {
            let replacements: [Character: Character] = ["[": "［", "]": "］", "*": "＊", "_": "＿",
                                                        "`": "｀", "\\": "＼", "|": "｜", "<": "＜", ">": "＞", "&": "＆"]
            return String(title.map { replacements[$0] ?? $0 }).split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        return "[\(label(document)) · \(label(chapter))\(location)]"
    }
}

struct ReadingRequest {
    let id = UUID()
    var chapter: Int?
    var citation: ReadingCitation?
}

struct BookReadingPlace {
    var volumeID: UUID?
    var chapter = 0
    var paragraph: Int? = 0
    var lastRequest: UUID?
}

struct BookReadingPage: Sendable {
    struct Paragraph: Identifiable, Sendable {
        let id: Int
        let text: String
        let highlight: NSRange?
        let endsCitation: Bool
    }
    let chapterIndex: Int
    let paragraphs: [Paragraph]
    let located: Bool

    func clampedParagraph(_ preferred: Int?) -> Int {
        min(max(0, preferred ?? 0), paragraphs.last?.id ?? 0)
    }

    static func chapters(from data: Data, through limit: Int?) throws -> [BookChapter] {
        let all = try JSONDecoder().decode([BookChapter].self, from: data)
        guard !all.isEmpty else { throw BookImportError.invalidBook }
        if let limit {
            guard all.indices.contains(limit) else { throw BookImportError.invalidBook }
            return Array(all.prefix(limit + 1))
        }
        return all
    }

    /// Old backups contain titles and quotes only. An ambiguous match must never jump to
    /// an arbitrary occurrence, and the caller supplies only chapters within the reading scope.
    static func make(chapters: [BookChapter], preferred: Int, citation: ReadingCitation?) throws -> Self {
        guard !chapters.isEmpty else { throw BookImportError.invalidBook }
        var index = min(max(0, preferred), chapters.count - 1)
        let match = try citation.flatMap { try locate($0, in: chapters) }
        if let match { index = match.chapter }
        let source = chapters[index].text
        var paragraphs: [Paragraph] = []
        var previousEnd = source.startIndex
        var utf16End = 0
        for line in source.split(whereSeparator: \.isNewline) {
            var remaining = line[...]
            utf16End += source[previousEnd..<line.startIndex].utf16.count
            while !remaining.isEmpty {
                try Task.checkCancellation()
                let chunk = remaining.prefix(720)
                let length = chunk.utf16.count
                let overlap = match.map { NSIntersectionRange($0.range, NSRange(location: utf16End, length: length)) }
                let local = overlap.flatMap { $0.length > 0 ? NSRange(location: $0.location - utf16End, length: $0.length) : nil }
                let endsCitation = match.map { local != nil && NSMaxRange($0.range) <= utf16End + length } ?? false
                paragraphs.append(.init(id: paragraphs.count, text: String(chunk), highlight: local, endsCitation: endsCitation))
                utf16End += length
                remaining = remaining[chunk.endIndex...]
            }
            previousEnd = line.endIndex
        }
        return Self(chapterIndex: index, paragraphs: paragraphs, located: match != nil)
    }

    private static func locate(_ citation: ReadingCitation, in chapters: [BookChapter]) throws -> (chapter: Int, range: NSRange)? {
        let pieces = citation.excerpt.split(whereSeparator: \.isWhitespace)
        guard !pieces.isEmpty else { return nil }
        let pattern = pieces.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        let regex = try NSRegularExpression(pattern: pattern)
        var found: (Int, NSRange)?
        for i in chapters.indices where chapters[i].title == citation.chapter {
            try Task.checkCancellation()
            if let exact = citation.chapterIndex, exact != i { continue }
            let text = chapters[i].text
            let length = text.utf16.count
            if let offset = citation.utf16Offset {
                guard (0..<length).contains(offset),
                      let result = regex.firstMatch(in: text, options: .anchored, range: NSRange(location: offset, length: length - offset)) else { continue }
                return (i, result.range)
            }
            var ambiguous = false
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: length)) { result, _, stop in
                guard let result else { return }
                if found != nil { ambiguous = true; stop.pointee = true }
                else { found = (i, result.range) }
            }
            if ambiguous { return nil }
        }
        return found
    }
}
