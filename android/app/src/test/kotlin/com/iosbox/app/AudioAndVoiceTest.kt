package com.iosbox.app.core.network

import com.iosbox.app.core.model.CustomHeader
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.time.LocalDate

class AudioAndVoiceTest {
    private lateinit var server: MockWebServer
    private lateinit var client: LLMClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        client = LLMClient(
            capabilityCache = GatewayCapabilityCache(InMemoryCapabilityCacheStore()),
            keyRouter = APIKeyPoolRouter(),
            isConsentAccepted = { true }
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun resolvesAudioTranscriptionsAndSpeechEndpointsProperly() {
        assertEquals(
            "https://api.openai.com/v1/audio/transcriptions",
            EndpointResolver.audioTranscriptionsEndpoint("https://api.openai.com").toASCIIString()
        )
        assertEquals(
            "https://api.groq.com/openai/v1/audio/transcriptions",
            EndpointResolver.audioTranscriptionsEndpoint("https://api.groq.com/openai/v1/chat/completions").toASCIIString()
        )
        assertEquals(
            "https://custom.example.com/proxy/audio/transcriptions",
            EndpointResolver.audioTranscriptionsEndpoint("https://custom.example.com/proxy#").toASCIIString()
        )
        assertEquals(
            "https://api.openai.com/v1/audio/speech",
            EndpointResolver.audioSpeechEndpoint("https://api.openai.com/v1/models").toASCIIString()
        )
        assertEquals(
            "https://api.openai.com/v1/audio/speech",
            EndpointResolver.audioSpeechEndpoint("https://api.openai.com/v1/audio/transcriptions").toASCIIString()
        )
        assertEquals(
            "http://192.168.1.50:8000/v1/audio/speech",
            EndpointResolver.audioSpeechEndpoint("http://192.168.1.50:8000").toASCIIString()
        )
        assertThrows(LLMError.InvalidURL::class.java) {
            EndpointResolver.audioTranscriptionsEndpoint("not-a-valid-url")
        }
    }

    @Test
    fun whisperTranscribeSendsMultipartHeadersAndRotatesKeysOn429() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(429)
                .setBody("""{"error":{"message":"Too many requests"}}""")
        )
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"text":"明天上午十点评审下周上线计划。"}""")
        )

        val base = server.url("/v1").toString()
        val result = AudioTranscriptionService.transcribe(
            llmClient = client,
            request = AudioTranscriptionRequest(
                baseURL = base,
                apiKey = "sk-key-1",
                apiKeys = listOf("sk-key-2"),
                customHeaders = listOf(CustomHeader(key = "X-Trace", value = "stage-b")),
                model = "whisper-large-v3-turbo",
                language = "zh",
                fileName = "../my\"meeting\n.m4a",
                mimeType = "audio/mp4",
                audioBytes = byteArrayOf(0x01, 0x02, 0x03, 0x04)
            )
        )

        assertEquals("明天上午十点评审下周上线计划。", result)
        assertEquals(2, server.requestCount)

        val firstReq = server.takeRequest()
        val secondReq = server.takeRequest()
        assertEquals("POST", secondReq.method)
        assertTrue(secondReq.path?.endsWith("/v1/audio/transcriptions") == true)
        assertEquals("stage-b", secondReq.getHeader("X-Trace"))
        assertTrue(firstReq.getHeader("Authorization") != secondReq.getHeader("Authorization"))

        val bodyText = secondReq.body.readUtf8()
        assertTrue(bodyText.contains("name=\"model\""))
        assertTrue(bodyText.contains("whisper-large-v3-turbo"))
        assertTrue(bodyText.contains("name=\"response_format\""))
        assertTrue(bodyText.contains("name=\"language\""))
        assertTrue(bodyText.contains("zh"))
        assertTrue(bodyText.contains("filename=\"my_meeting_.m4a\""))
        assertFalse(bodyText.contains("../"))
    }

    @Test
    fun whisperTranscribeSupportsPlainTextFallbackAndBlocksInsecurePublicHttpOrUnconsented() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "text/plain")
                .setBody("Plain text transcription")
        )
        val ok = AudioTranscriptionService.transcribe(
            llmClient = client,
            request = AudioTranscriptionRequest(
                baseURL = server.url("/v1").toString(),
                apiKey = "sk-test",
                fileName = "clip.wav",
                mimeType = "audio/wav",
                audioBytes = byteArrayOf(9, 8, 7)
            )
        )
        assertEquals("Plain text transcription", ok)

        var insecureBlocked = false
        try {
            AudioTranscriptionService.transcribe(
                llmClient = client,
                request = AudioTranscriptionRequest(
                    baseURL = "http://api.openai.com/v1",
                    apiKey = "sk-test",
                    fileName = "a.m4a",
                    mimeType = "audio/mp4",
                    audioBytes = byteArrayOf(1)
                )
            )
        } catch (_: LLMError.InsecurePublicHttp) {
            insecureBlocked = true
        }
        assertTrue(insecureBlocked)

        val noConsentClient = LLMClient(isConsentAccepted = { false })
        var consentBlocked = false
        try {
            AudioTranscriptionService.transcribe(
                llmClient = noConsentClient,
                request = AudioTranscriptionRequest(
                    baseURL = server.url("/v1").toString(),
                    apiKey = "sk-test",
                    fileName = "a.m4a",
                    mimeType = "audio/mp4",
                    audioBytes = byteArrayOf(1)
                )
            )
        } catch (_: LLMError.ConsentRequired) {
            consentBlocked = true
        }
        assertTrue(consentBlocked)

        assertThrows(IllegalArgumentException::class.java) {
            AudioTranscriptionService.readBoundedAudioBytes(
                ByteArrayInputStream(ByteArray(32)),
                maxBytes = 16
            )
        }
    }

    @Test
    fun cloudSpeechSynthesizerSendsJsonAndReturnsMp3BytesWithSentenceBoundaryTrim() = runTest {
        val sampleMp3 = byteArrayOf(0x49, 0x44, 0x33, 0x03, 0x00, 0x11)
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "audio/mpeg")
                .setBody(Buffer().write(sampleMp3))
        )

        val received = CloudSpeechSynthesizer.synthesize(
            llmClient = client,
            request = CloudTTSRequest(
                baseURL = server.url("/v1").toString(),
                apiKey = "sk-tts",
                model = "gpt-4o-mini-tts",
                voice = "nova",
                input = "第一句测试。"
            )
        )
        assertArrayEquals(sampleMp3, received)

        val req = server.takeRequest()
        assertEquals("Bearer sk-tts", req.getHeader("Authorization"))
        assertTrue(req.path?.endsWith("/v1/audio/speech") == true)
        val jsonBody = req.body.readUtf8()
        assertTrue(jsonBody.contains("\"model\":\"gpt-4o-mini-tts\""))
        assertTrue(jsonBody.contains("\"voice\":\"nova\""))
        assertTrue(jsonBody.contains("\"response_format\":\"mp3\""))

        val longText = "第一段已完成。" + "A".repeat(3800) + "第二段句号。" + "B".repeat(500)
        val trimmed = CloudSpeechSynthesizer.prepareInputText(longText, maxChars = 4096)
        assertTrue(trimmed.length <= 4096)
        assertTrue(trimmed.endsWith("第二段句号。"))
    }

    @Test
    fun meetingMinutesPromptBuilderIncludesDateSourceAndTranscript() {
        val refDate = LocalDate.of(2026, 11, 22)
        val minutesPrompt = MeetingMinutesPromptBuilder.buildPrompt(
            transcript = "周五前完成接口联调",
            sourceLabel = "standup.m4a",
            mode = TranscriptActionMode.MEETING_MINUTES,
            localDate = refDate
        )
        assertTrue(minutesPrompt.contains("2026-11-22"))
        assertTrue(minutesPrompt.contains("standup.m4a"))
        assertTrue(minutesPrompt.contains("<transcript>"))
        assertTrue(minutesPrompt.contains("周五前完成接口联调"))
        assertTrue(minutesPrompt.contains("YYYY-MM-DD HH:mm"))

        val cleanedNote = MeetingMinutesPromptBuilder.buildPrompt(
            transcript = "  嗯明天记得发周报  ",
            mode = TranscriptActionMode.VOICE_NOTE_CLEANUP
        )
        assertTrue(cleanedNote.contains("嗯明天记得发周报"))

        val raw = MeetingMinutesPromptBuilder.buildPrompt(
            transcript = "  原始转写内容  ",
            mode = TranscriptActionMode.INSERT_RAW
        )
        assertEquals("原始转写内容", raw)
    }
}
