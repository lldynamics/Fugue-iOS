package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ModelSpec
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSource
import java.io.IOException
import java.util.Base64
import java.util.UUID

object GeminiAdapter {
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    private val compactJson = Json { ignoreUnknownKeys = true }

    private data class WireOptions(
        val includeNativeSearch: Boolean,
        val includeThinkingConfig: Boolean
    )

    fun streamChat(client: LLMClient, request: LLMChatRequest): Flow<LLMStreamEvent> {
        val cache = client.capabilityCache
        val initial = WireOptions(
            includeNativeSearch = request.enableNativeSearch && !cache.isUnsupported(
                GatewayUnsupportedFeature.NATIVE_SEARCH,
                APIProtocolType.GEMINI,
                request.baseURL,
                request.modelID
            ),
            includeThinkingConfig = !cache.isUnsupported(
                GatewayUnsupportedFeature.THINKING_CONFIG,
                APIProtocolType.GEMINI,
                request.baseURL,
                request.modelID
            )
        )

        return client.streamWithResilience(
            request = request,
            initialState = initial,
            buildRequest = { activeKey, state ->
                val url = EndpointResolver.chatEndpoint(request.baseURL, APIProtocolType.GEMINI, request.modelID)
                val payload = buildRequestBody(
                    request = request,
                    includeNativeSearch = state.includeNativeSearch,
                    includeThinkingConfig = state.includeThinkingConfig
                )
                val bodyStr = compactJson.encodeToString(JsonObject.serializer(), payload)
                val builder = Request.Builder()
                    .url(url.toASCIIString())
                    .post(bodyStr.toRequestBody(jsonType))
                    .header("Content-Type", "application/json")
                    .header("Accept", "text/event-stream")
                if (activeKey.isNotEmpty()) {
                    builder.header("x-goog-api-key", activeKey)
                }
                LLMClient.applyCustomHeaders(request.customHeaders, builder)
                builder.build()
            },
            degradeOn400 = { _, detail, state, newlyDisabled ->
                val lower = detail.lowercase()
                when {
                    state.includeThinkingConfig && (lower.contains("thinkingconfig") || lower.contains("thinking_config") ||
                        lower.contains("thinkingbudget") || lower.contains("thinkinglevel")) -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.THINKING_CONFIG)
                        true to state.copy(includeThinkingConfig = false)
                    }
                    state.includeNativeSearch && (lower.contains("google_search") || lower.contains("tools")) -> {
                        newlyDisabled.add(GatewayUnsupportedFeature.NATIVE_SEARCH)
                        true to state.copy(includeNativeSearch = false)
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
        var reportedFinish = false
        var accumulatedThought = ""

        // Gemini inlineData image generation responses can exceed 2 MB per SSE event.
        SSEDecoder.events(source, maximumBytes = 20 * 1024 * 1024, onActivity = onActivity).collect { dataPart ->
            currentCoroutineContext().ensureActive()
            if (dataPart == "[DONE]") {
                completed = true
                return@collect
            }
            if (dataPart.isEmpty()) return@collect
            val obj = SSEDecoder.jsonObject(dataPart)

            obj.obj("error")?.str("message")?.let { throw LLMError.ApiError(it) }

            val blockReason = obj.obj("promptFeedback")?.str("blockReason")
            if (!blockReason.isNullOrEmpty()) {
                throw LLMError.ApiError(
                    L10n.text(
                        "提问内容被 Gemini 安全策略拦截（$blockReason），请调整后重试。",
                        "Prompt was blocked by Gemini safety policy ($blockReason). Adjust and retry."
                    )
                )
            }

            obj.objList("candidates")?.firstOrNull()?.let { first ->
                first.obj("content")?.objList("parts")?.forEach { part ->
                    val fnCall = part.obj("functionCall")
                    val fnName = fnCall?.str("name")
                    if (fnCall != null && !fnName.isNullOrEmpty()) {
                        val argsElem = fnCall["args"]
                        val argsJSON = if (argsElem != null && argsElem.isNotNull()) {
                            compactJson.encodeToString(kotlinx.serialization.json.JsonElement.serializer(), argsElem)
                        } else {
                            "{}"
                        }
                        collector.emit(
                            LLMStreamEvent.ToolCall(
                                LLMToolCall(
                                    id = UUID.randomUUID().toString().uppercase(),
                                    name = fnName,
                                    argumentsJSON = argsJSON,
                                    thoughtSignature = part.str("thoughtSignature")
                                )
                            )
                        )
                        return@forEach
                    }

                    val inline = part.obj("inlineData")
                    val dataB64 = inline?.str("data")
                    if (inline != null && !dataB64.isNullOrEmpty()) {
                        val mime = inline.str("mimeType") ?: "image/png"
                        if (mime.lowercase().startsWith("image/")) {
                            val ext = when {
                                mime.lowercase().contains("jpeg") || mime.lowercase().contains("jpg") -> "jpg"
                                mime.lowercase().contains("webp") -> "webp"
                                else -> "png"
                            }
                            val byteCount = runCatching { Base64.getDecoder().decode(dataB64).size }
                                .getOrElse { dataB64.toByteArray(Charsets.UTF_8).size }
                            collector.emit(
                                LLMStreamEvent.AttachmentDelta(
                                    MessageAttachment(
                                        kind = AttachmentKind.IMAGE,
                                        fileName = "generated.$ext",
                                        mimeType = mime,
                                        dataBase64 = dataB64,
                                        extractedText = null,
                                        byteSize = byteCount
                                    )
                                )
                            )
                            return@forEach
                        }
                    }

                    val text = part.str("text") ?: ""
                    val isThought = part.bool("thought") ?: false
                    val sig = part.str("thoughtSignature")

                    if (isThought) {
                        if (text.isNotEmpty()) {
                            accumulatedThought += text
                            collector.emit(LLMStreamEvent.ReasoningDelta(text))
                        }
                        if (!sig.isNullOrEmpty()) {
                            collector.emit(
                                LLMStreamEvent.ThinkingBlock(
                                    LLMThinkingBlock.thinking(accumulatedThought, sig)
                                )
                            )
                            accumulatedThought = ""
                        }
                    } else if (!sig.isNullOrEmpty() && text.isEmpty()) {
                        collector.emit(
                            LLMStreamEvent.ThinkingBlock(
                                LLMThinkingBlock.thinking(accumulatedThought, sig)
                            )
                        )
                        accumulatedThought = ""
                    } else if (text.isNotEmpty()) {
                        collector.emit(LLMStreamEvent.ContentDelta(text))
                    }
                }

                first.obj("groundingMetadata")?.objList("groundingChunks")?.forEach { chunk ->
                    chunk.obj("web")?.let { web ->
                        val uri = web.str("uri")
                        if (!uri.isNullOrEmpty()) {
                            collector.emit(LLMStreamEvent.GroundingSource(web.str("title") ?: uri, uri))
                        }
                    }
                }

                val finish = first.str("finishReason")
                if (!finish.isNullOrEmpty()) completed = true
                if (!reportedFinish) {
                    LLMFinishReason.fromProviderValue(finish)?.let { reason ->
                        reportedFinish = true
                        collector.emit(LLMStreamEvent.Finished(reason))
                    }
                }
            }

            obj.obj("usageMetadata")?.let { usage ->
                val promptTok = usage.int("promptTokenCount")
                val candTok = usage.int("candidatesTokenCount")
                val thoughtTok = usage.int("thoughtsTokenCount")
                val completionTok = if (candTok != null || thoughtTok != null) {
                    (candTok ?: 0) + (thoughtTok ?: 0)
                } else {
                    null
                }
                if (promptTok != null || completionTok != null) {
                    collector.emit(LLMStreamEvent.Usage(promptTok, completionTok))
                }
                val cachedTok = usage.int("cachedContentTokenCount")
                if (cachedTok != null && cachedTok > 0) {
                    collector.emit(LLMStreamEvent.CacheUsage(cachedTokens = cachedTok, cacheWriteTokens = null))
                }
            }
        }

        if (!completed) throw LLMError.InterruptedStream()
    }

    fun buildRequestBody(
        request: LLMChatRequest,
        includeNativeSearch: Boolean? = null,
        includeThinkingConfig: Boolean = true
    ): JsonObject {
        val useNativeSearch = includeNativeSearch ?: request.enableNativeSearch
        val sanitizedMessages = LLMClient.sanitizeToolHistory(request.messages)
        val contents = mutableListOf<Pair<String, MutableList<JsonObject>>>()

        for (msg in sanitizedMessages) {
            val roleStr = if (msg.role == MessageRole.ASSISTANT) "model" else "user"
            val parts = mutableListOf<JsonObject>()

            if (msg.role == MessageRole.TOOL) {
                parts.add(buildJsonObject {
                    putJsonObject("functionResponse") {
                        put("name", msg.toolName ?: "")
                        putJsonObject("response") { put("content", msg.content) }
                    }
                })
            } else if (msg.role == MessageRole.ASSISTANT && msg.toolCalls.isNotEmpty()) {
                for (block in msg.thinkingBlocks) {
                    if (block.kind == LLMThinkingBlock.Kind.THINKING &&
                        (block.thinking.isNotEmpty() || !block.signature.isNullOrEmpty())
                    ) {
                        parts.add(buildJsonObject {
                            put("text", block.thinking)
                            put("thought", true)
                            block.signature?.takeIf { it.isNotEmpty() }?.let { put("thoughtSignature", it) }
                        })
                    }
                }
                if (msg.content.isNotEmpty()) {
                    parts.add(buildJsonObject { put("text", msg.content) })
                }
                for (call in msg.toolCalls) {
                    parts.add(buildJsonObject {
                        putJsonObject("functionCall") {
                            put("name", call.name)
                            put("args", call.argumentsObject(compactJson))
                        }
                        call.thoughtSignature?.let { put("thoughtSignature", it) }
                    })
                }
            } else {
                for (att in msg.attachments) {
                    val b64 = att.dataBase64 ?: continue
                    if (att.kind == AttachmentKind.IMAGE) {
                        parts.add(buildJsonObject {
                            putJsonObject("inlineData") {
                                put("mimeType", att.mimeType)
                                put("data", b64)
                            }
                        })
                    } else if (msg.role == MessageRole.USER &&
                        att.kind == AttachmentKind.DOCUMENT &&
                        att.mimeType == "application/pdf"
                    ) {
                        parts.add(buildJsonObject {
                            putJsonObject("inlineData") {
                                put("mimeType", "application/pdf")
                                put("data", b64)
                            }
                        })
                    }
                }

                val textPart = LLMClient.composeTextWithDocuments(
                    text = msg.content,
                    attachments = msg.attachments,
                    includePDFText = false
                )
                if (textPart.isNotEmpty()) {
                    parts.add(buildJsonObject { put("text", textPart) })
                } else if (parts.isEmpty()) {
                    parts.add(buildJsonObject { put("text", "...") })
                }
            }

            val last = contents.lastOrNull()
            if (last != null && last.first == roleStr) {
                last.second.addAll(parts)
            } else {
                contents.add(roleStr to parts)
            }
        }

        if (contents.firstOrNull()?.first != "user") {
            contents.add(
                0,
                "user" to mutableListOf(buildJsonObject { put("text", L10n.text("继续", "Continue")) })
            )
        }

        return buildJsonObject {
            put("contents", buildJsonArray {
                for ((role, parts) in contents) {
                    add(buildJsonObject {
                        put("role", role)
                        put("parts", JsonArray(parts))
                    })
                }
            })

            val trimmedSystem = request.systemPrompt.trim()
            if (trimmedSystem.isNotEmpty()) {
                putJsonObject("systemInstruction") {
                    putJsonArray("parts") {
                        add(buildJsonObject { put("text", trimmedSystem) })
                    }
                }
            }

            putJsonObject("generationConfig") {
                put("topP", request.topP)
                request.temperature?.let { put("temperature", it) }
                request.maxOutputTokens?.takeIf { it > 0 }?.let { put("maxOutputTokens", it) }
                if (includeThinkingConfig) {
                    thinkingConfig(request)?.let { put("thinkingConfig", it) }
                }
            }

            if (request.tools.isNotEmpty()) {
                putJsonArray("tools") {
                    add(buildJsonObject {
                        putJsonArray("functionDeclarations") {
                            for (tool in request.tools) {
                                add(buildJsonObject {
                                    put("name", tool.name)
                                    put("description", tool.description)
                                    put("parameters", tool.parametersObject(compactJson))
                                })
                            }
                        }
                    })
                }
            } else if (useNativeSearch) {
                putJsonArray("tools") {
                    add(buildJsonObject {
                        putJsonObject("google_search") {}
                    })
                }
            }
        }
    }

    fun thinkingConfig(request: LLMChatRequest): JsonObject? {
        val lower = request.modelID.lowercase()
        if (lower.contains("-image") || lower.startsWith("imagen")) return null
        val usesThinkingLevel = lower.contains("gemini-3") || lower.contains("gemini-4")
        val isGemini25 = lower.contains("gemini-2.5")
        val isThinkingCapable = request.supportsReasoning || usesThinkingLevel || isGemini25 || lower.contains("thinking")
        if (!isThinkingCapable) return null

        val budget = maxOf(1024, request.thinkingBudgetTokens)
        if (usesThinkingLevel) {
            val level = if (!request.enableThinking || budget <= 4096) "low" else "high"
            return buildJsonObject {
                put("thinkingLevel", level)
                put("includeThoughts", request.enableThinking)
            }
        }

        val isFlash = lower.contains("flash")
        if (!request.enableThinking) {
            return if (isFlash) buildJsonObject { put("thinkingBudget", 0) } else null
        }
        val maxBudget = if (isFlash) 24_576 else 32_768
        return buildJsonObject {
            put("includeThoughts", true)
            put("thinkingBudget", minOf(budget, maxBudget))
        }
    }

    suspend fun fetchModels(
        client: LLMClient,
        baseURL: String,
        apiKey: String,
        customHeaders: List<CustomHeader>
    ): List<ModelSpec> {
        val baseEndpoint = EndpointResolver.modelsEndpoint(baseURL, APIProtocolType.GEMINI).toASCIIString()
        val results = mutableListOf<ModelSpec>()
        var pageToken: String? = null
        var pages = 0

        do {
            val urlBuilder = baseEndpoint.toHttpUrl().newBuilder()
            if (!pageToken.isNullOrEmpty()) {
                urlBuilder.setQueryParameter("pageToken", pageToken)
            }
            val builder = Request.Builder()
                .url(urlBuilder.build())
                .get()
            if (apiKey.isNotEmpty()) {
                builder.header("x-goog-api-key", apiKey)
            }
            LLMClient.applyCustomHeaders(customHeaders, builder)

            val page = client.fetchJsonObject(builder.build())
            val items = page.objList("models") ?: throw IOException("Missing models array in Gemini response")
            for (item in items) {
                val name = item.str("name") ?: throw IOException("Missing model name")
                val methods = item.strList("supportedGenerationMethods")
                if (methods != null && !methods.contains("generateContent")) continue
                val outputs = item.strList("supportedOutputModalities")
                if (outputs != null && outputs.none { it.equals("text", ignoreCase = true) }) continue

                val id = if (name.startsWith("models/")) name.removePrefix("models/") else name
                if (id.isEmpty()) throw IOException("Empty model id")
                results.add(ModelSpec.create(id = id, displayName = item.str("displayName")))
            }
            pageToken = page.str("nextPageToken")?.takeIf { it.isNotEmpty() }
            pages++
        } while (pageToken != null && pages < 20)

        return results
    }
}
