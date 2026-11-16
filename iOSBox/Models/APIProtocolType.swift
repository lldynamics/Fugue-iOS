import Foundation

enum APIProtocolType: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case anthropic = "anthropic"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible:
            return "OpenAI 兼容协议"
        case .anthropic:
            return "Anthropic Claude 原生"
        case .gemini:
            return "Google Gemini 原生"
        }
    }

    var shortBadge: String {
        switch self {
        case .openAICompatible:
            return "OpenAI"
        case .anthropic:
            return "Claude"
        case .gemini:
            return "Gemini"
        }
    }

    var subtitle: String {
        switch self {
        case .openAICompatible:
            return "支持 OpenAI / DeepSeek / OpenRouter / 硅基流动 / Ollama / 各类中转站"
        case .anthropic:
            return "使用 /v1/messages 接口，原生支持 Extended Thinking 与 PDF 文档"
        case .gemini:
            return "使用 streamGenerateContent 接口，原生支持多模态与思考链"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible:
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
    var value: String
    var isEnabled: Bool = true
}

struct ModelSpec: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var isEnabled: Bool = true
    var supportsVision: Bool = true
    var supportsReasoning: Bool = false

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

    static func inferReasoningSupport(modelID: String) -> Bool {
        let lower = modelID.lowercased()
        let keywords = ["reasoner", "r1", "qwq", "o1", "o3", "o4", "thinking", "claude-3-7", "claude-sonnet-4", "claude-opus-4", "gemini-2.5", "gemini-3"]
        return keywords.contains { lower.contains($0) }
    }

    static func inferVisionSupport(modelID: String) -> Bool {
        let lower = modelID.lowercased()
        if lower.contains("deepseek-chat") || lower.contains("deepseek-reasoner") {
            return false
        }
        let keywords = ["gpt-4", "gpt-5", "o1", "o3", "o4", "claude", "gemini", "vl", "vision", "pixtral", "qvq", "omni"]
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
