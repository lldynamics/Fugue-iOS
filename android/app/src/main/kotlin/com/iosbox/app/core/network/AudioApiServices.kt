package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.ProviderItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

enum class TranscriptActionMode {
    MEETING_MINUTES,
    VOICE_NOTE_CLEANUP,
    INSERT_RAW
}

object MeetingMinutesPromptBuilder {
    fun buildPrompt(
        transcript: String,
        sourceLabel: String? = null,
        mode: TranscriptActionMode,
        localDate: LocalDate = LocalDate.now()
    ): String {
        val cleanTranscript = transcript.trim()
        if (cleanTranscript.isEmpty()) return ""
        if (mode == TranscriptActionMode.INSERT_RAW) {
            return cleanTranscript
        }
        val sourceLine = sourceLabel?.trim()?.takeIf { it.isNotEmpty() }?.let { "（来源：$it）" } ?: ""
        return when (mode) {
            TranscriptActionMode.MEETING_MINUTES -> {
                val dateStr = localDate.format(DateTimeFormatter.ISO_LOCAL_DATE)
                """
                请根据以下语音转写文本整理一份结构清晰的「会议纪要与行动项」$sourceLine（参考日期：$dateStr）：

                要求：
                1. **一句话结论 (TL;DR)**：提炼核心议题与最终结论。
                2. **关键讨论要点**：按主题分点列出重要信息、共识与分歧（去除口水话与重复）。
                3. **待办行动项与日程**：列出具体待办、负责人（如提及），若涉及具体时间或截止日期请换算为明确日期时间格式（例如 `YYYY-MM-DD HH:mm` 或 `YYYY-MM-DD`），方便一键写入系统日历。
                4. **待确认问题**：如有遗留问题请单独标出；全篇请保持客观、忠于原文。

                <transcript>
                $cleanTranscript
                </transcript>
                """.trimIndent()
            }
            TranscriptActionMode.VOICE_NOTE_CLEANUP -> {
                """
                请将以下语音口述转写整理为通顺、精炼、可直接转发微信或办公软件的书面文字$sourceLine：

                要求：
                1. 去除口头禅（嗯、啊、那个等）、重复与明显语病，补全标点并合理分段。
                2. 如包含多个事项或要点，请使用简洁条理的编号/要点列表呈现。
                3. 忠实保留原意，不要凭空增删事实或数据。

                <transcript>
                $cleanTranscript
                </transcript>
                """.trimIndent()
            }
            TranscriptActionMode.INSERT_RAW -> cleanTranscript
        }
    }
}

data class AudioTranscriptionRequest(
    val baseURL: String,
    val apiKey: String,
    val apiKeys: List<String> = emptyList(),
    val customHeaders: List<CustomHeader> = emptyList(),
    val model: String = "whisper-1",
    val language: String = "",
    val fileName: String,
    val mimeType: String,
    val audioBytes: ByteArray
)

data class CloudTTSRequest(
    val baseURL: String,
    val apiKey: String,
    val apiKeys: List<String> = emptyList(),
    val customHeaders: List<CustomHeader> = emptyList(),
    val model: String = "tts-1",
    val voice: String = "alloy",
    val input: String
)

