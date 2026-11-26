import Foundation

enum ModelPricingCatalog {
    struct Preset: Identifiable, Equatable {
        let id: String
        let label: String
        let matchPrefixes: [String]
        let currency: String
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheReadPerMillion: Double?
        let cacheWritePerMillion: Double?
    }

    static let presets: [Preset] = [
        Preset(
            id: "gpt-4.1",
            label: "OpenAI GPT-4.1 ($2 / $8)",
            matchPrefixes: ["gpt-4.1"],
            currency: "USD",
            inputPerMillion: 2.0,
            outputPerMillion: 8.0,
            cacheReadPerMillion: 0.5,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "gpt-4.1-mini",
            label: "OpenAI GPT-4.1 mini ($0.4 / $1.6)",
            matchPrefixes: ["gpt-4.1-mini"],
            currency: "USD",
            inputPerMillion: 0.4,
            outputPerMillion: 1.6,
            cacheReadPerMillion: 0.1,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "gpt-4.1-nano",
            label: "OpenAI GPT-4.1 nano ($0.1 / $0.4)",
            matchPrefixes: ["gpt-4.1-nano"],
            currency: "USD",
            inputPerMillion: 0.1,
            outputPerMillion: 0.4,
            cacheReadPerMillion: 0.025,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "gpt-4o-mini",
            label: "OpenAI GPT-4o mini ($0.15 / $0.6)",
            matchPrefixes: ["gpt-4o-mini"],
            currency: "USD",
            inputPerMillion: 0.15,
            outputPerMillion: 0.60,
            cacheReadPerMillion: 0.075,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "gpt-4o",
            label: "OpenAI GPT-4o ($2.5 / $10)",
            matchPrefixes: ["gpt-4o", "chatgpt-4o"],
            currency: "USD",
            inputPerMillion: 2.5,
            outputPerMillion: 10.0,
            cacheReadPerMillion: 1.25,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "o4-mini",
            label: "OpenAI o4-mini / o3-mini ($1.1 / $4.4)",
            matchPrefixes: ["o4-mini", "o3-mini"],
            currency: "USD",
            inputPerMillion: 1.1,
            outputPerMillion: 4.4,
            cacheReadPerMillion: 0.275,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "o3",
            label: "OpenAI o3 ($2 / $8)",
            matchPrefixes: ["o3"],
            currency: "USD",
            inputPerMillion: 2.0,
            outputPerMillion: 8.0,
            cacheReadPerMillion: 0.5,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "claude-sonnet-4",
            label: "Claude Sonnet 4 / 4.5 / 3.7 ($3 / $15)",
            matchPrefixes: ["claude-sonnet-4", "claude-3-7-sonnet", "claude-3-5-sonnet"],
            currency: "USD",
            inputPerMillion: 3.0,
            outputPerMillion: 15.0,
            cacheReadPerMillion: 0.30,
            cacheWritePerMillion: 3.75
        ),
        Preset(
            id: "claude-opus-4-5",
            label: "Claude Opus 4.5 / 4.6 / 4.7 ($5 / $25)",
            matchPrefixes: [
                "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5",
                "claude-opus-4.7", "claude-opus-4.6", "claude-opus-4.5"
            ],
            currency: "USD",
            inputPerMillion: 5.0,
            outputPerMillion: 25.0,
            cacheReadPerMillion: 0.50,
            cacheWritePerMillion: 6.25
        ),
        Preset(
            id: "claude-opus-4",
            label: "Claude Opus 4 / 4.1 ($15 / $75)",
            matchPrefixes: ["claude-opus-4"],
            currency: "USD",
            inputPerMillion: 15.0,
            outputPerMillion: 75.0,
            cacheReadPerMillion: 1.50,
            cacheWritePerMillion: 18.75
        ),
        Preset(
            id: "claude-haiku",
            label: "Claude Haiku 3.5 / 4 ($0.8 / $4)",
            matchPrefixes: ["claude-3-5-haiku", "claude-haiku-4"],
            currency: "USD",
            inputPerMillion: 0.80,
            outputPerMillion: 4.0,
            cacheReadPerMillion: 0.08,
            cacheWritePerMillion: 1.0
        ),
        Preset(
            id: "deepseek-reasoner",
            label: "DeepSeek-R1 官方 (CNY ¥4 / ¥16)",
            matchPrefixes: ["deepseek-reasoner", "deepseek-r1"],
            currency: "CNY",
            inputPerMillion: 4.0,
            outputPerMillion: 16.0,
            cacheReadPerMillion: 1.0,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "deepseek-chat",
            label: "DeepSeek-V3 官方 (CNY ¥2 / ¥8)",
            matchPrefixes: ["deepseek-chat", "deepseek-v3"],
            currency: "CNY",
            inputPerMillion: 2.0,
            outputPerMillion: 8.0,
            cacheReadPerMillion: 0.5,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "gemini-2.5-pro",
            label: "Gemini 2.5 Pro ($1.25 / $10)",
            matchPrefixes: ["gemini-2.5-pro", "gemini-3-pro"],
            currency: "USD",
            inputPerMillion: 1.25,
            outputPerMillion: 10.0,
            cacheReadPerMillion: 0.31,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "gemini-2.5-flash-lite",
            label: "Gemini 2.5 Flash-Lite / 2.0 Flash ($0.1 / $0.4)",
            matchPrefixes: ["gemini-2.5-flash-lite", "gemini-2.0-flash-lite", "gemini-2.0-flash"],
            currency: "USD",
            inputPerMillion: 0.10,
            outputPerMillion: 0.40,
            cacheReadPerMillion: 0.025,
            cacheWritePerMillion: nil
        ),
        Preset(
            id: "gemini-2.5-flash",
            label: "Gemini 2.5 Flash ($0.3 / $2.5)",
            matchPrefixes: ["gemini-2.5-flash", "gemini-3-flash"],
            currency: "USD",
            inputPerMillion: 0.30,
            outputPerMillion: 2.50,
            cacheReadPerMillion: 0.075,
            cacheWritePerMillion: nil
        )
    ]

