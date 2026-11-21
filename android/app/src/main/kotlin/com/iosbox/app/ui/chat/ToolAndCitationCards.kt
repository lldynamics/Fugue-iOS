package com.iosbox.app.ui.chat

import android.content.Intent
import androidx.compose.foundation.BorderStroke
import androidx.core.net.toUri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Public
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.BookReplyEvidence
import com.iosbox.app.core.model.KnowledgeEvidence
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ReadingCitation
import com.iosbox.app.core.network.SearchEvidence
import com.iosbox.app.core.network.ToolCallRecord
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors

@Composable
internal fun ToolCallsStrip(toolCalls: List<ToolCallRecord>) {
    if (toolCalls.isEmpty()) return
    var expanded by remember(toolCalls.size) {
        mutableStateOf(toolCalls.any { !it.succeeded })
    }
    val accent = LocalAccentColors.current

    Surface(
        shape = RoundedCornerShape(DS.Radius.sm),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(DS.Spacing.sm)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Build,
                    contentDescription = null,
                    tint = accent.readableText,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = L10n.text("工具调用 (${toolCalls.size})", "Tool Calls (${toolCalls.size})"),
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp)
                )
            }

            if (expanded) {
                Spacer(modifier = Modifier.size(6.dp))
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (call in toolCalls) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = if (call.succeeded) Icons.Filled.CheckCircle else Icons.Filled.ErrorOutline,
                                contentDescription = null,
                                tint = if (call.succeeded) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(13.dp)
                            )
                            Text(
                                text = call.name,
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold)
                            )
                            if (call.argumentsSummary.isNotBlank()) {
                                Text(
                                    text = call.argumentsSummary,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f, fill = false)
                                )
                            } else {
                                Spacer(modifier = Modifier.weight(1f))
                            }
                            Text(
                                text = "· ${call.resultSummary}",
                                style = MaterialTheme.typography.labelSmall,
                                color = if (call.succeeded) accent.readableText else MaterialTheme.colorScheme.error,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun SearchCitationsCard(search: SearchEvidence) {
    if (search.sources.isEmpty()) return
    val context = LocalContext.current
    var expanded by remember { mutableStateOf(false) }
    val accent = LocalAccentColors.current

    Surface(
        shape = RoundedCornerShape(DS.Radius.sm),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(DS.Spacing.sm)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Public,
                    contentDescription = null,
                    tint = accent.readableText,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = L10n.text(
                        "联网来源 (${search.sources.size}) · ${search.query}",
                        "Web Sources (${search.sources.size}) · ${search.query}"
                    ),
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp)
                )
            }

            if (expanded) {
                Spacer(modifier = Modifier.size(6.dp))
                search.sources.forEachIndexed { idx, src ->
                    if (idx > 0) {
                        HorizontalDivider(
                            color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f),
                            modifier = Modifier.padding(vertical = 4.dp)
                        )
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                runCatching {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, src.url.toUri()))
                                }
                            }
                            .padding(vertical = 2.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Text(
                            text = "[${src.id}] ${src.title}",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium),
                            color = accent.readableText,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = src.url,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun ProposedMemoriesCard(
    proposed: List<String>,
    handled: List<String>,
    onSave: (String) -> Unit,
    onDismiss: (String) -> Unit
) {
    val pending = remember(proposed, handled) {
        proposed.filterNot { handled.contains(it) }
    }
    if (pending.isEmpty()) return
    val accent = LocalAccentColors.current

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (fact in pending) {
            Surface(
                shape = RoundedCornerShape(DS.Radius.sm),
                color = accent.softFill.copy(alpha = 0.7f),
                border = BorderStroke(1.dp, accent.solidFill.copy(alpha = 0.35f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(DS.Spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Psychology,
                            contentDescription = null,
                            tint = accent.readableText,
                            modifier = Modifier.size(15.dp)
                        )
                        Text(
                            text = L10n.text("记住一条个人偏好？", "Save Personal Memory?"),
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                            color = accent.readableText
                        )
                    }
                    Text(
                        text = fact,
                        style = MaterialTheme.typography.bodySmall
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End
                    ) {
                        TextButton(onClick = { onDismiss(fact) }) {
                            Text(L10n.text("忽略", "Dismiss"), style = MaterialTheme.typography.labelSmall)
                        }
                        Spacer(modifier = Modifier.size(6.dp))
                        Button(onClick = { onSave(fact) }) {
                            Text(L10n.text("记住", "Save"), style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun KnowledgeCitationsCard(
    knowledge: KnowledgeEvidence,
    onOpenCitation: (ReadingCitation) -> Unit
) {
    if (knowledge.passages.isEmpty()) return
    var expanded by remember { mutableStateOf(false) }
    val accent = LocalAccentColors.current

    Surface(
        shape = RoundedCornerShape(DS.Radius.sm),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(DS.Spacing.sm)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.AutoStories,
                    contentDescription = null,
                    tint = accent.readableText,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = L10n.text(
                        "知识库引用 (${knowledge.passages.size} 段 · ${knowledge.uniqueDocumentCount} 卷)",
                        "Knowledge Citations (${knowledge.passages.size} excerpts · ${knowledge.uniqueDocumentCount} docs)"
                    ),
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp)
                )
            }

            if (expanded) {
                Spacer(modifier = Modifier.size(6.dp))
                knowledge.passages.forEachIndexed { idx, p ->
                    if (idx > 0) {
                        HorizontalDivider(
                            color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f),
                            modifier = Modifier.padding(vertical = 4.dp)
                        )
                    }
                    val citation = remember(p) { ReadingCitation.fromPassage(p) }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onOpenCitation(citation) }
                            .padding(vertical = 2.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "[${p.id}] ${p.citationLabel}",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium),
                                color = accent.readableText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            Text(
                                text = L10n.text("查看原文", "Open"),
                                style = MaterialTheme.typography.labelSmall,
                                color = accent.readableText
                            )
                        }
                        Text(
                            text = p.excerpt,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun BookReplyEvidenceCard(
    bookReply: BookReplyEvidence,
    bookID: String,
    onOpenCitation: (ReadingCitation) -> Unit
) {
    if (bookReply.excerpts.isEmpty()) return
    var expanded by remember { mutableStateOf(false) }
    val accent = LocalAccentColors.current

    Surface(
        shape = RoundedCornerShape(DS.Radius.sm),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(modifier = Modifier.padding(DS.Spacing.sm)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.MenuBook,
                    contentDescription = null,
                    tint = accent.readableText,
                    modifier = Modifier.size(14.dp)
                )
                Text(
                    text = L10n.text(
                        "原书依据 (${bookReply.excerpts.size} 段) ·《${bookReply.title}》",
                        "Book Citations (${bookReply.excerpts.size}) · ${bookReply.title}"
                    ),
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp)
                )
            }

            if (expanded) {
                Spacer(modifier = Modifier.size(6.dp))
                bookReply.excerpts.forEachIndexed { idx, ex ->
                    if (idx > 0) {
                        HorizontalDivider(
                            color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f),
                            modifier = Modifier.padding(vertical = 4.dp)
                        )
                    }
                    val citation = remember(ex, bookID) {
                        ReadingCitation.fromExcerpt(ex, bookID, number = idx + 1, documentTitle = bookReply.title)
                    }
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onOpenCitation(citation) }
                            .padding(vertical = 2.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = ex.chapter,
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium),
                                color = accent.readableText,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            Text(
                                text = L10n.text("定位原文", "Locate"),
                                style = MaterialTheme.typography.labelSmall,
                                color = accent.readableText
                            )
                        }
                        Text(
                            text = ex.text,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }
    }
}
