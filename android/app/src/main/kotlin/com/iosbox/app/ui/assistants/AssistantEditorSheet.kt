package com.iosbox.app.ui.assistants

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.ContextLimitOptions
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.ui.theme.DS
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantEditorSheet(
    existing: PresetItem?,
    sortOrderForNew: Int,
    onSave: (PresetItem) -> Unit,
    onDelete: ((String) -> Unit)? = null,
    onDismiss: () -> Unit
) {
    var name by remember { mutableStateOf(existing?.name ?: "") }
    var iconEmoji by remember { mutableStateOf(existing?.iconEmoji ?: "🤖") }
    var subtitle by remember { mutableStateOf(existing?.subtitle ?: "") }
    var systemPrompt by remember { mutableStateOf(existing?.systemPrompt ?: "") }
    var useCustomTemperature by remember { mutableStateOf(existing?.useCustomTemperature ?: true) }
    var temperature by remember { mutableDoubleStateOf(existing?.temperature ?: 0.7) }
    var topP by remember { mutableDoubleStateOf(existing?.topP ?: 1.0) }
    var contextLimit by remember { mutableIntStateOf(existing?.contextMessageLimit ?: 20) }
    var enableThinking by remember { mutableStateOf(existing?.enableThinking ?: true) }
    var thinkingBudget by remember { mutableIntStateOf(existing?.thinkingBudgetTokens ?: 4096) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DS.Spacing.lg)
                .padding(bottom = DS.Spacing.xxl),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (existing == null) L10n.text("新建助手预设", "New Assistant")
                    else L10n.text("编辑助手预设", "Edit Assistant"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(
                    enabled = name.trim().isNotEmpty(),
                    onClick = {
                        onSave(
                            PresetItem(
                                id = existing?.id ?: UUID.randomUUID().toString().uppercase(),
                                name = name.trim(),
                                iconEmoji = iconEmoji.trim().ifEmpty { "🤖" },
                                subtitle = subtitle.trim(),
                                systemPrompt = systemPrompt.trim(),
                                temperature = temperature,
                                useCustomTemperature = useCustomTemperature,
                                topP = topP,
                                maxOutputTokens = existing?.maxOutputTokens ?: 0,
                                contextMessageLimit = contextLimit,
                                enableThinking = enableThinking,
                                thinkingBudgetTokens = thinkingBudget,
                                isBuiltIn = existing?.isBuiltIn ?: false,
                                sortOrder = existing?.sortOrder ?: sortOrderForNew,
                                createdAtEpochMs = existing?.createdAtEpochMs ?: System.currentTimeMillis()
                            )
                        )
                        onDismiss()
                    }
                ) {
                    Text(L10n.text("保存", "Save"))
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = iconEmoji,
                    onValueChange = { iconEmoji = it.take(4) },
                    label = { Text(L10n.text("图标", "Emoji")) },
                    singleLine = true,
                    modifier = Modifier.weight(0.28f)
                )
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(L10n.text("角色名称", "Name")) },
                    singleLine = true,
                    modifier = Modifier.weight(0.72f)
                )
            }

            OutlinedTextField(
                value = subtitle,
                onValueChange = { subtitle = it },
                label = { Text(L10n.text("简介", "Subtitle")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = systemPrompt,
                onValueChange = { systemPrompt = it },
                label = { Text(L10n.text("System Prompt", "System Prompt")) },
                minLines = 3,
                maxLines = 7,
                modifier = Modifier.fillMaxWidth()
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(L10n.text("启用深度思考", "Enable Thinking"))
                Switch(checked = enableThinking, onCheckedChange = { enableThinking = it })
            }

            if (enableThinking) {
                Text(
                    text = L10n.text("思考 Token 预算：$thinkingBudget", "Thinking Budget: $thinkingBudget"),
                    style = MaterialTheme.typography.bodySmall
                )
                Slider(
                    value = thinkingBudget.toFloat(),
                    onValueChange = { thinkingBudget = ((it / 1024f).roundToInt() * 1024).coerceIn(1024, 32768) },
                    valueRange = 1024f..32768f
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(L10n.text("自定义 Temperature", "Custom Temperature"))
                Switch(checked = useCustomTemperature, onCheckedChange = { useCustomTemperature = it })
            }

            if (useCustomTemperature) {
                Text(
                    text = "Temperature: ${String.format(Locale.US, "%.2f", temperature)}",
                    style = MaterialTheme.typography.bodySmall
                )
                Slider(
                    value = temperature.toFloat(),
                    onValueChange = { temperature = ((it * 20).roundToInt() / 20.0).coerceIn(0.0, 2.0) },
                    valueRange = 0f..2f
                )
            }

            Text(
                text = L10n.text("携带上下文条数", "Context Window"),
                style = MaterialTheme.typography.labelLarge
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (opt in ContextLimitOptions.valuesIncluding(contextLimit)) {
                    FilterChip(
                        selected = contextLimit == opt,
                        onClick = { contextLimit = opt },
                        label = { Text(ContextLimitOptions.label(opt)) }
                    )
                }
            }

            if (existing != null && onDelete != null) {
                TextButton(
                    onClick = {
                        onDelete(existing.id)
                        onDismiss()
                    },
                    modifier = Modifier.align(Alignment.End)
                ) {
                    Text(
                        text = L10n.text("删除此预设", "Delete Preset"),
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }
        }
    }
}
