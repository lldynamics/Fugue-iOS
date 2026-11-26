import Foundation

/// Only explicit markers backed by this reply's saved evidence can open the reader.
struct ReadingReferences: Equatable, Sendable {
    let sources: [ReadingCitation]
    private var markers: [String: [Int]] = [:]
    private static let brackets = try! NSRegularExpression(pattern: #"\[[^\[\]\r\n]+\]"#)
    static let linkScheme = "iosbox-reading"

    init(knowledge: KnowledgeEvidence? = nil, book: BookReplyEvidence? = nil, friend: BookFriend? = nil,
         limits: [UUID: Int] = [:]) {
        var candidates = (knowledge?.passages ?? []).map(ReadingCitation.init)
        if let book, let friend {
            for part in book.excerpts {
                candidates.append(ReadingCitation(part, in: friend.bookID, number: 0, documentTitle: book.title))
            }
        }
        var items: [ReadingCitation] = []
        for var item in candidates {
            if let friend, item.volumeID != friend.bookID { continue }
            if let limit = limits[item.volumeID],
               !(item.chapterIndex.map { $0 >= 0 && $0 <= limit } ?? false) { continue }
            guard !items.contains(where: { $0.volumeID == item.volumeID && $0.chapter == item.chapter &&
                $0.chapterIndex == item.chapterIndex && $0.utf16Offset == item.utf16Offset && $0.excerpt == item.excerpt
            }) else { continue }
            item.number = items.count + 1
            items.append(item)
        }
        sources = items
        for (index, item) in sources.enumerated() {
            // Older prompts asked for [Document · Section]. Some models retained the word Document.
            for marker in Set([item.marker, "[\(item.documentTitle) · \(item.chapter)]", "[Document · \(item.chapter)]"]) {
                markers[Self.normalized(marker), default: []].append(index)
            }
        }
    }

    private static func normalized(_ marker: String) -> String {
        marker.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func source(for url: URL) -> ReadingCitation? {
        guard url.scheme == Self.linkScheme, url.host == "passage",
              let index = Int(url.lastPathComponent), sources.indices.contains(index) else { return nil }
        return sources[index]
    }

    /// True when `text` links every source with an unambiguous inline marker (rendered as 〔原文 n〕).
    func citesAllSources(in text: String) -> Bool {
        guard !sources.isEmpty, text.contains("[") else { return false }
        var cited = Set<Int>()
        for match in Self.brackets.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text),
                  let matches = markers[Self.normalized(String(text[range]))],
                  matches.count == 1, let index = matches.first else { continue }
            cited.insert(index)
        }
        return cited.count == sources.count
    }

    func linkingMarkers(in original: AttributedString) -> AttributedString {
        guard !sources.isEmpty else { return original }
        var result = AttributedString()
        for run in original.runs {
            let slice = original[run.range]
            if run.link?.scheme == Self.linkScheme {
                var unlinked = AttributedString(slice)
                unlinked.link = nil
                result += unlinked
                continue
            }
            guard run.link == nil, run.inlinePresentationIntent?.contains(.code) != true,
                  slice.characters.contains("[") else {
                result += AttributedString(slice)
                continue
            }
            let text = String(slice.characters)
            var cursor = text.startIndex
            for match in Self.brackets.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text),
                      let matches = markers[Self.normalized(String(text[range]))],
                      matches.count == 1, let index = matches.first else { continue }
                result += AttributedString(String(text[cursor..<range.lowerBound]), attributes: run.attributes)
                var label = AttributedString(String(localized: "〔原文 \(sources[index].number)〕"), attributes: run.attributes)
                label.link = URL(string: "\(Self.linkScheme)://passage/\(index)")
                result += label
                cursor = range.upperBound
            }
            result += AttributedString(String(text[cursor...]), attributes: run.attributes)
        }
        return result
    }
}
