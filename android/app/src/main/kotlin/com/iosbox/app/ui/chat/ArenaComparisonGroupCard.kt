package com.iosbox.app.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.ViewColumn
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ReadingCitation
import com.iosbox.app.core.network.ArenaSynthesis
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors

@Composable
fun ArenaComparisonGroupCard(
    groupID: String,
    messages: List<ChatMessageItem>,
    isBlindMode: Boolean,
    isGenerating: Boolean,
    onOpenBallot: () -> Unit,
    onToggleBlindMode: () -> Unit,
    onFollowUp: (ChatMessageItem) -> Unit,
    onRegenerateSingle: (ChatMessageItem) -> Unit,
    onSynthesize: () -> Unit,
    onCrossCritique: () -> Unit,
    onOpenCitation: (ReadingCitation) -> Unit
) {
    val accent = LocalAccentColors.current
    val originals = remember(messages) { messages.filter { !it.isSynthesis } }
    val isRevealed = remember(messages, isBlindMode) {
        ArenaSynthesis.isGroupRevealed(messages, isBlindMode)
    }
    var activeTabID by remember(groupID) { mutableStateOf<String?>(null) }
    var sideBySideLayout by remember(groupID) { mutableStateOf(false) }

    val synthesisCount = messages.count { it.isSynthesis }
    LaunchedEffect(synthesisCount) {
        val lastSynthesis = messages.lastOrNull { it.isSynthesis }
        if (lastSynthesis != null) {
            activeTabID = lastSynthesis.id
        }
    }

    if (!isRevealed) {
        val blindOrdered = remember(originals, groupID) {
            ArenaSynthesis.blindDisplayOrder(originals, groupID)
        }
        val completeCount = originals.count(ArenaSynthesis::isComplete)
        Surface(
            shape = RoundedCornerShape(DS.Radius.lg),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(DS.Spacing.md),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.VisibilityOff,
                        contentDescription = null,
                        tint = accent.readableText,
                        modifier = Modifier.size(16.dp)
                    )
                    Text(
                        text = L10n.text(
                            "双盲竞技场 · ${originals.size} 个匿名候选 ($completeCount/${originals.size} 已完成)",
                            "Blind Arena · ${originals.size} Anonymous Candidates ($completeCount/${originals.size} Ready)"
                        ),
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold)
                    )
                }

                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    blindOrdered.forEachIndexed { idx, msg ->
                        val statusText = when {
                            msg.isStreaming -> L10n.text("生成中", "Streaming")
                            msg.errorMessage != null -> L10n.text("失败", "Failed")
                            ArenaSynthesis.isComplete(msg) -> L10n.text("就绪", "Ready")
                            else -> L10n.text("未完成", "Incomplete")
                        }
                        Surface(
                            shape = CircleShape,
                            color = MaterialTheme.colorScheme.surface
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                if (msg.isStreaming) {
                                    CircularProgressIndicator(modifier = Modifier.size(10.dp), strokeWidth = 1.6.dp)
                                }
                                Text(
                                    text = "${ArenaSynthesis.blindLabel(idx)} · $statusText",
                                    style = MaterialTheme.typography.labelSmall
                                )
                            }
                        }
                    }
                }

                Button(
                    onClick = onOpenBallot,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(L10n.text("进入双盲对比与投票", "Enter Blind Ballot & Vote"))
                }
            }
        }
        return
    }

    val currentActiveMessage = remember(messages, activeTabID) {
        messages.firstOrNull { it.id == activeTabID }
            ?: messages.firstOrNull { it.isSelectedInGroup }
            ?: messages.firstOrNull()
    }
    val completeCount = originals.count(ArenaSynthesis::isComplete)

    Surface(
        shape = RoundedCornerShape(DS.Radius.lg),
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.7f)),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.38f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(DS.Spacing.md),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.ViewColumn,
                    contentDescription = null,
                    tint = accent.readableText,
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    text = L10n.text(
                        "多模型并发对比 (${originals.size})",
                        "Model Arena (${originals.size})"
                    ),
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                if (isBlindMode) {
                    TextButton(
                        onClick = onOpenBallot,
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)
                    ) {
                        Text(
                            text = L10n.text("查看选票", "Ballot"),
                            style = MaterialTheme.typography.labelSmall
                        )
                    }
                }
                FilterChip(
                    selected = isBlindMode,
                    onClick = onToggleBlindMode,
                    leadingIcon = {
                        Icon(
                            imageVector = if (isBlindMode) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                            contentDescription = null,
                            modifier = Modifier.size(14.dp)
                        )
                    },
                    label = {
                        Text(
                            text = L10n.text("双盲", "Blind"),
                            style = MaterialTheme.typography.labelSmall
                        )
                    }
                )
                FilterChip(
                    selected = sideBySideLayout,
                    onClick = { sideBySideLayout = !sideBySideLayout },
                    label = {
                        Text(
                            text = if (sideBySideLayout) L10n.text("标签视图", "Tabs") else L10n.text("并排横滑", "Side-by-Side"),
                            style = MaterialTheme.typography.labelSmall
                        )
                    }
                )
            }

            if (isBlindMode && messages.none { it.assistanceMetadata.blindArenaBallot != null }) {
                Text(
                    text = L10n.text("此轮已揭晓，未记录独立选票。", "Revealed without a recorded ballot."),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            if (sideBySideLayout) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.md)
                ) {
                    for (msg in messages) {
                        SingleModelArenaCard(
                            message = msg,
                            groupMessages = messages,
                            isGenerating = isGenerating,
                            onFollowUp = { onFollowUp(msg) },
                            onRegenerate = { onRegenerateSingle(msg) },
                            onOpenCitation = onOpenCitation,
                            modifier = Modifier.width(308.dp)
                        )
                    }
                }
            } else {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    for (msg in messages) {
                        val isTabSelected = currentActiveMessage?.id == msg.id
                        val chipLabel = if (msg.isSynthesis) {
                            L10n.text("汇总 · ${msg.modelDisplayName}", "Judge · ${msg.modelDisplayName}")
                        } else {
                            msg.modelDisplayName.ifBlank { msg.providerName }
                        }
                        Surface(
                            shape = CircleShape,
                            color = if (isTabSelected) MaterialTheme.colorScheme.surface else MaterialTheme.colorScheme.surfaceVariant,
                            border = BorderStroke(
                                width = 1.dp,
                                color = if (isTabSelected) accent.solidFill.copy(alpha = 0.55f) else MaterialTheme.colorScheme.outline.copy(alpha = 0.25f)
                            ),
                            modifier = Modifier.clickable { activeTabID = msg.id }
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(7.dp)
                                        .clip(CircleShape)
                                        .background(DS.parseHexColor(msg.accentHex))
                                )
                                Text(
                                    text = chipLabel,
                                    style = MaterialTheme.typography.labelMedium.copy(
                                        fontWeight = if (isTabSelected) FontWeight.SemiBold else FontWeight.Normal
                                    ),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                when {
                                    msg.isStreaming -> {
                                        CircularProgressIndicator(modifier = Modifier.size(11.dp), strokeWidth = 1.6.dp)
                                    }
                                    msg.errorMessage != null -> {
                                        Icon(
                                            imageVector = Icons.Filled.ErrorOutline,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.error,
                                            modifier = Modifier.size(13.dp)
                                        )
                                    }
                                    msg.isSelectedInGroup -> {
                                        Icon(
                                            imageVector = Icons.Filled.CheckCircle,
                                            contentDescription = null,
                                            tint = accent.readableText,
                                            modifier = Modifier.size(13.dp)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                if (currentActiveMessage != null) {
                    SingleModelArenaCard(
                        message = currentActiveMessage,
                        groupMessages = messages,
                        isGenerating = isGenerating,
                        onFollowUp = { onFollowUp(currentActiveMessage) },
                        onRegenerate = { onRegenerateSingle(currentActiveMessage) },
                        onOpenCitation = onOpenCitation,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                OutlinedButton(
                    onClick = onSynthesize,
                    enabled = !isGenerating && completeCount >= 2,
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.AutoAwesome,
                        contentDescription = null,
                        modifier = Modifier.size(15.dp)
                    )
                    Spacer(modifier = Modifier.size(6.dp))
                    Text(
                        text = L10n.text("由裁判模型综合提炼", "Synthesize with Judge"),
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold)
                    )
                }

                OutlinedButton(
                    onClick = onCrossCritique,
                    enabled = !isGenerating && completeCount >= 2,
                    contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp)
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.CompareArrows,
                        contentDescription = null,
                        modifier = Modifier.size(15.dp)
                    )
                    Spacer(modifier = Modifier.size(6.dp))
                    Text(
                        text = L10n.text("互评修正", "Cross-Critique"),
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium)
                    )
                }
            }

            if (completeCount < 2) {
                Text(
                    text = L10n.text("至少需要两条完整答案才能汇总。", "At least 2 complete answers are required to synthesize."),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun SingleModelArenaCard(
    message: ChatMessageItem,
    groupMessages: List<ChatMessageItem>,
    isGenerating: Boolean,
    onFollowUp: () -> Unit,
    onRegenerate: () -> Unit,
    onOpenCitation: (ReadingCitation) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val accent = LocalAccentColors.current
    val isStaleSynthesis = message.isSynthesis && !ArenaSynthesis.isCurrent(message, groupMessages)

    Surface(
        shape = RoundedCornerShape(DS.Radius.md),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(
            width = 1.dp,
            color = if (message.isSelectedInGroup) accent.solidFill.copy(alpha = 0.5f) else MaterialTheme.colorScheme.outline.copy(alpha = 0.45f)
        ),
        modifier = modifier
    ) {
        Column(
            modifier = Modifier.padding(DS.Spacing.md),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.xs)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Row(
                    modifier = Modifier.weight(1f),
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
                        text = message.modelDisplayName.ifBlank { "Assistant" },
                        style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    if (message.providerName.isNotBlank()) {
                        Text(
                            text = "· ${message.providerName}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    if (message.isStreaming) {
                        CircularProgressIndicator(modifier = Modifier.size(12.dp), strokeWidth = 1.8.dp)
                    }
                }
                if (message.isSynthesis) {
                    Surface(
                        shape = CircleShape,
                        color = accent.softFill
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.AutoAwesome,
                                contentDescription = null,
                                tint = accent.readableText,
                                modifier = Modifier.size(11.dp)
                            )
                            Text(
                                text = L10n.text("裁判汇总", "Synthesis"),
                                style = MaterialTheme.typography.labelSmall,
                                color = accent.readableText
                            )
                        }
                    }
                } else if (message.assistanceMetadata.blindArenaBallot != null) {
                    Surface(
                        shape = CircleShape,
                        color = accent.softFill
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.EmojiEvents,
                                contentDescription = null,
                                tint = accent.readableText,
                                modifier = Modifier.size(11.dp)
                            )
                            Text(
                                text = L10n.text("盲评得票", "Blind Winner"),
                                style = MaterialTheme.typography.labelSmall,
                                color = accent.readableText
                            )
                        }
                    }
                }
            }

            if (isStaleSynthesis) {
                Text(
                    text = L10n.text(
                        "原答案已更新，此汇总已过期，不会用于后续上下文。请重新汇总。",
                        "Source answers updated; this synthesis is stale and won't be used as context."
                    ),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            ReasoningCard(
                reasoningText = message.reasoningContent,
                isStreaming = message.isStreaming && message.content.isEmpty(),
                thinkingDurationMs = message.thinkingDurationMs
            )

            if (message.attachments.isNotEmpty()) {
                AttachmentStrip(message.attachments)
            }

            message.assistanceMetadata.search?.let { search ->
                SearchCitationsCard(search = search)
            }

            message.assistanceMetadata.knowledgeEvidence?.let { knowledge ->
                KnowledgeCitationsCard(knowledge = knowledge, onOpenCitation = onOpenCitation)
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
                    IconButton(
                        onClick = onRegenerate,
                        enabled = !isGenerating,
                        modifier = Modifier.size(28.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Refresh,
                            contentDescription = L10n.text("重答", "Regenerate"),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp)
                        )
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

            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f))

            val canSelectFollowUp = !isGenerating &&
                (!message.isSynthesis || (ArenaSynthesis.isComplete(message) && ArenaSynthesis.isCurrent(message, groupMessages)))
            OutlinedButton(
                onClick = onFollowUp,
                enabled = canSelectFollowUp,
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
            ) {
                if (message.isSelectedInGroup) {
                    Icon(
                        imageVector = Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = accent.readableText,
                        modifier = Modifier.size(15.dp)
                    )
                    Spacer(modifier = Modifier.size(5.dp))
                    Text(
                        text = L10n.text("当前追问回复", "Selected Context Reply"),
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold)
                    )
                } else {
                    Text(
                        text = L10n.text("沿这条回答追问", "Use This Reply for Follow-Ups"),
                        style = MaterialTheme.typography.labelSmall
                    )
                }
            }
        }
    }
}
