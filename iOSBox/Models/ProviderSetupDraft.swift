import Foundation

/// Unsaved connection fields shared by guided setup and manual creation.
struct ProviderSetupDraft: Equatable, Identifiable {
    let id = UUID()
    var name: String
    var protocolType: APIProtocolType {
        didSet {
            if protocolType != oldValue {
                manualModelID = ""
                importedModels = []
            }
        }
    }
    var baseURL: String {
        didSet {
            guard baseURL != oldValue else { return }
            manualModelID = ""
            importedModels = []
            if !Self.sameOrigin(oldValue, baseURL) {
                apiKey = ""
                if ProviderTemplate.setupChoices.contains(where: { $0.setupName == name }),
                   let template = ProviderTemplate.setupChoices.first(where: { $0.id == serviceID }) {
                    name = template.setupName
                    accentHex = template.accentHex
                    iconSymbol = template.iconSymbol
                }
            }
        }
    }
    var apiKey: String
    var manualModelID = ""
    var accentHex: String
    var iconSymbol: String
    private var importedModels: [ModelSpec] = []

    init(template: ProviderTemplate = .openAIResponses, apiKey: String = "") {
        name = template.setupName
        protocolType = template.protocolType
        baseURL = template.baseURL
        self.apiKey = apiKey
        accentHex = template.accentHex
        iconSymbol = template.iconSymbol
    }

    var suggestedModels: [ModelSpec] {
        ProviderTemplate.matching(baseURL: baseURL, protocolType: protocolType)?.suggestedModels ?? importedModels
    }

    var serviceID: String {
        let host = URLComponents(string: baseURL)?.host?.lowercased()
        if let host, let known = ProviderTemplate.setupChoices.first(where: { URLComponents(string: $0.baseURL)?.host == host }) {
            return known.id
        }
        return NetworkLocation.isLocalOrPrivate(baseURL: baseURL) ? "ollama" : "custom_openai"
    }

    mutating func select(_ template: ProviderTemplate) {
        let retainedKey = Self.sameOrigin(baseURL, template.baseURL) ? apiKey : ""
        self = Self(template: template, apiKey: retainedKey)
    }

    mutating func apply(_ candidate: ClipboardProviderCandidate) {
        // A bare, generic sk- key carries no information about its issuer.
        if candidate.isGenericOpenAIKey {
            apiKey = candidate.apiKey
            return
        }
        let previousProtocol = protocolType
        let sameOrigin = Self.sameOrigin(baseURL, candidate.baseURL)
        baseURL = candidate.baseURL
        name = candidate.providerName
        iconSymbol = candidate.iconSymbol
        accentHex = candidate.accentHex
        var newProtocol = candidate.explicitProtocol ?? candidate.protocolType
        if candidate.explicitProtocol == nil, serviceID == ProviderTemplate.openAIResponses.id {
            name = ProviderTemplate.openAIResponses.setupName
            let path = URL(string: baseURL)?.standardized.path
            if path?.hasSuffix("/chat/completions") == true {
                newProtocol = .openAICompatible
            } else if path?.hasSuffix("/responses") == true || !sameOrigin || previousProtocol != .openAICompatible {
                newProtocol = .openAIResponses
            }
        }
        protocolType = newProtocol
        importedModels = candidate.suggestedModels
        if let extractedModel = candidate.extractedModelID, !extractedModel.isEmpty {
            manualModelID = extractedModel
        }
        if !candidate.apiKey.isEmpty { apiKey = candidate.apiKey }
    }

    private static func sameOrigin(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = URLComponents(string: lhs), let right = URLComponents(string: rhs),
              let host = left.host?.lowercased(), let scheme = left.scheme?.lowercased() else { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return host == right.host?.lowercased() && scheme == right.scheme?.lowercased()
            && (left.port ?? defaultPort) == (right.port ?? defaultPort)
    }
}

extension ProviderTemplate {
    // Protocol variants of the same service belong in advanced settings.
    static let setupChoices = [openAIResponses, openRouter]
        + catalog.filter { !["openai_responses", "openrouter", "openai", "custom_openai"].contains($0.id) }
        + catalog.filter { $0.id == "custom_openai" }

    var setupName: String {
        switch id {
        case "openai_responses", "openai": return String(localized: "OpenAI 官方")
        case "custom_openai": return String(localized: "自定义服务商")
        default: return name
        }
    }

    /// Identify distinct issuer prefixes when pasted against a mismatched official destination.
    /// Custom relay hosts return nil so proxy gateways that pass upstream keys keep working.
    static func mismatchedIssuer(apiKey: String, baseURL: String) -> ProviderTemplate? {
        let key = LLMClient.sanitizedAPIKey(apiKey)
        guard !key.isEmpty, let host = URLComponents(string: baseURL)?.host?.lowercased() else { return nil }
        let officialHosts: Set<String> = [
            "api.openai.com", "openrouter.ai", "api.deepseek.com", "api.siliconflow.cn",
            "api.anthropic.com", "generativelanguage.googleapis.com", "api.groq.com",
            "api.x.ai", "dashscope.aliyuncs.com", "api.moonshot.cn", "open.bigmodel.cn"
        ]
        guard officialHosts.contains(host) && !OpenAICompatibleAdapter.isOpenRouter(baseURL) || OpenAICompatibleAdapter.isOpenRouter(baseURL) else {
            return nil
        }
        let isKnownOfficial = officialHosts.contains(host) || OpenAICompatibleAdapter.isOpenRouter(baseURL)
        guard isKnownOfficial else { return nil }

        if key.hasPrefix("sk-or-"), !OpenAICompatibleAdapter.isOpenRouter(baseURL) {
            return openRouter
        }
        if (key.hasPrefix("sk-proj-") || key.hasPrefix("sk-svcacct-")), host != "api.openai.com" {
            return openAIResponses
        }
        if key.hasPrefix("sk-ant-"), host != "api.anthropic.com" {
            return catalog.first { $0.id == "anthropic" }
        }
        if key.hasPrefix("AIza"), host != "generativelanguage.googleapis.com" {
            return catalog.first { $0.id == "gemini" }
        }
        if key.hasPrefix("gsk_"), host != "api.groq.com" {
            return groq
        }
        if key.hasPrefix("xai-"), host != "api.x.ai" {
            return xai
        }
        return nil
    }
}
