package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ModelSpec
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.BufferedSource
import java.io.IOException
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import kotlin.math.roundToLong

class LLMHttpStatusException(
    val statusCode: Int,
    override val message: String,
    val retryAfterSeconds: Double?
) : Exception(message)

class LLMClient(
    val capabilityCache: GatewayCapabilityCache = GatewayCapabilityCache(),
    val keyRouter: APIKeyPoolRouter = APIKeyPoolRouter(),
    private val isConsentAccepted: () -> Boolean = { true },
    baseHttpClient: OkHttpClient? = null
) {
    val httpClient: OkHttpClient = (baseHttpClient?.newBuilder() ?: OkHttpClient.Builder())
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .callTimeout(0, TimeUnit.SECONDS)
        .addInterceptor(PrivateCleartextOnlyInterceptor())
        .build()

    internal val json = Json { ignoreUnknownKeys = true }

    fun streamChat(request: LLMChatRequest): Flow<LLMStreamEvent> = flow {
        if (!isConsentAccepted()) {
            throw LLMError.ConsentRequired()
        }
        startStream(request).collect { emit(it) }
    }

    internal fun startStream(request: LLMChatRequest): Flow<LLMStreamEvent> = when (request.protocolType) {
        APIProtocolType.OPEN_AI_COMPATIBLE -> OpenAICompatibleAdapter.streamChat(this, request)
        APIProtocolType.ANTHROPIC -> AnthropicAdapter.streamChat(this, request)
        APIProtocolType.GEMINI -> GeminiAdapter.streamChat(this, request)
    }

    suspend fun pingModel(
        providerName: String,
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        apiKeys: List<String> = emptyList(),
        customHeaders: List<CustomHeader> = emptyList(),
        modelID: String,
        supportsReasoning: Boolean = false,
        idleTimeoutSeconds: Double? = null
    ): LLMPingResult {
        val req = buildPingRequest(
            providerName = providerName,
            protocolType = protocolType,
            baseURL = baseURL,
            apiKey = apiKey,
            apiKeys = apiKeys,
            customHeaders = customHeaders,
            modelID = modelID,
            supportsReasoning = supportsReasoning,
            idleTimeoutSeconds = idleTimeoutSeconds
        )
        val startNanos = System.nanoTime()
        var firstMs: Int? = null
        var sawOutput = false
        var visibleChars = 0

        try {
            startStream(req).collect { event ->
                when (event) {
                    is LLMStreamEvent.ReasoningDelta -> if (event.text.isNotEmpty()) {
                        if (firstMs == null) firstMs = elapsedMsSince(startNanos)
                        sawOutput = true
                    }
                    is LLMStreamEvent.ThinkingBlock -> {
                        if (firstMs == null) firstMs = elapsedMsSince(startNanos)
                        sawOutput = true
                    }
                    is LLMStreamEvent.ContentDelta -> if (event.text.isNotEmpty()) {
                        if (firstMs == null) firstMs = elapsedMsSince(startNanos)
                        sawOutput = true
                        visibleChars += event.text.length
                        if (visibleChars >= 32) throw PingEarlyStopSignal
                    }
                    else -> Unit
                }
            }
        } catch (_: PingEarlyStopSignal) {
            // Early stop once sufficient visible output confirms model streaming works.
        }

        val total = elapsedMsSince(startNanos)
        if (!sawOutput) throw LLMError.EmptyResponse()
        return LLMPingResult(modelID = modelID, ttftMs = firstMs ?: total, totalMs = total)
    }

    private object PingEarlyStopSignal : CancellationException("Ping completed")

    suspend fun fetchModels(
        providerName: String = "",
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        apiKeys: List<String> = emptyList(),
        customHeaders: List<CustomHeader> = emptyList()
    ): List<ModelSpec> {
        val endpoint = EndpointResolver.modelsEndpoint(baseURL, protocolType)
        val scheme = endpoint.scheme?.lowercase() ?: ""
        if ((scheme != "http" && scheme != "https") || NetworkLocation.isPlainHTTPToPublicHost(baseURL)) {
            throw LLMError.InsecurePublicHttp(baseURL)
        }
        val orderedKeys = keyRouter.orderedKeys(
            rawKeys = listOf(apiKey) + apiKeys,
            protocolType = protocolType,
            baseURL = baseURL
        )
        var lastError: Throwable? = null
        val limit = minOf(orderedKeys.size, 4)

        for (index in 0 until limit) {
            val candidateKey = orderedKeys[index]
            try {
                val specs = when (protocolType) {
                    APIProtocolType.OPEN_AI_COMPATIBLE -> OpenAICompatibleAdapter.fetchModels(this, baseURL, candidateKey, customHeaders)
                    APIProtocolType.ANTHROPIC -> AnthropicAdapter.fetchModels(this, baseURL, candidateKey, customHeaders)
                    APIProtocolType.GEMINI -> GeminiAdapter.fetchModels(this, baseURL, candidateKey, customHeaders)
                }
                keyRouter.markHealthy(candidateKey, protocolType, baseURL)
                return specs
            } catch (err: LLMError.HttpError) {
                if (err.statusCode in setOf(401, 402, 403, 429) && index + 1 < limit) {
                    keyRouter.markUnhealthy(candidateKey, protocolType, baseURL, err.statusCode)
                    lastError = err
                    continue
                }
                throw err
            }
        }
        throw lastError ?: LLMError.EmptyResponse()
    }

    internal fun <State> streamWithResilience(
        request: LLMChatRequest,
        initialState: State,
        buildRequest: (activeKey: String, state: State) -> Request,
        degradeOn400: (statusCode: Int, detail: String, state: State, newlyDisabled: MutableSet<GatewayUnsupportedFeature>) -> Pair<Boolean, State>,
        consumeStream: suspend (
            response: Response,
            source: BufferedSource,
            onActivity: () -> Unit,
            collector: FlowCollector<LLMStreamEvent>
        ) -> Unit
    ): Flow<LLMStreamEvent> = flow {
        if (NetworkLocation.isPlainHTTPToPublicHost(request.baseURL)) {
            throw LLMError.InsecurePublicHttp(request.baseURL)
        }

        var state = initialState
        val newlyDisabled = linkedSetOf<GatewayUnsupportedFeature>()
        val orderedKeys = keyRouter.orderedKeys(
            rawKeys = request.effectiveAPIKeys,
            protocolType = request.protocolType,
            baseURL = request.baseURL
        )
        var keyIndex = 0
        var keyRotationsUsed = 0
        var transientRetriesUsed = 0
        val idleTimeoutSec = resolvedIdleTimeoutSeconds(request)
        val idleTimeoutMs = (idleTimeoutSec * 1000.0).roundToLong().coerceIn(50L, 3_600_000L)
        val attemptClient = httpClient.newBuilder()
            .readTimeout(idleTimeoutMs, TimeUnit.MILLISECONDS)
            .connectTimeout(minOf(30_000L, idleTimeoutMs), TimeUnit.MILLISECONDS)
            .build()

        while (true) {
            val activeKey = orderedKeys[keyIndex]
            val okHttpRequest = buildRequest(activeKey, state)
            request.validateBeforeSending?.invoke()

            var accepted = false
            try {
                executeCallCancellably(attemptClient.newCall(okHttpRequest)) { response ->
                    validateHttpResponse(response)
                    accepted = true
                    val body = response.body ?: throw LLMError.InterruptedStream()
                    consumeStream(response, body.source(), {}, this)
                }

                keyRouter.markHealthy(activeKey, request.protocolType, request.baseURL)
                if (newlyDisabled.isNotEmpty()) {
                    capabilityCache.markUnsupported(
                        newlyDisabled,
                        request.protocolType,
                        request.baseURL,
                        request.modelID
                    )
                }
                break
            } catch (statusErr: LLMHttpStatusException) {
                if (accepted) {
                    throw LLMError.HttpError(statusErr.statusCode, statusErr.message)
                }
                val code = statusErr.statusCode
                if (code in 400..422) {
                    val (degraded, nextState) = degradeOn400(code, statusErr.message, state, newlyDisabled)
                    if (degraded) {
                        state = nextState
                        emit(LLMStreamEvent.Retrying(code))
                        continue
                    }
                }
                if (code in setOf(401, 402, 403, 429) &&
                    keyIndex + 1 < orderedKeys.size &&
                    keyRotationsUsed < 3
                ) {
                    keyRouter.markUnhealthy(
                        activeKey,
                        request.protocolType,
                        request.baseURL,
                        code,
                        statusErr.retryAfterSeconds
                    )
                    keyIndex++
                    keyRotationsUsed++
                    emit(LLMStreamEvent.Retrying(code))
                    continue
                }
                if (code in setOf(429, 502, 503, 504, 529) && transientRetriesUsed == 0) {
                    val waitSec = transientRetryDelay(code, statusErr.retryAfterSeconds, statusErr.message)
                    if (waitSec != null) {
                        if (code == 429) {
                            keyRouter.markUnhealthy(
                                activeKey,
                                request.protocolType,
                                request.baseURL,
                                code,
                                statusErr.retryAfterSeconds
                            )
                        }
                        transientRetriesUsed++
                        emit(LLMStreamEvent.Retrying(code))
                        delay((waitSec * 1000.0).roundToLong().coerceAtLeast(1L))
                        continue
                    }
                }
                throw LLMError.HttpError(code, statusErr.message)
            } catch (blocked: BlockedTransportException) {
                throw blocked.llmError
            } catch (io: IOException) {
                if (!accepted && transientRetriesUsed == 0 && isTransientConnectionDrop(io)) {
                    transientRetriesUsed++
                    delay(200L)
                    continue
                }
                throw io
            }
        }

        emit(LLMStreamEvent.Done)
    }.flowOn(Dispatchers.IO)

    internal suspend fun fetchJsonObject(request: Request): JsonObject {
        val fresh = request.newBuilder()
            .header("Cache-Control", "no-cache")
            .build()
        val client = httpClient.newBuilder()
            .readTimeout(30, TimeUnit.SECONDS)
            .connectTimeout(30, TimeUnit.SECONDS)
            .build()
        return withContext(Dispatchers.IO) {
            try {
                executeCallCancellably(client.newCall(fresh)) { response ->
                    val data = response.body?.bytes() ?: ByteArray(0)
                    validateDataResponse(response, data)
                    val text = data.toString(Charsets.UTF_8)
                    val elem = runCatching { json.parseToJsonElement(text) }.getOrNull()
                    (elem as? JsonObject) ?: throw IOException("Unexpected non-object JSON response")
                }
            } catch (blocked: BlockedTransportException) {
                throw blocked.llmError
            }
        }
    }

    internal suspend fun fetchJsonElement(request: Request): kotlinx.serialization.json.JsonElement {
        val fresh = request.newBuilder()
            .header("Cache-Control", "no-cache")
            .build()
        val client = httpClient.newBuilder()
            .readTimeout(30, TimeUnit.SECONDS)
            .connectTimeout(30, TimeUnit.SECONDS)
            .build()
        return withContext(Dispatchers.IO) {
            try {
                executeCallCancellably(client.newCall(fresh)) { response ->
                    val data = response.body?.bytes() ?: ByteArray(0)
                    validateDataResponse(response, data)
                    val text = data.toString(Charsets.UTF_8)
                    runCatching { json.parseToJsonElement(text) }
                        .getOrElse { throw IOException("Cannot parse JSON response", it) }
                }
            } catch (blocked: BlockedTransportException) {
                throw blocked.llmError
            }
        }
    }

    private suspend inline fun <T> executeCallCancellably(
        call: Call,
        crossinline block: suspend (Response) -> T
    ): T {
        return kotlinx.coroutines.coroutineScope {
            val job = kotlin.coroutines.coroutineContext[kotlinx.coroutines.Job]
            val handle = job?.invokeOnCompletion { cause ->
                if (cause != null) call.cancel()
            }
            try {
                call.execute().use { response ->
                    block(response)
                }
            } finally {
                handle?.dispose()
            }
        }
    }

    companion object {
        const val STANDARD_IDLE_TIMEOUT_SECONDS = 45.0
        const val EXTENDED_IDLE_TIMEOUT_SECONDS = 120.0
        const val MAX_RETRY_AFTER_WAIT_SECONDS = 5.0

        fun resolvedIdleTimeoutSeconds(request: LLMChatRequest): Double {
            request.idleTimeoutSeconds?.takeIf { it > 0.0 }?.let { custom ->
                return custom.coerceIn(0.05, 3600.0)
            }
            val needsExtended = request.supportsReasoning ||
                ModelSpec.inferReasoningSupport(request.modelID) ||
                NetworkLocation.isLocalOrPrivate(request.baseURL)
            return if (needsExtended) EXTENDED_IDLE_TIMEOUT_SECONDS else STANDARD_IDLE_TIMEOUT_SECONDS
        }

        fun buildPingRequest(
            providerName: String,
            protocolType: APIProtocolType,
            baseURL: String,
            apiKey: String,
            apiKeys: List<String> = emptyList(),
            customHeaders: List<CustomHeader> = emptyList(),
            modelID: String,
            supportsReasoning: Boolean = false,
            idleTimeoutSeconds: Double? = null
        ): LLMChatRequest {
            val effectiveReasoning = supportsReasoning || ModelSpec.inferReasoningSupport(modelID)
            return LLMChatRequest(
                providerName = providerName,
                protocolType = protocolType,
                baseURL = baseURL,
                apiKey = apiKey,
                apiKeys = apiKeys,
                customHeaders = customHeaders,
                modelID = modelID,
                supportsReasoning = effectiveReasoning,
                systemPrompt = "",
                messages = listOf(LLMPromptMessage(role = MessageRole.USER, content = "Reply with: OK")),
                temperature = null,
                topP = 1.0,
                maxOutputTokens = if (effectiveReasoning) 1024 else 64,
                enableThinking = false,
                thinkingBudgetTokens = 1024,
                idleTimeoutSeconds = idleTimeoutSeconds
            )
        }

        fun transientRetryDelay(
            statusCode: Int,
            retryAfterSeconds: Double?,
            message: String
        ): Double? {
            if (retryAfterSeconds != null) {
                if (retryAfterSeconds > MAX_RETRY_AFTER_WAIT_SECONDS) return null
                return maxOf(0.05, retryAfterSeconds)
            }
            return when (statusCode) {
                429 -> {
                    val lower = message.lowercase()
                    val isHardQuota = lower.contains("insufficient_quota") ||
                        lower.contains("insufficient balance") ||
                        lower.contains("余额不足") ||
                        lower.contains("billing")
                    if (isHardQuota) null else 0.8
                }
                502, 503, 504, 529 -> 0.5
                else -> null
            }
        }

        private fun isTransientConnectionDrop(error: IOException): Boolean {
            if (error is BlockedTransportException) return false
            val msg = error.message?.lowercase() ?: ""
            return msg.contains("connection reset") ||
                msg.contains("unexpected end of stream") ||
                msg.contains("broken pipe") ||
                msg.contains("eof")
        }

        fun applyCustomHeaders(headers: List<CustomHeader>, builder: Request.Builder) {
            for (header in headers) {
                if (!header.isEnabled) continue
                val k = header.key.trim()
                val v = header.value.trim()
                if (k.isNotEmpty() && !(header.isSecret && v.isEmpty())) {
                    builder.header(k, v)
                }
            }
        }

        private fun validateHttpResponse(response: Response) {
            if (response.code in 200..299) return
            val retryAfter = parseRetryAfter(response)
            val errBytes = runCatching {
                val src = response.body?.source() ?: return@runCatching ByteArray(0)
                val out = java.io.ByteArrayOutputStream()
                val buf = ByteArray(4096)
                while (out.size() < 32_768) {
                    val read = src.read(buf, 0, minOf(buf.size, 32_768 - out.size()))
                    if (read <= 0) break
                    out.write(buf, 0, read)
                }
                out.toByteArray()
            }.getOrDefault(ByteArray(0))
            val msg = enrichErrorMessage(extractReadableErrorMessage(errBytes), response)
            throw LLMHttpStatusException(response.code, msg, retryAfter)
        }

        private fun validateDataResponse(response: Response, data: ByteArray) {
            if (response.code in 200..299) return
            val msg = enrichErrorMessage(extractReadableErrorMessage(data), response)
            throw LLMError.HttpError(response.code, msg)
        }

        fun parseRetryAfter(response: Response, nowMillis: Long = System.currentTimeMillis()): Double? {
            response.header("retry-after-ms")?.trim()?.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0.0 }?.let {
                return it / 1000.0
            }
            val raw = response.header("Retry-After")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            raw.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0.0 }?.let { return it }
            return runCatching {
                val instant = ZonedDateTime.parse(raw, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
                maxOf(0.0, (instant.toEpochMilli() - nowMillis) / 1000.0)
            }.getOrNull()
        }

        fun extractRequestID(response: Response): String? {
            val candidates = listOf("x-request-id", "request-id", "anthropic-request-id", "x-correlation-id")
            for (name in candidates) {
                val raw = response.header(name)?.trim() ?: continue
                if (raw.isNotEmpty()) {
                    val safe = raw.filter { it.code in 0x20..0x7E }
                    if (safe.isNotEmpty()) return safe.take(64)
                }
            }
            return null
        }

        private fun enrichErrorMessage(message: String, response: Response): String {
            val reqID = extractRequestID(response) ?: return message
            return if (message.contains(reqID)) message else "$message [Request ID: $reqID]"
        }

        private val errJson = Json { ignoreUnknownKeys = true }

        fun extractReadableErrorMessage(data: ByteArray): String {
            if (data.isEmpty()) return L10n.text("请求失败（无详细错误信息）", "Request failed with no details.")
            val text = data.toString(Charsets.UTF_8)
            val obj = runCatching { errJson.parseToJsonElement(text).jsonObject }.getOrNull()
            if (obj != null) {
                val errElem = obj["error"]
                if (errElem is JsonObject) {
                    errElem["message"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }?.let { return it }
                } else if (errElem is JsonPrimitive && errElem.isString) {
                    errElem.content.takeIf { it.isNotEmpty() }?.let { return it }
                }
                obj["message"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }?.let { return it }
                obj["detail"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() }?.let { return it }
            }
            val raw = data.copyOfRange(0, minOf(data.size, 600)).toString(Charsets.UTF_8).trim()
            return raw.ifEmpty { L10n.text("请求被服务端拒绝", "Request rejected by server") }
        }

        fun composeTextWithDocuments(
            text: String,
            attachments: List<MessageAttachment>,
            includePDFText: Boolean
        ): String {
            val blocks = mutableListOf<String>()
            for (item in attachments) {
                if (item.kind != com.iosbox.app.core.model.AttachmentKind.DOCUMENT) continue
                if (item.mimeType == "application/pdf" && !includePDFText && item.dataBase64 != null) continue
                val safeName = xmlEscapedAttribute(item.fileName)
                val extracted = item.extractedText
                if (!extracted.isNullOrEmpty()) {
                    val safeBody = extracted.replace("</attachment>", "<\\/attachment>", ignoreCase = true)
                    blocks.add("<attachment name=\"$safeName\">\n$safeBody\n</attachment>")
                } else {
                    blocks.add(
                        L10n.text(
                            "[附件: ${item.fileName} (${item.formattedSize})]",
                            "[Attachment: ${item.fileName} (${item.formattedSize})]"
                        )
                    )
                }
            }
            if (text.isNotEmpty()) blocks.add(text)
            return blocks.joinToString("\n\n")
        }

        private fun xmlEscapedAttribute(raw: String): String =
            raw.replace("&", "&amp;")
                .replace("\"", "&quot;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")

        fun sanitizeToolHistory(messages: List<LLMPromptMessage>): List<LLMPromptMessage> {
            val result = mutableListOf<LLMPromptMessage>()
            var index = 0
            while (index < messages.size) {
                val msg = messages[index]
                if (msg.role == MessageRole.TOOL) {
                    index++
                    continue
                }
                if (msg.role == MessageRole.ASSISTANT && msg.toolCalls.isNotEmpty()) {
                    var nextIdx = index + 1
                    val toolResponses = mutableListOf<LLMPromptMessage>()
                    while (nextIdx < messages.size && messages[nextIdx].role == MessageRole.TOOL) {
                        toolResponses.add(messages[nextIdx])
                        nextIdx++
                    }
                    if (toolResponses.isEmpty()) {
                        if (msg.content.isNotEmpty() || msg.reasoningContent.isNotEmpty() || msg.attachments.isNotEmpty()) {
                            result.add(
                                LLMPromptMessage(
                                    role = MessageRole.ASSISTANT,
                                    content = msg.content.ifEmpty { "..." },
                                    reasoningContent = msg.reasoningContent,
                                    thinkingBlocks = emptyList(),
                                    attachments = msg.attachments,
                                    toolCalls = emptyList()
                                )
                            )
                        }
                        index = nextIdx
                        continue
                    }

                    result.add(msg)
                    val remaining = toolResponses.toMutableList()
                    for (call in msg.toolCalls) {
                        val matchIdx = remaining.indexOfFirst { it.toolCallID == call.id }
                        if (matchIdx >= 0) {
                            result.add(remaining.removeAt(matchIdx))
                        } else {
                            val nameIdx = remaining.indexOfFirst { it.toolCallID.isNullOrEmpty() && it.toolName == call.name }
                            if (nameIdx >= 0) {
                                val matched = remaining.removeAt(nameIdx)
                                result.add(
                                    LLMPromptMessage(
                                        role = MessageRole.TOOL,
                                        content = matched.content,
                                        toolCallID = call.id,
                                        toolName = call.name
                                    )
                                )
                            } else {
                                result.add(
                                    LLMPromptMessage(
                                        role = MessageRole.TOOL,
                                        content = """{"error":"Tool execution was interrupted"}""",
                                        toolCallID = call.id,
                                        toolName = call.name
                                    )
                                )
                            }
                        }
                    }
                    index = nextIdx
                    continue
                }
                result.add(msg)
                index++
            }
            return result
        }

        private fun elapsedMsSince(startNanos: Long): Int =
            ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
    }
}
