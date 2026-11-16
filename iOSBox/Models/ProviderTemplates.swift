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

    static let catalog: [ProviderTemplate] = [
        ProviderTemplate(
            id: "custom_openai",
            name: "自定义 OpenAI 兼容中转站",
            protocolType: .openAICompatible,
            baseURL: "https://api.example.com/v1",
            iconSymbol: "slider.horizontal.below.square.and.square.filled",
            accentHex: "#3F6EF6",
            note: "支持 NewAPI / OneAPI / LiteLLM / vLLM 等任意兼容接口；URL 末尾加 # 可禁用自动补全 /v1",
            suggestedModels: []
        ),
        ProviderTemplate(
            id: "deepseek",
            name: "DeepSeek 深度求索",
            protocolType: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            iconSymbol: "brain.head.profile",
            accentHex: "#4D6BFE",
            note: "官方直连，支持 DeepSeek-V3 与 DeepSeek-R1 深度思考链",
            suggestedModels: [
                ModelSpec(id: "deepseek-chat", displayName: "DeepSeek V3", supportsVision: false, supportsReasoning: false),
                ModelSpec(id: "deepseek-reasoner", displayName: "DeepSeek R1", supportsVision: false, supportsReasoning: true)
            ]
        ),
        ProviderTemplate(
            id: "openrouter",
            name: "OpenRouter",
            protocolType: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            iconSymbol: "arrow.triangle.branch",
            accentHex: "#6366F1",
            note: "一个 Key 聚合全球数百个主流与开源模型，支持一键拉取全部模型",
            suggestedModels: [
                ModelSpec(id: "openai/gpt-4.1", displayName: "GPT-4.1", supportsVision: true, supportsReasoning: false),
                ModelSpec(id: "anthropic/claude-sonnet-4", displayName: "Claude Sonnet 4", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "google/gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "deepseek/deepseek-r1", displayName: "DeepSeek R1", supportsVision: false, supportsReasoning: true)
            ]
        ),
        ProviderTemplate(
            id: "siliconflow",
            name: "SiliconFlow 硅基流动",
            protocolType: .openAICompatible,
            baseURL: "https://api.siliconflow.cn/v1",
            iconSymbol: "cpu.fill",
            accentHex: "#7C3AED",
            note: "国内高速推理平台，聚合 DeepSeek / Qwen / GLM 等模型",
            suggestedModels: [
                ModelSpec(id: "deepseek-ai/DeepSeek-R1", displayName: "DeepSeek-R1", supportsVision: false, supportsReasoning: true),
                ModelSpec(id: "deepseek-ai/DeepSeek-V3", displayName: "DeepSeek-V3", supportsVision: false, supportsReasoning: false),
                ModelSpec(id: "Qwen/Qwen2.5-VL-72B-Instruct", displayName: "Qwen2.5-VL-72B", supportsVision: true, supportsReasoning: false)
            ]
        ),
        ProviderTemplate(
            id: "openai",
            name: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            iconSymbol: "circle.hexagongrid.fill",
            accentHex: "#10A37F",
            note: "OpenAI 官方接口，支持一键拉取账户可用模型",
            suggestedModels: [
                ModelSpec(id: "gpt-4.1", displayName: "GPT-4.1", supportsVision: true, supportsReasoning: false),
                ModelSpec(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", supportsVision: true, supportsReasoning: false),
                ModelSpec(id: "o4-mini", displayName: "o4-mini", supportsVision: true, supportsReasoning: true)
            ]
        ),
        ProviderTemplate(
            id: "anthropic",
            name: "Anthropic Claude",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            iconSymbol: "sparkles",
            accentHex: "#D97757",
            note: "Anthropic 原生 /v1/messages 协议，支持 Extended Thinking 与原版 PDF 解析",
            suggestedModels: [
                ModelSpec(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "claude-3-7-sonnet-latest", displayName: "Claude 3.7 Sonnet", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "claude-3-5-haiku-latest", displayName: "Claude 3.5 Haiku", supportsVision: true, supportsReasoning: false)
            ]
        ),
        ProviderTemplate(
            id: "gemini",
            name: "Google Gemini",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            iconSymbol: "wand.and.stars",
            accentHex: "#2563EB",
            note: "Google AI Studio 原生协议，支持多模态识图、PDF 文档及思考过程展示",
            suggestedModels: [
                ModelSpec(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsVision: true, supportsReasoning: true),
                ModelSpec(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", supportsVision: true, supportsReasoning: true)
            ]
        ),
        ProviderTemplate(
            id: "ollama",
            name: "Ollama / 局域网本地模型",
            protocolType: .openAICompatible,
            baseURL: "http://192.168.1.100:11434/v1",
            iconSymbol: "desktopcomputer",
            accentHex: "#059669",
            note: "连接局域网电脑运行的 Ollama / LM Studio，API Key 可留空",
            suggestedModels: []
        )
    ]
}
