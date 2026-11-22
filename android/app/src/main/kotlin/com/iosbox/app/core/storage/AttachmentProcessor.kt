package com.iosbox.app.core.storage

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.CancellationSignal
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.graphics.scale
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.atomic.AtomicReference
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt

sealed class AttachmentException(override val message: String) : Exception(message) {
    class ShareReadUnavailable : AttachmentException(
        L10n.text("共享应用未能及时提供附件，请重试或取消。", "The source app did not provide the attachments in time. Retry or cancel.")
    )
    class LimitExceeded : AttachmentException(
        L10n.text(
            "附件超出限制：单文件最多 20 MB，每次最多 8 个附件，总内容最多 32 MB。",
            "Attachment limit exceeded: max 20 MB per file, 8 files, and 32 MB total."
        )
    )

    class UnreadableImage : AttachmentException(
        L10n.text(
            "无法读取图片，或图片超过 20 MB 限制。",
            "Unable to decode image, or image exceeds 20 MB."
        )
    )

    class UnsupportedBinary : AttachmentException(
        L10n.text(
            "不支持的二进制文件格式，请选择图片、PDF、Office 文档（DOCX/XLSX/PPTX）或纯文本/代码文件。",
            "Unsupported binary file format. Please choose an image, PDF, Office document (DOCX/XLSX/PPTX), or plain text/code file."
        )
    )

    class LegacyOfficeUnsupported : AttachmentException(
        L10n.text(
            "暂不支持旧版二进制 .doc / .xls / .ppt，请先另存为 .docx / .xlsx / .pptx 或 PDF 后再试。",
            "Legacy binary .doc/.xls/.ppt files are not supported. Save as .docx/.xlsx/.pptx or PDF and try again."
        )
    )
}

object AttachmentProcessor {
    const val MAXIMUM_FILE_BYTES = 20 * 1024 * 1024
    const val MAXIMUM_ATTACHMENT_COUNT = 8
    const val MAXIMUM_PAYLOAD_BYTES = 32 * 1024 * 1024
    private const val MAX_IMAGE_DIMENSION = 1600
    private const val MAX_SOURCE_PIXELS = 64_000_000L
    private const val THUMBNAIL_DIMENSION = 512
    private val thumbnailDispatcher = Dispatchers.IO.limitedParallelism(2)
    private const val JPEG_QUALITY = 82
    private const val MAX_TEXT_CHARACTERS = 80_000
    private const val MAX_INLINE_PDF_BYTES = 8 * 1024 * 1024

    fun validate(attachments: List<MessageAttachment>) {
        if (attachments.size > MAXIMUM_ATTACHMENT_COUNT) throw AttachmentException.LimitExceeded()
        var remaining = MAXIMUM_PAYLOAD_BYTES.toLong()
        for (item in attachments) {
            val size = payloadBytes(item)
            if (size > remaining) throw AttachmentException.LimitExceeded()
            remaining -= size
        }
    }

    private fun payloadBytes(item: MessageAttachment): Long =
        (item.dataBase64?.length?.toLong() ?: 0L) + (item.extractedText?.toByteArray(Charsets.UTF_8)?.size ?: 0)

    suspend fun processBatch(contentResolver: ContentResolver, uris: List<Uri>, imageOnly: Boolean = false,
                             existing: List<MessageAttachment> = emptyList(), checkAccess: (Uri) -> Unit = {}): List<MessageAttachment> {
        val context = currentCoroutineContext()
        return processBatch(contentResolver, uris, imageOnly, existing, checkAccess, null, null) { context.ensureActive() }
    }

    suspend fun processSharedBatch(
        contentResolver: ContentResolver,
        uris: List<Uri>,
        checkAccess: (Uri) -> Unit
    ): List<MessageAttachment> {
        if (uris.isEmpty()) return emptyList()
        if (uris.size > MAXIMUM_ATTACHMENT_COUNT) throw AttachmentException.LimitExceeded()
        val signal = CancellationSignal()
        val openStream = AtomicReference<InputStream?>()
        return BoundedShareRead.run(timeoutMillis = 20_000, close = {
            try { openStream.getAndSet(null)?.close() } finally { signal.cancel() }
        }) { check ->
            processBatch(contentResolver, uris, false, emptyList(), checkAccess, signal, openStream, check)
        }
    }

