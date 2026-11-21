package com.iosbox.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.iosbox.app.core.model.L10n
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.delay

private sealed interface MarkdownBlock {
    data class Heading(val level: Int, val text: String) : MarkdownBlock
    data class CodeBlock(val language: String, val code: String) : MarkdownBlock
    data class MathBlock(val latex: String) : MarkdownBlock
    data class Blockquote(val lines: List<String>) : MarkdownBlock
    data class BulletList(val items: List<Pair<String, String>>) : MarkdownBlock
    data class Table(val headers: List<String>, val rows: List<List<String>>) : MarkdownBlock
    data object Divider : MarkdownBlock
    data class Paragraph(val text: String) : MarkdownBlock
}

@Composable
fun MarkdownMessageContent(
    markdown: String,
    modifier: Modifier = Modifier
) {
    val blocks = remember(markdown) { parseMarkdownBlocks(markdown) }
    val inlineCodeBg = MaterialTheme.colorScheme.surfaceVariant
    val linkColor = MaterialTheme.colorScheme.primary

    SelectionContainer(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
            for (block in blocks) {
                when (block) {
                    is MarkdownBlock.Heading -> {
                        val style = when (block.level) {
                            1 -> MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                            2 -> MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                            3 -> MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                            else -> MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold)
                        }
                        Text(
                            text = parseInlineMarkdown(block.text, inlineCodeBg, linkColor),
                            style = style,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                    is MarkdownBlock.CodeBlock -> CodeBlockCard(language = block.language, code = block.code)
                    is MarkdownBlock.MathBlock -> MathBlockCard(latex = block.latex)
                    is MarkdownBlock.Blockquote -> {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(DS.Radius.xs))
                                .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f))
                        ) {
                            Box(
                                modifier = Modifier
                                    .padding(vertical = 2.dp)
                                    .size(width = 3.dp, height = 18.dp)
                            )
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = DS.Spacing.md, vertical = DS.Spacing.sm),
                                verticalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                for (line in block.lines) {
                                    Text(
                                        text = parseInlineMarkdown(line, inlineCodeBg, linkColor),
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                    is MarkdownBlock.BulletList -> {
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            for ((marker, text) in block.items) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Text(
                                        text = marker,
                                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                                        color = MaterialTheme.colorScheme.primary
                                    )
                                    Text(
                                        text = parseInlineMarkdown(text, inlineCodeBg, linkColor),
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurface,
                                        modifier = Modifier.weight(1f)
                                    )
                                }
                            }
                        }
                    }
                    is MarkdownBlock.Table -> MarkdownTableView(block, inlineCodeBg, linkColor)
                    MarkdownBlock.Divider -> HorizontalDivider(color = MaterialTheme.colorScheme.outline)
                    is MarkdownBlock.Paragraph -> {
                        Text(
                            text = parseInlineMarkdown(block.text, inlineCodeBg, linkColor),
                            style = MaterialTheme.typography.bodyMedium.copy(lineHeight = 22.sp),
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CodeBlockCard(language: String, code: String) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }
    var showPreview by remember { mutableStateOf(false) }
    val previewable = remember(language) { ArtifactDocumentBuilder.isPreviewable(language) }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }

    if (showPreview) {
        ArtifactPreviewDialog(
            language = language,
            code = code,
            onDismiss = { showPreview = false }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(DS.Radius.sm))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f))
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(DS.Radius.sm))
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(horizontal = DS.Spacing.md, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = language.ifBlank { "code" },
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (previewable) {
                    Surface(
                        onClick = { showPreview = true },
                        shape = RoundedCornerShape(999.dp),
                        color = MaterialTheme.colorScheme.primaryContainer
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.PlayArrow,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.size(13.dp)
                            )
                            Text(
                                text = L10n.text("预览", "Preview"),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer
                            )
                        }
                    }
                }
                IconButton(
                    onClick = {
                        val cm = context.getSystemService(ClipboardManager::class.java)
                        cm?.setPrimaryClip(ClipData.newPlainText("Fugue", code))
                        copied = true
                    },
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                        contentDescription = L10n.text("复制代码", "Copy code"),
                        tint = if (copied) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp)
                    )
                }
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(DS.Spacing.md)
        ) {
            Text(
                text = code,
                style = MaterialTheme.typography.bodySmall.copy(
                    fontFamily = FontFamily.Monospace,
                    lineHeight = 19.sp
                ),
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}

@Composable
private fun MathBlockCard(latex: String) {
    val context = LocalContext.current
    var showRaw by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    val rendered = remember(latex) { MathDisplayFormatter.formatLatexToUnicode(latex) }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(DS.Radius.sm))
            .background(MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.28f))
            .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.25f), RoundedCornerShape(DS.Radius.sm))
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.md, vertical = 3.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Functions,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = if (showRaw) "LaTeX" else L10n.text("公式", "Math"),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary
                )
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                IconButton(
                    onClick = { showRaw = !showRaw },
                    modifier = Modifier.size(26.dp)
                ) {
                    Icon(
                        imageVector = if (showRaw) Icons.Filled.Functions else Icons.Filled.Code,
                        contentDescription = L10n.text("切换源码", "Toggle source"),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp)
                    )
                }
                IconButton(
                    onClick = {
                        val cm = context.getSystemService(ClipboardManager::class.java)
                        cm?.setPrimaryClip(ClipData.newPlainText("LaTeX", latex))
                        copied = true
                    },
                    modifier = Modifier.size(26.dp)
                ) {
                    Icon(
                        imageVector = if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                        contentDescription = L10n.text("复制 LaTeX", "Copy LaTeX"),
                        tint = if (copied) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = DS.Spacing.md, vertical = DS.Spacing.sm)
        ) {
            Text(
                text = if (showRaw) latex else rendered,
                style = if (showRaw) {
                    MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace, lineHeight = 19.sp)
                } else {
                    MaterialTheme.typography.bodyLarge.copy(
                        fontFamily = FontFamily.Serif,
                        lineHeight = 24.sp
                    )
                },
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}

