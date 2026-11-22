import Foundation

enum EndpointResolver {
    static func chatEndpoint(
        baseURL: String,
        protocolType: APIProtocolType,
        modelID: String = ""
    ) throws -> URL {
        var (components, path, forceRaw) = try parseBaseComponents(baseURL)

        switch protocolType {
        case .openAICompatible:
            if path.hasSuffix("/chat/completions") {
                break
            } else if forceRaw {
                path += "/chat/completions"
            } else {
                let versioned = ensureOpenAIVersionPrefix(path: path)
                path = "\(versioned)/chat/completions"
            }

        case .anthropic:
            if path.hasSuffix("/messages") {
                break
            } else if forceRaw {
                path += "/messages"
            } else {
                let versioned = ensureAnthropicVersionPrefix(path: path)
                path = "\(versioned)/messages"
            }

        case .gemini:
            let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedModel.contains(where: \.isWhitespace) || !isSafeGeminiModelIdentifier(trimmedModel) {
                throw LLMError.invalidURL(baseURL)
            }
            let encodedModel = normalizeGeminiModelPath(trimmedModel)
            if path.contains(":streamGenerateContent") {
                ensureQueryItem(name: "alt", value: "sse", in: &components)
            } else {
                let root = forceRaw ? path : ensureGeminiVersionPrefix(path: path)
                path = "\(root)/\(encodedModel):streamGenerateContent"
                ensureQueryItem(name: "alt", value: "sse", in: &components)
            }
        }

        return try finalizeURL(components: components, path: path, forceRaw: forceRaw, rawInput: baseURL)
    }

    static func modelsEndpoint(
        baseURL: String,
        protocolType: APIProtocolType
    ) throws -> URL {
        var (components, path, forceRaw) = try parseBaseComponents(baseURL)

        if path.hasSuffix("/chat/completions") {
            path = stripTrailingSlash(String(path.dropLast("/chat/completions".count)))
        } else if path.hasSuffix("/messages") {
            path = stripTrailingSlash(String(path.dropLast("/messages".count)))
        } else if protocolType == .gemini,
                  (path.contains(":streamGenerateContent") || path.contains(":generateContent")),
                  let modelsRange = path.range(of: "/models/") {
            path = stripTrailingSlash(String(path[..<modelsRange.lowerBound]))
        }

        switch protocolType {
        case .openAICompatible:
            if path.hasSuffix("/models") {
                break
            } else if forceRaw {
                path += "/models"
            } else {
                path = "\(ensureOpenAIVersionPrefix(path: path))/models"
            }

        case .anthropic:
            if path.hasSuffix("/models") {
                break
            } else if forceRaw {
                path += "/models"
            } else {
                path = "\(ensureAnthropicVersionPrefix(path: path))/models"
            }

        case .gemini:
            if path.hasSuffix("/models") {
                break
            } else {
                let root = forceRaw ? path : ensureGeminiVersionPrefix(path: path)
                path = "\(root)/models"
                ensureQueryItem(name: "pageSize", value: "200", in: &components)
            }
        }

        return try finalizeURL(components: components, path: path, forceRaw: forceRaw, rawInput: baseURL)
    }

    static func previewChatEndpoint(
        baseURL: String,
        protocolType: APIProtocolType,
        sampleModel: String = "model-id"
    ) -> String {
        (try? chatEndpoint(baseURL: baseURL, protocolType: protocolType, modelID: sampleModel).absoluteString)
            ?? String(localized: "URL 格式待完善")
    }

    static func audioTranscriptionsEndpoint(baseURL: String) throws -> URL {
        try openAIAudioEndpoint(baseURL: baseURL, suffix: "/audio/transcriptions", siblingSuffix: "/audio/speech")
    }

    static func audioSpeechEndpoint(baseURL: String) throws -> URL {
        try openAIAudioEndpoint(baseURL: baseURL, suffix: "/audio/speech", siblingSuffix: "/audio/transcriptions")
    }

