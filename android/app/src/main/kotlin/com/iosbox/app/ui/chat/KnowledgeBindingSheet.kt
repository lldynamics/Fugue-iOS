package com.iosbox.app.ui.chat

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
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
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.BookImporter
import com.iosbox.app.core.storage.BookVolumeItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KnowledgeBindingSheet(
    books: List<BookVolumeItem>,
    initialSelectedIDs: List<String>,
    chatRepository: ChatRepository,
    onApply: (List<String>) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var selectedIDs by remember(initialSelectedIDs) {
        mutableStateOf(initialSelectedIDs.map { it.uppercase() }.distinct())
    }
    var isImporting by remember { mutableStateOf(false) }
    var importError by remember { mutableStateOf<String?>(null) }

    val picker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            isImporting = true
            importError = null
            try {
                val prepared = withContext(Dispatchers.IO) {
                    BookImporter.readUri(context.contentResolver, uri)
                }
                val saved = chatRepository.storePreparedBook(prepared)
                val upper = saved.id.uppercase()
                if (!selectedIDs.contains(upper) && selectedIDs.size < 12) {
                    selectedIDs = selectedIDs + upper
                }
            } catch (t: Throwable) {
                importError = t.message ?: L10n.text("导入失败", "Import failed")
            } finally {
                isImporting = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
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
                    text = L10n.text("绑定本地参考知识库 (${selectedIDs.size}/12)", "Bind Knowledge Volumes (${selectedIDs.size}/12)"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(onClick = {
                    onApply(selectedIDs)
                    onDismiss()
                }) {
                    Text(L10n.text("完成", "Done"))
                }
            }

            OutlinedButton(
                enabled = !isImporting,
                onClick = {
                    picker.launch(
                        arrayOf(
                            "application/epub+zip",
                            "application/pdf",
                            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                            "text/*",
                            "application/octet-stream",
                            "*/*"
                        )
                    )
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                if (isImporting) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(modifier = Modifier.size(8.dp))
                    Text(L10n.text("正在导入文档…", "Importing…"))
                } else {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.size(6.dp))
                    Text(L10n.text("从文件导入书籍 / 资料 (EPUB / PDF / Office / TXT / MD)", "Import Book / Doc (EPUB / PDF / Office / TXT / MD)"))
                }
            }

            importError?.let { err ->
                Text(
                    text = err,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            Text(
                text = L10n.text(
                    "绑定后每轮提问会自动检索高相关原文片段并带章节/位置标记；开启 Agent 工具时模型也可主动调用 `search_documents` 深入查阅。",
                    "Auto-retrieves cited excerpts on every turn, and unlocks `search_documents` when Agent Tools are enabled."
                ),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            if (books.isEmpty()) {
                Text(
                    text = L10n.text("书架中暂无资料，点击上方按钮即可导入。", "No volumes on your shelf yet."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 16.dp)
                )
            } else {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 320.dp)
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    for (book in books) {
                        val upper = book.id.uppercase()
                        val checked = selectedIDs.contains(upper)
                        Surface(
                            shape = MaterialTheme.shapes.small,
                            color = if (checked) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.35f)
                            else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    selectedIDs = if (checked) {
                                        selectedIDs.filterNot { it == upper }
                                    } else if (selectedIDs.size < 12) {
                                        selectedIDs + upper
                                    } else {
                                        selectedIDs
                                    }
                                }
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Icon(
                                    imageVector = if (checked) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                                    contentDescription = null,
                                    tint = if (checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(20.dp)
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = book.title,
                                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        text = L10n.text(
                                            "共 ${book.chapterTitles.size} 节 · ${book.formattedSize}",
                                            "${book.chapterTitles.size} sections · ${book.formattedSize}"
                                        ),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if (selectedIDs.isNotEmpty()) {
                TextButton(
                    onClick = { selectedIDs = emptyList() },
                    modifier = Modifier.align(Alignment.End)
                ) {
                    Text(L10n.text("清空已绑定资料", "Clear Selected"), color = MaterialTheme.colorScheme.error)
                }
            }
        }
    }
}
