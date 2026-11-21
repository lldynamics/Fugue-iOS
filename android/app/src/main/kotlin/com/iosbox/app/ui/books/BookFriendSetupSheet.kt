package com.iosbox.app.ui.books

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.BookFriend
import com.iosbox.app.core.model.BookReplyEvidence
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.BookReferenceSearch
import com.iosbox.app.core.storage.BookVolumeItem
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookFriendSetupSheet(
    container: AppContainer,
    books: List<BookVolumeItem>,
    initialBook: BookVolumeItem?,
    onStartChat: (BookFriend) -> Unit,
    onDismiss: () -> Unit
) {
    val scope = rememberCoroutineScope()
    var selectedBookID by remember(initialBook?.id, books) {
        mutableStateOf(initialBook?.id ?: books.firstOrNull()?.id)
    }
    val selectedBook = remember(books, selectedBookID) {
        books.firstOrNull { it.id.equals(selectedBookID, ignoreCase = true) } ?: books.firstOrNull()
    }

    var name by remember { mutableStateOf("") }
    var aliases by remember { mutableStateOf("") }
    var throughChapter by remember(selectedBook?.id) { mutableStateOf<Int?>(null) }
    var showBookMenu by remember { mutableStateOf(false) }
    var showChapterMenu by remember { mutableStateOf(false) }

    var isWorking by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var previewEvidence by remember { mutableStateOf<BookReplyEvidence?>(null) }

    val validatedFriend = remember(selectedBook, name, aliases, throughChapter) {
        val book = selectedBook ?: return@remember null
        runCatching {
            BookFriend.make(
                bookID = book.id,
                bookTitle = book.title,
                chapterTitles = book.chapterTitles,
                name = name,
                aliasesRaw = aliases,
                throughChapter = throughChapter
            )
        }.getOrNull()
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DS.Spacing.lg)
                .padding(bottom = DS.Spacing.xxl),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = L10n.text("创建书中好友", "New Book Friend"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(
                    enabled = !isWorking && selectedBook != null && name.trim().isNotEmpty(),
                    onClick = {
                        val book = selectedBook ?: return@Button
                        scope.launch {
                            isWorking = true
                            errorText = null
                            try {
                                val friend = BookFriend.make(
                                    bookID = book.id,
                                    bookTitle = book.title,
                                    chapterTitles = book.chapterTitles,
                                    name = name,
                                    aliasesRaw = aliases,
                                    throughChapter = throughChapter
                                )
                                if (previewEvidence == null) {
                                    val found = withContext(Dispatchers.IO) {
                                        val chapters = container.chatRepository.loadBookChapters(book.id)
                                        BookReferenceSearch.reference(friend, chapters, friend.name)
                                    }
                                    previewEvidence = found
                                } else {
                                    onDismiss()
                                    onStartChat(friend)
                                }
                            } catch (t: Throwable) {
                                errorText = t.message ?: L10n.text("查找失败", "Lookup failed")
                            } finally {
                                isWorking = false
                            }
                        }
                    }
                ) {
                    Text(
                        if (previewEvidence == null) L10n.text("查找人物", "Find Character")
                        else L10n.text("开始对话", "Start Chat")
                    )
                }
            }

            if (selectedBook == null) {
                Text(
                    text = L10n.text("书架中暂无书籍，请先导入一本书。", "No books on your shelf yet. Import a book first."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                Box {
                    OutlinedButton(
                        onClick = { showBookMenu = true },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = L10n.text("书籍：${selectedBook.title}", "Book: ${selectedBook.title}"),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    DropdownMenu(
                        expanded = showBookMenu,
                        onDismissRequest = { showBookMenu = false }
                    ) {
                        for (b in books) {
                            DropdownMenuItem(
                                text = { Text(b.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                onClick = {
                                    selectedBookID = b.id
                                    throughChapter = null
                                    previewEvidence = null
                                    errorText = null
                                    showBookMenu = false
                                }
                            )
                        }
                    }
                }

                OutlinedTextField(
                    value = name,
                    onValueChange = {
                        name = it
                        previewEvidence = null
                        errorText = null
                    },
                    label = { Text(L10n.text("书中人物姓名（例：林黛玉 / 罗辑）", "Character Name")) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = aliases,
                    onValueChange = {
                        aliases = it
                        previewEvidence = null
                        errorText = null
                    },
                    label = { Text(L10n.text("别名 / 称呼（可选，逗号分隔）", "Aliases (optional, comma-separated)")) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                Box {
                    val progressLabel = validatedFriend?.progressLabel(selectedBook.chapterTitles)
                        ?: throughChapter?.let { selectedBook.chapterTitles.getOrNull(it) }
                        ?: L10n.text("全书（不防剧透）", "Full Book (No Spoiler Cap)")
                    OutlinedButton(
                        onClick = { showChapterMenu = true },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = L10n.text("阅读进度范围：$progressLabel", "Progress Cap: $progressLabel"),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    DropdownMenu(
                        expanded = showChapterMenu,
                        onDismissRequest = { showChapterMenu = false }
                    ) {
                        DropdownMenuItem(
                            text = { Text(L10n.text("全书", "Full Book")) },
                            onClick = {
                                throughChapter = null
                                previewEvidence = null
                                showChapterMenu = false
                            }
                        )
                        selectedBook.chapterTitles.forEachIndexed { idx, title ->
                            DropdownMenuItem(
                                text = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                onClick = {
                                    throughChapter = idx
                                    previewEvidence = null
                                    showChapterMenu = false
                                }
                            )
                        }
                    }
                }

                Text(
                    text = L10n.text(
                        "选定阅读进度后，角色仅根据该章节及之前的原文段落对话，绝不剧透后续情节。",
                        "Setting a reading progress cap ensures the character only draws from chapters you have already read."
                    ),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (isWorking) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    CircularProgressIndicator(modifier = Modifier.padding(4.dp))
                    Text(L10n.text("正在检索书中人物片段…", "Searching character passages…"))
                }
            }

            errorText?.let { err ->
                Text(
                    text = err,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            previewEvidence?.let { evidence ->
                Text(
                    text = L10n.text(
                        "已找到 ${evidence.excerpts.size} 段出场参考（对话时会动态选取最贴切原文）：",
                        "Found ${evidence.excerpts.size} sample passages:"
                    ),
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold)
                )
                for (ex in evidence.excerpts) {
                    Surface(
                        shape = MaterialTheme.shapes.small,
                        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(
                            modifier = Modifier.padding(DS.Spacing.sm),
                            verticalArrangement = Arrangement.spacedBy(3.dp)
                        ) {
                            Text(
                                text = ex.chapter,
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.primary
                            )
                            Text(
                                text = ex.text,
                                style = MaterialTheme.typography.bodySmall,
                                maxLines = 4,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }
        }
    }
}
