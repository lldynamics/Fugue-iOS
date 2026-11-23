package com.iosbox.app.core.network

import com.iosbox.app.core.model.L10n
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.URI
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

data class ReadablePage(
    val url: String,
    val title: String,
    val text: String,
    val isTruncated: Boolean
)

sealed class WebpageReadError(override val message: String) : Exception(message) {
    class InvalidUrl : WebpageReadError(
        L10n.text("仅支持有效的公开 HTTPS 网页链接。", "Only valid public HTTPS URLs are supported.")
    )

    class BlockedPrivateHost(host: String) : WebpageReadError(
        L10n.text(
            "安全策略已拦截对本机或内网地址的网页读取：$host",
            "Blocked reading private or local network host: $host"
        )
    )

    class HttpError(val code: Int) : WebpageReadError(
        L10n.text("网页请求返回 HTTP $code。", "Webpage request failed with HTTP $code.")
    )

    class UnsupportedContentType : WebpageReadError(
        L10n.text("该链接不是可读取的文本或网页类型。", "Unsupported non-text content type.")
    )

    class TooLarge : WebpageReadError(
        L10n.text("网页体积超过 2 MiB 读取限制。", "Webpage exceeds the 2 MiB limit.")
    )

    class EmptyContent : WebpageReadError(
        L10n.text("网页正文为空。", "Webpage content was empty.")
    )

    class DestinationNotApproved : WebpageReadError(
        L10n.text("用户已拒绝访问", "Declined by user")
    )
}

object WebpageReader {
    const val MAXIMUM_BYTES = 2_097_152
    const val MAX_REDIRECTS = 3
    const val MAX_TEXT_CHARS = 12_000

