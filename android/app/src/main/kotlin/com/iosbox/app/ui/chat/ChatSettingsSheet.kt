package com.iosbox.app.ui.chat

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.ContextLimitOptions
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.ConversationItem
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.core.storage.PromptTemplateEngine
import com.iosbox.app.ui.theme.DS
import java.util.Locale
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatSettingsSheet(
    conversation: ConversationItem,
    presets: List<PresetItem>,
    onSave: (ConversationItem) -> Unit,
    onDismiss: () -> Unit
) {
    var systemPrompt by remember { mutableStateOf(conversation.systemPrompt) }
    var assistantID by remember { mutableStateOf(conversation.assistantID) }
    var assistantEmoji by remember { mutableStateOf(conversation.assistantEmoji) }
    var enableThinking by remember { mutableStateOf(conversation.enableThinking) }
    var thinkingBudget by remember { mutableIntStateOf(conversation.thinkingBudgetTokens) }
    var useCustomTemperature by remember { mutableStateOf(conversation.useCustomTemperature) }
    var temperature by remember { mutableDoubleStateOf(conversation.temperature) }
    var topP by remember { mutableDoubleStateOf(conversation.topP) }
    var contextLimit by remember { mutableIntStateOf(conversation.contextMessageLimit) }
    var maxOutputText by remember { mutableStateOf(conversation.maxOutputTokens.toString()) }
    var enableAgentTools by remember { mutableStateOf(conversation.assistanceSettings.enableAgentTools) }
    var enableNativeGrounding by remember { mutableStateOf(conversation.assistanceSettings.enableNativeGrounding) }

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
                    text = L10n.text("会话参数与预设", "Chat Parameters & Presets"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(onClick = {
                    val maxOut = maxOutputText.toIntOrNull()?.coerceAtLeast(0) ?: 0
                    onSave(
                        conversation.copy(
                            assistantID = assistantID,
                            assistantEmoji = assistantEmoji,
                            systemPrompt = systemPrompt,
                            enableThinking = enableThinking,
                            thinkingBudgetTokens = thinkingBudget,
                            useCustomTemperature = useCustomTemperature,
                            temperature = temperature,
                            topP = topP,
                            contextMessageLimit = contextLimit,
                            maxOutputTokens = maxOut,
                            assistanceSettings = conversation.assistanceSettings.copy(
                                enableAgentTools = enableAgentTools,
                                enableNativeGrounding = enableNativeGrounding
                            ),
                            updatedAtEpochMs = System.currentTimeMillis()
                        )
                    )
                    onDismiss()
                }) {
                    Text(L10n.text("保存", "Save"))
                }
            }

            if (presets.isNotEmpty()) {
                Text(
                    text = L10n.text("一键套用助手角色", "Apply Assistant Preset"),
                    style = MaterialTheme.typography.labelLarge
                )
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    for (preset in presets) {
                        FilterChip(
                            selected = assistantID == preset.id,
                            onClick = {
                                assistantID = preset.id
                                assistantEmoji = preset.iconEmoji
                                systemPrompt = preset.systemPrompt
                                temperature = preset.temperature
                                useCustomTemperature = preset.useCustomTemperature
                                topP = preset.topP
                                maxOutputText = preset.maxOutputTokens.toString()
                                contextLimit = preset.contextMessageLimit
                                enableThinking = preset.enableThinking
                                thinkingBudget = preset.thinkingBudgetTokens
                            },
                            label = { Text("${preset.iconEmoji} ${preset.name}") }
                        )
                    }
                }
            }

            OutlinedTextField(
                value = systemPrompt,
                onValueChange = { systemPrompt = it },
                label = { Text(L10n.text("系统提示词 (System Prompt)", "System Prompt")) },
                minLines = 3,
                maxLines = 7,
                modifier = Modifier.fillMaxWidth()
            )

            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                for (opt in PromptTemplateEngine.availableVariables) {
                    TextButton(onClick = {
                        systemPrompt = if (systemPrompt.isBlank()) opt.token else "$systemPrompt ${opt.token}"
                    }) {
                        Text(
                            text = opt.token,
                            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace)
                        )
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(L10n.text("启用深度思考 (Thinking / R1)", "Enable Deep Thinking"))
                Switch(checked = enableThinking, onCheckedChange = { enableThinking = it })
            }

            if (!conversation.isGroupMode) {
                if (!conversation.isArenaMode) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(L10n.text("启用 Agent 工具调用", "Enable Agent Tools"))
                            Text(
                                text = L10n.text("允许模型自主联网搜索、读取网页或建议记忆。", "Allows autonomous web search, webpage reads, and memory suggestions."),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Switch(checked = enableAgentTools, onCheckedChange = { enableAgentTools = it })
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(L10n.text("原生联网检索 (Grounding)", "Native Web Grounding"))
                        Text(
                            text = L10n.text("由支持联网的模型原生附带引用来源。", "Uses built-in model grounding on supported providers."),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(checked = enableNativeGrounding, onCheckedChange = { enableNativeGrounding = it })
                }
            }

            if (enableThinking) {
                Text(
                    text = L10n.text("思考 Token 预算：$thinkingBudget", "Thinking Token Budget: $thinkingBudget"),
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
                Text(L10n.text("自定义随机度 (Temperature)", "Custom Temperature"))
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
                text = "Top P: ${String.format(Locale.US, "%.2f", topP)}",
                style = MaterialTheme.typography.bodySmall
            )
            Slider(
                value = topP.toFloat(),
                onValueChange = { topP = ((it * 20).roundToInt() / 20.0).coerceIn(0.1, 1.0) },
                valueRange = 0.1f..1.0f
            )

            Text(
                text = L10n.text("携带上下文条数", "Context Window"),
                style = MaterialTheme.typography.labelLarge
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (valOpt in ContextLimitOptions.valuesIncluding(contextLimit)) {
                    FilterChip(
                        selected = contextLimit == valOpt,
                        onClick = { contextLimit = valOpt },
                        label = { Text(ContextLimitOptions.label(valOpt)) }
                    )
                }
            }

            OutlinedTextField(
                value = maxOutputText,
                onValueChange = { s -> maxOutputText = s.filter { it.isDigit() } },
                label = { Text(L10n.text("最大输出 Tokens（0=默认）", "Max Output Tokens (0 = Default)")) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(8.dp))
        }
    }
}
