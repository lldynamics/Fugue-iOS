import Foundation

struct ProviderTemplate: Identifiable {
    let id: String
    let name: String
    let protocolType: APIProtocolType
    let baseURL: String
    let iconSymbol: String
    let accentHex: String
    let note: String
    let suggestedModels: [ModelSpec]

    static func matching(baseURL: String, protocolType: APIProtocolType) -> ProviderTemplate? {
        guard let endpoint = try? EndpointResolver.modelsEndpoint(baseURL: baseURL, protocolType: protocolType) else { return nil }
        return catalog.first {
            $0.protocolType == protocolType && !$0.suggestedModels.isEmpty
                && (try? EndpointResolver.modelsEndpoint(baseURL: $0.baseURL, protocolType: $0.protocolType)) == endpoint
        }
    }

    /// When the protocol changes, swap the Base URL only if it is empty, a known default for
    /// the old protocol, or the placeholder example. A custom gateway URL is kept as-is.
    static func baseURLAfterProtocolChange(
        currentBaseURL: String,
        from oldProtocol: APIProtocolType,
        to newProtocol: APIProtocolType
    ) -> String {
        guard oldProtocol != newProtocol else { return currentBaseURL }
        let normalized = currentBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let replaceable = Set(
            [oldProtocol.defaultBaseURL, "https://api.example.com/v1"]
                + catalog.filter { $0.protocolType == oldProtocol && $0.id != "ollama" }.map(\.baseURL)
        ).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

        if normalized.isEmpty || replaceable.contains(normalized) {
            return newProtocol.defaultBaseURL
        }
        return currentBaseURL
    }

    static let catalog: [ProviderTemplate] = [
        ProviderTemplate(
            id: "custom_openai",
            name: String(localized: "自定义 OpenAI 兼容中转站"),
            protocolType: .openAICompatible,
            baseURL: "https://api.example.com/v1",
            iconSymbol: "slider.horizontal.below.square.and.square.filled",
            accentHex: "#3F6EF6",
            note: String(localized: "支持 NewAPI / OneAPI / LiteLLM / vLLM 等任意兼容接口；URL 末尾加 # 可禁用自动补全 /v1"),
            suggestedModels: []
        ),
        ProviderTemplate(
            id: "deepseek",
            name: String(localized: "DeepSeek 深度求索"),
            protocolType: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            iconSymbol: "brain.head.profile",
            accentHex: "#4D6BFE",
            note: String(localized: "DeepSeek 官方接口，支持对话和深度思考。"),
            suggestedModels: [
                ModelSpec(id: "deepseek-flash", displayName: "DeepSeek V4.1 Flash", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", supportsVision: false, supportsReasoning: true)
            ]
        ),
        ProviderTemplate(
            id: "openrouter",
            name: "OpenRouter",
            protocolType: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            iconSymbol: "arrow.triangle.branch",
            accentHex: "#6366F1",
            note: String(localized: "一个 Key 聚合全球数百个主流与开源模型，支持一键拉取全部模型"),
            suggestedModels: [
                ModelSpec(id: "openrouter/auto", displayName: "OpenRouter Auto", supportsVision: true, supportsReasoning: false)
            ]
        ),
        ProviderTemplate(
            id: "siliconflow",
            name: String(localized: "SiliconFlow 硅基流动"),
            protocolType: .openAICompatible,
            baseURL: "https://api.siliconflow.cn/v1",
            iconSymbol: "cpu.fill",
            accentHex: "#7C3AED",
            note: String(localized: "国内高速推理平台，聚合 DeepSeek / Qwen / GLM 等模型"),
            suggestedModels: [
                ModelSpec(id: "deepseek-ai/DeepSeek-V4.1-Flash", displayName: "DeepSeek V4.1 Flash", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "deepseek-ai/DeepSeek-V4-Pro", displayName: "DeepSeek V4 Pro", supportsVision: false, supportsReasoning: true)
            ]
        ),
        ProviderTemplate(
            id: "openai",
            name: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            iconSymbol: "circle.hexagongrid.fill",
            accentHex: "#10A37F",
            note: String(localized: "OpenAI 官方接口，支持一键拉取账户可用模型"),
            suggestedModels: [
                ModelSpec(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol"),
                ModelSpec(id: "gpt-6.2-astra", displayName: "GPT-6.2 Astra"),
                ModelSpec(id: "gpt-6-luna", displayName: "GPT-6 Luna")
            ]
        ),
        ProviderTemplate(
            id: "openai_responses",
            name: "OpenAI Responses API",
            protocolType: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            iconSymbol: "bolt.horizontal.circle",
            accentHex: "#0D9488",
            note: String(localized: "OpenAI 新一代 /v1/responses 协议，原生支持推理摘要与内置联网检索"),
            suggestedModels: [
                ModelSpec(id: "gpt-5", displayName: "GPT-5", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "o3", displayName: "OpenAI o3", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "gpt-4.1", displayName: "GPT-4.1", supportsVision: true, supportsReasoning: false)
            ]
        ),
        ProviderTemplate(
            id: "anthropic",
            name: "Anthropic Claude",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            iconSymbol: "sparkles",
            accentHex: "#D97757",
            note: String(localized: "Anthropic 原生 /v1/messages 协议，支持 Extended Thinking 与原版 PDF 解析"),
            suggestedModels: [
                ModelSpec(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5"),
                ModelSpec(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"),
                ModelSpec(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5"),
                ModelSpec(id: "claude-fable-5-2", displayName: "Claude Fable 5.2")
            ]
        ),
        ProviderTemplate(
            id: "gemini",
            name: "Google Gemini",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            iconSymbol: "wand.and.stars",
            accentHex: "#2563EB",
            note: String(localized: "Google AI Studio 原生协议，支持多模态识图、PDF 文档及思考过程展示"),
            suggestedModels: [
                ModelSpec(id: "gemini-4-neon", displayName: "Gemini 4 Neon"),
                ModelSpec(id: "gemini-4-hydrogen", displayName: "Gemini 4 Hydrogen"),
                ModelSpec(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash")
            ]
        ),
        ProviderTemplate(
            id: "ollama",
            name: String(localized: "Ollama / 局域网本地模型"),
            protocolType: .openAICompatible,
            baseURL: "http://192.168.1.100:11434/v1",
            iconSymbol: "desktopcomputer",
            accentHex: "#059669",
            note: String(localized: "连接局域网电脑运行的 Ollama / LM Studio，API Key 可留空"),
            suggestedModels: []
        )
    ]
}