@Composable
private fun MarkdownTableView(
    table: MarkdownBlock.Table,
    inlineCodeBg: Color,
    linkColor: Color
) {
    val cols = maxOf(table.headers.size, table.rows.maxOfOrNull { it.size } ?: 0)
    if (cols == 0) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .clip(RoundedCornerShape(DS.Radius.xs))
            .border(1.dp, MaterialTheme.colorScheme.outline, RoundedCornerShape(DS.Radius.xs))
    ) {
        Row(
            modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant)
        ) {
            for (c in 0 until cols) {
                val cell = table.headers.getOrElse(c) { "" }
                Text(
                    text = parseInlineMarkdown(cell, inlineCodeBg, linkColor),
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                )
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outline)
        table.rows.forEachIndexed { rIdx, row ->
            Row {
                for (c in 0 until cols) {
                    val cell = row.getOrElse(c) { "" }
                    Text(
                        text = parseInlineMarkdown(cell, inlineCodeBg, linkColor),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                    )
                }
            }
            if (rIdx < table.rows.lastIndex) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
            }
        }
    }
}

private fun parseMarkdownBlocks(raw: String): List<MarkdownBlock> {
    if (raw.isEmpty()) return emptyList()
    val lines = raw.replace("\r\n", "\n").split('\n')
    val blocks = mutableListOf<MarkdownBlock>()
    var i = 0

    while (i < lines.size) {
        val line = lines[i]
        val trimmed = line.trim()

        if (trimmed.isEmpty()) {
            i++
            continue
        }

        // Fenced code block
        if (trimmed.startsWith("```")) {
            val lang = trimmed.removePrefix("```").trim()
            val codeLines = mutableListOf<String>()
            i++
            while (i < lines.size && !lines[i].trim().startsWith("```")) {
                codeLines.add(lines[i])
                i++
            }
            if (i < lines.size) i++
            blocks.add(MarkdownBlock.CodeBlock(lang, codeLines.joinToString("\n")))
            continue
        }

        // Display math block: $$...$$ or \[...\]
        if (trimmed.startsWith("$$")) {
            if (trimmed.length >= 4 && trimmed.endsWith("$$")) {
                val latex = trimmed.removePrefix("$$").removeSuffix("$$").trim()
                if (latex.isNotEmpty()) blocks.add(MarkdownBlock.MathBlock(latex))
                i++
                continue
            }
            val mathLines = mutableListOf<String>()
            val firstRest = trimmed.removePrefix("$$").trim()
            if (firstRest.isNotEmpty()) mathLines.add(firstRest)
            i++
            while (i < lines.size && !lines[i].trim().endsWith("$$")) {
                mathLines.add(lines[i])
                i++
            }
            if (i < lines.size) {
                val lastRest = lines[i].trim().removeSuffix("$$").trim()
                if (lastRest.isNotEmpty()) mathLines.add(lastRest)
                i++
            }
            val latex = mathLines.joinToString("\n").trim()
            if (latex.isNotEmpty()) blocks.add(MarkdownBlock.MathBlock(latex))
            continue
        }

        if (trimmed.startsWith("\\[")) {
            if (trimmed.length >= 4 && trimmed.endsWith("\\]")) {
                val latex = trimmed.removePrefix("\\[").removeSuffix("\\]").trim()
                if (latex.isNotEmpty()) blocks.add(MarkdownBlock.MathBlock(latex))
                i++
                continue
            }
            val mathLines = mutableListOf<String>()
            val firstRest = trimmed.removePrefix("\\[").trim()
            if (firstRest.isNotEmpty()) mathLines.add(firstRest)
            i++
            while (i < lines.size && !lines[i].trim().endsWith("\\]")) {
                mathLines.add(lines[i])
                i++
            }
            if (i < lines.size) {
                val lastRest = lines[i].trim().removeSuffix("\\]").trim()
                if (lastRest.isNotEmpty()) mathLines.add(lastRest)
                i++
            }
            val latex = mathLines.joinToString("\n").trim()
            if (latex.isNotEmpty()) blocks.add(MarkdownBlock.MathBlock(latex))
            continue
        }

        // Horizontal rule
        if (trimmed == "---" || trimmed == "***" || trimmed == "___") {
            blocks.add(MarkdownBlock.Divider)
            i++
            continue
        }

        // Heading
        val headingMatch = Regex("^(#{1,6})\\s+(.+)$").matchEntire(trimmed)
        if (headingMatch != null) {
            blocks.add(MarkdownBlock.Heading(headingMatch.groupValues[1].length, headingMatch.groupValues[2]))
            i++
            continue
        }

        // Markdown Table
        if (trimmed.contains('|') && i + 1 < lines.size && isTableSeparator(lines[i + 1].trim())) {
            val headers = splitTableRow(trimmed)
            i += 2
            val rows = mutableListOf<List<String>>()
            while (i < lines.size && lines[i].trim().contains('|') && lines[i].trim().isNotEmpty()) {
                rows.add(splitTableRow(lines[i].trim()))
                i++
            }
            blocks.add(MarkdownBlock.Table(headers, rows))
            continue
        }

        // Blockquote
        if (trimmed.startsWith(">")) {
            val quoteLines = mutableListOf<String>()
            while (i < lines.size && lines[i].trim().startsWith(">")) {
                quoteLines.add(lines[i].trim().removePrefix(">").trimStart())
                i++
            }
            blocks.add(MarkdownBlock.Blockquote(quoteLines))
            continue
        }

        // Bullet or numbered list
        if (isListLine(trimmed)) {
            val items = mutableListOf<Pair<String, String>>()
            while (i < lines.size && isListLine(lines[i].trim())) {
                val cur = lines[i].trim()
                val ordered = Regex("^(\\d+\\.)\\s+(.+)$").matchEntire(cur)
                if (ordered != null) {
                    items.add(ordered.groupValues[1] to ordered.groupValues[2])
                } else {
                    items.add("•" to cur.drop(2).trimStart())
                }
                i++
            }
            blocks.add(MarkdownBlock.BulletList(items))
            continue
        }

        // Regular paragraph
        val para = mutableListOf<String>()
        while (i < lines.size) {
            val curTrim = lines[i].trim()
            if (curTrim.isEmpty() ||
                curTrim.startsWith("```") ||
                curTrim.startsWith("$$") ||
                curTrim.startsWith("\\[") ||
                curTrim.startsWith(">") ||
                curTrim == "---" || curTrim == "***" || curTrim == "___" ||
                Regex("^#{1,6}\\s+.+$").matches(curTrim) ||
                isListLine(curTrim) ||
                (curTrim.contains('|') && i + 1 < lines.size && isTableSeparator(lines[i + 1].trim()))
            ) {
                break
            }
            para.add(lines[i])
            i++
        }
        if (para.isNotEmpty()) {
            blocks.add(MarkdownBlock.Paragraph(para.joinToString("\n")))
        }
    }
    return blocks
}

