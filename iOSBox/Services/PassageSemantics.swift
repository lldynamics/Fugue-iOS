import Foundation
import NaturalLanguage
import Accelerate

struct PassageSemantics {

    private static let equivalents = [
        ["逾期交付", "晚交货", "交货晚", "延期交货", "迟延交付"],
        ["违约责任", "违约后果", "违约怎么办"], ["截止日期", "最后期限", "最迟什么时候"],
        ["付款", "付钱", "支付款项"], ["离职", "辞职", "辞去工作"],
        ["延期", "推迟", "延后"], ["refund", "reimbursement", "money back"]
    ]

    static func language(for query: String) -> NLLanguage {
        NLLanguageRecognizer.dominantLanguage(for: query) ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english)
    }
    static func contextualModel(for query: String) -> NLContextualEmbedding? {
        NLContextualEmbedding(language: language(for: query))
    }
    private static func contextualVector(_ text: String, model: NLContextualEmbedding?, language: NLLanguage) -> [Double]? {
        guard let model, model.hasAvailableAssets, let result = try? model.embeddingResult(for: text, language: language) else { return nil }
        var sum = Array(repeating: 0.0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            guard vector.count == sum.count else { return true }
            for i in sum.indices { sum[i] += vector[i] }
            count += 1
            return true
        }
        return count == 0 ? nil : sum.map { $0 / Double(count) }
    }

    struct Scorer {
        let model: String?
        let evaluate: (String, [Float]?) -> (score: Double, computed: [Float]?)
    }

    /// Distinguish passages whose Chinese sentence vectors all have high cosine similarity.
    /// Called only on the shortlist. Word vectors are unit-normalized once per query.
    static func chineseWordScore(for query: String) -> ((String) -> Double?)? {
        let language = language(for: query)
        guard [.simplifiedChinese, .traditionalChinese].contains(language),
              let embedding = NLEmbedding.wordEmbedding(for: language) else { return nil }
        let stop: Set<String> = ["的", "了", "是", "在", "有", "时", "做", "要", "去", "才", "并", "再", "给",
                                 "应该", "怎样", "怎么", "如何", "什么", "时候", "需要", "可以", "哪里", "什么时候"]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(language)
        var cache: [String: [Float]] = [:]
        func vectors(_ text: String, limit: Int) -> [[Float]] {
            tokenizer.string = text
            var found: [[Float]] = []
            var seen = Set<String>()
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let word = String(text[range])
                guard seen.insert(word).inserted, !stop.contains(word) else { return true }
                if let cached = cache[word] { found.append(cached) }
                else if let v = embedding.vector(for: word)?.map(Float.init) {
                    let norm = sqrt(vDSP.dot(v, v))
                    if norm > 0 {
                        let unit = vDSP.divide(v, norm)
                        found.append(unit)
                        if cache.count < 1024 { cache[word] = unit }
                    }
                }
                return found.count < limit
            }
            return found
        }
        let queryWords = vectors(query, limit: 12)
        guard !queryWords.isEmpty else { return nil }
        return { text in
            let passageWords = vectors(text, limit: 96)
            guard !passageWords.isEmpty else { return nil }
            let sum = queryWords.reduce(Float.zero) { total, queryWord in
                total + passageWords.reduce(Float.zero) { max($0, vDSP.dot(queryWord, $1)) }
            }
            return Double(sum) / Double(queryWords.count)
        }
    }
    func scorer(for query: String) -> Scorer {
        let groups = Self.equivalents.filter { group in group.contains { query.localizedCaseInsensitiveContains($0) } }
        let language = Self.language(for: query)
        let embedding = NLEmbedding.sentenceEmbedding(for: language)
        let contextual = embedding == nil ? Self.contextualModel(for: query) : nil
        let vector = embedding?.vector(for: query) ?? Self.contextualVector(query, model: contextual, language: language)
        let model = embedding.map { "sentence.\(language.rawValue).\($0.revision)" }
            ?? contextual.map { "context.\($0.modelIdentifier).\($0.revision).\(language.rawValue)" }
        let q = vector?.map(Float.init)
        let qNorm = sqrt(q?.reduce(0) { $0 + $1*$1 } ?? 0)
        return Scorer(model: q == nil ? nil : model) { text, stored in
            let floor = groups.contains { group in group.contains { text.localizedCaseInsensitiveContains($0) } } ? 1.0 : 0
            guard let q, qNorm > 0 else { return (floor, nil) }
            let cached = stored?.count == q.count ? stored : nil
            let computed = cached == nil ? (embedding?.vector(for: text) ?? Self.contextualVector(text, model: contextual, language: language))?.map(Float.init) : nil
            guard let v = cached ?? computed, v.count == q.count else { return (floor, nil) }
            let dot = zip(q,v).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            let norm = qNorm * sqrt(v.reduce(Float.zero) { $0 + $1*$1 })
            return (max(floor, norm > 0 ? Double(dot/norm) : 0), computed)
        }
    }
}
