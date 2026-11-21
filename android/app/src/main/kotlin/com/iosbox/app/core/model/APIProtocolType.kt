package com.iosbox.app.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
enum class APIProtocolType(val rawValue: String) {
    @SerialName("openai_compatible")
    OPEN_AI_COMPATIBLE("openai_compatible"),

    @SerialName("anthropic")
    ANTHROPIC("anthropic"),

    @SerialName("gemini")
    GEMINI("gemini");

    val displayName: String
        get() = when (this) {
            OPEN_AI_COMPATIBLE -> L10n.text("OpenAI 兼容协议", "OpenAI Compatible")
            ANTHROPIC -> L10n.text("Anthropic Claude 原生", "Anthropic Claude Native")
            GEMINI -> L10n.text("Google Gemini 原生", "Google Gemini Native")
        }

    val shortBadge: String
        get() = when (this) {
            OPEN_AI_COMPATIBLE -> "OpenAI"
            ANTHROPIC -> "Claude"
            GEMINI -> "Gemini"
        }

    val subtitle: String
        get() = when (this) {
            OPEN_AI_COMPATIBLE -> L10n.text(
                "支持 OpenAI / DeepSeek / OpenRouter / 硅基流动 / Ollama / 各类中转站",
                "Works with OpenAI, DeepSeek, OpenRouter, SiliconFlow, Ollama, and relays"
            )
            ANTHROPIC -> L10n.text(
                "使用 /v1/messages 接口，原生支持 Extended Thinking 与 PDF 文档",
                "Uses /v1/messages with native Extended Thinking and PDF support"
            )
            GEMINI -> L10n.text(
                "使用 streamGenerateContent 接口，原生支持多模态与思考链",
                "Uses streamGenerateContent with native multimodal and thinking support"
            )
        }

    val defaultBaseURL: String
        get() = when (this) {
            OPEN_AI_COMPATIBLE -> "https://api.openai.com/v1"
            ANTHROPIC -> "https://api.anthropic.com/v1"
            GEMINI -> "https://generativelanguage.googleapis.com/v1beta"
        }

    companion object {
        fun fromRaw(raw: String): APIProtocolType =
            entries.firstOrNull { it.rawValue == raw } ?: OPEN_AI_COMPATIBLE
    }
}

@Serializable
data class CustomHeader(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val key: String,
    val value: String = "",
    val isEnabled: Boolean = true,
    val isSecret: Boolean = false
) {
    companion object {
        private val sensitiveTokens = listOf(
            "authorization", "api-key", "apikey", "api_key", "token", "secret", "cookie", "password", "x-key"
        )

        fun looksSensitive(key: String): Boolean {
            val lower = key.trim().lowercase()
            return lower == "x-auth" || lower.endsWith("-key") || sensitiveTokens.any { lower.contains(it) }
        }
    }
}

@Serializable
data class ModelSpec(
    val id: String,
    val displayName: String = id,
    val isEnabled: Boolean = true,
    val supportsVision: Boolean = inferVisionSupport(id),
    val supportsReasoning: Boolean = inferReasoningSupport(id),
    val inputPricePerMillion: Double? = null,
    val outputPricePerMillion: Double? = null,
    val cacheReadPricePerMillion: Double? = null,
    val cacheWritePricePerMillion: Double? = null,
    val priceCurrency: String? = null,
    val isFavorite: Boolean? = null,
    val catalogStatus: CatalogStatus? = null,
    val retiredStarterDefault: Boolean? = null
) {
    @Serializable
    enum class CatalogStatus {
        @SerialName("listed")
        LISTED,

        @SerialName("unlisted")
        UNLISTED,

        @SerialName("manual")
        MANUAL
    }

    val isSelectable: Boolean
        get() = isEnabled && catalogStatus != CatalogStatus.UNLISTED

    val isStarred: Boolean
        get() = isFavorite == true

    companion object {
        fun create(
            id: String,
            displayName: String? = null,
            isEnabled: Boolean = true,
            supportsVision: Boolean? = null,
            supportsReasoning: Boolean? = null,
            catalogStatus: CatalogStatus? = null
        ): ModelSpec = ModelSpec(
            id = id,
            displayName = if (!displayName.isNullOrEmpty()) displayName else id,
            isEnabled = isEnabled,
            supportsVision = supportsVision ?: inferVisionSupport(id),
            supportsReasoning = supportsReasoning ?: inferReasoningSupport(id),
            catalogStatus = catalogStatus
        )

        fun inferReasoningSupport(modelID: String): Boolean {
            val lower = modelID.lowercase()
            val keywords = listOf(
                "reasoner", "r1", "deepseek-flash", "deepseek-v4", "qwq", "o1", "o3", "o4",
                "gpt-5", "gpt-6", "thinking", "magistral", "qwen3",
                "claude-3-7", "claude-sonnet-4", "claude-opus-4", "claude-haiku-4", "claude-4",
                "claude-sonnet-5", "claude-opus-5", "claude-haiku-5", "claude-fable-5",
                "gemini-2.5", "gemini-3", "gemini-4"
            )
            return keywords.any { lower.contains(it) }
        }

        fun inferVisionSupport(modelID: String): Boolean {
            val lower = modelID.lowercase()
            if (lower.contains("deepseek-chat") || lower.contains("deepseek-reasoner")) {
                return false
            }
            val keywords = listOf(
                "gpt-4", "gpt-5", "gpt-6", "o1", "o3", "o4", "claude", "gemini",
                "vl", "vision", "pixtral", "qvq", "omni", "deepseek-flash", "deepseek-v4.1-flash"
            )
            return keywords.any { lower.contains(it) }
        }

        fun deduplicated(specs: List<ModelSpec>): List<ModelSpec> {
            val seen = HashSet<String>()
            return specs.filter { seen.add(it.id) }
        }
    }
}

@Serializable
data class ResolvedModelTarget(
    val providerID: String,
    val providerName: String,
    val protocolType: APIProtocolType,
    val modelID: String,
    val modelDisplayName: String,
    val accentHex: String,
    val supportsVision: Boolean,
    val supportsReasoning: Boolean
) {
    val id: String
        get() = "$providerID::$modelID"
}
