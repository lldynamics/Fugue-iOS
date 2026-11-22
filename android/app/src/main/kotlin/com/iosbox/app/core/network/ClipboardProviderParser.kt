package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.ProviderTemplate
import java.net.URI

data class ClipboardProviderCandidate(
    val apiKey: String,
    val baseURL: String,
    val protocolType: APIProtocolType,
    val providerName: String,
    val templateID: String,
    val accentHex: String,
    val iconSymbol: String,
    val confidenceNote: String,
    val suggestedModels: List<ModelSpec>,
    val isGenericOpenAIKey: Boolean
)

object ClipboardProviderParser {
    const val MAX_INPUT_CHARS = 8192

    private val URL_REGEX = Regex("""https?://[^\s"'<>)\],;]+""", RegexOption.IGNORE_CASE)
    private val ANTHROPIC_KEY_REGEX = Regex("""\bsk-ant-[A-Za-z0-9_\-]{12,}""")
    private val GEMINI_KEY_REGEX = Regex("""\bAIza[0-9A-Za-z_\-]{20,}""")
    private val OPENROUTER_KEY_REGEX = Regex("""\bsk-or-v1-[A-Za-z0-9]{16,}""")
    private val GROQ_KEY_REGEX = Regex("""\bgsk_[A-Za-z0-9]{16,}""")
    private val OPENAI_PROJECT_KEY_REGEX = Regex("""\bsk-(?:proj|svcacct|live|test)-[A-Za-z0-9_\-]{16,}""")
    private val GENERIC_SK_KEY_REGEX = Regex("""\bsk-[A-Za-z0-9_\-]{16,}""")
    private val LABELED_KEY_REGEX = Regex(
        """(?:api[_\-\s]?key|access[_\-\s]?token|token)\s*[:=]\s*["']?([A-Za-z0-9._\-]{16,})["']?""",
        RegexOption.IGNORE_CASE
    )
    private val BEARER_KEY_REGEX = Regex("""Bearer\s+([A-Za-z0-9._\-]{16,})""", RegexOption.IGNORE_CASE)

    private val NON_CHAT_FRAGMENTS = listOf(
        "whisper", "tts", "dall-e", "embedding", "moderation",
        "sora", "realtime", "transcribe", "gpt-image"
    )

    private val PREFERRED_MODEL_PATTERNS = listOf(
        "gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1", "gpt-4o", "gpt-6",
        "deepseek-chat", "deepseek-flash", "deepseek-v4",
        "claude-sonnet", "claude-haiku",
        "gemini-2.5-flash", "gemini-3", "gemini-4",
        "llama-3.3-70b", "qwen", "openrouter/auto"
    )

    fun parse(rawInput: String): ClipboardProviderCandidate? {
        val text = rawInput.take(MAX_INPUT_CHARS).trim()
        if (text.isEmpty()) return null

        val rawURLs = URL_REGEX.findAll(text)
            .map { it.value.trimEnd('.', ',', ';', ':') }
            .distinct()
            .toList()

        val hasExplicitPublicHttp = rawURLs.any { NetworkLocation.isPlainHTTPToPublicHost(it) }
        val safeURLs = rawURLs.filter { url ->
            val scheme = runCatching { URI(url.trimEnd('#')).scheme?.lowercase() }.getOrNull()
            (scheme == "https" || scheme == "http") &&
                !NetworkLocation.isPlainHTTPToPublicHost(url) &&
                !url.contains("api.example.com", ignoreCase = true)
        }
        if (hasExplicitPublicHttp && safeURLs.isEmpty()) {
            return null
        }

        val detectedKey = detectKey(text)
        val extractedURL = safeURLs.firstOrNull()

        if (detectedKey == null && extractedURL == null) {
            return null
        }

        if (detectedKey != null && detectedKey.type != KeyOrigin.GENERIC_SK && detectedKey.type != KeyOrigin.LABELED) {
            return buildKnownKeyCandidate(detectedKey, extractedURL)
        }

        if (extractedURL != null) {
            return buildUrlMatchedCandidate(
                url = extractedURL,
                apiKey = detectedKey?.value.orEmpty()
            )
        }

        val genericKey = detectedKey?.value ?: return null
        val openaiTpl = ProviderTemplate.catalog.firstOrNull { it.id == "openai" }
        return ClipboardProviderCandidate(
            apiKey = genericKey,
            baseURL = openaiTpl?.baseURL ?: "https://api.openai.com/v1",
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            providerName = "OpenAI / 兼容服务",
            templateID = "openai",
            accentHex = openaiTpl?.accentHex ?: "#10A37F",
            iconSymbol = openaiTpl?.iconSymbol ?: "circle.hexagongrid.fill",
            confidenceNote = L10n.text(
                "识别到通用 sk- 密钥，请在下方确认实际服务商或中转站地址。",
                "Detected generic sk- key. Confirm the actual provider or gateway URL below."
            ),
            suggestedModels = openaiTpl?.suggestedModels.orEmpty(),
            isGenericOpenAIKey = true
        )
    }

