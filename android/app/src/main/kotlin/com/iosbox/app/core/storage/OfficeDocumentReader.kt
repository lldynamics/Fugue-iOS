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
import java.io.StringReader
import java.net.URI
import java.net.URLDecoder
import java.util.zip.ZipFile
import javax.xml.parsers.SAXParserFactory

/**
 * Parses Office Open XML documents (.docx, .xlsx, .pptx) securely inside an isolated ZIP + SAX pass
 * without executing macros, external DTDs, or network entities.
 */
object OfficeDocumentReader {
    val SUPPORTED_EXTENSIONS = setOf("docx", "xlsx", "pptx")
    val LEGACY_BINARY_EXTENSIONS = setOf("doc", "xls", "ppt")
    val SUPPORTED_MIME_TYPES = setOf(
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    )

    private const val MAX_EXPANDED_BYTES = 64L * 1024L * 1024L
    private const val MAX_ENTRY_COUNT = 40_000
    private const val XML_ENTRY_LIMIT = 16 * 1024 * 1024
    private const val MAX_XML_DEPTH = 128
    private const val MAX_SHEETS = 200
    private const val MAX_ROWS_PER_SHEET = 5_000
    private const val MAX_COLS_PER_ROW = 64

    private val entityOrDoctypeRegex = Regex("<!(?:ENTITY|DOCTYPE)\\b", RegexOption.IGNORE_CASE)
    private val slideFileRegex = Regex("""^ppt/slides/slide(\d+)\.xml$""", RegexOption.IGNORE_CASE)
    private val sheetFileRegex = Regex("""^xl/worksheets/sheet(\d+)\.xml$""", RegexOption.IGNORE_CASE)
    private val headingStyleRegex = Regex("""^(?:heading|标题)\s*([1-6])$""", RegexOption.IGNORE_CASE)

    fun detectExtension(fileName: String, mimeType: String?): String? {
        val cleanExt = fileName.substringAfterLast('/', "")
            .substringAfterLast('\\')
            .substringAfterLast('.', "")
            .lowercase()
        if (cleanExt in SUPPORTED_EXTENSIONS || cleanExt in LEGACY_BINARY_EXTENSIONS) {
            return cleanExt
        }
        return when (mimeType?.lowercase()?.trim()) {
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "xlsx"
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx"
            "application/msword" -> "doc"
            "application/vnd.ms-excel" -> "xls"
            "application/vnd.ms-powerpoint" -> "ppt"
            else -> null
        }
    }

    fun mimeTypeFor(ext: String): String? = when (ext.lowercase()) {
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        else -> null
    }

    fun extractText(
        data: ByteArray,
        ext: String,
        fallbackTitle: String,
        maxChars: Int = 80_000,
        checkCancellation: () -> Unit = {}
    ): String {
        val manuscript = extractChapters(data, ext, fallbackTitle, checkCancellation)
        val body = if (manuscript.chapters.size == 1 &&
            (manuscript.chapters[0].title == "正文" || manuscript.chapters[0].title == "Content")
        ) {
            manuscript.chapters[0].text
        } else {
            manuscript.chapters.joinToString("\n\n") { ch -> "--- ${ch.title} ---\n${ch.text}" }
        }
        if (body.length <= maxChars) return body
        return body.take(maxChars) + L10n.text(
            "\n\n...[文档内容较长，已截取前 $maxChars 个字符]...",
            "\n\n...[Document truncated to the first $maxChars characters]..."
        )
    }

    fun extractChapters(
        data: ByteArray,
        ext: String,
        fallbackTitle: String,
        checkCancellation: () -> Unit = {}
    ): BookManuscript {
        checkCancellation()
        if (data.isEmpty()) throw BookImportError.InvalidBook()
        val lowerExt = ext.lowercase()
        if (lowerExt !in SUPPORTED_EXTENSIONS) throw BookImportError.FileType()

        val temp = try {
            File.createTempFile("fugue-office-", ".$lowerExt")
        } catch (_: IOException) {
            throw BookImportError.InvalidBook()
        }
        try {
            temp.writeBytes(data)
            return ZipFile(temp).use { zip ->
                val archive = ArchiveReader(zip, checkCancellation)
                if (archive.hasEntry("EncryptedPackage")) {
                    throw BookImportError.Locked()
                }
                val cleanTitle = fallbackTitle.trim().ifEmpty { L10n.text("未命名文档", "Untitled Document") }.take(300)
                when (lowerExt) {
                    "docx" -> readDocx(archive, cleanTitle, checkCancellation)
                    "xlsx" -> readXlsx(archive, cleanTitle, checkCancellation)
                    "pptx" -> readPptx(archive, cleanTitle, checkCancellation)
                    else -> throw BookImportError.FileType()
                }
            }
        } catch (e: BookImportError) {
            throw e
        } catch (_: IOException) {
            throw BookImportError.InvalidBook()
        } finally {
            temp.delete()
        }
    }

