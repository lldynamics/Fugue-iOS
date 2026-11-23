package com.iosbox.app.ui.chat

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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.automirrored.filled.Label
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.ViewColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ConversationItem
import com.iosbox.app.core.storage.ConversationSearch
import com.iosbox.app.core.storage.ConversationSearchHit
import com.iosbox.app.core.storage.ConversationTimeGrouping
import com.iosbox.app.ui.providers.QuickKeySetupSheet
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationListScreen(
    container: AppContainer,
    onOpenConversation: (String) -> Unit,
    onCreateConversation: () -> Unit,
    onCreateArenaConversation: () -> Unit,
    onCreateGroupConversation: () -> Unit,
    onGoToProviders: () -> Unit,
    onOpenFlashcards: () -> Unit
) {
    val conversations by container.chatRepository.observeConversations().collectAsStateWithLifecycle(initialValue = emptyList())
    val providers by container.chatRepository.observeProviders().collectAsStateWithLifecycle(initialValue = emptyList())
    val flashcards by container.flashcardRepository.cards.collectAsStateWithLifecycle()
    val prefs by container.preferences.state.collectAsStateWithLifecycle()
    val readyCount = remember(providers) { ChatRepository.readyTargets(providers).size }
    val dueCardsCount = remember(flashcards) {
        val now = System.currentTimeMillis()
        flashcards.count { it.isDue(now) }
    }

    var searchQuery by remember { mutableStateOf("") }
    var selectedFolderTag by remember { mutableStateOf<String?>(null) }
    var bookmarkedOnly by remember { mutableStateOf(false) }
    var messagesByConversation by remember { mutableStateOf<Map<String, List<ChatMessageItem>>>(emptyMap()) }
    var editingTagFor by remember { mutableStateOf<ConversationItem?>(null) }
    var showQuickKeySetup by remember { mutableStateOf(false) }
    var isBatchSelecting by remember { mutableStateOf(false) }
    var selectedBatchIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var showBatchTagDialog by remember { mutableStateOf(false) }
    var showBatchDeleteConfirm by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val availableTags = remember(conversations) {
        conversations.mapNotNull { it.folderTag?.trim()?.takeIf { tag -> tag.isNotEmpty() } }
            .distinct()
            .sorted()
    }

    LaunchedEffect(conversations, searchQuery, bookmarkedOnly) {
        if (searchQuery.isNotBlank() || bookmarkedOnly) {
            if (searchQuery.isNotBlank()) delay(160)
            messagesByConversation = container.chatRepository.getAllMessagesGroupedByConversation()
        }
    }

    val searchResults = remember(conversations, messagesByConversation, searchQuery, selectedFolderTag, bookmarkedOnly) {
        ConversationSearch.search(
            conversations = conversations,
            messagesByConversation = messagesByConversation,
            query = searchQuery,
            folderTag = selectedFolderTag,
            bookmarkedChatsOnly = bookmarkedOnly
        )
    }
    val conversationMap = remember(conversations) { conversations.associateBy { it.id } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = L10n.text("夜奔", "Fugue"),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                    )
                },
                actions = {
                    IconButton(onClick = onOpenFlashcards) {
                        if (dueCardsCount > 0) {
                            BadgedBox(badge = { Badge { Text(dueCardsCount.toString()) } }) {
                                Icon(
                                    imageVector = Icons.Filled.School,
                                    contentDescription = L10n.text("学习闪卡", "Flashcards")
                                )
                            }
                        } else {
                            Icon(
                                imageVector = Icons.Filled.School,
                                contentDescription = L10n.text("学习闪卡", "Flashcards")
                            )
                        }
                    }
                    if (!prefs.simpleDailyMode) {
                        IconButton(onClick = onCreateGroupConversation) {
                            Icon(
                                imageVector = Icons.Filled.Groups,
                                contentDescription = L10n.text("新建圆桌群聊", "New Group Chat")
                            )
                        }
                        IconButton(onClick = onCreateArenaConversation) {
                            Icon(
                                imageVector = Icons.Filled.ViewColumn,
                                contentDescription = L10n.text("新建竞技场", "New Model Arena")
                            )
                        }
                    }
                }
            )
        },
        floatingActionButton = {
            if (!isBatchSelecting) {
                FloatingActionButton(onClick = onCreateConversation) {
                    Icon(Icons.Filled.Add, contentDescription = L10n.text("新对话", "New Chat"))
                }
            }
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            if (readyCount == 0) {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.sm)
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = L10n.text("连接第一个 AI 模型", "Connect Your First Model"),
                            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                        )
                        Text(
                            text = L10n.text(
                                "填入 OpenAI、Claude、Gemini 或中转站 API Key 即可开始纯本地直连对话。",
                                "Add an OpenAI, Claude, Gemini, or custom gateway API key to start chatting directly."
                            ),
                            style = MaterialTheme.typography.bodySmall
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { showQuickKeySetup = true }) {
                                Text(L10n.text("剪贴板一键配 Key", "Quick Key Setup"))
                            }
                            TextButton(onClick = onGoToProviders) {
                                Text(L10n.text("手动配置服务商", "All Providers"))
                            }
                        }
                    }
                }
            }

            if (conversations.isNotEmpty()) {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    placeholder = { Text(L10n.text("全文检索对话、消息内容、标签…", "Search chats and message text…")) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.xs)
                )

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = DS.Spacing.lg, vertical = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    FilterChip(
                        selected = selectedFolderTag == null && !bookmarkedOnly,
                        onClick = {
                            selectedFolderTag = null
                            bookmarkedOnly = false
                        },
                        label = { Text(L10n.text("全部", "All")) }
                    )
                    FilterChip(
                        selected = bookmarkedOnly,
                        onClick = { bookmarkedOnly = !bookmarkedOnly },
                        leadingIcon = {
                            Icon(Icons.Filled.Bookmark, contentDescription = null, modifier = Modifier.size(14.dp))
                        },
                        label = { Text(L10n.text("有收藏", "Bookmarked")) }
                    )
                    for (tag in availableTags) {
                        FilterChip(
                            selected = selectedFolderTag == tag,
                            onClick = {
                                selectedFolderTag = if (selectedFolderTag == tag) null else tag
                            },
                            label = { Text(tag) }
                        )
                    }
                    if (searchQuery.isBlank()) {
                        FilterChip(
                            selected = isBatchSelecting,
                            onClick = {
                                isBatchSelecting = !isBatchSelecting
                                selectedBatchIds = emptySet()
                            },
                            leadingIcon = {
                                Icon(Icons.Filled.Checklist, contentDescription = null, modifier = Modifier.size(14.dp))
                            },
                            label = {
                                Text(
                                    if (isBatchSelecting) L10n.text("完成", "Done")
                                    else L10n.text("批量管理", "Manage")
                                )
                            }
                        )
                    }
                }
            }

            if (searchResults.isEmpty()) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = if (conversations.isEmpty()) {
                                L10n.text("点击右下角 + 开启第一段对话", "Tap + below to start a conversation")
                            } else {
                                L10n.text("没有匹配的对话", "No matching conversations")
                            },
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                    contentPadding = PaddingValues(bottom = if (isBatchSelecting) 16.dp else 88.dp)
                ) {
                    if (searchQuery.isBlank()) {
                        val filteredConvs = searchResults.mapNotNull { conversationMap[it.conversationID] }
                        val pinned = filteredConvs.filter { it.isPinned }
                        val regular = filteredConvs.filter { !it.isPinned }

                        if (pinned.isNotEmpty()) {
                            item(key = "hdr_pinned") {
                                Text(
                                    text = L10n.text("置顶对话", "Pinned"),
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = 6.dp)
                                )
                            }
                            items(pinned, key = { it.id }) { conv ->
                                val isChecked = conv.id in selectedBatchIds
                                ConversationRow(
                                    conversation = conv,
                                    hits = emptyList(),
                                    isBatchSelecting = isBatchSelecting,
                                    isBatchSelected = isChecked,
                                    onClick = {
                                        if (isBatchSelecting) {
                                            selectedBatchIds = if (isChecked) selectedBatchIds - conv.id else selectedBatchIds + conv.id
                                        } else {
                                            onOpenConversation(conv.id)
                                        }
                                    },
                                    onTogglePin = {
                                        scope.launch {
                                            container.chatRepository.saveConversation(conv.copy(isPinned = !conv.isPinned))
                                        }
                                    },
                                    onSetFolderTag = { editingTagFor = conv },
                                    onDelete = {
                                        scope.launch {
                                            container.chatRepository.deleteConversation(conv.id)
                                        }
                                    }
                                )
                                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
                            }
                        }

                        val grouped = ConversationTimeGrouping.groupByTime(
                            items = regular,
                            timestampOf = { it.updatedAtEpochMs }
                        )
                        for ((bucket, groupItems) in grouped) {
                            item(key = "hdr_${bucket.name}") {
                                Text(
                                    text = bucket.title,
                                    style = MaterialTheme.typography.labelLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = 6.dp)
                                )
                            }
                            items(groupItems, key = { it.id }) { conv ->
                                val isChecked = conv.id in selectedBatchIds
                                ConversationRow(
                                    conversation = conv,
                                    hits = emptyList(),
                                    isBatchSelecting = isBatchSelecting,
                                    isBatchSelected = isChecked,
                                    onClick = {
                                        if (isBatchSelecting) {
                                            selectedBatchIds = if (isChecked) selectedBatchIds - conv.id else selectedBatchIds + conv.id
                                        } else {
                                            onOpenConversation(conv.id)
                                        }
                                    },
                                    onTogglePin = {
                                        scope.launch {
                                            container.chatRepository.saveConversation(conv.copy(isPinned = !conv.isPinned))
                                        }
                                    },
                                    onSetFolderTag = { editingTagFor = conv },
                                    onDelete = {
                                        scope.launch {
                                            container.chatRepository.deleteConversation(conv.id)
                                        }
                                    }
                                )
                                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
                            }
                        }
                    } else {
                        items(searchResults, key = { it.conversationID }) { res ->
                            val conv = conversationMap[res.conversationID] ?: return@items
                            ConversationRow(
                                conversation = conv,
                                hits = res.hits,
                                isBatchSelecting = false,
                                isBatchSelected = false,
                                onClick = { onOpenConversation(conv.id) },
                                onTogglePin = {
                                    scope.launch {
                                        container.chatRepository.saveConversation(
                                            conv.copy(isPinned = !conv.isPinned)
                                        )
                                    }
                                },
                                onSetFolderTag = { editingTagFor = conv },
                                onDelete = {
                                    scope.launch {
                                        container.chatRepository.deleteConversation(conv.id)
                                    }
                                }
                            )
                            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
                        }
                    }
                }
            }

            if (isBatchSelecting) {
                Surface(
                    tonalElevation = 3.dp,
                    shadowElevation = 4.dp,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.sm),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = L10n.text("已选 ${selectedBatchIds.size} 项", "${selectedBatchIds.size} selected"),
                            style = MaterialTheme.typography.labelLarge
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(
                                onClick = { showBatchTagDialog = true },
                                enabled = selectedBatchIds.isNotEmpty()
                            ) {
                                Text(L10n.text("批量标签", "Tag"))
                            }
                            Button(
                                onClick = { showBatchDeleteConfirm = true },
                                enabled = selectedBatchIds.isNotEmpty()
                            ) {
                                Text(L10n.text("删除 (${selectedBatchIds.size})", "Delete (${selectedBatchIds.size})"))
                            }
                        }
                    }
                }
            }
        }
    }

    if (showQuickKeySetup) {
        QuickKeySetupSheet(
            container = container,
            existingProviders = providers,
            onConnected = {
                showQuickKeySetup = false
                onCreateConversation()
            },
            onDismiss = { showQuickKeySetup = false }
        )
    }

    if (showBatchTagDialog) {
        var tagDraft by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showBatchTagDialog = false },
            title = { Text(L10n.text("批量设置分组标签", "Batch Set Folder Tag")) },
            text = {
                OutlinedTextField(
                    value = tagDraft,
                    onValueChange = { tagDraft = it },
                    singleLine = true,
                    placeholder = { Text(L10n.text("例如：工作、学习（留空清除）", "e.g. Work, Study (blank to clear)")) },
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(onClick = {
                    val cleaned = tagDraft.trim().takeIf { it.isNotEmpty() }?.take(32)
                    val targetIds = selectedBatchIds
                    showBatchTagDialog = false
                    isBatchSelecting = false
                    selectedBatchIds = emptySet()
                    scope.launch {
                        for (conv in conversations.filter { it.id in targetIds }) {
                            container.chatRepository.saveConversation(conv.copy(folderTag = cleaned))
                        }
                    }
                }) {
                    Text(L10n.text("应用", "Apply"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showBatchTagDialog = false }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    if (showBatchDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showBatchDeleteConfirm = false },
            title = { Text(L10n.text("批量删除对话", "Delete Selected Conversations")) },
            text = {
                Text(
                    L10n.text(
                        "确定永久删除已选择的 ${selectedBatchIds.size} 段对话及其消息？",
                        "Permanently delete ${selectedBatchIds.size} selected conversations?"
                    )
                )
            },
            confirmButton = {
                Button(onClick = {
                    val targetIds = selectedBatchIds
                    showBatchDeleteConfirm = false
                    isBatchSelecting = false
                    selectedBatchIds = emptySet()
                    scope.launch {
                        for (id in targetIds) {
                            container.chatRepository.deleteConversation(id)
                        }
                    }
                }) {
                    Text(L10n.text("全部删除", "Delete All"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showBatchDeleteConfirm = false }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    editingTagFor?.let { target ->
        var tagDraft by remember(target.id) { mutableStateOf(target.folderTag.orEmpty()) }
        AlertDialog(
            onDismissRequest = { editingTagFor = null },
            title = { Text(L10n.text("设置分组标签", "Set Folder Tag")) },
            text = {
                OutlinedTextField(
                    value = tagDraft,
                    onValueChange = { tagDraft = it },
                    singleLine = true,
                    placeholder = { Text(L10n.text("例如：工作、学习、读书笔记（留空清除）", "e.g. Work, Study (blank to clear)")) },
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(onClick = {
                    val cleaned = tagDraft.trim().takeIf { it.isNotEmpty() }?.take(32)
                    val conv = target
                    editingTagFor = null
                    scope.launch {
                        container.chatRepository.saveConversation(conv.copy(folderTag = cleaned))
                    }
                }) {
                    Text(L10n.text("保存", "Save"))
                }
            },
            dismissButton = {
                TextButton(onClick = { editingTagFor = null }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }
}

@Composable
private fun ConversationRow(
    conversation: ConversationItem,
    hits: List<ConversationSearchHit>,
    isBatchSelecting: Boolean = false,
    isBatchSelected: Boolean = false,
    onClick: () -> Unit,
    onTogglePin: () -> Unit,
    onSetFolderTag: () -> Unit,
    onDelete: () -> Unit
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val accent = LocalAccentColors.current
    val dateText = remember(conversation.updatedAtEpochMs) {
        DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
            .format(Date(conversation.updatedAtEpochMs))
    }

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Row(
            modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            if (isBatchSelecting) {
                Icon(
                    imageVector = if (isBatchSelected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (isBatchSelected) accent.readableText else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(22.dp)
                )
            }
            Text(
                text = conversation.assistantEmoji.ifBlank { "✨" },
                style = MaterialTheme.typography.headlineSmall
            )
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    if (conversation.isPinned) {
                        Icon(
                            imageVector = Icons.Filled.PushPin,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(14.dp)
                        )
                    }
                    Text(
                        text = conversation.title,
                        style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.Medium),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    if (conversation.isGroupMode) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.secondaryContainer
                        ) {
                            Text(
                                text = L10n.text("群聊", "Group"),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSecondaryContainer,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                            )
                        }
                    } else if (conversation.isArenaMode) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primaryContainer
                        ) {
                            Text(
                                text = L10n.text("竞技场", "Arena"),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                            )
                        }
                    }
                    conversation.folderTag?.takeIf { it.isNotBlank() }?.let { tag ->
                        Surface(
                            shape = CircleShape,
                            color = accent.softFill
                        ) {
                            Text(
                                text = tag,
                                style = MaterialTheme.typography.labelSmall,
                                color = accent.readableText,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                            )
                        }
                    }
                }
                Spacer(modifier = Modifier.height(2.dp))
                val modelOrArenaLabel = when {
                    conversation.isGroupMode -> L10n.text(
                        "群聊 · ${conversation.groupMembers.size} 人",
                        "Group · ${conversation.groupMembers.size} members"
                    )
                    conversation.isArenaMode -> L10n.text(
                        "竞技场 · ${conversation.arenaTargets.size} 模型",
                        "Arena · ${conversation.arenaTargets.size} models"
                    )
                    else -> conversation.primaryTarget?.let { "${it.providerName} · ${it.modelDisplayName}" }
                }
                Text(
                    text = listOfNotNull(
                        modelOrArenaLabel,
                        dateText
                    ).joinToString(" · "),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                for (hit in hits.take(2)) {
                    val annotated = buildAnnotatedString {
                        append("${hit.speaker}: ")
                        append(hit.excerpt.before)
                        withStyle(SpanStyle(color = accent.readableText, fontWeight = FontWeight.Bold)) {
                            append(hit.excerpt.match)
                        }
                        append(hit.excerpt.after)
                    }
                    Text(
                        text = annotated,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                }
            }
            Box {
                IconButton(onClick = { menuExpanded = true }) {
                    Icon(Icons.Filled.MoreVert, contentDescription = null)
                }
                DropdownMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { menuExpanded = false }
                ) {
                    DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.PushPin, contentDescription = null) },
                        text = {
                            Text(
                                if (conversation.isPinned) L10n.text("取消置顶", "Unpin")
                                else L10n.text("置顶对话", "Pin")
                            )
                        },
                        onClick = {
                            menuExpanded = false
                            onTogglePin()
                        }
                    )
                    DropdownMenuItem(
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.Label, contentDescription = null) },
                        text = { Text(L10n.text("设置分组标签", "Folder Tag")) },
                        onClick = {
                            menuExpanded = false
                            onSetFolderTag()
                        }
                    )
                    DropdownMenuItem(
                        leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null) },
                        text = { Text(L10n.text("删除对话", "Delete")) },
                        onClick = {
                            menuExpanded = false
                            onDelete()
                        }
                    )
                }
            }
        }
    }
}