    private fun processBatch(
        contentResolver: ContentResolver,
        uris: List<Uri>,
        imageOnly: Boolean,
        existing: List<MessageAttachment>,
        checkAccess: (Uri) -> Unit,
        signal: CancellationSignal?,
        openStream: AtomicReference<InputStream?>?,
        checkCancellation: () -> Unit
    ): List<MessageAttachment> {
        if (uris.size > MAXIMUM_ATTACHMENT_COUNT - existing.size) throw AttachmentException.LimitExceeded()
        validate(existing)
        var remaining = MAXIMUM_PAYLOAD_BYTES - existing.sumOf(::payloadBytes)
        return uris.map { uri ->
            checkCancellation()
            if (remaining <= 0) throw AttachmentException.LimitExceeded()
            checkAccess(uri)
            val item = processUri(contentResolver, uri, imageOnly, remaining, signal, openStream, checkCancellation)
            checkCancellation()
            remaining -= payloadBytes(item)
            if (remaining < 0) throw AttachmentException.LimitExceeded()
            item
        }
    }

    private fun processUri(
        contentResolver: ContentResolver,
        uri: Uri,
        imageOnly: Boolean,
        remaining: Long,
        signal: CancellationSignal?,
        openStream: AtomicReference<InputStream?>?,
        checkCancellation: () -> Unit
    ): MessageAttachment {
        val fileName = resolveFileName(contentResolver, uri, signal) ?: if (imageOnly) "image.jpg" else "file"
        checkCancellation()
        val rawMime = contentResolver.getType(uri)?.lowercase()
        val ext = fileName.substringAfterLast('.', "").lowercase()
        checkCancellation()
        val bytes = readBytesLimited(contentResolver, uri, signal, openStream, checkCancellation)

        val isImage = imageOnly ||
            rawMime?.startsWith("image/") == true ||
            ext in setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "gif")
        if (isImage) {
            return processImageBytes(bytes, suggestedName = fileName, maximumPayload = remaining)
                ?: throw AttachmentException.UnreadableImage()
        }

        if (rawMime == "application/pdf" || ext == "pdf") {
            val extraction = PdfTextExtractor.extractForAttachment(
                data = bytes,
                maxChars = MAX_TEXT_CHARACTERS,
                checkCancellation = checkCancellation
            )
            val candidateText = when {
                extraction.isLocked -> L10n.text(
                    "[此 PDF 受密码或权限保护，无法提取正文；若模型支持原生 PDF 仍可尝试读取]",
                    "[PDF is password/permission protected; text could not be extracted]"
                )
                extraction.text.isNotEmpty() -> if (bytes.size > MAX_INLINE_PDF_BYTES) {
                    L10n.text(
                        "[PDF 文件超过 8 MB 内联上限，已提取文本供模型读取]\n\n",
                        "[PDF exceeds 8 MB inline cap; extracted text attached for model reading]\n\n"
                    ) + extraction.text
                } else {
                    extraction.text
                }
                bytes.size > MAX_INLINE_PDF_BYTES -> L10n.text(
                    "[PDF 文件超过 8 MB 内联上限，且未识别出可提取文字]",
                    "[PDF exceeds the 8 MB inline cap and contains no extractable text]"
                )
                else -> null
            }

            val wantsInlineBase64 = bytes.size <= MAX_INLINE_PDF_BYTES
            val encodedSize = if (wantsInlineBase64) encodedLength(bytes.size) else 0L
            val candidateTextBytes = candidateText?.toByteArray(Charsets.UTF_8)?.size?.toLong() ?: 0L

            var finalBase64: String? = null
            var finalText: String? = candidateText
            if (wantsInlineBase64) {
                if (encodedSize + candidateTextBytes <= remaining) {
                    finalBase64 = Base64.getEncoder().encodeToString(bytes)
                } else if (candidateText == null) {
                    throw AttachmentException.LimitExceeded()
                } else if (encodedSize <= remaining) {
                    val roomForText = (remaining - encodedSize).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                    finalText = fitUtf8Prefix(candidateText, roomForText).ifEmpty { null }
                    finalBase64 = Base64.getEncoder().encodeToString(bytes)
                } else {
                    finalText = fitUtf8Prefix(candidateText, remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                    if (finalText.isEmpty()) throw AttachmentException.LimitExceeded()
                }
            } else if (candidateTextBytes > remaining) {
                finalText = fitUtf8Prefix(candidateText.orEmpty(), remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                if (finalText.isEmpty()) throw AttachmentException.LimitExceeded()
            }

            return MessageAttachment(
                kind = AttachmentKind.DOCUMENT,
                fileName = fileName,
                mimeType = "application/pdf",
                dataBase64 = finalBase64,
                extractedText = finalText,
                byteSize = bytes.size
            )
        }

        val officeExt = OfficeDocumentReader.detectExtension(fileName, rawMime)
        if (officeExt in OfficeDocumentReader.LEGACY_BINARY_EXTENSIONS) {
            throw AttachmentException.LegacyOfficeUnsupported()
        }
        if (officeExt != null && officeExt in OfficeDocumentReader.SUPPORTED_EXTENSIONS) {
            val baseTitle = fileName.substringBeforeLast('.')
            val officeText = try {
                OfficeDocumentReader.extractText(
                    data = bytes,
                    ext = officeExt,
                    fallbackTitle = baseTitle,
                    maxChars = MAX_TEXT_CHARACTERS,
                    checkCancellation = checkCancellation
                )
            } catch (_: BookImportError.NoText) {
                L10n.text("[文档中未提取到可读文字内容]", "[No readable text found in document]")
            } catch (_: BookImportError.Locked) {
                L10n.text("[此文档已加密，无法读取内容，请先解除密码保护后重试]", "[Document is encrypted and cannot be read]")
            } catch (_: BookImportError) {
                throw AttachmentException.UnsupportedBinary()
            }
            val safeText = fitUtf8Prefix(officeText, remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
            if (safeText.isEmpty()) throw AttachmentException.LimitExceeded()
            return MessageAttachment(
                kind = AttachmentKind.DOCUMENT,
                fileName = fileName,
                mimeType = rawMime ?: OfficeDocumentReader.mimeTypeFor(officeExt) ?: "application/octet-stream",
                dataBase64 = null,
                extractedText = safeText,
                byteSize = bytes.size
            )
        }

        val decoded = decodePlainTextOrThrow(bytes)
        val resolvedMime = rawMime
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "text/plain"
        return MessageAttachment(
            kind = AttachmentKind.DOCUMENT,
            fileName = fileName,
            mimeType = resolvedMime,
            dataBase64 = null,
            extractedText = truncateIfNeeded(decoded),
            byteSize = bytes.size
        )
    }

    private fun encodedLength(size: Int): Long = ((size.toLong() + 2) / 3) * 4

    private fun imageBounds(data: ByteArray): BitmapFactory.Options? {
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, boundsOpts)
        return boundsOpts.takeIf {
            it.outWidth > 0 && it.outHeight > 0 && it.outWidth.toLong() * it.outHeight <= MAX_SOURCE_PIXELS
        }
    }

    private fun decodeBoundedImage(data: ByteArray, maximumDimension: Int): Bitmap? {
        if (data.isEmpty() || data.size > MAXIMUM_FILE_BYTES) return null
        val boundsOpts = imageBounds(data) ?: return null
        val longest = max(boundsOpts.outWidth, boundsOpts.outHeight)
        var sampleSize = 1
        while ((longest.toLong() + sampleSize - 1) / sampleSize > maximumDimension) {
            sampleSize *= 2
        }
        val decodeOpts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size, decodeOpts) ?: return null
        if (bitmap.width > maximumDimension || bitmap.height > maximumDimension ||
            bitmap.allocationByteCount.toLong() > 4L * maximumDimension * maximumDimension) {
            bitmap.recycle()
            return null
        }
        return bitmap
    }

