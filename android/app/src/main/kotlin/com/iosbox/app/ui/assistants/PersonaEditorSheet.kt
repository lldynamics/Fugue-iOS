package com.iosbox.app.ui.assistants

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.GroupMember
import com.iosbox.app.core.model.GroupPersona
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.PersonaMaterial
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.ui.chat.ModelPickerSheet
import com.iosbox.app.ui.theme.DS
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PersonaEditorSheet(
    existing: GroupMember?,
    providers: List<ProviderItem>,
    onSave: (GroupMember) -> Unit,
    onDelete: ((String) -> Unit)? = null,
    onDismiss: () -> Unit
) {
    val readyTargets = remember(providers) { ChatRepository.readyTargets(providers) }
    val initialTarget = remember(existing, readyTargets) {
        existing?.target ?: readyTargets.firstOrNull()
    }

    var name by remember(existing?.id) { mutableStateOf(existing?.name ?: "") }
    var title by remember(existing?.id) { mutableStateOf(existing?.title ?: "") }
    var emoji by remember(existing?.id) { mutableStateOf(existing?.avatarEmoji ?: "🎭") }
    var accentHex by remember(existing?.id) { mutableStateOf(existing?.accentHex ?: GroupMember.paletteHexes.first()) }
    var rolePrompt by remember(existing?.id) { mutableStateOf(existing?.rolePrompt ?: "") }
    var temperature by remember(existing?.id) { mutableDoubleStateOf(existing?.temperature ?: 0.75) }
    var selectedTarget by remember(existing?.id) { mutableStateOf(initialTarget) }
    val materials = remember(existing?.id) {
        mutableStateListOf<PersonaMaterial>().apply {
            addAll(existing?.persona?.materials.orEmpty())
        }
    }

    var showModelPicker by remember { mutableStateOf(false) }
    var showAddMaterial by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 640.dp)
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
                    text = if (existing == null) L10n.text("新建人物档案", "New Persona")
                    else L10n.text("编辑人物档案", "Edit Persona"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(
                    enabled = name.trim().isNotEmpty() && selectedTarget != null,
                    onClick = {
                        val target = selectedTarget ?: return@Button
                        val cleanMaterials = materials.toList()
                        val profileId = (existing?.profileID ?: existing?.id ?: UUID.randomUUID().toString()).uppercase()
                        onSave(
                            GroupMember(
                                id = profileId,
                                profileID = profileId,
                                name = name.trim(),
                                title = title.trim(),
                                avatarEmoji = emoji.trim().ifEmpty { "🎭" },
                                accentHex = accentHex,
                                rolePrompt = rolePrompt.trim(),
                                target = target,
                                temperature = temperature,
                                isMuted = false,
                                persona = if (cleanMaterials.isEmpty()) null else GroupPersona(cleanMaterials)
                            )
                        )
                        onDismiss()
                    }
                ) {
                    Text(L10n.text("保存", "Save"))
                }
            }

            if (selectedTarget == null) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(DS.Radius.sm),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = L10n.text(
                            "暂无可用模型，请先在「服务商」配置 API Key。",
                            "No ready model yet. Configure a provider in Providers first."
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(DS.Spacing.md)
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = emoji,
                    onValueChange = { if (it.length <= 4) emoji = it },
                    label = { Text(L10n.text("头像", "Emoji")) },
                    singleLine = true,
                    modifier = Modifier.weight(0.28f)
                )
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(L10n.text("人物姓名", "Name")) },
                    singleLine = true,
                    modifier = Modifier.weight(0.72f)
                )
            }

            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text(L10n.text("身份 / 头衔", "Role / Title")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (hex in GroupMember.paletteHexes) {
                    val selected = accentHex.equals(hex, ignoreCase = true)
                    Box(
                        modifier = Modifier
                            .size(if (selected) 26.dp else 22.dp)
                            .clip(CircleShape)
                            .background(DS.parseHexColor(hex))
                            .clickable { accentHex = hex }
                    )
                }
            }

            Surface(
                shape = RoundedCornerShape(DS.Radius.sm),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.5f)),
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = readyTargets.isNotEmpty()) { showModelPicker = true }
            ) {
                Column(modifier = Modifier.padding(DS.Spacing.md)) {
                    Text(
                        text = L10n.text("绑定模型（点击切换）", "Assigned Model (tap to change)"),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = selectedTarget?.let { "${it.providerName} · ${it.modelDisplayName}" }
                            ?: L10n.text("暂无可用模型", "No ready model"),
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium)
                    )
                }
            }

            OutlinedTextField(
                value = rolePrompt,
                onValueChange = { rolePrompt = it },
                label = { Text(L10n.text("人设设定与说话风格", "Persona Prompt & Voice")) },
                minLines = 3,
                maxLines = 6,
                modifier = Modifier.fillMaxWidth()
            )

            Text(
                text = "Temperature: ${String.format(Locale.US, "%.2f", temperature)}",
                style = MaterialTheme.typography.bodySmall
            )
            Slider(
                value = temperature.toFloat(),
                onValueChange = { temperature = ((it * 20).roundToInt() / 20.0).coerceIn(0.0, 1.5) },
                valueRange = 0f..1.5f
            )

            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.45f))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = L10n.text(
                        "参考资料 (${materials.size}/${PersonaMaterial.MAXIMUM_COUNT})",
                        "Reference Materials (${materials.size}/${PersonaMaterial.MAXIMUM_COUNT})"
                    ),
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                )
                if (materials.size < PersonaMaterial.MAXIMUM_COUNT) {
                    OutlinedButton(onClick = { showAddMaterial = true }) {
                        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.size(4.dp))
                        Text(L10n.text("添加资料", "Add Material"), style = MaterialTheme.typography.labelMedium)
                    }
                }
            }

            for ((idx, mat) in materials.withIndex()) {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DS.Spacing.md, vertical = DS.Spacing.sm),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = mat.title,
                                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = mat.text,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                        IconButton(onClick = { materials.removeAt(idx) }) {
                            Icon(
                                imageVector = Icons.Filled.Delete,
                                contentDescription = L10n.text("删除资料", "Delete Material"),
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                }
            }

            if (existing != null && onDelete != null) {
                TextButton(
                    onClick = {
                        onDelete(existing.profileID ?: existing.id)
                        onDismiss()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(L10n.text("删除此人物档案", "Delete Persona"))
                }
            }
        }
    }

    if (showModelPicker) {
        ModelPickerSheet(
            providers = providers,
            selectedTargetId = selectedTarget?.id,
            title = L10n.text("选择绑定模型", "Select Persona Model"),
            onSelect = { selectedTarget = it },
            onDismiss = { showModelPicker = false }
        )
    }

    if (showAddMaterial) {
        AddPersonaMaterialDialog(
            onAdd = { mat ->
                if (materials.size < PersonaMaterial.MAXIMUM_COUNT) {
                    materials.add(mat)
                }
                showAddMaterial = false
            },
            onDismiss = { showAddMaterial = false }
        )
    }
}

@Composable
private fun AddPersonaMaterialDialog(
    onAdd: (PersonaMaterial) -> Unit,
    onDismiss: () -> Unit
) {
    var matTitle by remember { mutableStateOf("") }
    var matBody by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(L10n.text("添加人物参考语料", "Add Reference Material")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
                OutlinedTextField(
                    value = matTitle,
                    onValueChange = { matTitle = it },
                    label = { Text(L10n.text("资料标题（如：访谈摘录）", "Source Title")) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = matBody,
                    onValueChange = { matBody = it.take(PersonaMaterial.MAXIMUM_CHARACTERS) },
                    label = { Text(L10n.text("语料正文（最多 4000 字）", "Content (max 4000 chars)")) },
                    minLines = 4,
                    maxLines = 8,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                enabled = matTitle.trim().isNotEmpty() && matBody.trim().isNotEmpty(),
                onClick = {
                    onAdd(
                        PersonaMaterial(
                            title = matTitle.trim(),
                            text = matBody.trim()
                        )
                    )
                }
            ) {
                Text(L10n.text("添加", "Add"))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(L10n.text("取消", "Cancel"))
            }
        }
    )
}
