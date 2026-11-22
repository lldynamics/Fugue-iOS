package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.L10n
import java.net.URI

object EndpointResolver {
    fun chatEndpoint(
        baseURL: String,
        protocolType: APIProtocolType,
        modelID: String = ""
    ): URI {
        val parsed = parseBaseComponents(baseURL)
        var path = parsed.path
        var query = parsed.rawQuery

        when (protocolType) {
            APIProtocolType.OPEN_AI_COMPATIBLE -> {
                if (!path.endsWith("/chat/completions")) {
                    path = if (parsed.forceRaw) {
                        "$path/chat/completions"
                    } else {
                        "${ensureOpenAIVersionPrefix(path)}/chat/completions"
                    }
                }
            }
            APIProtocolType.ANTHROPIC -> {
                if (!path.endsWith("/messages")) {
                    path = if (parsed.forceRaw) {
                        "$path/messages"
                    } else {
                        "${ensureAnthropicVersionPrefix(path)}/messages"
                    }
                }
            }
            APIProtocolType.GEMINI -> {
                val trimmedModel = modelID.trim()
                if (trimmedModel.any { it.isWhitespace() } || !isSafeGeminiModelIdentifier(trimmedModel)) {
                    throw LLMError.InvalidURL(baseURL)
                }
                val encodedModel = normalizeGeminiModelPath(trimmedModel)
                if (path.contains(":streamGenerateContent")) {
                    query = ensureQueryItem(query, "alt", "sse")
                } else {
                    val root = if (parsed.forceRaw) path else ensureGeminiVersionPrefix(path)
                    path = "$root/$encodedModel:streamGenerateContent"
                    query = ensureQueryItem(query, "alt", "sse")
                }
            }
        }

        return finalizeURI(parsed, path, query, baseURL)
    }

    fun modelsEndpoint(
        baseURL: String,
        protocolType: APIProtocolType
    ): URI {
        val parsed = parseBaseComponents(baseURL)
        var path = parsed.path
        var query = parsed.rawQuery

        if (path.endsWith("/chat/completions")) {
            path = stripTrailingSlash(path.removeSuffix("/chat/completions"))
        } else if (path.endsWith("/messages")) {
            path = stripTrailingSlash(path.removeSuffix("/messages"))
        } else if (protocolType == APIProtocolType.GEMINI &&
            (path.contains(":streamGenerateContent") || path.contains(":generateContent"))
        ) {
            val modelsIdx = path.indexOf("/models/")
            if (modelsIdx >= 0) {
                path = stripTrailingSlash(path.substring(0, modelsIdx))
            }
            query = removeQueryItem(query, "alt")
        }

        when (protocolType) {
            APIProtocolType.OPEN_AI_COMPATIBLE -> {
                if (!path.endsWith("/models")) {
                    path = if (parsed.forceRaw) "$path/models" else "${ensureOpenAIVersionPrefix(path)}/models"
                }
            }
            APIProtocolType.ANTHROPIC -> {
                if (!path.endsWith("/models")) {
                    path = if (parsed.forceRaw) "$path/models" else "${ensureAnthropicVersionPrefix(path)}/models"
                }
            }
            APIProtocolType.GEMINI -> {
                if (!path.endsWith("/models")) {
                    val root = if (parsed.forceRaw) path else ensureGeminiVersionPrefix(path)
                    path = "$root/models"
                    query = ensureQueryItem(query, "pageSize", "200")
                }
            }
        }

        return finalizeURI(parsed, path, query, baseURL)
    }

    fun previewChatEndpoint(
        baseURL: String,
        protocolType: APIProtocolType,
        sampleModel: String = "model-id"
    ): String =
        runCatching { chatEndpoint(baseURL, protocolType, sampleModel).toASCIIString() }
            .getOrElse { L10n.text("URL 格式待完善", "Enter a valid URL") }

    fun audioTranscriptionsEndpoint(baseURL: String): URI =
        openAIAudioEndpoint(baseURL, suffix = "/audio/transcriptions", siblingSuffix = "/audio/speech")

    fun audioSpeechEndpoint(baseURL: String): URI =
        openAIAudioEndpoint(baseURL, suffix = "/audio/speech", siblingSuffix = "/audio/transcriptions")

    private fun openAIAudioEndpoint(
        baseURL: String,
        suffix: String,
        siblingSuffix: String
    ): URI {
        val parsed = parseBaseComponents(baseURL)
        var path = parsed.path
        if (path.endsWith("/chat/completions")) {
            path = stripTrailingSlash(path.removeSuffix("/chat/completions"))
        } else if (path.endsWith("/models")) {
            path = stripTrailingSlash(path.removeSuffix("/models"))
        } else if (path.endsWith(siblingSuffix)) {
            path = stripTrailingSlash(path.removeSuffix(siblingSuffix))
        }
        if (!path.endsWith(suffix)) {
            path = if (parsed.forceRaw) "$path$suffix" else "${ensureOpenAIVersionPrefix(path)}$suffix"
        }
        return finalizeURI(parsed, path, parsed.rawQuery, baseURL)
    }

