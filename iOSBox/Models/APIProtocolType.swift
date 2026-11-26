import Foundation

enum APIProtocolType: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case openAIResponses = "openai_responses"
    case anthropic = "anthropic"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible:
            return String(localized: "OpenAI 兼容协议")
        case .openAIResponses:
            return String(localized: "OpenAI Responses API")
        case .anthropic:
            return String(localized: "Anthropic Claude 原生")
        case .gemini:
            return String(localized: "Google Gemini 原生")
        }
    }

    var shortBadge: String {
        switch self {
        case .openAICompatible:
            return "Chat Completions"
        case .openAIResponses:
            return "Responses API"
        case .anthropic:
            return "Claude"
        case .gemini:
            return "Gemini"
        }
    }

    var subtitle: String {
        switch self {
        case .openAICompatible:
            return String(localized: "支持 OpenAI / DeepSeek / OpenRouter / 硅基流动 / Ollama / 各类中转站")
        case .openAIResponses:
            return String(localized: "使用 /v1/responses 新一代接口，支持推理摘要、原生联网检索与多轮工具调用")
        case .anthropic:
            return String(localized: "使用 /v1/messages 接口，原生支持 Extended Thinking 与 PDF 文档")
        case .gemini:
            return String(localized: "使用 streamGenerateContent 接口，原生支持多模态与思考链")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible, .openAIResponses:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var symbolName: String {
        switch self {
        case .openAICompatible:
            return "point.3.connected.trianglepath.dotted"
        case .openAIResponses:
            return "bolt.horizontal.circle"
        case .anthropic:
            return "sparkles"
        case .gemini:
            return "wand.and.stars"
        }
    }
}

struct CustomHeader: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var key: String
    /// For secret headers this is empty in the database; the real value lives in the Keychain
    /// (see `ProviderConfig.resolvedCustomHeaders`).
    var value: String
    var isEnabled: Bool = true
    var isSecret: Bool = false

    init(id: UUID = UUID(), key: String, value: String, isEnabled: Bool = true, isSecret: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.isSecret = isSecret
    }

    // Tolerates data saved before `isSecret` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decode(String.self, forKey: .key)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }

    /// Header names that typically carry credentials.
    static func looksSensitive(_ key: String) -> Bool {
        let lower = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "x-auth" || lower.hasSuffix("-key") || ["authorization", "api-key", "apikey", "api_key", "token", "secret", "cookie", "password", "x-key"]
            .contains { lower.contains($0) }
    }
}

struct PracticeAudioRates: Codable, Hashable {
    var input: Double?
    var output: Double?
    var cachedInput: Double?
    var perMinute: Double?
}

struct ModelSpec: Codable, Hashable, Identifiable {
    enum CatalogStatus: String, Codable {
        case listed, unlisted, manual
    }

    var id: String
    var displayName: String
    var isEnabled: Bool = true
    var supportsVision: Bool = true
    var supportsReasoning: Bool = false
    /// Optional for backwards-compatible decoding of existing model configurations.
    var inputPricePerMillion: Double?
    var outputPricePerMillion: Double?
    var cacheReadPricePerMillion: Double?
    var cacheWritePricePerMillion: Double?
    var priceCurrency: String?
    var audioRates: PracticeAudioRates?
    var priceSource: ModelPriceSource?
    var reportedMedia: ModelMediaCapabilities?
    var isFavorite: Bool?
    // Older configurations have no provenance until their next catalog refresh.
    var catalogStatus: CatalogStatus?
    var retiredStarterDefault: Bool?

    var isSelectable: Bool { isEnabled && catalogStatus != .unlisted }

    var isStarred: Bool {
        get { isFavorite == true }
        set { isFavorite = newValue ? true : nil }
    }

    init(
        id: String,
        displayName: String? = nil,
        isEnabled: Bool = true,
        supportsVision: Bool? = nil,
        supportsReasoning: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName?.isEmpty == false ? displayName! : id
        self.isEnabled = isEnabled
        self.supportsVision = supportsVision ?? Self.inferVisionSupport(modelID: id)
        self.supportsReasoning = supportsReasoning ?? Self.inferReasoningSupport(modelID: id)
    }

    /// Default for newly added models; users can toggle it per model. This flag decides
    /// whether thinking / reasoning parameters are sent to the API.
    static func inferReasoningSupport(modelID: String) -> Bool {
        let lower = modelID.lowercased()
        let keywords = [
            "reasoner", "r1", "deepseek-flash", "deepseek-v4", "qwq", "o1", "o3", "o4", "gpt-5", "gpt-6", "thinking", "magistral", "qwen3",
            "claude-3-7", "claude-sonnet-4", "claude-opus-4", "claude-haiku-4", "claude-4",
            "claude-sonnet-5", "claude-opus-5", "claude-haiku-5", "claude-fable-5", "gemini-2.5", "gemini-3", "gemini-4"
        ]
        return keywords.contains { lower.contains($0) }
    }

    static func inferVisionSupport(modelID: String) -> Bool {
        let lower = modelID.lowercased()
        if lower.contains("deepseek-chat") || lower.contains("deepseek-reasoner") {
            return false
        }
        let keywords = ["gpt-4", "gpt-5", "gpt-6", "o1", "o3", "o4", "claude", "gemini", "vl", "vision", "pixtral", "qvq", "omni", "deepseek-flash", "deepseek-v4.1-flash"]
        return keywords.contains { lower.contains($0) }
    }
}

struct ResolvedModelTarget: Codable, Hashable, Identifiable {
    var providerID: UUID
    var providerName: String
    var protocolType: APIProtocolType
    var modelID: String
    var modelDisplayName: String
    var accentHex: String
    var supportsVision: Bool
    var supportsReasoning: Bool

    var id: String {
        "\(providerID.uuidString)::\(modelID)"
    }
}