    private static let usdDeepSeekReasoner = Preset(
        id: "deepseek-reasoner",
        label: "DeepSeek-R1 ($0.55 / $2.19)",
        matchPrefixes: ["deepseek-reasoner", "deepseek-r1"],
        currency: "USD",
        inputPerMillion: 0.55,
        outputPerMillion: 2.19,
        cacheReadPerMillion: 0.14,
        cacheWritePerMillion: nil
    )

    private static let usdDeepSeekChat = Preset(
        id: "deepseek-chat",
        label: "DeepSeek-V3 ($0.27 / $1.10)",
        matchPrefixes: ["deepseek-chat", "deepseek-v3"],
        currency: "USD",
        inputPerMillion: 0.27,
        outputPerMillion: 1.10,
        cacheReadPerMillion: 0.07,
        cacheWritePerMillion: nil
    )

    static func isUSDAggregator(baseURL: String?) -> Bool {
        guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else {
            return false
        }
        let usdDomains = [
            "openrouter.ai",
            "together.xyz",
            "together.ai",
            "fireworks.ai",
            "groq.com",
            "deepinfra.com",
            "siliconflow.com",
            "cerebras.ai",
            "sambanova.ai",
            "hyperbolic.xyz",
            "nebius.com"
        ]
        return usdDomains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Matches the most specific preset (longest matching token) against a model ID using token boundaries,
    /// using USD rates when `baseURL` points to a known USD-billed aggregator/router.
    static func match(modelID: String, baseURL: String? = nil) -> Preset? {
        let lower = modelID.lowercased()
        var best: (preset: Preset, length: Int)?
        for preset in presets {
            if preset.id == "o3" && lower.contains("o3-pro") { continue }
            for token in preset.matchPrefixes where containsToken(token, in: lower) {
                if best == nil || token.count > best!.length {
                    best = (preset, token.count)
                }
            }
        }
        guard let matched = best?.preset else { return nil }
        if matched.currency == "CNY" && isUSDAggregator(baseURL: baseURL) {
            switch matched.id {
            case "deepseek-reasoner":
                return usdDeepSeekReasoner
            case "deepseek-chat":
                return usdDeepSeekChat
            default:
                let fx = 7.2
                return Preset(
                    id: matched.id,
                    label: matched.label,
                    matchPrefixes: matched.matchPrefixes,
                    currency: "USD",
                    inputPerMillion: (matched.inputPerMillion / fx * 1000).rounded() / 1000,
                    outputPerMillion: (matched.outputPerMillion / fx * 1000).rounded() / 1000,
                    cacheReadPerMillion: matched.cacheReadPerMillion.map { ($0 / fx * 1000).rounded() / 1000 },
                    cacheWritePerMillion: matched.cacheWritePerMillion.map { ($0 / fx * 1000).rounded() / 1000 }
                )
            }
        }
        return matched
    }

    private static func isASCIIAlphanumeric(_ char: Character) -> Bool {
        char.isASCII && (char.isLetter || char.isNumber)
    }

    private static func containsToken(_ token: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: token, range: searchRange) {
            let validStart: Bool
            if match.lowerBound == text.startIndex {
                validStart = true
            } else {
                let prev = text[text.index(before: match.lowerBound)]
                validStart = !isASCIIAlphanumeric(prev)
            }
            let validEnd: Bool
            if match.upperBound == text.endIndex {
                validEnd = true
            } else {
                let next = text[match.upperBound]
                validEnd = !isASCIIAlphanumeric(next)
            }
            if validStart && validEnd {
                return true
            }
            searchRange = text.index(after: match.lowerBound)..<text.endIndex
        }
        return false
    }

    static func apply(_ preset: Preset, to spec: inout ModelSpec) {
        spec.inputPricePerMillion = preset.inputPerMillion
        spec.outputPricePerMillion = preset.outputPerMillion
        spec.cacheReadPricePerMillion = preset.cacheReadPerMillion
        spec.cacheWritePricePerMillion = preset.cacheWritePerMillion
        spec.priceCurrency = preset.currency
        spec.priceSource = .manual
    }
}
