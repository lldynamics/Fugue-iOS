package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ModelSpec
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSource
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.util.UUID

object OpenAICompatibleAdapter {
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    private val compactJson = Json { ignoreUnknownKeys = true }

    private val nonChatModelPrefixes = listOf(
        "gpt-image", "gpt-realtime", "gpt-live", "gpt-transcribe",
        "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-4o-mini-tts",
        "gpt-4o-realtime", "text-embedding", "omni-moderation", "text-moderation",
        "whisper-", "tts-", "dall-e", "sora-"
    )

    private data class WireOptions(
        val useUsageOption: Boolean,
        val useNativeSearch: Boolean,
        val useReasoningContent: Boolean
    )

    private data class PendingToolCall(
        var id: String = "",
        var name: String = "",
        var args: String = ""
    )

    fun streamChat(client: LLMClient, request: LLMChatRequest): Flow<LLMStreamEvent> {
        val cache = client.capabilityCache
        val initial = WireOptions(
            useUsageOption = !cache.isUnsupported(
                GatewayUnsupportedFeature.STREAM_OPTIONS,
                APIProtocolType.OPEN_AI_COMPATIBLE,
                request.baseURL,
                request.modelID
            ),
            useNativeSearch = request.enableNativeSearch && !cache.isUnsupported(
                GatewayUnsupportedFeature.NATIVE_SEARCH,
                APIProtocolType.OPEN_AI_COMPATIBLE,
                request.baseURL,
                request.modelID
            ),
            useReasoningContent = !cache.isUnsupported(
                GatewayUnsupportedFeature.REASONING_CONTENT,
                APIProtocolType.OPEN_AI_COMPATIBLE,
                request.baseURL,
                request.modelID
            )
        )

        return client.streamWithResilience(
            request = request,
            initialState = initial,
            buildRequest = { activeKey, state ->
                val url = EndpointResolver.chatEndpoint(request.baseURL, APIProtocolType.OPEN_AI_COMPATIBLE, request.modelID)
                val payload = buildRequestBody(
                    request = request,
                    includeUsageOption = state.useUsageOption,
                    includeNativeSearch = state.useNativeSearch,
                    includeReasoningContent = state.useReasoningContent
                )
                val bodyStr = compactJson.encodeToString(JsonObject.serializer(), payload)
                val builder = Request.Builder()
                    .url(url.toASCIIString())
                    .post(bodyStr.toRequestBody(jsonType))
                    .header("Content-Type", "application/json")
                    .header("Accept", "text/event-stream")
                if (activeKey.isNotEmpty()) {
                    builder.header("Authorization", "Bearer $activeKey")
                }
                LLMClient.applyCustomHeaders(request.customHeaders, builder)
                builder.build()
            },
            degradeOn400 = { _, detail, state, newlyDisabled ->
                val lower = detail.lowercase()
                when {
                    state.useUsageOption && lower.contains("stream_options") -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.STREAM_OPTIONS)
                        true to state.copy(useUsageOption = false)
                    }
                    state.useReasoningContent && lower.contains("reasoning_content") -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.REASONING_CONTENT)
                        true to state.copy(useReasoningContent = false)
                    }
                    state.useNativeSearch && (lower.contains("web_search") || lower.contains("plugins") ||
                        lower.contains("unknown") || lower.contains("unrecognized")) -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.NATIVE_SEARCH)
                        true to state.copy(useNativeSearch = false)
                    }
                    else -> false to state
                }
            },
            consumeStream = { response, source, onActivity, collector ->
                consumeAcceptedResponse(response, source, onActivity, collector)
            }
        )
    }

    private suspend fun consumeAcceptedResponse(
        response: Response,
        source: BufferedSource,
        onActivity: () -> Unit,
        collector: FlowCollector<LLMStreamEvent>
    ) {
        val contentType = response.header("Content-Type")?.lowercase() ?: ""
        if (contentType.contains("application/json") && !contentType.contains("event-stream")) {
            collector.emit(LLMStreamEvent.NonStreamingResponse)
            val maxJsonBytes = 16 * 1024 * 1024
            val out = ByteArrayOutputStream()
            val buf = ByteArray(4096)
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = source.read(buf)
                if (read < 0) break
                if (out.size() + read > maxJsonBytes) throw LLMError.InterruptedStream()
                out.write(buf, 0, read)
                onActivity()
            }
            emitNonStreamingJSON(out.toByteArray(), collector)
            return
        }

        val thinkParser = ThinkTagStreamParser()
        var receivedNativeReasoning = false
        var completed = false
        var reportedFinish = false
        val pendingToolCalls = HashMap<Int, PendingToolCall>()

        SSEDecoder.events(source, onActivity = onActivity).collect { dataPart ->
            currentCoroutineContext().ensureActive()
            if (dataPart == "[DONE]") {
                completed = true
                return@collect
            }
            if (dataPart.isEmpty()) return@collect
            val obj = SSEDecoder.jsonObject(dataPart)

            obj.obj("error")?.str("message")?.let { throw LLMError.ApiError(it) }

            obj.obj("usage")?.let { usage ->
                val prompt = usage.int("prompt_tokens")
                val completion = usage.int("completion_tokens")
                if (prompt != null || completion != null) {
                    collector.emit(LLMStreamEvent.Usage(prompt, completion))
                }
                val cached = usage.obj("prompt_tokens_details")?.int("cached_tokens")
                    ?: usage.int("prompt_cache_hit_tokens")
                if (cached != null && cached > 0) {
                    collector.emit(LLMStreamEvent.CacheUsage(cachedTokens = cached, cacheWriteTokens = null))
                }
            }

            val choices = obj.objList("choices") ?: return@collect
            val first = choices.firstOrNull() ?: return@collect
            val finishReason = first.str("finish_reason")
            if (!finishReason.isNullOrEmpty()) completed = true

            val delta = first.obj("delta") ?: first.obj("message") ?: JsonObject(emptyMap())

            val reasoning = delta.str("reasoning_content") ?: delta.str("reasoning")
            if (!reasoning.isNullOrEmpty()) {
                receivedNativeReasoning = true
                collector.emit(LLMStreamEvent.ReasoningDelta(reasoning))
            }

            val content = delta.str("content")
            if (!content.isNullOrEmpty()) {
                if (receivedNativeReasoning) {
                    collector.emit(LLMStreamEvent.ContentDelta(content))
                } else {
                    emitSegments(thinkParser.feed(content), collector)
                }
            }

            delta.objList("annotations")?.forEach { ann ->
                if (ann.str("type") == "url_citation") {
                    ann.obj("url_citation")?.let { cite ->
                        val url = cite.str("url")
                        if (!url.isNullOrEmpty()) {
                            collector.emit(LLMStreamEvent.GroundingSource(cite.str("title") ?: url, url))
                        }
                    }
                }
            }

            delta.objList("tool_calls")?.forEachIndexed { offset, tc ->
                val tcID = tc.str("id")?.takeIf { it.isNotEmpty() }
                val index = tc.int("index")
                    ?: tcID?.let { id -> pendingToolCalls.entries.firstOrNull { it.value.id == id }?.key }
                    ?: if (delta.objList("tool_calls")!!.size > 1) offset
                    else if (tcID != null && pendingToolCalls.keys.maxOrNull()?.let { pendingToolCalls[it]?.id?.isNotEmpty() == true } == true) {
                        (pendingToolCalls.keys.maxOrNull() ?: 0) + 1
                    } else {
                        pendingToolCalls.keys.maxOrNull() ?: 0
                    }

                val entry = pendingToolCalls.getOrPut(index) { PendingToolCall() }
                if (tcID != null) entry.id = tcID
                tc.obj("function")?.let { fn ->
                    fn.str("name")?.let { entry.name += it }
                    fn.str("arguments")?.let { entry.args += it }
                }
            }

            if (!reportedFinish) {
                LLMFinishReason.fromProviderValue(finishReason)?.let { reason ->
                    reportedFinish = true
                    collector.emit(LLMStreamEvent.Finished(reason))
                }
            }
        }

        if (!completed) throw LLMError.InterruptedStream()
        if (!receivedNativeReasoning) {
            emitSegments(thinkParser.finish(), collector)
        }
        for (index in pendingToolCalls.keys.sorted()) {
            val entry = pendingToolCalls[index] ?: continue
            if (entry.name.isNotEmpty()) {
                collector.emit(
                    LLMStreamEvent.ToolCall(
                        LLMToolCall(
                            id = entry.id.ifEmpty { UUID.randomUUID().toString().uppercase() },
                            name = entry.name,
                            argumentsJSON = entry.args.ifEmpty { "{}" }
                        )
                    )
                )
            }
        }
    }

    private suspend fun emitSegments(
        segments: List<ThinkTagStreamParser.Segment>,
        collector: FlowCollector<LLMStreamEvent>
    ) {
        for (seg in segments) {
            when (seg) {
                is ThinkTagStreamParser.Segment.Reasoning -> collector.emit(LLMStreamEvent.ReasoningDelta(seg.text))
                is ThinkTagStreamParser.Segment.Content -> collector.emit(LLMStreamEvent.ContentDelta(seg.text))
            }
        }
    }

    private suspend fun emitNonStreamingJSON(
        data: ByteArray,
        collector: FlowCollector<LLMStreamEvent>
    ) {
        val text = data.toString(Charsets.UTF_8)
        val obj = runCatching { compactJson.parseToJsonElement(text) as? JsonObject }.getOrNull()
        val first = obj?.objList("choices")?.firstOrNull()
        val message = first?.obj("message")
        if (obj == null || first == null || message == null) {
            throw LLMError.ApiError(LLMClient.extractReadableErrorMessage(data))
        }

        val reasoning = message.str("reasoning_content") ?: message.str("reasoning")
        if (!reasoning.isNullOrEmpty()) {
            collector.emit(LLMStreamEvent.ReasoningDelta(reasoning))
        }

        val content = message.str("content")
        if (!content.isNullOrEmpty()) {
            val parser = ThinkTagStreamParser()
            emitSegments(parser.feed(content) + parser.finish(), collector)
        }

        message.objList("annotations")?.forEach { ann ->
            if (ann.str("type") == "url_citation") {
                ann.obj("url_citation")?.let { cite ->
                    val url = cite.str("url")
                    if (!url.isNullOrEmpty()) {
                        collector.emit(LLMStreamEvent.GroundingSource(cite.str("title") ?: url, url))
                    }
                }
            }
        }

        message.objList("tool_calls")?.forEach { tc ->
            val tcID = tc.str("id") ?: UUID.randomUUID().toString().uppercase()
            val fn = tc.obj("function")
            val name = fn?.str("name")
            if (!name.isNullOrEmpty()) {
                val args = fn.str("arguments") ?: "{}"
                collector.emit(LLMStreamEvent.ToolCall(LLMToolCall(id = tcID, name = name, argumentsJSON = args)))
            }
        }

        obj.obj("usage")?.let { usage ->
            collector.emit(LLMStreamEvent.Usage(usage.int("prompt_tokens"), usage.int("completion_tokens")))
            val cached = usage.obj("prompt_tokens_details")?.int("cached_tokens")
                ?: usage.int("prompt_cache_hit_tokens")
            if (cached != null && cached > 0) {
                collector.emit(LLMStreamEvent.CacheUsage(cachedTokens = cached, cacheWriteTokens = null))
            }
        }

        LLMFinishReason.fromProviderValue(first.str("finish_reason"))?.let {
            collector.emit(LLMStreamEvent.Finished(it))
        }
    }

    fun buildRequestBody(
        request: LLMChatRequest,
        includeUsageOption: Boolean = true,
        includeNativeSearch: Boolean? = null,
        includeReasoningContent: Boolean = true
    ): JsonObject {
        val useNativeSearch = includeNativeSearch ?: request.enableNativeSearch
        val sanitizedMessages = LLMClient.sanitizeToolHistory(request.messages)
        val wireMessages = mutableListOf<MutableMap<String, JsonElement>>()
        val baseModel = baseModelName(request.modelID)
        val viaOpenRouter = isOpenRouter(request.baseURL)
        val isOpenAIReasoning = isOpenAIReasoningModel(baseModel)
        val directOpenAIHost = isDirectOpenAIHost(request.baseURL)

        val trimmedSystem = request.systemPrompt.trim()
        if (trimmedSystem.isNotEmpty()) {
            wireMessages.add(
                mutableMapOf(
                    "role" to JsonPrimitive("system"),
                    "content" to JsonPrimitive(trimmedSystem)
                )
            )
        }

        for (msg in sanitizedMessages) {
            if (msg.role == MessageRole.TOOL) {
                wireMessages.add(
                    mutableMapOf(
                        "role" to JsonPrimitive("tool"),
                        "tool_call_id" to JsonPrimitive(msg.toolCallID ?: ""),
                        "content" to JsonPrimitive(msg.content)
                    )
                )
                continue
            }

            if (msg.role == MessageRole.ASSISTANT && msg.toolCalls.isNotEmpty()) {
                val assistantMap = mutableMapOf<String, JsonElement>(
                    "role" to JsonPrimitive("assistant"),
                    "tool_calls" to buildJsonArray {
                        for (call in msg.toolCalls) {
                            add(
                                buildJsonObject {
                                    put("id", call.id)
                                    put("type", "function")
                                    putJsonObject("function") {
                                        put("name", call.name)
                                        put("arguments", call.argumentsJSON)
                                    }
                                }
                            )
                        }
                    },
                    "content" to if (msg.content.isEmpty()) JsonNull else JsonPrimitive(msg.content)
                )
                if (includeReasoningContent && msg.reasoningContent.isNotEmpty() &&
                    !directOpenAIHost && (!isOpenAIReasoning || viaOpenRouter)
                ) {
                    assistantMap["reasoning_content"] = JsonPrimitive(msg.reasoningContent)
                }
                wireMessages.add(assistantMap)
                continue
            }

            val roleStr = if (msg.role == MessageRole.ASSISTANT) "assistant" else "user"
            val combinedText = LLMClient.composeTextWithDocuments(
                text = msg.content,
                attachments = msg.attachments,
                includePDFText = true
            )
            val imageAttachments = msg.attachments.filter { it.kind == AttachmentKind.IMAGE && it.dataBase64 != null }

            val newContent: JsonElement = if (imageAttachments.isEmpty() || msg.role == MessageRole.ASSISTANT) {
                if (combinedText.isEmpty() && msg.role == MessageRole.ASSISTANT && msg.attachments.isNotEmpty()) {
                    JsonPrimitive("[Generated image: ${msg.attachments.joinToString(", ") { it.fileName }}]")
                } else {
                    JsonPrimitive(combinedText.ifEmpty { "..." })
                }
            } else {
                buildJsonArray {
                    if (combinedText.isNotEmpty()) {
                        add(buildJsonObject {
                            put("type", "text")
                            put("text", combinedText)
                        })
                    }
                    for (img in imageAttachments) {
                        val b64 = img.dataBase64 ?: continue
                        add(buildJsonObject {
                            put("type", "image_url")
                            putJsonObject("image_url") {
                                put("url", "data:${img.mimeType};base64,$b64")
                            }
                        })
                    }
                    if (combinedText.isEmpty() && imageAttachments.isEmpty()) {
                        add(buildJsonObject {
                            put("type", "text")
                            put("text", "...")
                        })
                    }
                }
            }

            val last = wireMessages.lastOrNull()
            if (last != null && last["role"]?.asStringOrNull() == roleStr && !last.containsKey("tool_calls")) {
                val prevContent = last["content"]
                val mergedContent: JsonElement = if (prevContent is JsonPrimitive && prevContent.isString &&
                    newContent is JsonPrimitive && newContent.isString
                ) {
                    val prevStr = prevContent.content
                    val newStr = newContent.content
                    val merged = when {
                        prevStr.isEmpty() -> newStr
                        newStr.isEmpty() -> prevStr
                        else -> "$prevStr\n\n$newStr"
                    }
                    JsonPrimitive(merged)
                } else {
                    JsonArray(asContentParts(prevContent) + asContentParts(newContent))
                }
                last["content"] = mergedContent
            } else {
                wireMessages.add(
                    mutableMapOf(
                        "role" to JsonPrimitive(roleStr),
                        "content" to newContent
                    )
                )
            }
        }

        val firstNonSystem = wireMessages.indexOfFirst { it["role"]?.asStringOrNull() != "system" }
        if (firstNonSystem >= 0 && wireMessages[firstNonSystem]["role"]?.asStringOrNull() == "assistant") {
            wireMessages.add(
                firstNonSystem,
                mutableMapOf(
                    "role" to JsonPrimitive("user"),
                    "content" to JsonPrimitive(L10n.text("继续", "Continue"))
                )
            )
        }

        return buildJsonObject {
            put("model", request.modelID)
            put("messages", JsonArray(wireMessages.map { JsonObject(it) }))
            put("stream", true)

            val omitSampling = isOpenAIReasoning || baseModel.contains("reasoner")
            if (!omitSampling) {
                request.temperature?.let { put("temperature", it) }
                if (request.topP < 0.999) {
                    put("top_p", request.topP)
                }
            }
            request.maxOutputTokens?.takeIf { it > 0 }?.let { maxTokens ->
                val key = if (isOpenAIReasoning && !viaOpenRouter) "max_completion_tokens" else "max_tokens"
                put(key, maxTokens)
            }
            if (includeUsageOption) {
                putJsonObject("stream_options") { put("include_usage", true) }
            }
            if (request.tools.isNotEmpty()) {
                putJsonArray("tools") {
                    for (tool in request.tools) {
                        add(buildJsonObject {
                            put("type", "function")
                            putJsonObject("function") {
                                put("name", tool.name)
                                put("description", tool.description)
                                put("parameters", tool.parametersObject(compactJson))
                            }
                        })
                    }
                }
            }
            if (useNativeSearch) {
                if (viaOpenRouter) {
                    putJsonArray("plugins") {
                        add(buildJsonObject { put("id", "web") })
                    }
                } else {
                    putJsonObject("web_search_options") {
                        put("search_context_size", "medium")
                    }
                }
            }
            for ((k, v) in reasoningParameters(request)) {
                put(k, v)
            }
        }
    }

    fun reasoningParameters(request: LLMChatRequest): Map<String, JsonElement> {
        if (!request.supportsReasoning) return emptyMap()
        val baseModel = baseModelName(request.modelID)
        val budget = maxOf(1024, request.thinkingBudgetTokens)

        if (isOpenRouter(request.baseURL)) {
            return if (request.enableThinking) {
                mapOf("reasoning" to buildJsonObject { put("max_tokens", budget) })
            } else {
                emptyMap()
            }
        }

        if (isOpenAIReasoningModel(baseModel)) {
            if (baseModel.startsWith("o1-mini") || baseModel.startsWith("o1-preview")) {
                return emptyMap()
            }
            val effort = when {
                !request.enableThinking || budget <= 2048 -> "low"
                budget <= 8192 -> "medium"
                else -> "high"
            }
            return mapOf("reasoning_effort" to JsonPrimitive(effort))
        }

        val host = runCatching { URI(request.baseURL.trim().trimEnd('#')).host?.lowercase() }.getOrNull()
        if (host == "api.deepseek.com" && (baseModel == "deepseek-flash" || baseModel.startsWith("deepseek-v4"))) {
            return mapOf(
                "thinking" to buildJsonObject {
                    put("type", if (request.enableThinking) "enabled" else "disabled")
                }
            )
        }

        if (baseModel.contains("qwen3") && !baseModel.contains("instruct") && !baseModel.contains("thinking")) {
            val map = mutableMapOf<String, JsonElement>(
                "enable_thinking" to JsonPrimitive(request.enableThinking)
            )
            if (request.enableThinking) {
                map["thinking_budget"] = JsonPrimitive(budget)
            }
            return map
        }

        return emptyMap()
    }

    private fun asContentParts(content: JsonElement?): List<JsonObject> {
        if (content is JsonArray) return content.mapNotNull { it as? JsonObject }
        val text = content.asStringOrNull()
        if (!text.isNullOrEmpty()) {
            return listOf(buildJsonObject {
                put("type", "text")
                put("text", text)
            })
        }
        return emptyList()
    }

    fun baseModelName(modelID: String): String {
        val lower = modelID.lowercase()
        return lower.substringAfterLast('/', lower)
    }

    fun isOpenAIReasoningModel(baseModel: String): Boolean {
        if (baseModel.contains("-chat")) return false
        return listOf("o1", "o3", "o4", "gpt-5", "gpt-6").any { baseModel.startsWith(it) }
    }

    fun isOpenRouter(baseURL: String): Boolean {
        val host = runCatching { URI(baseURL.trim().trimEnd('#')).host?.lowercase() }.getOrNull() ?: ""
        return host == "openrouter.ai" || host.endsWith(".openrouter.ai")
    }

    private fun isDirectOpenAIHost(baseURL: String): Boolean {
        val host = runCatching { URI(baseURL.trim().trimEnd('#')).host?.lowercase() }.getOrNull() ?: ""
        return host == "api.openai.com" || host.endsWith(".openai.com")
    }

    suspend fun fetchModels(
        client: LLMClient,
        baseURL: String,
        apiKey: String,
        customHeaders: List<CustomHeader>
    ): List<ModelSpec> {
        val endpoint = EndpointResolver.modelsEndpoint(baseURL, APIProtocolType.OPEN_AI_COMPATIBLE)
        val builder = Request.Builder()
            .url(endpoint.toASCIIString())
            .get()
        if (apiKey.isNotEmpty()) {
            builder.header("Authorization", "Bearer $apiKey")
        }
        LLMClient.applyCustomHeaders(customHeaders, builder)

        val root = client.fetchJsonElement(builder.build())
        val rows = when (root) {
            is JsonObject -> (root["data"] as? JsonArray)
                ?: (root["models"] as? JsonArray)
                ?: throw IOException("Unexpected model list payload")
            is JsonArray -> root
            else -> throw IOException("Unexpected model list payload")
        }
        val items = CatalogReadBudget().modelRows(rows)

        data class RankedModel(val model: ModelSpec, val created: Double, val position: Int)

        val ranked = mutableListOf<RankedModel>()
        val seen = HashSet<String>()

        items.forEachIndexed { position, item ->
            val rawID = item.str("id") ?: item.str("name") ?: throw IOException("Missing model id")
            val id = rawID.trim()
            if (id.isEmpty()) throw IOException("Empty model id")
            if (!seen.add(id)) return@forEachIndexed

            val architecture = item.obj("architecture")
            val outputs = item.strList("output_modalities") ?: architecture?.strList("output_modalities")
            if (outputs != null && !outputs.contains("text")) return@forEachIndexed
            if (endpoint.host.equals("api.openai.com", ignoreCase = true) &&
                nonChatModelPrefixes.any { id.startsWith(it) }
            ) {
                return@forEachIndexed
            }

            val displayName = item.str("name") ?: id
            val inputs = item.strList("input_modalities") ?: architecture?.strList("input_modalities")
            val efforts = item.obj("effort")?.strList("supported_levels")
                ?: item.strList("supported_reasoning_efforts")

            val spec = ModelSpec.create(
                id = id,
                displayName = displayName,
                supportsVision = inputs?.contains("image"),
                supportsReasoning = efforts?.isNotEmpty()
            )
            ranked.add(RankedModel(spec, item.doubleVal("created") ?: 0.0, position))
        }

        return ranked.sortedWith(
            compareByDescending<RankedModel> { it.created }.thenBy { it.position }
        ).map { it.model }
    }
}
