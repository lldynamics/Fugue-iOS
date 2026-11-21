package com.iosbox.app.ui.chat

/**
 * Lightweight pure-Kotlin LaTeX math to clean Unicode typography converter
 * and currency-safe inline `$...$` delimiter detector.
 */
object MathDisplayFormatter {
    private val GREEK_AND_SYMBOLS: Map<String, String> = mapOf(
        "\\alpha" to "α",
        "\\beta" to "β",
        "\\gamma" to "γ",
        "\\delta" to "δ",
        "\\epsilon" to "ε",
        "\\varepsilon" to "ϵ",
        "\\zeta" to "ζ",
        "\\eta" to "η",
        "\\theta" to "θ",
        "\\vartheta" to "ϑ",
        "\\iota" to "ι",
        "\\kappa" to "κ",
        "\\lambda" to "λ",
        "\\mu" to "μ",
        "\\nu" to "ν",
        "\\xi" to "ξ",
        "\\pi" to "π",
        "\\varpi" to "ϖ",
        "\\rho" to "ρ",
        "\\sigma" to "σ",
        "\\varsigma" to "ς",
        "\\tau" to "τ",
        "\\upsilon" to "υ",
        "\\phi" to "φ",
        "\\varphi" to "ϕ",
        "\\chi" to "χ",
        "\\psi" to "ψ",
        "\\omega" to "ω",
        "\\Gamma" to "Γ",
        "\\Delta" to "Δ",
        "\\Theta" to "Θ",
        "\\Lambda" to "Λ",
        "\\Xi" to "Ξ",
        "\\Pi" to "Π",
        "\\Sigma" to "Σ",
        "\\Upsilon" to "Υ",
        "\\Phi" to "Φ",
        "\\Psi" to "Ψ",
        "\\Omega" to "Ω",
        "\\times" to "×",
        "\\cdot" to "·",
        "\\div" to "÷",
        "\\pm" to "±",
        "\\mp" to "∓",
        "\\leq" to "≤",
        "\\le" to "≤",
        "\\geq" to "≥",
        "\\ge" to "≥",
        "\\neq" to "≠",
        "\\ne" to "≠",
        "\\approx" to "≈",
        "\\equiv" to "≡",
        "\\sim" to "∼",
        "\\simeq" to "≃",
        "\\cong" to "≅",
        "\\propto" to "∝",
        "\\infty" to "∞",
        "\\partial" to "∂",
        "\\nabla" to "∇",
        "\\sum" to "∑",
        "\\prod" to "∏",
        "\\int" to "∫",
        "\\oint" to "∮",
        "\\forall" to "∀",
        "\\exists" to "∃",
        "\\nexists" to "∄",
        "\\notin" to "∉",
        "\\in" to "∈",
        "\\ni" to "∋",
        "\\subseteq" to "⊆",
        "\\supseteq" to "⊇",
        "\\subset" to "⊂",
        "\\supset" to "⊃",
        "\\cup" to "∪",
        "\\cap" to "∩",
        "\\setminus" to "∖",
        "\\emptyset" to "∅",
        "\\varnothing" to "∅",
        "\\rightarrow" to "→",
        "\\to" to "→",
        "\\leftarrow" to "←",
        "\\leftrightarrow" to "↔",
        "\\Rightarrow" to "⇒",
        "\\implies" to "⇒",
        "\\Leftarrow" to "⇐",
        "\\Leftrightarrow" to "⇔",
        "\\iff" to "⇔",
        "\\mapsto" to "↦",
        "\\ldots" to "…",
        "\\cdots" to "⋯",
        "\\vdots" to "⋮",
        "\\ddots" to "⋱",
        "\\dots" to "…",
        "\\neg" to "¬",
        "\\land" to "∧",
        "\\lor" to "∨",
        "\\oplus" to "⊕",
        "\\otimes" to "⊗",
        "\\perp" to "⊥",
        "\\angle" to "∠",
        "\\degree" to "°",
        "\\circ" to "∘",
        "\\prime" to "′",
        "\\langle" to "⟨",
        "\\rangle" to "⟩",
        "\\lceil" to "⌈",
        "\\rceil" to "⌉",
        "\\lfloor" to "⌊",
        "\\rfloor" to "⌋",
        "\\{" to "{",
        "\\}" to "}"
    )

