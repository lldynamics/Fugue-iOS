package com.iosbox.app.ui.chat

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.network.ArenaSynthesis
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BlindBallotDialog(
    groupID: String,
    question: ChatMessageItem?,
    messages: List<ChatMessageItem>,
    isGenerating: Boolean,
    initialAnswerId: String? = null,
    onVote: (ChatMessageItem) -> Unit,
    onDismiss: () -> Unit
) {
    val candidates = remember(messages, groupID) {
        ArenaSynthesis.blindDisplayOrder(
            ArenaSynthesis.sources(messages, groupID),
            groupID
        )
    }
    val eligible = remember(candidates) { candidates.filter(ArenaSynthesis::isComplete) }
    val revealed = remember(candidates) { candidates.any { it.assistanceMetadata.blindArenaRevealed } }

    var selectedID by remember(groupID) { mutableStateOf<String?>(null) }
    var visibleID by remember(groupID, initialAnswerId) {
        mutableStateOf(initialAnswerId ?: candidates.firstOrNull()?.id)
    }
    var openedIDs by remember(groupID) { mutableStateOf(emptySet<String>()) }

    val activeIndex = remember(candidates, visibleID) {
        val idx = candidates.indexOfFirst { it.id == visibleID }
        if (idx >= 0) idx else 0
    }
    val visibleCandidate = candidates.getOrNull(activeIndex)
    LaunchedEffect(visibleCandidate?.id) {
        visibleCandidate?.id?.let { openedIDs = openedIDs + it }
    }
    val accent = LocalAccentColors.current

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = L10n.text("关闭", "Close"))
                        }
                    },
                    title = {
                        Text(
                            text = L10n.text("双盲对比", "Blind Ballot"),
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                        )
                    }
                )
            },
            bottomBar = {
                if (!revealed) {
                    val chosen = eligible.firstOrNull { it.id == selectedID }
                    val canVote = !isGenerating && eligible.size >= 2 && chosen != null
                    Surface(tonalElevation = 3.dp) {
                        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.md)) {
                            val hint = when {
                                isGenerating -> L10n.text("等待回答完成后再投票。", "Wait for the answers to finish before voting.")
                                eligible.size < 2 -> L10n.text("至少需要两个完整回答才能投票。", "At least two complete answers are required to vote.")
                                chosen == null -> L10n.text("请选择一个回答后投票。", "Select an answer before voting.")
                                else -> null
                            }
                            if (hint != null) {
                                Text(text = hint, style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(bottom = DS.Spacing.sm))
                            }
                            Button(
                                onClick = { if (chosen != null) onVote(chosen) },
                                enabled = canVote,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(
                                    text = L10n.text("投票并揭晓", "Vote & Reveal"),
                                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                                )
                            }
                        }
                    }
                }
            }
        ) { innerPadding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding)
                    .verticalScroll(rememberScrollState())
                    .padding(DS.Spacing.lg),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
            ) {
                if (question != null) {
                    if (question.content.isNotBlank()) {
                        Text(
                            text = question.content,
                            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                            textAlign = TextAlign.Start,
                            modifier = Modifier.fillMaxWidth()
                        )
                    } else {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(Icons.Filled.AttachFile, contentDescription = null)
                            Text(
                                text = L10n.text("附件消息", "Attachment message"),
                                style = MaterialTheme.typography.titleMedium
                            )
                        }
                    }
                }

                Text(
                    text = if (revealed) {
                        L10n.text("已揭晓模型身份", "Model identities revealed")
                    } else {
                        L10n.text("盲评阅览所有答案，投票选出最佳回复后揭晓模型", "Review blindly, vote for the winner, then reveal model identities")
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                if (candidates.isNotEmpty()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        candidates.forEachIndexed { idx, candidate ->
                            val letter = ArenaSynthesis.blindLetter(idx)
                            val isViewing = visibleCandidate?.id == candidate.id
                            val isPicked = if (revealed) {
                                candidate.assistanceMetadata.blindArenaBallot != null
                            } else {
                                selectedID == candidate.id
                            }
                            FilterChip(
                                selected = isViewing,
                                onClick = { visibleID = candidate.id },
                                label = {
                                    Text(
                                        text = if (isPicked) "✓ $letter" else letter,
                                        fontWeight = if (isViewing) FontWeight.Bold else FontWeight.Normal
                                    )
                                }
                            )
                        }
                    }
                    if (!revealed) {
                        val opened = candidates.count { it.id in openedIDs }
                        Text(
                            text = if (opened < candidates.size) {
                                L10n.text("已打开 $opened/${candidates.size} 个回答，建议先比较。",
                                    "Opened $opened/${candidates.size} answers. Consider comparing them first.")
                            } else {
                                L10n.text("已打开 $opened/${candidates.size} 个回答。", "Opened $opened/${candidates.size} answers.")
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                if (visibleCandidate != null) {
                    val letter = ArenaSynthesis.blindLetter(activeIndex)
                    val checked = if (revealed) {
                        visibleCandidate.assistanceMetadata.blindArenaBallot != null
                    } else {
                        selectedID == visibleCandidate.id
                    }
                    val selectable = !revealed && !isGenerating && ArenaSynthesis.isComplete(visibleCandidate)

                    Surface(
                        shape = RoundedCornerShape(DS.Radius.lg),
                        border = BorderStroke(
                            width = if (checked) 1.5.dp else 1.dp,
                            color = if (checked) accent.solidFill else MaterialTheme.colorScheme.outline
                        ),
                        color = MaterialTheme.colorScheme.surface,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(
                            modifier = Modifier.padding(DS.Spacing.lg),
                            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = selectable) {
                                        selectedID = visibleCandidate.id
                                    }
                                    .padding(vertical = 4.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Icon(
                                    imageVector = if (checked) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                                    contentDescription = null,
                                    tint = if (checked) accent.solidFill else MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                Text(
                                    text = L10n.text("回答 $letter", "Answer $letter"),
                                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                    modifier = Modifier.weight(1f)
                                )
                                if (revealed && visibleCandidate.assistanceMetadata.blindArenaBallot != null) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                                    ) {
                                        Icon(
                                            imageVector = Icons.Filled.EmojiEvents,
                                            contentDescription = null,
                                            tint = accent.readableText,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Text(
                                            text = L10n.text("本轮胜出", "Winner"),
                                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                                            color = accent.readableText
                                        )
                                    }
                                }
                            }

                            if (revealed) {
                                Text(
                                    text = "${visibleCandidate.providerName} · ${visibleCandidate.modelDisplayName}",
                                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                                    color = DS.parseHexColor(visibleCandidate.accentHex)
                                )
                            }

                            if (visibleCandidate.content.isNotEmpty()) {
                                MarkdownMessageContent(markdown = visibleCandidate.content)
                            }

                            if (visibleCandidate.isStreaming) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                                    Text(
                                        text = L10n.text("正在生成…", "Streaming…"),
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            } else if (!ArenaSynthesis.isComplete(visibleCandidate)) {
                                Text(
                                    text = visibleCandidate.errorMessage
                                        ?: visibleCandidate.finishReasonValue?.userNotice
                                        ?: L10n.text("此回答未完成", "This answer did not complete"),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error
                                )
                            }
                        }
                    }
                }

                Spacer(modifier = Modifier.height(16.dp))
            }
        }
    }
}
