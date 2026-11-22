import Foundation

struct ClipboardProviderCandidate: Equatable {
    let apiKey: String
    let baseURL: String
    let protocolType: APIProtocolType
    let providerName: String
    let templateID: String
    let accentHex: String
    let iconSymbol: String
    let confidenceNote: String
    let suggestedModels: [ModelSpec]
    let isGenericOpenAIKey: Bool
}

enum ClipboardProviderParser {
    static let maxInputChars = 8192

    private static let nonChatFragments = [
        "whisper", "tts", "dall-e", "embedding", "moderation",
        "sora", "realtime", "transcribe", "gpt-image"
    ]

    private static let preferredModelPatterns = [
        "gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1", "gpt-4o", "gpt-6",
        "deepseek-chat", "deepseek-flash", "deepseek-v4",
        "claude-sonnet", "claude-haiku",
        "gemini-2.5-flash", "gemini-3", "gemini-4",
        "llama-3.3-70b", "qwen", "openrouter/auto"
    ]

    static func parse(_ rawInput: String) -> ClipboardProviderCandidate? {
        let trimmed = String(rawInput.prefix(maxInputChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawURLs = extractURLs(from: trimmed)
        let hasExplicitPublicHTTP = rawURLs.contains { NetworkLocation.isPlainHTTPToPublicHost(baseURL: $0) }
        let safeURLs = rawURLs.filter { url in
            let scheme = URL(string: url.hasSuffix("#") ? String(url.dropLast()) : url)?.scheme?.lowercased()
            return (scheme == "https" || scheme == "http")
                && !NetworkLocation.isPlainHTTPToPublicHost(baseURL: url)
                && !url.localizedCaseInsensitiveContains("api.example.com")
        }
        if hasExplicitPublicHTTP && safeURLs.isEmpty {
            return nil
        }

        let detectedKey = detectKey(in: trimmed)
        let extractedURL = safeURLs.first

        if detectedKey == nil && extractedURL == nil {
            return nil
        }

        if let detectedKey, detectedKey.origin != .genericSK && detectedKey.origin != .labeled {
            return buildKnownKeyCandidate(detectedKey, extractedURL: extractedURL)
        }

        if let extractedURL {
            return buildURLMatchedCandidate(url: extractedURL, apiKey: detectedKey?.value ?? "")
        }

        guard let genericKey = detectedKey?.value else { return nil }
        let openaiTemplate = ProviderTemplate.catalog.first { $0.id == "openai" }
        return ClipboardProviderCandidate(
            apiKey: genericKey,
            baseURL: openaiTemplate?.baseURL ?? "https://api.openai.com/v1",
            protocolType: .openAICompatible,
            providerName: String(localized: "OpenAI / 兼容服务"),
            templateID: "openai",
            accentHex: openaiTemplate?.accentHex ?? "#10A37F",
            iconSymbol: openaiTemplate?.iconSymbol ?? "circle.hexagongrid.fill",
            confidenceNote: String(localized: "识别到通用 sk- 密钥，请在下方确认实际服务商或中转站地址。"),
            suggestedModels: openaiTemplate?.suggestedModels ?? [],
            isGenericOpenAIKey: true
        )
    }

    static func pickBestStarterModel(
        from models: [ModelSpec],
        protocolType: APIProtocolType
    ) -> ModelSpec? {
        let eligible = models.filter { spec in
            let lower = spec.id.lowercased()
            return !nonChatFragments.contains { lower.contains($0) }
        }
        let pool = eligible.isEmpty ? models : eligible
        for pattern in preferredModelPatterns {
            if let hit = pool.first(where: { $0.id.lowercased().contains(pattern) }) {
                return hit
            }
        }
        if protocolType == .anthropic,
           let claude = pool.first(where: { $0.id.lowercased().contains("claude") }) {
            return claude
        }
        if protocolType == .gemini,
           let gemini = pool.first(where: { $0.id.lowercased().contains("gemini") }) {
            return gemini
        }
        return pool.first
    }

    private enum KeyOrigin {
        case anthropic
        case gemini
        case openRouter
        case groq
        case openAIPrefixed
        case genericSK
        case labeled
    }

    private struct DetectedKey {
        let value: String
        let origin: KeyOrigin
    }

    private static func extractURLs(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s"'<>)\],;]+"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var result: [String] = []
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let cleaned = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if seen.insert(cleaned).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    private static func firstMatch(pattern: String, in text: String, captureGroup: Int = 0, caseInsensitive: Bool = false) -> String? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              captureGroup < match.numberOfRanges,
              let range = Range(match.range(at: captureGroup), in: text) else {
            return nil
        }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func detectKey(in text: String) -> DetectedKey? {
        if let value = firstMatch(pattern: #"\bsk-ant-[A-Za-z0-9_\-]{12,}"#, in: text) {
            return DetectedKey(value: value, origin: .anthropic)
        }
        if let value = firstMatch(pattern: #"\bAIza[0-9A-Za-z_\-]{20,}"#, in: text) {
            return DetectedKey(value: value, origin: .gemini)
        }
        if let value = firstMatch(pattern: #"\bsk-or-v1-[A-Za-z0-9]{16,}"#, in: text) {
            return DetectedKey(value: value, origin: .openRouter)
        }
        if let value = firstMatch(pattern: #"\bgsk_[A-Za-z0-9]{16,}"#, in: text) {
            return DetectedKey(value: value, origin: .groq)
        }
        if let value = firstMatch(pattern: #"\bsk-(?:proj|svcacct|live|test)-[A-Za-z0-9_\-]{16,}"#, in: text) {
            return DetectedKey(value: value, origin: .openAIPrefixed)
        }
        if let value = firstMatch(pattern: #"\bsk-[A-Za-z0-9_\-]{16,}"#, in: text) {
            return DetectedKey(value: value, origin: .genericSK)
        }
        if let value = firstMatch(
            pattern: #"(?:api[_\-\s]?key|access[_\-\s]?token|token)\s*[:=]\s*["']?([A-Za-z0-9._\-]{16,})["']?"#,
            in: text,
            captureGroup: 1,
            caseInsensitive: true
        ) {
            return DetectedKey(value: value, origin: .labeled)
        }
        if let value = firstMatch(
            pattern: #"Bearer\s+([A-Za-z0-9._\-]{16,})"#,
            in: text,
            captureGroup: 1,
            caseInsensitive: true
        ) {
            return DetectedKey(value: value, origin: .labeled)
        }
        return nil
    }

    private static func buildKnownKeyCandidate(
        _ key: DetectedKey,
        extractedURL: String?
    ) -> ClipboardProviderCandidate {
        switch key.origin {
        case .anthropic:
            let tpl = ProviderTemplate.catalog.first { $0.id == "anthropic" }
            let useURL = extractedURL ?? tpl?.baseURL ?? "https://api.anthropic.com/v1"
            let isRelay = extractedURL != nil && !useURL.localizedCaseInsensitiveContains("anthropic.com")
            return ClipboardProviderCandidate(
                apiKey: key.value,
                baseURL: useURL,
                protocolType: isRelay ? .openAICompatible : .anthropic,
                providerName: isRelay ? hostDisplayName(for: useURL, fallback: "Claude Relay") : (tpl?.name ?? "Anthropic Claude"),
                templateID: "anthropic",
                accentHex: tpl?.accentHex ?? "#D97757",
                iconSymbol: tpl?.iconSymbol ?? "sparkles",
                confidenceNote: String(localized: "已识别 Anthropic Key (sk-ant-...)"),
                suggestedModels: tpl?.suggestedModels ?? [],
                isGenericOpenAIKey: false
            )
        case .gemini:
            let tpl = ProviderTemplate.catalog.first { $0.id == "gemini" }
            let useURL = extractedURL ?? tpl?.baseURL ?? "https://generativelanguage.googleapis.com/v1beta"
            return ClipboardProviderCandidate(
                apiKey: key.value,
                baseURL: useURL,
                protocolType: .gemini,
                providerName: tpl?.name ?? "Google Gemini",
                templateID: "gemini",
                accentHex: tpl?.accentHex ?? "#2563EB",
                iconSymbol: tpl?.iconSymbol ?? "wand.and.stars",
                confidenceNote: String(localized: "已识别 Google Gemini Key (AIza...)"),
                suggestedModels: tpl?.suggestedModels ?? [],
                isGenericOpenAIKey: false
            )
        case .openRouter:
            let tpl = ProviderTemplate.catalog.first { $0.id == "openrouter" }
            return ClipboardProviderCandidate(
                apiKey: key.value,
                baseURL: extractedURL ?? tpl?.baseURL ?? "https://openrouter.ai/api/v1",
                protocolType: .openAICompatible,
                providerName: "OpenRouter",
                templateID: "openrouter",
                accentHex: tpl?.accentHex ?? "#6366F1",
                iconSymbol: tpl?.iconSymbol ?? "arrow.triangle.branch",
                confidenceNote: String(localized: "已识别 OpenRouter Key (sk-or-v1-...)"),
                suggestedModels: tpl?.suggestedModels ?? [],
                isGenericOpenAIKey: false
            )
        case .groq:
            return ClipboardProviderCandidate(
                apiKey: key.value,
                baseURL: extractedURL ?? "https://api.groq.com/openai/v1",
                protocolType: .openAICompatible,
                providerName: "Groq",
                templateID: "custom_openai",
                accentHex: "#F55036",
                iconSymbol: "bolt.fill",
                confidenceNote: String(localized: "已识别 Groq Key (gsk_...)，同时支持极速对话与 Whisper 转写。"),
                suggestedModels: [
                    ModelSpec(id: "llama-3.3-70b-versatile", displayName: "Llama 3.3 70B"),
                    ModelSpec(id: "qwen/qwen3-32b", displayName: "Qwen 3 32B")
                ],
                isGenericOpenAIKey: false
            )
        case .openAIPrefixed:
            let tpl = ProviderTemplate.catalog.first { $0.id == "openai" }
            let useURL = extractedURL ?? tpl?.baseURL ?? "https://api.openai.com/v1"
            let isRelay = extractedURL != nil && !useURL.localizedCaseInsensitiveContains("openai.com")
            return ClipboardProviderCandidate(
                apiKey: key.value,
                baseURL: useURL,
                protocolType: .openAICompatible,
                providerName: isRelay ? hostDisplayName(for: useURL, fallback: "OpenAI 中转") : "OpenAI",
                templateID: isRelay ? "custom_openai" : "openai",
                accentHex: tpl?.accentHex ?? "#10A37F",
                iconSymbol: tpl?.iconSymbol ?? "circle.hexagongrid.fill",
                confidenceNote: String(localized: "已识别 OpenAI Key。"),
                suggestedModels: tpl?.suggestedModels ?? [],
                isGenericOpenAIKey: false
            )
        case .genericSK, .labeled:
            return buildURLMatchedCandidate(
                url: extractedURL ?? "https://api.openai.com/v1",
                apiKey: key.value
            )
        }
    }

    private static func buildURLMatchedCandidate(url: String, apiKey: String) -> ClipboardProviderCandidate {
        let lower = url.lowercased()
        let matched: ProviderTemplate? = {
            if lower.contains("deepseek.com") {
                return ProviderTemplate.catalog.first { $0.id == "deepseek" }
            }
            if lower.contains("siliconflow.") {
                return ProviderTemplate.catalog.first { $0.id == "siliconflow" }
            }
            if lower.contains("openrouter.ai") {
                return ProviderTemplate.catalog.first { $0.id == "openrouter" }
            }
            if lower.contains("anthropic.com") {
                return ProviderTemplate.catalog.first { $0.id == "anthropic" }
            }
            if lower.contains("generativelanguage.googleapis.com") {
                return ProviderTemplate.catalog.first { $0.id == "gemini" }
            }
            if lower.contains("openai.com") {
                return ProviderTemplate.catalog.first { $0.id == "openai" }
            }
            if NetworkLocation.isLocalOrPrivate(baseURL: url) {
                return ProviderTemplate.catalog.first { $0.id == "ollama" }
            }
            return nil
        }()

        if let matched {
            return ClipboardProviderCandidate(
                apiKey: apiKey,
                baseURL: url,
                protocolType: matched.protocolType,
                providerName: matched.name,
                templateID: matched.id,
                accentHex: matched.accentHex,
                iconSymbol: matched.iconSymbol,
                confidenceNote: String(localized: "已从地址自动匹配服务商「\(matched.name)」。"),
                suggestedModels: matched.suggestedModels,
                isGenericOpenAIKey: false
            )
        }

        let proto: APIProtocolType = {
            if lower.contains("anthropic") { return .anthropic }
            if lower.contains("generativelanguage.googleapis.com") { return .gemini }
            return .openAICompatible
        }()
        return ClipboardProviderCandidate(
            apiKey: apiKey,
            baseURL: url,
            protocolType: proto,
            providerName: hostDisplayName(for: url, fallback: String(localized: "自定义服务商")),
            templateID: "custom_openai",
            accentHex: "#3F6EF6",
            iconSymbol: "slider.horizontal.below.square.and.square.filled",
            confidenceNote: NetworkLocation.isLocalOrPrivate(baseURL: url)
                ? String(localized: "已识别局域网本地服务地址（可免 Key）。")
                : String(localized: "已提取自定义 Base URL 与凭证，可直接测通。"),
            suggestedModels: [],
            isGenericOpenAIKey: false
        )
    }

    private static func hostDisplayName(for rawURL: String, fallback: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutHash = trimmed.hasSuffix("#") ? String(trimmed.dropLast()) : trimmed
        guard let host = URLComponents(string: withoutHash)?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return fallback
        }
        return host.hasPrefix("api.") ? String(host.dropFirst(4)) : host
    }
}
