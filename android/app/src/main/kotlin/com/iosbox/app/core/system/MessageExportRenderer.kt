package com.iosbox.app.core.system

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.StaticLayout
import android.text.TextPaint
import androidx.core.content.FileProvider
import androidx.core.graphics.createBitmap
import androidx.core.graphics.withTranslation
import com.iosbox.app.core.model.L10n
import java.io.File
import java.io.FileOutputStream
import java.text.DateFormat
import java.util.Date
import java.util.UUID

sealed interface ExportBlock {
    data class Heading(val level: Int, val text: String) : ExportBlock
    data class CodeBlock(val language: String, val code: String) : ExportBlock
    data class Quote(val text: String) : ExportBlock
    data class Bullet(val marker: String, val text: String) : ExportBlock
    data object Divider : ExportBlock
    data class Paragraph(val text: String) : ExportBlock
}

object MessageExportLayout {
    fun parseBlocks(markdown: String): List<ExportBlock> {
        val normalized = markdown.replace("\r\n", "\n").replace('\r', '\n')
        val lines = normalized.split('\n')
        val blocks = ArrayList<ExportBlock>()
        val paragraphBuffer = ArrayList<String>()
        val quoteBuffer = ArrayList<String>()

        fun flushParagraph() {
            val joined = paragraphBuffer.joinToString("\n").trim()
            if (joined.isNotEmpty()) {
                blocks.add(ExportBlock.Paragraph(cleanInline(joined)))
            }
            paragraphBuffer.clear()
        }

        fun flushQuote() {
            val joined = quoteBuffer.joinToString("\n").trim()
            if (joined.isNotEmpty()) {
                blocks.add(ExportBlock.Quote(cleanInline(joined)))
            }
            quoteBuffer.clear()
        }

        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            val trimmed = line.trim()

            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                flushParagraph()
                flushQuote()
                val fence = if (trimmed.startsWith("```")) "```" else "~~~"
                val lang = trimmed.drop(3).trim()
                val codeLines = ArrayList<String>()
                index++
                while (index < lines.size) {
                    val candidate = lines[index]
                    if (candidate.trim().startsWith(fence)) {
                        index++
                        break
                    }
                    codeLines.add(candidate)
                    index++
                }
                blocks.add(ExportBlock.CodeBlock(lang, codeLines.joinToString("\n")))
                continue
            }

            if (trimmed.isEmpty()) {
                flushParagraph()
                flushQuote()
                index++
                continue
            }

            if (isDivider(trimmed)) {
                flushParagraph()
                flushQuote()
                blocks.add(ExportBlock.Divider)
                index++
                continue
            }

            val heading = parseHeading(trimmed)
            if (heading != null) {
                flushParagraph()
                flushQuote()
                blocks.add(ExportBlock.Heading(heading.first, cleanInline(heading.second)))
                index++
                continue
            }

            if (trimmed.startsWith(">")) {
                flushParagraph()
                var body = trimmed.drop(1)
                if (body.startsWith(" ")) body = body.drop(1)
                quoteBuffer.add(body)
                index++
                continue
            } else if (quoteBuffer.isNotEmpty()) {
                flushQuote()
            }

            val bullet = parseBullet(trimmed)
            if (bullet != null) {
                flushParagraph()
                blocks.add(ExportBlock.Bullet(bullet.first, cleanInline(bullet.second)))
                index++
                continue
            }

            paragraphBuffer.add(line)
            index++
        }

        flushParagraph()
        flushQuote()
        return blocks
    }

    private fun parseHeading(line: String): Pair<Int, String>? {
        var hashes = 0
        while (hashes < line.length && line[hashes] == '#') {
            hashes++
        }
        if (hashes !in 1..6 || hashes >= line.length || line[hashes] != ' ') return null
        return hashes to line.substring(hashes + 1).trim()
    }

    private fun parseBullet(line: String): Pair<String, String>? {
        if (line.startsWith("- ") || line.startsWith("* ") || line.startsWith("+ ")) {
            return "•" to line.substring(2).trim()
        }
        val dot = line.indexOf('.')
        if (dot > 0 && dot + 1 < line.length && line[dot + 1] == ' ') {
            val prefix = line.substring(0, dot)
            if (prefix.all { it.isDigit() }) {
                return "$prefix." to line.substring(dot + 2).trim()
            }
        }
        return null
    }

    private fun isDivider(trimmed: String): Boolean {
        val compact = trimmed.filter { !it.isWhitespace() }
        if (compact.length < 3) return false
        return compact.all { it == '-' } || compact.all { it == '*' } || compact.all { it == '_' }
    }

    private fun cleanInline(raw: String): String {
        val formatted = PlainTextFormatter.toPlainText(raw)
        return formatted.ifEmpty { raw }
    }
}

