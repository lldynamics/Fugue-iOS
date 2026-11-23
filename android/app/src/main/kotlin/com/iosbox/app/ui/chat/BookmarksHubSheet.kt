package com.iosbox.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.BookmarkRemove
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.storage.ConversationItem
import com.iosbox.app.core.system.MessageExportRenderer
import com.iosbox.app.core.system.PlainTextFormatter
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

data class BookmarkedEntry(
    val messageId: String,
    val conversationId: String,
    val conversationTitle: String,
    val folderTag: String?,
    val speaker: String,
    val content: String,
    val createdAtEpochMs: Long
)

object BookmarksHubFilter {
    fun availableTags(entries: List<BookmarkedEntry>): List<String> =
        entries.mapNotNull { it.folderTag?.trim()?.takeIf(String::isNotEmpty) }
            .distinct()
            .sorted()

    fun filter(
        entries: List<BookmarkedEntry>,
        query: String,
        tag: String?
    ): List<BookmarkedEntry> {
        val cleanTag = tag?.trim()?.takeIf(String::isNotEmpty)
        val cleanQuery = query.trim()

        return entries
            .filter { entry ->
                if (cleanTag != null && entry.folderTag?.trim() != cleanTag) {
                    return@filter false
                }
                if (cleanQuery.isNotEmpty()) {
                    val matched = entry.content.contains(cleanQuery, ignoreCase = true) ||
                        entry.conversationTitle.contains(cleanQuery, ignoreCase = true) ||
                        entry.speaker.contains(cleanQuery, ignoreCase = true) ||
                        (entry.folderTag?.contains(cleanQuery, ignoreCase = true) == true)
                    if (!matched) return@filter false
                }
                true
            }
            .sortedByDescending { it.createdAtEpochMs }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookmarksHubSheet(
    container: AppContainer,
    conversations: List<ConversationItem>,
    onOpenConversation: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val accent = LocalAccentColors.current

    var searchQuery by remember { mutableStateOf("") }
    var selectedTag by remember { mutableStateOf<String?>(null) }
    var allEntries by remember { mutableStateOf<List<BookmarkedEntry>>(emptyList()) }
    var refreshTick by remember { mutableIntStateOf(0) }

    LaunchedEffect(conversations, refreshTick) {
        val grouped = container.chatRepository.getAllMessagesGroupedByConversation()
        val convById = conversations.associateBy { it.id }
        val built = buildList {
            for ((convId, messages) in grouped) {
                val conv = convById[convId] ?: continue
                for (msg in messages) {
                    val meta = msg.assistanceMetadata
                    if (!meta.isBookmarked || meta.isContextDivider) continue
                    val speaker = when {
                        msg.role == MessageRole.USER -> L10n.text("我", "Me")
                        msg.modelDisplayName.isNotBlank() -> msg.modelDisplayName
                        msg.providerName.isNotBlank() -> msg.providerName
                        else -> L10n.text("助手", "Assistant")
                    }
                    add(
                        BookmarkedEntry(
                            messageId = msg.id,
                            conversationId = convId,
                            conversationTitle = conv.title,
                            folderTag = conv.folderTag,
                            speaker = speaker,
                            content = msg.content,
                            createdAtEpochMs = msg.createdAtEpochMs
                        )
                    )
                }
            }
        }
        allEntries = built
    }

    val availableTags = remember(allEntries) { BookmarksHubFilter.availableTags(allEntries) }
    val filteredEntries = remember(allEntries, searchQuery, selectedTag) {
        BookmarksHubFilter.filter(allEntries, searchQuery, selectedTag)
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 320.dp, max = 640.dp)
                .padding(horizontal = DS.Spacing.lg)
                .padding(bottom = DS.Spacing.xl),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
        ) {
            Text(
                text = L10n.text("跨会话收藏夹", "Saved Bookmarks"),
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
            )

            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                singleLine = true,
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                placeholder = { Text(L10n.text("搜索收藏内容、对话或模型…", "Search bookmarked content…")) },
                modifier = Modifier.fillMaxWidth()
            )

            if (availableTags.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    FilterChip(
                        selected = selectedTag == null,
                        onClick = { selectedTag = null },
                        label = { Text(L10n.text("全部", "All")) }
                    )
                    for (tag in availableTags) {
                        FilterChip(
                            selected = selectedTag == tag,
                            onClick = { selectedTag = if (selectedTag == tag) null else tag },
                            label = { Text(tag) }
                        )
                    }
                }
            }

