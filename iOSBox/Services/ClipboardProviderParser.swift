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
    var extractedModelID: String? = nil
    var explicitProtocol: APIProtocolType? = nil
}

enum ClipboardProviderParser {
    static let maxInputChars = 8192

    private static let nonChatFragments = [
        "whisper", "tts", "dall-e", "embedding", "moderation",
        "sora", "realtime", "transcribe", "gpt-image",
        "-image", "image-", "imagen", "flux", "kolors",
        "rerank", "bge-", "audio", "speech", "asr", "ocr",
        "video", "veo", "lyria", "davinci", "babbage",
        "codex", "aqa", "computer-use", "search-preview"
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

        if let deepLinkCandidate = parseDeepLinkOrStructuredJSON(trimmed) {
            return deepLinkCandidate
        }

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
        let extractedModel = detectModelID(in: trimmed, excludingKey: detectedKey?.value)
        let explicitProtocol = detectExplicitProtocol(in: trimmed)

        if detectedKey == nil && extractedURL == nil {
            return nil
        }

        var candidate: ClipboardProviderCandidate
        if let detectedKey, detectedKey.origin != .genericSK && detectedKey.origin != .labeled {
            candidate = buildKnownKeyCandidate(detectedKey, extractedURL: extractedURL)
        } else if let extractedURL {
            candidate = buildURLMatchedCandidate(url: extractedURL, apiKey: detectedKey?.value ?? "")
        } else {
            guard let genericKey = detectedKey?.value else { return nil }
            let openaiTemplate = ProviderTemplate.catalog.first { $0.id == "openai" }
            candidate = ClipboardProviderCandidate(
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
        candidate.extractedModelID = extractedModel
        if let explicitProtocol {
            candidate.explicitProtocol = explicitProtocol
        }
        return candidate
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

    /// Selects up to `limit` diverse chat-capable models (always keeping `primaryID` first when present)
    /// so newly verified providers start with a practical model set instead of a single model.
    static func pickRecommendedStarterModels(
        from models: [ModelSpec],
        primaryID: String? = nil,
        protocolType: APIProtocolType,
        limit: Int = 4
    ) -> [ModelSpec] {
        guard limit > 0, !models.isEmpty else { return [] }
        let eligible = models.filter { spec in
            guard spec.catalogStatus != .unlisted else { return false }
            let lower = spec.id.lowercased()
            return !nonChatFragments.contains { lower.contains($0) }
        }
        let pool = eligible.isEmpty ? models.filter { $0.catalogStatus != .unlisted } : eligible
        var selected: [ModelSpec] = []
        var seen = Set<String>()

        func appendIfNew(_ spec: ModelSpec?) {
            guard let spec, selected.count < limit, seen.insert(spec.id).inserted else { return }
            selected.append(spec)
        }

        if let primaryID, !primaryID.isEmpty {
            appendIfNew(models.first { $0.id == primaryID } ?? ModelSpec(id: primaryID))
        }
        if selected.isEmpty {
            appendIfNew(pickBestStarterModel(from: pool, protocolType: protocolType))
        }
        for pattern in preferredModelPatterns where selected.count < limit {
            appendIfNew(pool.first { $0.id.lowercased().contains(pattern) })
        }
        if selected.count < limit {
            appendIfNew(pool.first { $0.supportsReasoning })
        }
        if selected.count < limit {
            appendIfNew(pool.first { $0.supportsVision })
        }
        for item in pool where selected.count < min(limit, 3) {
            appendIfNew(item)
        }
        return selected
    }

    /// Returns true when pasted text contains more than a bare single-line token (e.g. URL + key, JSON, or DeepLink snippet).
    static func looksLikeMultiFieldSnippet(_ rawInput: String) -> Bool {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("http://") || lower.contains("https://")
            || lower.hasPrefix("iosbox://") || lower.hasPrefix("ccswitch://")
            || lower.hasPrefix("cherrystudio://") || lower.hasPrefix("oneapi://")
            || lower.hasPrefix("newapi://") {
            return true
        }
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return true
        }
        let nonEmptyLines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return nonEmptyLines.count >= 2
    }

    private static func parseDeepLinkOrStructuredJSON(_ trimmed: String) -> ClipboardProviderCandidate? {
        let lower = trimmed.lowercased()
        let supportedSchemes = ["iosbox://", "ccswitch://", "cherrystudio://", "oneapi://", "newapi://"]
        if supportedSchemes.contains(where: { lower.hasPrefix($0) }),
           let comp = URLComponents(string: trimmed) {
            let items = Dictionary(
                (comp.queryItems ?? []).compactMap { item -> (String, String)? in
                    guard let val = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else { return nil }
                    return (item.name.lowercased(), val)
                },
                uniquingKeysWith: { first, _ in first }
            )
            // Check base64 payload in `data` or `config` query param first
            for payloadKey in ["data", "config", "payload"] {
                if let encoded = items[payloadKey],
                   let decoded = decodeBase64UTF8(encoded),
                   let nested = parseJSONConfigObject(decoded) {
                    return nested
                }
            }
            let urlVal = items["url"] ?? items["baseurl"] ?? items["base_url"] ?? items["endpoint"] ?? items["api_url"] ?? items["host"]
            let keyVal = items["key"] ?? items["apikey"] ?? items["api_key"] ?? items["token"] ?? ""
            let nameVal = items["name"] ?? items["title"] ?? items["provider"]
            let modelVal = items["model"] ?? items["model_id"] ?? items["modelid"]
            let protoVal = items["protocol"] ?? items["type"]
            if let candidate = buildStructuredCandidate(baseURL: urlVal, apiKey: keyVal, customName: nameVal, modelID: modelVal, protocolHint: protoVal) {
                return candidate
            }
        }

        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            return parseJSONConfigObject(trimmed)
        }
        return nil
    }

    private static func decodeBase64UTF8(_ raw: String) -> String? {
        var normalized = raw
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = normalized.count % 4
        if rem > 0 {
            normalized += String(repeating: "=", count: 4 - rem)
        }
        guard let data = Data(base64Encoded: normalized),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseJSONConfigObject(_ jsonText: String) -> ClipboardProviderCandidate? {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var flat: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flat[k.lowercased()] = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let nested = v as? [String: Any] {
                for (nk, nv) in nested {
                    if let ns = nv as? String, !ns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flat[nk.lowercased()] = ns.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        let urlVal = flat["baseurl"] ?? flat["base_url"] ?? flat["endpoint"] ?? flat["url"] ?? flat["apihost"] ?? flat["api_host"]
        let keyVal = flat["apikey"] ?? flat["api_key"] ?? flat["key"] ?? flat["token"] ?? ""
        let nameVal = flat["name"] ?? flat["provider"] ?? flat["title"]
        let modelVal = flat["model"] ?? flat["defaultmodel"] ?? flat["default_model"] ?? flat["model_id"]
        let protoVal = flat["protocol"] ?? flat["type"] ?? flat["apitype"]
        return buildStructuredCandidate(baseURL: urlVal, apiKey: keyVal, customName: nameVal, modelID: modelVal, protocolHint: protoVal)
    }

    private static func buildStructuredCandidate(
        baseURL: String?,
        apiKey: String,
        customName: String?,
        modelID: String?,
        protocolHint: String?
    ) -> ClipboardProviderCandidate? {
        let cleanKey = LLMClient.sanitizedAPIKey(apiKey)
        let cleanURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanURL, !cleanURL.isEmpty {
            let checkURL = cleanURL.hasSuffix("#") ? String(cleanURL.dropLast()) : cleanURL
            let scheme = URL(string: checkURL)?.scheme?.lowercased()
            guard (scheme == "https" || scheme == "http"),
                  !NetworkLocation.isPlainHTTPToPublicHost(baseURL: cleanURL),
                  !cleanURL.localizedCaseInsensitiveContains("api.example.com") else {
                return nil
            }
        }
        guard (cleanURL?.isEmpty == false) || !cleanKey.isEmpty else { return nil }

        var baseCandidate: ClipboardProviderCandidate
        if let detected = detectKey(in: cleanKey), detected.origin != .genericSK && detected.origin != .labeled {
            baseCandidate = buildKnownKeyCandidate(detected, extractedURL: cleanURL)
        } else if let cleanURL, !cleanURL.isEmpty {
            baseCandidate = buildURLMatchedCandidate(url: cleanURL, apiKey: cleanKey)
        } else {
            return nil
        }

        let explicitProto: APIProtocolType? = {
            guard let hint = protocolHint?.lowercased(), !hint.isEmpty else { return nil }
            if let direct = APIProtocolType(rawValue: hint) { return direct }
            if hint.contains("response") { return .openAIResponses }
            if hint.contains("anthropic") || hint.contains("claude") { return .anthropic }
            if hint.contains("gemini") { return .gemini }
            if hint.contains("openai") || hint.contains("chat") { return .openAICompatible }
            return nil
        }()

        let finalName = (customName?.isEmpty == false) ? customName! : baseCandidate.providerName
        return ClipboardProviderCandidate(
            apiKey: baseCandidate.apiKey,
            baseURL: baseCandidate.baseURL,
            protocolType: explicitProto ?? baseCandidate.protocolType,
            providerName: finalName,
            templateID: baseCandidate.templateID,
            accentHex: baseCandidate.accentHex,
            iconSymbol: baseCandidate.iconSymbol,
            confidenceNote: String(localized: "已识别一键配置信息（\(finalName)）。"),
            suggestedModels: baseCandidate.suggestedModels,
            isGenericOpenAIKey: false,
            extractedModelID: modelID,
            explicitProtocol: explicitProto
        )
    }

    private enum KeyOrigin {
        case anthropic
        case gemini
        case openRouter
        case groq
        case xai
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
        if let value = firstMatch(pattern: #"\bxai-[A-Za-z0-9_\-]{16,}"#, in: text) {
            return DetectedKey(value: value, origin: .xai)
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

    private static func detectModelID(in text: String, excludingKey: String?) -> String? {
        guard let value = firstMatch(
            pattern: #"(?:^|\n)\s*[-*•]?\s*(?:model(?:\s*id|_id)?|模型(?:\s*ID)?)\s*[:=：]\s*["'`]?([A-Za-z0-9][A-Za-z0-9._:/\-]{1,119})["'`]?"#,
            in: text,
            captureGroup: 1,
            caseInsensitive: true
        ) else {
            return nil
        }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
            return nil
        }
        if let excludingKey, value == excludingKey {
            return nil
        }
        return value
    }

    private static func detectExplicitProtocol(in text: String) -> APIProtocolType? {
        guard let raw = firstMatch(
            pattern: #"(?:^|\n)\s*[-*•]?\s*(?:protocol|api[_\-\s]?protocol|协议)\s*[:=：]\s*["'`]?([A-Za-z0-9_\-\s/]+?)["'`]?\s*(?:\n|$)"#,
            in: text,
            captureGroup: 1,
            caseInsensitive: true
        ) else {
            return nil
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = APIProtocolType(rawValue: normalized) {
            return direct
        }
        if normalized.contains("response") { return .openAIResponses }
        if normalized.contains("anthropic") || normalized.contains("claude") { return .anthropic }
        if normalized.contains("gemini") { return .gemini }
        if normalized.contains("openai") || normalized.contains("chat") || normalized.contains("compatible") {
            return .openAICompatible
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
            let tpl = ProviderTemplate.groq
            return ClipboardProviderCandidate(
                apiKey: key.value,
                baseURL: extractedURL ?? tpl.baseURL,
                protocolType: .openAICompatible,
                providerName: tpl.name,
                templateID: tpl.id,
                accentHex: tpl.accentHex,
                iconSymbol: tpl.iconSymbol,
                confidenceNote: String(localized: "已识别 Groq Key (gsk_...)，同时支持极速对话与 Whisper 转写。"),
                suggestedModels: tpl.suggestedModels,
                isGenericOpenAIKey: false
            )
        case .xai:
            let tpl = ProviderTemplate.xai
            return ClipboardProviderCandidate(
                apiKey: key.value,
                baseURL: extractedURL ?? tpl.baseURL,
                protocolType: .openAICompatible,
                providerName: tpl.name,
                templateID: tpl.id,
                accentHex: tpl.accentHex,
                iconSymbol: tpl.iconSymbol,
                confidenceNote: String(localized: "已识别 xAI Key (xai-...)。"),
                suggestedModels: tpl.suggestedModels,
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
            if lower.contains("dashscope.aliyuncs.com") {
                return ProviderTemplate.dashScope
            }
            if lower.contains("api.groq.com") {
                return ProviderTemplate.groq
            }
            if lower.contains("api.x.ai") {
                return ProviderTemplate.xai
            }
            if lower.contains("api.moonshot.cn") || lower.contains("api.moonshot.ai") {
                return ProviderTemplate.moonshot
            }
            if lower.contains("open.bigmodel.cn") {
                return ProviderTemplate.zhipu
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
