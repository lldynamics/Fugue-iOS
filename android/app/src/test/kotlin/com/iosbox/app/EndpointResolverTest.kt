package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class EndpointResolverTest {
    @Test
    fun openAIChatEndpointAutoAppendsV1AndHandlesVersionedPaths() {
        assertEquals(
            "https://api.openai.com/v1/chat/completions",
            EndpointResolver.chatEndpoint("https://api.openai.com", APIProtocolType.OPEN_AI_COMPATIBLE).toASCIIString()
        )
        assertEquals(
            "https://openrouter.ai/api/v1/chat/completions",
            EndpointResolver.chatEndpoint("https://openrouter.ai/api/v1/", APIProtocolType.OPEN_AI_COMPATIBLE).toASCIIString()
        )
        assertEquals(
            "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            EndpointResolver.chatEndpoint("https://open.bigmodel.cn/api/paas/v4", APIProtocolType.OPEN_AI_COMPATIBLE).toASCIIString()
        )
        assertEquals(
            "https://relay.example.com/custom/chat/completions",
            EndpointResolver.chatEndpoint("https://relay.example.com/custom#", APIProtocolType.OPEN_AI_COMPATIBLE).toASCIIString()
        )
    }

    @Test
    fun anthropicChatAndModelsEndpoints() {
        assertEquals(
            "https://api.anthropic.com/v1/messages",
            EndpointResolver.chatEndpoint("https://api.anthropic.com", APIProtocolType.ANTHROPIC).toASCIIString()
        )
        assertEquals(
            "https://api.anthropic.com/v1/models",
            EndpointResolver.modelsEndpoint("https://api.anthropic.com/v1/messages", APIProtocolType.ANTHROPIC).toASCIIString()
        )
    }

    @Test
    fun geminiChatAndModelsEndpointsAndPathValidation() {
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
            EndpointResolver.chatEndpoint(
                "https://generativelanguage.googleapis.com",
                APIProtocolType.GEMINI,
                "gemini-2.5-flash"
            ).toASCIIString()
        )
        assertEquals(
            "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
            EndpointResolver.modelsEndpoint(
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse",
                APIProtocolType.GEMINI
            ).toASCIIString()
        )
        assertThrows(LLMError.InvalidURL::class.java) {
            EndpointResolver.chatEndpoint(
                "https://generativelanguage.googleapis.com/v1beta",
                APIProtocolType.GEMINI,
                "../evil"
            )
        }
        assertThrows(LLMError.InvalidURL::class.java) {
            EndpointResolver.chatEndpoint(
                "https://generativelanguage.googleapis.com/v1beta",
                APIProtocolType.GEMINI,
                "gemini?key=leak"
            )
        }
    }

    @Test
    fun openAIModelsEndpointStripsChatCompletions() {
        assertEquals(
            "https://api.deepseek.com/v1/models",
            EndpointResolver.modelsEndpoint(
                "https://api.deepseek.com/v1/chat/completions",
                APIProtocolType.OPEN_AI_COMPATIBLE
            ).toASCIIString()
        )
    }
}