    private static func openAIAudioEndpoint(baseURL: String, suffix: String, siblingSuffix: String) throws -> URL {
        let (components, rawPath, forceRaw) = try parseBaseComponents(baseURL)
        var path = rawPath
        if path.hasSuffix("/chat/completions") {
            path = stripTrailingSlash(String(path.dropLast("/chat/completions".count)))
        } else if path.hasSuffix("/models") {
            path = stripTrailingSlash(String(path.dropLast("/models".count)))
        } else if path.hasSuffix(siblingSuffix) {
            path = stripTrailingSlash(String(path.dropLast(siblingSuffix.count)))
        }
        if !path.hasSuffix(suffix) {
            path = forceRaw ? "\(path)\(suffix)" : "\(ensureOpenAIVersionPrefix(path: path))\(suffix)"
        }
        return try finalizeURL(components: components, path: path, forceRaw: forceRaw, rawInput: baseURL)
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

    private static func parseBaseComponents(_ baseURL: String) throws -> (URLComponents, String, Bool) {
        let cleaned = sanitizeInput(baseURL)
        let forceRaw = cleaned.hasSuffix("#")
        let raw = forceRaw ? String(cleaned.dropLast()) : cleaned
        let trimmed = stripTrailingSlash(raw)

        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            throw LLMError.invalidURL(baseURL)
        }

        let normalizedPath = stripTrailingSlash(components.path)
        return (components, normalizedPath, forceRaw)
    }

    private static func finalizeURL(
        components: URLComponents,
        path: String,
        forceRaw: Bool,
        rawInput: String
    ) throws -> URL {
        var updated = components
        updated.path = path.hasPrefix("/") || path.isEmpty ? path : "/\(path)"
        if forceRaw {
            updated.fragment = nil
        }
        guard let url = updated.url, url.scheme != nil, url.host != nil else {
            throw LLMError.invalidURL(rawInput)
        }
        return url
    }

    private static func ensureQueryItem(name: String, value: String, in components: inout URLComponents) {
        let existingItems = components.queryItems ?? []
        if existingItems.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return
        }
        if let existingQuery = components.percentEncodedQuery, !existingQuery.isEmpty {
            components.percentEncodedQuery = "\(existingQuery)&\(name)=\(value)"
        } else {
            components.percentEncodedQuery = "\(name)=\(value)"
        }
    }

    private static func ensureOpenAIVersionPrefix(path: String) -> String {
        let lower = path.lowercased()
        if lower.isEmpty || lower == "/" {
            return "/v1"
        }
        let segments = lower.split(separator: "/").map(String.init)
        let hasVersionSegment = segments.contains { seg in
            seg == "v1" || seg == "v2" || seg == "v3" || seg == "v4" || seg == "v1beta" || seg == "openai"
        }
        return hasVersionSegment ? path : "\(path)/v1"
    }

    private static func ensureAnthropicVersionPrefix(path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/v1"
        }
        let segments = path.lowercased().split(separator: "/").map(String.init)
        return segments.contains("v1") ? path : "\(path)/v1"
    }

    private static func ensureGeminiVersionPrefix(path: String) -> String {
        if path.isEmpty || path == "/" {
            return "/v1beta"
        }
        let segments = path.lowercased().split(separator: "/").map(String.init)
        return (segments.contains("v1beta") || segments.contains("v1")) ? path : "\(path)/v1beta"
    }

    private static func isSafeGeminiModelIdentifier(_ modelID: String) -> Bool {
        if modelID.isEmpty { return true }
        let bare = modelID.hasPrefix("models/") ? String(modelID.dropFirst("models/".count)) : modelID
        guard !bare.isEmpty,
              !bare.contains(".."),
              !bare.contains("/"),
              !bare.contains("\\"),
              !bare.contains("?"),
              !bare.contains("#"),
              !bare.contains("%") else {
            return false
        }
        return true
    }

    private static func normalizeGeminiModelPath(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return trimmed
        }
        return "models/\(trimmed.isEmpty ? "gemini-2.5-flash" : trimmed)"
    }
}