    fun pickBestStarterModel(
        models: List<ModelSpec>,
        protocolType: APIProtocolType
    ): ModelSpec? {
        val eligible = models.filter { spec ->
            val lower = spec.id.lowercase()
            NON_CHAT_FRAGMENTS.none { lower.contains(it) }
        }
        val pool = eligible.ifEmpty { models }
        for (pattern in PREFERRED_MODEL_PATTERNS) {
            pool.firstOrNull { it.id.lowercase().contains(pattern) }?.let { return it }
        }
        if (protocolType == APIProtocolType.ANTHROPIC) {
            pool.firstOrNull { it.id.lowercase().contains("claude") }?.let { return it }
        }
        if (protocolType == APIProtocolType.GEMINI) {
            pool.firstOrNull { it.id.lowercase().contains("gemini") }?.let { return it }
        }
        return pool.firstOrNull()
    }

    private enum class KeyOrigin {
        ANTHROPIC,
        GEMINI,
        OPENROUTER,
        GROQ,
        OPENAI_PREFIXED,
        GENERIC_SK,
        LABELED
    }

    private data class DetectedKey(val value: String, val type: KeyOrigin)

    private fun detectKey(text: String): DetectedKey? {
        ANTHROPIC_KEY_REGEX.find(text)?.value?.let { return DetectedKey(it, KeyOrigin.ANTHROPIC) }
        GEMINI_KEY_REGEX.find(text)?.value?.let { return DetectedKey(it, KeyOrigin.GEMINI) }
        OPENROUTER_KEY_REGEX.find(text)?.value?.let { return DetectedKey(it, KeyOrigin.OPENROUTER) }
        GROQ_KEY_REGEX.find(text)?.value?.let { return DetectedKey(it, KeyOrigin.GROQ) }
        OPENAI_PROJECT_KEY_REGEX.find(text)?.value?.let { return DetectedKey(it, KeyOrigin.OPENAI_PREFIXED) }
        GENERIC_SK_KEY_REGEX.find(text)?.value?.let { return DetectedKey(it, KeyOrigin.GENERIC_SK) }
        LABELED_KEY_REGEX.find(text)?.groupValues?.getOrNull(1)?.trim()?.takeIf { it.isNotEmpty() }?.let {
            return DetectedKey(it, KeyOrigin.LABELED)
        }
        BEARER_KEY_REGEX.find(text)?.groupValues?.getOrNull(1)?.trim()?.takeIf { it.isNotEmpty() }?.let {
            return DetectedKey(it, KeyOrigin.LABELED)
        }
        return null
    }

