package com.iosbox.app

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.PersonaFeedKind
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.network.PersonaFeedError
import com.iosbox.app.core.network.PersonaFeedReader
import com.iosbox.app.core.network.SubscriptionFeedParser
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ConversationTree
import com.iosbox.app.core.storage.ModelMentionParser
import com.iosbox.app.core.storage.SlashPromptCommand
import com.iosbox.app.ui.chat.ArtifactDocumentBuilder
import com.iosbox.app.ui.chat.MathDisplayFormatter
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Phase3PowerToolsTest {

    @Test
    fun artifactDocumentBuilderLocksDownHtmlSvgAndMermaid() {
        assertTrue(ArtifactDocumentBuilder.isPreviewable("HTML"))
        assertTrue(ArtifactDocumentBuilder.isPreviewable("mermaid"))
        assertFalse(ArtifactDocumentBuilder.isPreviewable("kotlin"))
        assertTrue(ArtifactDocumentBuilder.allowsJavaScript("html"))
        assertFalse(ArtifactDocumentBuilder.allowsJavaScript("svg"))

        val dirtyHtml = "<!-- <head><script>evil()</script></head> --><!DOCTYPE html><html><body>Hi</body></html>"
        val hardened = ArtifactDocumentBuilder.htmlDocument("html", dirtyHtml)
        assertTrue(hardened.startsWith("<!doctype html><head><meta http-equiv=\"Content-Security-Policy\""))
        assertTrue(hardened.contains("connect-src 'none'"))
        assertTrue(hardened.contains("RTCPeerConnection"))
        assertFalse(hardened.contains("evil()"))

        val svgWithScript = "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script><circle r=\"10\"/></svg>"
        val svgHtml = ArtifactDocumentBuilder.htmlDocument("svg", svgWithScript)
        assertTrue(svgHtml.contains("data:image/svg+xml;base64,"))
        assertFalse(svgHtml.contains("<script>alert(1)"))

        val mermaidHtml = ArtifactDocumentBuilder.htmlDocument("mermaid", "flowchart TD\nA[Start] --> B[End]")
        assertTrue(mermaidHtml.contains("sequenceDiagram"))
        assertTrue(mermaidHtml.contains("A[Start] --&gt; B[End]"))
    }

    @Test
    fun mathDisplayFormatterConvertsLatexAndGuardsCurrency() {
        val converted = MathDisplayFormatter.formatLatexToUnicode("""\frac{\alpha + \beta}{2} \leq \sqrt{x^2 + y_i}""")
        assertTrue(converted.contains("α"))
        assertTrue(converted.contains("β"))
        assertTrue(converted.contains("≤"))
        assertTrue(converted.contains("√("))
        assertTrue(converted.contains("x²"))
        assertTrue(converted.contains("yᵢ"))

        val currency = "The total cost is $100 and $200 or maybe $5 or$10 today."
        val dollar1 = currency.indexOf('$')
        assertNull(MathDisplayFormatter.findInlineMathEnd(currency, dollar1))
        val dollar3 = currency.indexOf("$5")
        assertNull(MathDisplayFormatter.findInlineMathEnd(currency, dollar3))

        val mathLine = "Einstein wrote \$100 notes about \$E = mc^2$ yesterday."
        val firstEscaped = mathLine.indexOf('$')
        assertNull(MathDisplayFormatter.findInlineMathEnd(mathLine, firstEscaped))
        val mathStart = mathLine.indexOf("\$E")
        val mathEnd = MathDisplayFormatter.findInlineMathEnd(mathLine, mathStart)
        assertNotNull(mathEnd)
        assertEquals("E = mc^2", mathLine.substring(mathStart + 1, mathEnd!!))
    }

    @Test
    fun conversationTreeHandlesBranchingSwitchSubtreeAndArenaGroups() {
        val u1 = msg("U1", MessageRole.USER, "Original question", sortIndex = 0)
        val a1 = msg("A1", MessageRole.ASSISTANT, "Winner reply", convGroup = "G1", selected = true, sortIndex = 1)
        val b1 = msg("B1", MessageRole.ASSISTANT, "Alt reply", convGroup = "G1", selected = false, sortIndex = 2)
        val u2 = msg("U2", MessageRole.USER, "Follow up branch 1", sortIndex = 3)
        val a2 = msg("A2", MessageRole.ASSISTANT, "Answer branch 1", sortIndex = 4)

        val (linked, initialLeaf) = ConversationTree.linkHistory(listOf(u1, a1, b1, u2, a2))
        assertEquals("A2", initialLeaf)
        val linkedU2 = linked.first { it.id == "U2" }
        assertEquals("A1", linkedU2.parentMessageID)

        // User edits U2 into a parallel branch U2_B -> A2_B sharing parent A1
        val u2b = msg("U2B", MessageRole.USER, "Edited question", parentId = linkedU2.parentMessageID, sortIndex = 5)
        val a2b = msg("A2B", MessageRole.ASSISTANT, "Answer branch 2", parentId = "U2B", sortIndex = 6)
        val all = linked + u2b + a2b

        val siblings = ConversationTree.branchSiblingsMap("A2B", all)
        assertEquals(listOf("U2", "U2B"), siblings["U2"]?.map { it.id })
        assertEquals(listOf("U2", "U2B"), siblings["U2B"]?.map { it.id })

        val branch2Active = ConversationTree.activeMessages("A2B", all)
        assertEquals(listOf("U1", "A1", "B1", "U2B", "A2B"), branch2Active.map { it.id })

        val switchedLeaf = ConversationTree.resolveBranchLeaf(linkedU2, all)
        assertEquals("A2", switchedLeaf)
        val branch1Active = ConversationTree.activeMessages(switchedLeaf, all)
        assertEquals(listOf("U1", "A1", "B1", "U2", "A2"), branch1Active.map { it.id })

        val subtree = ConversationTree.descendantSubtree(linkedU2, "A2", all)
        assertEquals(listOf("U2", "A2"), subtree.map { it.id })
    }

    @Test
    fun slashCommandsAndModelMentionParserMatchAndResolveCorrectly() {
        assertEquals(10, SlashPromptCommand.builtIns.size)
        val socMatches = SlashPromptCommand.matching("/soc")
        assertEquals(listOf("/socratic"), socMatches.map { it.command })
        assertTrue(SlashPromptCommand.matching("/socratic extra").isEmpty())

        val ready = listOf(
            ResolvedModelTarget("P1", "OpenAI", APIProtocolType.OPEN_AI_COMPATIBLE, "gpt-4o", "GPT-4o", "#3F6EF6", true, false),
            ResolvedModelTarget("P2", "Anthropic", APIProtocolType.ANTHROPIC, "claude-sonnet-4", "Claude Sonnet 4", "#8A4FFF", true, true),
            ResolvedModelTarget("P3", "Gemini", APIProtocolType.GEMINI, "gemini-2.5-pro", "Gemini 2.5 Pro", "#18A058", true, true)
        )

        assertNull(ModelMentionParser.activeMentionQuery("contact user@example.com"))
        assertEquals("", ModelMentionParser.activeMentionQuery("Try asking @"))
        assertEquals("clau", ModelMentionParser.activeMentionQuery("Explain this @clau"))
        assertNull(ModelMentionParser.activeMentionQuery("Explain this @claude please"))

        val hits = ModelMentionParser.matchingTargets("clau", ready)
        assertEquals(1, hits.size)
        assertEquals("claude-sonnet-4", hits[0].modelID)
        assertEquals("Explain this", ModelMentionParser.stripTrailingMention("Explain this @clau"))
    }

    @Test
    fun subscriptionFeedParserHandlesRssAtomDiscoveryAndRejectsXXE() {
        val html = """
            <html><head>
              <link rel="alternate" type="application/atom+xml" href="/feed.xml?a=1&amp;b=2" />
            </head><body>Hello</body></html>
        """.trimIndent()
        val discovered = SubscriptionFeedParser.discover(html, "https://blog.example.com/posts/")
        assertEquals("https://blog.example.com/feed.xml?a=1&b=2", discovered)

        val atomXml = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Engineering Notes</title>
              <entry>
                <id>tag:example.com,2026:1</id>
                <title>First Post</title>
                <link rel="alternate" href="/articles/1" />
                <updated>2026-03-10T12:00:00Z</updated>
                <summary>&lt;p&gt;Hello &amp;amp; welcome&lt;/p&gt;</summary>
              </entry>
              <entry>
                <id>tag:example.com,2026:private</id>
                <title>Blocked SSRF Link</title>
                <link rel="alternate" href="http://127.0.0.1/secret" />
              </entry>
            </feed>
        """.trimIndent().toByteArray()

        val items = SubscriptionFeedParser.parse(atomXml, "https://blog.example.com/feed.xml")
        assertEquals(1, items.size)
        assertEquals("First Post", items[0].title)
        assertEquals("https://blog.example.com/articles/1", items[0].url)
        assertTrue(items[0].excerpt?.contains("Hello") == true)

        val xxeAttempt = """
            <?xml version="1.0"?>
            <!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
            <rss version="2.0"><channel><item><title>&xxe;</title><link>https://blog.example.com/x</link></item></channel></rss>
        """.trimIndent().toByteArray()
        val failed = runCatching {
            SubscriptionFeedParser.parse(xxeAttempt, "https://blog.example.com/rss.xml")
        }.exceptionOrNull()
        assertTrue(failed is PersonaFeedError.InvalidFeed)
    }

    @Test
    fun personaFeedReaderBaselinesFirstPollAndEmitsNewBlogAndXItems() = runTest {
        val homepageHtml = """<html><head><link rel="alternate" type="application/rss+xml" href="/rss.xml"></head></html>""".toByteArray()
        val rssInitial = """
            <rss version="2.0"><channel>
              <item><guid>g1</guid><title>Old Essay</title><link>https://writer.example.com/old</link></item>
            </channel></rss>
        """.trimIndent().toByteArray()
        val rssSecond = """
            <rss version="2.0"><channel>
              <item><guid>g2</guid><title>New Essay</title><link>https://writer.example.com/new</link></item>
              <item><guid>g1</guid><title>Old Essay</title><link>https://writer.example.com/old</link></item>
            </channel></rss>
        """.trimIndent().toByteArray()

        var rssPayload = rssInitial
        val blogReader = PersonaFeedReader(
            fetch = { url, _, _ ->
                when (url) {
                    "https://writer.example.com/" -> homepageHtml to "https://writer.example.com/"
                    "https://writer.example.com/rss.xml" -> rssPayload to "https://writer.example.com/rss.xml"
                    else -> error("Unexpected url: $url")
                }
            }
        )

        val feed0 = PersonaFeedReader.parseSource("https://writer.example.com/", PersonaFeedKind.BLOG)
        val batch1 = blogReader.read(feed0)
        assertTrue(batch1.items.isEmpty())
        assertEquals("https://writer.example.com/rss.xml", batch1.checkpoint.feedURL)

        rssPayload = rssSecond
        val batch2 = blogReader.read(feed0.copy(checkpoint = batch1.checkpoint))
        assertEquals(listOf("New Essay"), batch2.items.map { it.title })

        // Test X source normalization & polling
        val xFeedSource = PersonaFeedReader.parseSource("https://x.com/AdaLovelace", PersonaFeedKind.X)
        assertEquals("adalovelace", xFeedSource.address)

        var xTimelineJson = """{"data":[{"id":"100","text":"First tweet"}],"meta":{"newest_id":"100","result_count":1}}"""
        val xReader = PersonaFeedReader(
            tokenProvider = { "secret-bearer" },
            fetch = { url, _, headers ->
                assertEquals("Bearer secret-bearer", headers["Authorization"])
                if (url.contains("/2/users/by/username/")) {
                    """{"data":{"id":"42"}}""".toByteArray() to url
                } else {
                    xTimelineJson.toByteArray() to url
                }
            }
        )

        val xBatch1 = xReader.read(xFeedSource)
        assertTrue(xBatch1.items.isEmpty())
        assertEquals("100", xBatch1.checkpoint.sinceID)

        xTimelineJson = """{"data":[{"id":"102","text":"Third"},{"id":"101","text":"Second"}],"meta":{"newest_id":"102","result_count":2}}"""
        val xBatch2 = xReader.read(xFeedSource.copy(checkpoint = xBatch1.checkpoint))
        assertEquals(listOf("Second", "Third"), xBatch2.items.map { it.title })
        assertEquals("102", xBatch2.checkpoint.sinceID)
    }

    private fun msg(
        id: String,
        role: MessageRole,
        content: String,
        parentId: String? = null,
        convGroup: String? = null,
        selected: Boolean = true,
        sortIndex: Int = 0
    ): ChatMessageItem = ChatMessageItem(
        id = id,
        conversationID = "C1",
        role = role,
        content = content,
        reasoningContent = "",
        attachments = emptyList(),
        providerID = if (role == MessageRole.ASSISTANT) "P1" else null,
        providerName = if (role == MessageRole.ASSISTANT) "OpenAI" else "",
        modelID = if (role == MessageRole.ASSISTANT) "gpt-4o" else "",
        modelDisplayName = if (role == MessageRole.ASSISTANT) "GPT-4o" else "",
        accentHex = "#3F6EF6",
        comparisonGroupID = convGroup,
        isSelectedInGroup = selected,
        isStreaming = false,
        errorMessage = null,
        finishReason = null,
        promptTokens = null,
        completionTokens = null,
        cachedTokens = null,
        latencyMs = null,
        thinkingDurationMs = null,
        synthesisSourceDigest = null,
        latestRequestID = null,
        assistanceMetadata = MessageAssistanceMetadata(),
        parentMessageID = parentId,
        sortIndex = sortIndex,
        createdAtEpochMs = 1_000L + sortIndex
    )
}
