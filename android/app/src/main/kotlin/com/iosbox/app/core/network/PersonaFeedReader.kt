package com.iosbox.app.core.network

import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.PersonaFeed
import com.iosbox.app.core.model.PersonaFeedCheckpoint
import com.iosbox.app.core.model.PersonaFeedItem
import com.iosbox.app.core.model.PersonaFeedKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.URI
import java.net.URLEncoder
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

sealed class PersonaFeedError(override val message: String) : Exception(message) {
    class InvalidAccount : PersonaFeedError(
        L10n.text("请填写有效的 X 用户名或个人主页地址。", "Please enter a valid X handle or profile URL.")
    )

    class InvalidFeed : PersonaFeedError(
        L10n.text("未找到可读取的 RSS 或 Atom 订阅，请填写博客公布的订阅地址。", "No valid RSS or Atom feed found.")
    )

    class MissingToken : PersonaFeedError(
        L10n.text("读取 X 动态需要在人物资料中保存有读取权限的 X API Bearer Token。", "Reading X feeds requires an X API Bearer Token in the persona settings.")
    )

    class ApiError(val status: Int) : PersonaFeedError(
        L10n.text("X 接口返回 HTTP $status，请检查读取权限或稍后再试。", "X API returned HTTP $status.")
    )
}

data class PersonaFeedBatch(
    val items: List<PersonaFeedItem>,
    val checkpoint: PersonaFeedCheckpoint
)

