package com.iosbox.app.ui.system

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Language
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.network.ReadablePage
import com.iosbox.app.core.network.WebpageReader
import com.iosbox.app.core.storage.AttachmentProcessor
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ChatDraft
import com.iosbox.app.core.system.ExternalEntryRouter
import com.iosbox.app.core.system.ExternalSharePayload
import com.iosbox.app.core.system.InitialConversationDraft
import com.iosbox.app.core.system.ShareReadingAction
import com.iosbox.app.ui.chat.ModelPickerSheet
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URI

@Composable
fun ExternalShareDialog(
    payload: ExternalSharePayload,
    container: AppContainer,
    isCurrent: () -> Boolean,
    onDismiss: () -> Unit,
    onOpenConversation: (String) -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val providers by container.chatRepository.observeProviders().collectAsStateWithLifecycle(initialValue = emptyList())
    val readyTargets = remember(providers) { ChatRepository.readyTargets(providers) }
    val prefs by container.preferences.state.collectAsStateWithLifecycle()
    val defaultTargetId = prefs.defaultTargetID

    var selectedTarget by remember(readyTargets, defaultTargetId) {
        mutableStateOf<ResolvedModelTarget?>(
            defaultTargetId?.let { id -> readyTargets.firstOrNull { it.id == id } } ?: readyTargets.firstOrNull()
        )
    }
    var selectedAction by remember { mutableStateOf(ShareReadingAction.DEEP_SUMMARY) }
    var fetchedPage by remember { mutableStateOf<ReadablePage?>(null) }
    var isFetchingUrl by remember { mutableStateOf(false) }
    var isCreating by remember { mutableStateOf(false) }
    var isCommitting by remember { mutableStateOf(false) }
    var preparation by remember { mutableStateOf<Job?>(null) }
    val missingReadGrant = L10n.text("共享附件缺少读取授权，请从原应用重新分享。",
        "The attachment is missing a read grant. Share it again from the source app.")
    var errorText by remember(payload) { mutableStateOf(if (payload.attachmentsRejected) missingReadGrant else null) }
    var showModelPicker by remember { mutableStateOf(false) }
    val cancel = {
        preparation?.cancel()
        onDismiss()
    }

    AlertDialog(
        onDismissRequest = { if (!isCommitting) cancel() },
        title = {
            Text(
                text = if (payload.isProcessText) {
                    L10n.text("用夜奔解读选区", "Analyze Highlight with Fugue")
                } else {
                    L10n.text("发送到夜奔分析", "Send to Fugue")
                }
            )
        },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.sm),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        val previewTitle = fetchedPage?.title?.ifBlank { null } ?: payload.subject
                        if (!previewTitle.isNullOrBlank()) {
                            Text(
                                text = previewTitle,
                                style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold),
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        val previewBody = fetchedPage?.text ?: payload.sharedText
                        if (previewBody.isNotBlank()) {
                            Text(
                                text = previewBody,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 5,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        if (payload.streamUris.isNotEmpty()) {
                            Text(
                                text = L10n.text(
                                    "包含 ${payload.streamUris.size} 个分享文件",
                                    "${payload.streamUris.size} attached file(s)"
                                ),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary
                            )
                        }
                    }
                }

                val url = payload.detectedHttpsUrl
                if (url != null && fetchedPage == null) {
                    OutlinedButton(
                        enabled = !isFetchingUrl && !isCreating,
                        onClick = {
                            scope.launch {
                                isFetchingUrl = true
                                errorText = null
                                runCatching {
                                    withContext(Dispatchers.IO) {
                                        WebpageReader.read(URI(url))
                                    }
                                }.onSuccess { page ->
                                    fetchedPage = page
                                }.onFailure { err ->
                                    errorText = err.message ?: L10n.text("网页正文读取失败", "Failed to read webpage")
                                }
                                isFetchingUrl = false
                            }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        if (isFetchingUrl) {
                            CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 1.8.dp)
                        } else {
                            Icon(Icons.Filled.Language, contentDescription = null, modifier = Modifier.size(16.dp))
                        }
                        Spacer(modifier = Modifier.size(6.dp))
                        Text(L10n.text("抓取网页正文精读", "Fetch Webpage Content"))
                    }
                }

                Text(
                    text = L10n.text("分析方式", "Action"),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    for (action in ShareReadingAction.entries) {
                        FilterChip(
                            selected = selectedAction == action,
                            onClick = { selectedAction = action },
                            label = { Text(action.label, style = MaterialTheme.typography.labelSmall) }
                        )
                    }
                }

                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.45f)),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = readyTargets.isNotEmpty() && !isCreating) {
                            showModelPicker = true
                        }
                ) {
                    Column(modifier = Modifier.padding(DS.Spacing.sm)) {
                        Text(
                            text = L10n.text("使用模型（点击切换）", "Model (tap to switch)"),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = selectedTarget?.let { "${it.providerName} · ${it.modelDisplayName}" }
                                ?: L10n.text("请先在「服务商」配置可用模型", "Configure a ready model first"),
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium)
                        )
                    }
                }

                errorText?.let { err ->
                    Text(
                        text = err,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }
        },
        confirmButton = {
            Button(
                enabled = !isCreating && !isFetchingUrl,
                onClick = {
                    isCreating = true
                    val target = selectedTarget
                    preparation = scope.launch {
                        errorText = null
                        val page = fetchedPage
                        val rawBody = page?.text ?: payload.sharedText
                        val prompt = selectedAction.buildPrompt(
                            body = rawBody,
                            pageTitle = page?.title ?: payload.subject,
                            sourceUrl = page?.url ?: payload.detectedHttpsUrl
                        )
                        val titleHint = (page?.title ?: payload.subject ?: payload.sharedText)
                            .trim()
                            .lineSequence()
                            .firstOrNull()
                            .orEmpty()
                            .take(28)
                            .ifEmpty { L10n.text("分享精读", "Shared Reading") }

                        try {
                            if (payload.attachmentsRejected) throw SecurityException(missingReadGrant)
                            val processedAttachments = AttachmentProcessor.processSharedBatch(
                                context.contentResolver, payload.streamUris.map { it.toUri() }
                            ) {
                                if (!ExternalEntryRouter.canReadSharedAttachment(context, it)) throw SecurityException(missingReadGrant)
                            }
                            ensureActive()
                            if (!isCurrent()) return@launch
                            isCommitting = true
                            val conversation = container.chatRepository.createConversation(
                                primaryTarget = target,
                                initialTitle = titleHint,
                                initialDraft = ChatDraft(text = prompt, attachments = processedAttachments),
                                isCurrent = isCurrent
                            )
                            ensureActive()
                            if (!isCurrent()) return@launch
                            container.externalEntryRouter.stageInitialDraft(
                                conversationId = conversation.id,
                                draft = InitialConversationDraft(
                                    text = prompt,
                                    attachments = processedAttachments,
                                    autoSend = target != null && container.preferences.isConsentAccepted
                                )
                            )
                            onOpenConversation(conversation.id)
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (err: Exception) {
                            errorText = err.message ?: L10n.text("附件处理失败", "Failed to read shared files")
                        } finally {
                            isCreating = false
                            isCommitting = false
                        }
                    }
                }
            ) {
                Text(L10n.text("开始分析", "Analyze"))
            }
        },
        dismissButton = {
            TextButton(enabled = !isCommitting, onClick = cancel) {
                Text(L10n.text("取消", "Cancel"))
            }
        }
    )

    if (showModelPicker) {
        ModelPickerSheet(
            providers = providers,
            selectedTargetId = selectedTarget?.id,
            onSelect = { selectedTarget = it },
            onDismiss = { showModelPicker = false }
        )
    }
}