private object AudioHttpExecutor {
    suspend fun executeWithKeyRotation(
        llmClient: LLMClient,
        baseURL: String,
        primaryKey: String,
        extraKeys: List<String>,
        maxResponseBytes: Int,
        buildRequest: (activeKey: String) -> Request
    ): Pair<ByteArray, String?> {
        if (!llmClient.hasConsentAccepted()) {
            throw LLMError.ConsentRequired()
        }
        if (NetworkLocation.isPlainHTTPToPublicHost(baseURL)) {
            throw LLMError.InsecurePublicHttp(baseURL)
        }

        val orderedKeys = llmClient.keyRouter.orderedKeys(
            rawKeys = listOf(primaryKey) + extraKeys,
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            baseURL = baseURL
        )
        val limit = minOf(orderedKeys.size, 4)
        var lastError: Throwable? = null

        for (index in 0 until limit) {
            val candidateKey = orderedKeys[index]
            val request = buildRequest(candidateKey)
            val response = executeCall(llmClient.clientFor(request).newCall(request))

            val result = response.use { res ->
                val rawBytes = readResponseBytes(res, maxBytes = maxOf(maxResponseBytes, 32_768))
                if (res.code !in 200..299) {
                    val errSlice = rawBytes.copyOfRange(0, minOf(rawBytes.size, 32_768))
                    val message = LLMClient.extractReadableErrorMessage(errSlice)
                    val httpErr = LLMError.HttpError(res.code, message)
                    if (res.code in setOf(401, 402, 403, 429) && index + 1 < limit) {
                        llmClient.keyRouter.markUnhealthy(
                            key = candidateKey,
                            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                            baseURL = baseURL,
                            statusCode = res.code
                        )
                        lastError = httpErr
                        return@use null
                    }
                    throw httpErr
                }
                if (rawBytes.size > maxResponseBytes) {
                    throw IOException(
                        L10n.text("服务端返回音频或响应体积过大。", "Server response exceeded maximum allowed size.")
                    )
                }
                llmClient.keyRouter.markHealthy(
                    key = candidateKey,
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    baseURL = baseURL
                )
                rawBytes to res.header("Content-Type")
            }
            if (result != null) return result
        }
        throw lastError ?: LLMError.EmptyResponse()
    }

    private suspend fun executeCall(call: Call): Response = withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { cont ->
            cont.invokeOnCancellation {
                call.cancel()
            }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isCancelled) return
                    cont.resumeWithException(e)
                }

                override fun onResponse(call: Call, response: Response) {
                    if (cont.isCancelled) {
                        response.close()
                        return
                    }
                    cont.resume(response)
                }
            })
        }
    }

    private fun readResponseBytes(response: Response, maxBytes: Int): ByteArray {
        val body = response.body ?: return ByteArray(0)
        val contentLength = body.contentLength()
        if (contentLength > maxBytes.toLong()) {
            throw IOException(
                L10n.text("服务端响应超出安全大小上限。", "Response content length exceeded maximum limit.")
            )
        }
        val stream = body.byteStream()
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val read = stream.read(buf)
            if (read <= 0) break
            total += read
            if (total > maxBytes) {
                throw IOException(
                    L10n.text("服务端响应超出安全大小上限。", "Response stream exceeded maximum limit.")
                )
            }
            out.write(buf, 0, read)
        }
        return out.toByteArray()
    }
}

object AudioTranscriptionService {
    const val MAX_AUDIO_BYTES = 25 * 1024 * 1024
    const val MAX_RESPONSE_BYTES = 4 * 1024 * 1024

    val PRESET_MODELS = listOf(
        "whisper-1",
        "gpt-4o-mini-transcribe",
        "whisper-large-v3-turbo",
        "FunAudioLLM/SenseVoiceSmall"
    )

    val PRESET_LANGUAGES: List<Pair<String, String>> = listOf(
        "" to "自动识别",
        "zh" to "中文",
        "en" to "English",
        "ja" to "日本語"
    )

    private val jsonCodec = Json { ignoreUnknownKeys = true }

    fun resolveAudioProvider(
        providers: List<ProviderItem>,
        preferredProviderID: String?
    ): ProviderItem? {
        val eligible = providers.filter {
            it.isEnabled &&
                it.protocolType == APIProtocolType.OPEN_AI_COMPATIBLE &&
                it.hasConfiguredChatAPI
        }
        if (eligible.isEmpty()) return null
        val preferred = preferredProviderID?.trim()?.takeIf { it.isNotEmpty() }
        if (preferred != null) {
            eligible.firstOrNull { it.id.equals(preferred, ignoreCase = true) }?.let { return it }
        }
        return eligible.firstOrNull()
    }