    private val SORTED_COMMANDS: List<Map.Entry<String, String>> =
        GREEK_AND_SYMBOLS.entries.sortedByDescending { it.key.length }

    private val SUPERSCRIPTS: Map<Char, Char> = mapOf(
        '0' to '⁰', '1' to '¹', '2' to '²', '3' to '³', '4' to '⁴',
        '5' to '⁵', '6' to '⁶', '7' to '⁷', '8' to '⁸', '9' to '⁹',
        '+' to '⁺', '-' to '⁻', '=' to '⁼', '(' to '⁽', ')' to '⁾',
        'n' to 'ⁿ', 'i' to 'ⁱ'
    )

    private val SUBSCRIPTS: Map<Char, Char> = mapOf(
        '0' to '₀', '1' to '₁', '2' to '₂', '3' to '₃', '4' to '₄',
        '5' to '₅', '6' to '₆', '7' to '₇', '8' to '₈', '9' to '₉',
        '+' to '₊', '-' to '₋', '=' to '₌', '(' to '₍', ')' to '₎',
        'a' to 'ₐ', 'e' to 'ₑ', 'h' to 'ₕ', 'i' to 'ᵢ', 'j' to 'ⱼ',
        'k' to 'ₖ', 'l' to 'ₗ', 'm' to 'ₘ', 'n' to 'ₙ', 'o' to 'ₒ',
        'p' to 'ₚ', 'r' to 'ᵣ', 's' to 'ₛ', 't' to 'ₜ', 'u' to 'ᵤ',
        'v' to 'ᵥ', 'x' to 'ₓ'
    )

    fun formatLatexToUnicode(latex: String): String {
        var result = latex.trim()
            .replace("\\\\", "\n")
            .replace("\\,", " ")
            .replace("\\;", " ")
            .replace("\\:", " ")
            .replace("\\!", "")
            .replace("\\quad", "  ")
            .replace("\\qquad", "    ")
            .replace(Regex("\\\\(left|right)\\s*"), "")

        result = expandWrapperCommands(result)
        result = expandFractions(result)
        result = expandSqrts(result)

        for ((cmd, sym) in SORTED_COMMANDS) {
            result = replaceCommandToken(result, cmd, sym)
        }

        result = applyScripts(result, '^', SUPERSCRIPTS)
        result = applyScripts(result, '_', SUBSCRIPTS)
        return result.replace(Regex("[\\t ]+"), " ").trim()
    }

    /**
     * Given `text[startIndex] == '$'`, returns the index of the matching closing `$`,
     * or `null` when this looks like currency (e.g., `$100 and $200`) or unclosed `$`.
     */
    fun findInlineMathEnd(text: String, startIndex: Int): Int? {
        if (startIndex < 0 || startIndex + 1 >= text.length || text[startIndex] != '$') return null
        if (isEscaped(text, startIndex)) return null
        if (text[startIndex + 1] == '$' || text[startIndex + 1].isWhitespace()) return null

        var i = startIndex + 1
        while (i < text.length) {
            val ch = text[i]
            if (ch == '\n' || ch == '\r') return null
            if (ch == '$' && !isEscaped(text, i)) {
                if (i + 1 < text.length && text[i + 1] == '$') return null
                if (i > startIndex + 1 && !text[i - 1].isWhitespace()) {
                    val body = text.substring(startIndex + 1, i)
                    if (isLikelyCurrency(body)) return null
                    return i
                }
                return null
            }
            i++
        }
        return null
    }

