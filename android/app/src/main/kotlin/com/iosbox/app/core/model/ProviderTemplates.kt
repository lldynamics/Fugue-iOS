package com.iosbox.app.core.model

import com.iosbox.app.core.network.EndpointResolver

data class ProviderTemplate(
    val id: String,
    val name: String,
    val protocolType: APIProtocolType,
    val baseURL: String,
    val iconSymbol: String,
    val accentHex: String,
    val note: String,
    val suggestedModels: List<ModelSpec>
) {
    companion object {
        val catalog: List<ProviderTemplate> by lazy {
            listOf(
                ProviderTemplate(
                    id = "custom_openai",
                    name = L10n.text("自定义 OpenAI 兼容中转站", "Custom OpenAI-Compatible Relay"),
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    baseURL = "https://api.example.com/v1",
                    iconSymbol = "slider.horizontal.below.square.and.square.filled",
                    accentHex = "#3F6EF6",
                    note = L10n.text(
                        "支持 NewAPI / OneAPI / LiteLLM / vLLM 等任意兼容接口；URL 末尾加 # 可禁用自动补全 /v1",
                        "Supports NewAPI, OneAPI, LiteLLM, vLLM, and any compatible gateway. Append # to keep the raw path."
                    ),
                    suggestedModels = emptyList()
                ),
                ProviderTemplate(
                    id = "deepseek",
                    name = L10n.text("DeepSeek 深度求索", "DeepSeek"),
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    baseURL = "https://api.deepseek.com/v1",
                    iconSymbol = "brain.head.profile",
                    accentHex = "#4D6BFE",
                    note = L10n.text(
                        "DeepSeek 官方接口，支持对话和深度思考。",
                        "Official DeepSeek API with chat and deep reasoning support."
                    ),
                    suggestedModels = listOf(
                        ModelSpec.create("deepseek-flash", "DeepSeek V4.1 Flash", supportsVision = true, supportsReasoning = true),
                        ModelSpec.create("deepseek-v4-pro", "DeepSeek V4 Pro", supportsVision = false, supportsReasoning = true)
                    )
                ),
                ProviderTemplate(
                    id = "openrouter",
                    name = "OpenRouter",
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    baseURL = "https://openrouter.ai/api/v1",
                    iconSymbol = "arrow.triangle.branch",
                    accentHex = "#6366F1",
                    note = L10n.text(
                        "一个 Key 聚合全球数百个主流与开源模型，支持一键拉取全部模型",
                        "Access hundreds of hosted and open models with one key and fetch the full model list."
                    ),
                    suggestedModels = listOf(
                        ModelSpec.create("openrouter/auto", "OpenRouter Auto", supportsVision = true, supportsReasoning = false)
                    )
                ),
                ProviderTemplate(
                    id = "siliconflow",
                    name = L10n.text("SiliconFlow 硅基流动", "SiliconFlow"),
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    baseURL = "https://api.siliconflow.cn/v1",
                    iconSymbol = "cpu.fill",
                    accentHex = "#7C3AED",
                    note = L10n.text(
                        "国内高速推理平台，聚合 DeepSeek / Qwen / GLM 等模型",
                        "High-speed inference platform hosting DeepSeek, Qwen, GLM, and more."
                    ),
                    suggestedModels = listOf(
                        ModelSpec.create("deepseek-ai/DeepSeek-V4.1-Flash", "DeepSeek V4.1 Flash", supportsVision = true, supportsReasoning = true),
                        ModelSpec.create("deepseek-ai/DeepSeek-V4-Pro", "DeepSeek V4 Pro", supportsVision = false, supportsReasoning = true)
                    )
                ),
                ProviderTemplate(
                    id = "openai",
                    name = "OpenAI",
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    baseURL = "https://api.openai.com/v1",
                    iconSymbol = "circle.hexagongrid.fill",
                    accentHex = "#10A37F",
                    note = L10n.text(
                        "OpenAI 官方接口，支持一键拉取账户可用模型",
                        "Official OpenAI API with one-tap account model listing."
                    ),
                    suggestedModels = listOf(
                        ModelSpec.create("gpt-6.2-sol", "GPT-6.2 Sol"),
                        ModelSpec.create("gpt-6.2-astra", "GPT-6.2 Astra"),
                        ModelSpec.create("gpt-6-luna", "GPT-6 Luna")
                    )
                ),
                ProviderTemplate(
                    id = "anthropic",
                    name = "Anthropic Claude",
                    protocolType = APIProtocolType.ANTHROPIC,
                    baseURL = "https://api.anthropic.com/v1",
                    iconSymbol = "sparkles",
                    accentHex = "#D97757",
                    note = L10n.text(
                        "Anthropic 原生 /v1/messages 协议，支持 Extended Thinking 与原版 PDF 解析",
                        "Native Anthropic /v1/messages protocol with Extended Thinking and PDF document support."
                    ),
                    suggestedModels = listOf(
                        ModelSpec.create("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                        ModelSpec.create("claude-opus-5-5", "Claude Opus 5.5"),
                        ModelSpec.create("claude-haiku-5-5", "Claude Haiku 5.5"),
                        ModelSpec.create("claude-fable-5-2", "Claude Fable 5.2")
                    )
                ),
                ProviderTemplate(
                    id = "gemini",
                    name = "Google Gemini",
                    protocolType = APIProtocolType.GEMINI,
                    baseURL = "https://generativelanguage.googleapis.com/v1beta",
                    iconSymbol = "wand.and.stars",
                    accentHex = "#2563EB",
                    note = L10n.text(
                        "Google AI Studio 原生协议，支持多模态识图、PDF 文档及思考过程展示",
                        "Native Google AI Studio protocol with image/PDF input and thinking summaries."
                    ),
                    suggestedModels = listOf(
                        ModelSpec.create("gemini-4-neon", "Gemini 4 Neon"),
                        ModelSpec.create("gemini-4-hydrogen", "Gemini 4 Hydrogen"),
                        ModelSpec.create("gemini-3.8-flash", "Gemini 3.8 Flash")
                    )
                ),
                ProviderTemplate(
                    id = "ollama",
                    name = L10n.text("Ollama / 局域网本地模型", "Ollama / Local LAN Model"),
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    baseURL = "http://192.168.1.100:11434/v1",
                    iconSymbol = "desktopcomputer",
                    accentHex = "#059669",
                    note = L10n.text(
                        "连接局域网电脑运行的 Ollama / LM Studio，API Key 可留空",
                        "Connect to Ollama or LM Studio on your local network. API key can be left empty."
                    ),
                    suggestedModels = emptyList()
                )
            )
        }

        fun matching(baseURL: String, protocolType: APIProtocolType): ProviderTemplate? {
            val endpoint = runCatching { EndpointResolver.modelsEndpoint(baseURL, protocolType) }.getOrNull() ?: return null
            return catalog.firstOrNull { tpl ->
                tpl.protocolType == protocolType &&
                    tpl.suggestedModels.isNotEmpty() &&
                    runCatching { EndpointResolver.modelsEndpoint(tpl.baseURL, tpl.protocolType) }.getOrNull() == endpoint
            }
        }

        fun baseURLAfterProtocolChange(
            currentBaseURL: String,
            fromOldProtocol: APIProtocolType,
            toNewProtocol: APIProtocolType
        ): String {
            if (fromOldProtocol == toNewProtocol) return currentBaseURL
            val normalized = currentBaseURL.trim().trim('/')
            val replaceable = buildSet {
                add(fromOldProtocol.defaultBaseURL.trim('/'))
                add("https://api.example.com/v1")
                catalog.filter { it.protocolType == fromOldProtocol && it.id != "ollama" }
                    .forEach { add(it.baseURL.trim('/')) }
            }
            return if (normalized.isEmpty() || replaceable.contains(normalized)) {
                toNewProtocol.defaultBaseURL
            } else {
                currentBaseURL
            }
        }
    }
}
