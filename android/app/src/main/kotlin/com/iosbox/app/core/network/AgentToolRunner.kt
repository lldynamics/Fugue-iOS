package com.iosbox.app.core.network

import com.iosbox.app.core.model.L10n
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.net.URI

enum class WebpageApprovalDecision {
    ALLOW,
    DENY
}

@Serializable
data class ToolCallRecord(
    val id: String,
    val name: String,
    val argumentsSummary: String,
    val resultSummary: String,
    val succeeded: Boolean
)

/**
 * Multi-round Agent Tool definitions & dispatcher, ported from iOS `AgentToolRunner.swift`.
 */
object AgentToolRunner {
    const val MAX_TOOL_ROUNDS = 3
    private const val MAX_MEMORY_CHARACTERS = 200
    private val compactJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val httpsLinkRegex = Regex("https://[^\\s<>\"'\\)\\]]+", RegexOption.IGNORE_CASE)

    fun extractUserProvidedURLs(texts: List<String>): Set<String> {
        val allowed = HashSet<String>()
        for (text in texts) {
            if (text.isEmpty()) continue
            for (match in httpsLinkRegex.findAll(text)) {
                val cleaned = match.value.trimEnd(',', '.', ';', ':', '!', '?', '\'', '"', ')', ']')
                val uri = runCatching { URI(cleaned) }.getOrNull() ?: continue
                if (uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank()) {
                    allowed.add(canonicalURLKey(uri))
                }
            }
        }
        return allowed
    }

    fun canonicalURLKey(uri: URI): String {
        val scheme = uri.scheme?.lowercase() ?: "https"
        val host = uri.host?.lowercase() ?: ""
        val port = if (uri.port == 443) -1 else uri.port
        val rawPath = uri.rawPath.orEmpty()
        val authority = if (port != -1) "$host:$port" else host
        return buildString {
            append(scheme).append("://").append(authority).append(rawPath)
            val q = uri.rawQuery
            if (!q.isNullOrEmpty()) {
                append('?').append(q)
            }
        }
    }

    fun definitions(hasTavilyKey: Boolean, hasKnowledgeBase: Boolean = false): List<LLMToolDefinition> {
        val tools = mutableListOf(
            LLMToolDefinition(
                name = "read_webpage",
                description = "Read the main text content of a public HTTPS webpage URL when the user provides a URL or asks to inspect a specific page.",
                parametersSchemaJSON = """{"type":"object","properties":{"url":{"type":"string","description":"Public HTTPS webpage URL to read"}},"required":["url"]}"""
            ),
            LLMToolDefinition(
                name = "propose_memory",
                description = "Suggest a concise long-term personal preference or background fact for the user to optionally save (only when the user explicitly states a durable preference or background).",
                parametersSchemaJSON = """{"type":"object","properties":{"fact":{"type":"string","description":"Concise user preference or background fact (max 200 chars)"}},"required":["fact"]}"""
            )
        )
        if (hasKnowledgeBase) {
            tools.add(
                0,
                LLMToolDefinition(
                    name = "search_documents",
                    description = "Search across the user's bound local reference documents (PDFs, EPUBs, Markdown, books) by keywords or question to retrieve exact cited passages.",
                    parametersSchemaJSON = """{"type":"object","properties":{"query":{"type":"string","description":"Focused search terms or question to look up in bound documents"}},"required":["query"]}"""
                )
            )
        }
        if (hasTavilyKey) {
            tools.add(
                0,
                LLMToolDefinition(
                    name = "web_search",
                    description = "Search the web for current facts, documentation, news, or verification.",
                    parametersSchemaJSON = """{"type":"object","properties":{"query":{"type":"string","description":"Concise search query (1-400 characters)"}},"required":["query"]}"""
                )
            )
        }
        return tools
    }

    data class ExecutionOutput(
        val toolOutputJSON: String,
        val record: ToolCallRecord,
        val searchEvidence: SearchEvidence? = null,
        val proposedMemory: String? = null,
        val error: Throwable? = null
    )

