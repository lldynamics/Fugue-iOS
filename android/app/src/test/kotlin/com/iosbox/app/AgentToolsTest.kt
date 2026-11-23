package com.iosbox.app

import com.iosbox.app.core.backup.BackupJson
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.network.AgentToolRunner
import com.iosbox.app.core.network.GatewayCapabilityCache
import com.iosbox.app.core.network.InMemoryCapabilityCacheStore
import com.iosbox.app.core.network.LLMChatRequest
import com.iosbox.app.core.network.LLMClient
import com.iosbox.app.core.network.LLMPromptMessage
import com.iosbox.app.core.network.LLMStreamEvent
import com.iosbox.app.core.network.LLMToolCall
import com.iosbox.app.core.network.ReadablePage
import com.iosbox.app.core.network.SearchEvidence
import com.iosbox.app.core.network.SearchSource
import com.iosbox.app.core.network.SubscriptionFeedParser
import com.iosbox.app.core.network.TavilySearchClient
import com.iosbox.app.core.network.ToolCallRecord
import com.iosbox.app.core.network.WebpageApprovalDecision
import com.iosbox.app.core.network.WebpageReadError
import com.iosbox.app.core.network.WebpageReader
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

class AgentToolsTest {
    @Test
    fun webpageReaderAppliesApprovalBeforeFollowingANewLocation() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/current"))
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/current"))
            server.enqueue(MockResponse().setHeader("Content-Type", "text/plain").setBody("Current text"))
            val client = OkHttpClient()
            val url = server.url("/previous").toUri()
            try {
                WebpageReader.read(url, client, skipPublicHostCheckForTesting = true, authorizeRedirect = { false })
                throw AssertionError("The new location still needs approval")
            } catch (_: WebpageReadError.DestinationNotApproved) {}
            assertEquals(1, server.requestCount)
            val allowed = WebpageReader.read(url, client, skipPublicHostCheckForTesting = true,
                authorizeRedirect = { it.path == "/current" })
            assertEquals("Current text", allowed.text)
            assertEquals(3, server.requestCount)
        }
    }
    @Test
    fun articleAndFeedParsersKeepVisibleContentAndReadQuotedLinkAttributes() {
        val (title, body) = WebpageReader.extractReadableHtml(
            "<title>Notes &amp; references</title><article><svg /><p>Keep this paragraph.</p></article>"
        )
        assertEquals("Notes & references", title)
        assertTrue(body.contains("Keep this paragraph."))
        val feed = SubscriptionFeedParser.discover(
            """<head><template><link rel="alternate" type="application/rss+xml" href="/example.xml"></template>
                <link title="Today's notes" href="/feed.xml?group=one&amp;format=rss" type="application/rss+xml" rel="alternate"></head>""",
            "https://example.com/library/"
        )
        assertEquals("https://example.com/feed.xml?group=one&format=rss", feed)
    }

    @Test
    fun webpageReaderBlocksInsecureAndPrivateHostsAndExtractsCleanHtmlText() = runTest {
        assertThrows(WebpageReadError.InvalidUrl::class.java) {
            WebpageReader.validate(URI("http://example.com/docs"))
        }
        assertThrows(WebpageReadError.BlockedPrivateHost::class.java) {
            WebpageReader.validate(URI("https://127.0.0.1/secret"))
        }
        assertThrows(WebpageReadError.BlockedPrivateHost::class.java) {
            WebpageReader.validate(URI("https://192.168.1.50:8443/admin"))
        }
        assertThrows(WebpageReadError.BlockedPrivateHost::class.java) {
            WebpageReader.validate(URI("https://[::1]/local"))
        }
        WebpageReader.validate(URI("https://developer.android.com/jetpack/compose"))

        val server = MockWebServer()
        server.start()
        try {
            server.enqueue(
                MockResponse()
                    .setHeader("Content-Type", "text/html; charset=utf-8")
                    .setBody(
                        """
                        <html>
                        <head><title>Compose &amp; Kotlin Guide</title><script>alert('x')</script></head>
                        <body><style>.a{color:red}</style><h1>Hello World</h1><p>Paragraph &lt;one&gt;.</p></body>
                        </html>
                        """.trimIndent()
                    )
            )
            val page = WebpageReader.read(
                uri = server.url("/guide").toUri(),
                client = OkHttpClient(),
                skipPublicHostCheckForTesting = true
            )
            assertEquals("Compose & Kotlin Guide", page.title)
            assertTrue(page.text.contains("Hello World"))
            assertTrue(page.text.contains("Paragraph <one>."))
            assertFalse(page.text.contains("alert"))
            assertFalse(page.text.contains("color:red"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun tavilySearchClientDecodesValidatesUrlsAndRejectsRedirects() = runTest {
        val raw = """
            {
              "results": [
                {"title": "Local Blocked", "url": "https://127.0.0.1/leak", "content": "should be skipped"},
                {"title": "Plain HTTP Blocked", "url": "http://example.com/post", "content": "should be skipped"},
                {"title": "Kotlin Coroutines", "url": "https://kotlinlang.org/docs/coroutines-overview.html", "content": "Asynchronous programming with coroutines."}
              ],
              "usage": {"credits": 1.0}
            }
        """.trimIndent().toByteArray(Charsets.UTF_8)

        val evidence = TavilySearchClient.decode(raw, "kotlin coroutines", nowEpochMs = 1_795_239_000_000L)
        assertEquals(1, evidence.sources.size)
        assertEquals("https://kotlinlang.org/docs/coroutines-overview.html", evidence.sources[0].url)
        assertTrue(evidence.prompt.contains("Untrusted reference", ignoreCase = true))

        // HTTP 302 redirect on Tavily endpoint must not be followed (returns HTTP error cleanly)
        val server = MockWebServer()
        server.start()
        try {
            server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "https://evil.example.com/steal"))
            var thrown: Throwable? = null
            try {
                TavilySearchClient.search("test query", "tvly-secret-key", endpointUrl = server.url("/search").toString())
            } catch (t: Throwable) {
                thrown = t
            }
            assertTrue(thrown is com.iosbox.app.core.network.SearchError.Http)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun agentToolRunnerCanonicalizesUserUrlsAndGatesUnlistedWebpages() = runTest {
        val userUrls = AgentToolRunner.extractUserProvidedURLs(
            listOf("请帮我看一下 https://Developer.Android.com:443/jetpack/compose#section-1。")
        )
        assertEquals(setOf("https://developer.android.com/jetpack/compose"), userUrls)

        // Exfiltration variant with unexpected query string is NOT auto-allowed
        val queryVariantKey = AgentToolRunner.canonicalURLKey(
            URI("https://developer.android.com/jetpack/compose?secret=leaked")
        )
        assertFalse(userUrls.contains(queryVariantKey))

        var approvalAsked = false
        val deniedOutput = AgentToolRunner.execute(
            call = LLMToolCall(
                id = "call_deny",
                name = "read_webpage",
                argumentsJSON = """{"url":"https://example.com/unlisted"}"""
            ),
            searchHandler = { error("unused") },
            webpageHandler = { error("should not fetch when denied") },
            webpageApproval = {
                approvalAsked = true
                WebpageApprovalDecision.DENY
            }
        )
        assertTrue(approvalAsked)
        assertFalse(deniedOutput.record.succeeded)
        assertTrue(deniedOutput.toolOutputJSON.contains("declined"))
    }

    @Test
    fun agentToolRunnerExecutesSearchWebpageAndProposeMemoryTools() = runTest {
        val defsWithAll = AgentToolRunner.definitions(hasTavilyKey = true, hasKnowledgeBase = true)
        assertEquals(
            listOf("web_search", "search_documents", "read_webpage", "propose_memory"),
            defsWithAll.map { it.name }
        )
        val defsNoTavily = AgentToolRunner.definitions(hasTavilyKey = false, hasKnowledgeBase = false)
        assertEquals(listOf("read_webpage", "propose_memory"), defsNoTavily.map { it.name })

        val searchExec = AgentToolRunner.execute(
            call = LLMToolCall("c1", "web_search", """{"query":"Compose 2026"}"""),
            searchHandler = { q ->
                SearchEvidence(
                    query = q,
                    searchedAt = 1_795_239_000_000L,
                    sources = listOf(SearchSource(1, "Compose", "https://developer.android.com/compose", "Modern UI toolkit"))
                )
            }
        )
        assertTrue(searchExec.record.succeeded)
        assertEquals(1, searchExec.searchEvidence?.sources?.size)

        val memExec = AgentToolRunner.execute(
            call = LLMToolCall("c2", "propose_memory", """{"fact":"Prefers Kotlin over Java"}"""),
            searchHandler = { error("unused") }
        )
        assertTrue(memExec.record.succeeded)
        assertEquals("Prefers Kotlin over Java", memExec.proposedMemory)

        val pageExec = AgentToolRunner.execute(
            call = LLMToolCall("c3", "read_webpage", """{"url":"https://example.com/page"}"""),
            searchHandler = { error("unused") },
            webpageHandler = { uri -> ReadablePage(uri.toASCIIString(), "Example Title", "Main article body", false) },
            webpageApproval = { WebpageApprovalDecision.ALLOW }
        )
        assertTrue(pageExec.record.succeeded)
        assertTrue(pageExec.toolOutputJSON.contains("Main article body"))
    }

    @Test
    fun multiRoundToolCallingEndToEndAcrossOpenAIAndAnthropicAdapters() = runTest {
        val server = MockWebServer()
        server.start()
        try {
            val client = LLMClient(capabilityCache = GatewayCapabilityCache(InMemoryCapabilityCacheStore()))

            // OpenAI Round 1: emits streamed tool_call; Round 2: emits final answer after receiving tool role message
            server.enqueue(
                MockResponse()
                    .setHeader("Content-Type", "text/event-stream")
                    .setBody(
                        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"propose_memory\",\"arguments\":\"{\\\"fact\\\":\\\"Likes \"}}]},\"finish_reason\":null}]}\n\n" +
                            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"espresso\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n" +
                            "data: [DONE]\n\n"
                    )
            )
            server.enqueue(
                MockResponse()
                    .setHeader("Content-Type", "text/event-stream")
                    .setBody(
                        "data: {\"choices\":[{\"delta\":{\"content\":\"Noted your preference!\"},\"finish_reason\":\"stop\"}]}\n\n" +
                            "data: [DONE]\n\n"
                    )
            )

            val tools = AgentToolRunner.definitions(hasTavilyKey = false)
            val req1 = LLMChatRequest(
                providerName = "MockOpenAI",
                protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                baseURL = server.url("/v1").toString(),
                apiKey = "sk-test",
                modelID = "gpt-4.1",
                supportsReasoning = false,
                systemPrompt = "Be helpful",
                messages = listOf(LLMPromptMessage(MessageRole.USER, "I love espresso")),
                temperature = 0.2,
                topP = 1.0,
                maxOutputTokens = 200,
                enableThinking = false,
                thinkingBudgetTokens = 1024,
                tools = tools
            )
            val round1Events = client.streamChat(req1).toList()
            val toolCall = round1Events.filterIsInstance<LLMStreamEvent.ToolCall>().single().call
            assertEquals("call_1", toolCall.id)
            assertEquals("propose_memory", toolCall.name)

            val exec = AgentToolRunner.execute(toolCall, searchHandler = { error("unused") })
            assertEquals("Likes espresso", exec.proposedMemory)

            val req2 = req1.copy(
                messages = req1.messages + listOf(
                    LLMPromptMessage(MessageRole.ASSISTANT, content = "", toolCalls = listOf(toolCall)),
                    LLMPromptMessage(MessageRole.TOOL, content = exec.toolOutputJSON, toolCallID = toolCall.id, toolName = toolCall.name)
                )
            )
            val round2Events = client.streamChat(req2).toList()
            val finalContent = round2Events.filterIsInstance<LLMStreamEvent.ContentDelta>().joinToString("") { it.text }
            assertEquals("Noted your preference!", finalContent)

            server.takeRequest()
            val secondBody = server.takeRequest().body.readUtf8()
            assertTrue(secondBody.contains("\"role\":\"tool\""))
            assertTrue(secondBody.contains("\"tool_call_id\":\"call_1\""))

            // Anthropic Round 1: emits tool_use block
            server.enqueue(
                MockResponse()
                    .setHeader("Content-Type", "text/event-stream")
                    .setBody(
                        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_webpage\",\"input\":{}}}\n\n" +
                            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"url\\\":\\\"https://example.com\\\"}\"}}\n\n" +
                            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" +
                            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n" +
                            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
                    )
            )
            val anthropicEvents = client.streamChat(
                req1.copy(
                    providerName = "MockAnthropic",
                    protocolType = APIProtocolType.ANTHROPIC,
                    modelID = "claude-3-7-sonnet"
                )
            ).toList()
            val anthropicCall = anthropicEvents.filterIsInstance<LLMStreamEvent.ToolCall>().single().call
            assertEquals("toolu_1", anthropicCall.id)
            assertEquals("read_webpage", anthropicCall.name)
            assertTrue(anthropicCall.argumentsJSON.contains("https://example.com"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun toolAndSearchMetadataRoundTripPreservesUnknownFields() {
        val codec = BackupJson.codec
        val existingJson = codec.parseToJsonElement(
            """{"isBookmarked":true,"requestedSearchQuery":"old query","routeNotice":"fast-model"}"""
        ).jsonObject

        val meta = MessageAssistanceMetadata(
            requestedSearchQuery = "latest Kotlin",
            search = SearchEvidence(
                query = "latest Kotlin",
                searchedAt = 1_795_239_000_000L,
                sources = listOf(SearchSource(1, "Kotlin", "https://kotlinlang.org", "Release notes"))
            ),
            toolCalls = listOf(ToolCallRecord("t1", "web_search", "latest Kotlin", "1 source", true)),
            proposedMemories = listOf("Uses Android Studio"),
            handledMemories = emptyList()
        )
        val merged = meta.mergeInto(existingJson, codec)
        assertEquals("latest Kotlin", merged["requestedSearchQuery"]?.jsonPrimitive?.content)
        assertTrue(merged.containsKey("search"))
        assertTrue(merged.containsKey("toolCalls"))
        assertTrue(merged.containsKey("proposedMemories"))
        assertTrue(merged.containsKey("routeNotice"))

        val cleared = MessageAssistanceMetadata(requestedSearchQuery = null, search = null)
        val afterClear = cleared.mergeInto(merged, codec)
        assertNull(afterClear["requestedSearchQuery"])
        assertNull(afterClear["search"])
        assertTrue(afterClear.containsKey("routeNotice"))
    }
}
