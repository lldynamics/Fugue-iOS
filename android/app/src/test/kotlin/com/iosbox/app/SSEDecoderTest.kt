package com.iosbox.app.core.network

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SSEDecoderTest {
    @Test
    fun decodesBomCrLfMultiLineDataAndDiscardsUnterminatedTrailingEvent() = runTest {
        val bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())
        val payload = (
            "data: {\"a\":1}\r\n\r\n" +
                ": keep-alive\r\n" +
                "data: line1\n" +
                "data:line2\n" +
                "data\n\n" +
                "data: [DONE]\r\r" +
                "data: unterminated"
            ).toByteArray(Charsets.UTF_8)

        val buffer = Buffer().write(bom).write(payload)
        var activityCount = 0
        val events = SSEDecoder.events(buffer, onActivity = { activityCount++ }).toList()

        assertEquals(listOf("{\"a\":1}", "line1\nline2\n", "[DONE]"), events)
        assertTrue(activityCount > 0)
    }

    @Test
    fun enforcesMaximumBytesPerEvent() = runTest {
        val raw = "data: ${"x".repeat(200)}\n\n"
        val buffer = Buffer().writeUtf8(raw)
        var threw = false
        try {
            SSEDecoder.events(buffer, maximumBytes = 64).toList()
        } catch (_: LLMError.InterruptedStream) {
            threw = true
        }
        assertTrue(threw)
    }
}
