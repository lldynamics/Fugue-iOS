import Foundation
import NaturalLanguage

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
