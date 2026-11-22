package com.iosbox.app.core.system

/**
 * Converts Markdown-formatted assistant responses into clean, paste-friendly plain text
 * suitable for messaging apps (WeChat, Feishu, DingTalk), emails, and notes.
 */
object PlainTextFormatter {
    private val headingRegex = Regex("""^\s{0,3}#{1,6}\s+(.*)$""")
    private val blockquotePrefixRegex = Regex("""^\s{0,3}>\s?""")
    private val dividerLineRegex = Regex("""^\s{0,3}(?:[-*_]\s*){3,}$""")
    private val tableDividerRegex = Regex("""^\|?\s*:?-{2,}:?(?:\s*\|\s*:?-{2,}:?)*\s*\|?$""")
    private val unorderedListRegex = Regex("""^(\s*)[-*+]\s+(.*)$""")
    private val orderedListRegex = Regex("""^(\s*)(\d+\.)\s+(.*)$""")
    private val imageRegex = Regex("""!\[([^\]]*)]\([^)]*\)""")
    private val linkRegex = Regex("""\[([^\]]+)]\(([^)\s]+)\)""")
    private val autoLinkRegex = Regex("""<(https?://[^>]+)>""")
    private val boldDoubleStarRegex = Regex("""\*\*([^\n*]+?)\*\*""")
    private val boldDoubleUnderscoreRegex = Regex("""__([^\n_]+?)__""")
    private val strikeRegex = Regex("""~~([^\n~]+?)~~""")
    private val inlineCodeRegex = Regex("""`([^`\n]+?)`""")
    private val italicStarRegex = Regex("""(?<!\*)\*([^\s*](?:[^*\n]*?[^\s*])?)\*(?!\*)""")
    private val italicWordSafeUnderscoreRegex = Regex("""(?<![\p{L}\p{N}_])_([^\s_](?:[^_\n]*?[^\s_])?)_(?![\p{L}\p{N}_])""")
    private val inlineMathRegex = Regex("""(?<!\w)\$([^\s$](?:[^$\n]*?[^\s$])?)\$(?!\d)""")
    private val cjkCharRegex = Regex("""[\p{IsHan}\p{IsHiragana}\p{IsKatakana}]""")
    private val multiBlankLineRegex = Regex("""\n{3,}""")

    fun toPlainText(markdown: String): String {
        if (markdown.isBlank()) return ""
        val normalized = markdown.replace("\r\n", "\n").replace('\r', '\n')
        val outLines = ArrayList<String>()
        var inCodeFence = false
        var fenceToken = ""

        for (rawLine in normalized.split('\n')) {
            val trimmed = rawLine.trim()
            val fenceCandidate = when {
                trimmed.startsWith("```") -> "```"
                trimmed.startsWith("~~~") -> "~~~"
                else -> null
            }
            if (fenceCandidate != null) {
                if (!inCodeFence) {
                    inCodeFence = true
                    fenceToken = fenceCandidate
                    continue
                } else if (fenceCandidate == fenceToken) {
                    inCodeFence = false
                    fenceToken = ""
                    continue
                }
            }

            if (inCodeFence) {
                outLines.add(rawLine)
                continue
            }

            outLines.add(formatMarkdownLine(rawLine) ?: continue)
        }

        return outLines.joinToString("\n")
            .replace(multiBlankLineRegex, "\n\n")
            .trim()
    }

    private fun formatMarkdownLine(rawLine: String): String? {
        var line = rawLine
        while (blockquotePrefixRegex.containsMatchIn(line)) {
            line = blockquotePrefixRegex.replaceFirst(line, "")
        }

        val trimmed = line.trim()
        if (trimmed.isEmpty()) return ""

        if (dividerLineRegex.matches(trimmed)) {
            return ""
        }

        if (trimmed.contains('|') && (trimmed.startsWith('|') || trimmed.endsWith('|') || tableDividerRegex.matches(trimmed))) {
            if (tableDividerRegex.matches(trimmed)) {
                return null
            }
            val rawCells = trimmed.trim('|').split('|').map { cleanInline(it.trim()) }
            val nonEmpty = rawCells.filter { it.isNotEmpty() }
            if (nonEmpty.isEmpty()) return null
            if (nonEmpty.size == 2) {
                val sep = if (cjkCharRegex.containsMatchIn(trimmed)) "：" else ": "
                return "${nonEmpty[0]}$sep${nonEmpty[1]}"
            }
            return nonEmpty.joinToString(" | ")
        }

        headingRegex.matchEntire(trimmed)?.let { match ->
            return cleanInline(match.groupValues[1].trim())
        }

        unorderedListRegex.matchEntire(line)?.let { match ->
            val indent = match.groupValues[1]
            val body = cleanInline(match.groupValues[2].trim())
            return "$indent• $body"
        }

        orderedListRegex.matchEntire(line)?.let { match ->
            val indent = match.groupValues[1]
            val num = match.groupValues[2]
            val body = cleanInline(match.groupValues[3].trim())
            return "$indent$num $body"
        }

        return cleanInline(line)
    }

    private fun cleanInline(raw: String): String {
        if (raw.isEmpty()) return ""
        var text = imageRegex.replace(raw) { it.groupValues[1] }
        text = linkRegex.replace(text) { match ->
            val label = match.groupValues[1].trim()
            val url = match.groupValues[2].trim()
            if (label.isEmpty() || label == url) url else "$label ($url)"
        }
        text = autoLinkRegex.replace(text) { it.groupValues[1] }
        text = text
            .replace("$$", "")
            .replace("\\[", "")
            .replace("\\]", "")
            .replace("\\(", "")
            .replace("\\)", "")
        text = inlineMathRegex.replace(text) { it.groupValues[1] }
        text = inlineCodeRegex.replace(text) { it.groupValues[1] }
        text = boldDoubleStarRegex.replace(text) { it.groupValues[1] }
        text = boldDoubleUnderscoreRegex.replace(text) { it.groupValues[1] }
        text = strikeRegex.replace(text) { it.groupValues[1] }
        text = italicStarRegex.replace(text) { it.groupValues[1] }
        text = italicWordSafeUnderscoreRegex.replace(text) { it.groupValues[1] }
        return text
    }
}