    suspend fun execute(
        call: LLMToolCall,
        searchHandler: suspend (String) -> SearchEvidence,
        webpageHandler: suspend (URI) -> ReadablePage = { WebpageReader.read(it) },
        webpageApproval: (suspend (URI) -> WebpageApprovalDecision)? = null,
        knowledgeHandler: (suspend (String) -> String)? = null
    ): ExecutionOutput {
        val args = call.argumentsObject(compactJson)

        return when (call.name) {
            "web_search" -> {
                val query = (args["query"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
                if (query.isEmpty()) {
                    return ExecutionOutput(
                        toolOutputJSON = jsonError("Missing search query"),
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = "",
                            resultSummary = L10n.text("缺少搜索词", "Missing search query"),
                            succeeded = false
                        )
                    )
                }
                try {
                    val evidence = searchHandler(query.take(TavilySearchClient.MAXIMUM_QUERY_CHARACTERS))
                    ExecutionOutput(
                        toolOutputJSON = evidence.prompt,
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = query,
                            resultSummary = L10n.text("${evidence.sources.size} 个来源", "${evidence.sources.size} sources"),
                            succeeded = true
                        ),
                        searchEvidence = evidence
                    )
                } catch (t: Throwable) {
                    val msg = t.message ?: L10n.text("搜索失败", "Search failed")
                    ExecutionOutput(
                        toolOutputJSON = jsonError(msg),
                        record = ToolCallRecord(call.id, call.name, query, msg, succeeded = false),
                        error = t
                    )
                }
            }

            "search_documents" -> {
                val query = (args["query"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
                if (query.isEmpty()) {
                    return ExecutionOutput(
                        toolOutputJSON = jsonError("Missing document search query"),
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = "",
                            resultSummary = L10n.text("缺少搜索词", "Missing search query"),
                            succeeded = false
                        )
                    )
                }
                if (knowledgeHandler == null) {
                    return ExecutionOutput(
                        toolOutputJSON = jsonError("No reference documents are bound to this conversation"),
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = query,
                            resultSummary = L10n.text("未绑定文档", "No bound documents"),
                            succeeded = false
                        )
                    )
                }
                try {
                    val promptText = knowledgeHandler(query.take(400))
                    ExecutionOutput(
                        toolOutputJSON = promptText.ifEmpty { """{"matches":[]}""" },
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = query,
                            resultSummary = L10n.text("已完成检索", "Searched"),
                            succeeded = true
                        )
                    )
                } catch (t: Throwable) {
                    val msg = t.message ?: L10n.text("检索失败", "Search failed")
                    ExecutionOutput(
                        toolOutputJSON = jsonError(msg),
                        record = ToolCallRecord(call.id, call.name, query, msg, succeeded = false),
                        error = t
                    )
                }
            }

            "read_webpage" -> {
                val rawURL = (args["url"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
                val uri = runCatching { URI(rawURL) }.getOrNull()
                if (uri == null || uri.host.isNullOrBlank()) {
                    return ExecutionOutput(
                        toolOutputJSON = jsonError("Invalid URL"),
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = rawURL,
                            resultSummary = L10n.text("无效链接", "Invalid URL"),
                            succeeded = false
                        )
                    )
                }
                try {
                    WebpageReader.validate(uri)
                    if (webpageApproval != null) {
                        val decision = webpageApproval(uri)
                        if (decision == WebpageApprovalDecision.DENY) {
                            return ExecutionOutput(
                                toolOutputJSON = jsonError("User declined reading external webpage"),
                                record = ToolCallRecord(
                                    id = call.id,
                                    name = call.name,
                                    argumentsSummary = uri.host ?: rawURL,
                                    resultSummary = L10n.text("用户已拒绝访问", "Declined by user"),
                                    succeeded = false
                                )
                            )
                        }
                    }
                    val page = webpageHandler(uri)
                    val payload = buildJsonObject {
                        put("url", page.url)
                        put("title", page.title)
                        put("text", page.text.take(WebpageReader.MAX_TEXT_CHARS))
                        put("truncated", page.isTruncated || page.text.length > WebpageReader.MAX_TEXT_CHARS)
                    }
                    ExecutionOutput(
                        toolOutputJSON = "Untrusted webpage reference:\n$payload",
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = uri.host ?: rawURL,
                            resultSummary = page.title.takeIf { it.isNotEmpty() }?.take(60)
                                ?: L10n.text("已完成", "Done"),
                            succeeded = true
                        )
                    )
                } catch (t: Throwable) {
                    val msg = t.message ?: L10n.text("读取失败", "Read failed")
                    ExecutionOutput(
                        toolOutputJSON = jsonError(msg),
                        record = ToolCallRecord(call.id, call.name, rawURL, msg, succeeded = false),
                        error = t
                    )
                }
            }

            "propose_memory" -> {
                val fact = (args["fact"] as? JsonPrimitive)?.contentOrNull?.trim().orEmpty()
                if (fact.isEmpty()) {
                    return ExecutionOutput(
                        toolOutputJSON = jsonError("Empty memory fact"),
                        record = ToolCallRecord(
                            id = call.id,
                            name = call.name,
                            argumentsSummary = "",
                            resultSummary = L10n.text("内容为空", "Empty"),
                            succeeded = false
                        )
                    )
                }
                val bounded = fact.take(MAX_MEMORY_CHARACTERS)
                ExecutionOutput(
                    toolOutputJSON = """{"status":"proposed_for_user_confirmation"}""",
                    record = ToolCallRecord(
                        id = call.id,
                        name = call.name,
                        argumentsSummary = bounded.take(80),
                        resultSummary = L10n.text("待用户确认", "Pending confirmation"),
                        succeeded = true
                    ),
                    proposedMemory = bounded
                )
            }

            else -> {
                ExecutionOutput(
                    toolOutputJSON = jsonError("Unsupported tool: ${call.name}"),
                    record = ToolCallRecord(
                        id = call.id,
                        name = call.name,
                        argumentsSummary = call.argumentsJSON,
                        resultSummary = L10n.text("不支持的工具", "Unsupported tool"),
                        succeeded = false
                    )
                )
            }
        }
    }

    private fun jsonError(message: String): String =
        buildJsonObject { put("error", message) }.toString()
}