    private fun readDocx(
        archive: ArchiveReader,
        fallbackTitle: String,
        checkCancellation: () -> Unit
    ): BookManuscript {
        val rootRels = archive.readOptionalBytes("_rels/.rels", XML_ENTRY_LIMIT)?.let {
            parseRels(it, basePart = "", checkCancellation = checkCancellation)
        }.orEmpty()
        val mainDocPath = rootRels.firstOrNull {
            it.type.endsWith("/officeDocument", ignoreCase = true)
        }?.target ?: "word/document.xml"

        val mainBytes = archive.readRequiredBytes(mainDocPath, XML_ENTRY_LIMIT)
        val mainText = parseWordXml(mainBytes, checkCancellation)
        val docDir = mainDocPath.substringBeforeLast('/', "")
        val footnotesCandidate = if (docDir.isEmpty()) "footnotes.xml" else "$docDir/footnotes.xml"
        val notesText = archive.readOptionalBytes(footnotesCandidate, XML_ENTRY_LIMIT)
            ?.let { parseWordXml(it, checkCancellation) }
            .orEmpty()

        val combined = buildString {
            append(mainText)
            if (notesText.isNotBlank()) {
                if (isNotEmpty()) append("\n\n")
                append(L10n.text("[脚注]\n", "[Footnotes]\n"))
                append(notesText)
            }
        }.trim()

        if (combined.isEmpty()) throw BookImportError.NoText()
        if (combined.toByteArray(Charsets.UTF_8).size > BookManuscript.MAXIMUM_TEXT_BYTES) {
            throw BookImportError.TextLimit()
        }
        val chapters = try {
            BookImporter.splitChapters(combined, checkCancellation)
        } catch (_: BookImportError.NoText) {
            listOf(BookChapter(title = fallbackTitle, text = combined))
        }
        return BookManuscript(title = fallbackTitle, chapters = chapters)
    }

    private fun readXlsx(
        archive: ArchiveReader,
        fallbackTitle: String,
        checkCancellation: () -> Unit
    ): BookManuscript {
        val sharedStrings = archive.readOptionalBytes("xl/sharedStrings.xml", XML_ENTRY_LIMIT)
            ?.let { parseSharedStrings(it, checkCancellation) }
            ?: emptyList()

        val workbookRels = archive.readOptionalBytes("xl/_rels/workbook.xml.rels", XML_ENTRY_LIMIT)
            ?.let { relBytes ->
                parseRels(relBytes, basePart = "xl/workbook.xml", checkCancellation = checkCancellation)
                    .associateBy { it.id }
            }.orEmpty()

        val declaredSheets = archive.readOptionalBytes("xl/workbook.xml", XML_ENTRY_LIMIT)
            ?.let { parseWorkbookSheets(it, checkCancellation) }
            .orEmpty()

        val sheetTargets: List<Pair<String, String>> = if (declaredSheets.isNotEmpty()) {
            declaredSheets.mapNotNull { sheet ->
                val rel = workbookRels[sheet.relId] ?: return@mapNotNull null
                sheet.name to rel.target
            }
        } else {
            emptyList()
        }.ifEmpty {
            archive.entryNames()
                .mapNotNull { path ->
                    val match = sheetFileRegex.matchEntire(path) ?: return@mapNotNull null
                    val num = match.groupValues[1].toIntOrNull() ?: Int.MAX_VALUE
                    Triple(num, L10n.text("工作表 $num", "Sheet $num"), path)
                }
                .sortedBy { it.first }
                .map { it.second to it.third }
        }

        if (sheetTargets.isEmpty()) throw BookImportError.NoText()

        val chapters = mutableListOf<BookChapter>()
        var totalBytes = 0
        for ((sheetName, path) in sheetTargets.take(MAX_SHEETS)) {
            checkCancellation()
            val sheetBytes = archive.readOptionalBytes(path, XML_ENTRY_LIMIT) ?: continue
            val sheetText = parseWorksheetXml(sheetBytes, sharedStrings, checkCancellation).trim()
            if (sheetText.isEmpty()) continue
            val title = sheetName.trim().ifEmpty { L10n.text("工作表", "Sheet") }.take(300)
            val addedBytes = title.toByteArray(Charsets.UTF_8).size + sheetText.toByteArray(Charsets.UTF_8).size
            if (addedBytes > BookManuscript.MAXIMUM_TEXT_BYTES - totalBytes) {
                throw BookImportError.TextLimit()
            }
            totalBytes += addedBytes
            chapters.add(BookChapter(title = title, text = sheetText))
        }

        if (chapters.isEmpty()) throw BookImportError.NoText()
        return BookManuscript(title = fallbackTitle, chapters = chapters)
    }

