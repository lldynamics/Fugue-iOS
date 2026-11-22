package com.iosbox.app.core.storage

import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.BookManuscript
import com.iosbox.app.core.model.L10n
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.ByteArrayInputStream

data class PdfExtractionResult(
    val text: String,
    val isLocked: Boolean = false,
    val pageCount: Int = 0
)

/**
 * Extracts text from PDF documents using pdfbox-android for both chat attachments and Book Shelf imports.
 */
object PdfTextExtractor {
    fun extractForAttachment(
        data: ByteArray,
        maxPages: Int = 200,
        maxChars: Int = 80_000,
        checkCancellation: () -> Unit = {}
    ): PdfExtractionResult {
        if (data.isEmpty() || maxPages <= 0 || maxChars <= 0) {
            return PdfExtractionResult(text = "")
        }
        val document = try {
            PDDocument.load(ByteArrayInputStream(data))
        } catch (_: InvalidPasswordException) {
            return PdfExtractionResult(text = "", isLocked = true)
        } catch (_: Exception) {
            return PdfExtractionResult(text = "")
        }

        return document.use { doc ->
            val totalPages = doc.numberOfPages
            if (doc.currentAccessPermission?.canExtractContent() == false) {
                return@use PdfExtractionResult(text = "", isLocked = true, pageCount = totalPages)
            }

            val stripper = PDFTextStripper().apply {
                sortByPosition = true
            }
            val pages = mutableListOf<String>()
            var remaining = maxChars
            var truncated = totalPages > maxPages
            val pageLimit = minOf(totalPages, maxPages)

            for (page in 1..pageLimit) {
                checkCancellation()
                if (remaining <= 0) {
                    truncated = true
                    break
                }
                stripper.startPage = page
                stripper.endPage = page
                val raw = runCatching { stripper.getText(doc) }.getOrNull().orEmpty().trim()
                if (raw.isEmpty()) continue
                val excerpt = if (raw.length > remaining) {
                    truncated = true
                    raw.take(remaining)
                } else {
                    raw
                }
                remaining -= excerpt.length
                pages.add(L10n.text("--- 第 $page 页 ---\n$excerpt", "--- Page $page ---\n$excerpt"))
            }

            if (truncated && pages.isNotEmpty()) {
                pages.add(
                    L10n.text(
                        "…[PDF 内容较长，仅提取前 $maxPages 页、最多 $maxChars 个字符]…",
                        "…[PDF is large; truncated to first $maxPages pages / $maxChars characters]…"
                    )
                )
            }
            PdfExtractionResult(
                text = pages.joinToString("\n\n"),
                isLocked = false,
                pageCount = totalPages
            )
        }
    }

    fun extractForBook(
        data: ByteArray,
        title: String,
        checkCancellation: () -> Unit = {}
    ): BookManuscript {
        if (data.isEmpty()) throw BookImportError.InvalidBook()
        val document = try {
            PDDocument.load(ByteArrayInputStream(data))
        } catch (_: InvalidPasswordException) {
            throw BookImportError.Locked()
        } catch (_: Exception) {
            throw BookImportError.InvalidBook()
        }

        return document.use { doc ->
            if (doc.currentAccessPermission?.canExtractContent() == false) {
                throw BookImportError.Locked()
            }
            val pageCount = doc.numberOfPages
            if (pageCount <= 0) throw BookImportError.NoText()
            if (pageCount > BookManuscript.MAXIMUM_CHAPTERS) throw BookImportError.TextLimit()

            val stripper = PDFTextStripper().apply {
                sortByPosition = true
            }
            val chapters = mutableListOf<BookChapter>()
            var totalBytes = 0

            for (page in 1..pageCount) {
                checkCancellation()
                stripper.startPage = page
                stripper.endPage = page
                val raw = runCatching { stripper.getText(doc) }.getOrNull().orEmpty().trim()
                if (raw.isEmpty()) continue

                val chapterTitle = L10n.text("第 $page 页", "Page $page")
                val addedBytes = raw.toByteArray(Charsets.UTF_8).size +
                    chapterTitle.toByteArray(Charsets.UTF_8).size
                if (addedBytes > BookManuscript.MAXIMUM_TEXT_BYTES - totalBytes) {
                    throw BookImportError.TextLimit()
                }
                totalBytes += addedBytes
                chapters.add(BookChapter(title = chapterTitle, text = raw))
            }

            if (chapters.isEmpty()) throw BookImportError.NoText()
            val cleanTitle = title.trim().ifEmpty { L10n.text("未命名书籍", "Untitled Book") }.take(300)
            BookManuscript(title = cleanTitle, chapters = chapters)
        }
    }
}
