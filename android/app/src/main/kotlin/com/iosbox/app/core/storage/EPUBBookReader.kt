package com.iosbox.app.core.storage

import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.BookManuscript
import com.iosbox.app.core.model.L10n
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.StringReader
import java.net.URI
import java.net.URLDecoder
import java.util.zip.ZipInputStream
import javax.xml.parsers.SAXParserFactory

/**
 * Reads local EPUB publications safely without executing scripts or fetching external entities/DTDs.
 */
object EPUBBookReader {
    private const val MAX_EXPANDED_BYTES = 64 * 1024 * 1024
    private const val MAX_ENTRY_COUNT = 40_000
    private const val CONTAINER_LIMIT = 256 * 1024
    private const val OPF_LIMIT = 4 * 1024 * 1024
    private const val ENCRYPTION_LIMIT = 1024 * 1024
    private const val CHAPTER_LIMIT = 24 * 1024 * 1024
    private const val MAX_XML_DEPTH = 128

    private val suppressedTags = setOf("script", "style", "nav", "svg", "noscript")
    private val blockTags = setOf("br", "p", "div", "li", "section", "h1", "h2", "h3")
    private val htmlEntities = mapOf(
        "nbsp" to 160,
        "mdash" to 8212,
        "ndash" to 8211,
        "ldquo" to 8220,
        "rdquo" to 8221,
        "lsquo" to 8216,
        "rsquo" to 8217,
        "hellip" to 8230,
        "copy" to 169
    )
    private val entityDeclRegex = Regex("<!ENTITY\\b", RegexOption.IGNORE_CASE)

    fun read(data: ByteArray, fallbackTitle: String): BookManuscript {
        var expanded = 0L
        val seenPaths = HashSet<String>()
        var containerBytes: ByteArray? = null
        var encryptionBytes: ByteArray? = null

        scanZip(data) { name, zis ->
            if (seenPaths.size >= MAX_ENTRY_COUNT || !seenPaths.add(name)) {
                throw BookImportError.InvalidBook()
            }
            when (name) {
                "META-INF/container.xml" -> {
                    val b = readLimited(zis, CONTAINER_LIMIT) { expanded + it <= MAX_EXPANDED_BYTES }
                    expanded += b.size
                    containerBytes = b
                }
                "META-INF/encryption.xml" -> {
                    val b = readLimited(zis, ENCRYPTION_LIMIT) { expanded + it <= MAX_EXPANDED_BYTES }
                    expanded += b.size
                    encryptionBytes = b
                }
            }
        }

        val containerData = containerBytes ?: throw BookImportError.InvalidBook()
        val container = parseXml(containerData, XmlMode.CONTAINER)
        val packagePath = container.rootFile ?: throw BookImportError.InvalidBook()
        val opfPath = localPath(packagePath, relativeTo = "") ?: throw BookImportError.InvalidBook()

        val encrypted = HashSet<String>()
        encryptionBytes?.let { encData ->
            val enc = parseXml(encData, XmlMode.ENCRYPTION)
            for (raw in enc.encryptedPaths) {
                localPath(raw, relativeTo = "")?.let { encrypted.add(it) }
            }
        }

        var opfBytes: ByteArray? = null
        scanZip(data) { name, zis ->
            if (name == opfPath) {
                val b = readLimited(zis, OPF_LIMIT) { expanded + it <= MAX_EXPANDED_BYTES }
                expanded += b.size
                opfBytes = b
            }
        }
        val opfData = opfBytes ?: throw BookImportError.InvalidBook()
        val pkg = parseXml(opfData, XmlMode.PACKAGE)
        if (pkg.spine.size > BookManuscript.MAXIMUM_CHAPTERS) {
            throw BookImportError.TextLimit()
        }

        val orderedChapterPaths = mutableListOf<String>()
        val neededPaths = HashSet<String>()
        for (id in pkg.spine) {
            val resource = pkg.manifest[id] ?: throw BookImportError.InvalidBook()
            if (resource.mediaType != "application/xhtml+xml" && resource.mediaType != "text/html") continue
            val resolved = localPath(resource.href, relativeTo = opfPath) ?: throw BookImportError.InvalidBook()
            if (encrypted.contains(resolved)) {
                throw BookImportError.Locked()
            }
            orderedChapterPaths.add(resolved)
            neededPaths.add(resolved)
        }

        val extractedChapters = HashMap<String, ByteArray>(neededPaths.size)
        if (neededPaths.isNotEmpty()) {
            scanZip(data) { name, zis ->
                if (neededPaths.contains(name)) {
                    val b = readLimited(zis, CHAPTER_LIMIT) { expanded + it <= MAX_EXPANDED_BYTES }
                    expanded += b.size
                    extractedChapters[name] = b
                }
            }
        }

        val chapters = mutableListOf<BookChapter>()
        var totalTextBytes = 0
        for (path in orderedChapterPaths) {
            val chapterData = extractedChapters[path] ?: throw BookImportError.InvalidBook()
            val page = parseChapterWithEntityFallback(chapterData)
            val text = page.body.trim()
            if (text.isEmpty()) continue
            totalTextBytes += text.toByteArray(Charsets.UTF_8).size
            if (totalTextBytes > BookManuscript.MAXIMUM_TEXT_BYTES) {
                throw BookImportError.TextLimit()
            }
            val label = page.heading.ifEmpty { page.title }
            val chapterTitle = if (label.isEmpty()) {
                L10n.text("第 ${chapters.size + 1} 节", "Section ${chapters.size + 1}")
            } else {
                label.take(300)
            }
            chapters.add(BookChapter(title = chapterTitle, text = text))
        }

        if (chapters.isEmpty()) {
            throw BookImportError.NoText()
        }
        val bookTitle = pkg.title.ifEmpty { fallbackTitle }.ifEmpty { L10n.text("未命名书籍", "Untitled Book") }.take(300)
        return BookManuscript(title = bookTitle, chapters = chapters)
    }

