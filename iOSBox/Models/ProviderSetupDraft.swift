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
        var newProtocol = candidate.protocolType
        if serviceID == ProviderTemplate.openAIResponses.id {
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

    /// Only identify distinct issuer prefixes at the two official destinations.
    static func mismatchedIssuer(apiKey: String, baseURL: String) -> ProviderTemplate? {
        let key = LLMClient.sanitizedAPIKey(apiKey)
        if OpenAICompatibleAdapter.isOpenRouter(baseURL), key.hasPrefix("sk-proj-") || key.hasPrefix("sk-svcacct-") {
            return openAIResponses
        }
        if URLComponents(string: baseURL)?.host?.lowercased() == "api.openai.com", key.hasPrefix("sk-or-") {
            return openRouter
        }
        return nil
    }
}