            if (filteredEntries.isEmpty()) {
                Text(
                    text = if (allEntries.isEmpty()) {
                        L10n.text(
                            "暂无收藏消息。长按对话里的消息或点击书签按钮即可跨会话汇总到这里。",
                            "No bookmarked messages yet."
                        )
                    } else {
                        L10n.text("没有匹配的收藏内容。", "No matching bookmarks.")
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = DS.Spacing.lg)
                )
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm),
                    contentPadding = PaddingValues(bottom = DS.Spacing.md)
                ) {
                    items(filteredEntries, key = { it.messageId }) { entry ->
                        val preview = remember(entry.content) {
                            PlainTextFormatter.toPlainText(entry.content).ifBlank { entry.content }
                        }
                        Card(
                            shape = RoundedCornerShape(DS.Radius.md),
                            colors = CardDefaults.cardColors(
                                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
                            )
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(DS.Spacing.md),
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                ) {
                                    Text(
                                        text = entry.conversationTitle,
                                        style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold),
                                        color = accent.readableText,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    entry.folderTag?.trim()?.takeIf { it.isNotEmpty() }?.let { tag ->
                                        Surface(
                                            shape = RoundedCornerShape(999.dp),
                                            color = accent.softFill
                                        ) {
                                            Text(
                                                text = tag,
                                                style = MaterialTheme.typography.labelSmall,
                                                color = accent.readableText,
                                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                                            )
                                        }
                                    }
                                }

                                Text(
                                    text = "${entry.speaker} · ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(entry.createdAtEpochMs))}",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )

                                Text(
                                    text = preview,
                                    style = MaterialTheme.typography.bodySmall,
                                    maxLines = 4,
                                    overflow = TextOverflow.Ellipsis
                                )

                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    TextButton(onClick = {
                                        onDismiss()
                                        onOpenConversation(entry.conversationId)
                                    }) {
                                        Icon(
                                            imageVector = Icons.AutoMirrored.Filled.OpenInNew,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Spacer(modifier = Modifier.size(4.dp))
                                        Text(L10n.text("打开对话", "Open"))
                                    }

                                    TextButton(onClick = {
                                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                        clipboard.setPrimaryClip(ClipData.newPlainText("Fugue Bookmark", preview))
                                        Toast.makeText(
                                            context,
                                            L10n.text("已复制纯文本", "Copied plain text"),
                                            Toast.LENGTH_SHORT
                                        ).show()
                                    }) {
                                        Icon(
                                            imageVector = Icons.Filled.ContentCopy,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Spacer(modifier = Modifier.size(4.dp))
                                        Text(L10n.text("复制", "Copy"))
                                    }

                                    TextButton(onClick = {
                                        scope.launch {
                                            runCatching {
                                                val file = withContext(Dispatchers.IO) {
                                                    MessageExportRenderer.writePdfFile(
                                                        context = context,
                                                        title = entry.conversationTitle,
                                                        speaker = entry.speaker,
                                                        timestampMs = entry.createdAtEpochMs,
                                                        markdown = entry.content
                                                    )
                                                }
                                                MessageExportRenderer.shareFile(context, file, "application/pdf")
                                            }.onFailure { err ->
                                                Toast.makeText(
                                                    context,
                                                    err.message ?: L10n.text("导出失败", "Export failed"),
                                                    Toast.LENGTH_SHORT
                                                ).show()
                                            }
                                        }
                                    }) {
                                        Icon(
                                            imageVector = Icons.Filled.PictureAsPdf,
                                            contentDescription = null,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Spacer(modifier = Modifier.size(4.dp))
                                        Text("PDF")
                                    }

                                    Spacer(modifier = Modifier.weight(1f))

                                    IconButton(onClick = {
                                        scope.launch {
                                            container.chatRepository.updateMessageMetadata(entry.messageId) { current ->
                                                current.copy(isBookmarked = false)
                                            }
                                            refreshTick += 1
                                        }
                                    }) {
                                        Icon(
                                            imageVector = Icons.Filled.BookmarkRemove,
                                            contentDescription = L10n.text("取消收藏", "Remove Bookmark"),
                                            tint = MaterialTheme.colorScheme.error
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
