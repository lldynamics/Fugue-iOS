package com.iosbox.app.ui.chat

import android.graphics.BitmapFactory
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
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
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatDetailScreen(
    conversationId: String,
    container: AppContainer,
    onBack: () -> Unit,
    onGoToProviders: () -> Unit
) {
    val vm: ChatViewModel = viewModel(
        key = "chat_$conversationId",
        factory = ChatViewModel.factory(conversationId, container)
    )
    val state by vm.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val listState = rememberLazyListState()

    var showModelPicker by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }
    var showAttachMenu by remember { mutableStateOf(false) }

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

    LaunchedEffect(state.messages.size, state.messages.lastOrNull()?.content?.length) {
        if (state.messages.isNotEmpty()) {
            listState.scrollToItem(state.messages.lastIndex)
        }
    }

    val conv = state.conversation
    val readyTargets = remember(state.providers) { ChatRepository.readyTargets(state.providers) }
    val activeTarget = conv?.primaryTarget ?: readyTargets.firstOrNull()

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
                            text = activeTarget?.let { "${it.providerName} · ${it.modelDisplayName}" }
                                ?: L10n.text("未配置可用模型（点击选择）", "No ready model (tap to choose)"),
                            style = MaterialTheme.typography.labelSmall,
                            color = if (activeTarget != null) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.error,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.clickable { showModelPicker = true }
                        )
                    }
                },
                actions = {
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
                if (state.messages.isEmpty()) {
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
                                    text = L10n.text("纯本地直连 · 开始提问", "Local Direct · Ask anything"),
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
                    items(state.messages, key = { it.id }) { msg ->
                        MessageBubbleRow(
                            message = msg,
                            canRegenerate = !state.isGenerating && msg.role == MessageRole.ASSISTANT,
                            onRegenerate = { vm.regenerateMessage(msg) }
                        )
                    }
                }
            }

            HorizontalDivider(color = MaterialTheme.colorScheme.outline)

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
                } else {
                    val canSend = state.draftText.isNotBlank() || state.draftAttachments.isNotEmpty()
                    IconButton(
                        onClick = { vm.sendCurrentDraft() },
                        enabled = canSend,
                        modifier = Modifier
                            .size(44.dp)
                            .clip(CircleShape)
                            .background(
                                if (canSend) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.surfaceVariant
                            )
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Send,
                            contentDescription = L10n.text("发送", "Send"),
                            tint = if (canSend) MaterialTheme.colorScheme.onPrimary
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

    if (showSettings && conv != null) {
        ChatSettingsSheet(
            conversation = conv,
            presets = state.presets,
            onSave = vm::updateConversationSettings,
            onDismiss = { showSettings = false }
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

    state.pendingConsent?.let { consent ->
        AIConsentDialog(
            targetSummary = consent.recipientSummary,
            onAccept = vm::acceptConsent,
            onDismiss = vm::dismissConsent
        )
    }
}

@Composable
private fun MessageBubbleRow(
    message: ChatMessageItem,
    canRegenerate: Boolean,
    onRegenerate: () -> Unit
) {
    val clipboard = LocalClipboardManager.current
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
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.xs)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(8.dp)
                        .clip(CircleShape)
                        .background(DS.parseHexColor(message.accentHex))
                )
                Text(
                    text = listOf(message.providerName, message.modelDisplayName)
                        .filter { it.isNotBlank() }
                        .joinToString(" · ")
                        .ifEmpty { "Assistant" },
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (message.isStreaming) {
                    CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 1.8.dp)
                }
            }

            ReasoningCard(
                reasoningText = message.reasoningContent,
                isStreaming = message.isStreaming && message.content.isEmpty(),
                thinkingDurationMs = message.thinkingDurationMs
            )

            if (message.attachments.isNotEmpty()) {
                AttachmentStrip(message.attachments)
            }

            if (message.content.isNotEmpty()) {
                MarkdownMessageContent(markdown = message.content)
            } else if (message.isStreaming && message.reasoningContent.isEmpty()) {
                Text(
                    text = L10n.text("正在连接模型…", "Waiting for response…"),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
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

            if (!message.isStreaming) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    if (message.content.isNotEmpty()) {
                        IconButton(
                            onClick = { clipboard.setText(AnnotatedString(message.content)) },
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
private fun AttachmentStrip(attachments: List<MessageAttachment>) {
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
