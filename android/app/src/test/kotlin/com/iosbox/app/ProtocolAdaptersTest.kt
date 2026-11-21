package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.MessageRole
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ProtocolAdaptersTest {
    private lateinit var server: MockWebServer
    private lateinit var client: LLMClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        client = LLMClient(
            capabilityCache = GatewayCapabilityCache(InMemoryCapabilityCacheStore()),
            keyRouter = APIKeyPoolRouter()
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun blocksPlainHttpToPublicHostBeforeSocketIO() = runTest {
        val req = LLMChatRequest(
            providerName = "OpenAI",
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            baseURL = "http://api.openai.com/v1",
            apiKey = "sk-test",
            modelID = "gpt-4.1",
            supportsReasoning = false,
            systemPrompt = "",
            messages = listOf(LLMPromptMessage(MessageRole.USER, "Hello")),
            temperature = null,
            topP = 1.0,
            maxOutputTokens = null,
            enableThinking = false,
            thinkingBudgetTokens = 1024
        )
        var blocked = false
        try {
            client.streamChat(req).toList()
        } catch (_: LLMError.InsecurePublicHttp) {
            blocked = true
        }
        assertTrue(blocked)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun openAIStreamingWith400StreamOptionsDegradeAnd429KeyRotation() = runTest {
        // 1st attempt: 429 rate-limit on key-1 triggers rotation to key-2
        server.enqueue(
            MockResponse()
                .setResponseCode(429)
                .setBody("""{"error":{"message":"Rate limit exceeded"}}""")
        )
        // 2nd attempt: 400 unknown stream_options triggers capability cache degrade
        server.enqueue(
            MockResponse()
                .setResponseCode(400)
                .setBody("""{"error":{"message":"Unrecognized parameter stream_options"}}""")
        )
        // 3rd attempt: succeeds with <think> + content + usage
        val sse = listOf(
            "data: {\"choices\":[{\"delta\":{\"content\":\"<think>idea</think>Hello \"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"world\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}\n\n",
            "data: [DONE]\n\n"
        ).joinToString("")
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "text/event-stream")
                .setBody(sse)
        )

        val baseUrl = server.url("/v1").toString()
        val req = LLMChatRequest(
            providerName = "Local Mock",
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            baseURL = baseUrl,
            apiKey = "sk-key-1",
            apiKeys = listOf("sk-key-2"),
            modelID = "custom-model",
            supportsReasoning = false,
            systemPrompt = "",
            messages = listOf(LLMPromptMessage(MessageRole.USER, "Hi")),
            temperature = null,
            topP = 1.0,
            maxOutputTokens = null,
            enableThinking = true,
            thinkingBudgetTokens = 2048
        )

        val events = client.streamChat(req).toList()
        val reasoning = events.filterIsInstance<LLMStreamEvent.ReasoningDelta>().joinToString("") { it.text }
        val content = events.filterIsInstance<LLMStreamEvent.ContentDelta>().joinToString("") { it.text }
        val usage = events.filterIsInstance<LLMStreamEvent.Usage>().last()

        assertEquals("idea", reasoning)
        assertEquals("Hello world", content)
        assertEquals(10, usage.promptTokens)
        assertEquals(5, usage.completionTokens)
        assertTrue(
            client.capabilityCache.isUnsupported(
                GatewayUnsupportedFeature.STREAM_OPTIONS,
                APIProtocolType.OPEN_AI_COMPATIBLE,
                baseUrl,
                "custom-model"
            )
        )
    }

    @Test
    fun anthropicStreamingAndPaginatedModels() = runTest {
        val sse = listOf(
            "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"cache_read_input_tokens\":4}}}\n\n",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"step1\"}}\n\n",
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Answer\"}}\n\n",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n",
            "data: {\"type\":\"message_stop\"}\n\n"
        ).joinToString("")
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "text/event-stream")
                .setBody(sse)
        )

        val baseUrl = server.url("/v1").toString()
        val req = LLMChatRequest(
            providerName = "Anthropic Mock",
            protocolType = APIProtocolType.ANTHROPIC,
            baseURL = baseUrl,
            apiKey = "ant-key",
            modelID = "claude-sonnet-5-5",
            supportsReasoning = true,
            systemPrompt = "Be concise.",
            messages = listOf(LLMPromptMessage(MessageRole.USER, "Hi")),
            temperature = null,
            topP = 1.0,
            maxOutputTokens = null,
            enableThinking = true,
            thinkingBudgetTokens = 2048,
            enablePromptCaching = true
        )

        val events = client.streamChat(req).toList()
        assertEquals("step1", events.filterIsInstance<LLMStreamEvent.ReasoningDelta>().joinToString("") { it.text })
        assertEquals("Answer", events.filterIsInstance<LLMStreamEvent.ContentDelta>().joinToString("") { it.text })
        val usage = events.filterIsInstance<LLMStreamEvent.Usage>().last()
        assertEquals(16, usage.promptTokens)
        assertEquals(7, usage.completionTokens)

        // Paginated /models fetch
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}],"has_more":true,"last_id":"claude-opus-5-5"}"""
            )
        )
        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"data":[{"id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5"}],"has_more":false}"""
            )
        )
        val models = client.fetchModels(
            protocolType = APIProtocolType.ANTHROPIC,
            baseURL = baseUrl,
            apiKey = "ant-key"
        )
        assertEquals(listOf("claude-opus-5-5", "claude-sonnet-5-5"), models.map { it.id })
    }

    @Test
    fun geminiStreamingThoughtImageOutputAndPaginatedModels() = runTest {
        val sse = listOf(
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"plan\",\"thought\":true}]}}]}\n\n",
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Done\"},{\"inlineData\":{\"mimeType\":\"image/png\",\"data\":\"AQID\"}}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"candidatesTokenCount\":6,\"thoughtsTokenCount\":4,\"cachedContentTokenCount\":5}}\n\n"
        ).joinToString("")
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "text/event-stream")
                .setBody(sse)
        )

        val baseUrl = server.url("/v1beta").toString()
        val req = LLMChatRequest(
            providerName = "Gemini Mock",
            protocolType = APIProtocolType.GEMINI,
            baseURL = baseUrl,
            apiKey = "gem-key",
            modelID = "gemini-3.8-flash",
            supportsReasoning = true,
            systemPrompt = "",
            messages = listOf(LLMPromptMessage(MessageRole.USER, "Draw")),
            temperature = null,
            topP = 1.0,
            maxOutputTokens = null,
            enableThinking = true,
            thinkingBudgetTokens = 4096
        )

        val events = client.streamChat(req).toList()
        assertEquals("plan", events.filterIsInstance<LLMStreamEvent.ReasoningDelta>().joinToString("") { it.text })
        assertEquals("Done", events.filterIsInstance<LLMStreamEvent.ContentDelta>().joinToString("") { it.text })
        assertEquals(1, events.filterIsInstance<LLMStreamEvent.AttachmentDelta>().size)
        val usage = events.filterIsInstance<LLMStreamEvent.Usage>().last()
        assertEquals(20, usage.promptTokens)
        assertEquals(10, usage.completionTokens) // 6 candidates + 4 thoughts
        val cache = events.filterIsInstance<LLMStreamEvent.CacheUsage>().last()
        assertEquals(5, cache.cachedTokens)

        server.enqueue(
            MockResponse().setResponseCode(200).setBody(
                """{"models":[{"name":"models/gemini-4-neon","displayName":"Gemini 4 Neon","supportedGenerationMethods":["generateContent"]}]}"""
            )
        )
        val models = client.fetchModels(
            protocolType = APIProtocolType.GEMINI,
            baseURL = baseUrl,
            apiKey = "gem-key"
        )
        assertEquals(listOf("gemini-4-neon"), models.map { it.id })
    }
}
