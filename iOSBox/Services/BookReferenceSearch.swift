import CryptoKit
import Foundation
import NaturalLanguage

/// A per-character hybrid index (IDF-weighted CJK/Latin lexical + cached semantic vectors + RRF fusion)
/// over the selected reading range, built off the main actor.
actor BookReferenceSearch {
    static let shared = BookReferenceSearch()
    private static let maxCachedSemanticScenes = 600

    private struct Scene {
        let excerpt: BookExcerpt
        let voiced: Bool
        let chapterIndex: Int
        let tokens: Set<String>
    }

    private var cachedFriend: BookFriend?
    private var cachedManuscriptDigest: Data?
    private var cachedScenes: [Scene] = []
    private var cachedLocalLanguage: String?
    private var cachedLocalVectors: [Int: [Float]] = [:]
    private var cachedCloudModelKey: String?
    private var cachedCloudVectors: [Int: [Float]] = [:]

    func invalidate(bookID: UUID) {
        if cachedFriend?.bookID == bookID {
            cachedFriend = nil
            cachedManuscriptDigest = nil
            cachedScenes.removeAll(keepingCapacity: false)
            cachedLocalLanguage = nil
            cachedLocalVectors.removeAll(keepingCapacity: false)
            cachedCloudModelKey = nil
            cachedCloudVectors.removeAll(keepingCapacity: false)
        }
    }

    func reference(
        for friend: BookFriend,
        manuscript: Data,
        question: String,
        embeddingConfig: EmbeddingConfig? = nil,
        embeddingSession: URLSession? = nil
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
            cachedLocalLanguage = nil
            cachedLocalVectors.removeAll(keepingCapacity: true)
            cachedCloudVectors.removeAll(keepingCapacity: true)
            cachedCloudModelKey = nil
        }

        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let excludedNameTerms = Set(([friend.name] + friend.aliases).flatMap { Self.sceneTokens(in: $0) })
        let queryTerms = Self.sceneTokens(in: String(cleanQuestion.suffix(400)))
            .subtracting(excludedNameTerms)
            .sorted()
            .prefix(32)

        // 1. Channel A: IDF-weighted lexical scoring over all character scenes.
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
        let lexicalIDs = lexicalRanked.prefix(60).map { String($0.index) }

        // 2. Channel B: Cached dense semantic vectors (optional Embedding API -> local NLEmbedding fallback).
        var semanticIDs: [String] = []
        var usedCloudVectors = false
        if !cleanQuestion.isEmpty {
            if let embeddingConfig {
                if let cloud = try? await rankViaCloudEmbeddings(
                    query: cleanQuestion,
                    config: embeddingConfig,
                    session: embeddingSession
                ), !cloud.isEmpty {
                    semanticIDs = cloud
                    usedCloudVectors = true
                }
            }
            if !usedCloudVectors {
                semanticIDs = try rankViaCachedLocalEmbeddings(query: cleanQuestion)
            }
        }

        // 3. Fuse via Reciprocal Rank Fusion (RRF) + voiced dialogue & chapter diversity bonus.
        let fused = RAGHybridRanker.fuseRRF(
            lexicalRankedIDs: lexicalIDs,
            semanticRankedIDs: semanticIDs,
            k: RAGHybridRanker.defaultRRFK,
            lexicalWeight: 1.0,
            semanticWeight: usedCloudVectors ? 1.1 : 0.75
        )

        var scores = [Double](repeating: 0, count: cachedScenes.count)
        for i in cachedScenes.indices {
            let base = fused[String(i)] ?? 0.0
            let voiceTieBreak = cachedScenes[i].voiced ? 0.0025 : 0.0
            scores[i] = base + voiceTieBreak
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

    private func rankViaCloudEmbeddings(
        query: String,
        config: EmbeddingConfig,
        session: URLSession?
    ) async throws -> [String] {
        if cachedCloudModelKey != config.cacheKey {
            cachedCloudModelKey = config.cacheKey
            cachedCloudVectors.removeAll(keepingCapacity: true)
        }
        let budget = min(cachedScenes.count, 128)
        let strideStep = max(1, cachedScenes.count / max(1, budget))
        var missingIndices: [Int] = []
        for idx in stride(from: 0, to: cachedScenes.count, by: strideStep) {
            if missingIndices.count + cachedCloudVectors.count >= budget { break }
            if cachedCloudVectors[idx] == nil {
                missingIndices.append(idx)
            }
        }
        if !missingIndices.isEmpty {
            let texts = missingIndices.map { cachedScenes[$0].excerpt.text }
            let vectors = try await EmbeddingClient.embed(texts: texts, config: config, session: session)
            for (idx, vec) in zip(missingIndices, vectors) {
                cachedCloudVectors[idx] = vec
            }
        }
        guard let queryVec = try await EmbeddingClient.embed(
            texts: [String(query.suffix(400))],
            config: config,
            session: session
        ).first else { return [] }

        var scored: [(index: Int, sim: Double)] = []
        for (idx, vec) in cachedCloudVectors {
            let sim = EmbeddingClient.dotSimilarity(queryVec, vec)
            if sim > 0.24 {
                scored.append((idx, sim))
            }
        }
        scored.sort { $0.sim > $1.sim }
        return scored.prefix(40).map { String($0.index) }
    }

    private func rankViaCachedLocalEmbeddings(query: String) throws -> [String] {
        guard let (langKey, emb) = Self.sentenceEmbedding(for: query),
              let rawQueryVec = emb.vector(for: String(query.suffix(300))),
              let queryVec = try? EmbeddingClient.normalizeVector(rawQueryVec.map(Float.init)) else {
            return []
        }
        if cachedLocalLanguage != langKey {
            cachedLocalLanguage = langKey
            cachedLocalVectors.removeAll(keepingCapacity: true)
        }
        if cachedLocalVectors.isEmpty {
            let budget = min(cachedScenes.count, Self.maxCachedSemanticScenes)
            let strideStep = max(1, cachedScenes.count / max(1, budget))
            var count = 0
            for idx in stride(from: 0, to: cachedScenes.count, by: strideStep) {
                if count >= budget { break }
                if count.isMultiple(of: 32) { try Task.checkCancellation() }
                if let raw = emb.vector(for: String(cachedScenes[idx].excerpt.text.prefix(280))),
                   let norm = try? EmbeddingClient.normalizeVector(raw.map(Float.init)) {
                    cachedLocalVectors[idx] = norm
                }
                count += 1
            }
        }
        var scored: [(index: Int, sim: Double)] = []
        for (idx, vec) in cachedLocalVectors where vec.count == queryVec.count {
            let sim = EmbeddingClient.dotSimilarity(queryVec, vec)
            if sim > 0.30 {
                scored.append((idx, sim))
            }
        }
        scored.sort { $0.sim > $1.sim }
        return scored.prefix(40).map { String($0.index) }
    }

    private static func sceneTokens(in text: String) -> Set<String> {
        var tokens = PersonaMaterials.terms(in: text)
        for token in SearchTokenizer.indexText(text, maxCharacters: 2_000).split(separator: " ") where token.count >= 2 {
            tokens.insert(String(token))
        }
        return tokens
    }

    private static func sentenceEmbedding(for text: String) -> (String, NLEmbedding)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(200)))
        if let lang = recognizer.dominantLanguage, let emb = NLEmbedding.sentenceEmbedding(for: lang) {
            return (lang.rawValue, emb)
        }
        if let zh = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) {
            return (NLLanguage.simplifiedChinese.rawValue, zh)
        }
        if let en = NLEmbedding.sentenceEmbedding(for: .english) {
            return (NLLanguage.english.rawValue, en)
        }
        return nil
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
