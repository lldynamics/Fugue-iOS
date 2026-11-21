package com.iosbox.app.ui.assistants

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.GroupMember
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.launch
import java.util.Locale

private enum class AssistantDirectoryTab {
    ASSISTANTS,
    PERSONAS
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantListScreen(
    container: AppContainer,
    onStartChatWithPreset: (PresetItem) -> Unit,
    onStartPrivatePersonaChat: (GroupMember) -> Unit
) {
    val presets by container.chatRepository.observePresets().collectAsStateWithLifecycle(initialValue = emptyList())
    val personas by container.chatRepository.observePersonaProfiles().collectAsStateWithLifecycle(initialValue = emptyList())
    val providers by container.chatRepository.observeProviders().collectAsStateWithLifecycle(initialValue = emptyList())
    val scope = rememberCoroutineScope()

    var selectedTab by remember { mutableStateOf(AssistantDirectoryTab.ASSISTANTS) }
    var editingPreset by remember { mutableStateOf<PresetItem?>(null) }
    var showCreatePreset by remember { mutableStateOf(false) }
    var editingPersona by remember { mutableStateOf<GroupMember?>(null) }
    var showCreatePersona by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = L10n.text("助手与角色", "Assistants & Personas"),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                    )
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = {
                    if (selectedTab == AssistantDirectoryTab.ASSISTANTS) {
                        showCreatePreset = true
                    } else {
                        showCreatePersona = true
                    }
                }
            ) {
                Icon(
                    Icons.Filled.Add,
                    contentDescription = if (selectedTab == AssistantDirectoryTab.ASSISTANTS) {
                        L10n.text("新建助手", "New Assistant")
                    } else {
                        L10n.text("新建人物", "New Persona")
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
                    .padding(horizontal = DS.Spacing.lg, vertical = DS.Spacing.xs),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                FilterChip(
                    selected = selectedTab == AssistantDirectoryTab.ASSISTANTS,
                    onClick = { selectedTab = AssistantDirectoryTab.ASSISTANTS },
                    label = { Text(L10n.text("助手预设 (${presets.size})", "Assistants (${presets.size})")) }
                )
                FilterChip(
                    selected = selectedTab == AssistantDirectoryTab.PERSONAS,
                    onClick = { selectedTab = AssistantDirectoryTab.PERSONAS },
                    label = { Text(L10n.text("角色目录 (${personas.size})", "Personas (${personas.size})")) }
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
            } else {
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
                                        val detail = listOfNotNull(
                                            "${persona.target.providerName} · ${persona.target.modelDisplayName}",
                                            if (matCount > 0) L10n.text("$matCount 份参考资料", "$matCount materials") else null
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
            }
        }
    }

    if (showCreatePreset || editingPreset != null) {
        AssistantEditorSheet(
            existing = editingPreset,
            sortOrderForNew = (presets.maxOfOrNull { it.sortOrder } ?: 0) + 1,
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
}
