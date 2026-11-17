import Foundation

enum EndpointResolver {
    static func chatEndpoint(
        baseURL: String,
        protocolType: APIProtocolType,
        modelID: String = ""
    ) throws -> URL {
        let cleaned = sanitizeInput(baseURL)
        let forceRaw = cleaned.hasSuffix("#")
        let raw = forceRaw ? String(cleaned.dropLast()) : cleaned
        let trimmed = stripTrailingSlash(raw)

        guard !trimmed.isEmpty else {
            throw LLMError.invalidURL(baseURL)
        }

        let finalString: String
        switch protocolType {
        case .openAICompatible:
            if trimmed.hasSuffix("/chat/completions") {
                finalString = trimmed
            } else if forceRaw {
                finalString = "\(trimmed)/chat/completions"
            } else {
                let versioned = ensureOpenAIVersionPrefix(trimmed)
                finalString = "\(versioned)/chat/completions"
            }

        case .anthropic:
            if trimmed.hasSuffix("/messages") {
                finalString = trimmed
            } else if forceRaw {
                finalString = "\(trimmed)/messages"
            } else {
                let versioned = ensureAnthropicVersionPrefix(trimmed)
                finalString = "\(versioned)/messages"
            }

        case .gemini:
            let encodedModel = normalizeGeminiModelPath(modelID)
            if trimmed.contains(":streamGenerateContent") {
                finalString = trimmed
            } else {
                let root = forceRaw ? trimmed : ensureGeminiVersionPrefix(trimmed)
                finalString = "\(root)/\(encodedModel):streamGenerateContent?alt=sse"
            }
        }

        guard let url = URL(string: finalString), url.scheme != nil, url.host != nil else {
            throw LLMError.invalidURL(finalString)
        }
        return url
    }

    static func modelsEndpoint(
        baseURL: String,
        protocolType: APIProtocolType
    ) throws -> URL {
        let cleaned = sanitizeInput(baseURL)
        let forceRaw = cleaned.hasSuffix("#")
        let raw = forceRaw ? String(cleaned.dropLast()) : cleaned
        var trimmed = stripTrailingSlash(raw)

        guard !trimmed.isEmpty else {
            throw LLMError.invalidURL(baseURL)
        }

        if trimmed.hasSuffix("/chat/completions") {
            trimmed = String(trimmed.dropLast("/chat/completions".count))
        } else if trimmed.hasSuffix("/messages") {
            trimmed = String(trimmed.dropLast("/messages".count))
        }

        let finalString: String
        switch protocolType {
        case .openAICompatible:
            if trimmed.hasSuffix("/models") {
                finalString = trimmed
            } else if forceRaw {
                finalString = "\(trimmed)/models"
            } else {
                finalString = "\(ensureOpenAIVersionPrefix(trimmed))/models"
            }

        case .anthropic:
            if trimmed.hasSuffix("/models") {
                finalString = trimmed
            } else if forceRaw {
                finalString = "\(trimmed)/models"
            } else {
                finalString = "\(ensureAnthropicVersionPrefix(trimmed))/models"
            }

        case .gemini:
            if trimmed.hasSuffix("/models") {
                finalString = trimmed
            } else {
                let root = forceRaw ? trimmed : ensureGeminiVersionPrefix(trimmed)
                finalString = "\(root)/models?pageSize=200"
            }
        }

        guard let url = URL(string: finalString), url.scheme != nil, url.host != nil else {
            throw LLMError.invalidURL(finalString)
        }
        return url
    }

    static func previewChatEndpoint(
        baseURL: String,
        protocolType: APIProtocolType,
        sampleModel: String = "model-id"
    ) -> String {
        (try? chatEndpoint(baseURL: baseURL, protocolType: protocolType, modelID: sampleModel).absoluteString)
            ?? String(localized: "URL 格式待完善")
    }

    // MARK: - Helpers

    private static func sanitizeInput(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTrailingSlash(_ value: String) -> String {
        var copy = value
        while copy.hasSuffix("/") {
            copy.removeLast()
        }
        return copy
    }

    private static func ensureOpenAIVersionPrefix(_ base: String) -> String {
        guard let components = URLComponents(string: base) else {
            return "\(base)/v1"
        }
        let path = components.path.lowercased()
        if path.isEmpty || path == "/" {
            return "\(base)/v1"
        }
        let segments = path.split(separator: "/").map(String.init)
        let hasVersionSegment = segments.contains { seg in
            seg == "v1" || seg == "v2" || seg == "v3" || seg == "v4" || seg == "v1beta" || seg == "openai"
        }
        if hasVersionSegment {
            return base
        }
        return "\(base)/v1"
    }

    private static func ensureAnthropicVersionPrefix(_ base: String) -> String {
        guard let components = URLComponents(string: base) else {
            return "\(base)/v1"
        }
        let segments = components.path.lowercased().split(separator: "/").map(String.init)
        if segments.contains("v1") {
            return base
        }
        return "\(base)/v1"
    }

    private static func ensureGeminiVersionPrefix(_ base: String) -> String {
        guard let components = URLComponents(string: base) else {
            return "\(base)/v1beta"
        }
        let segments = components.path.lowercased().split(separator: "/").map(String.init)
        if segments.contains("v1beta") || segments.contains("v1") {
            return base
        }
        return "\(base)/v1beta"
    }

    private static func normalizeGeminiModelPath(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return trimmed
        }
        return "models/\(trimmed.isEmpty ? "gemini-2.5-flash" : trimmed)"
    }
}