    private fun imageBytes(base64: String?): ByteArray? {
        if (base64.isNullOrEmpty() || base64.length > encodedLength(MAXIMUM_FILE_BYTES)) return null
        return try { Base64.getDecoder().decode(base64) } catch (_: IllegalArgumentException) { null }
    }

    suspend fun previewBitmap(base64: String?): Bitmap? = withContext(thumbnailDispatcher) {
        imageBytes(base64)?.let { decodeBoundedImage(it, THUMBNAIL_DIMENSION) }
    }

    fun validateRestoredImages(attachments: List<MessageAttachment>): List<MessageAttachment> {
        var remainingImages = MAXIMUM_ATTACHMENT_COUNT
        var remainingBytes = MAXIMUM_PAYLOAD_BYTES
        return attachments.map { attachment ->
            val encoded = attachment.dataBase64
            if (attachment.kind != AttachmentKind.IMAGE || encoded == null) return@map attachment
            if (remainingImages > 0 && encoded.length <= remainingBytes) {
                val data = imageBytes(encoded)
                if (data != null && data.size <= MAXIMUM_FILE_BYTES && imageBounds(data) != null) {
                    remainingImages--
                    remainingBytes -= encoded.length
                    return@map attachment
                }
            }
            attachment.copy(dataBase64 = null)
        }
    }

    fun processImageBytes(data: ByteArray, suggestedName: String = "image.jpg",
                          maximumPayload: Long = MAXIMUM_PAYLOAD_BYTES.toLong()): MessageAttachment? {
        val decoded = decodeBoundedImage(data, MAX_IMAGE_DIMENSION * 2) ?: return null
        val finalBitmap = downscaleIfNeeded(decoded, MAX_IMAGE_DIMENSION)
        val out = ByteArrayOutputStream()
        if (!finalBitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)) {
            if (finalBitmap !== decoded) finalBitmap.recycle()
            decoded.recycle()
            return null
        }
        val jpegBytes = out.toByteArray()
        if (finalBitmap !== decoded) finalBitmap.recycle()
        decoded.recycle()
        if (encodedLength(jpegBytes.size) > maximumPayload) throw AttachmentException.LimitExceeded()

