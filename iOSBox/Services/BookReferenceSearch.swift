import Foundation
import NaturalLanguage

/// A per-character index over the whole selected reading range, built off the main actor.
actor BookReferenceSearch {
    static let shared = BookReferenceSearch()
    private struct Scene {
        let excerpt: BookExcerpt
        let voiced: Bool
        let chapterIndex: Int
    }
    private var cachedFriend: BookFriend?
    private var cachedScenes: [Scene] = []

    func reference(for friend: BookFriend, manuscript: Data, question: String) throws -> BookReplyEvidence {
        try Task.checkCancellation()
        if cachedFriend != friend {
            let chapters = try JSONDecoder().decode([BookChapter].self, from: manuscript)
            let scenes = try build(chapters: chapters, friend: friend)
            guard !scenes.isEmpty else { throw BookImportError.noMatches }
            cachedFriend = friend
            cachedScenes = scenes
        }
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = PersonaMaterials.terms(in: String(cleanQuestion.suffix(400)))
            .subtracting(([friend.name] + friend.aliases).flatMap { PersonaMaterials.terms(in: $0) })
            .sorted().prefix(28)
        var scores = [Double](repeating: 0, count: cachedScenes.count)
        var lexicalMatchCount = 0
        for (i, scene) in cachedScenes.enumerated() {
            if i.isMultiple(of: 128) { try Task.checkCancellation() }
            var score = Double(scene.voiced ? 1 : 0)
            var lexicalHits = 0
            for term in terms where scene.excerpt.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                score += 4.0
                lexicalHits += 1
            }
            if lexicalHits > 0 { lexicalMatchCount += 1 }
            scores[i] = score
        }
        // Only compute sentence embeddings when lexical search did not find enough scenes,
        // and bound sampled scenes so huge novels stay responsive.
        if lexicalMatchCount < 3,
           !cleanQuestion.isEmpty,
           let emb = Self.sentenceEmbedding(for: cleanQuestion),
           let queryVector = emb.vector(for: String(cleanQuestion.suffix(300))) {
            let maxSemanticScenes = 180
            let zeroIndices = cachedScenes.indices.filter { scores[$0] <= 1.0 }
            let strideStep = max(1, zeroIndices.count / maxSemanticScenes)
            var sampled = 0
            for pos in stride(from: 0, to: zeroIndices.count, by: strideStep) {
                guard sampled < maxSemanticScenes else { break }
                if sampled.isMultiple(of: 24) { try Task.checkCancellation() }
                let idx = zeroIndices[pos]
                if let sceneVector = emb.vector(for: String(cachedScenes[idx].excerpt.text.prefix(260))) {
                    let sim = Self.cosineSimilarity(queryVector, sceneVector)
                    if sim > 0.35 {
                        scores[idx] += sim * 2.5
                    }
                }
                sampled += 1
            }
        }
        var chosen: [BookExcerpt] = [], usedChapters = Set<Int>(), used = Set<Int>()
        while chosen.count < min(3, scores.count) {
            var best: Int?, bestValue = -1.0
            for i in scores.indices where !used.contains(i) {
                let value = scores[i] * 2.0 + (usedChapters.contains(cachedScenes[i].chapterIndex) ? 0.0 : 1.0)
                if value > bestValue { best = i; bestValue = value }
            }
            guard let best else { break }
            used.insert(best)
            usedChapters.insert(cachedScenes[best].chapterIndex)
            chosen.append(cachedScenes[best].excerpt)
        }
        return BookReplyEvidence(name: friend.name, title: friend.bookTitle, excerpts: chosen)
    }

    private static func sentenceEmbedding(for text: String) -> NLEmbedding? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(200)))
        if let lang = recognizer.dominantLanguage, let emb = NLEmbedding.sentenceEmbedding(for: lang) {
            return emb
        }
        return NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) ?? NLEmbedding.sentenceEmbedding(for: .english)
    }

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = (normA.squareRoot() * normB.squareRoot())
        guard denom > 1e-9 else { return 0 }
        return dot / denom
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
                        scenes.append(Scene(excerpt: BookExcerpt(id: scenes.count, chapter: chapter.title, text: excerpt, chapterIndex: chapterIndex,
                                                                utf16Offset: offset + chunk.prefix(while: \.isWhitespace).utf16.count),
                                            voiced: speech.firstMatch(in: body, range: range) != nil, chapterIndex: chapterIndex))
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