    private fun buildKnownKeyCandidate(key: DetectedKey, extractedURL: String?): ClipboardProviderCandidate {
        return when (key.type) {
            KeyOrigin.ANTHROPIC -> {
                val tpl = ProviderTemplate.catalog.firstOrNull { it.id == "anthropic" }
                val useURL = extractedURL ?: (tpl?.baseURL ?: "https://api.anthropic.com/v1")
                val isRelay = extractedURL != null && !useURL.contains("anthropic.com", ignoreCase = true)
                ClipboardProviderCandidate(
                    apiKey = key.value,
                    baseURL = useURL,
                    protocolType = if (isRelay) APIProtocolType.OPEN_AI_COMPATIBLE else APIProtocolType.ANTHROPIC,
                    providerName = if (isRelay) hostDisplayName(useURL, "Claude Relay") else (tpl?.name ?: "Anthropic Claude"),
                    templateID = "anthropic",
                    accentHex = tpl?.accentHex ?: "#D97757",
                    iconSymbol = tpl?.iconSymbol ?: "sparkles",
                    confidenceNote = L10n.text("已识别 Anthropic Key (sk-ant-...)", "Recognized Anthropic key (sk-ant-...)"),
                    suggestedModels = tpl?.suggestedModels.orEmpty(),
                    isGenericOpenAIKey = false
                )
            }
            KeyOrigin.GEMINI -> {
                val tpl = ProviderTemplate.catalog.firstOrNull { it.id == "gemini" }
                val useURL = extractedURL ?: (tpl?.baseURL ?: "https://generativelanguage.googleapis.com/v1beta")
                ClipboardProviderCandidate(
                    apiKey = key.value,
                    baseURL = useURL,
                    protocolType = APIProtocolType.GEMINI,
                    providerName = tpl?.name ?: "Google Gemini",
                    templateID = "gemini",
                    accentHex = tpl?.accentHex ?: "#2563EB",
                    iconSymbol = tpl?.iconSymbol ?: "wand.and.stars",
                    confidenceNote = L10n.text("已识别 Google Gemini Key (AIza...)", "Recognized Gemini key (AIza...)"),
                    suggestedModels = tpl?.suggestedModels.orEmpty(),
                    isGenericOpenAIKey = false
                )
            }
            KeyOrigin.OPENROUTER -> {
                val tpl = ProviderTemplate.catalog.firstOrNull { it.id == "openrouter" }
                ClipboardProviderCandidate(
                    apiKey = key.value,
                    baseURL = extractedURL ?: (tpl?.baseURL ?: "https://openrouter.ai/api/v1"),
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    providerName = "OpenRouter",
                    templateID = "openrouter",
                    accentHex = tpl?.accentHex ?: "#6366F1",
                    iconSymbol = tpl?.iconSymbol ?: "arrow.triangle.branch",
                    confidenceNote = L10n.text("已识别 OpenRouter Key (sk-or-v1-...)", "Recognized OpenRouter key (sk-or-v1-...)"),
                    suggestedModels = tpl?.suggestedModels.orEmpty(),
                    isGenericOpenAIKey = false
                )
            }
            KeyOrigin.GROQ -> ClipboardProviderCandidate(
                apiKey = key.value,
                baseURL = extractedURL ?: "https://api.groq.com/openai/v1",
                protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                providerName = "Groq",
                templateID = "custom_openai",
                accentHex = "#F55036",
                iconSymbol = "bolt.fill",
                confidenceNote = L10n.text("已识别 Groq Key (gsk_...)，同时支持极速对话与 Whisper 转写。", "Recognized Groq key (gsk_...) for chat and Whisper."),
                suggestedModels = listOf(
                    ModelSpec.create("llama-3.3-70b-versatile", "Llama 3.3 70B"),
                    ModelSpec.create("qwen/qwen3-32b", "Qwen 3 32B")
                ),
                isGenericOpenAIKey = false
            )
            KeyOrigin.OPENAI_PREFIXED -> {
                val tpl = ProviderTemplate.catalog.firstOrNull { it.id == "openai" }
                val useURL = extractedURL ?: (tpl?.baseURL ?: "https://api.openai.com/v1")
                val isRelay = extractedURL != null && !useURL.contains("openai.com", ignoreCase = true)
                ClipboardProviderCandidate(
                    apiKey = key.value,
                    baseURL = useURL,
                    protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
                    providerName = if (isRelay) hostDisplayName(useURL, "OpenAI 中转") else "OpenAI",
                    templateID = if (isRelay) "custom_openai" else "openai",
                    accentHex = tpl?.accentHex ?: "#10A37F",
                    iconSymbol = tpl?.iconSymbol ?: "circle.hexagongrid.fill",
                    confidenceNote = L10n.text("已识别 OpenAI Key。", "Recognized OpenAI key."),
                    suggestedModels = tpl?.suggestedModels.orEmpty(),
                    isGenericOpenAIKey = false
                )
            }
            KeyOrigin.GENERIC_SK, KeyOrigin.LABELED -> buildUrlMatchedCandidate(
                url = extractedURL ?: "https://api.openai.com/v1",
                apiKey = key.value
            )
        }
    }

