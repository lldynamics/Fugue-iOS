package com.iosbox.app.ui.chat

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Build
import android.speech.RecognizerIntent
import android.util.Base64
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
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
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ClearAll
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.EventAvailable
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.HowToVote
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Quiz
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RssFeed
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Style
import androidx.compose.material.icons.filled.Summarize
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.ViewColumn
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.draw.alpha
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
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.runtime.saveable.rememberSaveable
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
import com.iosbox.app.core.model.GroupSourceNotice
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ProposedScheduleItem
import com.iosbox.app.core.model.ReadingCitation
import com.iosbox.app.core.model.StudyCardDraft
import com.iosbox.app.core.model.StudyCoachMode
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ConversationExporter
import com.iosbox.app.core.storage.ConversationSearch
import com.iosbox.app.core.storage.ModelMentionParser
import com.iosbox.app.core.storage.SlashPromptCommand
import com.iosbox.app.core.system.CalendarIntentLauncher
import java.util.Locale
import com.iosbox.app.ui.books.BookReaderSheet
import com.iosbox.app.ui.study.MessageStudyDeckCard
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle

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
    onOpenConversation: (String) -> Unit,
    onOpenFlashcards: () -> Unit
) {
    val vm: ChatViewModel = viewModel(
        key = "chat_$conversationId",
        factory = ChatViewModel.factory(conversationId, container)
    )
    val state by vm.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()

    var showModelPicker by remember { mutableStateOf(false) }
    var showArenaConfig by remember { mutableStateOf(false) }
    var showGroupSetup by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showKnowledgeSheet by remember { mutableStateOf(false) }
    var showBookProgressDialog by remember { mutableStateOf(false) }
    var showCoachDialog by remember { mutableStateOf(false) }
    var showInChatSearch by remember { mutableStateOf(false) }
    var showMoreMenu by remember { mutableStateOf(false) }
    var pendingMarkdownExport by remember { mutableStateOf<String?>(null) }
    var exportStatusAlert by remember { mutableStateOf<String?>(null) }
    var readingRequest by remember { mutableStateOf<ReaderLaunchState?>(null) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }
    var showAttachMenu by remember { mutableStateOf(false) }
    var activeBallotGroupID by remember { mutableStateOf<String?>(null) }
    var judgeGroupID by remember { mutableStateOf<String?>(null) }
    var compareSourceMessage by remember { mutableStateOf<ChatMessageItem?>(null) }
    var editingBranchMessage by remember { mutableStateOf<ChatMessageItem?>(null) }
    var editingBranchText by remember { mutableStateOf("") }

    val markdownExportLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("text/markdown")
    ) { uri ->
        val md = pendingMarkdownExport
        pendingMarkdownExport = null
        if (uri == null || md == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use {
                        it.write(md.toByteArray(Charsets.UTF_8))
                    } ?: error("Cannot write markdown file")
                }
            }.onSuccess {
                exportStatusAlert = L10n.text("Markdown 对话记录已保存。", "Markdown transcript saved.")
            }.onFailure { err ->
                exportStatusAlert = err.message ?: L10n.text("导出失败", "Export failed")
            }
        }
    }

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

    val speechLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val spoken = result.data
                ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (spoken.isNotEmpty()) {
                vm.appendDictatedText(spoken)
            }
        }
    }

    var promptedNotificationsThisSession by rememberSaveable { mutableStateOf(false) }
    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { _ -> }

    LaunchedEffect(state.isGenerating) {
        if (
            state.isGenerating &&
            !promptedNotificationsThisSession &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            promptedNotificationsThisSession = true
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
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
                    Box {
                        IconButton(onClick = { showMoreMenu = true }, enabled = conv != null) {
                            Icon(Icons.Filled.MoreVert, contentDescription = L10n.text("更多操作", "More"))
                        }
                        DropdownMenu(
                            expanded = showMoreMenu,
                            onDismissRequest = { showMoreMenu = false }
                        ) {
                            DropdownMenuItem(
                                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                                text = { Text(L10n.text("搜消息 / 收藏夹", "Search / Bookmarks")) },
                                onClick = {
                                    showMoreMenu = false
                                    showInChatSearch = true
                                }
                            )
                            DropdownMenuItem(
                                leadingIcon = { Icon(Icons.Filled.ClearAll, contentDescription = null) },
                                text = { Text(L10n.text("插入上下文清空分隔线", "Insert Context Divider")) },
                                enabled = !state.isGenerating && state.messages.isNotEmpty(),
                                onClick = {
                                    showMoreMenu = false
                                    vm.insertContextDivider()
                                }
                            )
                            DropdownMenuItem(
                                leadingIcon = { Icon(Icons.Filled.Upload, contentDescription = null) },
                                text = { Text(L10n.text("导出 Markdown", "Export Markdown")) },
                                enabled = state.messages.isNotEmpty() && conv != null,
                                onClick = {
                                    showMoreMenu = false
                                    conv?.let { c ->
                                        pendingMarkdownExport = ConversationExporter.makeMarkdown(c, state.messages)
                                        val name = ConversationExporter.sanitizedFileName(c.title)
                                        markdownExportLauncher.launch("$name.md")
                                    }
                                }
                            )
                            DropdownMenuItem(
                                leadingIcon = { Icon(Icons.Filled.School, contentDescription = null) },
                                text = { Text(L10n.text("学习闪卡库", "Flashcards")) },
                                onClick = {
                                    showMoreMenu = false
                                    onOpenFlashcards()
                                }
                            )
                            if (conv?.isGroupMode == true) {
                                DropdownMenuItem(
                                    leadingIcon = { Icon(Icons.Filled.RssFeed, contentDescription = null) },
                                    text = { Text(L10n.text("检查订阅动态", "Check Feeds")) },
                                    enabled = !state.isGenerating && !state.isRefreshingFeeds,
                                    onClick = {
                                        showMoreMenu = false
                                        vm.refreshPersonaFeeds()
                                    }
                                )
                            }
                        }
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

            state.feedStatusNotice?.let { notice ->
                Surface(
                    color = MaterialTheme.colorScheme.secondaryContainer,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.xs),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            imageVector = Icons.Filled.RssFeed,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSecondaryContainer,
                            modifier = Modifier
                                .padding(end = 6.dp)
                                .size(15.dp)
                        )
                        Text(
                            text = notice,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSecondaryContainer,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(onClick = { vm.clearFeedStatusNotice() }, modifier = Modifier.size(28.dp)) {
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
                                    branchSiblings = state.branchSiblings[msg.id].orEmpty(),
                                    canEditUser = !state.isGenerating && msg.role == MessageRole.USER,
                                    canRegenerate = !state.isGenerating && msg.role == MessageRole.ASSISTANT && msg.assistanceMetadata.sourceNotice == null,
                                    canCompareWithAnother = !state.isGenerating &&
                                        conv?.isGroupMode != true &&
                                        msg.role == MessageRole.ASSISTANT &&
                                        msg.assistanceMetadata.sourceNotice == null &&
                                        readyTargets.size >= 2,
                                    canStudyGenerate = !state.isGenerating &&
                                        state.studyGeneratingMessageID == null &&
                                        msg.role == MessageRole.ASSISTANT &&
                                        msg.assistanceMetadata.sourceNotice == null &&
                                        msg.content.isNotBlank(),
                                    isStudyGenerating = state.studyGeneratingMessageID == msg.id,
                                    canExtractSchedule = !state.isGenerating &&
                                        state.scheduleExtractingMessageID == null &&
                                        msg.role == MessageRole.ASSISTANT &&
                                        msg.assistanceMetadata.sourceNotice == null &&
                                        msg.content.isNotBlank(),
                                    isScheduleExtracting = state.scheduleExtractingMessageID == msg.id,
                                    isSpeaking = state.speakingMessageID == msg.id,
                                    onSwitchBranch = vm::switchBranch,
                                    onEditUserMessage = {
                                        editingBranchMessage = msg
                                        editingBranchText = msg.content
                                    },
                                    onQuoteReply = { vm.quoteMessageForFollowUp(msg) },
                                    onToggleSpeak = { vm.toggleSpeakMessage(msg) },
                                    onExtractSchedules = { vm.extractSchedulesForMessage(msg) },
                                    onRegenerate = { vm.regenerateMessage(msg) },
                                    onCompareWithAnother = { compareSourceMessage = msg },
                                    onApproveMemory = { fact -> vm.approveProposedMemory(msg, fact) },
                                    onDismissMemory = { fact -> vm.dismissProposedMemory(msg, fact) },
                                    onOpenCitation = openCitation,
                                    onToggleBookmark = { vm.toggleBookmark(msg) },
                                    onToggleExcluded = { vm.toggleExcludedFromContext(msg) },
                                    onDeleteDivider = { vm.deleteContextDivider(msg) },
                                    onGenerateFlashcards = { vm.generateFlashcardsForMessage(msg) },
                                    onGenerateQuiz = { vm.generateQuizForMessage(msg) },
                                    onSaveCard = { card -> vm.saveDraftCardsToDeck(msg, listOf(card)) },
                                    onSaveAllCards = { vm.saveDraftCardsToDeck(msg, msg.assistanceMetadata.generatedFlashcards) },
                                    onSelectQuizOption = { qId, optIdx -> vm.selectQuizOption(msg, qId, optIdx) },
                                    onOpenFlashcardLibrary = onOpenFlashcards
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

                    val hasGroupFeeds = conv.groupMembers.any { !it.isMuted && it.persona?.feeds?.any { f -> f.enabled } == true }
                    if (hasGroupFeeds) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = if (state.isGenerating || state.isRefreshingFeeds) 0.4f else 0.9f),
                            modifier = Modifier.clickable(enabled = !state.isGenerating && !state.isRefreshingFeeds) {
                                vm.refreshPersonaFeeds()
                            }
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                            ) {
                                if (state.isRefreshingFeeds) {
                                    CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 1.8.dp)
                                } else {
                                    Icon(Icons.Filled.RssFeed, contentDescription = null, modifier = Modifier.size(14.dp))
                                }
                                Text(L10n.text("检查动态", "Feeds"), style = MaterialTheme.typography.labelSmall)
                            }
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
                    if (!conv.isArenaMode) {
                        val coachMode = conv.assistanceSettings.studyCoachMode
                        FilterChip(
                            selected = coachMode != StudyCoachMode.OFF,
                            onClick = { showCoachDialog = true },
                            enabled = !state.isGenerating,
                            leadingIcon = {
                                Icon(Icons.Filled.School, contentDescription = null, modifier = Modifier.size(15.dp))
                            },
                            label = {
                                Text(
                                    text = coachMode.shortBadge,
                                    style = MaterialTheme.typography.labelSmall
                                )
                            }
                        )
                    }
                }

                val coachMode = conv.assistanceSettings.studyCoachMode
                if (!conv.isArenaMode && coachMode != StudyCoachMode.OFF && coachMode.quickChips.isNotEmpty()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = DS.Spacing.md, vertical = 2.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        for (chip in coachMode.quickChips) {
                            Surface(
                                shape = CircleShape,
                                color = MaterialTheme.colorScheme.secondaryContainer.copy(
                                    alpha = if (state.isGenerating) 0.4f else 0.9f
                                ),
                                modifier = Modifier.clickable(enabled = !state.isGenerating) {
                                    vm.sendQuickPrompt(chip.prompt)
                                }
                            ) {
                                Text(
                                    text = chip.label,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSecondaryContainer,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
                                )
                            }
                        }
                    }
                }
            }

            state.quotedExcerpt?.let { quote ->
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.md, vertical = 2.dp)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.sm, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.FormatQuote,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(16.dp)
                        )
                        Text(
                            text = quote,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f)
                        )
                        IconButton(onClick = { vm.setQuotedExcerpt(null) }, modifier = Modifier.size(22.dp)) {
                            Icon(Icons.Filled.Close, contentDescription = null, modifier = Modifier.size(14.dp))
                        }
                    }
                }
            }

            state.temporaryTargetOverride?.let { overrideTarget ->
                if (conv != null && !conv.isGroupMode && !conv.isArenaMode) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DS.Spacing.md, vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primaryContainer
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Text(
                                    text = L10n.text(
                                        "本条临时使用 @${overrideTarget.modelDisplayName}",
                                        "One-turn model: @${overrideTarget.modelDisplayName}"
                                    ),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onPrimaryContainer
                                )
                                Icon(
                                    imageVector = Icons.Filled.Close,
                                    contentDescription = L10n.text("取消临时指定", "Clear override"),
                                    tint = MaterialTheme.colorScheme.onPrimaryContainer,
                                    modifier = Modifier
                                        .size(14.dp)
                                        .clickable { vm.setTemporaryTargetOverride(null) }
                                )
                            }
                        }
                    }
                }
            }

            val slashMatches = remember(state.draftText) { SlashPromptCommand.matching(state.draftText) }
            if (slashMatches.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = DS.Spacing.md, vertical = 3.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    for (cmd in slashMatches) {
                        Surface(
                            onClick = { vm.applySlashCommand(cmd) },
                            shape = RoundedCornerShape(DS.Radius.sm),
                            color = MaterialTheme.colorScheme.surfaceVariant,
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.45f))
                        ) {
                            Column(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
                            ) {
                                Text(
                                    text = "${cmd.command} · ${cmd.title}",
                                    style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                    color = MaterialTheme.colorScheme.primary
                                )
                                Text(
                                    text = cmd.subtitle,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.widthIn(max = 200.dp)
                                )
                            }
                        }
                    }
                }
            }

            val mentionTargets = remember(state.draftText, readyTargets, conv?.isGroupMode, conv?.isArenaMode) {
                val query = if (conv != null && !conv.isGroupMode && !conv.isArenaMode) {
                    ModelMentionParser.activeMentionQuery(state.draftText)
                } else null
                if (query == null) emptyList() else ModelMentionParser.matchingTargets(query, readyTargets)
            }
            if (mentionTargets.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = DS.Spacing.md, vertical = 3.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    for (mTarget in mentionTargets) {
                        Surface(
                            onClick = { vm.selectMentionOverride(mTarget) },
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.75f)
                        ) {
                            Text(
                                text = "@${mTarget.modelDisplayName} (${mTarget.providerName})",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
                            )
                        }
                    }
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

                IconButton(
                    onClick = {
                        val speechIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
                            putExtra(RecognizerIntent.EXTRA_PROMPT, L10n.text("请说话…", "Speak now…"))
                        }
                        val launched = runCatching { speechLauncher.launch(speechIntent) }.isSuccess
                        if (!launched) {
                            vm.reportBannerError(
                                L10n.text(
                                    "当前设备未安装系统语音识别服务。",
                                    "No system speech recognizer is available on this device."
                                )
                            )
                        }
                    },
                    enabled = !state.isGenerating
                ) {
                    Icon(
                        imageVector = Icons.Filled.Mic,
                        contentDescription = L10n.text("语音输入", "Voice Input")
                    )
                }

                OutlinedTextField(
                    value = state.draftText,
                    onValueChange = vm::updateDraftText,
                    modifier = Modifier.weight(1f),
                    placeholder = { Text(L10n.text("输入消息…", "Message…")) },
                    maxLines = 5,
                    shape = RoundedCornerShape(DS.Radius.lg)
                )

                val canSendDraft = state.draftText.isNotBlank() ||
                    state.draftAttachments.isNotEmpty() ||
                    !state.quotedExcerpt.isNullOrBlank()
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

    if (showCoachDialog && conv != null) {
        val currentCoach = conv.assistanceSettings.studyCoachMode
        AlertDialog(
            onDismissRequest = { showCoachDialog = false },
            title = { Text(L10n.text("选择助学导师模式", "Study Coach Mode")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (mode in StudyCoachMode.entries) {
                        val selected = currentCoach == mode
                        Surface(
                            shape = RoundedCornerShape(DS.Radius.sm),
                            color = if (selected) MaterialTheme.colorScheme.primaryContainer
                            else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    vm.setStudyCoachMode(mode)
                                    showCoachDialog = false
                                }
                        ) {
                            Column(
                                modifier = Modifier.padding(DS.Spacing.sm),
                                verticalArrangement = Arrangement.spacedBy(2.dp)
                            ) {
                                Text(
                                    text = mode.displayName,
                                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold)
                                )
                                Text(
                                    text = mode.subtitle,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showCoachDialog = false }) {
                    Text(L10n.text("关闭", "Close"))
                }
            }
        )
    }

    if (showInChatSearch) {
        var inChatQuery by remember { mutableStateOf("") }
        var inChatBookmarksOnly by remember { mutableStateOf(false) }
        val accent = LocalAccentColors.current
        val inChatHits = remember(state.messages, inChatQuery, inChatBookmarksOnly) {
            ConversationSearch.inConversation(
                messages = state.messages,
                query = inChatQuery,
                bookmarksOnly = inChatBookmarksOnly
            )
        }
        val msgById = remember(state.messages) { state.messages.associateBy { it.id } }

        ModalBottomSheet(onDismissRequest = { showInChatSearch = false }) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.lg)
                    .padding(bottom = DS.Spacing.xxl),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = L10n.text("本对话搜索与收藏", "Search & Bookmarks"),
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                    )
                    FilterChip(
                        selected = inChatBookmarksOnly,
                        onClick = { inChatBookmarksOnly = !inChatBookmarksOnly },
                        leadingIcon = {
                            Icon(Icons.Filled.Bookmark, contentDescription = null, modifier = Modifier.size(15.dp))
                        },
                        label = { Text(L10n.text("仅看收藏", "Bookmarked Only")) }
                    )
                }

                OutlinedTextField(
                    value = inChatQuery,
                    onValueChange = { inChatQuery = it },
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    placeholder = { Text(L10n.text("搜索关键词、代码或文件名…", "Search messages…")) },
                    modifier = Modifier.fillMaxWidth()
                )

                if (inChatHits.isEmpty()) {
                    Text(
                        text = L10n.text("暂无匹配消息或收藏记录。", "No matching messages or bookmarks."),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 18.dp)
                    )
                } else {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 320.dp)
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        for (hit in inChatHits) {
                            val hitMsg = msgById[hit.messageID] ?: continue
                            Surface(
                                shape = RoundedCornerShape(DS.Radius.sm),
                                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        val entryIndex = timelineEntries.indexOfFirst { entry ->
                                            when (entry) {
                                                is ChatTimelineEntry.SingleMessage -> entry.message.id == hit.messageID
                                                is ChatTimelineEntry.ArenaGroup -> entry.messages.any { it.id == hit.messageID }
                                            }
                                        }
                                        showInChatSearch = false
                                        if (entryIndex >= 0) {
                                            scope.launch { listState.animateScrollToItem(entryIndex) }
                                        }
                                    }
                            ) {
                                Column(
                                    modifier = Modifier.padding(DS.Spacing.sm),
                                    verticalArrangement = Arrangement.spacedBy(3.dp)
                                ) {
                                    Text(
                                        text = if (hitMsg.role == MessageRole.USER) L10n.text("提问", "You")
                                        else hitMsg.modelDisplayName.ifBlank { "Assistant" },
                                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                        color = accent.readableText
                                    )
                                    val ex = hit.excerpt
                                    if (ex != null) {
                                        val annotated = buildAnnotatedString {
                                            append(ex.before)
                                            withStyle(SpanStyle(color = accent.readableText, fontWeight = FontWeight.Bold)) {
                                                append(ex.match)
                                            }
                                            append(ex.after)
                                        }
                                        Text(
                                            text = annotated,
                                            style = MaterialTheme.typography.bodySmall,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    } else {
                                        Text(
                                            text = hitMsg.content,
                                            style = MaterialTheme.typography.bodySmall,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis
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

    exportStatusAlert?.let { msg ->
        AlertDialog(
            onDismissRequest = { exportStatusAlert = null },
            title = { Text(L10n.text("导出提示", "Export")) },
            text = { Text(msg) },
            confirmButton = {
                Button(onClick = { exportStatusAlert = null }) {
                    Text(L10n.text("好", "OK"))
                }
            }
        )
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

    editingBranchMessage?.let { origMsg ->
        AlertDialog(
            onDismissRequest = { editingBranchMessage = null },
            title = { Text(L10n.text("编辑并新建分支", "Edit & Create Branch")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = L10n.text(
                            "将在原位置创建一条并行分支，原消息与后续回复会完整保留。",
                            "Creates a parallel branch at this turn while keeping your previous history intact."
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    OutlinedTextField(
                        value = editingBranchText,
                        onValueChange = { editingBranchText = it },
                        minLines = 3,
                        maxLines = 8,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = editingBranchText.trim().isNotEmpty(),
                    onClick = {
                        vm.editAndBranchUserMessage(origMsg, editingBranchText)
                        editingBranchMessage = null
                    }
                ) {
                    Text(L10n.text("发送新分支", "Send Branch"))
                }
            },
            dismissButton = {
                TextButton(onClick = { editingBranchMessage = null }) {
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
    branchSiblings: List<ChatMessageItem>,
    canEditUser: Boolean,
    canRegenerate: Boolean,
    canCompareWithAnother: Boolean,
    canStudyGenerate: Boolean,
    isStudyGenerating: Boolean,
    canExtractSchedule: Boolean,
    isScheduleExtracting: Boolean,
    isSpeaking: Boolean,
    onSwitchBranch: (ChatMessageItem) -> Unit,
    onEditUserMessage: () -> Unit,
    onQuoteReply: () -> Unit,
    onRegenerate: () -> Unit,
    onToggleSpeak: () -> Unit,
    onExtractSchedules: () -> Unit,
    onCompareWithAnother: () -> Unit,
    onApproveMemory: (String) -> Unit,
    onDismissMemory: (String) -> Unit,
    onOpenCitation: (ReadingCitation) -> Unit,
    onToggleBookmark: () -> Unit,
    onToggleExcluded: () -> Unit,
    onDeleteDivider: () -> Unit,
    onGenerateFlashcards: () -> Unit,
    onGenerateQuiz: () -> Unit,
    onSaveCard: (StudyCardDraft) -> Unit,
    onSaveAllCards: () -> Unit,
    onSelectQuizOption: (String, Int) -> Unit,
    onOpenFlashcardLibrary: () -> Unit
) {
    val context = LocalContext.current
    val accent = LocalAccentColors.current
    val meta = message.assistanceMetadata

    if (meta.isContextDivider) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            HorizontalDivider(modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.surfaceVariant
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Text(
                        text = message.content,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = L10n.text("移除分隔线", "Remove divider"),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier
                            .size(14.dp)
                            .clickable(onClick = onDeleteDivider)
                    )
                }
            }
            HorizontalDivider(modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
        }
        return
    }

    val excludedModifier = if (meta.isExcludedFromContext) Modifier.alpha(0.55f) else Modifier

    if (message.role == MessageRole.USER) {
        Column(
            modifier = excludedModifier.fillMaxWidth(),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            if (!meta.quotedExcerpt.isNullOrBlank()) {
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f),
                    modifier = Modifier.widthIn(max = 310.dp)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.sm, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.FormatQuote,
                            contentDescription = null,
                            tint = accent.readableText,
                            modifier = Modifier.size(14.dp)
                        )
                        Text(
                            text = meta.quotedExcerpt,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
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
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(2.dp)
            ) {
                if (meta.isExcludedFromContext) {
                    Text(
                        text = L10n.text("已排除", "Excluded"),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(end = 4.dp)
                    )
                }
                if (branchSiblings.size > 1) {
                    BranchSwitcherPill(
                        currentMessage = message,
                        siblings = branchSiblings,
                        onSwitchBranch = onSwitchBranch
                    )
                }
                if (canEditUser) {
                    IconButton(onClick = onEditUserMessage, modifier = Modifier.size(24.dp)) {
                        Icon(
                            imageVector = Icons.Filled.Edit,
                            contentDescription = L10n.text("编辑并分支", "Edit & Branch"),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(14.dp)
                        )
                    }
                }
                IconButton(onClick = onToggleBookmark, modifier = Modifier.size(24.dp)) {
                    Icon(
                        imageVector = if (meta.isBookmarked) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder,
                        contentDescription = L10n.text("收藏", "Bookmark"),
                        tint = if (meta.isBookmarked) accent.readableText else MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp)
                    )
                }
                IconButton(onClick = onToggleExcluded, modifier = Modifier.size(24.dp)) {
                    Icon(
                        imageVector = if (meta.isExcludedFromContext) Icons.Filled.Visibility else Icons.Filled.VisibilityOff,
                        contentDescription = L10n.text("从上下文排除", "Toggle Context"),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp)
                    )
                }
            }
        }
    } else {
        val groupSpeaker = meta.groupSpeakerDisplayTitle
        val speakerColor = DS.parseHexColor(message.accentHex)

        Column(
            modifier = excludedModifier.fillMaxWidth(),
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

            val sourceNotice = meta.sourceNotice
            if (sourceNotice != null) {
                SourceNoticeCard(notice = sourceNotice)
            } else if (message.content.isNotEmpty()) {
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

            MessageStudyDeckCard(
                drafts = meta.generatedFlashcards,
                quiz = meta.generatedQuiz,
                onSaveCard = onSaveCard,
                onSaveAllCards = onSaveAllCards,
                onSelectQuizOption = onSelectQuizOption,
                onOpenFlashcardLibrary = onOpenFlashcardLibrary
            )

            if (meta.proposedSchedules.isNotEmpty()) {
                ProposedSchedulesCard(items = meta.proposedSchedules)
            }

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
                    if (branchSiblings.size > 1) {
                        BranchSwitcherPill(
                            currentMessage = message,
                            siblings = branchSiblings,
                            onSwitchBranch = onSwitchBranch
                        )
                    }
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
                        if (meta.sourceNotice == null) {
                            IconButton(
                                onClick = onQuoteReply,
                                modifier = Modifier.size(28.dp)
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.FormatQuote,
                                    contentDescription = L10n.text("引用追问", "Quote Reply"),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(15.dp)
                                )
                            }
                        }
                        IconButton(
                            onClick = onToggleSpeak,
                            modifier = Modifier.size(28.dp)
                        ) {
                            Icon(
                                imageVector = if (isSpeaking) Icons.Filled.StopCircle else Icons.AutoMirrored.Filled.VolumeUp,
                                contentDescription = if (isSpeaking) L10n.text("停止朗读", "Stop Speaking") else L10n.text("语音朗读", "Read Aloud"),
                                tint = if (isSpeaking) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
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
                    IconButton(onClick = onToggleBookmark, modifier = Modifier.size(28.dp)) {
                        Icon(
                            imageVector = if (meta.isBookmarked) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder,
                            contentDescription = L10n.text("收藏消息", "Bookmark"),
                            tint = if (meta.isBookmarked) accent.readableText else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                    IconButton(onClick = onToggleExcluded, modifier = Modifier.size(28.dp)) {
                        Icon(
                            imageVector = if (meta.isExcludedFromContext) Icons.Filled.Visibility else Icons.Filled.VisibilityOff,
                            contentDescription = L10n.text("切换是否计入上下文", "Toggle Context Inclusion"),
                            tint = if (meta.isExcludedFromContext) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(15.dp)
                        )
                    }
                    if (isStudyGenerating) {
                        CircularProgressIndicator(modifier = Modifier.size(15.dp), strokeWidth = 1.8.dp)
                    } else if (canStudyGenerate) {
                        IconButton(onClick = onGenerateFlashcards, modifier = Modifier.size(28.dp)) {
                            Icon(
                                imageVector = Icons.Filled.Style,
                                contentDescription = L10n.text("提炼闪卡", "Generate Flashcards"),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(15.dp)
                            )
                        }
                        IconButton(onClick = onGenerateQuiz, modifier = Modifier.size(28.dp)) {
                            Icon(
                                imageVector = Icons.Filled.Quiz,
                                contentDescription = L10n.text("随堂测验", "Generate Quiz"),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(15.dp)
                            )
                        }
                    }
                    if (isScheduleExtracting) {
                        CircularProgressIndicator(modifier = Modifier.size(15.dp), strokeWidth = 1.8.dp)
                    } else if (canExtractSchedule) {
                        IconButton(onClick = onExtractSchedules, modifier = Modifier.size(28.dp)) {
                            Icon(
                                imageVector = Icons.Filled.EventAvailable,
                                contentDescription = L10n.text("提取日程", "Extract Schedule"),
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(15.dp)
                            )
                        }
                    }
                    val metaParts = buildList {
                        if (meta.isExcludedFromContext) add(L10n.text("已排除", "Excluded"))
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
private fun BranchSwitcherPill(
    currentMessage: ChatMessageItem,
    siblings: List<ChatMessageItem>,
    onSwitchBranch: (ChatMessageItem) -> Unit
) {
    val idx = siblings.indexOfFirst { it.id == currentMessage.id }.takeIf { it >= 0 } ?: 0
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.85f)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 1.dp)
        ) {
            IconButton(
                onClick = { if (idx > 0) onSwitchBranch(siblings[idx - 1]) },
                enabled = idx > 0,
                modifier = Modifier.size(20.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.ChevronLeft,
                    contentDescription = L10n.text("上一分支", "Previous branch"),
                    modifier = Modifier.size(14.dp)
                )
            }
            Text(
                text = "${idx + 1} / ${siblings.size}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            IconButton(
                onClick = { if (idx + 1 < siblings.size) onSwitchBranch(siblings[idx + 1]) },
                enabled = idx + 1 < siblings.size,
                modifier = Modifier.size(20.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.ChevronRight,
                    contentDescription = L10n.text("下一分支", "Next branch"),
                    modifier = Modifier.size(14.dp)
                )
            }
        }
    }
}

@Composable
private fun SourceNoticeCard(notice: GroupSourceNotice) {
    val context = LocalContext.current
    Surface(
        shape = RoundedCornerShape(DS.Radius.md),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.45f)),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(DS.Spacing.md),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.RssFeed,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(15.dp)
                )
                Text(
                    text = notice.byline,
                    style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.primary
                )
            }
            Text(
                text = notice.title,
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface
            )
            if (!notice.excerpt.isNullOrBlank()) {
                Text(
                    text = notice.excerpt,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis
                )
            }
            Surface(
                onClick = {
                    runCatching {
                        context.startActivity(Intent(Intent.ACTION_VIEW, notice.url.toUri()))
                    }
                },
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.OpenInNew,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.size(13.dp)
                    )
                    Text(
                        text = L10n.text("打开原文", "Open Link"),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onPrimaryContainer
                    )
                }
            }
        }
    }
}

@Composable
private fun ProposedSchedulesCard(items: List<ProposedScheduleItem>) {
    val context = LocalContext.current
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        for (item in items) {
            Surface(
                shape = RoundedCornerShape(DS.Radius.sm),
                color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.55f),
                border = BorderStroke(0.5.dp, MaterialTheme.colorScheme.outlineVariant),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(DS.Spacing.md),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.primaryContainer
                        ) {
                            Text(
                                text = item.kind.badgeTitle,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimaryContainer,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                            )
                        }
                        ProposedScheduleItem.formatDisplaySchedule(item)?.let { formattedTime ->
                            Text(
                                text = formattedTime,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    Text(
                        text = item.title,
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    if (item.notes.isNotBlank()) {
                        Text(
                            text = item.notes,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Surface(
                        onClick = { CalendarIntentLauncher.launchCalendarInsert(context, item) },
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.primary
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.EventAvailable,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onPrimary,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = item.kind.confirmButtonTitle,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onPrimary
                            )
                        }
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