class PersonaFeedReader(
    private val skipPublicHostCheckForTesting: Boolean = false,
    private val fetch: suspend (url: String, accept: String, headers: Map<String, String>) -> Pair<ByteArray, String> =
        { url, accept, headers ->
            WebpageReader.fetchRaw(
                url = url,
                accept = accept,
                extraHeaders = headers,
                skipPublicHostCheckForTesting = skipPublicHostCheckForTesting
            )
        },
    private val tokenProvider: () -> String = { "" }
) {
    private val json = Json { ignoreUnknownKeys = true }

    companion object {
        private val X_HOSTS = setOf("x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com")
        private val X_HANDLE_REGEX = Regex("^[A-Za-z0-9_]{1,15}$")

        fun parseSource(input: String, kind: PersonaFeedKind): PersonaFeed {
            val raw = input.trim()
            return when (kind) {
                PersonaFeedKind.BLOG -> {
                    val uri = runCatching { URI(raw) }.getOrNull() ?: throw WebpageReadError.InvalidUrl()
                    WebpageReader.validate(uri)
                    PersonaFeed(kind = kind, address = uri.toASCIIString())
                }

                PersonaFeedKind.X -> {
                    var handle = raw
                    if (raw.contains('/')) {
                        val uri = runCatching { URI(raw) }.getOrNull() ?: throw PersonaFeedError.InvalidAccount()
                        val scheme = uri.scheme?.lowercase()
                        val host = uri.host?.lowercase().orEmpty()
                        val segments = uri.path.orEmpty().trim('/').split('/').filter { it.isNotEmpty() }
                        if (scheme != "https" ||
                            !X_HOSTS.contains(host) ||
                            !uri.rawUserInfo.isNullOrEmpty() ||
                            uri.port != -1 ||
                            segments.size != 1
                        ) {
                            throw PersonaFeedError.InvalidAccount()
                        }
                        handle = segments[0]
                    }
                    if (handle.startsWith("@")) handle = handle.drop(1)
                    if (!X_HANDLE_REGEX.matches(handle)) {
                        throw PersonaFeedError.InvalidAccount()
                    }
                    PersonaFeed(kind = kind, address = handle.lowercase())
                }
            }
        }
    }

    suspend fun read(feed: PersonaFeed, nowMs: Long = System.currentTimeMillis()): PersonaFeedBatch {
        return when (feed.kind) {
            PersonaFeedKind.BLOG -> readBlog(feed)
            PersonaFeedKind.X -> readX(feed, nowMs)
        }
    }

    suspend fun blogEntries(address: String): Pair<String, List<PersonaFeedItem>> {
        var currentUrl = address
        val accept = "application/atom+xml, application/rss+xml, application/xml, text/xml, text/html;q=0.5"
        for (attempt in 0..1) {
            if (!skipPublicHostCheckForTesting) {
                val uri = runCatching { URI(currentUrl) }.getOrNull() ?: throw WebpageReadError.InvalidUrl()
                WebpageReader.validate(uri)
            }
            val (data, finalUrl) = fetch(currentUrl, accept, emptyMap())
            if (!skipPublicHostCheckForTesting) {
                val finalUri = runCatching { URI(finalUrl) }.getOrNull() ?: throw WebpageReadError.InvalidUrl()
                WebpageReader.validate(finalUri)
            }
            val parsed = withContext(Dispatchers.Default) {
                val context = currentCoroutineContext()
                try {
                    SubscriptionFeedParser.parse(data, finalUrl, skipPublicHostCheckForTesting) { context.ensureActive() }
                } catch (_: PersonaFeedError.InvalidFeed) { null }
            }
            if (parsed != null) {
                val ordered = if (parsed.all { it.published != null }) {
                    parsed.sortedByDescending { it.published ?: 0L }
                } else {
                    parsed
                }
                return finalUrl to ordered
            }
            if (attempt == 0) {
                val discovered = withContext(Dispatchers.Default) {
                    val context = currentCoroutineContext()
                    SubscriptionFeedParser.discover(data.toString(Charsets.UTF_8), finalUrl, skipPublicHostCheckForTesting) {
                        context.ensureActive()
                    }
                }
                if (discovered != null && discovered != finalUrl) {
                    currentUrl = discovered
                    continue
                }
            }
            throw PersonaFeedError.InvalidFeed()
        }
        throw PersonaFeedError.InvalidFeed()
    }

    private suspend fun readBlog(feed: PersonaFeed): PersonaFeedBatch {
        var state = feed.checkpoint ?: PersonaFeedCheckpoint()
        val cachedUrl = state.feedURL
        val result: Pair<String, List<PersonaFeedItem>> = if (cachedUrl != null && cachedUrl != feed.address) {
            try {
                blogEntries(cachedUrl)
            } catch (e: WebpageReadError.HttpError) {
                if (e.code == 404) blogEntries(feed.address) else throw e
            } catch (_: PersonaFeedError.InvalidFeed) {
                blogEntries(feed.address)
            }
        } else {
            blogEntries(feed.address)
        }

        state = state.copy(feedURL = result.first)
        val window = result.second.take(256)
        val ids = window.map { it.id }
        val known = state.recentIDs.toHashSet()
        val latestIDs = ids.toHashSet()
        val nextRecent = (ids + state.recentIDs.filter { !latestIDs.contains(it) }).take(512)
        state = state.copy(recentIDs = nextRecent)
        val newItems = if (feed.checkpoint == null) {
            emptyList()
        } else {
            window.filter { !known.contains(it.id) }.reversed()
        }
        return PersonaFeedBatch(items = newItems, checkpoint = state)
    }

    @Serializable
    private data class XLookupResponse(val data: XUser)

    @Serializable
    private data class XUser(val id: String)

    @Serializable
    private data class XTimelineResponse(
        val data: List<XPost>? = null,
        val meta: XMeta
    )

    @Serializable
    private data class XPost(
        val id: String,
        val text: String,
        val created_at: String? = null
    )

    @Serializable
    private data class XMeta(
        val next_token: String? = null,
        val newest_id: String? = null,
        val result_count: Int = 0
    )

    private suspend fun readX(feed: PersonaFeed, nowMs: Long): PersonaFeedBatch {
        val handle = parseSource(feed.address, PersonaFeedKind.X).address
        val bearer = tokenProvider().trim()
        if (bearer.isEmpty()) throw PersonaFeedError.MissingToken()
        var state = feed.checkpoint ?: PersonaFeedCheckpoint()

        suspend fun requestJson(path: String, query: List<Pair<String, String>> = emptyList()): String {
            val qs = if (query.isEmpty()) "" else "?" + query.joinToString("&") { (k, v) ->
                "${URLEncoder.encode(k, "UTF-8")}=${URLEncoder.encode(v, "UTF-8")}"
            }
            val fullUrl = "https://api.x.com$path$qs"
            return try {
                val (bytes, _) = fetch(
                    fullUrl,
                    "application/json",
                    mapOf("Authorization" to "Bearer $bearer")
                )
                bytes.toString(Charsets.UTF_8)
            } catch (e: WebpageReadError.HttpError) {
                throw PersonaFeedError.ApiError(e.code)
            }
        }

        if (state.userID == null) {
            val lookupRaw = requestJson("/2/users/by/username/$handle")
            val lookup = json.decodeFromString(XLookupResponse.serializer(), lookupRaw)
            state = state.copy(userID = lookup.data.id)
        }

        val uid = state.userID ?: throw PersonaFeedError.InvalidAccount()
        if (!isPostID(uid)) throw PersonaFeedError.InvalidAccount()

        val initial = feed.checkpoint == null
        val baseQuery = mutableListOf(
            "max_results" to if (initial) "5" else "100",
            "tweet.fields" to "created_at",
            "exclude" to "retweets"
        )
        val sinceId = state.sinceID
        val startedAt = state.startedAt
        if (sinceId != null) {
            baseQuery.add("since_id" to sinceId)
        } else if (startedAt != null) {
            baseQuery.add("start_time" to DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(startedAt)))
        }

        val endpoint = "/2/users/$uid/tweets"
        val nextToken = state.nextPage
        val timelineRaw = if (nextToken != null) {
            try {
                requestJson(endpoint, baseQuery + ("pagination_token" to nextToken))
            } catch (e: PersonaFeedError.ApiError) {
                if (e.status == 400) {
                    state = state.copy(pendingNewestID = null)
                    requestJson(endpoint, baseQuery)
                } else {
                    throw e
                }
            }
        } else {
            requestJson(endpoint, baseQuery)
        }

        val page = json.decodeFromString(XTimelineResponse.serializer(), timelineRaw)
        val posts = page.data.orEmpty()
        if (posts.size != page.meta.result_count || !posts.all { isPostID(it.id) }) {
            throw PersonaFeedError.InvalidFeed()
        }

        val newest = state.pendingNewestID ?: page.meta.newest_id ?: posts.firstOrNull()?.id
        state = state.copy(startedAt = state.startedAt ?: nowMs)
        if (initial) {
            return PersonaFeedBatch(
                items = emptyList(),
                checkpoint = state.copy(sinceID = newest)
            )
        }

        val batch = (state.pendingItems.orEmpty()).toMutableList()
        val known = batch.map { it.id }.toHashSet()
        for (post in posts) {
            if (!known.add(post.id)) continue
            val publishedMs = post.created_at?.let { ts ->
                runCatching { Instant.parse(ts).toEpochMilli() }.getOrNull()
                    ?: runCatching { OffsetDateTime.parse(ts).toInstant().toEpochMilli() }.getOrNull()
            }
            batch.add(
                PersonaFeedItem(
                    id = post.id,
                    title = post.text.take(500),
                    url = "https://x.com/i/web/status/${post.id}",
                    published = publishedMs
                )
            )
        }

        batch.sortWith(compareBy<PersonaFeedItem> { it.id.length }.thenBy { it.id })
        if (batch.size > 400) {
            val overflow = batch.size - 400
            repeat(overflow) { batch.removeAt(batch.lastIndex) }
            state = state.copy(truncatedBatch = true)
        }

        val next = page.meta.next_token
        if (next != null) {
            return PersonaFeedBatch(
                items = emptyList(),
                checkpoint = state.copy(
                    nextPage = next,
                    pendingNewestID = newest,
                    pendingItems = batch
                )
            )
        }

        val finalSince = (if (state.truncatedBatch == true) batch.lastOrNull()?.id else newest) ?: state.sinceID
        return PersonaFeedBatch(
            items = batch,
            checkpoint = state.copy(
                sinceID = finalSince,
                nextPage = null,
                pendingNewestID = null,
                pendingItems = null,
                truncatedBatch = null
            )
        )
    }

    private fun isPostID(id: String): Boolean =
        id.isNotEmpty() && id.length <= 20 && id.all { it in '0'..'9' }
}