    fun sanitizeFileName(raw: String): String {
        val tail = raw.substringAfterLast('/').substringAfterLast('\\').trim()
        val cleaned = buildString(tail.length) {
            for (ch in tail) {
                if (ch.code in 0x20..0x7E && ch !in listOf('"', '\'', ';', '/', '\\')) {
                    append(ch)
                } else if (ch.code > 0x7E && !ch.isISOControl()) {
                    append(ch)
                } else {
                    append('_')
                }
            }
        }.trim('.', ' ')
        return if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") {
            "recording.m4a"
        } else {
            cleaned.take(120)
        }
    }

    fun mimeTypeForExtension(fileName: String, fallbackMime: String? = null): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "m4a", "mp4", "m4b" -> "audio/mp4"
            "mp3", "mpga", "mpeg" -> "audio/mpeg"
            "wav", "wave" -> "audio/wav"
            "webm" -> "audio/webm"
            "ogg", "oga", "opus" -> "audio/ogg"
            "flac" -> "audio/flac"
            "aac" -> "audio/aac"
            else -> fallbackMime?.takeIf { it.startsWith("audio/", ignoreCase = true) } ?: "audio/mp4"
        }
    }

    fun readBoundedAudioBytes(input: InputStream, maxBytes: Int = MAX_AUDIO_BYTES): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val read = input.read(buf)
            if (read <= 0) break
            total += read
            if (total > maxBytes) {
                throw IllegalArgumentException(
                    L10n.text(
                        "音频文件超过 25 MB 上限，请剪辑后分段转写。",
                        "Audio file exceeds the 25 MB limit."
                    )
                )
            }
            out.write(buf, 0, read)
        }
        val bytes = out.toByteArray()
        if (bytes.isEmpty()) {
            throw IllegalArgumentException(
                L10n.text("音频文件为空，无法转写。", "Audio file is empty.")
            )
        }
        return bytes
    }

    fun parseTranscriptionResponse(rawBytes: ByteArray, contentType: String? = null): String {
        val rawText = rawBytes.toString(Charsets.UTF_8).trim()
        if (rawText.isEmpty()) throw LLMError.EmptyResponse()

        val element = runCatching { jsonCodec.parseToJsonElement(rawText) }.getOrNull()
        if (element is JsonObject) {
            val errObj = element["error"]
            if (errObj is JsonObject) {
                val msg = errObj["message"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
                if (msg.isNotEmpty()) throw LLMError.ApiError(msg)
            } else if (errObj is JsonPrimitive && errObj.isString && errObj.content.isNotBlank()) {
                throw LLMError.ApiError(errObj.content.trim())
            }
            val text = element["text"]?.jsonPrimitive?.contentOrNull?.trim().orEmpty()
            if (text.isNotEmpty()) return text
            val nested = runCatching { element["data"]?.jsonObject?.get("text")?.jsonPrimitive?.contentOrNull?.trim() }
                .getOrNull()
                .orEmpty()
            if (nested.isNotEmpty()) return nested
            throw LLMError.EmptyResponse()
        }

        if (contentType?.contains("application/json", ignoreCase = true) == true) {
            throw LLMError.EmptyResponse()
        }
        return rawText
    }

    suspend fun transcribe(
        llmClient: LLMClient,
        request: AudioTranscriptionRequest
    ): String {
        if (request.audioBytes.isEmpty()) {
            throw IllegalArgumentException(L10n.text("音频内容为空。", "Audio data is empty."))
        }
        if (request.audioBytes.size > MAX_AUDIO_BYTES) {
            throw IllegalArgumentException(
                L10n.text("音频文件超过 25 MB 上限。", "Audio file exceeds the 25 MB limit.")
            )
        }

        val endpoint = EndpointResolver.audioTranscriptionsEndpoint(request.baseURL)
        val safeFileName = sanitizeFileName(request.fileName)
        val safeMime = mimeTypeForExtension(safeFileName, request.mimeType)
        val model = request.model.trim().ifEmpty { "whisper-1" }
        val language = request.language.trim()

        val (responseBytes, contentType) = AudioHttpExecutor.executeWithKeyRotation(
            llmClient = llmClient,
            baseURL = request.baseURL,
            primaryKey = request.apiKey,
            extraKeys = request.apiKeys,
            maxResponseBytes = MAX_RESPONSE_BYTES
        ) { activeKey ->
            val multipart = MultipartBody.Builder()
                .setType(MultipartBody.FORM)
                .addFormDataPart(
                    "file",
                    safeFileName,
                    request.audioBytes.toRequestBody(safeMime.toMediaType())
                )
                .addFormDataPart("model", model)
                .addFormDataPart("response_format", "json")
            if (language.isNotEmpty()) {
                multipart.addFormDataPart("language", language)
            }
            val builder = Request.Builder()
                .url(endpoint.toASCIIString())
                .post(multipart.build())
                .header("Accept", "application/json, text/plain")
            if (activeKey.isNotEmpty()) {
                builder.header("Authorization", "Bearer $activeKey")
            }
            LLMClient.applyCustomHeaders(request.customHeaders, builder)
            builder.build()
        }
        return parseTranscriptionResponse(responseBytes, contentType)
    }
}

