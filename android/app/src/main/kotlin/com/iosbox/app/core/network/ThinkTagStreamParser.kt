package com.iosbox.app.core.network

/**
 * Incrementally separates a leading `<think>...</think>` (or `<thinking>...</thinking>`) block
 * from regular assistant content across arbitrary SSE token boundaries.
 */
class ThinkTagStreamParser {
    sealed interface Segment {
        data class Reasoning(val text: String) : Segment
        data class Content(val text: String) : Segment
    }

    private enum class Phase {
        DETECTING,
        INSIDE_THINK,
        AFTER_THINK,
        PASSTHROUGH
    }

    private var phase: Phase = Phase.DETECTING
    private val buffer = StringBuilder()
    private var activeCloseTag: String = "</think>"
    private var dropLeadingNewlineInThink: Boolean = false

    fun feed(chunk: String): List<Segment> {
        if (chunk.isEmpty()) return emptyList()
        return when (phase) {
            Phase.PASSTHROUGH -> listOf(Segment.Content(chunk))
            Phase.AFTER_THINK -> consumeAfterThink(chunk)
            Phase.INSIDE_THINK -> consumeInsideThink(chunk)
            Phase.DETECTING -> consumeDetecting(chunk)
        }
    }

    fun finish(): List<Segment> {
        if (buffer.isEmpty()) return emptyList()
        val leftover = buffer.toString()
        buffer.setLength(0)
        return when (phase) {
            Phase.INSIDE_THINK -> listOf(Segment.Reasoning(leftover))
            Phase.DETECTING -> listOf(Segment.Content(leftover))
            Phase.AFTER_THINK, Phase.PASSTHROUGH -> emptyList()
        }
    }

    private fun consumeDetecting(chunk: String): List<Segment> {
        buffer.append(chunk)
        val raw = buffer.toString()
        val leading = raw.dropWhile { it.isWhitespace() }
        if (leading.isEmpty()) {
            return emptyList()
        }

        for ((open, close) in TAG_PAIRS) {
            if (leading.startsWith(open)) {
                val rest = leading.drop(open.length)
                buffer.setLength(0)
                activeCloseTag = close
                phase = Phase.INSIDE_THINK
                dropLeadingNewlineInThink = true
                return if (rest.isEmpty()) emptyList() else consumeInsideThink(rest)
            }
        }

        if (TAG_PAIRS.any { (open, _) -> open.startsWith(leading) }) {
            return emptyList()
        }

        phase = Phase.PASSTHROUGH
        buffer.setLength(0)
        return listOf(Segment.Content(raw))
    }

    private fun consumeInsideThink(chunk: String): List<Segment> {
        var incoming = chunk
        if (dropLeadingNewlineInThink && incoming.isNotEmpty()) {
            dropLeadingNewlineInThink = false
            incoming = when {
                incoming.startsWith("\r\n") -> incoming.drop(2)
                incoming.startsWith("\n") -> incoming.drop(1)
                else -> incoming
            }
            if (incoming.isEmpty()) return emptyList()
        }
        buffer.append(incoming)
        val current = buffer.toString()
        val closeIdx = current.indexOf(activeCloseTag)
        if (closeIdx >= 0) {
            val outputs = mutableListOf<Segment>()
            val thought = current.substring(0, closeIdx)
            if (thought.isNotEmpty()) {
                outputs.add(Segment.Reasoning(thought))
            }
            val rest = current.substring(closeIdx + activeCloseTag.length)
            buffer.setLength(0)
            phase = Phase.AFTER_THINK
            if (rest.isNotEmpty()) {
                outputs.addAll(consumeAfterThink(rest))
            }
            return outputs
        }

        val partialStart = trailingPartialMatchStart(current, activeCloseTag)
        if (partialStart != null) {
            val safePart = current.substring(0, partialStart)
            val tail = current.substring(partialStart)
            buffer.setLength(0)
            buffer.append(tail)
            return if (safePart.isEmpty()) emptyList() else listOf(Segment.Reasoning(safePart))
        }

        buffer.setLength(0)
        return listOf(Segment.Reasoning(current))
    }

    private fun consumeAfterThink(chunk: String): List<Segment> {
        val trimmed = chunk.dropWhile { it == '\n' || it == '\r' }
        if (trimmed.isEmpty()) return emptyList()
        phase = Phase.PASSTHROUGH
        return listOf(Segment.Content(trimmed))
    }

    private fun trailingPartialMatchStart(text: String, target: String): Int? {
        val maxPrefixLen = minOf(text.length, target.length - 1)
        if (maxPrefixLen < 1) return null
        for (len in maxPrefixLen downTo 1) {
            val start = text.length - len
            if (target.startsWith(text.substring(start))) {
                return start
            }
        }
        return null
    }

    companion object {
        private val TAG_PAIRS = listOf(
            "<think>" to "</think>",
            "<thinking>" to "</thinking>"
        )
    }
}
