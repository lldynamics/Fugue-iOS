package com.iosbox.app.ui.books

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Face
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.BookVolumeItem
import com.iosbox.app.core.storage.ShelfReadingStateItem
import com.iosbox.app.ui.theme.DS

@Composable
fun ReadingShelfSection(
    books: List<BookVolumeItem>,
    shelfStates: List<ShelfReadingStateItem>,
    onReadBook: (BookVolumeItem) -> Unit,
    onOpenCompanion: (BookVolumeItem) -> Unit,
    onCreateBookFriend: (BookVolumeItem) -> Unit,
    onDeleteBook: (BookVolumeItem) -> Unit
) {
    val stateByBook = remember(shelfStates) {
        shelfStates.associateBy { it.bookID.uppercase() }
    }
    var deleteCandidate by remember { mutableStateOf<BookVolumeItem?>(null) }

    if (books.isEmpty()) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(DS.Spacing.xl),
            contentAlignment = Alignment.Center
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Book,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(36.dp)
                )
                Text(
                    text = L10n.text(
                        "点击右下角 + 导入 EPUB / TXT / Markdown 书籍。",
                        "Tap + to import an EPUB, TXT, or Markdown book."
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = L10n.text(
                        "支持原文沉浸阅读、伴读对话、对话知识库引用，以及生成《红楼梦》《三体》等书中好友。",
                        "Supports immersive reading, reading companions, local RAG citations, and Book Friends."
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    } else {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = DS.Spacing.lg,
                end = DS.Spacing.lg,
                top = DS.Spacing.sm,
                bottom = 88.dp
            ),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            items(books, key = { it.id }) { book ->
                val state = stateByBook[book.id.uppercase()]
                val chapterLabel = state?.let { s ->
                    book.chapterTitles.getOrNull(s.chapter)
                }
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onReadBook(book) }
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.AutoStories,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(26.dp)
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = book.title,
                                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                val meta = buildList {
                                    add(L10n.text("共 ${book.chapterTitles.size} 节", "${book.chapterTitles.size} sections"))
                                    add(book.formattedSize)
                                    if (chapterLabel != null) {
                                        add(L10n.text("读至 $chapterLabel", "At $chapterLabel"))
                                    }
                                }.joinToString(" · ")
                                Text(
                                    text = meta,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                            IconButton(onClick = { deleteCandidate = book }) {
                                Icon(
                                    imageVector = Icons.Filled.Delete,
                                    contentDescription = L10n.text("从书架移除", "Remove Book"),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            OutlinedButton(
                                onClick = { onReadBook(book) },
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                            ) {
                                Icon(Icons.Filled.AutoStories, contentDescription = null, modifier = Modifier.size(15.dp))
                                Spacer(modifier = Modifier.size(5.dp))
                                Text(L10n.text("阅读原文", "Read"), style = MaterialTheme.typography.labelMedium)
                            }
                            Button(
                                onClick = { onOpenCompanion(book) },
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                            ) {
                                Icon(Icons.Filled.Forum, contentDescription = null, modifier = Modifier.size(15.dp))
                                Spacer(modifier = Modifier.size(5.dp))
                                Text(L10n.text("开启伴读", "Companion"), style = MaterialTheme.typography.labelMedium)
                            }
                            OutlinedButton(
                                onClick = { onCreateBookFriend(book) },
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                            ) {
                                Icon(Icons.Filled.Face, contentDescription = null, modifier = Modifier.size(15.dp))
                                Spacer(modifier = Modifier.size(5.dp))
                                Text(L10n.text("书中好友", "Book Friend"), style = MaterialTheme.typography.labelMedium)
                            }
                        }
                    }
                }
            }
        }
    }

    deleteCandidate?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            title = { Text(L10n.text("从书架移除《${target.title}》？", "Remove \"${target.title}\"?")) },
            text = {
                Text(
                    L10n.text(
                        "已有聊天记录和引用卡片会保留。如需继续查阅原文或与书中角色聊天，可随时重新导入同一文件。",
                        "Existing chats and citations are preserved. You can re-import this book at any time."
                    )
                )
            },
            confirmButton = {
                Button(onClick = {
                    val item = target
                    deleteCandidate = null
                    onDeleteBook(item)
                }) {
                    Text(L10n.text("移除", "Remove"))
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteCandidate = null }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }
}