    private data class ParsedBase(
        val scheme: String,
        val rawUserInfo: String?,
        val host: String,
        val port: Int,
        val path: String,
        val rawQuery: String?,
        val rawFragment: String?,
        val forceRaw: Boolean
    )

    private fun stripTrailingSlash(value: String): String {
        var copy = value
        while (copy.endsWith("/")) {
            copy = copy.dropLast(1)
        }
        return copy
    }

    private fun parseBaseComponents(baseURL: String): ParsedBase {
        val cleaned = baseURL.trim()
        val forceRaw = cleaned.endsWith("#")
        val raw = if (forceRaw) cleaned.dropLast(1) else cleaned
        val trimmed = stripTrailingSlash(raw)
        if (trimmed.isEmpty()) throw LLMError.InvalidURL(baseURL)

        val uri = runCatching { URI(trimmed) }.getOrElse { throw LLMError.InvalidURL(baseURL) }
        val scheme = uri.scheme?.lowercase()
        val host = uri.host
        if ((scheme != "http" && scheme != "https") || host.isNullOrEmpty()) {
            throw LLMError.InvalidURL(baseURL)
        }
        val normalizedPath = stripTrailingSlash(uri.rawPath ?: "")
        return ParsedBase(
            scheme = scheme,
            rawUserInfo = uri.rawUserInfo,
            host = host,
            port = uri.port,
            path = normalizedPath,
            rawQuery = uri.rawQuery,
            rawFragment = if (forceRaw) null else uri.rawFragment,
            forceRaw = forceRaw
        )
    }

    private fun finalizeURI(
        parsed: ParsedBase,
        path: String,
        rawQuery: String?,
        rawInput: String
    ): URI {
        val normalizedPath = if (path.isEmpty() || path.startsWith("/")) path else "/$path"
        val authority = buildString {
            if (!parsed.rawUserInfo.isNullOrEmpty()) {
                append(parsed.rawUserInfo).append('@')
            }
            append(parsed.host)
            if (parsed.port != -1) {
                append(':').append(parsed.port)
            }
        }
        val composed = buildString {
            append(parsed.scheme).append("://").append(authority).append(normalizedPath)
            if (!rawQuery.isNullOrEmpty()) {
                append('?').append(rawQuery)
            }
            if (!parsed.rawFragment.isNullOrEmpty()) {
                append('#').append(parsed.rawFragment)
            }
        }
        return runCatching { URI(composed) }.getOrNull()
            ?.takeIf { !it.scheme.isNullOrEmpty() && !it.host.isNullOrEmpty() }
            ?: throw LLMError.InvalidURL(rawInput)
    }

    private fun ensureQueryItem(existingQuery: String?, name: String, value: String): String {
        if (!existingQuery.isNullOrEmpty()) {
            val hasName = existingQuery.split('&').any { pair ->
                pair.substringBefore('=').equals(name, ignoreCase = true)
            }
            if (hasName) return existingQuery
            return "$existingQuery&$name=$value"
        }
        return "$name=$value"
    }

    private fun removeQueryItem(existingQuery: String?, name: String): String? {
        if (existingQuery.isNullOrEmpty()) return existingQuery
        val kept = existingQuery.split('&').filter { pair ->
            pair.isNotEmpty() && !pair.substringBefore('=').equals(name, ignoreCase = true)
        }
        return if (kept.isEmpty()) null else kept.joinToString("&")
    }

    private fun ensureOpenAIVersionPrefix(path: String): String {
        val lower = path.lowercase()
        if (lower.isEmpty() || lower == "/") return "/v1"
        val segments = lower.split('/').filter { it.isNotEmpty() }
        val hasVersionSegment = segments.any { seg ->
            seg == "v1" || seg == "v2" || seg == "v3" || seg == "v4" || seg == "v1beta" || seg == "openai"
        }
        return if (hasVersionSegment) path else "$path/v1"
    }

    private fun ensureAnthropicVersionPrefix(path: String): String {
        if (path.isEmpty() || path == "/") return "/v1"
        val segments = path.lowercase().split('/').filter { it.isNotEmpty() }
        return if (segments.contains("v1")) path else "$path/v1"
    }

    private fun ensureGeminiVersionPrefix(path: String): String {
        if (path.isEmpty() || path == "/") return "/v1beta"
        val segments = path.lowercase().split('/').filter { it.isNotEmpty() }
        return if (segments.contains("v1beta") || segments.contains("v1")) path else "$path/v1beta"
    }

    private fun isSafeGeminiModelIdentifier(modelID: String): Boolean {
        if (modelID.isEmpty()) return true
        val bare = if (modelID.startsWith("models/")) modelID.removePrefix("models/") else modelID
        return bare.isNotEmpty() &&
            !bare.contains("..") &&
            !bare.contains('/') &&
            !bare.contains('\\') &&
            !bare.contains('?') &&
            !bare.contains('#') &&
            !bare.contains('%')
    }

    private fun normalizeGeminiModelPath(modelID: String): String {
        val trimmed = modelID.trim()
        if (trimmed.startsWith("models/")) return trimmed
        return "models/${if (trimmed.isEmpty()) "gemini-2.5-flash" else trimmed}"
    }
}