    internal fun localPath(href: String, relativeTo: String): String? {
        val trimmed = href.trim()
        if (trimmed.isEmpty() || trimmed.contains('\\')) return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        if (uri.scheme != null || uri.host != null || uri.authority != null) return null
        val rawPath = uri.rawPath ?: return null
        val decoded = runCatching { URLDecoder.decode(rawPath.replace("+", "%2B"), "UTF-8") }.getOrNull() ?: return null
        if (decoded.isEmpty() || decoded.startsWith('/')) return null

        val result = relativeTo.split('/').dropLast(1).filter { it.isNotEmpty() }.toMutableList()
        for (component in decoded.split('/')) {
            when (component) {
                "", "." -> Unit
                ".." -> {
                    if (result.isEmpty()) return null
                    result.removeAt(result.lastIndex)
                }
                else -> result.add(component)
            }
        }
        return if (result.isEmpty()) null else result.joinToString("/")
    }

    private inline fun scanZip(data: ByteArray, onEntry: (String, ZipInputStream) -> Unit) {
        try {
            ZipInputStream(ByteArrayInputStream(data)).use { zis ->
                while (true) {
                    val entry = zis.nextEntry ?: break
                    if (!entry.isDirectory) {
                        onEntry(entry.name, zis)
                    }
                    zis.closeEntry()
                }
            }
        } catch (e: BookImportError) {
            throw e
        } catch (_: Throwable) {
            throw BookImportError.InvalidBook()
        }
    }

