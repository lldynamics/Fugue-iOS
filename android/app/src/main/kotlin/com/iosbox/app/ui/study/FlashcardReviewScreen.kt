package com.iosbox.app.ui.study

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.StudyFlashcard
import com.iosbox.app.core.model.StudyReviewRating
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private enum class StudyTabMode {
    REVIEW,
    BROWSE
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FlashcardReviewScreen(
    container: AppContainer,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val repo = container.flashcardRepository
    val cards by repo.cards.collectAsStateWithLifecycle()
    val accent = LocalAccentColors.current

    var selectedDeck by remember { mutableStateOf<String?>(null) }
    var tabMode by remember { mutableStateOf(StudyTabMode.REVIEW) }
    var browseQuery by remember { mutableStateOf("") }
    var nowClock by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var showAnswer by remember { mutableStateOf(false) }
    var showHint by remember { mutableStateOf(false) }
    var showEditorFor by remember { mutableStateOf<StudyFlashcard?>(null) }
    var showNewCardDialog by remember { mutableStateOf(false) }
    var pendingTsvExport by remember { mutableStateOf<String?>(null) }
    var exportAlert by remember { mutableStateOf<String?>(null) }

    val deckNames = remember(cards) { repo.deckNames(cards) }
    val dueQueue = remember(cards, selectedDeck, nowClock) {
        repo.dueCards(deck = selectedDeck, nowEpochMs = nowClock)
    }
    val browseList = remember(cards, selectedDeck, browseQuery) {
        repo.filteredCards(deck = selectedDeck, query = browseQuery)
    }
    val masteredCount = remember(cards) { cards.count { it.isMastered } }
    val currentCard = dueQueue.firstOrNull()

    val exportTsvLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("text/tab-separated-values")
    ) { uri ->
        val content = pendingTsvExport
        pendingTsvExport = null
        if (uri == null || content == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use {
                        it.write(content.toByteArray(Charsets.UTF_8))
                    } ?: error("Cannot write export file")
                }
            }.onSuccess {
                exportAlert = L10n.text("Anki TSV 已导出。", "Anki TSV exported successfully.")
            }.onFailure { err ->
                exportAlert = err.message ?: L10n.text("导出失败", "Export failed")
            }
        }
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
                        Text(
                            text = L10n.text("学习闪卡库 (SM-2)", "Study Flashcards (SM-2)"),
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                        )
                        Text(
                            text = L10n.text(
                                "待复习 ${dueQueue.size} · 已掌握 $masteredCount · 共 ${cards.size} 张",
                                "${dueQueue.size} due · $masteredCount mastered · ${cards.size} total"
                            ),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                },
                actions = {
                    IconButton(
                        enabled = cards.isNotEmpty(),
                        onClick = {
                            pendingTsvExport = repo.exportAnkiTSV(deckFilter = selectedDeck)
                            val ts = SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date())
                            exportTsvLauncher.launch("Fugue-AnkiCards-$ts.tsv")
                        }
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Upload,
                            contentDescription = L10n.text("导出 Anki (.tsv)", "Export Anki TSV")
                        )
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showNewCardDialog = true }) {
                Icon(Icons.Filled.Add, contentDescription = L10n.text("新建闪卡", "New Flashcard"))
            }
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = DS.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                FilterChip(
                    selected = tabMode == StudyTabMode.REVIEW,
                    onClick = {
                        tabMode = StudyTabMode.REVIEW
                        nowClock = System.currentTimeMillis()
                    },
                    label = { Text(L10n.text("复习模式 (${dueQueue.size})", "Review (${dueQueue.size})")) }
                )
                FilterChip(
                    selected = tabMode == StudyTabMode.BROWSE,
                    onClick = { tabMode = StudyTabMode.BROWSE },
                    label = { Text(L10n.text("卡库管理 (${cards.size})", "Library (${cards.size})")) }
                )
            }

            if (deckNames.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    FilterChip(
                        selected = selectedDeck == null,
                        onClick = {
                            selectedDeck = null
                            showAnswer = false
                            showHint = false
                        },
                        label = { Text(L10n.text("全部卡组", "All Decks")) }
                    )
                    for (deck in deckNames) {
                        FilterChip(
                            selected = selectedDeck == deck,
                            onClick = {
                                selectedDeck = deck
                                showAnswer = false
                                showHint = false
                            },
                            label = { Text(deck, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                        )
                    }
                }
            }

            if (tabMode == StudyTabMode.REVIEW) {
                if (cards.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth(),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = L10n.text(
                                "还没有学习闪卡。\n在对话回复下方点击「制卡」自动提炼，或点击右下角 + 手动添加。",
                                "No flashcards yet.\nGenerate cards from any AI reply or tap + below to add one manually."
                            ),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                } else if (currentCard == null) {
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth(),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.CheckCircle,
                                contentDescription = null,
                                tint = accent.readableText,
                                modifier = Modifier.size(44.dp)
                            )
                            Text(
                                text = L10n.text("今日待复习已全部完成！", "All Due Cards Reviewed!"),
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                            )
                            Text(
                                text = L10n.text(
                                    "当前筛选共有 ${repo.filteredCards(selectedDeck).size} 张卡片，已掌握 $masteredCount 张。",
                                    "${repo.filteredCards(selectedDeck).size} cards in selection · $masteredCount mastered."
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            OutlinedButton(onClick = { tabMode = StudyTabMode.BROWSE }) {
                                Text(L10n.text("浏览全部卡片", "Browse All Cards"))
                            }
                        }
                    }
                } else {
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth()
                            .padding(vertical = DS.Spacing.sm),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
                    ) {
                        Card(
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.45f)),
                            shape = RoundedCornerShape(DS.Radius.lg),
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth()
                                .clickable { showAnswer = !showAnswer }
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxSize()
                                    .padding(DS.Spacing.xl),
                                verticalArrangement = Arrangement.SpaceBetween
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Surface(shape = CircleShape, color = accent.softFill) {
                                        Text(
                                            text = currentCard.deckName,
                                            style = MaterialTheme.typography.labelSmall,
                                            color = accent.readableText,
                                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 3.dp)
                                        )
                                    }
                                    Text(
                                        text = if (showAnswer) L10n.text("点击翻回正面", "Tap to flip back")
                                        else L10n.text("点击查看答案", "Tap to reveal"),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }

                                Column(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalArrangement = Arrangement.spacedBy(12.dp)
                                ) {
                                    Text(
                                        text = currentCard.front,
                                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold)
                                    )
                                    val hint = currentCard.hint
                                    if (!hint.isNullOrBlank()) {
                                        if (showHint || showAnswer) {
                                            Text(
                                                text = "💡 $hint",
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant
                                            )
                                        } else {
                                            TextButton(onClick = { showHint = true }) {
                                                Text(L10n.text("显示记忆提示", "Show Hint"))
                                            }
                                        }
                                    }
                                    if (showAnswer) {
                                        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f))
                                        Text(
                                            text = currentCard.back,
                                            style = MaterialTheme.typography.bodyLarge
                                        )
                                    }
                                }

                                Text(
                                    text = L10n.text(
                                        "复习次数 ${currentCard.repetitions} · 难度系数 ${String.format(Locale.US, "%.2f", currentCard.easeFactor)}",
                                        "Reps ${currentCard.repetitions} · EF ${String.format(Locale.US, "%.2f", currentCard.easeFactor)}"
                                    ),
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        if (!showAnswer) {
                            Button(
                                onClick = { showAnswer = true },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(L10n.text("显示答案", "Show Answer"))
                            }
                        } else {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                val ratingColors = mapOf(
                                    StudyReviewRating.AGAIN to MaterialTheme.colorScheme.error,
                                    StudyReviewRating.HARD to Color(0xFFD97706),
                                    StudyReviewRating.GOOD to accent.solidFill,
                                    StudyReviewRating.EASY to Color(0xFF16A34A)
                                )
                                for (rating in StudyReviewRating.entries) {
                                    Button(
                                        onClick = {
                                            val ts = System.currentTimeMillis()
                                            repo.recordReview(currentCard.id, rating, nowEpochMs = ts)
                                            nowClock = ts
                                            showAnswer = false
                                            showHint = false
                                        },
                                        colors = ButtonDefaults.buttonColors(
                                            containerColor = ratingColors[rating] ?: accent.solidFill,
                                            contentColor = Color.White
                                        ),
                                        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 8.dp),
                                        modifier = Modifier.weight(1f)
                                    ) {
                                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                            Text(
                                                text = rating.title,
                                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold)
                                            )
                                            Text(
                                                text = currentCard.nextIntervalLabel(rating),
                                                style = MaterialTheme.typography.labelSmall
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                OutlinedTextField(
                    value = browseQuery,
                    onValueChange = { browseQuery = it },
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    placeholder = { Text(L10n.text("搜索问题、答案或卡组…", "Search cards…")) },
                    modifier = Modifier.fillMaxWidth()
                )
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(bottom = 88.dp),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
                ) {
                    items(browseList, key = { it.id }) { card ->
                        Card(
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { showEditorFor = card }
                        ) {
                            Row(
                                modifier = Modifier.padding(DS.Spacing.md),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                                        Surface(shape = CircleShape, color = accent.softFill) {
                                            Text(
                                                text = card.deckName,
                                                style = MaterialTheme.typography.labelSmall,
                                                color = accent.readableText,
                                                modifier = Modifier.padding(horizontal = 7.dp, vertical = 1.dp)
                                            )
                                        }
                                        val statusLabel = when {
                                            card.isMastered -> L10n.text("已掌握", "Mastered")
                                            card.isDue(nowClock) -> L10n.text("待复习", "Due")
                                            else -> L10n.text("间隔 ${card.intervalDays.toInt()} 天", "${card.intervalDays.toInt()}d")
                                        }
                                        Text(
                                            text = statusLabel,
                                            style = MaterialTheme.typography.labelSmall,
                                            color = if (card.isDue(nowClock)) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                    Text(
                                        text = card.front,
                                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        text = card.back,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                }
                                IconButton(onClick = { repo.deleteCard(card.id) }) {
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
    }

    if (showNewCardDialog || showEditorFor != null) {
        val editing = showEditorFor
        var deck by remember(editing?.id) { mutableStateOf(editing?.deckName ?: selectedDeck ?: "") }
        var front by remember(editing?.id) { mutableStateOf(editing?.front ?: "") }
        var back by remember(editing?.id) { mutableStateOf(editing?.back ?: "") }
        var hint by remember(editing?.id) { mutableStateOf(editing?.hint ?: "") }

        AlertDialog(
            onDismissRequest = {
                showNewCardDialog = false
                showEditorFor = null
            },
            title = {
                Text(
                    if (editing == null) L10n.text("新建闪卡", "New Flashcard")
                    else L10n.text("编辑闪卡", "Edit Flashcard")
                )
            },
            text = {
                Column(
                    modifier = Modifier.heightIn(max = 420.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedTextField(
                        value = deck,
                        onValueChange = { deck = it },
                        singleLine = true,
                        label = { Text(L10n.text("卡组名称（可选）", "Deck Name")) },
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = front,
                        onValueChange = { front = it },
                        minLines = 2,
                        maxLines = 4,
                        label = { Text(L10n.text("正面（问题）", "Front (Question)")) },
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = back,
                        onValueChange = { back = it },
                        minLines = 3,
                        maxLines = 6,
                        label = { Text(L10n.text("背面（答案）", "Back (Answer)")) },
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = hint,
                        onValueChange = { hint = it },
                        singleLine = true,
                        label = { Text(L10n.text("记忆提示（可选）", "Hint (optional)")) },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = front.trim().isNotEmpty() && back.trim().isNotEmpty(),
                    onClick = {
                        if (editing == null) {
                            repo.addCard(deckName = deck, front = front, back = back, hint = hint)
                        } else {
                            repo.updateCard(editing.id, deckName = deck, front = front, back = back, hint = hint)
                        }
                        showNewCardDialog = false
                        showEditorFor = null
                    }
                ) {
                    Text(L10n.text("保存", "Save"))
                }
            },
            dismissButton = {
                TextButton(onClick = {
                    showNewCardDialog = false
                    showEditorFor = null
                }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    exportAlert?.let { msg ->
        AlertDialog(
            onDismissRequest = { exportAlert = null },
            title = { Text(L10n.text("导出结果", "Export Result")) },
            text = { Text(msg) },
            confirmButton = {
                Button(onClick = { exportAlert = null }) {
                    Text(L10n.text("好", "OK"))
                }
            }
        )
    }
}