private fun isListLine(trimmed: String): Boolean =
    trimmed.startsWith("- ") || trimmed.startsWith("* ") || trimmed.startsWith("+ ") ||
        Regex("^\\d+\\.\\s+.+$").matches(trimmed)

private fun isTableSeparator(line: String): Boolean {
    if (!line.contains('-')) return false
    val cleaned = line.trim('|', ' ')
    return cleaned.isNotEmpty() && cleaned.all { it == '-' || it == ':' || it == '|' || it == ' ' }
}

private fun splitTableRow(line: String): List<String> =
    line.trim().trim('|').split('|').map { it.trim() }

private fun parseInlineMarkdown(
    text: String,
    inlineCodeBg: Color,
    linkColor: Color
): AnnotatedString = buildAnnotatedString {
    var i = 0
    while (i < text.length) {
        when {
            text[i] == '`' -> {
                val end = text.indexOf('`', i + 1)
                if (end > i + 1) {
                    withStyle(
                        SpanStyle(
                            fontFamily = FontFamily.Monospace,
                            background = inlineCodeBg,
                            fontSize = 13.sp
                        )
                    ) {
                        append(" ${text.substring(i + 1, end)} ")
                    }
                    i = end + 1
                } else {
                    append(text[i])
                    i++
                }
            }
            text.startsWith("\\(", i) -> {
                val end = text.indexOf("\\)", i + 2)
                if (end > i + 2) {
                    val formatted = MathDisplayFormatter.formatLatexToUnicode(text.substring(i + 2, end))
                    withStyle(
                        SpanStyle(
                            fontFamily = FontFamily.Serif,
                            fontStyle = FontStyle.Italic,
                            background = linkColor.copy(alpha = 0.08f)
                        )
                    ) {
                        append(formatted)
                    }
                    i = end + 2
                } else {
                    append("\\(")
                    i += 2
                }
            }
            text[i] == '$' -> {
                val end = MathDisplayFormatter.findInlineMathEnd(text, i)
                if (end != null && end > i + 1) {
                    val formatted = MathDisplayFormatter.formatLatexToUnicode(text.substring(i + 1, end))
                    withStyle(
                        SpanStyle(
                            fontFamily = FontFamily.Serif,
                            fontStyle = FontStyle.Italic,
                            background = linkColor.copy(alpha = 0.08f)
                        )
                    ) {
                        append(formatted)
                    }
                    i = end + 1
                } else {
                    append(text[i])
                    i++
                }
            }
            text.startsWith("**", i) -> {
                val end = text.indexOf("**", i + 2)
                if (end > i + 2) {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                        append(text.substring(i + 2, end))
                    }
                    i = end + 2
                } else {
                    append("**")
                    i += 2
                }
            }
            text.startsWith("~~", i) -> {
                val end = text.indexOf("~~", i + 2)
                if (end > i + 2) {
                    withStyle(SpanStyle(textDecoration = TextDecoration.LineThrough)) {
                        append(text.substring(i + 2, end))
                    }
                    i = end + 2
                } else {
                    append("~~")
                    i += 2
                }
            }
            text[i] == '*' && !text.startsWith("* ", i) -> {
                val end = text.indexOf('*', i + 1)
                if (end > i + 1) {
                    withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                        append(text.substring(i + 1, end))
                    }
                    i = end + 1
                } else {
                    append(text[i])
                    i++
                }
            }
            text[i] == '[' -> {
                val closeBracket = text.indexOf(']', i + 1)
                val openParen = if (closeBracket > i && closeBracket + 1 < text.length && text[closeBracket + 1] == '(') closeBracket + 1 else -1
                val closeParen = if (openParen > 0) text.indexOf(')', openParen + 1) else -1
                if (closeBracket > i && openParen > 0 && closeParen > openParen) {
                    val label = text.substring(i + 1, closeBracket)
                    withStyle(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)) {
                        append(label)
                    }
                    i = closeParen + 1
                } else {
                    append(text[i])
                    i++
                }
            }
            else -> {
                append(text[i])
                i++
            }
        }
    }
}
