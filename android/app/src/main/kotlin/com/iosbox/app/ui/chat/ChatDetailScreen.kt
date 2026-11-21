package com.iosbox.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.HowToVote
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Summarize
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.ViewColumn
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ReadingCitation
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.ui.books.BookReaderSheet
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors

private data class ReaderLaunchState(
    val volumeID: String,
    val throughChapter: Int?,
    val citation: ReadingCitation? = null,
    val companionConversationID: String? = null
)

private sealed interface ChatTimelineEntry {
    val key: String

    data class SingleMessage(val message: ChatMessageItem) : ChatTimelineEntry {
        override val key: String = "msg_${message.id}"
    }

    data class ArenaGroup(val groupID: String, val messages: List<ChatMessageItem>) : ChatTimelineEntry {
        override val key: String = "grp_$groupID"
    }
}

private fun groupTimelineEntries(messages: List<ChatMessageItem>): List<ChatTimelineEntry> {
    val entries = mutableListOf<ChatTimelineEntry>()
    val seenGroups = HashSet<String>()
    for (msg in messages) {
        val gid = msg.comparisonGroupID
        if (gid == null) {
            entries.add(ChatTimelineEntry.SingleMessage(msg))
        } else {
            val normalized = gid.uppercase()
            if (seenGroups.add(normalized)) {
                val groupMembers = messages.filter { it.comparisonGroupID.equals(gid, ignoreCase = true) }
                entries.add(ChatTimelineEntry.ArenaGroup(gid, groupMembers))
            }
        }
    }
    return entries
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatDetailScreen(
    conversationId: String,
    container: AppContainer,
    onBack: () -> Unit,
    onGoToProviders: () -> Unit,
    onOpenMemories: () -> Unit,
    onOpenConversation: (String) -> Unit
) {
    val vm: ChatViewModel = viewModel(
        key = "chat_$conversationId",
        factory = ChatViewModel.factory(conversationId, container)
    )
    val state by vm.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val listState = rememberLazyListState()

    var showModelPicker by remember { mutableStateOf(false) }
    var showArenaConfig by remember { mutableStateOf(false) }
    var showGroupSetup by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showKnowledgeSheet by remember { mutableStateOf(false) }
    var showBookProgressDialog by remember { mutableStateOf(false) }
    var readingRequest by remember { mutableStateOf<ReaderLaunchState?>(null) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }
    var showAttachMenu by remember { mutableStateOf(false) }
    var activeBallotGroupID by remember { mutableStateOf<String?>(null) }
    var judgeGroupID by remember { mutableStateOf<String?>(null) }
    var compareSourceMessage by remember { mutableStateOf<ChatMessageItem?>(null) }

    val imagePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickMultipleVisualMedia(maxItems = 4)
    ) { uris ->
        vm.attachUris(context.contentResolver, uris, imageOnly = true)
    }

    val documentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        vm.attachUris(context.contentResolver, uris, imageOnly = false)
    }

    val timelineEntries = remember(state.messages) { groupTimelineEntries(state.messages) }

    LaunchedEffect(timelineEntries.size, state.messages.lastOrNull()?.content?.length) {
        if (timelineEntries.isNotEmpty()) {
            listState.scrollToItem(timelineEntries.lastIndex)
        }
    }

    val conv = state.conversation
    val activeFriend = conv?.activeBookFriend
    val readyTargets = remember(state.providers) { ChatRepository.readyTargets(state.providers) }
    val activeTarget = conv?.primaryTarget ?: readyTargets.firstOrNull()
    val openCitation: (ReadingCitation) -> Unit = { cite ->
        val cap = if (activeFriend != null && cite.volumeID.equals(activeFriend.bookID, ignoreCase = true)) {
            activeFriend.throughChapter
        } else {
            null
        }
        val companionId = if (conv?.companionBookID.equals(cite.volumeID, ignoreCase = true)) conv?.id else null
        readingRequest = ReaderLaunchState(
            volumeID = cite.volumeID,
            throughChapter = cap,
            citation = cite,
            companionConversationID = companionId
        )
    }

    val topBarSubtitle: String
    val topBarSubtitleOk: Boolean
    if (conv?.isGroupMode == true) {
        val activeCount = conv.activeGroupMembers.size
        val totalCount = conv.groupMembers.size
        val modeBadge = conv.assistanceSettings.groupSpeakingMode.shortBadge
        topBarSubtitle = L10n.text(
            "群聊 · $activeCount/$totalCount 人 · $modeBadge",
            "Group · $activeCount/$totalCount · $modeBadge"
        )
        topBarSubtitleOk = activeCount >= 1
    } else if (conv?.isArenaMode == true) {
        val count = conv.arenaTargets.size
        val blindSuffix = if (conv.assistanceSettings.blindArenaMode) L10n.text(" · 双盲", " · Blind") else ""
        topBarSubtitle = if (count >= 2) {
            L10n.text("竞技场 · $count 模型$blindSuffix", "Arena · $count Models$blindSuffix")
        } else {
            L10n.text("竞技场 · 请选 ≥2 模型", "Arena · Pick ≥2 models")
        }
        topBarSubtitleOk = count >= 2
    } else {
        topBarSubtitle = activeTarget?.let { "${it.providerName} · ${it.modelDisplayName}" }
            ?: L10n.text("未配置可用模型（点击选择）", "No ready model (tap to choose)")
        topBarSubtitleOk = activeTarget != null
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = L10n.text("返回", "Back"))
                    }
                },
                title = {
                    Column {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable(enabled = conv != null) {
                                renameText = conv?.title ?: ""
                                showRenameDialog = true
                            }
                        ) {
                            Text(
                                text = conv?.title ?: L10n.text("对话", "Chat"),
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Icon(
                                imageVector = Icons.Filled.Edit,
                                contentDescription = null,
                                modifier = Modifier
                                    .padding(start = 4.dp)
                                    .size(14.dp),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Text(
                            text = topBarSubtitle,
                            style = MaterialTheme.typography.labelSmall,
                            color = if (topBarSubtitleOk) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.error,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.clickable(enabled = conv != null) {
                                when {
                                    conv?.isGroupMode == true -> showGroupSetup = true
                                    conv?.isArenaMode == true -> showArenaConfig = true
                                    else -> showModelPicker = true
                                }
                            }
                        )
                    }
                },
                actions = {
                    val readableBookID = conv?.companionBookID
                        ?: activeFriend?.bookID
                        ?: conv?.assistanceSettings?.knowledgeVolumeIDs?.firstOrNull()
                    if (readableBookID != null) {
                        IconButton(onClick = {
                            readingRequest = ReaderLaunchState(
                                volumeID = readableBookID,
                                throughChapter = activeFriend?.throughChapter,
                                citation = null,
                                companionConversationID = if (conv?.companionBookID.equals(readableBookID, ignoreCase = true)) {
                                    conv?.id
                                } else {
                                    null
                                }
                            )
                        }) {
                            Icon(
                                imageVector = Icons.Filled.AutoStories,
                                contentDescription = L10n.text("阅读原文", "Open Reader"),
                                tint = MaterialTheme.colorScheme.primary
                            )
                        }
                    }
                    if (conv?.isGroupMode == true) {
                        IconButton(onClick = { showGroupSetup = true }, enabled = !state.isGenerating) {
                            Icon(
                                imageVector = Icons.Filled.Groups,
                                contentDescription = L10n.text("群成员与设置", "Group Settings"),
                                tint = MaterialTheme.colorScheme.primary
                            )
                        }
                    } else {
                        IconButton(onClick = { showArenaConfig = true }, enabled = conv != null && !state.isGenerating) {
                            Icon(
                                imageVector = Icons.Filled.ViewColumn,
                                contentDescription = L10n.text("模型竞技场", "Model Arena"),
                                tint = if (conv?.isArenaMode == true) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurface
                            )
                        }
                    }
                    IconButton(onClick = { showSettings = true }, enabled = conv != null) {
                        Icon(Icons.Filled.Tune, contentDescription = L10n.text("会话参数", "Chat Settings"))
                    }
                }
            )
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .imePadding()
        ) {
            if (readyTargets.isEmpty()) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onGoToProviders() }
                ) {
                    Text(
                        text = L10n.text(
                            "尚未配置可用模型，点击前往「服务商」填入 API Key。",
                            "No ready model yet. Tap to configure an API key in Providers."
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.sm)
                    )
                }
            }

            if (activeFriend != null) {
                val friendBook = remember(state.books, activeFriend.bookID) {
                    state.books.firstOrNull { it.id.equals(activeFriend.bookID, ignoreCase = true) }
                }
                val progressLabel = activeFriend.progressLabel(friendBook?.chapterTitles ?: emptyList())
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "📖 ${activeFriend.byline} · $progressLabel",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        TextButton(
                            enabled = !state.isGenerating && friendBook != null,
                            onClick = { showBookProgressDialog = true }
                        ) {
                            Text(L10n.text("调整进度", "Progress"), style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
            }

            state.activeGroupSpeaker?.let { speakerLabel ->
                Surface(
                    color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 1.8.dp)
                        Text(
                            text = L10n.text("$speakerLabel 正在发言…", "$speakerLabel is speaking…"),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    }
                }
            }

            state.bannerError?.let { err ->
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.xs),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = err,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(onClick = { vm.clearBannerError() }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }

            LazyColumn(
                state = listState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
                contentPadding = PaddingValues(DS.Spacing.lg),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
            ) {
                if (timelineEntries.isEmpty()) {
                    item {
                        Box(
                            modifier = Modifier
                                .fillParentMaxHeight(0.65f)
                                .fillMaxWidth(),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = conv?.assistantEmoji ?: "✨",
                                    style = MaterialTheme.typography.displaySmall
                                )
                                Text(
                                    text = when {
                                        conv?.isGroupMode == true -> L10n.text(
                                            "圆桌群聊 · 抛出话题或 @点名",
                                            "Roundtable · Throw a topic or @mention"
                                        )
                                        conv?.isArenaMode == true -> L10n.text("多模型竞技场 · 同台竞技", "Model Arena · Side-by-Side")
                                        else -> L10n.text("纯本地直连 · 开始提问", "Local Direct · Ask anything")
                                    },
                                    style = MaterialTheme.typography.titleSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                val systemPrompt = conv?.systemPrompt
                                if (!systemPrompt.isNullOrBlank()) {
                                    Text(
                                        text = systemPrompt,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 3,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.padding(horizontal = 24.dp)
                                    )
                                }
                            }
                        }
                    }
                } else {
                    items(timelineEntries, key = { it.key }) { entry ->
                        when (entry) {
                            is ChatTimelineEntry.SingleMessage -> {
                                val msg = entry.message
                                MessageBubbleRow(
                                    message = msg,
                                    activeBookID = activeFriend?.bookID,
                                    canRegenerate = !state.isGenerating && msg.role == MessageRole.ASSISTANT,
                                    canCompareWithAnother = !state.isGenerating &&
                                        conv?.isGroupMode != true &&
                                        msg.role == MessageRole.ASSISTANT &&
                                        readyTargets.size >= 2,
                                    onRegenerate = { vm.regenerateMessage(msg) },
                                    onCompareWithAnother = { compareSourceMessage = msg },
                                    onApproveMemory = { fact -> vm.approveProposedMemory(msg, fact) },
                                    onDismissMemory = { fact -> vm.dismissProposedMemory(msg, fact) },
                                    onOpenCitation = openCitation
                                )
                            }
                            is ChatTimelineEntry.ArenaGroup -> {
                                ArenaComparisonGroupCard(
                                    groupID = entry.groupID,
                                    messages = entry.messages,
                                    isBlindMode = conv?.assistanceSettings?.blindArenaMode == true,
                                    isGenerating = state.isGenerating,
                                    onOpenBallot = { activeBallotGroupID = entry.groupID },
                                    onToggleBlindMode = vm::toggleBlindArenaMode,
                                    onFollowUp = vm::selectContextReply,
                                    onRegenerateSingle = vm::regenerateMessage,
                                    onSynthesize = { judgeGroupID = entry.groupID },
                                    onCrossCritique = { vm.crossCritiqueGroup(entry.groupID) },
                                    onOpenCitation = openCitation
                                )
                            }
                        }
                    }
                }
            }

            HorizontalDivider(color = MaterialTheme.colorScheme.outline)

            if (conv?.isGroupMode == true) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = DS.Spacing.md, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = if (state.isGenerating) 0.4f else 0.9f),
                        modifier = Modifier.clickable(enabled = !state.isGenerating) { vm.continueGroupDiscussion() }
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(Icons.Filled.PlayArrow, contentDescription = null, modifier = Modifier.size(14.dp))
                            Text(L10n.text("继续讨论", "Continue"), style = MaterialTheme.typography.labelSmall)
                        }
                    }
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = if (state.isGenerating) 0.4f else 0.9f),
                        modifier = Modifier.clickable(enabled = !state.isGenerating) { vm.startGroupVote() }
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(Icons.Filled.HowToVote, contentDescription = null, modifier = Modifier.size(14.dp))
                            Text(L10n.text("全员表决", "Vote"), style = MaterialTheme.typography.labelSmall)
                        }
                    }
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = if (state.isGenerating) 0.4f else 0.9f),
                        modifier = Modifier.clickable(enabled = !state.isGenerating) { vm.summarizeGroupDiscussion() }
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(Icons.Filled.Summarize, contentDescription = null, modifier = Modifier.size(14.dp))
                            Text(L10n.text("生成纪要", "Summary"), style = MaterialTheme.typography.labelSmall)
                        }
                    }

                    for (member in conv.activeGroupMembers) {
                        Surface(
                            shape = CircleShape,
                            border = BorderStroke(1.dp, DS.parseHexColor(member.accentHex).copy(alpha = 0.5f)),
                            color = MaterialTheme.colorScheme.surface,
                            modifier = Modifier.clickable { vm.appendMentionToDraft(member) }
                        ) {
                            Text(
                                text = "@${member.mentionToken}",
                                style = MaterialTheme.typography.labelSmall,
                                color = DS.parseHexColor(member.accentHex),
                                modifier = Modifier.padding(horizontal = 9.dp, vertical = 5.dp)
                            )
                        }
                    }
                }
            } else if (conv != null) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = DS.Spacing.md, vertical = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    FilterChip(
                        selected = state.useWebSearchOnce,
                        onClick = vm::toggleUseWebSearchOnce,
                        enabled = !state.isGenerating,
                        leadingIcon = {
                            Icon(Icons.Filled.Public, contentDescription = null, modifier = Modifier.size(15.dp))
                        },
                        label = {
                            Text(
                                text = L10n.text("联网搜索", "Web Search"),
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    )
                    if (!conv.isArenaMode) {
                        FilterChip(
                            selected = conv.assistanceSettings.enableAgentTools,
                            onClick = vm::toggleAgentTools,
                            enabled = !state.isGenerating,
                            leadingIcon = {
                                Icon(Icons.Filled.Build, contentDescription = null, modifier = Modifier.size(15.dp))
                            },
                            label = {
                                Text(
                                    text = L10n.text("Agent 工具", "Agent Tools"),
                                    style = MaterialTheme.typography.labelSmall
                                )
                            }
                        )
                    }
                    FilterChip(
                        selected = conv.assistanceSettings.enableNativeGrounding,
                        onClick = vm::toggleNativeGrounding,
                        enabled = !state.isGenerating,
                        leadingIcon = {
                            Icon(Icons.Filled.Public, contentDescription = null, modifier = Modifier.size(15.dp))
                        },
                        label = {
                            Text(
                                text = L10n.text("原生检索", "Grounding"),
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    )
                    if (!conv.isArenaMode) {
                        val memSuffix = if (state.enabledMemoryCount > 0) " (${state.enabledMemoryCount})" else ""
                        FilterChip(
                            selected = conv.assistanceSettings.usePersonalMemory,
                            onClick = vm::togglePersonalMemory,
                            enabled = !state.isGenerating,
                            leadingIcon = {
                                Icon(Icons.Filled.Psychology, contentDescription = null, modifier = Modifier.size(15.dp))
                            },
                            label = {
                                Text(
                                    text = L10n.text("记忆$memSuffix", "Memory$memSuffix"),
                                    style = MaterialTheme.typography.labelSmall
                                )
                            }
                        )
                    }
                    val kbCount = conv.assistanceSettings.knowledgeVolumeIDs.size
                    val kbSuffix = if (kbCount > 0) " ($kbCount)" else ""
                    FilterChip(
                        selected = kbCount > 0,
                        onClick = { showKnowledgeSheet = true },
                        enabled = !state.isGenerating,
                        leadingIcon = {
                            Icon(Icons.Filled.AutoStories, contentDescription = null, modifier = Modifier.size(15.dp))
                        },
                        label = {
                            Text(
                                text = L10n.text("知识库$kbSuffix", "Knowledge$kbSuffix"),
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    )
                }
            }

            if (state.draftAttachments.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = DS.Spacing.md, vertical = DS.Spacing.xs),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    for (att in state.draftAttachments) {
                        AttachmentChip(attachment = att, onRemove = { vm.removeDraftAttachment(att.id) })
                    }
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.sm, vertical = DS.Spacing.sm),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Box {
                    IconButton(onClick = { showAttachMenu = true }, enabled = !state.isGenerating) {
                        Icon(
                            imageVector = Icons.Filled.AttachFile,
                            contentDescription = L10n.text("添加附件", "Attach")
                        )
                    }
                    DropdownMenu(
                        expanded = showAttachMenu,
                        onDismissRequest = { showAttachMenu = false }
                    ) {
                        DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.Image, contentDescription = null) },
                            text = { Text(L10n.text("选择图片", "Choose Images")) },
                            onClick = {
                                showAttachMenu = false
                                imagePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                            }
                        )
                        DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.Description, contentDescription = null) },
                            text = { Text(L10n.text("选择 PDF / 文本 / 代码", "Choose PDF / Text / Code")) },
                            onClick = {
                                showAttachMenu = false
                                documentPicker.launch(arrayOf("application/pdf", "text/*", "application/json", "*/*"))
                            }
                        )
                    }
                }

                OutlinedTextField(
                    value = state.draftText,
                    onValueChange = vm::updateDraftText,
                    modifier = Modifier.weight(1f),
                    placeholder = { Text(L10n.text("输入消息…", "Message…")) },
                    maxLines = 5,
                    shape = RoundedCornerShape(DS.Radius.lg)
                )

                val canSendDraft = state.draftText.isNotBlank() || state.draftAttachments.isNotEmpty()
                val canBargeIn = conv?.isGroupMode == true && state.isGenerating && canSendDraft
                if (state.isGenerating) {
                    IconButton(
                        onClick = { vm.stopGeneration() },
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.error)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Stop,
                            contentDescription = L10n.text("停止生成", "Stop"),
                            tint = MaterialTheme.colorScheme.onError
                        )
                    }
                }
                if (!state.isGenerating || canBargeIn) {
                    IconButton(
                        onClick = { vm.sendCurrentDraft() },
                        enabled = canSendDraft,
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(
                                if (canSendDraft) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.surfaceVariant
                            )
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Send,
                            contentDescription = if (canBargeIn) L10n.text("插话发送", "Barge In") else L10n.text("发送", "Send"),
                            tint = if (canSendDraft) MaterialTheme.colorScheme.onPrimary
                            else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }

    if (showModelPicker) {
        ModelPickerSheet(
            providers = state.providers,
            selectedTargetId = activeTarget?.id,
            onSelect = vm::selectModel,
            onDismiss = { showModelPicker = false }
        )
    }

    if (showArenaConfig && conv != null) {
        ArenaConfigSheet(
            providers = state.providers,
            isArenaMode = conv.isArenaMode,
            selectedTargets = conv.arenaTargets,
            blindArenaMode = conv.assistanceSettings.blindArenaMode,
            onApply = vm::setArenaConfiguration,
            onDismiss = { showArenaConfig = false }
        )
    }

    if (showGroupSetup && conv != null) {
        GroupSetupSheet(
            existing = conv,
            providers = state.providers,
            personaProfiles = state.personaProfiles,
            onSave = vm::updateGroupConfiguration,
            onDismiss = { showGroupSetup = false }
        )
    }

    compareSourceMessage?.let { src ->
        ModelPickerSheet(
            providers = state.providers,
            selectedTargetId = null,
            title = L10n.text("选择对比模型", "Compare with Model"),
            onSelect = { secondTarget -> vm.compareWithAnotherModel(src, secondTarget) },
            onDismiss = { compareSourceMessage = null }
        )
    }

    judgeGroupID?.let { gid ->
        ModelPickerSheet(
            providers = state.providers,
            selectedTargetId = activeTarget?.id,
            title = L10n.text("选择裁判模型", "Select Judge Model"),
            onSelect = { judgeTarget -> vm.synthesizeGroup(gid, judgeTarget) },
            onDismiss = { judgeGroupID = null }
        )
    }

    activeBallotGroupID?.let { gid ->
        val firstIdx = state.messages.indexOfFirst { it.comparisonGroupID.equals(gid, ignoreCase = true) }
        val question = if (firstIdx > 0) {
            val parentId = state.messages[firstIdx].parentMessageID
            val prior = state.messages.subList(0, firstIdx)
            prior.lastOrNull { it.role == MessageRole.USER && it.id == parentId }
                ?: prior.lastOrNull { it.role == MessageRole.USER }
        } else null
        BlindBallotDialog(
            groupID = gid,
            question = question,
            messages = state.messages,
            isGenerating = state.isGenerating,
            onVote = vm::castBlindVote,
            onDismiss = { activeBallotGroupID = null }
        )
    }

    if (showSettings && conv != null) {
        ChatSettingsSheet(
            conversation = conv,
            presets = state.presets,
            books = state.books,
            enabledMemoryCount = state.enabledMemoryCount,
            chatRepository = container.chatRepository,
            onOpenMemories = onOpenMemories,
            onSave = vm::updateConversationSettings,
            onDismiss = { showSettings = false }
        )
    }

    if (showKnowledgeSheet && conv != null) {
        KnowledgeBindingSheet(
            books = state.books,
            initialSelectedIDs = conv.assistanceSettings.knowledgeVolumeIDs,
            chatRepository = container.chatRepository,
            onApply = vm::updateBoundKnowledgeVolumes,
            onDismiss = { showKnowledgeSheet = false }
        )
    }

    readingRequest?.let { req ->
        BookReaderSheet(
            container = container,
            volumeID = req.volumeID,
            throughChapter = req.throughChapter,
            initialCitation = req.citation,
            companionConversationID = req.companionConversationID,
            onQuotePassage = vm::quotePassageToDraft,
            onDismiss = { readingRequest = null }
        )
    }

    if (showBookProgressDialog && activeFriend != null) {
        val friendBook = state.books.firstOrNull { it.id.equals(activeFriend.bookID, ignoreCase = true) }
        if (friendBook != null) {
            AlertDialog(
                onDismissRequest = { showBookProgressDialog = false },
                title = { Text(L10n.text("调整书中好友阅读进度", "Book Friend Reading Progress")) },
                text = {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 320.dp)
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Text(
                            text = L10n.text(
                                "往回调整章节进度时，会自动开启一条新对话以防后续章节剧透。",
                                "Rewinding to an earlier chapter opens a fresh chat to prevent spoilers."
                            ),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        TextButton(
                            onClick = {
                                showBookProgressDialog = false
                                vm.changeBookFriendProgress(null, onOpenConversation)
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = L10n.text("全书", "Full Book"),
                                fontWeight = if (activeFriend.throughChapter == null) FontWeight.Bold else FontWeight.Normal
                            )
                        }
                        friendBook.chapterTitles.forEachIndexed { idx, title ->
                            TextButton(
                                onClick = {
                                    showBookProgressDialog = false
                                    vm.changeBookFriendProgress(idx, onOpenConversation)
                                },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(
                                    text = title,
                                    fontWeight = if (activeFriend.throughChapter == idx) FontWeight.Bold else FontWeight.Normal,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { showBookProgressDialog = false }) {
                        Text(L10n.text("关闭", "Close"))
                    }
                }
            )
        }
    }

    if (showRenameDialog) {
        AlertDialog(
            onDismissRequest = { showRenameDialog = false },
            title = { Text(L10n.text("重命名对话", "Rename Chat")) },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(onClick = {
                    vm.renameConversation(renameText)
                    showRenameDialog = false
                }) {
                    Text(L10n.text("保存", "Save"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showRenameDialog = false }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    state.pendingConsent?.let { consent ->
        AIConsentDialog(
            targetSummary = consent.recipientSummary,
            onAccept = vm::acceptConsent,
            onDismiss = vm::dismissConsent
        )
    }

    state.pendingWebpageApproval?.let { req ->
        AlertDialog(
            onDismissRequest = { req.onResolve(false, false) },
            title = { Text(L10n.text("允许读取外部网页？", "Allow Reading Webpage?")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = L10n.text(
                            "模型请求读取以下 HTTPS 页面正文：",
                            "The model requested to read this HTTPS webpage:"
                        ),
                        style = MaterialTheme.typography.bodySmall
                    )
                    Text(
                        text = req.url,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary
                    )
                    if (req.hasQuery) {
                        Text(
                            text = L10n.text(
                                "注意：该链接带有查询参数，请确认未拼接隐私对话内容。",
                                "Note: This URL includes query parameters. Verify no private data is embedded."
                            ),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                }
            },
            confirmButton = {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (!req.hasQuery && req.host.isNotEmpty()) {
                        TextButton(onClick = { req.onResolve(true, true) }) {
                            Text(L10n.text("本对话信任域名", "Trust Host"))
                        }
                    }
                    Button(onClick = { req.onResolve(true, false) }) {
                        Text(L10n.text("允许本次", "Allow Once"))
                    }
                }
            },
            dismissButton = {
                TextButton(onClick = { req.onResolve(false, false) }) {
                    Text(L10n.text("拒绝", "Deny"))
                }
            }
        )
    }
}

@Composable
private fun MessageBubbleRow(
    message: ChatMessageItem,
    activeBookID: String?,
    canRegenerate: Boolean,
    canCompareWithAnother: Boolean,
    onRegenerate: () -> Unit,
    onCompareWithAnother: () -> Unit,
    onApproveMemory: (String) -> Unit,
    onDismissMemory: (String) -> Unit,
    onOpenCitation: (ReadingCitation) -> Unit
) {
    val context = LocalContext.current
    val accent = LocalAccentColors.current

    if (message.role == MessageRole.USER) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            if (message.attachments.isNotEmpty()) {
                AttachmentStrip(message.attachments)
            }
            if (message.content.isNotEmpty()) {
                Surface(
                    shape = RoundedCornerShape(DS.Radius.lg),
                    color = accent.solidFill,
                    modifier = Modifier.widthIn(max = 310.dp)
                ) {
                    Text(
                        text = message.content,
                        style = MaterialTheme.typography.bodyMedium,
                        color = accent.solidForeground,
                        modifier = Modifier.padding(horizontal = DS.Spacing.md, vertical = DS.Spacing.sm)
                    )
                }
            }
        }
    } else {
        val meta = message.assistanceMetadata
        val groupSpeaker = meta.groupSpeakerDisplayTitle
        val speakerColor = DS.parseHexColor(message.accentHex)

        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.xs)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (groupSpeaker != null) {
                    Text(
                        text = meta.groupMemberEmoji ?: "🤖",
                        style = MaterialTheme.typography.titleSmall
                    )
                    Text(
                        text = groupSpeaker,
                        style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                        color = speakerColor
                    )
                    if (message.modelDisplayName.isNotBlank()) {
                        Text(
                            text = "· ${message.modelDisplayName}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    meta.groupSpeechIntent?.badgeTitle?.let { intentBadge ->
                        Surface(
                            shape = CircleShape,
                            color = speakerColor.copy(alpha = 0.14f)
                        ) {
                            Text(
                                text = intentBadge,
                                style = MaterialTheme.typography.labelSmall,
                                color = speakerColor,
                                modifier = Modifier.padding(horizontal = 7.dp, vertical = 1.dp)
                            )
                        }
                    }
                    if (meta.groupAskedHost) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.tertiaryContainer
                        ) {
                            Text(
                                text = L10n.text("@群主 等你拍板", "@Host"),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onTertiaryContainer,
                                modifier = Modifier.padding(horizontal = 7.dp, vertical = 1.dp)
                            )
                        }
                    }
                } else {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(speakerColor)
                    )
                    Text(
                        text = listOf(message.providerName, message.modelDisplayName)
                            .filter { it.isNotBlank() }
                            .joinToString(" · ")
                            .ifEmpty { "Assistant" },
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                if (message.isStreaming) {
                    CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 1.8.dp)
                }
            }

            if (!meta.groupReplyToSpeaker.isNullOrBlank()) {
                Surface(
                    shape = RoundedCornerShape(DS.Radius.xs),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
                ) {
                    Text(
                        text = "↩ @${meta.groupReplyToSpeaker}：${meta.groupReplyToExcerpt.orEmpty()}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                    )
                }
            }

            ReasoningCard(
                reasoningText = message.reasoningContent,
                isStreaming = message.isStreaming && message.content.isEmpty(),
                thinkingDurationMs = message.thinkingDurationMs
            )

            ToolCallsStrip(toolCalls = meta.toolCalls)

            meta.search?.let { search ->
                SearchCitationsCard(search = search)
            }

            meta.knowledgeEvidence?.let { knowledge ->
                KnowledgeCitationsCard(knowledge = knowledge, onOpenCitation = onOpenCitation)
            }

            meta.bookReply?.let { bookReply ->
                val resolvedBookId = activeBookID ?: meta.knowledgeEvidence?.passages?.firstOrNull()?.volumeID
                if (resolvedBookId != null) {
                    BookReplyEvidenceCard(
                        bookReply = bookReply,
                        bookID = resolvedBookId,
                        onOpenCitation = onOpenCitation
                    )
                }
            }

            if (message.attachments.isNotEmpty()) {
                AttachmentStrip(message.attachments)
            }

            if (message.content.isNotEmpty()) {
                MarkdownMessageContent(markdown = message.content)
            } else if (message.isStreaming && message.reasoningContent.isEmpty() && meta.toolCalls.isEmpty()) {
                Text(
                    text = L10n.text("正在连接模型…", "Waiting for response…"),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            ProposedMemoriesCard(
                proposed = meta.proposedMemories,
                handled = meta.handledMemories,
                onSave = onApproveMemory,
                onDismiss = onDismissMemory
            )

            message.finishReasonValue?.let { reason ->
                Text(
                    text = reason.userNotice,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.tertiary
                )
            }

            message.errorMessage?.let { err ->
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(DS.Radius.xs),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = err,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(DS.Spacing.sm)
                    )
                }
            }

            if (!message.isStreaming && meta.groupReactions.isNotEmpty()) {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    for (reaction in meta.groupReactions) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f)
                        ) {
                            Text(
                                text = "${reaction.emoji} ${reaction.memberName}",
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                            )
                        }
                    }
                }
            }

            if (!message.isStreaming) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    if (message.content.isNotEmpty()) {
                        IconButton(
                            onClick = {
                                val cm = context.getSystemService(ClipboardManager::class.java)
                                cm?.setPrimaryClip(ClipData.newPlainText("Fugue", message.content))
                            },
                            modifier = Modifier.size(28.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.ContentCopy,
                                contentDescription = L10n.text("复制", "Copy"),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(15.dp)
                            )
                        }
                    }
                    if (canRegenerate) {
                        IconButton(
                            onClick = onRegenerate,
                            modifier = Modifier.size(28.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Refresh,
                                contentDescription = L10n.text("重答", "Regenerate"),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                    if (canCompareWithAnother) {
                        IconButton(
                            onClick = onCompareWithAnother,
                            modifier = Modifier.size(28.dp)
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.CompareArrows,
                                contentDescription = L10n.text("找另一个模型对比", "Compare with Another Model"),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                    val metaParts = buildList {
                        message.latencyMs?.let { add("TTFT ${it}ms") }
                        if (message.promptTokens != null || message.completionTokens != null) {
                            val total = (message.promptTokens ?: 0) + (message.completionTokens ?: 0)
                            add("$total tok")
                        }
                    }
                    if (metaParts.isNotEmpty()) {
                        Text(
                            text = metaParts.joinToString(" · "),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun AttachmentStrip(attachments: List<MessageAttachment>) {
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        for (att in attachments) {
            if (att.kind == AttachmentKind.IMAGE && !att.dataBase64.isNullOrEmpty()) {
                val bitmap = remember(att.id, att.dataBase64) {
                    runCatching {
                        val bytes = Base64.decode(att.dataBase64, Base64.DEFAULT)
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
                    }.getOrNull()
                }
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap,
                        contentDescription = att.fileName,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(96.dp)
                            .clip(RoundedCornerShape(DS.Radius.sm))
                    )
                    continue
                }
            }
            AttachmentChip(attachment = att, onRemove = null)
        }
    }
}

@Composable
private fun AttachmentChip(attachment: MessageAttachment, onRemove: (() -> Unit)?) {
    Surface(
        shape = RoundedCornerShape(DS.Radius.sm),
        color = MaterialTheme.colorScheme.surfaceVariant
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Icon(
                imageVector = if (attachment.kind == AttachmentKind.IMAGE) Icons.Filled.Image else Icons.Filled.Description,
                contentDescription = null,
                modifier = Modifier.size(16.dp)
            )
            Column {
                Text(
                    text = attachment.fileName,
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.widthIn(max = 150.dp)
                )
                Text(
                    text = attachment.formattedSize,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (onRemove != null) {
                IconButton(onClick = onRemove, modifier = Modifier.size(20.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.size(14.dp))
                }
            }
        }
    }
}