    private fun readLimited(
        zis: ZipInputStream,
        entryLimit: Int,
        canExpandBy: (Long) -> Boolean
    ): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16_384)
        while (true) {
            val read = zis.read(buf)
            if (read <= 0) break
            if (out.size() + read > entryLimit || !canExpandBy(out.size().toLong() + read)) {
                throw BookImportError.TextLimit()
            }
            out.write(buf, 0, read)
        }
        return out.toByteArray()
    }

    private enum class XmlMode { CONTAINER, PACKAGE, ENCRYPTION, CHAPTER }

    private data class ManifestItem(val href: String, val mediaType: String)

    private class EpubXmlHandler(private val mode: XmlMode) : DefaultHandler() {
        val manifest = HashMap<String, ManifestItem>()
        val spine = mutableListOf<String>()
        val encryptedPaths = mutableListOf<String>()
        var rootFile: String? = null
        var title = ""
        var heading = ""
        var body = ""

        private val stack = mutableListOf<String>()
        private var suppressed = 0
        private var bodyDepth: Int? = null
        private var captureDepth: Int? = null
        private var captureHeading = false
        private val captureBuf = StringBuilder()
        private val bodyBuf = StringBuilder()

        override fun resolveEntity(publicId: String?, systemId: String?): InputSource {
            return InputSource(StringReader(""))
        }

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
            val rawName = localName?.takeIf { it.isNotEmpty() } ?: qName.orEmpty()
            val name = rawName.substringAfterLast(':').lowercase()
            stack.add(name)
            if (stack.size > MAX_XML_DEPTH) {
                throw BookImportError.InvalidBook()
            }

            when (mode) {
                XmlMode.CONTAINER -> {
                    if (name == "rootfile" && rootFile == null) {
                        rootFile = attr(attributes, "full-path")
                    }
                }
                XmlMode.ENCRYPTION -> {
                    if (name == "cipherreference") {
                        attr(attributes, "URI")?.let { encryptedPaths.add(it) }
                    }
                }
                XmlMode.PACKAGE -> {
                    if (name == "item") {
                        val id = attr(attributes, "id")
                        val href = attr(attributes, "href")
                        val mediaType = attr(attributes, "media-type")
                        if (id != null && href != null && mediaType != null) {
                            manifest[id] = ManifestItem(href, mediaType)
                        }
                    } else if (name == "itemref") {
                        val linear = attr(attributes, "linear")
                        val idref = attr(attributes, "idref")
                        if (!linear.equals("no", ignoreCase = true) && idref != null) {
                            spine.add(idref)
                        }
                    } else if (name == "title" && stack.contains("metadata") && title.isEmpty()) {
                        beginCapture(isHeading = false)
                    }
                }
                XmlMode.CHAPTER -> {
                    if (suppressedTags.contains(name)) {
                        suppressed++
                    }
                    if (suppressed > 0) return
                    if (name == "body") {
                        bodyDepth = stack.size
                    }
                    if (name == "title" && stack.contains("head") && title.isEmpty()) {
                        beginCapture(isHeading = false)
                    }
                    if ((name == "h1" || name == "h2") && bodyDepth != null && heading.isEmpty() && captureDepth == null) {
                        beginCapture(isHeading = true)
                    }
                    if (bodyDepth != null && blockTags.contains(name) && bodyBuf.isNotEmpty() && !bodyBuf.endsWith('\n')) {
                        bodyBuf.append('\n')
                    }
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (suppressed > 0 || length <= 0) return
            val str = String(ch, start, length)
            if (captureDepth != null && captureBuf.length < 1_200) {
                captureBuf.append(str.take(300))
            }
            if (bodyDepth != null) {
                bodyBuf.append(str)
            }
        }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            if (stack.size == captureDepth) {
                val clean = captureBuf.toString()
                    .trim()
                    .replace(Regex("\\s+"), " ")
                if (captureHeading) {
                    heading = clean
                } else {
                    title = clean
                }
                captureDepth = null
            }
            if (stack.size == bodyDepth) {
                bodyDepth = null
                body = bodyBuf.toString()
            }
            if (mode == XmlMode.CHAPTER && stack.isNotEmpty() && suppressedTags.contains(stack.last())) {
                suppressed = (suppressed - 1).coerceAtLeast(0)
            }
            if (stack.isNotEmpty()) {
                stack.removeAt(stack.lastIndex)
            }
        }

        override fun endDocument() {
            if (body.isEmpty() && bodyBuf.isNotEmpty()) {
                body = bodyBuf.toString()
            }
        }

        private fun beginCapture(isHeading: Boolean) {
            captureDepth = stack.size
            captureHeading = isHeading
            captureBuf.setLength(0)
        }

        private fun attr(attributes: Attributes?, name: String): String? {
            if (attributes == null) return null
            attributes.getValue(name)?.let { return it }
            for (i in 0 until attributes.length) {
                if (attributes.getQName(i).equals(name, ignoreCase = true) ||
                    attributes.getLocalName(i).equals(name, ignoreCase = true)
                ) {
                    return attributes.getValue(i)
                }
            }
            return null
        }
    }

    private fun parseChapterWithEntityFallback(data: ByteArray): EpubXmlHandler {
        return try {
            parseXml(data, XmlMode.CHAPTER)
        } catch (_: BookImportError) {
            var source = data.toString(Charsets.UTF_8)
            var changed = false
            for ((name, code) in htmlEntities) {
                val token = "&$name;"
                if (source.contains(token)) {
                    source = source.replace(token, "&#$code;")
                    changed = true
                }
            }
            if (!changed) throw BookImportError.InvalidBook()
            parseXml(source.toByteArray(Charsets.UTF_8), XmlMode.CHAPTER)
        }
    }

    private fun parseXml(data: ByteArray, mode: XmlMode): EpubXmlHandler {
        val probe = data.toString(Charsets.UTF_8)
        if (entityDeclRegex.containsMatchIn(probe)) {
            throw BookImportError.InvalidBook()
        }
        val factory = SAXParserFactory.newInstance().apply {
            isNamespaceAware = true
            isValidating = false
            runCatching { isXIncludeAware = false }
            runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            runCatching { setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) }
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", false) }
        }
        val handler = EpubXmlHandler(mode)
        try {
            val parser = factory.newSAXParser()
            parser.parse(InputSource(ByteArrayInputStream(data)), handler)
        } catch (e: BookImportError) {
            throw e
        } catch (_: Throwable) {
            throw BookImportError.InvalidBook()
        }
        return handler
    }
}
