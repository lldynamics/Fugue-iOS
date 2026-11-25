package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ModelSpec
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSource
import java.io.IOException

object AnthropicAdapter {
    private const val ANTHROPIC_VERSION = "2023-06-01"
    const val THINKING_OUTPUT_CAP = 32_000
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    private val compactJson = Json { ignoreUnknownKeys = true }

    private data class WireOptions(
        val useCache: Boolean,
        val useNativeSearch: Boolean,
        val useThinking: Boolean,
        val clampMaxTokensTo4096: Boolean
    )

    private data class PendingToolBlock(
        val id: String,
        val name: String,
        var json: String = "",
        val initialInput: JsonElement? = null
    )

    private data class PendingThinkingBlock(
        var thinking: String = "",
        var signature: String = ""
    )

    fun streamChat(client: LLMClient, request: LLMChatRequest): Flow<LLMStreamEvent> {
        val cache = client.capabilityCache
        val initial = WireOptions(
            useCache = request.enablePromptCaching && !cache.isUnsupported(
                GatewayUnsupportedFeature.PROMPT_CACHING,
                APIProtocolType.ANTHROPIC,
                request.baseURL,
                request.modelID
            ),
            useNativeSearch = request.enableNativeSearch && !cache.isUnsupported(
                GatewayUnsupportedFeature.NATIVE_SEARCH,
                APIProtocolType.ANTHROPIC,
                request.baseURL,
                request.modelID
            ),
            useThinking = request.enableThinking && request.supportsReasoning && !cache.isUnsupported(
                GatewayUnsupportedFeature.THINKING_CONFIG,
                APIProtocolType.ANTHROPIC,
                request.baseURL,
                request.modelID
            ),
            clampMaxTokensTo4096 = false
        )

        return client.streamWithResilience(
            request = request,
            initialState = initial,
            buildRequest = { activeKey, state ->
                val url = EndpointResolver.chatEndpoint(request.baseURL, APIProtocolType.ANTHROPIC, request.modelID)
                val payload = buildRequestBody(
                    request = request,
                    includeCacheControl = state.useCache,
                    includeNativeSearch = state.useNativeSearch,
                    includeThinking = state.useThinking,
                    maxTokensCap = if (state.clampMaxTokensTo4096) 4096 else null
                )
                val bodyStr = compactJson.encodeToString(JsonObject.serializer(), payload)
                val builder = Request.Builder()
                    .url(url.toASCIIString())
                    .post(bodyStr.toRequestBody(jsonType))
                    .header("Content-Type", "application/json")
                    .header("Accept", "text/event-stream")
                    .header("anthropic-version", ANTHROPIC_VERSION)
                if (activeKey.isNotEmpty()) {
                    builder.header("x-api-key", activeKey)
                }
                LLMClient.applyCustomHeaders(request.customHeaders, builder)
                builder.build()
            },
            degradeOn400 = { _, detail, state, newlyDisabled ->
                val lower = detail.lowercase()
                when {
                    LLMClient.isUnrecoverable400(lower) -> false to state
                    state.useCache && lower.contains("cache_control") -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.PROMPT_CACHING)
                        true to state.copy(useCache = false)
                    }
                    state.useThinking && (lower.contains("thinking") || lower.contains("budget_tokens") || lower.contains("adaptive") || lower.contains("display")) -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.THINKING_CONFIG)
                        true to state.copy(useThinking = false)
                    }
                    state.useNativeSearch && (lower.contains("web_search") || lower.contains("tools")) -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.NATIVE_SEARCH)
                        true to state.copy(useNativeSearch = false)
                    }
                    !state.clampMaxTokensTo4096 && lower.contains("max_tokens") -> {
                        true to state.copy(clampMaxTokensTo4096 = true)
                    }
                    else -> false to state
                }
            },
            consumeStream = { _, source, onActivity, collector ->
                consumeAcceptedResponse(source, onActivity, collector)
            }
        )
    }

    private suspend fun consumeAcceptedResponse(
        source: BufferedSource,
        onActivity: () -> Unit,
        collector: FlowCollector<LLMStreamEvent>
    ) {
        var completed = false
        var inputTokens: Int? = null
        var outputTokens: Int? = null
        var cachedTokens: Int? = null
        var cacheWriteTokens: Int? = null
        val pendingToolBlocks = HashMap<Int, PendingToolBlock>()
        val pendingThinkingBlocks = HashMap<Int, PendingThinkingBlock>()

        SSEDecoder.events(source, onActivity = onActivity).collect { dataPart ->
            currentCoroutineContext().ensureActive()
            if (completed) return@collect
            if (dataPart == "[DONE]") {
                completed = true
                return@collect
            }
            if (dataPart.isEmpty()) return@collect
            val obj = SSEDecoder.jsonObject(dataPart)
            val eventType = obj.str("type") ?: throw LLMError.InterruptedStream()

            when (eventType) {
                "message_stop" -> {
                    completed = true
                }
                "message_start" -> {
                    val usage = obj.obj("message")?.obj("usage")
                    if (usage != null) {
                        val baseIn = usage.int("input_tokens")
                        val cacheRead = usage.int("cache_read_input_tokens")
                        val cacheWrite = usage.int("cache_creation_input_tokens")
                        if (baseIn != null || cacheRead != null || cacheWrite != null) {
                            inputTokens = (baseIn ?: 0) + (cacheRead ?: 0) + (cacheWrite ?: 0)
                        }
                        if (cacheRead != null && cacheRead > 0) cachedTokens = cacheRead
                        if (cacheWrite != null && cacheWrite > 0) cacheWriteTokens = cacheWrite
                    }
                }
                "content_block_start" -> {
                    val index = obj.int("index")
                    val block = obj.obj("content_block")
                    val blockType = block?.str("type")
                    if (index != null && block != null && blockType != null) {
                        when (blockType) {
                            "tool_use" -> {
                                val id = block.str("id")
                                val name = block.str("name")
                                if (id != null && name != null) {
                                    pendingToolBlocks[index] = PendingToolBlock(id, name, initialInput = block["input"])
                                }
                            }
                            "thinking" -> {
                                val initialThinking = block.str("thinking") ?: ""
                                val initialSig = block.str("signature") ?: ""
                                if (initialThinking.isNotEmpty()) {
                                    collector.emit(LLMStreamEvent.ReasoningDelta(initialThinking))
                                }
                                pendingThinkingBlocks[index] = PendingThinkingBlock(initialThinking, initialSig)
                            }
                            "redacted_thinking" -> {
                                val data = block.str("data")
                                if (!data.isNullOrEmpty()) {
                                    collector.emit(LLMStreamEvent.ThinkingBlock(LLMThinkingBlock.redacted(data)))
                                }
                            }
                            "web_search_tool_result" -> {
                                block.objList("content")?.forEach { item ->
                                    if (item.str("type") == "web_search_result") {
                                        val url = item.str("url")
                                        if (!url.isNullOrEmpty()) {
                                            collector.emit(
                                                LLMStreamEvent.GroundingSource(item.str("title") ?: url, url)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                "content_block_delta" -> {
                    val delta = obj.obj("delta")
                    val deltaType = delta?.str("type")
                    val blockIndex = obj.int("index")
                    if (delta != null && deltaType != null) {
                        when (deltaType) {
                            "thinking_delta" -> {
                                val thinking = delta.str("thinking")
                                if (!thinking.isNullOrEmpty()) {
                                    if (blockIndex != null) {
                                        val entry = pendingThinkingBlocks.getOrPut(blockIndex) { PendingThinkingBlock() }
                                        entry.thinking += thinking
                                    }
                                    collector.emit(LLMStreamEvent.ReasoningDelta(thinking))
                                }
                            }
                            "signature_delta" -> {
                                val sig = delta.str("signature")
                                if (!sig.isNullOrEmpty() && blockIndex != null) {
                                    val entry = pendingThinkingBlocks.getOrPut(blockIndex) { PendingThinkingBlock() }
                                    entry.signature += sig
                                }
                            }
                            "text_delta" -> {
                                val text = delta.str("text")
                                if (!text.isNullOrEmpty()) {
                                    collector.emit(LLMStreamEvent.ContentDelta(text))
                                }
                            }
                            "input_json_delta" -> {
                                val partial = delta.str("partial_json")
                                if (blockIndex != null && partial != null) {
                                    pendingToolBlocks[blockIndex]?.let { it.json += partial }
                                }
                            }
                        }
                    }
                }
                "content_block_stop" -> {
                    val index = obj.int("index")
                    if (index != null) {
                        pendingThinkingBlocks.remove(index)?.let { entry ->
                            collector.emit(
                                LLMStreamEvent.ThinkingBlock(
                                    LLMThinkingBlock.thinking(
                                        entry.thinking,
                                        entry.signature.ifEmpty { null }
                                    )
                                )
                            )
                        }
                        pendingToolBlocks.remove(index)?.let { emitToolCall(it, collector) }
                    }
                }
                "message_delta" -> {
                    val delta = obj.obj("delta")
                    LLMFinishReason.fromProviderValue(delta?.str("stop_reason"))?.let { reason ->
                        collector.emit(LLMStreamEvent.Finished(reason))
                    }
                    val outTok = obj.obj("usage")?.int("output_tokens")
                    if (outTok != null) {
                        outputTokens = outTok
                        collector.emit(LLMStreamEvent.Usage(inputTokens, outTok))
                    }
                }
                "error" -> {
                    val msg = obj.obj("error")?.str("message")
                    if (msg != null) throw LLMError.ApiError(msg)
                }
            }
        }

        if (!completed) throw LLMError.InterruptedStream()
        for (index in pendingThinkingBlocks.keys.sorted()) {
            pendingThinkingBlocks.remove(index)?.let { entry ->
                collector.emit(
                    LLMStreamEvent.ThinkingBlock(
                        LLMThinkingBlock.thinking(entry.thinking, entry.signature.ifEmpty { null })
                    )
                )
            }
        }
        for (index in pendingToolBlocks.keys.sorted()) {
            pendingToolBlocks.remove(index)?.let { emitToolCall(it, collector) }
        }
        if (inputTokens != null || outputTokens != null) {
            collector.emit(LLMStreamEvent.Usage(inputTokens, outputTokens))
        }
        if (cachedTokens != null || cacheWriteTokens != null) {
            collector.emit(LLMStreamEvent.CacheUsage(cachedTokens, cacheWriteTokens))
        }
    }

    private suspend fun emitToolCall(entry: PendingToolBlock, collector: FlowCollector<LLMStreamEvent>) {
        val finalJSON = when {
            entry.json.isNotEmpty() -> entry.json
            entry.initialInput != null && entry.initialInput.isNotNull() ->
                compactJson.encodeToString(JsonElement.serializer(), entry.initialInput)
            else -> "{}"
        }
        collector.emit(LLMStreamEvent.ToolCall(LLMToolCall(id = entry.id, name = entry.name, argumentsJSON = finalJSON)))
    }

    fun buildRequestBody(
        request: LLMChatRequest,
        includeCacheControl: Boolean? = null,
        includeNativeSearch: Boolean? = null,
        includeThinking: Boolean = true,
        maxTokensCap: Int? = null
    ): JsonObject {
        val useCache = includeCacheControl ?: request.enablePromptCaching
        val useNativeSearch = includeNativeSearch ?: request.enableNativeSearch
        val sanitizedMessages = LLMClient.sanitizeToolHistory(request.messages)

        val hasUnsignedAssistantToolTurn = sanitizedMessages.any { msg ->
            msg.role == MessageRole.ASSISTANT && msg.toolCalls.isNotEmpty() &&
                msg.thinkingBlocks.none { block ->
                    when (block.kind) {
                        LLMThinkingBlock.Kind.THINKING -> !block.signature.isNullOrEmpty()
                        LLMThinkingBlock.Kind.REDACTED_THINKING -> !block.redactedData.isNullOrEmpty()
                    }
                }
        }
        val shouldEnableThinking = includeThinking && request.enableThinking && request.supportsReasoning && !hasUnsignedAssistantToolTurn
        val model = request.modelID.lowercase()
        val usesAdaptiveThinking = listOf(
            "claude-sonnet-5", "claude-opus-5", "claude-haiku-5",
            "claude-fable-5", "claude-mythos-5", "claude-opus-4-7", "claude-opus-4-8"
        ).any { model.contains(it) }

        val wireMessages = mutableListOf<Pair<String, MutableList<JsonObject>>>()

        for (msg in sanitizedMessages) {
            val roleStr = if (msg.role == MessageRole.ASSISTANT) "assistant" else "user"
            val blocks = mutableListOf<JsonObject>()

            if (msg.role == MessageRole.TOOL) {
                blocks.add(buildJsonObject {
                    put("type", "tool_result")
                    put("tool_use_id", msg.toolCallID ?: "")
                    put("content", msg.content)
                })
            } else if (msg.role == MessageRole.ASSISTANT && msg.toolCalls.isNotEmpty()) {
                if (shouldEnableThinking) {
                    for (tb in msg.thinkingBlocks) {
                        when (tb.kind) {
                            LLMThinkingBlock.Kind.THINKING -> {
                                val sig = tb.signature
                                if (!sig.isNullOrEmpty()) {
                                    blocks.add(buildJsonObject {
                                        put("type", "thinking")
                                        put("thinking", tb.thinking)
                                        put("signature", sig)
                                    })
                                }
                            }
                            LLMThinkingBlock.Kind.REDACTED_THINKING -> {
                                val data = tb.redactedData
                                if (!data.isNullOrEmpty()) {
                                    blocks.add(buildJsonObject {
                                        put("type", "redacted_thinking")
                                        put("data", data)
                                    })
                                }
                            }
                        }
                    }
                }
                if (msg.content.isNotEmpty()) {
                    blocks.add(buildJsonObject {
                        put("type", "text")
                        put("text", msg.content)
                    })
                }
                for (call in msg.toolCalls) {
                    blocks.add(buildJsonObject {
                        put("type", "tool_use")
                        put("id", call.id)
                        put("name", call.name)
                        put("input", call.argumentsObject(compactJson))
                    })
                }
            } else {
                if (msg.role == MessageRole.USER) {
                    for (att in msg.attachments) {
                        val b64 = att.dataBase64 ?: continue
                        if (att.kind == com.iosbox.app.core.model.AttachmentKind.IMAGE) {
                            blocks.add(buildJsonObject {
                                put("type", "image")
                                put("source", buildJsonObject {
                                    put("type", "base64")
                                    put("media_type", att.mimeType)
                                    put("data", b64)
                                })
                            })
                        } else if (att.kind == com.iosbox.app.core.model.AttachmentKind.DOCUMENT &&
                            att.mimeType == "application/pdf"
                        ) {
                            blocks.add(buildJsonObject {
                                put("type", "document")
                                put("source", buildJsonObject {
                                    put("type", "base64")
                                    put("media_type", "application/pdf")
                                    put("data", b64)
                                })
                            })
                        }
                    }
                }

                val textPart = LLMClient.composeTextWithDocuments(
                    text = msg.content,
                    attachments = msg.attachments,
                    includePDFText = false
                )
                if (textPart.isNotEmpty()) {
                    blocks.add(buildJsonObject {
                        put("type", "text")
                        put("text", textPart)
                    })
                } else if (blocks.isEmpty()) {
                    val placeholder = if (msg.role == MessageRole.ASSISTANT && msg.attachments.isNotEmpty()) {
                        "[Generated image: ${msg.attachments.joinToString(", ") { it.fileName }}]"
                    } else {
                        "..."
                    }
                    blocks.add(buildJsonObject {
                        put("type", "text")
                        put("text", placeholder)
                    })
                }
            }

            val last = wireMessages.lastOrNull()
            if (last != null && last.first == roleStr) {
                val existingBlocks = last.second
                val incomingHasThinking = blocks.any {
                    val t = it.str("type")
                    t == "thinking" || t == "redacted_thinking"
                }
                val existingHasNonThinking = existingBlocks.any {
                    val t = it.str("type")
                    t != "thinking" && t != "redacted_thinking"
                }
                if (roleStr == "assistant" && incomingHasThinking && existingHasNonThinking) {
                    wireMessages.add(
                        "user" to mutableListOf(buildJsonObject {
                            put("type", "text")
                            put("text", L10n.text("继续", "Continue"))
                        })
                    )
                    wireMessages.add(roleStr to blocks)
                } else {
                    existingBlocks.addAll(blocks)
                }
            } else {
                wireMessages.add(roleStr to blocks)
            }
        }

        if (wireMessages.firstOrNull()?.first != "user") {
            wireMessages.add(
                0,
                "user" to mutableListOf(buildJsonObject {
                    put("type", "text")
                    put("text", L10n.text("继续", "Continue"))
                })
            )
        }

        if (useCache && wireMessages.isNotEmpty()) {
            val indicesToTag = if (wireMessages.size >= 2) {
                listOf(wireMessages.size - 2, wireMessages.size - 1)
            } else {
                listOf(wireMessages.size - 1)
            }
            for (idx in indicesToTag) {
                val blocks = wireMessages[idx].second
                if (blocks.isNotEmpty()) {
                    val lastBlock = blocks[blocks.lastIndex].toMutableMap()
                    lastBlock["cache_control"] = buildJsonObject { put("type", "ephemeral") }
                    blocks[blocks.lastIndex] = JsonObject(lastBlock)
                }
            }
        }

        val requestedMax = request.maxOutputTokens ?: 0
        var budget = maxOf(1024, request.thinkingBudgetTokens)
        val finalMaxTokens: Int
        when {
            usesAdaptiveThinking -> {
                finalMaxTokens = if (requestedMax > 0) requestedMax else defaultMaxTokens(request.modelID)
            }
            shouldEnableThinking -> {
                finalMaxTokens = if (requestedMax > budget + 1024) {
                    requestedMax
                } else {
                    minOf(budget + 8192, THINKING_OUTPUT_CAP)
                }
                budget = maxOf(1024, minOf(budget, finalMaxTokens - 4096))
            }
            requestedMax > 0 -> {
                finalMaxTokens = requestedMax
            }
            else -> {
                finalMaxTokens = defaultMaxTokens(request.modelID)
            }
        }

        val cappedMaxTokens = maxTokensCap?.let { minOf(finalMaxTokens, it) } ?: finalMaxTokens

        return buildJsonObject {
            put("model", request.modelID)
            put("max_tokens", cappedMaxTokens)
            put("messages", buildJsonArray {
                for ((role, blocks) in wireMessages) {
                    add(buildJsonObject {
                        put("role", role)
                        put("content", JsonArray(blocks))
                    })
                }
            })
            put("stream", true)

            val trimmedSystem = request.systemPrompt.trim()
            if (trimmedSystem.isNotEmpty()) {
                if (useCache) {
                    put("system", buildJsonArray {
                        add(buildJsonObject {
                            put("type", "text")
                            put("text", trimmedSystem)
                            put("cache_control", buildJsonObject { put("type", "ephemeral") })
                        })
                    })
                } else {
                    put("system", trimmedSystem)
                }
            }

            val allTools = mutableListOf<JsonObject>()
            for (tool in request.tools) {
                allTools.add(buildJsonObject {
                    put("name", tool.name)
                    put("description", tool.description)
                    put("input_schema", tool.parametersObject(compactJson))
                })
            }
            if (useNativeSearch && allTools.none { it.str("name") == "web_search" }) {
                allTools.add(buildJsonObject {
                    put("type", "web_search_20250305")
                    put("name", "web_search")
                    put("max_uses", 3)
                })
            }
            if (allTools.isNotEmpty()) {
                put("tools", JsonArray(allTools))
            }

            when {
                usesAdaptiveThinking -> {
                    if (shouldEnableThinking) {
                        put("thinking", buildJsonObject {
                            put("type", "adaptive")
                            put("display", "summarized")
                        })
                    }
                }
                shouldEnableThinking -> {
                    put("thinking", buildJsonObject {
                        put("type", "enabled")
                        put("budget_tokens", budget)
                    })
                }
                request.temperature != null -> {
                    put("temperature", request.temperature.coerceIn(0.0, 1.0))
                }
            }
        }
    }

    fun defaultMaxTokens(modelID: String): Int {
        val lower = modelID.lowercase()
        val isLegacyClaude3 = lower.contains("claude-3-") &&
            !lower.contains("claude-3-5") &&
            !lower.contains("claude-3-7")
        return if (isLegacyClaude3) 4096 else 8192
    }

    suspend fun fetchModels(
        client: LLMClient,
        baseURL: String,
        apiKey: String,
        customHeaders: List<CustomHeader>
    ): List<ModelSpec> {
        val baseEndpoint = EndpointResolver.modelsEndpoint(baseURL, APIProtocolType.ANTHROPIC).toASCIIString()
        val results = mutableListOf<ModelSpec>()
        var cursor: String? = null
        var pages = 0
        val budget = CatalogReadBudget()
        val seenCursors = HashSet<String>()

        do {
            val urlBuilder = baseEndpoint.toHttpUrl().newBuilder()
            if (!cursor.isNullOrEmpty()) {
                urlBuilder.setQueryParameter("after_id", cursor)
            }
            val builder = Request.Builder()
                .url(urlBuilder.build())
                .get()
                .header("anthropic-version", ANTHROPIC_VERSION)
            if (apiKey.isNotEmpty()) {
                builder.header("x-api-key", apiKey)
            }
            LLMClient.applyCustomHeaders(customHeaders, builder)

            val page = client.fetchJsonObject(builder.build(), budget)
            val rows = page["data"] as? JsonArray
                ?: throw IOException("Missing data array in Anthropic /models response")
            val items = budget.modelRows(rows)
            for (item in items) {
                val id = item.str("id")?.takeIf { it.isNotEmpty() } ?: throw IOException("Missing model id")
                results.add(ModelSpec.create(id = id, displayName = item.str("display_name")))
            }
            val hasMore = page.bool("has_more") == true
            cursor = if (hasMore) {
                page.str("last_id")?.takeIf { it.isNotEmpty() } ?: throw IOException("Missing last_id cursor")
            } else {
                null
            }
            val next = cursor
            if (next != null && !seenCursors.add(next)) throw IOException("Repeated model list cursor")
            pages++
        } while (cursor != null && pages < 20)
        if (cursor != null) throw IOException("Model list has too many pages")

        return results
    }
}
