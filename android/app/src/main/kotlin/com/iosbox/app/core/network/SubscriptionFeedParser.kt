package com.iosbox.app.core.network

import com.iosbox.app.core.model.PersonaFeedItem
import kotlinx.coroutines.CancellationException
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.StringReader
import java.net.URI
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.xml.XMLConstants
import javax.xml.parsers.SAXParserFactory

object SubscriptionFeedParser {
    private val RECOGNIZED_ROOTS = setOf("rss", "feed", "rdf")
    private val LINK_ATTRIBUTES = setOf("rel", "type", "href")
    private val DOCTYPE_OR_ENTITY_REGEX = Regex("<!(?:DOCTYPE|ENTITY)\\b", RegexOption.IGNORE_CASE)
    private val RFC822_FALLBACK = DateTimeFormatter.ofPattern("EEE, d MMM yyyy HH:mm:ss Z", Locale.US)

    fun parse(
        data: ByteArray,
        baseUrl: String,
        skipPublicHostCheckForTesting: Boolean = false,
        checkCancellation: () -> Unit = {}
    ): List<PersonaFeedItem> {
        if (data.size > WebpageReader.MAXIMUM_BYTES) {
            throw WebpageReadError.TooLarge()
        }
        val headProbe = String(data, 0, minOf(data.size, 8192), Charsets.UTF_8)
        if (DOCTYPE_OR_ENTITY_REGEX.containsMatchIn(headProbe)) {
            throw PersonaFeedError.InvalidFeed()
        }

        val factory = SAXParserFactory.newInstance().apply {
            isNamespaceAware = false
            isValidating = false
            runCatching { setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true) }
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            runCatching { setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) }
        }

        val handler = FeedSaxHandler(
            initialBaseUrl = baseUrl,
            skipPublicHostCheckForTesting = skipPublicHostCheckForTesting,
            checkCancellation = checkCancellation
        )
        try {
            val parser = factory.newSAXParser()
            val reader = parser.xmlReader
            reader.entityResolver = org.xml.sax.EntityResolver { _, _ -> InputSource(StringReader("")) }
            reader.contentHandler = handler
            reader.parse(InputSource(ByteArrayInputStream(data)))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            throw PersonaFeedError.InvalidFeed()
        }

        if (!handler.recognized) {
            throw PersonaFeedError.InvalidFeed()
        }
        return handler.items
    }

    fun discover(
        html: String,
        baseUrl: String,
        skipPublicHostCheckForTesting: Boolean = false,
        checkCancellation: () -> Unit = {}
    ): String? {
        val baseUri = runCatching { URI(baseUrl) }.getOrNull() ?: return null
        val head = html.take(150_000)
        var found: String? = null
        var hidden: String? = null
        WebpageReader.scanHtml(head, checkCancellation) { name, closing, _, start, end ->
            if (hidden != null) {
                if (closing && name == hidden) hidden = null
                return@scanHtml true
            }
            if (!closing && (name == "script" || name == "style" || name == "template")) {
                hidden = name
                return@scanHtml true
            }
            if (name == "head" && closing) return@scanHtml false
            if (name != "link" || closing) return@scanHtml true
            val values = discoveryAttributes(head, start + 5, end - 1)
            val relTokens = values["rel"].orEmpty().lowercase().split(Regex("\\s+"))
            val type = values["type"].orEmpty().lowercase()
            val rawHref = values["href"] ?: return@scanHtml true
            if ("alternate" !in relTokens || type !in setOf("application/rss+xml", "application/atom+xml")) return@scanHtml true
            val resolved = runCatching { baseUri.resolve(WebpageReader.decodeHtmlEntities(rawHref)) }.getOrNull()
            if (resolved != null) found = validateUrl(resolved, skipPublicHostCheckForTesting)
            found == null
        }
        return found
    }

    private fun discoveryAttributes(html: String, start: Int, end: Int): Map<String, String> {
        val values = HashMap<String, String>()
        var cursor = start
        while (cursor < end) {
            if (html[cursor].isWhitespace() || html[cursor] == '/') {
                cursor++
                continue
            }
            val nameStart = cursor
            while (cursor < end && !html[cursor].isWhitespace() && html[cursor] !in "=/") cursor++
            if (cursor == nameStart) {
                cursor++
                continue
            }
            val name = html.substring(nameStart, cursor).lowercase()
            while (cursor < end && html[cursor].isWhitespace()) cursor++
            if (cursor >= end || html[cursor] != '=') continue
            cursor++
            while (cursor < end && html[cursor].isWhitespace()) cursor++
            if (cursor >= end) break
            val quote = html[cursor].takeIf { it == '"' || it == '\'' }
            if (quote != null) cursor++
            val valueStart = cursor
            while (cursor < end && (if (quote != null) html[cursor] != quote else !html[cursor].isWhitespace())) cursor++
            if (name in LINK_ATTRIBUTES) values.putIfAbsent(name, html.substring(valueStart, cursor))
            if (quote != null && cursor < end) cursor++
        }
        return values
    }

    internal fun parseFeedDate(raw: String): Long? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        runCatching { return Instant.parse(trimmed).toEpochMilli() }
        runCatching { return OffsetDateTime.parse(trimmed).toInstant().toEpochMilli() }
        runCatching { return ZonedDateTime.parse(trimmed, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli() }
        runCatching { return ZonedDateTime.parse(trimmed, RFC822_FALLBACK).toInstant().toEpochMilli() }
        return null
    }

    private fun validateUrl(uri: URI, skipCheck: Boolean): String? {
        return runCatching {
            if (!skipCheck) {
                WebpageReader.validate(uri)
            } else {
                val scheme = uri.scheme?.lowercase()
                if (scheme != "http" && scheme != "https") error("bad scheme")
            }
            uri.toASCIIString()
        }.getOrNull()
    }

    private class FeedSaxHandler(
        initialBaseUrl: String,
        private val skipPublicHostCheckForTesting: Boolean,
        private val checkCancellation: () -> Unit
    ) : DefaultHandler() {
        private val stack = ArrayList<String>()
        private val bases = ArrayList<URI>().apply {
            add(runCatching { URI(initialBaseUrl) }.getOrElse { URI("https://invalid.local") })
        }
        private var sourceDepth: Int? = null
        private var fieldName: String? = null
        private var fieldDepth: Int = 0
        private val buffer = StringBuilder()
        private val fields = HashMap<String, String>()
        private var itemLink: String? = null
        private val seen = HashSet<String>()

        var recognized: Boolean = false
            private set
        val items = ArrayList<PersonaFeedItem>()

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
            checkCancellation()
            val rawName = (qName?.takeIf { it.isNotBlank() } ?: localName.orEmpty())
            val name = rawName.substringAfterLast(':').lowercase()
            stack.add(name)

            val parentBase = bases.last()
            val xmlBase = attributes?.getValue("xml:base")
            val nextBase = xmlBase?.let { runCatching { parentBase.resolve(it) }.getOrNull() } ?: parentBase
            bases.add(nextBase)

            if (stack.size == 1) {
                recognized = RECOGNIZED_ROOTS.contains(name)
            }
            if (!recognized || stack.size >= 100) {
                throw SAXException("Unsupported or overly deep feed XML")
            }

            if (sourceDepth == null &&
                (stack == listOf("rss", "channel", "item") ||
                    stack == listOf("feed", "entry") ||
                    stack == listOf("rdf", "item"))
            ) {
                sourceDepth = stack.size
                fields.clear()
                itemLink = null
            } else {
                val depth = sourceDepth
                if (depth != null && stack.size == depth + 1) {
                    fieldName = name
                    fieldDepth = stack.size
                    buffer.setLength(0)
                    if (name == "link") {
                        val rel = attributes?.getValue("rel").orEmpty()
                        if (rel.isEmpty() || rel == "alternate") {
                            val href = attributes?.getValue("href")
                            if (!href.isNullOrBlank()) {
                                publicLink(href)?.let { itemLink = it }
                            }
                        }
                    }
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            checkCancellation()
            if (fieldName != null && buffer.length < 8192) {
                val take = minOf(length, 8192 - buffer.length)
                buffer.appendRange(ch, start, start + take)
            }
        }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            checkCancellation()
            val activeField = fieldName
            if (activeField != null && stack.size == fieldDepth) {
                val text = buffer.toString().trim()
                if (text.isNotEmpty()) {
                    fields[activeField] = text
                    if (activeField == "link" && itemLink == null) {
                        itemLink = publicLink(text)
                    }
                }
                fieldName = null
            }

            val depth = sourceDepth
            if (depth != null && stack.size == depth) {
                val url = itemLink ?: publicLink(fields["guid"] ?: fields["id"] ?: "")
                if (url != null) {
                    val key = fields["guid"] ?: fields["id"] ?: url
                    val digest = sha256Hex(key)
                    if (seen.add(digest)) {
                        val rawTitle = WebpageReader.plainText(fields["title"].orEmpty())
                        val rawExcerpt = WebpageReader.plainText(
                            fields["summary"]
                                ?: fields["description"]
                                ?: fields["content"]
                                ?: fields["encoded"]
                                ?: ""
                        )
                        val stamp = fields["published"]
                            ?: fields["pubdate"]
                            ?: fields["date"]
                            ?: fields["updated"]
                            ?: ""
                        items.add(
                            PersonaFeedItem(
                                id = digest,
                                title = (rawTitle.ifEmpty { url }).take(350),
                                url = url,
                                excerpt = rawExcerpt.take(350).takeIf { it.isNotEmpty() },
                                published = parseFeedDate(stamp)
                            )
                        )
                    }
                }
                sourceDepth = null
            }

            if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex)
            if (bases.size > 1) bases.removeAt(bases.lastIndex)
        }

        private fun publicLink(value: String): String? {
            if (value.isBlank()) return null
            val resolved = runCatching { bases.last().resolve(value.trim()) }.getOrNull() ?: return null
            return validateUrl(resolved, skipPublicHostCheckForTesting)
        }

        private fun sha256Hex(raw: String): String {
            val bytes = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}
