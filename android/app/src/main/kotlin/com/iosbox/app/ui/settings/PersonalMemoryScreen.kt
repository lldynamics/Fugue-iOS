package com.iosbox.app.ui.settings

import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.PersonalMemoryPrompt
import com.iosbox.app.core.storage.PersonalMemoryItem
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.launch
import java.util.UUID

private data class MemoryDraft(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val text: String = "",
    val isEnabled: Boolean = true,
    val createdAtEpochMs: Long = System.currentTimeMillis()
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PersonalMemoryScreen(
    container: AppContainer,
    onBack: () -> Unit
) {
    val memories by container.chatRepository.observePersonalMemories()
        .collectAsStateWithLifecycle(initialValue = emptyList())
    val scope = rememberCoroutineScope()

    var editingDraft by remember { mutableStateOf<MemoryDraft?>(null) }
    var deleteCandidate by remember { mutableStateOf<PersonalMemoryItem?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = L10n.text("返回", "Back")
                        )
                    }
                },
                title = {
                    Column {
                        Text(
                            text = L10n.text("个人长期记忆", "Personal Memory"),
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                        )
                        Text(
                            text = "${memories.size} / ${PersonalMemoryPrompt.MAXIMUM_COUNT}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            )
        },
        floatingActionButton = {
            if (memories.size < PersonalMemoryPrompt.MAXIMUM_COUNT) {
                FloatingActionButton(onClick = { editingDraft = MemoryDraft() }) {
                    Icon(Icons.Filled.Add, contentDescription = L10n.text("添加记忆", "Add Memory"))
                }
            }
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(
                start = DS.Spacing.lg,
                end = DS.Spacing.lg,
                top = DS.Spacing.sm,
                bottom = 88.dp
            ),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            item {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)
                    ),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(DS.Spacing.md),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.Top
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Psychology,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(20.dp)
                        )
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(
                                text = L10n.text(
                                    "手动记录职业、技术栈或语言偏好（最多 ${PersonalMemoryPrompt.MAXIMUM_COUNT} 条，每条 ${PersonalMemoryPrompt.MAXIMUM_CHARACTERS} 字）。",
                                    "Store career context, tech stack, or response preferences (up to ${PersonalMemoryPrompt.MAXIMUM_COUNT} items, ${PersonalMemoryPrompt.MAXIMUM_CHARACTERS} chars each)."
                                ),
                                style = MaterialTheme.typography.bodySmall
                            )
                            Text(
                                text = L10n.text(
                                    "开启对话的「记忆」开关后随请求发送；记忆保存在本机，并包含在 iOS/Android 互通 JSON 备份中。",
                                    "Included when a chat has Memory enabled. Stored locally and included in JSON backups."
                                ),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }

            if (memories.isEmpty()) {
                item {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 40.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = L10n.text(
                                "暂无个人记忆，点击右下角 + 添加。",
                                "No personal memories yet. Tap + to add one."
                            ),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                items(memories, key = { it.id }) { memory ->
                    Card(
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                editingDraft = MemoryDraft(
                                    id = memory.id,
                                    text = memory.content,
                                    isEnabled = memory.isEnabled,
                                    createdAtEpochMs = memory.createdAtEpochMs
                                )
                            }
                    ) {
                        Row(
                            modifier = Modifier.padding(DS.Spacing.md),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Text(
                                text = memory.content,
                                style = MaterialTheme.typography.bodyMedium,
                                color = if (memory.isEnabled) MaterialTheme.colorScheme.onSurface
                                else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.weight(1f)
                            )
                            Switch(
                                checked = memory.isEnabled,
                                onCheckedChange = { enabled ->
                                    scope.launch {
                                        container.chatRepository.setPersonalMemoryEnabled(memory.id, enabled)
                                    }
                                }
                            )
                            IconButton(onClick = { deleteCandidate = memory }) {
                                Icon(
                                    imageVector = Icons.Filled.Delete,
                                    contentDescription = L10n.text("删除", "Delete"),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    editingDraft?.let { draft ->
        var text by remember(draft.id) { mutableStateOf(draft.text) }
        val trimmedLen = text.trim().length
        val canSave = trimmedLen in 1..PersonalMemoryPrompt.MAXIMUM_CHARACTERS
        AlertDialog(
            onDismissRequest = { editingDraft = null },
            title = { Text(L10n.text("编辑个人记忆", "Edit Personal Memory")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = text,
                        onValueChange = { text = it },
                        placeholder = {
                            Text(
                                L10n.text(
                                    "例如：我主要使用 Kotlin/Compose，回答请简洁并给出可直接运行的代码。",
                                    "Example: I build Android apps with Kotlin and Compose. Keep replies concise."
                                )
                            )
                        },
                        minLines = 4,
                        maxLines = 8,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Text(
                        text = "$trimmedLen / ${PersonalMemoryPrompt.MAXIMUM_CHARACTERS}",
                        style = MaterialTheme.typography.labelSmall,
                        color = if (trimmedLen > PersonalMemoryPrompt.MAXIMUM_CHARACTERS) {
                            MaterialTheme.colorScheme.error
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        }
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = canSave,
                    onClick = {
                        val toSave = PersonalMemoryItem(
                            id = draft.id,
                            content = text.trim(),
                            isEnabled = draft.isEnabled,
                            createdAtEpochMs = draft.createdAtEpochMs
                        )
                        editingDraft = null
                        scope.launch { container.chatRepository.savePersonalMemory(toSave) }
                    }
                ) {
                    Text(L10n.text("保存", "Save"))
                }
            },
            dismissButton = {
                TextButton(onClick = { editingDraft = null }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    deleteCandidate?.let { target ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            title = { Text(L10n.text("删除这条记忆？", "Delete Memory?")) },
            text = { Text(target.content) },
            confirmButton = {
                Button(onClick = {
                    val id = target.id
                    deleteCandidate = null
                    scope.launch { container.chatRepository.deletePersonalMemory(id) }
                }) {
                    Spacer(modifier = Modifier.size(0.dp))
                    Text(L10n.text("删除", "Delete"))
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