    private fun readPptx(
        archive: ArchiveReader,
        fallbackTitle: String,
        checkCancellation: () -> Unit
    ): BookManuscript {
        val presentationRels = archive.readOptionalBytes("ppt/_rels/presentation.xml.rels", XML_ENTRY_LIMIT)
            ?.let { relBytes ->
                parseRels(relBytes, basePart = "ppt/presentation.xml", checkCancellation = checkCancellation)
                    .associateBy { it.id }
            }.orEmpty()

        val orderedRelIds = archive.readOptionalBytes("ppt/presentation.xml", XML_ENTRY_LIMIT)
            ?.let { parsePresentationSlideRelIds(it, checkCancellation) }
            .orEmpty()

        val slidePaths: List<String> = orderedRelIds.mapNotNull { relId ->
            presentationRels[relId]?.target
        }.ifEmpty {
            archive.entryNames()
                .mapNotNull { path ->
                    val match = slideFileRegex.matchEntire(path) ?: return@mapNotNull null
                    val num = match.groupValues[1].toIntOrNull() ?: Int.MAX_VALUE
                    num to path
                }
                .sortedBy { it.first }
                .map { it.second }
        }

        if (slidePaths.isEmpty()) throw BookImportError.NoText()
        if (slidePaths.size > BookManuscript.MAXIMUM_CHAPTERS) throw BookImportError.TextLimit()

        val chapters = mutableListOf<BookChapter>()
        var totalBytes = 0

        slidePaths.forEachIndexed { idx, slidePath ->
            checkCancellation()
            val slideBytes = archive.readOptionalBytes(slidePath, XML_ENTRY_LIMIT) ?: return@forEachIndexed
            val slideBody = parsePresentationTextXml(slideBytes, ignoreSlideNumbers = false, checkCancellation = checkCancellation)

            val slideDir = slidePath.substringBeforeLast('/', "")
            val slideFile = slidePath.substringAfterLast('/')
            val relsPath = if (slideDir.isEmpty()) "_rels/$slideFile.rels" else "$slideDir/_rels/$slideFile.rels"
            val noteTarget = archive.readOptionalBytes(relsPath, XML_ENTRY_LIMIT)
                ?.let { parseRels(it, basePart = slidePath, checkCancellation = checkCancellation) }
                ?.firstOrNull { it.type.endsWith("/notesSlide", ignoreCase = true) }
                ?.target
                ?: "ppt/notesSlides/notesSlide${idx + 1}.xml"

            val notesText = archive.readOptionalBytes(noteTarget, XML_ENTRY_LIMIT)
                ?.let { parsePresentationTextXml(it, ignoreSlideNumbers = true, checkCancellation = checkCancellation) }
                .orEmpty()

            val fullSlide = buildString {
                if (slideBody.isNotBlank()) append(slideBody)
                if (notesText.isNotBlank()) {
                    if (isNotEmpty()) append("\n\n")
                    append(L10n.text("[备注] ", "[Notes] "))
                    append(notesText)
                }
            }.trim()

            if (fullSlide.isEmpty()) return@forEachIndexed
            val chapterTitle = L10n.text("第 ${idx + 1} 页", "Slide ${idx + 1}")
            val addedBytes = chapterTitle.toByteArray(Charsets.UTF_8).size + fullSlide.toByteArray(Charsets.UTF_8).size
            if (addedBytes > BookManuscript.MAXIMUM_TEXT_BYTES - totalBytes) {
                throw BookImportError.TextLimit()
            }
            totalBytes += addedBytes
            chapters.add(BookChapter(title = chapterTitle, text = fullSlide))
        }

        if (chapters.isEmpty()) throw BookImportError.NoText()
        return BookManuscript(title = fallbackTitle, chapters = chapters)
    }