    private fun isEscaped(text: String, index: Int): Boolean {
        var backslashes = 0
        var idx = index - 1
        while (idx >= 0 && text[idx] == '\\') {
            backslashes++
            idx--
        }
        return backslashes % 2 == 1
    }

    private fun isLikelyCurrency(body: String): Boolean {
        val trimmed = body.trim()
        if (trimmed.isEmpty()) return true
        if (trimmed.all { it.isDigit() || it == ',' || it == '.' }) return true
        if (trimmed[0].isDigit() &&
            trimmed.any { it.isWhitespace() } &&
            !trimmed.contains('\\') &&
            !trimmed.any { it in "=^_+-*/<>±×÷≈≤≥" }
        ) {
            return true
        }
        return false
    }

    private fun expandWrapperCommands(input: String): String {
        val wrappers = listOf("\\text", "\\mathrm", "\\mathbf", "\\mathit", "\\mathsf", "\\operatorname")
        var text = input
        var changed = true
        while (changed) {
            changed = false
            for (cmd in wrappers) {
                val idx = findCommand(text, cmd)
                if (idx >= 0) {
                    val openBrace = skipSpaces(text, idx + cmd.length)
                    val innerRange = if (openBrace < text.length && text[openBrace] == '{') {
                        extractBraceGroup(text, openBrace)
                    } else null
                    if (innerRange != null) {
                        val (inner, closeIdx) = innerRange
                        text = text.substring(0, idx) + inner + text.substring(closeIdx + 1)
                        changed = true
                        break
                    }
                }
            }
        }
        return text
    }

    private fun expandFractions(input: String): String {
        var text = input
        while (true) {
            val idx = findCommand(text, "\\frac").takeIf { it >= 0 }
                ?: findCommand(text, "\\dfrac").takeIf { it >= 0 }
                ?: findCommand(text, "\\tfrac")
            if (idx < 0) break
            val cmdLen = if (text.startsWith("\\dfrac", idx) || text.startsWith("\\tfrac", idx)) 6 else 5
            val numStart = skipSpaces(text, idx + cmdLen)
            val numGroup = if (numStart < text.length && text[numStart] == '{') {
                extractBraceGroup(text, numStart)
            } else if (numStart < text.length) {
                text[numStart].toString() to numStart
            } else null

            if (numGroup == null) break
            val denStart = skipSpaces(text, numGroup.second + 1)
            val denGroup = if (denStart < text.length && text[denStart] == '{') {
                extractBraceGroup(text, denStart)
            } else if (denStart < text.length) {
                text[denStart].toString() to denStart
            } else null

            if (denGroup == null) break
            val numFmt = formatFracPart(formatLatexToUnicode(numGroup.first))
            val denFmt = formatFracPart(formatLatexToUnicode(denGroup.first))
            text = text.substring(0, idx) + "$numFmt/$denFmt" + text.substring(denGroup.second + 1)
        }
        return text
    }

    private fun formatFracPart(part: String): String {
        val clean = part.trim()
        val isSimple = clean.isNotEmpty() && clean.all { it.isLetterOrDigit() || it in "αβγδεζηθικλμνξπρστυφχψωΓΔΘΛΞΠΣΥΦΨΩ" }
        return if (isSimple && clean.length <= 4) clean else "($clean)"
    }