object CloudSpeechSynthesizer {
    const val MAX_INPUT_CHARS = 4096
    const val MAX_AUDIO_RESPONSE_BYTES = 16 * 1024 * 1024

    val PRESET_MODELS = listOf("tts-1", "tts-1-hd", "gpt-4o-mini-tts")
    val PRESET_VOICES = listOf("alloy", "nova", "shimmer", "echo", "fable", "onyx")

    private val jsonType = "application/json; charset=utf-8".toMediaType()
    private val jsonCodec = Json { ignoreUnknownKeys = true }

    fun prepareInputText(cleanedSpeechText: String, maxChars: Int = MAX_INPUT_CHARS): String {
        val trimmed = cleanedSpeechText.trim()
        if (trimmed.length <= maxChars) return trimmed
        val window = trimmed.substring(0, maxChars)
        val boundaryChars = charArrayOf('。', '！', '？', '.', '!', '?', '\n')
        val cutIndex = window.lastIndexOfAny(boundaryChars)
        return if (cutIndex >= maxChars / 2) {
            window.substring(0, cutIndex + 1).trim()
        } else {
            window.trim()
        }
    }

    suspend fun synthesize(
        llmClient: LLMClient,
        request: CloudTTSRequest
    ): ByteArray {
        val prepared = prepareInputText(request.input)
        if (prepared.isEmpty()) {
            throw LLMError.EmptyResponse()
        }

        val endpoint = EndpointResolver.audioSpeechEndpoint(request.baseURL)
        val model = request.model.trim().ifEmpty { "tts-1" }
        val voice = request.voice.trim().ifEmpty { "alloy" }
        val payload = buildJsonObject {
            put("model", model)
            put("input", prepared)
            put("voice", voice)
            put("response_format", "mp3")
        }
        val bodyStr = jsonCodec.encodeToString(JsonObject.serializer(), payload)

        val (audioBytes, _) = AudioHttpExecutor.executeWithKeyRotation(
            llmClient = llmClient,
            baseURL = request.baseURL,
            primaryKey = request.apiKey,
            extraKeys = request.apiKeys,
            maxResponseBytes = MAX_AUDIO_RESPONSE_BYTES
        ) { activeKey ->
            val builder = Request.Builder()
                .url(endpoint.toASCIIString())
                .post(bodyStr.toRequestBody(jsonType))
                .header("Content-Type", "application/json")
                .header("Accept", "audio/mpeg, audio/*")
            if (activeKey.isNotEmpty()) {
                builder.header("Authorization", "Bearer $activeKey")
            }
            LLMClient.applyCustomHeaders(request.customHeaders, builder)
            builder.build()
        }
        if (audioBytes.isEmpty()) {
            throw LLMError.EmptyResponse()
        }
        return audioBytes
    }
}
