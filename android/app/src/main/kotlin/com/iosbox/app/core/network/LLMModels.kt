package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

sealed class LLMError(override val message: String) : Exception(message) {
    class InvalidURL(raw: String) : LLMError(
        L10n.text("无效的接口地址：$raw", "Invalid endpoint URL: $raw")
    )

    class InsecurePublicHttp(raw: String) : LLMError(
        L10n.text(
            "安全策略拦截：公网地址必须使用 HTTPS，仅局域网或本机地址允许 HTTP（$raw）",
            "Blocked insecure HTTP to a public host. Use HTTPS or a local/LAN host ($raw)."
        )
    )

    class MissingAPIKey(provider: String) : LLMError(
        L10n.text(
            "请先在「设置」页面为「$provider」配置 API Key（本地服务若免鉴权可忽略）",
            "Configure an API key for \"$provider\" in Settings first (local auth-free servers can omit it)."
        )
    )

    class HttpError(val statusCode: Int, val detail: String) : LLMError("HTTP $statusCode：$detail")
    class ApiError(msg: String) : LLMError(msg)
    class InterruptedStream : LLMError(
        L10n.text("连接提前结束，回复可能不完整，请重试。", "Connection ended early; the reply may be incomplete. Please retry.")
    )

    class EmptyResponse : LLMError(
        L10n.text("服务端未返回有效内容", "The server returned no valid content.")
    )

    class UnavailableModel : LLMError(
        L10n.text("此服务商或模型已停用、删除或更改，请重新选择模型。", "This provider or model is disabled, removed, or changed.")
    )

    class UnavailableTool : LLMError(
        L10n.text("模型请求了本轮未启用的工具，已停止处理。", "The model called a tool that is not enabled for this turn.")
    )

    class ConsentRequired : LLMError(
        L10n.text("请先确认接收方并授权发送。", "Please review and accept AI data transmission before sending.")
    )
}

@Serializable
data class LLMToolDefinition(
    val name: String,
    val description: String,
    val parametersSchemaJSON: String
) {
    fun parametersObject(json: Json): JsonObject =
        runCatching { json.parseToJsonElement(parametersSchemaJSON) as? JsonObject }.getOrNull()
            ?: buildJsonObject {
                put("type", "object")
                put("properties", buildJsonObject {})
            }
}

@Serializable
data class LLMThinkingBlock(
    val kind: Kind,
    val thinking: String,
    val signature: String? = null,
    val redactedData: String? = null
) {
    @Serializable
    enum class Kind {
        @SerialName("thinking")
        THINKING,

        @SerialName("redacted_thinking")
        REDACTED_THINKING
    }

    companion object {
        fun thinking(thinking: String, signature: String?): LLMThinkingBlock =
            LLMThinkingBlock(Kind.THINKING, thinking, signature, null)

        fun redacted(redactedData: String): LLMThinkingBlock =
            LLMThinkingBlock(Kind.REDACTED_THINKING, "", null, redactedData)
    }
}

@Serializable
data class LLMToolCall(
    val id: String,
    val name: String,
    val argumentsJSON: String,
    val thoughtSignature: String? = null
) {
    fun argumentsObject(json: Json): JsonObject =
        runCatching { json.parseToJsonElement(argumentsJSON) as? JsonObject }.getOrNull() ?: buildJsonObject {}
}

data class LLMPromptMessage(
    val role: MessageRole,
    val content: String,
    val reasoningContent: String = "",
    val thinkingBlocks: List<LLMThinkingBlock> = emptyList(),
    val attachments: List<MessageAttachment> = emptyList(),
    val toolCalls: List<LLMToolCall> = emptyList(),
    val toolCallID: String? = null,
    val toolName: String? = null
)

