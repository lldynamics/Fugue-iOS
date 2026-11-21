package com.iosbox.app.core.storage

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.graphics.scale
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.util.Base64
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt

sealed class AttachmentException(override val message: String) : Exception(message) {
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
            "不支持的二进制文件格式，请选择图片、PDF 或纯文本/代码文件。",
            "Unsupported binary file format. Please choose an image, PDF, or plain text/code file."
        )
    )
}

object AttachmentProcessor {
    const val MAXIMUM_FILE_BYTES = 20 * 1024 * 1024
    const val MAXIMUM_ATTACHMENT_COUNT = 8
    const val MAXIMUM_PAYLOAD_BYTES = 32 * 1024 * 1024
    private const val MAX_IMAGE_DIMENSION = 1600
    private const val JPEG_QUALITY = 82
    private const val MAX_TEXT_CHARACTERS = 80_000
    private const val MAX_INLINE_PDF_BYTES = 8 * 1024 * 1024

    fun validate(attachments: List<MessageAttachment>) {
        if (attachments.size > MAXIMUM_ATTACHMENT_COUNT) throw AttachmentException.LimitExceeded()
        var remaining = MAXIMUM_PAYLOAD_BYTES
        for (item in attachments) {
            val size = (item.dataBase64?.toByteArray(Charsets.UTF_8)?.size ?: 0) +
                (item.extractedText?.toByteArray(Charsets.UTF_8)?.size ?: 0)
            if (size > remaining) throw AttachmentException.LimitExceeded()
            remaining -= size
        }
    }

    fun processUri(
        contentResolver: ContentResolver,
        uri: Uri,
        imageOnly: Boolean = false
    ): MessageAttachment {
        val fileName = resolveFileName(contentResolver, uri) ?: if (imageOnly) "image.jpg" else "file"
        val rawMime = contentResolver.getType(uri)?.lowercase()
        val ext = fileName.substringAfterLast('.', "").lowercase()
        val bytes = readBytesLimited(contentResolver, uri)

        val isImage = imageOnly ||
            rawMime?.startsWith("image/") == true ||
            ext in setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "gif")
        if (isImage) {
            return processImageBytes(bytes, suggestedName = fileName)
                ?: throw AttachmentException.UnreadableImage()
        }

        if (rawMime == "application/pdf" || ext == "pdf") {
            val base64 = if (bytes.size <= MAX_INLINE_PDF_BYTES) {
                Base64.getEncoder().encodeToString(bytes)
            } else {
                null
            }
            val note = if (base64 == null) {
                L10n.text(
                    "[PDF 文件超过 8 MB 内联上限，当前未附加原始 PDF 数据]",
                    "[PDF exceeds the 8 MB inline attachment cap]"
                )
            } else {
                null
            }
            return MessageAttachment(
                kind = AttachmentKind.DOCUMENT,
                fileName = fileName,
                mimeType = "application/pdf",
                dataBase64 = base64,
                extractedText = note,
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

    fun processImageBytes(data: ByteArray, suggestedName: String = "image.jpg"): MessageAttachment? {
        if (data.isEmpty() || data.size > MAXIMUM_FILE_BYTES) return null
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, boundsOpts)
        if (boundsOpts.outWidth <= 0 || boundsOpts.outHeight <= 0) return null

        val longest = max(boundsOpts.outWidth, boundsOpts.outHeight)
        var sampleSize = 1
        while (longest / sampleSize > MAX_IMAGE_DIMENSION * 2) {
            sampleSize *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, decodeOpts) ?: return null
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

    private fun truncateIfNeeded(text: String): String {
        if (text.length <= MAX_TEXT_CHARACTERS) return text
        val prefix = text.take(MAX_TEXT_CHARACTERS)
        return L10n.text(
            "$prefix\n\n...[文件内容较长，已截取前 $MAX_TEXT_CHARACTERS 个字符]...",
            "$prefix\n\n...[File truncated to the first $MAX_TEXT_CHARACTERS characters]..."
        )
    }

    private fun readBytesLimited(contentResolver: ContentResolver, uri: Uri): ByteArray {
        val input = contentResolver.openInputStream(uri) ?: throw AttachmentException.LimitExceeded()
        return input.use { stream ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(16_384)
            while (true) {
                val read = stream.read(buf)
                if (read <= 0) break
                if (out.size() + read > MAXIMUM_FILE_BYTES) throw AttachmentException.LimitExceeded()
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