    private val publicOnlyDns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> {
            val addrs = Dns.SYSTEM.lookup(hostname)
            val safe = addrs.filter { addr ->
                val rawIp = addr.hostAddress.orEmpty()
                !addr.isAnyLocalAddress &&
                    !addr.isLoopbackAddress &&
                    !addr.isLinkLocalAddress &&
                    !addr.isSiteLocalAddress &&
                    !addr.isMulticastAddress &&
                    !NetworkLocation.isLocalOrPrivateHost(rawIp)
            }
            if (safe.isEmpty()) {
                throw UnknownHostException("Blocked non-public DNS resolution for $hostname")
            }
            return safe
        }
    }

    val defaultClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .dns(publicOnlyDns)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .build()
    }

    fun validate(uri: URI) {
        val scheme = uri.scheme?.lowercase() ?: throw WebpageReadError.InvalidUrl()
        if (scheme != "https") throw WebpageReadError.InvalidUrl()
        val host = uri.host?.takeIf { it.isNotBlank() } ?: throw WebpageReadError.InvalidUrl()
        if (!uri.rawUserInfo.isNullOrEmpty()) throw WebpageReadError.InvalidUrl()
        if (NetworkLocation.isLocalOrPrivateHost(host) || NetworkLocation.isLocalOrPrivate(uri.toASCIIString())) {
            throw WebpageReadError.BlockedPrivateHost(host)
        }
    }

    fun requestIdentity(uri: URI): String =
        uri.toASCIIString().toHttpUrlOrNull()?.newBuilder()?.fragment(null)?.build()?.toString()
            ?: uri.toASCIIString()

    fun origin(uri: URI): String? {
        val url = uri.toASCIIString().toHttpUrlOrNull() ?: return null
        return url.newBuilder().encodedPath("/").query(null).fragment(null).build().toString()
    }

    private data class FetchedResponse(
        val bytes: ByteArray,
        val finalUrl: String,
        val mime: String,
        val charset: java.nio.charset.Charset
    )

    suspend fun fetchRaw(
        url: String,
        accept: String,
        extraHeaders: Map<String, String> = emptyMap(),
        client: OkHttpClient = defaultClient,
        skipPublicHostCheckForTesting: Boolean = false
    ): Pair<ByteArray, String> = withContext(Dispatchers.IO) {
        val uri = runCatching { URI(url.trim()) }.getOrNull() ?: throw WebpageReadError.InvalidUrl()
        val fetched = fetchVerifiedBytes(
            uri = uri,
            accept = accept,
            extraHeaders = extraHeaders,
            requireReadableMime = false,
            client = client,
            skipPublicHostCheckForTesting = skipPublicHostCheckForTesting
        )
        fetched.bytes to fetched.finalUrl
    }

    suspend fun read(
        uri: URI,
        client: OkHttpClient = defaultClient,
        skipPublicHostCheckForTesting: Boolean = false,
        authorizeRedirect: (suspend (URI) -> Boolean)? = null
    ): ReadablePage = withContext(Dispatchers.IO) {
        val fetched = fetchVerifiedBytes(
            uri = uri,
            accept = "text/html,application/xhtml+xml,text/plain,application/json,application/xml;q=0.9,*/*;q=0.1",
            extraHeaders = emptyMap(),
            requireReadableMime = true,
            client = client,
            skipPublicHostCheckForTesting = skipPublicHostCheckForTesting,
            authorizeRedirect = authorizeRedirect
        )

        val rawText = fetched.bytes.toString(fetched.charset)
        val isHtml = fetched.mime.contains("html") ||
            fetched.mime.isEmpty() && rawText.trimStart().startsWith("<")
        val (rawTitle, bodyText) = if (isHtml) {
            val context = currentCoroutineContext()
            extractReadableHtml(rawText) { context.ensureActive() }
        } else {
            "" to collapseWhitespace(rawText)
        }

        if (bodyText.isBlank()) {
            throw WebpageReadError.EmptyContent()
        }

        val truncated = bodyText.length > MAX_TEXT_CHARS
        val finalText = if (truncated) bodyText.take(MAX_TEXT_CHARS) else bodyText
        ReadablePage(
            url = fetched.finalUrl,
            title = rawTitle.take(300),
            text = finalText,
            isTruncated = truncated
        )
    }

    private suspend fun fetchVerifiedBytes(
        uri: URI,
        accept: String,
        extraHeaders: Map<String, String>,
        requireReadableMime: Boolean,
        client: OkHttpClient,
        skipPublicHostCheckForTesting: Boolean,
        authorizeRedirect: (suspend (URI) -> Boolean)? = null
    ): FetchedResponse {
        var currentUri = uri
        var redirects = 0
        val approved = hashSetOf(requestIdentity(uri))
        val directClient = if (client.followRedirects || client.followSslRedirects) {
            client.newBuilder().followRedirects(false).followSslRedirects(false).build()
        } else client
        val authenticatedOrigin = if (extraHeaders.keys.any { it.equals("Authorization", ignoreCase = true) }) {
            origin(uri) ?: throw WebpageReadError.InvalidUrl()
        } else null

        while (true) {
            if (!skipPublicHostCheckForTesting) {
                validate(currentUri)
            }
            if (authenticatedOrigin != null && origin(currentUri) != authenticatedOrigin) throw WebpageReadError.InvalidUrl()
            val requestKey = requestIdentity(currentUri)
            if (requestKey !in approved && authorizeRedirect != null) {
                if (!authorizeRedirect(currentUri)) throw WebpageReadError.DestinationNotApproved()
                approved.add(requestKey)
            }
            currentCoroutineContext().ensureActive()

            val reqBuilder = Request.Builder()
                .url(currentUri.toASCIIString())
                .get()
                .header("Accept", accept)
                .header("User-Agent", "Fugue/1.0 (+https://iosbox.app)")
            for ((k, v) in extraHeaders) {
                reqBuilder.header(k, v)
            }

            directClient.newCall(reqBuilder.build()).execute().use { resp ->
                if (resp.code in listOf(301, 302, 303, 307, 308)) {
                    if (redirects >= MAX_REDIRECTS) {
                        throw WebpageReadError.HttpError(resp.code)
                    }
                    val location = resp.header("Location")?.trim().orEmpty()
                    if (location.isEmpty()) throw WebpageReadError.HttpError(resp.code)
                    val resolved = runCatching { currentUri.resolve(location) }.getOrNull()
                        ?: throw WebpageReadError.InvalidUrl()
                    currentUri = resolved
                    redirects++
                    continue
                }

                if (!resp.isSuccessful) {
                    throw WebpageReadError.HttpError(resp.code)
                }

                val mediaType = resp.body?.contentType()
                val mime = if (mediaType != null) {
                    "${mediaType.type}/${mediaType.subtype}".lowercase()
                } else {
                    (resp.header("Content-Type") ?: "").substringBefore(';').trim().lowercase()
                }
                if (requireReadableMime && mime.isNotEmpty() && !isReadableMime(mime)) {
                    throw WebpageReadError.UnsupportedContentType()
                }

                val contentLength = resp.body?.contentLength() ?: -1L
                if (contentLength > MAXIMUM_BYTES) {
                    throw WebpageReadError.TooLarge()
                }

                val source = resp.body?.source() ?: throw WebpageReadError.EmptyContent()
                val out = ByteArrayOutputStream()
                val buf = ByteArray(8192)
                while (true) {
                    val read = source.read(buf)
                    if (read < 0) break
                    if (out.size() + read > MAXIMUM_BYTES) {
                        throw WebpageReadError.TooLarge()
                    }
                    out.write(buf, 0, read)
                }

                val charset = mediaType?.charset(Charsets.UTF_8) ?: Charsets.UTF_8
                return FetchedResponse(
                    bytes = out.toByteArray(),
                    finalUrl = currentUri.toASCIIString(),
                    mime = mime,
                    charset = charset
                )
            }
        }
    }

    private fun isReadableMime(mime: String): Boolean =
        mime.startsWith("text/") ||
            mime == "application/xhtml+xml" ||
            mime == "application/json" ||
            mime == "application/xml" ||
            mime.endsWith("+xml") ||
            mime.endsWith("+json")

    fun plainText(html: String): String = extractReadableHtml(html).second

    fun extractReadableHtml(html: String, checkCancellation: () -> Unit = {}): Pair<String, String> {
        val input = html.take(MAXIMUM_BYTES)
        val output = StringBuilder()
        val title = StringBuilder()
        var inTitle = false
        var capturedTitle = false
        var suppressed: String? = null
        scanHtml(input, checkCancellation, text = { start, end ->
            if (suppressed == null) {
                output.append(input, start, end)
                if (inTitle && title.length < 1200) title.append(input, start, minOf(end, start + 1200 - title.length))
            }
        }) { name, closing, selfClosing, _, _ ->
            when {
                suppressed != null -> if (closing && name == suppressed) suppressed = null
                !closing && name in hiddenTags && !(name == "svg" && selfClosing) -> { suppressed = name; output.append(' ') }
                name == "title" && !capturedTitle -> {
                    inTitle = !closing
                    capturedTitle = closing
                }
                name in blockTags -> output.append('\n')
            }
            true
        }
        return collapseWhitespace(decodeHtmlEntities(title.toString())) to
            collapseWhitespace(decodeHtmlEntities(output.toString())).take(MAX_TEXT_CHARS + 1)
    }

    private val hiddenTags = setOf("script", "style", "noscript", "svg")
    private val blockTags = setOf("p", "div", "br", "li", "ul", "ol", "tr", "h1", "h2", "h3", "h4",
        "h5", "h6", "section", "article", "header", "footer", "blockquote")
    private val horizontalSpace = Regex("[\\t ]+")

    private fun collapseWhitespace(text: String): String =
        text.lineSequence().map { horizontalSpace.replace(it, " ").trim() }
            .filter { it.isNotEmpty() }.joinToString("\n")

    // Advance over each candidate once, including malformed and unterminated tags.
    internal fun scanHtml(input: String, checkCancellation: () -> Unit = {},
                          text: (Int, Int) -> Unit = { _, _ -> },
                          tag: (String, Boolean, Boolean, Int, Int) -> Boolean) {
        var i = 0
        var textStart = 0
        var nextCancellationCheck = 0
        while (i < input.length) {
            if (i >= nextCancellationCheck) {
                checkCancellation()
                nextCancellationCheck = i + 1024
            }
            if (input[i] != '<' || i + 1 >= input.length) { i++; continue }
            val start = i
            if (input.startsWith("<!--", start)) {
                text(textStart, start)
                var end = start + 4
                while (end + 2 < input.length && !input.startsWith("-->", end)) {
                    if ((end and 1023) == 0) checkCancellation()
                    end++
                }
                i = minOf(input.length, end + 3)
                textStart = i
                continue
            }
            val closing = input[i + 1] == '/'
            var j = i + if (closing) 2 else 1
            if (j >= input.length) break
            val special = input[j] == '!' || input[j] == '?'
            if (!special && !input[j].isLetter()) { i++; continue }
            val nameStart = j
            while (j < input.length && j - nameStart < 64 && (input[j].isLetterOrDigit() || input[j] == '-')) j++
            val name = if (special) "" else input.substring(nameStart, j).lowercase()
            var quote: Char? = null
            while (j < input.length && j - start < 8192) {
                val c = input[j]
                if (quote != null) {
                    if (c == quote) quote = null
                } else {
                    if (c == '>' || c == '<') break
                    if (c == '"' || c == '\'') quote = c
                }
                j++
            }
            if (j < input.length && input[j] == '>' && quote == null) {
                text(textStart, start)
                var tail = j - 1
                while (tail > start && input[tail].isWhitespace()) tail--
                if (!tag(name, closing, input[tail] == '/', start, j + 1)) return
                i = j + 1
                textStart = i
            } else {
                i = maxOf(start + 1, j)
            }
        }
        checkCancellation()
        text(textStart, input.length)
    }

    internal fun decodeHtmlEntities(text: String): String {
        var result = text
            .replace("&nbsp;", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
        result = NUMERIC_HEX_ENTITY.replace(result) { match ->
            val code = match.groupValues[1].toIntOrNull(16)
            if (code != null && Character.isValidCodePoint(code)) String(Character.toChars(code)) else match.value
        }
        result = NUMERIC_DEC_ENTITY.replace(result) { match ->
            val code = match.groupValues[1].toIntOrNull(10)
            if (code != null && Character.isValidCodePoint(code)) String(Character.toChars(code)) else match.value
        }
        return result
    }

    private val NUMERIC_HEX_ENTITY = Regex("&#[xX]([0-9a-fA-F]+);")
    private val NUMERIC_DEC_ENTITY = Regex("&#([0-9]+);")
}