    private fun expandSqrts(input: String): String {
        var text = input
        while (true) {
            val idx = findCommand(text, "\\sqrt")
            if (idx < 0) break
            var cursor = skipSpaces(text, idx + 5)
            var rootPrefix = "√"
            if (cursor < text.length && text[cursor] == '[') {
                val closeBracket = text.indexOf(']', cursor + 1)
                if (closeBracket > cursor) {
                    val deg = text.substring(cursor + 1, closeBracket).trim()
                    rootPrefix = when (deg) {
                        "3" -> "∛"
                        "4" -> "∜"
                        else -> "${toUnicodeScript(deg, SUPERSCRIPTS) ?: deg}√"
                    }
                    cursor = skipSpaces(text, closeBracket + 1)
                }
            }
            val group = if (cursor < text.length && text[cursor] == '{') {
                extractBraceGroup(text, cursor)
            } else if (cursor < text.length) {
                text[cursor].toString() to cursor
            } else null

            if (group == null) break
            val inner = group.first.trim()
            val formatted = if (inner.length <= 1 || inner.all { it.isLetterOrDigit() }) {
                "$rootPrefix$inner"
            } else {
                "$rootPrefix($inner)"
            }
            text = text.substring(0, idx) + formatted + text.substring(group.second + 1)
        }
        return text
    }

    private fun applyScripts(input: String, marker: Char, table: Map<Char, Char>): String {
        val sb = StringBuilder(input.length)
        var i = 0
        while (i < input.length) {
            val ch = input[i]
            if (ch == marker && i + 1 < input.length && !isEscaped(input, i)) {
                if (input[i + 1] == '{') {
                    val group = extractBraceGroup(input, i + 1)
                    if (group != null) {
                        val content = group.first.trim()
                        val mapped = toUnicodeScript(content, table)
                        if (mapped != null) {
                            sb.append(mapped)
                        } else {
                            sb.append(marker).append('(').append(content).append(')')
                        }
                        i = group.second + 1
                        continue
                    }
                } else {
                    val single = input[i + 1]
                    val mapped = table[single]
                    if (mapped != null) {
                        sb.append(mapped)
                        i += 2
                        continue
                    }
                }
            }
            sb.append(ch)
            i++
        }
        return sb.toString()
    }

    private fun toUnicodeScript(content: String, table: Map<Char, Char>): String? {
        if (content.isEmpty()) return null
        val out = StringBuilder(content.length)
        for (c in content) {
            if (c == ' ') continue
            val mapped = table[c] ?: return null
            out.append(mapped)
        }
        return out.toString()
    }

    private fun findCommand(text: String, cmd: String): Int {
        var idx = text.indexOf(cmd)
        while (idx >= 0) {
            val after = idx + cmd.length
            if (after >= text.length || !text[after].isLetter()) {
                return idx
            }
            idx = text.indexOf(cmd, idx + 1)
        }
        return -1
    }

    private fun replaceCommandToken(text: String, cmd: String, replacement: String): String {
        val isAlphaCmd = cmd.length > 1 && cmd[1].isLetter()
        if (!isAlphaCmd) return text.replace(cmd, replacement)
        val sb = StringBuilder(text.length)
        var i = 0
        while (i < text.length) {
            if (text.startsWith(cmd, i)) {
                val after = i + cmd.length
                val boundaryOk = after >= text.length || !text[after].isLetter()
                if (boundaryOk) {
                    sb.append(replacement)
                    i = if (after < text.length && text[after] == ' ' &&
                        after + 1 < text.length && !text[after + 1].isLetterOrDigit()
                    ) {
                        after + 1
                    } else {
                        after
                    }
                    continue
                }
            }
            sb.append(text[i])
            i++
        }
        return sb.toString()
    }

    private fun skipSpaces(text: String, start: Int): Int {
        var i = start
        while (i < text.length && text[i] == ' ') i++
        return i
    }

    private fun extractBraceGroup(text: String, openBraceIdx: Int): Pair<String, Int>? {
        if (openBraceIdx >= text.length || text[openBraceIdx] != '{') return null
        var depth = 0
        var i = openBraceIdx
        while (i < text.length) {
            val ch = text[i]
            if (ch == '{' && !isEscaped(text, i)) {
                depth++
            } else if (ch == '}' && !isEscaped(text, i)) {
                depth--
                if (depth == 0) {
                    return text.substring(openBraceIdx + 1, i) to i
                }
            }
            i++
        }
        return null
    }
}
