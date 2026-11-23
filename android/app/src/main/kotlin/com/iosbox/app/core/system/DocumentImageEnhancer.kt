package com.iosbox.app.core.system

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import androidx.core.graphics.createBitmap
import com.iosbox.app.core.model.L10n
import java.io.File
import java.io.FileOutputStream

object DocumentScanFilter {
    fun enhanceLumaScalar(luma: Int): Int {
        val clamped = luma.coerceIn(0, 255)
        if (clamped >= 195) return 255
        if (clamped <= 55) return (clamped * 0.45f).toInt().coerceIn(0, 255)
        val t = (clamped - 55f) / 140f
        return (24f + t * 231f).toInt().coerceIn(0, 255)
    }

    fun enhancePixelLuma(argb: Int): Int {
        val alpha = (argb ushr 24) and 0xFF
        val r = (argb ushr 16) and 0xFF
        val g = (argb ushr 8) and 0xFF
        val b = argb and 0xFF
        val luma = ((299 * r + 587 * g + 114 * b) / 1000).coerceIn(0, 255)
        val out = enhanceLumaScalar(luma)
        return (alpha shl 24) or (out shl 16) or (out shl 8) or out
    }

    fun buildDocumentScanPrompt(existingInput: String): String {
        val prompt = L10n.text(
            "请逐字提取图片中的全部文字与表格内容（保持原排版与数字准确），并整理核心要点。",
            "Extract all text and tables verbatim from these images, preserving numbers and structure, then summarize key takeaways."
        )
        val trimmed = existingInput.trim()
        if (trimmed.isEmpty()) return prompt
        if (trimmed.contains(prompt)) return existingInput
        return "$prompt\n\n$trimmed"
    }
}

object DocumentImageEnhancer {
    private const val MAX_EDGE_PX = 2000

    fun enhanceCapturedFile(file: File): Boolean {
        if (!file.exists() || file.length() == 0L) return false

        val decoded = runCatching { decodeBoundedBitmap(file) }.getOrNull() ?: return false
        val width = decoded.width
        val height = decoded.height
        if (width <= 0 || height <= 0) {
            decoded.recycle()
            return false
        }

        val pixels = IntArray(width * height)
        decoded.getPixels(pixels, 0, width, 0, 0, width, height)
        decoded.recycle()

        for (i in pixels.indices) {
            pixels[i] = DocumentScanFilter.enhancePixelLuma(pixels[i])
        }

        val output = createBitmap(width, height, Bitmap.Config.ARGB_8888)
        output.setPixels(pixels, 0, width, 0, 0, width, height)
        return try {
            FileOutputStream(file).use { stream ->
                output.compress(Bitmap.CompressFormat.JPEG, 90, stream)
            }
            true
        } catch (_: Throwable) {
            false
        } finally {
            output.recycle()
        }
    }

    private fun decodeBoundedBitmap(file: File): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val source = ImageDecoder.createSource(file)
            return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val w = info.size.width
                val h = info.size.height
                val longest = maxOf(w, h)
                if (longest > MAX_EDGE_PX && w > 0 && h > 0) {
                    val scale = MAX_EDGE_PX.toFloat() / longest
                    decoder.setTargetSize(
                        (w * scale).toInt().coerceAtLeast(1),
                        (h * scale).toInt().coerceAtLeast(1)
                    )
                }
            }
        }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        val srcW = bounds.outWidth
        val srcH = bounds.outHeight
        if (srcW <= 0 || srcH <= 0) return null

        var sampleSize = 1
        val longest = maxOf(srcW, srcH)
        while (longest / sampleSize > MAX_EDGE_PX) {
            sampleSize *= 2
        }

        val decodeOpts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeFile(file.absolutePath, decodeOpts)
    }
}
