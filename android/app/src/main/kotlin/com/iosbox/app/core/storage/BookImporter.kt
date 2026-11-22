package com.iosbox.app.core.storage

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.BookManuscript
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.PreparedBook
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

object BookImporter {
    const val MAXIMUM_FILE_BYTES = 64 * 1024 * 1024

    private val chapterHeadingRegex = Regex(
        """^(?:#{1,4}\s+\S|第[〇零一二三四五六七八九十百千万两\d壹贰叁肆伍陆柒捌玖拾佰仟]+[章节回卷部篇]|(?:chapter|part|book)\s+(?:\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\b|序章$|楔子$|尾声$|后记$)""",
        RegexOption.IGNORE_CASE
    )

    suspend fun readUri(contentResolver: ContentResolver, uri: Uri): PreparedBook {
        val context = currentCoroutineContext()
        val fileName = resolveFileName(contentResolver, uri) ?: "book.txt"
        val bytes = readBytesLimited(contentResolver, uri) { context.ensureActive() }
        return PreparedBook.from(parse(bytes, fileName) { context.ensureActive() })
    }

    fun parse(data: ByteArray, filename: String, checkCancellation: () -> Unit = {}): BookManuscript {
        if (data.size > MAXIMUM_FILE_BYTES) {
            throw BookImportError.FileLimit()
        }
        val cleanName = filename.substringAfterLast('/').substringAfterLast('\\')
        val ext = cleanName.substringAfterLast('.', "").lowercase()
        val baseTitle = (if (cleanName.contains('.')) cleanName.substringBeforeLast('.') else cleanName)
            .trim()
            .ifEmpty { L10n.text("未命名书籍", "Untitled Book") }
            .take(300)

        return when (ext) {
            "epub" -> EPUBBookReader.read(data, fallbackTitle = baseTitle, checkCancellation = checkCancellation)
            "pdf" -> PdfTextExtractor.extractForBook(data, title = baseTitle, checkCancellation = checkCancellation)
            in OfficeDocumentReader.SUPPORTED_EXTENSIONS ->
                OfficeDocumentReader.extractChapters(data, ext = ext, fallbackTitle = baseTitle, checkCancellation = checkCancellation)
            "txt", "md", "markdown", "text" -> {
                val raw = decodeText(data) ?: throw BookImportError.NoText()
                if (raw.contains('\u0000')) throw BookImportError.NoText()
                val cleaned = raw.trimStart('\uFEFF').trim()
                if (cleaned.isEmpty()) throw BookImportError.NoText()
                if (cleaned.toByteArray(Charsets.UTF_8).size > BookManuscript.MAXIMUM_TEXT_BYTES) {
                    throw BookImportError.TextLimit()
                }
                BookManuscript(title = baseTitle, chapters = splitChapters(cleaned, checkCancellation))
            }
            else -> throw BookImportError.FileType()
        }
    }

    fun decodeText(data: ByteArray): String? {
        if (data.size >= 2) {
            val isUtf16LE = data[0] == 0xFF.toByte() && data[1] == 0xFE.toByte()
            val isUtf16BE = data[0] == 0xFE.toByte() && data[1] == 0xFF.toByte()
            if (isUtf16LE || isUtf16BE) {
                return runCatching { String(data, Charsets.UTF_16) }.getOrNull()
            }
        }
        decodeStrict(data, Charsets.UTF_8)?.let { return it }
        val gb18030 = runCatching { Charset.forName("GB18030") }.getOrNull()
        if (gb18030 != null) {
            decodeStrict(data, gb18030)?.let { return it }
        }
        return null
    }

    private fun decodeStrict(data: ByteArray, charset: Charset): String? {
        return runCatching {
            charset.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(data))
                .toString()
        }.getOrNull()
    }

    internal fun splitChapters(text: String, checkCancellation: () -> Unit = {}): List<BookChapter> {
        val result = mutableListOf<BookChapter>()
        var currentTitle = L10n.text("正文", "Content")
        val currentBody = StringBuilder()

        fun flush() {
            val body = currentBody.trim().toString()
            if (body.isNotEmpty()) {
                result.add(BookChapter(title = currentTitle, text = body))
            }
            currentBody.setLength(0)
        }

        for (rawLine in text.lineSequence()) {
            checkCancellation()
            val trimmed = rawLine.trim()
            if (trimmed.length <= 300 && trimmed.toByteArray(Charsets.UTF_8).size <= 300 && chapterHeadingRegex.containsMatchIn(trimmed)) {
                flush()
                currentTitle = trimmed.trim('#', ' ', '\t').ifEmpty { L10n.text("正文", "Content") }
                if (result.size >= BookManuscript.MAXIMUM_CHAPTERS) {
                    throw BookImportError.TextLimit()
                }
                continue
            }
            currentBody.append(rawLine).append('\n')
        }
        flush()

        if (result.isEmpty()) throw BookImportError.NoText()
        return result
    }

    private fun readBytesLimited(contentResolver: ContentResolver, uri: Uri, checkCancellation: () -> Unit): ByteArray {
        val stream = contentResolver.openInputStream(uri) ?: throw BookImportError.InvalidBook()
        return stream.use { input ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(32_768)
            while (true) {
                checkCancellation()
                val read = input.read(buf)
                if (read <= 0) break
                if (out.size() + read > MAXIMUM_FILE_BYTES) {
                    throw BookImportError.FileLimit()
                }
                out.write(buf, 0, read)
            }
            out.toByteArray()
        }
    }

    private fun resolveFileName(contentResolver: ContentResolver, uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) {
                    val name = cursor.getString(idx)?.trim()
                    if (!name.isNullOrEmpty()) return name
                }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')
    }
}
