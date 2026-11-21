package com.iosbox.app.core.network

import org.junit.Assert.assertEquals
import org.junit.Test

class ThinkTagStreamParserTest {
    @Test
    fun separatesLeadingThinkBlockAcrossSingleCharSplits() {
        val parser = ThinkTagStreamParser()
        val input = "  \n<think>\nStep 1: analyze.\n</think>\n\nFinal answer <think>example</think>."
        val segments = mutableListOf<ThinkTagStreamParser.Segment>()
        for (ch in input) {
            segments.addAll(parser.feed(ch.toString()))
        }
        segments.addAll(parser.finish())

        val reasoning = segments.filterIsInstance<ThinkTagStreamParser.Segment.Reasoning>()
            .joinToString("") { it.text }
        val content = segments.filterIsInstance<ThinkTagStreamParser.Segment.Content>()
            .joinToString("") { it.text }

        assertEquals("Step 1: analyze.\n", reasoning)
        assertEquals("Final answer <think>example</think>.", content)
    }

    @Test
    fun passesThroughRegularContentMentioningThinkTag() {
        val parser = ThinkTagStreamParser()
        val segments = parser.feed("Use <think> tags carefully.") + parser.finish()
        assertEquals(
            listOf(ThinkTagStreamParser.Segment.Content("Use <think> tags carefully.")),
            segments
        )
    }

    @Test
    fun flushesUnclosedThinkOnFinish() {
        val parser = ThinkTagStreamParser()
        val segments = parser.feed("<thinking>partial reasoning") + parser.finish()
        val reasoning = segments.filterIsInstance<ThinkTagStreamParser.Segment.Reasoning>()
            .joinToString("") { it.text }
        assertEquals("partial reasoning", reasoning)
    }
}