    internal fun resolvePackagePath(target: String, basePart: String): String? {
        val trimmed = target.trim()
        if (trimmed.isEmpty() || trimmed.contains('\\')) return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        if (uri.scheme != null || uri.host != null || uri.authority != null) return null
        val rawPath = uri.rawPath ?: return null
        val decoded = runCatching { URLDecoder.decode(rawPath.replace("+", "%2B"), "UTF-8") }.getOrNull() ?: return null
        if (decoded.isEmpty()) return null

        val result = if (decoded.startsWith('/')) {
            mutableListOf()
        } else {
            basePart.split('/').dropLast(1).filter { it.isNotEmpty() }.toMutableList()
        }
        for (component in decoded.trimStart('/').split('/')) {
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

    private class ArchiveReader(
        private val zip: ZipFile,
        private val checkCancellation: () -> Unit
    ) {
        private val files = HashSet<String>()
        private val orderedNames = mutableListOf<String>()
        private var expandedBytes = 0L

        init {
            if (zip.size() > MAX_ENTRY_COUNT) throw BookImportError.InvalidBook()
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                checkCancellation()
                val entry = entries.nextElement()
                if (!entry.isDirectory) {
                    if (!files.add(entry.name)) throw BookImportError.InvalidBook()
                    orderedNames.add(entry.name)
                }
            }
        }

        fun hasEntry(name: String): Boolean = name in files
        fun entryNames(): List<String> = orderedNames

        fun readRequiredBytes(path: String, limit: Int): ByteArray =
            readOptionalBytes(path, limit) ?: throw BookImportError.InvalidBook()

        fun readOptionalBytes(path: String, limit: Int): ByteArray? {
            if (path !in files) return null
            val entry = zip.getEntry(path) ?: return null
            if (entry.size > limit || entry.size > MAX_EXPANDED_BYTES - expandedBytes) {
                throw BookImportError.TextLimit()
            }
            val bytes = zip.getInputStream(entry).use { input ->
                val out = ByteArrayOutputStream()
                val buf = ByteArray(16_384)
                while (true) {
                    checkCancellation()
                    val read = input.read(buf)
                    if (read < 0) break
                    if (read > limit - out.size() || read > (MAX_EXPANDED_BYTES - expandedBytes - out.size())) {
                        throw BookImportError.TextLimit()
                    }
                    out.write(buf, 0, read)
                }
                out.toByteArray()
            }
            expandedBytes += bytes.size.toLong()
            return bytes
        }
    }

    private data class RelationshipEntry(val id: String, val type: String, val target: String)
    private data class WorkbookSheetSpec(val name: String, val relId: String)

    private fun parseRels(
        data: ByteArray,
        basePart: String,
        checkCancellation: () -> Unit
    ): List<RelationshipEntry> {
        val list = mutableListOf<RelationshipEntry>()
        parseSaxXml(data, checkCancellation) {
            onStart { name, attrs ->
                if (name == "relationship") {
                    val mode = attr(attrs, "TargetMode")
                    if (mode.equals("External", ignoreCase = true)) return@onStart
                    val id = attr(attrs, "Id") ?: return@onStart
                    val rawTarget = attr(attrs, "Target") ?: return@onStart
                    val type = attr(attrs, "Type").orEmpty()
                    val resolved = resolvePackagePath(rawTarget, basePart) ?: return@onStart
                    list.add(RelationshipEntry(id = id, type = type, target = resolved))
                }
            }
        }
        return list
    }

    private fun parseWordXml(data: ByteArray, checkCancellation: () -> Unit): String {
        val lines = mutableListOf<String>()
        var tableDepth = 0
        var cellDepth = 0
        var inParagraph = false
        var inTextRun = false
        var headingLevel = 0
        val paragraphBuf = StringBuilder()
        var currentRowCells: MutableList<String>? = null
        var currentCellBuf: StringBuilder? = null

        parseSaxXml(data, checkCancellation) {
            onStart { name, attrs ->
                when (name) {
                    "tbl" -> tableDepth++
                    "tr" -> if (tableDepth > 0) currentRowCells = mutableListOf()
                    "tc" -> if (tableDepth > 0) {
                        cellDepth++
                        currentCellBuf = StringBuilder()
                    }
                    "p" -> {
                        inParagraph = true
                        headingLevel = 0
                        paragraphBuf.setLength(0)
                    }
                    "pstyle" -> if (inParagraph) {
                        val rawStyle = attr(attrs, "val").orEmpty().trim()
                        val match = headingStyleRegex.matchEntire(rawStyle)
                        val level = match?.groupValues?.get(1)?.toIntOrNull()
                            ?: rawStyle.toIntOrNull()?.takeIf { it in 1..6 }
                        if (level != null) headingLevel = level
                    }
                    "t", "deltext" -> if (inParagraph) inTextRun = true
                    "br" -> if (inParagraph) paragraphBuf.append('\n')
                    "tab" -> if (inParagraph) paragraphBuf.append(' ')
                }
            }
            onChars { chunk ->
                if (inParagraph && inTextRun) {
                    paragraphBuf.append(chunk)
                }
            }
            onEnd { name ->
                when (name) {
                    "t", "deltext" -> inTextRun = false
                    "p" -> {
                        val rawPara = paragraphBuf.toString().trim()
                        if (rawPara.isNotEmpty()) {
                            if (cellDepth > 0) {
                                val cell = currentCellBuf
                                if (cell != null) {
                                    if (cell.isNotEmpty()) cell.append("; ")
                                    cell.append(rawPara.replace(Regex("\\s+"), " "))
                                }
                            } else if (headingLevel in 1..6) {
                                val hashes = "#".repeat(headingLevel.coerceIn(1, 4))
                                lines.add("$hashes ${rawPara.replace(Regex("\\s+"), " ")}")
                            } else {
                                lines.add(rawPara)
                            }
                        }
                        inParagraph = false
                        inTextRun = false
                        paragraphBuf.setLength(0)
                    }
                    "tc" -> {
                        if (cellDepth > 0) {
                            cellDepth--
                            if (cellDepth == 0) {
                                currentRowCells?.add(currentCellBuf?.toString().orEmpty().trim())
                                currentCellBuf = null
                            }
                        }
                    }
                    "tr" -> {
                        val row = currentRowCells
                        if (row != null && row.any { it.isNotEmpty() }) {
                            lines.add(row.joinToString(" | "))
                        }
                        currentRowCells = null
                    }
                    "tbl" -> if (tableDepth > 0) tableDepth--
                }
            }
        }
        return lines.joinToString("\n\n").trim()
    }

    private fun parseSharedStrings(data: ByteArray, checkCancellation: () -> Unit): List<String> {
        val list = mutableListOf<String>()
        var inSi = false
        var inPhonetic = false
        var inText = false
        val buf = StringBuilder()

        parseSaxXml(data, checkCancellation) {
            onStart { name, _ ->
                when (name) {
                    "si" -> {
                        inSi = true
                        buf.setLength(0)
                    }
                    "rph" -> if (inSi) inPhonetic = true
                    "t" -> if (inSi && !inPhonetic) inText = true
                }
            }
            onChars { chunk ->
                if (inSi && !inPhonetic && inText) buf.append(chunk)
            }
            onEnd { name ->
                when (name) {
                    "t" -> inText = false
                    "rph" -> inPhonetic = false
                    "si" -> {
                        list.add(buf.toString())
                        inSi = false
                        inText = false
                    }
                }
            }
        }
        return list
    }

    private fun parseWorkbookSheets(data: ByteArray, checkCancellation: () -> Unit): List<WorkbookSheetSpec> {
        val sheets = mutableListOf<WorkbookSheetSpec>()
        parseSaxXml(data, checkCancellation) {
            onStart { name, attrs ->
                if (name == "sheet") {
                    val sheetName = attr(attrs, "name").orEmpty()
                    val relId = attr(attrs, "id") ?: return@onStart
                    sheets.add(WorkbookSheetSpec(name = sheetName, relId = relId))
                }
            }
        }
        return sheets
    }

    private fun parseWorksheetXml(
        data: ByteArray,
        sharedStrings: List<String>,
        checkCancellation: () -> Unit
    ): String {
        val rows = mutableListOf<String>()
        var inRow = false
        var rowLimitHit = false
        var currentRow = ArrayList<Pair<Int, String>>()
        var nextSequentialCol = 0

        var inCell = false
        var cellCol = 0
        var cellType = ""
        var inValue = false
        var inInlineText = false
        val valBuf = StringBuilder()

        parseSaxXml(data, checkCancellation) {
            onStart { name, attrs ->
                when (name) {
                    "row" -> {
                        if (rows.size >= MAX_ROWS_PER_SHEET) {
                            rowLimitHit = true
                            return@onStart
                        }
                        inRow = true
                        currentRow = ArrayList()
                        nextSequentialCol = 0
                    }
                    "c" -> if (inRow) {
                        inCell = true
                        val ref = attr(attrs, "r")
                        cellCol = parseColumnIndex(ref) ?: nextSequentialCol
                        nextSequentialCol = cellCol + 1
                        cellType = attr(attrs, "t").orEmpty().lowercase()
                        valBuf.setLength(0)
                    }
                    "v" -> if (inCell && cellType != "inlinestr") {
                        inValue = true
                        valBuf.setLength(0)
                    }
                    "t" -> if (inCell && cellType == "inlinestr") {
                        inInlineText = true
                    }
                }
            }
            onChars { chunk ->
                if (inCell && (inValue || inInlineText)) {
                    valBuf.append(chunk)
                }
            }
            onEnd { name ->
                when (name) {
                    "v" -> inValue = false
                    "t" -> inInlineText = false
                    "c" -> {
                        if (inCell && cellCol in 0 until MAX_COLS_PER_ROW) {
                            val raw = valBuf.toString().trim()
                            val formatted = when (cellType) {
                                "s" -> raw.toIntOrNull()?.let { sharedStrings.getOrNull(it) }.orEmpty()
                                "b" -> if (raw == "1" || raw.equals("true", ignoreCase = true)) "TRUE" else if (raw.isEmpty()) "" else "FALSE"
                                else -> raw
                            }.trim().replace(Regex("\\s+"), " ")
                            if (formatted.isNotEmpty()) {
                                currentRow.add(cellCol to formatted)
                            }
                        }
                        inCell = false
                        inValue = false
                        inInlineText = false
                    }
                    "row" -> {
                        if (inRow && currentRow.isNotEmpty()) {
                            val maxCol = currentRow.maxOf { it.first }.coerceAtMost(MAX_COLS_PER_ROW - 1)
                            val dense = Array(maxCol + 1) { "" }
                            for ((col, text) in currentRow) {
                                if (col <= maxCol) dense[col] = text
                            }
                            rows.add(dense.joinToString(" | "))
                        }
                        inRow = false
                    }
                }
            }
        }
        if (rowLimitHit) {
            rows.add(
                L10n.text(
                    "…[工作表超过 $MAX_ROWS_PER_SHEET 行，已截断]…",
                    "…[Worksheet truncated at $MAX_ROWS_PER_SHEET rows]…"
                )
            )
        }
        return rows.joinToString("\n")
    }

    private fun parsePresentationSlideRelIds(data: ByteArray, checkCancellation: () -> Unit): List<String> {
        val ids = mutableListOf<String>()
        parseSaxXml(data, checkCancellation) {
            onStart { name, attrs ->
                if (name == "sldid") {
                    attr(attrs, "id")?.let { ids.add(it) }
                }
            }
        }
        return ids
    }

    private fun parsePresentationTextXml(
        data: ByteArray,
        ignoreSlideNumbers: Boolean,
        checkCancellation: () -> Unit
    ): String {
        val paragraphs = mutableListOf<String>()
        var inPara = false
        var inText = false
        var suppressedFieldDepth = 0
        val buf = StringBuilder()

        parseSaxXml(data, checkCancellation) {
            onStart { name, attrs ->
                when (name) {
                    "p" -> {
                        inPara = true
                        buf.setLength(0)
                    }
                    "fld" -> if (inPara && ignoreSlideNumbers) {
                        if (attr(attrs, "type").equals("slidenum", ignoreCase = true)) {
                            suppressedFieldDepth++
                        }
                    }
                    "t" -> if (inPara && suppressedFieldDepth == 0) inText = true
                    "br" -> if (inPara && suppressedFieldDepth == 0) buf.append('\n')
                    "tab" -> if (inPara && suppressedFieldDepth == 0) buf.append(' ')
                }
            }
            onChars { chunk ->
                if (inPara && inText && suppressedFieldDepth == 0) buf.append(chunk)
            }
            onEnd { name ->
                when (name) {
                    "t" -> inText = false
                    "fld" -> if (suppressedFieldDepth > 0) suppressedFieldDepth--
                    "p" -> {
                        val clean = buf.toString().trim()
                        if (clean.isNotEmpty()) paragraphs.add(clean)
                        inPara = false
                        inText = false
                    }
                }
            }
        }
        return paragraphs.joinToString("\n")
    }

    private fun parseColumnIndex(ref: String?): Int? {
        val clean = ref?.trim().orEmpty()
        if (clean.isEmpty()) return null
        var acc = 0
        var hasLetter = false
        for (ch in clean) {
            if (ch in 'A'..'Z') {
                hasLetter = true
                acc = acc * 26 + (ch - 'A' + 1)
            } else if (ch in 'a'..'z') {
                hasLetter = true
                acc = acc * 26 + (ch - 'a' + 1)
            } else {
                break
            }
        }
        return if (hasLetter && acc >= 1) acc - 1 else null
    }

    private class SaxDsl {
        var startHandler: (String, Attributes?) -> Unit = { _, _ -> }
        var charsHandler: (String) -> Unit = {}
        var endHandler: (String) -> Unit = {}

        fun onStart(block: (String, Attributes?) -> Unit) {
            startHandler = block
        }

        fun onChars(block: (String) -> Unit) {
            charsHandler = block
        }

        fun onEnd(block: (String) -> Unit) {
            endHandler = block
        }
    }

    private fun parseSaxXml(
        data: ByteArray,
        checkCancellation: () -> Unit,
        configure: SaxDsl.() -> Unit
    ) {
        checkCancellation()
        val headProbe = String(data, 0, minOf(data.size, 8_192), Charsets.UTF_8)
        if (entityOrDoctypeRegex.containsMatchIn(headProbe) ||
            entityOrDoctypeRegex.containsMatchIn(data.toString(Charsets.UTF_8))
        ) {
            throw BookImportError.InvalidBook()
        }

        val dsl = SaxDsl().apply(configure)
        val factory = SAXParserFactory.newInstance().apply {
            isNamespaceAware = true
            isValidating = false
            runCatching { isXIncludeAware = false }
            runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
            runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
            runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            runCatching { setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) }
        }

        val stack = ArrayList<String>()
        val handler = object : DefaultHandler() {
            override fun resolveEntity(publicId: String?, systemId: String?): InputSource {
                return InputSource(StringReader(""))
            }

            override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
                checkCancellation()
                val raw = localName?.takeIf { it.isNotEmpty() } ?: qName.orEmpty()
                val name = raw.substringAfterLast(':').lowercase()
                stack.add(name)
                if (stack.size > MAX_XML_DEPTH) throw BookImportError.InvalidBook()
                dsl.startHandler(name, attributes)
            }

            override fun characters(ch: CharArray, start: Int, length: Int) {
                checkCancellation()
                if (length > 0) dsl.charsHandler(String(ch, start, length))
            }

            override fun endElement(uri: String?, localName: String?, qName: String?) {
                checkCancellation()
                val name = (localName?.takeIf { it.isNotEmpty() } ?: qName.orEmpty())
                    .substringAfterLast(':')
                    .lowercase()
                dsl.endHandler(name)
                if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex)
            }
        }

        try {
            factory.newSAXParser().parse(InputSource(ByteArrayInputStream(data)), handler)
        } catch (e: BookImportError) {
            throw e
        } catch (_: Exception) {
            checkCancellation()
            throw BookImportError.InvalidBook()
        }
    }

    private fun attr(attributes: Attributes?, name: String): String? {
        if (attributes == null) return null
        attributes.getValue(name)?.let { return it }
        for (i in 0 until attributes.length) {
            val qName = attributes.getQName(i).orEmpty()
            val local = attributes.getLocalName(i).orEmpty()
            if (local.equals(name, ignoreCase = true) ||
                qName.equals(name, ignoreCase = true) ||
                qName.substringAfterLast(':').equals(name, ignoreCase = true)
            ) {
                return attributes.getValue(i)
            }
        }
        return null
    }
}
