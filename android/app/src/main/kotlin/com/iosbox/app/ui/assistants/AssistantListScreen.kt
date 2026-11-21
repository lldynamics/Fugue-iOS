package com.iosbox.app.ui.assistants

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.launch
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantListScreen(
    container: AppContainer,
    onStartChatWithPreset: (PresetItem) -> Unit
) {
    val presets by container.chatRepository.observePresets().collectAsStateWithLifecycle(initialValue = emptyList())
    val scope = rememberCoroutineScope()
    var editingPreset by remember { mutableStateOf<PresetItem?>(null) }
    var showCreate by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = L10n.text("助手预设", "Assistants"),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                    )
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showCreate = true }) {
                Icon(Icons.Filled.Add, contentDescription = L10n.text("新建助手", "New Assistant"))
            }
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
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
    }

    if (showCreate || editingPreset != null) {
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
                showCreate = false
                editingPreset = null
            }
        )
    }
}
