package com.iosbox.app.core.network

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okio.BufferedSource
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * Pulls one complete SSE `data:` event at a time, preserving blank `data:` lines while enforcing
 * line and event size caps and discarding any trailing event not terminated by a blank line.
 */
object SSEDecoder {
    const val DEFAULT_MAXIMUM_BYTES = 2 * 1024 * 1024

    private val json = Json { ignoreUnknownKeys = true }

    fun events(
        source: BufferedSource,
        maximumBytes: Int = DEFAULT_MAXIMUM_BYTES,
        onActivity: (() -> Unit)? = null
    ): Flow<String> = flow {
        val line = ByteArrayOutputStream(256)
        val fields = mutableListOf<String>()
        var eventSize = 0
        var bytesSinceTouch = 0
        var streamBytes = 0
        var emittedEvents = 0
        var skipLF = false
        var firstLine = true

        fun finishLine(): String? {
            val raw = line.toByteArray()
            line.reset()
            val cleaned = if (firstLine) {
                firstLine = false
                if (raw.size >= 3 &&
                    raw[0] == 0xEF.toByte() &&
                    raw[1] == 0xBB.toByte() &&
                    raw[2] == 0xBF.toByte()
                ) {
                    raw.copyOfRange(3, raw.size)
                } else {
                    raw
                }
            } else {
                raw
            }
            if (cleaned.isEmpty()) {
                val event = if (fields.isEmpty()) null else fields.joinToString("\n")
                fields.clear()
                eventSize = 0
                return event
            }
            val text = decodeUtf8StrictOrThrow(cleaned)
            if (text == "data" || text.startsWith("data:")) {
                var field = if (text == "data") "" else text.substring(5)
                if (field.startsWith(" ")) field = field.substring(1)
                eventSize += cleaned.size + 1
                if (eventSize > maximumBytes) throw LLMError.InterruptedStream()
                fields.add(field)
            }
            return null
        }

        while (!source.exhausted()) {
            currentCoroutineContext().ensureActive()
            val byte = source.readByte().toInt() and 0xFF
            if (++streamBytes > 32 * 1024 * 1024) throw LLMError.InterruptedStream()
            if (skipLF) {
                skipLF = false
                if (byte == 10) continue
            }
            if (byte == 13 || byte == 10) {
                bytesSinceTouch = 0
                onActivity?.invoke()
                skipLF = (byte == 13)
                val event = finishLine()
                if (event != null) {
                    if (++emittedEvents > 12_000) throw LLMError.InterruptedStream()
                    emit(event)
                }
            } else {
                line.write(byte)
                if (line.size() > maximumBytes) throw LLMError.InterruptedStream()
                bytesSinceTouch++
                if (bytesSinceTouch >= 256) {
                    bytesSinceTouch = 0
                    onActivity?.invoke()
                }
            }
        }
        // Per SSE spec & iOS SSEDecoder: discard an event not terminated by a blank line.
    }

    fun jsonObject(data: String): JsonObject {
        val element = runCatching { json.parseToJsonElement(data) }.getOrNull()
        return (element as? JsonObject) ?: throw LLMError.ApiError(
            com.iosbox.app.core.model.L10n.text(
                "流式响应格式无效，回复可能不完整。",
                "Invalid streaming response format; reply may be incomplete."
            )
        )
    }

    private fun decodeUtf8StrictOrThrow(bytes: ByteArray): String {
        val decoder = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return runCatching { decoder.decode(ByteBuffer.wrap(bytes)).toString() }
            .getOrElse { throw LLMError.InterruptedStream() }
    }
}
