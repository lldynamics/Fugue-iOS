import CryptoKit
import Foundation

/// A per-character lexical index (IDF-weighted CJK/Latin) over the selected reading range, built off the main actor.
actor BookReferenceSearch {
    static let shared = BookReferenceSearch()

    private struct Scene {
        let excerpt: BookExcerpt
        let voiced: Bool
        let chapterIndex: Int
        let tokens: Set<String>
    }

    private var cachedFriend: BookFriend?
    private var cachedManuscriptDigest: Data?
    private var cachedScenes: [Scene] = []

    func invalidate(bookID: UUID) {
        if cachedFriend?.bookID == bookID {
            cachedFriend = nil
            cachedManuscriptDigest = nil
            cachedScenes.removeAll(keepingCapacity: false)
        }
    }

    func reference(
        for friend: BookFriend,
        manuscript: Data,
        question: String
    ) async throws -> BookReplyEvidence {
        try Task.checkCancellation()
        let digest = Data(SHA256.hash(data: manuscript))
        if cachedFriend != friend || cachedManuscriptDigest != digest {
            let chapters = try JSONDecoder().decode([BookChapter].self, from: manuscript)
            let scenes = try build(chapters: chapters, friend: friend)
            guard !scenes.isEmpty else { throw BookImportError.noMatches }
            cachedFriend = friend
            cachedManuscriptDigest = digest
            cachedScenes = scenes
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let excludedNameTerms = Set(([friend.name] + friend.aliases).flatMap { Self.sceneTokens(in: $0) })
        let queryTerms = Self.sceneTokens(in: String(cleanQuestion.suffix(400)))
            .subtracting(excludedNameTerms)
            .sorted()
            .prefix(32)

        // IDF-weighted lexical scoring over all character scenes.
        var termDocFreq: [String: Int] = [:]
        if !queryTerms.isEmpty {
            for scene in cachedScenes {
                for term in queryTerms where scene.tokens.contains(term) {
                    termDocFreq[term, default: 0] += 1
                }
            }
        }
        let totalScenes = Double(max(cachedScenes.count, 1))
        var lexicalRanked: [(index: Int, score: Double)] = []
        for (i, scene) in cachedScenes.enumerated() {
            if i.isMultiple(of: 128) { try Task.checkCancellation() }
            var score = 0.0
            for term in queryTerms where scene.tokens.contains(term) {
                let df = Double(max(termDocFreq[term] ?? 1, 1))
                let idf = 1.0 + log(max(1.0, totalScenes / df))
                score += 2.5 * idf
            }
            if score > 0 {
                if scene.voiced { score += 1.2 }
                lexicalRanked.append((i, score))
            }
        }
        lexicalRanked.sort { $0.score > $1.score }

        var scores = [Double](repeating: 0, count: cachedScenes.count)
        for (rank, entry) in lexicalRanked.prefix(60).enumerated() {
            scores[entry.index] = 1.0 / (60.0 + Double(rank + 1))
        }
        for i in cachedScenes.indices where cachedScenes[i].voiced {
            scores[i] += 0.0025
        }

        var chosen: [BookExcerpt] = [], usedChapters = Set<Int>(), used = Set<Int>()
        while chosen.count < min(3, scores.count) {
            var best: Int?, bestValue = -1.0
            for i in scores.indices where !used.contains(i) {
                let diversity = usedChapters.contains(cachedScenes[i].chapterIndex) ? 0.0 : 0.003
                let value = scores[i] + diversity
                if value > bestValue { best = i; bestValue = value }
            }
            guard let best else { break }
            used.insert(best)
            usedChapters.insert(cachedScenes[best].chapterIndex)
            chosen.append(cachedScenes[best].excerpt)
        }
        return BookReplyEvidence(name: friend.name, title: friend.bookTitle, excerpts: chosen)
    }

    private static func sceneTokens(in text: String) -> Set<String> {
        var tokens = PersonaMaterials.terms(in: text)
        for token in SearchTokenizer.indexText(text, maxCharacters: 2_000).split(separator: " ") where token.count >= 2 {
            tokens.insert(String(token))
        }
        return tokens
    }

    private func build(chapters: [BookChapter], friend: BookFriend) throws -> [Scene] {
        let names = ([friend.name] + friend.aliases).filter { !$0.isEmpty && $0.count <= 60 }.prefix(9)
        guard !names.isEmpty else { throw BookImportError.name }
        let alternatives = names.map { name in
            let literal = NSRegularExpression.escapedPattern(for: name)
            return name.unicodeScalars.allSatisfy(\.isASCII) ? "(?<![A-Za-z0-9_])\(literal)(?![A-Za-z0-9_])" : literal
        }.joined(separator: "|")
        let person = "(?:\(alternatives))"
        let mentioned = try NSRegularExpression(pattern: person, options: .caseInsensitive)
        let speech = try NSRegularExpression(pattern: person + #"(?:[：:]|[，,\s]*(?:(?:低声|轻声|笑着|轻轻|又)?[说问答道喊]|said\b|asked\b|replied\b))"#, options: .caseInsensitive)
        var scenes: [Scene] = []
        let last = friend.throughChapter ?? chapters.count - 1
        guard chapters.indices.contains(last) else { throw BookImportError.invalidBook }
        for chapterIndex in 0...last {
            try Task.checkCancellation()
            let chapter = chapters[chapterIndex]
            let lines = chapter.text.split(whereSeparator: \.isNewline)
            var previousStart = chapter.text.startIndex
            var lineOffset = 0
            for i in lines.indices {
                lineOffset += chapter.text[previousStart..<lines[i].startIndex].utf16.count
                previousStart = lines[i].startIndex
                var offset = lineOffset
                var rest = lines[i][...]
                while !rest.isEmpty {
                    try Task.checkCancellation()
                    let chunk = rest.prefix(420)
                    let complete = chunk.endIndex == rest.endIndex
                    let body = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    let range = NSRange(body.startIndex..., in: body)
                    if mentioned.firstMatch(in: body, range: range) != nil {
                        var excerpt = body
                        if complete, body.count < 230, i + 1 < lines.count {
                            let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                            if let first = next.first, "“「『\"—".contains(first) { excerpt += "\n" + next.prefix(420 - body.count - 1) }
                        }
                        scenes.append(Scene(
                            excerpt: BookExcerpt(
                                id: scenes.count,
                                chapter: chapter.title,
                                text: excerpt,
                                chapterIndex: chapterIndex,
                                utf16Offset: offset + chunk.prefix(while: \.isWhitespace).utf16.count
                            ),
                            voiced: speech.firstMatch(in: body, range: range) != nil,
                            chapterIndex: chapterIndex,
                            tokens: Self.sceneTokens(in: excerpt)
                        ))
                    }
                    if complete { break }
                    let next = chunk.index(chunk.endIndex, offsetBy: -62)
                    offset += rest[..<next].utf16.count
                    rest = rest[next...]
                }
            }
        }
        return scenes
    }
}