        val jpegName = if (suggestedName.contains('.')) {
            suggestedName.substringBeforeLast('.') + ".jpg"
        } else {
            "$suggestedName.jpg"
        }
        return MessageAttachment(
            kind = AttachmentKind.IMAGE,
            fileName = jpegName,
            mimeType = "image/jpeg",
            dataBase64 = Base64.getEncoder().encodeToString(jpegBytes),
            extractedText = null,
            byteSize = jpegBytes.size
        )
    }

    private fun downscaleIfNeeded(bitmap: Bitmap, maxDimension: Int): Bitmap {
        val longest = max(bitmap.width, bitmap.height)
        if (longest <= maxDimension || longest <= 0) return bitmap
        val scale = maxDimension.toDouble() / longest.toDouble()
        val w = max(1, floor(bitmap.width * scale).roundToInt())
        val h = max(1, floor(bitmap.height * scale).roundToInt())
        return bitmap.scale(w, h)
    }

    private fun decodePlainTextOrThrow(data: ByteArray): String {
        val hasUtf16Bom = data.size >= 2 && (
            (data[0] == 0xFF.toByte() && data[1] == 0xFE.toByte()) ||
                (data[0] == 0xFE.toByte() && data[1] == 0xFF.toByte())
            )
        if (hasUtf16Bom) {
            val utf16 = String(data, StandardCharsets.UTF_16)
            if (!utf16.contains('\u0000')) return utf16
        }
        val sampleLimit = minOf(data.size, 8192)
        for (i in 0 until sampleLimit) {
            if (data[i].toInt() == 0) throw AttachmentException.UnsupportedBinary()
        }
        val utf8 = String(data.copyOfRange(0, minOf(data.size, 400_000)), StandardCharsets.UTF_8)
        if (utf8.contains('\u0000')) throw AttachmentException.UnsupportedBinary()
        return utf8
    }

    private fun fitUtf8Prefix(text: String, maxBytes: Int): String {
        if (maxBytes <= 0 || text.isEmpty()) return ""
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return text
        var end = maxBytes
        // Step backward over UTF-8 continuation bytes (10xxxxxx) so we never cut a multi-byte rune in half.
        while (end > 0 && (bytes[end - 1].toInt() and 0xC0) == 0x80) {
            end--
        }
        if (end > 0 && (bytes[end - 1].toInt() and 0x80) != 0) {
            // Check whether the leading byte at (end - 1) or earlier needs trimming; rewind to clean character boundary.
            var start = end - 1
            while (start > 0 && (bytes[start].toInt() and 0xC0) == 0x80) start--
            val lead = bytes[start].toInt() and 0xFF
            val seqLen = when {
                (lead and 0x80) == 0 -> 1
                (lead and 0xE0) == 0xC0 -> 2
                (lead and 0xF0) == 0xE0 -> 3
                (lead and 0xF8) == 0xF0 -> 4
                else -> 1
            }
            if (start + seqLen > maxBytes) end = start
        }
        return String(bytes, 0, end, Charsets.UTF_8)
    }

    private fun truncateIfNeeded(text: String): String {
        if (text.length <= MAX_TEXT_CHARACTERS) return text
        val prefix = text.take(MAX_TEXT_CHARACTERS)
        return L10n.text(
            "$prefix\n\n...[文件内容较长，已截取前 $MAX_TEXT_CHARACTERS 个字符]...",
            "$prefix\n\n...[File truncated to the first $MAX_TEXT_CHARACTERS characters]..."
        )
    }

    private fun readBytesLimited(
        contentResolver: ContentResolver, uri: Uri, signal: CancellationSignal?,
        openStream: AtomicReference<InputStream?>?, checkCancellation: () -> Unit
    ): ByteArray {
        val input = if (signal == null) {
            contentResolver.openInputStream(uri) ?: throw AttachmentException.LimitExceeded()
        } else {
            val descriptor = contentResolver.openAssetFileDescriptor(uri, "r", signal)
                ?: throw AttachmentException.ShareReadUnavailable()
            try { descriptor.createInputStream() }
            catch (error: Exception) { descriptor.close(); throw error }
        }
        openStream?.set(input)
        return try { input.use { stream ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(16_384)
            while (true) {
                checkCancellation()
                val read = stream.read(buf)
                if (read <= 0) break
                if (out.size() + read > MAXIMUM_FILE_BYTES) throw AttachmentException.LimitExceeded()
                out.write(buf, 0, read)
            }
            out.toByteArray()
        } } finally { openStream?.compareAndSet(input, null) }
    }

    private fun resolveFileName(contentResolver: ContentResolver, uri: Uri, signal: CancellationSignal?): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, signal)?.use { cursor ->
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
