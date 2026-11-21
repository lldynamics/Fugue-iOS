package com.iosbox.app.ui.study

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Quiz
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Style
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.StudyCardDraft
import com.iosbox.app.core.model.StudyQuizBundle
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors

@Composable
internal fun MessageStudyDeckCard(
    drafts: List<StudyCardDraft>,
    quiz: StudyQuizBundle?,
    onSaveCard: (StudyCardDraft) -> Unit,
    onSaveAllCards: () -> Unit,
    onSelectQuizOption: (questionID: String, optionIndex: Int) -> Unit,
    onOpenFlashcardLibrary: () -> Unit
) {
    if (drafts.isEmpty() && quiz == null) return
    val accent = LocalAccentColors.current

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (drafts.isNotEmpty()) {
            Surface(
                shape = RoundedCornerShape(DS.Radius.sm),
                color = accent.softFill.copy(alpha = 0.55f),
                border = BorderStroke(1.dp, accent.solidFill.copy(alpha = 0.35f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(DS.Spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Style,
                                contentDescription = null,
                                tint = accent.readableText,
                                modifier = Modifier.size(16.dp)
                            )
                            Text(
                                text = L10n.text("提炼学习闪卡 (${drafts.size} 张)", "Study Flashcards (${drafts.size})"),
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                color = accent.readableText
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            TextButton(onClick = onOpenFlashcardLibrary) {
                                Text(L10n.text("去复习", "Review"), style = MaterialTheme.typography.labelSmall)
                            }
                            Button(onClick = onSaveAllCards) {
                                Text(L10n.text("全部加入卡包", "Save All"), style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }

                    drafts.forEachIndexed { idx, card ->
                        if (idx > 0) {
                            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "${idx + 1}. ${card.front}",
                                    style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold),
                                    modifier = Modifier.weight(1f)
                                )
                                TextButton(onClick = { onSaveCard(card) }) {
                                    Text(L10n.text("收卡", "Save"), style = MaterialTheme.typography.labelSmall)
                                }
                            }
                            Text(
                                text = card.back,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            val hint = card.hint
                            if (!hint.isNullOrBlank()) {
                                Text(
                                    text = "💡 $hint",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = accent.readableText
                                )
                            }
                        }
                    }
                }
            }
        }

        if (quiz != null) {
            Surface(
                shape = RoundedCornerShape(DS.Radius.sm),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(DS.Spacing.sm),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Quiz,
                                contentDescription = null,
                                tint = accent.readableText,
                                modifier = Modifier.size(16.dp)
                            )
                            Text(
                                text = quiz.title,
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                color = accent.readableText
                            )
                        }
                        if (quiz.answeredCount > 0) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                Icon(
                                    imageVector = Icons.Filled.School,
                                    contentDescription = null,
                                    tint = accent.readableText,
                                    modifier = Modifier.size(14.dp)
                                )
                                Text(
                                    text = "${quiz.correctCount}/${quiz.questions.size}",
                                    style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                                    color = accent.readableText
                                )
                            }
                        }
                    }

                    quiz.questions.forEachIndexed { qIdx, q ->
                        if (qIdx > 0) {
                            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(
                                text = "${qIdx + 1}. ${q.question}",
                                style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.SemiBold)
                            )
                            q.options.forEachIndexed { optIdx, optionText ->
                                val isPicked = q.selectedIndex == optIdx
                                val isRight = q.correctIndex == optIdx
                                val bgColor = when {
                                    !q.isAnswered -> MaterialTheme.colorScheme.surface
                                    isRight -> Color(0xFF16A34A).copy(alpha = 0.16f)
                                    isPicked && !isRight -> MaterialTheme.colorScheme.error.copy(alpha = 0.16f)
                                    else -> MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
                                }
                                val borderColor = when {
                                    !q.isAnswered -> MaterialTheme.colorScheme.outline.copy(alpha = 0.35f)
                                    isRight -> Color(0xFF16A34A)
                                    isPicked -> MaterialTheme.colorScheme.error
                                    else -> MaterialTheme.colorScheme.outline.copy(alpha = 0.25f)
                                }
                                Surface(
                                    shape = RoundedCornerShape(DS.Radius.xs),
                                    color = bgColor,
                                    border = BorderStroke(1.dp, borderColor),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable(enabled = !q.isAnswered) {
                                            onSelectQuizOption(q.id, optIdx)
                                        }
                                ) {
                                    Row(
                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                                    ) {
                                        Text(
                                            text = "${('A' + optIdx)}. $optionText",
                                            style = MaterialTheme.typography.bodySmall,
                                            modifier = Modifier.weight(1f)
                                        )
                                        if (q.isAnswered && isRight) {
                                            Icon(
                                                imageVector = Icons.Filled.CheckCircle,
                                                contentDescription = null,
                                                tint = Color(0xFF16A34A),
                                                modifier = Modifier.size(14.dp)
                                            )
                                        }
                                    }
                                }
                            }
                            if (q.isAnswered && q.explanation.isNotBlank()) {
                                Surface(
                                    shape = RoundedCornerShape(DS.Radius.xs),
                                    color = MaterialTheme.colorScheme.surface
                                ) {
                                    Text(
                                        text = L10n.text("解析：${q.explanation}", "Explanation: ${q.explanation}"),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(DS.Spacing.xs)
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