data class LLMChatRequest(
    val providerName: String,
    val protocolType: APIProtocolType,
    val baseURL: String,
    val apiKey: String,
    val apiKeys: List<String> = emptyList(),
    val customHeaders: List<CustomHeader> = emptyList(),
    val modelID: String,
    val supportsReasoning: Boolean,
    val systemPrompt: String,
    val messages: List<LLMPromptMessage>,
    val temperature: Double?,
    val topP: Double,
    val maxOutputTokens: Int?,
    val enableThinking: Boolean,
    val thinkingBudgetTokens: Int,
    val enablePromptCaching: Boolean = false,
    val enableNativeSearch: Boolean = false,
    val idleTimeoutSeconds: Double? = null,
    val tools: List<LLMToolDefinition> = emptyList(),
    val validateBeforeSending: (suspend () -> Unit)? = null
) {
    val effectiveAPIKeys: List<String>
        get() {
            val result = mutableListOf<String>()
            val seen = HashSet<String>()
            for (raw in listOf(apiKey) + apiKeys) {
                val trimmed = LLMClient.sanitizedAPIKey(raw)
                if (trimmed.isNotEmpty() && seen.add(trimmed)) {
                    result.add(trimmed)
                }
            }
            return result
        }
}

data class LLMPingResult(
    val modelID: String,
    val ttftMs: Int,
    val totalMs: Int
)

@Serializable
enum class LLMFinishReason(val rawValue: String) {
    @SerialName("length")
    LENGTH("length"),

    @SerialName("content_filter")
    CONTENT_FILTER("content_filter");

    val userNotice: String
        get() = when (this) {
            LENGTH -> L10n.text(
                "回复已达到最大输出长度，内容可能不完整。可在会话参数中调大「最大输出 Tokens」后重答。",
                "Reply reached the max output token limit and may be truncated. Increase Max Output Tokens in chat settings and retry."
            )
            CONTENT_FILTER -> L10n.text(
                "回复被模型服务商的安全策略拦截或截断。",
                "Reply was blocked or truncated by the provider's safety filter."
            )
        }

    companion object {
        fun fromProviderValue(raw: String?): LLMFinishReason? {
            val value = raw?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            return when (value) {
                "length", "max_tokens", "model_context_window_exceeded" -> LENGTH
                "content_filter", "refusal", "safety", "recitation", "prohibited_content",
                "blocklist", "spii", "image_safety" -> CONTENT_FILTER
                else -> null
            }
        }
    }
}

sealed interface LLMStreamEvent {
    data class Retrying(val httpStatus: Int) : LLMStreamEvent
    data object NonStreamingResponse : LLMStreamEvent
    data class ReasoningDelta(val text: String) : LLMStreamEvent
    data class ThinkingBlock(val block: LLMThinkingBlock) : LLMStreamEvent
    data class ContentDelta(val text: String) : LLMStreamEvent
    data class AttachmentDelta(val attachment: MessageAttachment) : LLMStreamEvent
    data class ToolCall(val call: LLMToolCall) : LLMStreamEvent
    data class GroundingSource(val title: String, val url: String) : LLMStreamEvent
    data class Usage(val promptTokens: Int?, val completionTokens: Int?) : LLMStreamEvent
    data class CacheUsage(val cachedTokens: Int?, val cacheWriteTokens: Int?) : LLMStreamEvent
    data class Finished(val reason: LLMFinishReason) : LLMStreamEvent
    data object Done : LLMStreamEvent
}

@Serializable
enum class GatewayUnsupportedFeature(val rawValue: String) {
    @SerialName("stream_options")
    STREAM_OPTIONS("stream_options"),

    @SerialName("prompt_caching")
    PROMPT_CACHING("prompt_caching"),

    @SerialName("native_search")
    NATIVE_SEARCH("native_search"),

    @SerialName("thinking_config")
    THINKING_CONFIG("thinking_config"),

    @SerialName("reasoning_content")
    REASONING_CONTENT("reasoning_content"),

    @SerialName("reasoning_params")
    REASONING_PARAMS("reasoning_params"),

    @SerialName("max_completion_tokens")
    MAX_COMPLETION_TOKENS("max_completion_tokens"),

    @SerialName("requires_max_completion_tokens")
    REQUIRES_MAX_COMPLETION_TOKENS("requires_max_completion_tokens"),

    @SerialName("sampling_params")
    SAMPLING_PARAMS("sampling_params")
}
