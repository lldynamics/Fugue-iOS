package com.iosbox.app.ui.books

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ReadingCitation
import com.iosbox.app.core.storage.BookReadingPage
import com.iosbox.app.core.storage.ShelfReadingStateItem
import com.iosbox.app.ui.theme.DS
import com.iosbox.app.ui.theme.LocalAccentColors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookReaderSheet(
    container: AppContainer,
    volumeID: String,
    throughChapter: Int? = null,
    initialCitation: ReadingCitation? = null,
    companionConversationID: String? = null,
    onQuotePassage: ((String) -> Unit)? = null,
    onDismiss: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    val dark = isSystemInDarkTheme()
    val paperBackground = if (dark) MaterialTheme.colorScheme.surfaceVariant else Color(0xFFFBF8F3)
    val accent = LocalAccentColors.current

    var bookTitle by remember(volumeID) { mutableStateOf(initialCitation?.documentTitle ?: "") }
    var visibleChapters by remember(volumeID, throughChapter) { mutableStateOf<List<BookChapter>>(emptyList()) }
    var activeChapter by remember(volumeID) { mutableIntStateOf(0) }
    var activeCitation by remember(volumeID, initialCitation) { mutableStateOf(initialCitation) }
    var page by remember { mutableStateOf<BookReadingPage?>(null) }
    var errorMessage by remember(volumeID) { mutableStateOf<String?>(null) }
    var showChapterMenu by remember { mutableStateOf(false) }

    LaunchedEffect(volumeID, throughChapter) {
        errorMessage = null
        try {
            val loaded = withContext(Dispatchers.IO) {
                val book = container.chatRepository.getBook(volumeID) ?: throw BookImportError.Unavailable()
                val allChapters = container.chatRepository.loadBookChapters(volumeID)
                val scoped = BookReadingPage.chaptersThrough(allChapters, throughChapter)
                val saved = if (throughChapter == null) container.chatRepository.getShelfState(volumeID) else null
                Triple(book.title, scoped, saved)
            }
            val (title, scoped, saved) = loaded
            bookTitle = title
            visibleChapters = scoped
            val startChapter = activeCitation?.chapterIndex?.takeIf { it in scoped.indices }
                ?: saved?.chapter?.takeIf { it in scoped.indices }
                ?: 0
            activeChapter = startChapter
            val built = withContext(Dispatchers.IO) {
                BookReadingPage.make(scoped, preferredChapter = startChapter, citation = activeCitation)
            }
            page = built
            activeChapter = built.chapterIndex

            val targetParagraph = if (built.located) {
                built.paragraphs.indexOfFirst { it.highlightRange != null }.takeIf { it >= 0 } ?: 0
            } else {
                built.clampedParagraph(saved?.paragraph)
            }
            if (targetParagraph > 0) {
                listState.scrollToItem(targetParagraph + 1)
            }
        } catch (t: Throwable) {
            errorMessage = t.message ?: L10n.text("无法读取原文", "Failed to load book")
        }
    }

    LaunchedEffect(activeChapter, activeCitation) {
        val scoped = visibleChapters
        if (scoped.isEmpty()) return@LaunchedEffect
        runCatching {
            withContext(Dispatchers.IO) {
                BookReadingPage.make(scoped, preferredChapter = activeChapter, citation = activeCitation)
            }
        }.onSuccess { built ->
            page = built
            activeChapter = built.chapterIndex
            val highlightIdx = built.paragraphs.indexOfFirst { it.highlightRange != null }
            if (built.located && highlightIdx >= 0) {
                listState.scrollToItem(highlightIdx + 1)
            } else if (activeCitation == null) {
                listState.scrollToItem(0)
            }
        }.onFailure { t ->
            errorMessage = t.message ?: L10n.text("无法读取章节", "Failed to load chapter")
        }
    }

    DisposableEffect(volumeID, throughChapter) {
        onDispose {
            if (throughChapter == null && visibleChapters.isNotEmpty()) {
                val pIdx = (listState.firstVisibleItemIndex - 1).coerceAtLeast(0)
                val chapter = activeChapter
                scope.launch {
                    val existing = container.chatRepository.getShelfState(volumeID)
                    container.chatRepository.saveShelfState(
                        ShelfReadingStateItem(
                            bookID = volumeID.uppercase(),
                            conversationID = companionConversationID ?: existing?.conversationID,
                            chapter = chapter,
                            paragraph = pIdx
                        )
                    )
                }
            }
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Scaffold(
            containerColor = paperBackground,
            topBar = {
                TopAppBar(
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = paperBackground),
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.Filled.Close, contentDescription = L10n.text("关闭", "Close"))
                        }
                    },
                    title = {
                        Column {
                            Text(
                                text = bookTitle.ifEmpty { L10n.text("原文阅读", "Book Reader") },
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            val chTitle = visibleChapters.getOrNull(activeChapter)?.title
                            if (chTitle != null) {
                                Text(
                                    text = chTitle,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    },
                    actions = {
                        if (visibleChapters.isNotEmpty()) {
                            Box {
                                TextButton(onClick = { showChapterMenu = true }) {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.MenuBook,
                                        contentDescription = null,
                                        modifier = Modifier.size(16.dp)
                                    )
                                    Spacer(modifier = Modifier.size(4.dp))
                                    Text(L10n.text("目录", "Chapters"))
                                }
                                DropdownMenu(
                                    expanded = showChapterMenu,
                                    onDismissRequest = { showChapterMenu = false }
                                ) {
                                    visibleChapters.forEachIndexed { idx, ch ->
                                        DropdownMenuItem(
                                            text = {
                                                Text(
                                                    text = ch.title,
                                                    fontWeight = if (idx == activeChapter) FontWeight.Bold else FontWeight.Normal,
                                                    color = if (idx == activeChapter) accent.readableText else MaterialTheme.colorScheme.onSurface,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis
                                                )
                                            },
                                            onClick = {
                                                showChapterMenu = false
                                                activeCitation = null
                                                activeChapter = idx
                                            }
                                        )
                                    }
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
            ) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))

                when {
                    errorMessage != null -> {
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth()
                                .padding(DS.Spacing.xl),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Text(
                                    text = errorMessage ?: "",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.error
                                )
                                val savedExcerpt = initialCitation?.excerpt
                                if (!savedExcerpt.isNullOrBlank()) {
                                    Surface(
                                        shape = MaterialTheme.shapes.small,
                                        color = MaterialTheme.colorScheme.surface
                                    ) {
                                        Text(
                                            text = savedExcerpt,
                                            style = MaterialTheme.typography.bodySmall,
                                            modifier = Modifier.padding(DS.Spacing.md)
                                        )
                                    }
                                }
                            }
                        }
                    }

                    page == null -> {
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .fillMaxWidth(),
                            contentAlignment = Alignment.Center
                        ) {
                            CircularProgressIndicator()
                        }
                    }

                    else -> {
                        val loadedPage = page
                        val currentChapter = visibleChapters.getOrNull(loadedPage?.chapterIndex ?: 0)
                        if (loadedPage != null && currentChapter != null) {
                            SelectionContainer(modifier = Modifier.weight(1f)) {
                                LazyColumn(
                                    state = listState,
                                    modifier = Modifier.fillMaxSize(),
                                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 20.dp),
                                    verticalArrangement = Arrangement.spacedBy(14.dp)
                                ) {
                                    item(key = "header_${loadedPage.chapterIndex}") {
                                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                            Text(
                                                text = currentChapter.title,
                                                style = MaterialTheme.typography.headlineSmall.copy(
                                                    fontFamily = FontFamily.Serif,
                                                    fontWeight = FontWeight.Bold
                                                )
                                            )
                                            val cite = activeCitation
                                            if (cite != null && !loadedPage.located) {
                                                Text(
                                                    text = L10n.text(
                                                        "未能在当前阅读范围内精确高亮定位该片段：",
                                                        "Could not pinpoint this excerpt in the current scope:"
                                                    ),
                                                    style = MaterialTheme.typography.labelSmall,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                                )
                                                Surface(color = accent.softFill, shape = MaterialTheme.shapes.small) {
                                                    Text(
                                                        text = cite.excerpt,
                                                        style = MaterialTheme.typography.bodySmall,
                                                        modifier = Modifier.padding(DS.Spacing.sm)
                                                    )
                                                }
                                            }
                                        }
                                    }

                                    items(loadedPage.paragraphs, key = { "${loadedPage.chapterIndex}_${it.id}" }) { p ->
                                        val highlight = p.highlightRange
                                        val annotated = remember(p.text, highlight) {
                                            if (highlight == null || highlight.first < 0 || highlight.last >= p.text.length) {
                                                buildAnnotatedString { append(p.text) }
                                            } else {
                                                buildAnnotatedString {
                                                    append(p.text)
                                                    addStyle(
                                                        style = SpanStyle(
                                                            background = Color(0xFFFFD54F).copy(alpha = 0.55f),
                                                            color = Color.Black
                                                        ),
                                                        start = highlight.first,
                                                        end = highlight.last + 1
                                                    )
                                                }
                                            }
                                        }
                                        val rowModifier = if (onQuotePassage != null) {
                                            Modifier
                                                .fillMaxWidth()
                                                .clickable {
                                                    onQuotePassage(p.text)
                                                    onDismiss()
                                                }
                                        } else {
                                            Modifier.fillMaxWidth()
                                        }
                                        Text(
                                            text = annotated,
                                            style = MaterialTheme.typography.bodyLarge.copy(
                                                fontFamily = FontFamily.Serif,
                                                fontSize = 18.sp,
                                                lineHeight = 29.sp
                                            ),
                                            modifier = rowModifier
                                        )
                                    }
                                }
                            }

                            val cite = activeCitation
                            if (loadedPage.located && cite != null && onQuotePassage != null) {
                                Surface(
                                    color = paperBackground,
                                    tonalElevation = 2.dp,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.xs),
                                        horizontalArrangement = Arrangement.End
                                    ) {
                                        Button(onClick = {
                                            onQuotePassage(cite.excerpt)
                                            onDismiss()
                                        }) {
                                            Icon(
                                                imageVector = Icons.Filled.FormatQuote,
                                                contentDescription = null,
                                                modifier = Modifier.size(16.dp)
                                            )
                                            Spacer(modifier = Modifier.size(6.dp))
                                            Text(L10n.text("就这段提问", "Ask About Excerpt"))
                                        }
                                    }
                                }
                            }

                            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.25f))
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(paperBackground)
                                    .padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.xs),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                OutlinedButton(
                                    enabled = activeChapter > 0,
                                    onClick = {
                                        activeCitation = null
                                        activeChapter = (activeChapter - 1).coerceAtLeast(0)
                                    }
                                ) {
                                    Text(L10n.text("上一章", "Previous"))
                                }
                                Text(
                                    text = "${activeChapter + 1} / ${visibleChapters.size}",
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                                OutlinedButton(
                                    enabled = activeChapter < visibleChapters.lastIndex,
                                    onClick = {
                                        activeCitation = null
                                        activeChapter = (activeChapter + 1).coerceAtMost(visibleChapters.lastIndex)
                                    }
                                ) {
                                    Text(L10n.text("下一章", "Next"))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