    private fun buildUrlMatchedCandidate(url: String, apiKey: String): ClipboardProviderCandidate {
        val lower = url.lowercase()
        val matched = when {
            lower.contains("deepseek.com") -> ProviderTemplate.catalog.firstOrNull { it.id == "deepseek" }
            lower.contains("siliconflow.") -> ProviderTemplate.catalog.firstOrNull { it.id == "siliconflow" }
            lower.contains("openrouter.ai") -> ProviderTemplate.catalog.firstOrNull { it.id == "openrouter" }
            lower.contains("anthropic.com") -> ProviderTemplate.catalog.firstOrNull { it.id == "anthropic" }
            lower.contains("generativelanguage.googleapis.com") -> ProviderTemplate.catalog.firstOrNull { it.id == "gemini" }
            lower.contains("openai.com") -> ProviderTemplate.catalog.firstOrNull { it.id == "openai" }
            NetworkLocation.isLocalOrPrivate(url) -> ProviderTemplate.catalog.firstOrNull { it.id == "ollama" }
            else -> null
        }

        if (matched != null) {
            return ClipboardProviderCandidate(
                apiKey = apiKey,
                baseURL = url,
                protocolType = matched.protocolType,
                providerName = matched.name,
                templateID = matched.id,
                accentHex = matched.accentHex,
                iconSymbol = matched.iconSymbol,
                confidenceNote = L10n.text(
                    "已从地址自动匹配服务商「${matched.name}」。",
                    "Matched provider \"${matched.name}\" from URL."
                ),
                suggestedModels = matched.suggestedModels,
                isGenericOpenAIKey = false
            )
        }

        val proto = when {
            lower.contains("anthropic") -> APIProtocolType.ANTHROPIC
            lower.contains("generativelanguage.googleapis.com") -> APIProtocolType.GEMINI
            else -> APIProtocolType.OPEN_AI_COMPATIBLE
        }
        return ClipboardProviderCandidate(
            apiKey = apiKey,
            baseURL = url,
            protocolType = proto,
            providerName = hostDisplayName(url, L10n.text("自定义服务商", "Custom Provider")),
            templateID = "custom_openai",
            accentHex = "#3F6EF6",
            iconSymbol = "slider.horizontal.below.square.and.square.filled",
            confidenceNote = if (NetworkLocation.isLocalOrPrivate(url)) {
                L10n.text("已识别局域网本地服务地址（可免 Key）。", "Recognized local/LAN endpoint.")
            } else {
                L10n.text("已提取自定义 Base URL 与凭证，可直接测通。", "Extracted custom gateway URL and credentials.")
            },
            suggestedModels = emptyList(),
            isGenericOpenAIKey = false
        )
    }

    private fun hostDisplayName(url: String, fallback: String): String {
        val host = runCatching { URI(url.trim().trimEnd('#')).host }.getOrNull()?.trim().orEmpty()
        return if (host.isEmpty()) fallback else host.removePrefix("api.")
    }
}
