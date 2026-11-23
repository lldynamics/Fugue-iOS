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
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.StringReader
import java.net.URI
import java.net.URLDecoder
import java.util.zip.ZipFile
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

    fun read(data: ByteArray, fallbackTitle: String, checkCancellation: () -> Unit = {}): BookManuscript {
        checkCancellation()
        val temporary = try {
            File.createTempFile("fugue-book-", ".epub")
        } catch (_: IOException) {
            throw BookImportError.InvalidBook()
        }
        try {
            temporary.writeBytes(data)
            return ZipFile(temporary).use { readArchive(it, fallbackTitle, checkCancellation) }
        } catch (_: IOException) {
            throw BookImportError.InvalidBook()
        } finally {
            temporary.delete()
        }
    }

    private data class ParsedChapter(val label: String, val text: String, val textBytes: Int)

    private fun readArchive(zip: ZipFile, fallbackTitle: String, checkCancellation: () -> Unit): BookManuscript {
        if (zip.size() > MAX_ENTRY_COUNT) throw BookImportError.InvalidBook()
        val files = HashSet<String>()
        for (entry in zip.entries()) {
            checkCancellation()
            if (!entry.isDirectory && !files.add(entry.name)) throw BookImportError.InvalidBook()
        }

        var expanded = 0L
        fun readEntry(path: String, limit: Int): ByteArray {
            if (path !in files) throw BookImportError.InvalidBook()
            val entry = zip.getEntry(path) ?: throw BookImportError.InvalidBook()
            if (entry.size > limit || entry.size > MAX_EXPANDED_BYTES - expanded) {
                throw BookImportError.TextLimit()
            }
            val bytes = zip.getInputStream(entry).use { input ->
                readLimited(input, limit, checkCancellation) { it <= MAX_EXPANDED_BYTES - expanded }
            }
            expanded += bytes.size
            return bytes
        }

        val container = parseXml(readEntry("META-INF/container.xml", CONTAINER_LIMIT), XmlMode.CONTAINER, checkCancellation)
        val packagePath = container.rootFile ?: throw BookImportError.InvalidBook()
        val opfPath = localPath(packagePath, relativeTo = "") ?: throw BookImportError.InvalidBook()
        val encrypted = HashSet<String>()
        if ("META-INF/encryption.xml" in files) {
            val enc = parseXml(readEntry("META-INF/encryption.xml", ENCRYPTION_LIMIT), XmlMode.ENCRYPTION, checkCancellation)
            for (raw in enc.encryptedPaths) {
                localPath(raw, relativeTo = "")?.let { encrypted.add(it) }
            }
        }

        val pkg = parseXml(readEntry(opfPath, OPF_LIMIT), XmlMode.PACKAGE, checkCancellation)
        if (pkg.spine.size > BookManuscript.MAXIMUM_CHAPTERS) throw BookImportError.TextLimit()
        val parsed = HashMap<String, ParsedChapter>()
        val chapters = mutableListOf<BookChapter>()
        var totalTextBytes = 0
        for (id in pkg.spine) {
            checkCancellation()
            val resource = pkg.manifest[id] ?: throw BookImportError.InvalidBook()
            if (resource.mediaType != "application/xhtml+xml" && resource.mediaType != "text/html") continue
            val path = localPath(resource.href, relativeTo = opfPath) ?: throw BookImportError.InvalidBook()
            if (path in encrypted) throw BookImportError.Locked()
            val chapter = parsed.getOrPut(path) {
                val page = parseChapterWithEntityFallback(readEntry(path, CHAPTER_LIMIT), checkCancellation)
                val text = page.body.trim()
                ParsedChapter(page.heading.ifEmpty { page.title }.take(300), text, text.toByteArray(Charsets.UTF_8).size)
            }
            if (chapter.text.isEmpty()) continue
            if (chapter.textBytes > BookManuscript.MAXIMUM_TEXT_BYTES - totalTextBytes) throw BookImportError.TextLimit()
            totalTextBytes += chapter.textBytes
            val title = chapter.label.ifEmpty { L10n.text("第 ${chapters.size + 1} 节", "Section ${chapters.size + 1}") }
            chapters.add(BookChapter(title, chapter.text))
        }

        if (chapters.isEmpty()) throw BookImportError.NoText()
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

    private fun readLimited(
        input: InputStream,
        entryLimit: Int,
        checkCancellation: () -> Unit,
        canExpandBy: (Long) -> Boolean
    ): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16_384)
        while (true) {
            checkCancellation()
            val read = input.read(buf)
            if (read < 0) break
            if (read > entryLimit - out.size() || !canExpandBy(out.size().toLong() + read)) {
                throw BookImportError.TextLimit()
            }
            out.write(buf, 0, read)
        }
        return out.toByteArray()
    }

    private enum class XmlMode { CONTAINER, PACKAGE, ENCRYPTION, CHAPTER }

    private data class ManifestItem(val href: String, val mediaType: String)

    private class EpubXmlHandler(private val mode: XmlMode, private val checkCancellation: () -> Unit) : DefaultHandler() {
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
            checkCancellation()
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
            checkCancellation()
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
            checkCancellation()
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

    private fun parseChapterWithEntityFallback(data: ByteArray, checkCancellation: () -> Unit): EpubXmlHandler {
        return try {
            parseXml(data, XmlMode.CHAPTER, checkCancellation)
        } catch (_: BookImportError) {
            var source = data.toString(Charsets.UTF_8)
            var changed = false
            for ((name, code) in htmlEntities) {
                checkCancellation()
                val token = "&$name;"
                if (source.contains(token)) {
                    source = source.replace(token, "&#$code;")
                    changed = true
                }
            }
            if (!changed) throw BookImportError.InvalidBook()
            parseXml(source.toByteArray(Charsets.UTF_8), XmlMode.CHAPTER, checkCancellation)
        }
    }

    private fun parseXml(data: ByteArray, mode: XmlMode, checkCancellation: () -> Unit): EpubXmlHandler {
        checkCancellation()
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
        val handler = EpubXmlHandler(mode, checkCancellation)
        try {
            val parser = factory.newSAXParser()
            parser.parse(InputSource(ByteArrayInputStream(data)), handler)
        } catch (e: BookImportError) {
            throw e
        } catch (_: Exception) {
            checkCancellation()
            throw BookImportError.InvalidBook()
        }
        return handler
    }
}