object MessageExportRenderer {
    private const val PDF_WIDTH = 595
    private const val PDF_HEIGHT = 842
    private const val CARD_WIDTH = 1080
    private const val SHARE_CARD_CHAR_CAP = 3600

    fun writePdfFile(
        context: Context,
        title: String,
        speaker: String,
        timestampMs: Long,
        markdown: String
    ): File {
        val blocks = MessageExportLayout.parseBlocks(markdown)
        val doc = PdfDocument()
        val marginX = 44f
        val topY = 44f
        val bottomLimit = PDF_HEIGHT - 50f
        val contentWidth = (PDF_WIDTH - marginX * 2).toInt()

        val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF111827.toInt()
            textSize = 18f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val subtitlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF6B7280.toInt()
            textSize = 10.5f
        }
        val headingPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF111827.toInt()
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val bodyPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF1F2937.toInt()
            textSize = 11.5f
        }
        val quotePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF4B5563.toInt()
            textSize = 11f
        }
        val codePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF111827.toInt()
            textSize = 9.5f
            typeface = Typeface.MONOSPACE
        }
        val langPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF6B7280.toInt()
            textSize = 8.5f
            typeface = Typeface.MONOSPACE
        }
        val footerPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF9CA3AF.toInt()
            textSize = 9f
        }
        val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFE5E7EB.toInt()
            strokeWidth = 1f
        }
        val codeBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFF3F4F6.toInt()
            style = Paint.Style.FILL
        }
        val accentStripePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF3F6EF6.toInt()
            style = Paint.Style.FILL
        }

        var pageNumber = 0
        var currentPage: PdfDocument.Page? = null
        var canvas: Canvas? = null
        var cursorY = topY

        fun finishCurrentPage() {
            val activePage = currentPage ?: return
            val activeCanvas = canvas ?: return
            val footerText = L10n.text("夜奔 (Fugue) · 第 $pageNumber 页", "Fugue · Page $pageNumber")
            val textWidth = footerPaint.measureText(footerText)
            activeCanvas.drawText(footerText, PDF_WIDTH - marginX - textWidth, PDF_HEIGHT - 26f, footerPaint)
            doc.finishPage(activePage)
            currentPage = null
            canvas = null
        }

        fun startPage() {
            finishCurrentPage()
            pageNumber++
            val pageInfo = PdfDocument.PageInfo.Builder(PDF_WIDTH, PDF_HEIGHT, pageNumber).create()
            val page = doc.startPage(pageInfo)
            currentPage = page
            canvas = page.canvas
            cursorY = topY
        }

        fun ensureSpace(neededHeight: Float) {
            if (cursorY + neededHeight > bottomLimit && cursorY > topY + 8f) {
                startPage()
            }
        }

        fun drawLayoutPaginated(layout: StaticLayout, startX: Float, paint: TextPaint) {
            for (lineIdx in 0 until layout.lineCount) {
                val lineHeight = (layout.getLineBottom(lineIdx) - layout.getLineTop(lineIdx)).toFloat()
                ensureSpace(lineHeight)
                val lineText = layout.text.subSequence(layout.getLineStart(lineIdx), layout.getLineEnd(lineIdx)).toString()
                val baselineOffset = (layout.getLineBaseline(lineIdx) - layout.getLineTop(lineIdx)).toFloat()
                canvas?.drawText(lineText, startX, cursorY + baselineOffset, paint)
                cursorY += lineHeight
            }
        }

        try {
            startPage()
            val resolvedTitle = title.trim().ifEmpty { L10n.text("夜奔 · 精选回复", "Fugue · Response") }
            val titleLayout = StaticLayout.Builder.obtain(resolvedTitle, 0, resolvedTitle.length, titlePaint, contentWidth)
                .setLineSpacing(2f, 1.15f)
                .build()
            drawLayoutPaginated(titleLayout, marginX, titlePaint)
            cursorY += 4f

            val dateStr = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(timestampMs))
            val subText = listOf(speaker.trim(), dateStr).filter { it.isNotEmpty() }.joinToString("  ·  ")
            if (subText.isNotEmpty()) {
                canvas?.drawText(subText, marginX, cursorY + 11f, subtitlePaint)
                cursorY += 18f
            }
            canvas?.drawLine(marginX, cursorY + 4f, PDF_WIDTH - marginX, cursorY + 4f, linePaint)
            cursorY += 18f

            for (block in blocks) {
                when (block) {
                    is ExportBlock.Heading -> {
                        headingPaint.textSize = when (block.level) {
                            1 -> 15.5f
                            2 -> 13.8f
                            else -> 12.2f
                        }
                        val layout = StaticLayout.Builder.obtain(block.text, 0, block.text.length, headingPaint, contentWidth)
                            .setLineSpacing(2f, 1.15f)
                            .build()
                        ensureSpace(layout.height.toFloat() + 6f)
                        cursorY += 4f
                        drawLayoutPaginated(layout, marginX, headingPaint)
                        cursorY += 6f
                    }
                    is ExportBlock.Paragraph -> {
                        val layout = StaticLayout.Builder.obtain(block.text, 0, block.text.length, bodyPaint, contentWidth)
                            .setLineSpacing(3f, 1.2f)
                            .build()
                        drawLayoutPaginated(layout, marginX, bodyPaint)
                        cursorY += 8f
                    }
                    is ExportBlock.Bullet -> {
                        val indent = 18f
                        val layout = StaticLayout.Builder.obtain(block.text, 0, block.text.length, bodyPaint, (contentWidth - indent).toInt())
                            .setLineSpacing(2.5f, 1.18f)
                            .build()
                        val firstLineH = if (layout.lineCount > 0) (layout.getLineBottom(0) - layout.getLineTop(0)).toFloat() else 16f
                        ensureSpace(firstLineH)
                        val baseline = if (layout.lineCount > 0) (layout.getLineBaseline(0) - layout.getLineTop(0)).toFloat() else 12f
                        canvas?.drawText(block.marker, marginX + 2f, cursorY + baseline, subtitlePaint)
                        drawLayoutPaginated(layout, marginX + indent, bodyPaint)
                        cursorY += 5f
                    }
                    is ExportBlock.Quote -> {
                        val padX = 12f
                        val padY = 8f
                        val layout = StaticLayout.Builder.obtain(block.text, 0, block.text.length, quotePaint, (contentWidth - padX - 8f).toInt())
                            .setLineSpacing(2.5f, 1.18f)
                            .build()
                        val boxH = layout.height + padY * 2
                        if (boxH <= (bottomLimit - topY)) {
                            ensureSpace(boxH + 6f)
                            val rect = RectF(marginX, cursorY, PDF_WIDTH - marginX, cursorY + boxH)
                            canvas?.drawRoundRect(rect, 6f, 6f, codeBgPaint)
                            canvas?.drawRoundRect(RectF(marginX, cursorY, marginX + 3.5f, cursorY + boxH), 2f, 2f, accentStripePaint)
                            cursorY += padY
                            drawLayoutPaginated(layout, marginX + padX, quotePaint)
                            cursorY += padY + 8f
                        } else {
                            drawLayoutPaginated(layout, marginX + padX, quotePaint)
                            cursorY += 8f
                        }
                    }
                    is ExportBlock.CodeBlock -> {
                        val pad = 10f
                        val langH = if (block.language.isNotEmpty()) 14f else 0f
                        val codeLayout = StaticLayout.Builder.obtain(block.code, 0, block.code.length, codePaint, (contentWidth - pad * 2).toInt())
                            .setLineSpacing(2f, 1.1f)
                            .build()
                        val boxH = codeLayout.height + pad * 2 + langH
                        if (boxH <= (bottomLimit - topY)) {
                            ensureSpace(boxH + 8f)
                            val rect = RectF(marginX, cursorY, PDF_WIDTH - marginX, cursorY + boxH)
                            canvas?.drawRoundRect(rect, 7f, 7f, codeBgPaint)
                            cursorY += pad
                            if (block.language.isNotEmpty()) {
                                canvas?.drawText(block.language.uppercase(), marginX + pad, cursorY + 8f, langPaint)
                                cursorY += langH
                            }
                            drawLayoutPaginated(codeLayout, marginX + pad, codePaint)
                            cursorY += pad + 8f
                        } else {
                            drawLayoutPaginated(codeLayout, marginX + pad, codePaint)
                            cursorY += 8f
                        }
                    }
                    ExportBlock.Divider -> {
                        ensureSpace(14f)
                        cursorY += 5f
                        canvas?.drawLine(marginX, cursorY, PDF_WIDTH - marginX, cursorY, linePaint)
                        cursorY += 9f
                    }
                }
            }

            finishCurrentPage()
            val file = newExportFile(context, resolvedTitle, "pdf")
            FileOutputStream(file).use { out ->
                doc.writeTo(out)
            }
            return file
        } finally {
            doc.close()
        }
    }

    fun writeShareCardPngFile(
        context: Context,
        title: String,
        speaker: String,
        timestampMs: Long,
        markdown: String
    ): File {
        val capped = if (markdown.length > SHARE_CARD_CHAR_CAP) {
            markdown.take(SHARE_CARD_CHAR_CAP) + "\n\n…"
        } else {
            markdown
        }
        val blocks = MessageExportLayout.parseBlocks(capped)
        val margin = 56f
        val innerWidth = (CARD_WIDTH - margin * 2).toInt()

        val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF111827.toInt()
            textSize = 40f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val subPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF6B7280.toInt()
            textSize = 24f
        }
        val headingPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF111827.toInt()
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val bodyPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF1F2937.toInt()
            textSize = 29f
        }
        val quotePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF4B5563.toInt()
            textSize = 27f
        }
        val codePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF111827.toInt()
            textSize = 24f
            typeface = Typeface.MONOSPACE
        }
        val dividerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFE5E7EB.toInt()
            strokeWidth = 2f
        }
        val cardBoxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFF3F4F6.toInt()
            style = Paint.Style.FILL
        }
        val accentPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF3F6EF6.toInt()
            style = Paint.Style.FILL
        }

        val resolvedTitle = title.trim().ifEmpty { L10n.text("夜奔 · 精选回复", "Fugue · Response") }
        val titleLayout = StaticLayout.Builder.obtain(resolvedTitle, 0, resolvedTitle.length, titlePaint, innerWidth)
            .setLineSpacing(4f, 1.15f).build()
        val dateStr = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(timestampMs))
        val subText = listOf(speaker.trim(), dateStr).filter { it.isNotEmpty() }.joinToString(" · ")

        data class PreparedBlock(
            val kind: ExportBlock,
            val layout: StaticLayout? = null
        )

        val prepared = blocks.map { block ->
            when (block) {
                is ExportBlock.Heading -> {
                    val p = TextPaint(headingPaint).apply {
                        textSize = if (block.level == 1) 36f else if (block.level == 2) 33f else 30f
                    }
                    PreparedBlock(block, StaticLayout.Builder.obtain(block.text, 0, block.text.length, p, innerWidth).setLineSpacing(4f, 1.15f).build())
                }
                is ExportBlock.Paragraph ->
                    PreparedBlock(block, StaticLayout.Builder.obtain(block.text, 0, block.text.length, bodyPaint, innerWidth).setLineSpacing(6f, 1.2f).build())
                is ExportBlock.Bullet ->
                    PreparedBlock(block, StaticLayout.Builder.obtain(block.text, 0, block.text.length, bodyPaint, innerWidth - 42).setLineSpacing(5f, 1.2f).build())
                is ExportBlock.Quote ->
                    PreparedBlock(block, StaticLayout.Builder.obtain(block.text, 0, block.text.length, quotePaint, innerWidth - 52).setLineSpacing(5f, 1.18f).build())
                is ExportBlock.CodeBlock ->
                    PreparedBlock(block, StaticLayout.Builder.obtain(block.code, 0, block.code.length, codePaint, innerWidth - 48).setLineSpacing(4f, 1.12f).build())
                ExportBlock.Divider -> PreparedBlock(block, null)
            }
        }

        var totalHeight = 56f + titleLayout.height + 16f + 36f + 32f
        for (item in prepared) {
            totalHeight += when (item.kind) {
                is ExportBlock.Heading -> (item.layout?.height ?: 0) + 20f
                is ExportBlock.Paragraph -> (item.layout?.height ?: 0) + 20f
                is ExportBlock.Bullet -> (item.layout?.height ?: 0) + 14f
                is ExportBlock.Quote -> (item.layout?.height ?: 0) + 40f + 20f
                is ExportBlock.CodeBlock -> (item.layout?.height ?: 0) + 44f + (if (item.kind.language.isNotEmpty()) 30f else 0f) + 20f
                ExportBlock.Divider -> 28f
            }
        }
        totalHeight += 86f
        val safeHeight = totalHeight.toInt().coerceIn(360, 8192)

        val bitmap = createBitmap(CARD_WIDTH, safeHeight)
        val c = Canvas(bitmap)
        c.drawColor(Color.WHITE)

        var y = 56f
        c.withTranslation(margin, y) {
            titleLayout.draw(this)
        }
        y += titleLayout.height + 10f

        if (subText.isNotEmpty()) {
            c.drawCircle(margin + 10f, y + 18f, 9f, accentPaint)
            c.drawText(subText, margin + 30f, y + 26f, subPaint)
            y += 42f
        }
        c.drawLine(margin, y + 8f, CARD_WIDTH - margin, y + 8f, dividerPaint)
        y += 32f

        for (item in prepared) {
            if (y > safeHeight - 96f) break
            val layout = item.layout
            when (item.kind) {
                is ExportBlock.Heading, is ExportBlock.Paragraph -> {
                    if (layout != null) {
                        c.withTranslation(margin, y) {
                            layout.draw(this)
                        }
                        y += layout.height + 20f
                    }
                }
                is ExportBlock.Bullet -> {
                    if (layout != null) {
                        c.drawText(item.kind.marker, margin + 6f, y + 28f, accentPaint.apply { textSize = 29f })
                        c.withTranslation(margin + 42f, y) {
                            layout.draw(this)
                        }
                        y += layout.height + 14f
                    }
                }
                is ExportBlock.Quote -> {
                    if (layout != null) {
                        val h = layout.height + 36f
                        c.drawRoundRect(RectF(margin, y, CARD_WIDTH - margin, y + h), 16f, 16f, cardBoxPaint)
                        c.drawRoundRect(RectF(margin, y, margin + 8f, y + h), 4f, 4f, accentPaint)
                        c.withTranslation(margin + 30f, y + 18f) {
                            layout.draw(this)
                        }
                        y += h + 20f
                    }
                }
                is ExportBlock.CodeBlock -> {
                    if (layout != null) {
                        val langH = if (item.kind.language.isNotEmpty()) 30f else 0f
                        val h = layout.height + 40f + langH
                        c.drawRoundRect(RectF(margin, y, CARD_WIDTH - margin, y + h), 16f, 16f, cardBoxPaint)
                        var textY = y + 20f
                        if (item.kind.language.isNotEmpty()) {
                            c.drawText(item.kind.language.uppercase(), margin + 24f, textY + 18f, subPaint)
                            textY += langH
                        }
                        c.withTranslation(margin + 24f, textY) {
                            layout.draw(this)
                        }
                        y += h + 20f
                    }
                }
                ExportBlock.Divider -> {
                    c.drawLine(margin, y + 12f, CARD_WIDTH - margin, y + 12f, dividerPaint)
                    y += 28f
                }
            }
        }

        c.drawLine(margin, safeHeight - 68f, CARD_WIDTH - margin, safeHeight - 68f, dividerPaint)
        c.drawText(
            L10n.text("夜奔 (Fugue) · 本地直连 AI", "Fugue · Direct BYOK AI"),
            margin,
            safeHeight - 30f,
            subPaint
        )

        val file = newExportFile(context, resolvedTitle, "png")
        FileOutputStream(file).use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 95, out)
        }
        bitmap.recycle()
        return file
    }

    fun shareFile(context: Context, file: File, mimeType: String) {
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(
            intent,
            L10n.text("分享或保存文件", "Share or Save Export")
        ).apply {
            if (context !is android.app.Activity) {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        context.startActivity(chooser)
    }

    private fun newExportFile(context: Context, title: String, ext: String): File {
        val exportsRoot = File(context.cacheDir, "exports").apply { mkdirs() }
        pruneOldExports(exportsRoot)
        val sanitized = title
            .replace(Regex("""[/\\:?%*|\"<>]"""), "-")
            .trim()
            .trim('.')
            .ifEmpty { "Fugue-Export" }
            .take(40)
        return File(exportsRoot, "${sanitized}_${UUID.randomUUID().toString().take(8)}.$ext")
    }

    private fun pruneOldExports(dir: File) {
        val cutoff = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        dir.listFiles()?.forEach { file ->
            if (file.lastModified() < cutoff) {
                file.delete()
            }
        }
    }
}
