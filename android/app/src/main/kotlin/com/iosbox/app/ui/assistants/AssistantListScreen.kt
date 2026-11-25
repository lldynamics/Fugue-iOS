package com.iosbox.app.ui.assistants

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.GroupMember
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.BookImporter
import com.iosbox.app.core.storage.BookVolumeItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.ui.books.BookFriendSetupSheet
import com.iosbox.app.ui.books.BookReaderSheet
import com.iosbox.app.ui.books.ReadingShelfSection
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale

private enum class AssistantDirectoryTab {
    ASSISTANTS,
    PERSONAS,
    SHELF
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantListScreen(
    container: AppContainer,
    onStartChatWithPreset: (PresetItem) -> Unit,
    onStartPrivatePersonaChat: (GroupMember) -> Unit,
    onOpenConversation: (String) -> Unit
) {
    val context = LocalContext.current
    val presets by container.chatRepository.observePresets().collectAsStateWithLifecycle(initialValue = emptyList())
    val personas by container.chatRepository.observePersonaProfiles().collectAsStateWithLifecycle(initialValue = emptyList())
    val providers by container.chatRepository.observeProviders().collectAsStateWithLifecycle(initialValue = emptyList())
    val books by container.chatRepository.observeBooks().collectAsStateWithLifecycle(initialValue = emptyList())
    val shelfStates by container.chatRepository.observeShelfStates().collectAsStateWithLifecycle(initialValue = emptyList())
    val prefs by container.preferences.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    var selectedTab by remember { mutableStateOf(AssistantDirectoryTab.ASSISTANTS) }
    LaunchedEffect(prefs.simpleDailyMode) {
        if (prefs.simpleDailyMode && selectedTab == AssistantDirectoryTab.PERSONAS) {
            selectedTab = AssistantDirectoryTab.ASSISTANTS
        }
    }
    var editingPreset by remember { mutableStateOf<PresetItem?>(null) }
    var showCreatePreset by remember { mutableStateOf(false) }
    var editingPersona by remember { mutableStateOf<GroupMember?>(null) }
    var showCreatePersona by remember { mutableStateOf(false) }
    var readingBook by remember { mutableStateOf<BookVolumeItem?>(null) }
    var showBookFriendSetupFor by remember { mutableStateOf<BookVolumeItem?>(null) }
    var showBookFriendSheet by remember { mutableStateOf(false) }
    var bookAlertMessage by remember { mutableStateOf<String?>(null) }

    val importBookLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                val prepared = withContext(Dispatchers.IO) {
                    BookImporter.readUri(context.contentResolver, uri)
                }
                container.chatRepository.storePreparedBook(prepared)
            }.onFailure { err ->
                bookAlertMessage = err.message ?: L10n.text("书籍导入失败", "Book import failed")
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = L10n.text("工作台", "Workspace"),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                    )
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = {
                    when (selectedTab) {
                        AssistantDirectoryTab.ASSISTANTS -> showCreatePreset = true
                        AssistantDirectoryTab.PERSONAS -> showCreatePersona = true
                        AssistantDirectoryTab.SHELF -> importBookLauncher.launch(
                            arrayOf(
                                "application/epub+zip",
                                "application/pdf",
                                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                                "text/*",
                                "application/octet-stream",
                                "*/*"
                            )
                        )
                    }
                }
            ) {
                Icon(
                    Icons.Filled.Add,
                    contentDescription = when (selectedTab) {
                        AssistantDirectoryTab.ASSISTANTS -> L10n.text("新建助手", "New Assistant")
                        AssistantDirectoryTab.PERSONAS -> L10n.text("新建人物", "New Persona")
                        AssistantDirectoryTab.SHELF -> L10n.text("导入书籍", "Import Book")
                    }
                )
            }
        }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.xs),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                FilterChip(
                    selected = selectedTab == AssistantDirectoryTab.ASSISTANTS,
                    onClick = { selectedTab = AssistantDirectoryTab.ASSISTANTS },
                    label = { Text(L10n.text("助手 (${presets.size})", "Assistants (${presets.size})")) }
                )
                if (!prefs.simpleDailyMode) {
                    FilterChip(
                        selected = selectedTab == AssistantDirectoryTab.PERSONAS,
                        onClick = { selectedTab = AssistantDirectoryTab.PERSONAS },
                        label = { Text(L10n.text("角色 (${personas.size})", "Personas (${personas.size})")) }
                    )
                }
                FilterChip(
                    selected = selectedTab == AssistantDirectoryTab.SHELF,
                    onClick = { selectedTab = AssistantDirectoryTab.SHELF },
                    label = { Text(L10n.text("书架 (${books.size})", "Shelf (${books.size})")) }
                )
            }

            if (selectedTab == AssistantDirectoryTab.ASSISTANTS) {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(
                        start = DS.Spacing.lg,
                        end = DS.Spacing.lg,
                        top = DS.Spacing.sm,
                        bottom = 88.dp
                    ),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
                ) {
                    items(presets, key = { it.id }) { preset ->
                        Card(
                            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onStartChatWithPreset(preset) }
                        ) {
                            Row(
                                modifier = Modifier.padding(DS.Spacing.md),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                Text(
                                    text = preset.iconEmoji,
                                    style = MaterialTheme.typography.headlineMedium
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = preset.name,
                                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                                    )
                                    if (preset.subtitle.isNotEmpty()) {
                                        Text(
                                            text = preset.subtitle,
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                    val tags = buildList {
                                        if (preset.useCustomTemperature) {
                                            add("T=${String.format(Locale.US, "%.1f", preset.temperature)}")
                                        }
                                        if (preset.enableThinking) {
                                            add(L10n.text("思考", "Think"))
                                        }
                                    }
                                    if (tags.isNotEmpty()) {
                                        Text(
                                            text = tags.joinToString(" · "),
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.primary
                                        )
                                    }
                                }
                                IconButton(onClick = { editingPreset = preset }) {
                                    Icon(Icons.Filled.Edit, contentDescription = L10n.text("编辑", "Edit"))
                                }
                            }
                        }
                    }
                }
            } else if (selectedTab == AssistantDirectoryTab.PERSONAS) {
                if (personas.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(DS.Spacing.xl),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = L10n.text(
                                "点击右下角 + 创建人物档案。\n可随时拉进多角色群聊，或点击卡片开启 1 对 1 私聊。",
                                "Tap + to create a reusable persona for group chats or 1-on-1 conversations."
                            ),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = PaddingValues(
                            start = DS.Spacing.lg,
                            end = DS.Spacing.lg,
                            top = DS.Spacing.sm,
                            bottom = 88.dp
                        ),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
                    ) {
                        items(personas, key = { it.id }) { persona ->
                            Card(
                                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { onStartPrivatePersonaChat(persona) }
                            ) {
                                Row(
                                    modifier = Modifier.padding(DS.Spacing.md),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                                ) {
                                    Text(
                                        text = persona.avatarEmoji,
                                        style = MaterialTheme.typography.headlineMedium
                                    )
                                    Column(modifier = Modifier.weight(1f)) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                                        ) {
                                            Box(
                                                modifier = Modifier
                                                    .size(8.dp)
                                                    .clip(CircleShape)
                                                    .background(DS.parseHexColor(persona.accentHex))
                                            )
                                            Text(
                                                text = persona.displayLabel,
                                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                                            )
                                        }
                                        if (persona.rolePrompt.isNotBlank()) {
                                            Text(
                                                text = persona.rolePrompt,
                                                style = MaterialTheme.typography.bodySmall,
                                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                        val matCount = persona.persona?.materials?.size ?: 0
                                        val feedCount = persona.persona?.feeds?.size ?: 0
                                        val detail = listOfNotNull(
                                            "${persona.target.providerName} · ${persona.target.modelDisplayName}",
                                            if (matCount > 0) L10n.text("$matCount 份参考资料", "$matCount materials") else null,
                                            if (feedCount > 0) L10n.text("$feedCount 个订阅源", "$feedCount feeds") else null
                                        ).joinToString(" · ")
                                        Text(
                                            text = detail,
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.primary
                                        )
                                    }
                                    IconButton(onClick = { editingPersona = persona }) {
                                        Icon(Icons.Filled.Edit, contentDescription = L10n.text("编辑", "Edit"))
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ReadingShelfSection(
                    books = books,
                    shelfStates = shelfStates,
                    onReadBook = { book -> readingBook = book },
                    onOpenCompanion = { book ->
                        scope.launch {
                            val ready = ChatRepository.readyTargets(providers)
                            val defaultId = container.preferences.state.value.defaultTargetID
                            val target = defaultId?.let { id -> ready.firstOrNull { it.id == id } } ?: ready.firstOrNull()
                            val conv = container.chatRepository.openOrCreateBookCompanion(book, target = target)
                            onOpenConversation(conv.id)
                        }
                    },
                    onCreateBookFriend = { book ->
                        showBookFriendSetupFor = book
                        showBookFriendSheet = true
                    },
                    onDeleteBook = { book ->
                        scope.launch { container.chatRepository.deleteBook(book.id) }
                    }
                )
            }
        }
    }

    if (showCreatePreset || editingPreset != null) {
        AssistantEditorSheet(
            existing = editingPreset,
            sortOrderForNew = (presets.maxOfOrNull { it.sortOrder } ?: 0) + 1,
            books = books,
            chatRepository = container.chatRepository,
            onSave = { item ->
                scope.launch { container.chatRepository.savePreset(item) }
            },
            onDelete = { id ->
                scope.launch { container.chatRepository.deletePreset(id) }
            },
            onDismiss = {
                showCreatePreset = false
                editingPreset = null
            }
        )
    }

    if (showCreatePersona || editingPersona != null) {
        PersonaEditorSheet(
            existing = editingPersona,
            providers = providers,
            secretStore = container.secretStore,
            onSave = { member ->
                scope.launch { container.chatRepository.savePersonaProfile(member) }
            },
            onDelete = { id ->
                scope.launch { container.chatRepository.deletePersonaProfile(id) }
            },
            onDismiss = {
                showCreatePersona = false
                editingPersona = null
            }
        )
    }

    readingBook?.let { book ->
        BookReaderSheet(
            container = container,
            volumeID = book.id,
            onDismiss = { readingBook = null }
        )
    }

    if (showBookFriendSheet) {
        BookFriendSetupSheet(
            container = container,
            books = books,
            initialBook = showBookFriendSetupFor,
            onStartChat = { friend ->
                scope.launch {
                    val ready = ChatRepository.readyTargets(providers)
                    val defaultId = container.preferences.state.value.defaultTargetID
                    val target = defaultId?.let { id -> ready.firstOrNull { it.id == id } } ?: ready.firstOrNull()
                    val conv = container.chatRepository.openOrCreateBookFriendChat(friend, target)
                    onOpenConversation(conv.id)
                }
            },
            onDismiss = {
                showBookFriendSheet = false
                showBookFriendSetupFor = null
            }
        )
    }

    bookAlertMessage?.let { msg ->
        AlertDialog(
            onDismissRequest = { bookAlertMessage = null },
            title = { Text(L10n.text("书籍提示", "Book Notice")) },
            text = { Text(msg) },
            confirmButton = {
                Button(onClick = { bookAlertMessage = null }) {
                    Text(L10n.text("好", "OK"))
                }
            }
        )
    }
}
