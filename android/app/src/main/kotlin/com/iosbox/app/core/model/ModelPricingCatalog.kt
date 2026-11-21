package com.iosbox.app.core.model

object ModelPricingCatalog {
    data class Preset(
        val id: String,
        val label: String,
        val matchPrefixes: List<String>,
        val currency: String,
        val inputPerMillion: Double,
        val outputPerMillion: Double,
        val cacheReadPerMillion: Double? = null,
        val cacheWritePerMillion: Double? = null
    )

    val presets: List<Preset> = listOf(
        Preset("gpt-4.1", "OpenAI GPT-4.1 ($2 / $8)", listOf("gpt-4.1"), "USD", 2.0, 8.0, 0.5, null),
        Preset("gpt-4.1-mini", "OpenAI GPT-4.1 mini ($0.4 / $1.6)", listOf("gpt-4.1-mini"), "USD", 0.4, 1.6, 0.1, null),
        Preset("gpt-4.1-nano", "OpenAI GPT-4.1 nano ($0.1 / $0.4)", listOf("gpt-4.1-nano"), "USD", 0.1, 0.4, 0.025, null),
        Preset("gpt-4o-mini", "OpenAI GPT-4o mini ($0.15 / $0.6)", listOf("gpt-4o-mini"), "USD", 0.15, 0.60, 0.075, null),
        Preset("gpt-4o", "OpenAI GPT-4o ($2.5 / $10)", listOf("gpt-4o", "chatgpt-4o"), "USD", 2.5, 10.0, 1.25, null),
        Preset("o4-mini", "OpenAI o4-mini / o3-mini ($1.1 / $4.4)", listOf("o4-mini", "o3-mini"), "USD", 1.1, 4.4, 0.275, null),
        Preset("o3", "OpenAI o3 ($2 / $8)", listOf("o3"), "USD", 2.0, 8.0, 0.5, null),
        Preset("claude-sonnet-4", "Claude Sonnet 4 / 4.5 / 3.7 ($3 / $15)", listOf("claude-sonnet-4", "claude-3-7-sonnet", "claude-3-5-sonnet"), "USD", 3.0, 15.0, 0.30, 3.75),
        Preset("claude-opus-4", "Claude Opus 4 ($15 / $75)", listOf("claude-opus-4"), "USD", 15.0, 75.0, 1.50, 18.75),
        Preset("claude-haiku", "Claude Haiku 3.5 / 4 ($0.8 / $4)", listOf("claude-3-5-haiku", "claude-haiku-4"), "USD", 0.80, 4.0, 0.08, 1.0),
        Preset("deepseek-reasoner", "DeepSeek-R1 (CNY ¥4 / ¥16)", listOf("deepseek-reasoner", "deepseek-r1"), "CNY", 4.0, 16.0, 1.0, null),
        Preset("deepseek-chat", "DeepSeek-V3 (CNY ¥2 / ¥8)", listOf("deepseek-chat", "deepseek-v3"), "CNY", 2.0, 8.0, 0.5, null),
        Preset("gemini-2.5-pro", "Gemini 2.5 Pro ($1.25 / $10)", listOf("gemini-2.5-pro", "gemini-3-pro"), "USD", 1.25, 10.0, 0.31, null),
        Preset("gemini-2.5-flash", "Gemini 2.5 Flash ($0.3 / $2.5)", listOf("gemini-2.5-flash", "gemini-2.0-flash", "gemini-3-flash"), "USD", 0.30, 2.50, 0.075, null)
    )

    fun match(modelID: String): Preset? {
        val lower = modelID.lowercase()
        var best: Pair<Preset, Int>? = null
        for (preset in presets) {
            if (preset.id == "o3" && lower.contains("o3-pro")) continue
            for (token in preset.matchPrefixes) {
                if (containsToken(token, lower) && (best == null || token.length > best.second)) {
                    best = preset to token.length
                }
            }
        }
        return best?.first
    }

    private fun isAsciiAlnum(ch: Char): Boolean = ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9'

    private fun containsToken(token: String, text: String): Boolean {
        var idx = text.indexOf(token)
        while (idx >= 0) {
            val validStart = idx == 0 || !isAsciiAlnum(text[idx - 1])
            val endIdx = idx + token.length
            val validEnd = endIdx == text.length || !isAsciiAlnum(text[endIdx])
            if (validStart && validEnd) return true
            idx = text.indexOf(token, idx + 1)
        }
        return false
    }

    fun apply(preset: Preset, spec: ModelSpec): ModelSpec = spec.copy(
        inputPricePerMillion = preset.inputPerMillion,
        outputPricePerMillion = preset.outputPerMillion,
        cacheReadPricePerMillion = preset.cacheReadPerMillion,
        cacheWritePricePerMillion = preset.cacheWritePerMillion,
        priceCurrency = preset.currency
    )
}
