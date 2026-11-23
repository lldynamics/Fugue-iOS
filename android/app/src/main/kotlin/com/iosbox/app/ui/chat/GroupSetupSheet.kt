package com.iosbox.app.ui.chat

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.PersonAdd
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
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
import com.iosbox.app.core.model.GroupRoomTemplate
import com.iosbox.app.core.model.GroupSpeakingMode
import com.iosbox.app.core.model.GroupSpeechStyle
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ConversationItem
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.ui.theme.DS
import java.util.Locale
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GroupSetupSheet(
    existing: ConversationItem? = null,
    providers: List<ProviderItem>,
    personaProfiles: List<GroupMember>,
    onSave: (
        title: String,
        emoji: String,
        systemPrompt: String,
        members: List<GroupMember>,
        speakingMode: GroupSpeakingMode,
        speechStyle: GroupSpeechStyle,
        maxRelayTurns: Int,
        splitShortBubbles: Boolean
    ) -> Unit,
    onDismiss: () -> Unit
) {
    val readyTargets = remember(providers) { ChatRepository.readyTargets(providers) }
    val defaultTemplate = remember { GroupRoomTemplate.builtInTemplates.first() }

    var title by remember(existing?.id) {
        mutableStateOf(existing?.title ?: defaultTemplate.roomTitle)
    }
    var emoji by remember(existing?.id) {
        mutableStateOf(existing?.assistantEmoji ?: defaultTemplate.roomEmoji)
    }
    var systemPrompt by remember(existing?.id) {
        mutableStateOf(existing?.systemPrompt ?: defaultTemplate.sharedTopicPrompt)
    }
    var speakingMode by remember(existing?.id) {
        mutableStateOf(existing?.assistanceSettings?.groupSpeakingMode ?: defaultTemplate.speakingMode)
    }
    var speechStyle by remember(existing?.id) {
        mutableStateOf(existing?.assistanceSettings?.groupSpeechStyle ?: defaultTemplate.speechStyle)
    }
    var maxRelayTurns by remember(existing?.id) {
        mutableIntStateOf(existing?.assistanceSettings?.groupMaxRelayTurns ?: 3)
    }
    var splitShortBubbles by remember(existing?.id) {
        mutableStateOf(existing?.assistanceSettings?.groupSplitShortBubbles ?: true)
    }
    val members = remember(existing?.id) {
        mutableStateListOf<GroupMember>().apply {
            val initial = existing?.groupMembers?.takeIf { it.isNotEmpty() }
                ?: defaultTemplate.instantiate(readyTargets)
            addAll(initial)
        }
    }

    var editingMemberIndex by remember { mutableStateOf<Int?>(null) }
    var draftNewMember by remember { mutableStateOf<GroupMember?>(null) }
    var showInviteDialog by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 650.dp)
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
                    text = if (existing == null) L10n.text("新建圆桌群聊", "New Roundtable Group")
                    else L10n.text("群聊设置 (${members.size}/6)", "Group Settings (${members.size}/6)"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(
                    enabled = members.isNotEmpty(),
                    onClick = {
                        onSave(
                            title.trim().ifEmpty { L10n.text("圆桌群聊", "Group Chat") },
                            emoji.trim().ifEmpty { "👥" },
                            systemPrompt.trim(),
                            members.toList(),
                            speakingMode,
                            speechStyle,
                            maxRelayTurns,
                            splitShortBubbles
                        )
                        onDismiss()
                    }
                ) {
                    Text(if (existing == null) L10n.text("创建", "Create") else L10n.text("保存", "Save"))
                }
            }

            if (readyTargets.isEmpty()) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(DS.Radius.sm),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = L10n.text(
                            "暂无可用模型，请先在「服务商」配置 API Key。",
                            "No ready model yet. Configure an API key in Providers first."
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(DS.Spacing.md)
                    )
                }
            }

            Text(
                text = L10n.text("快速套用圆桌阵容模板", "Quick Room Templates"),
                style = MaterialTheme.typography.labelLarge
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (tmpl in GroupRoomTemplate.builtInTemplates) {
                    FilterChip(
                        selected = title == tmpl.roomTitle,
                        onClick = {
                            title = tmpl.roomTitle
                            emoji = tmpl.roomEmoji
                            systemPrompt = tmpl.sharedTopicPrompt
                            speakingMode = tmpl.speakingMode
                            speechStyle = tmpl.speechStyle
                            members.clear()
                            members.addAll(tmpl.instantiate(readyTargets))
                        },
                        label = { Text("${tmpl.roomEmoji} ${tmpl.roomTitle}") }
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
                OutlinedTextField(
                    value = emoji,
                    onValueChange = { if (it.length <= 4) emoji = it },
                    label = { Text(L10n.text("图标", "Icon")) },
                    singleLine = true,
                    modifier = Modifier.weight(0.26f)
                )
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text(L10n.text("群名称", "Room Name")) },
                    singleLine = true,
                    modifier = Modifier.weight(0.74f)
                )
            }

            OutlinedTextField(
                value = systemPrompt,
                onValueChange = { systemPrompt = it },
                label = { Text(L10n.text("群主题背景", "Shared Topic Context")) },
                minLines = 2,
                maxLines = 4,
                modifier = Modifier.fillMaxWidth()
            )

            Text(
                text = L10n.text("发言机制", "Speaking Mode"),
                style = MaterialTheme.typography.labelLarge
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (mode in GroupSpeakingMode.entries) {
                    FilterChip(
                        selected = speakingMode == mode,
                        onClick = { speakingMode = mode },
                        label = { Text(mode.displayName) }
                    )
                }
            }
            Text(
                text = speakingMode.subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Text(
                text = L10n.text("发言风格", "Speech Style"),
                style = MaterialTheme.typography.labelLarge
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (style in GroupSpeechStyle.entries) {
                    FilterChip(
                        selected = speechStyle == style,
                        onClick = { speechStyle = style },
                        label = { Text(style.displayName) }
                    )
                }
            }

            if (speakingMode == GroupSpeakingMode.SMART_RELAY) {
                Text(
                    text = L10n.text("单轮自动接力上限：$maxRelayTurns 句", "Max Relay Turns: $maxRelayTurns"),
                    style = MaterialTheme.typography.bodySmall
                )
                Slider(
                    value = maxRelayTurns.toFloat(),
                    onValueChange = { maxRelayTurns = it.roundToInt().coerceIn(1, 6) },
                    valueRange = 1f..6f,
                    steps = 4
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = L10n.text("自然短句分两条气泡发出", "Split Short Replies into Two Bubbles"),
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f)
                )
                Switch(checked = splitShortBubbles, onCheckedChange = { splitShortBubbles = it })
            }

            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.45f))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = L10n.text("群成员列表 (${members.size}/6)", "Members (${members.size}/6)"),
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (personaProfiles.isNotEmpty() && members.size < 6) {
                        OutlinedButton(
                            onClick = { showInviteDialog = true }
                        ) {
                            Icon(Icons.Filled.PersonAdd, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.size(4.dp))
                            Text(L10n.text("邀请", "Invite"), style = MaterialTheme.typography.labelMedium)
                        }
                    }
                    if (members.size < 6 && readyTargets.isNotEmpty()) {
                        OutlinedButton(
                            onClick = {
                                val fallbackTarget = readyTargets[members.size % readyTargets.size]
                                val color = GroupMember.paletteHexes[members.size % GroupMember.paletteHexes.size]
                                draftNewMember = GroupMember(
                                    name = L10n.text("成员${members.size + 1}", "Member ${members.size + 1}"),
                                    title = "",
                                    avatarEmoji = "🤖",
                                    accentHex = color,
                                    rolePrompt = "",
                                    target = fallbackTarget,
                                    temperature = 0.75
                                )
                            }
                        ) {
                            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.size(4.dp))
                            Text(L10n.text("新增", "Add"), style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
            }

            for ((idx, member) in members.withIndex()) {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f)),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DS.Spacing.md, vertical = DS.Spacing.sm),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(text = member.avatarEmoji, style = MaterialTheme.typography.titleLarge)
                        Column(modifier = Modifier.weight(1f)) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Box(
                                    modifier = Modifier
                                        .size(8.dp)
                                        .clip(CircleShape)
                                        .background(DS.parseHexColor(member.accentHex))
                                )
                                Text(
                                    text = member.displayLabel,
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                if (member.isMuted) {
                                    Text(
                                        text = L10n.text("已静音", "Muted"),
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.error
                                    )
                                }
                            }
                            Text(
                                text = "${member.target.providerName} · ${member.target.modelDisplayName}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (member.rolePrompt.isNotBlank()) {
                                Text(
                                    text = member.rolePrompt,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                        IconButton(onClick = {
                            members[idx] = member.copy(isMuted = !member.isMuted)
                        }) {
                            Icon(
                                imageVector = if (member.isMuted) Icons.AutoMirrored.Filled.VolumeOff
                                else Icons.AutoMirrored.Filled.VolumeUp,
                                contentDescription = L10n.text("静音切换", "Toggle Mute"),
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        IconButton(onClick = { editingMemberIndex = idx }) {
                            Icon(
                                imageVector = Icons.Filled.Edit,
                                contentDescription = L10n.text("编辑成员", "Edit Member"),
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        if (members.size > 1) {
                            IconButton(onClick = { members.removeAt(idx) }) {
                                Icon(
                                    imageVector = Icons.Filled.Delete,
                                    contentDescription = L10n.text("移除成员", "Remove Member"),
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(12.dp))
        }
    }

    val editingMember = editingMemberIndex?.let { idx -> members.getOrNull(idx) } ?: draftNewMember
    if (editingMember != null) {
        GroupMemberEditorDialog(
            initial = editingMember,
            providers = providers,
            onConfirm = { updated ->
                val idx = editingMemberIndex
                if (idx != null && idx in members.indices) {
                    members[idx] = updated
                } else if (members.size < 6) {
                    members.add(updated)
                }
                editingMemberIndex = null
                draftNewMember = null
            },
            onDismiss = {
                editingMemberIndex = null
                draftNewMember = null
            }
        )
    }

    if (showInviteDialog) {
        val invitable = personaProfiles.filter { prof ->
            val pid = prof.profileID ?: prof.id
            members.none { it.profileID.equals(pid, ignoreCase = true) }
        }
        AlertDialog(
            onDismissRequest = { showInviteDialog = false },
            title = { Text(L10n.text("从角色目录邀请", "Invite from Personas")) },
            text = {
                if (invitable.isEmpty()) {
                    Text(
                        text = L10n.text("目录中可邀请的角色都已在群内。", "All saved personas are already in this room."),
                        style = MaterialTheme.typography.bodySmall
                    )
                } else {
                    Column(
                        modifier = Modifier.verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        for (prof in invitable) {
                            Surface(
                                shape = RoundedCornerShape(DS.Radius.sm),
                                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.4f)),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        if (members.size < 6) {
                                            members.add(prof.inRoom())
                                        }
                                        showInviteDialog = false
                                    }
                            ) {
                                Row(
                                    modifier = Modifier.padding(DS.Spacing.sm),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Text(prof.avatarEmoji, style = MaterialTheme.typography.titleMedium)
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(prof.displayLabel, style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold))
                                        Text(
                                            "${prof.target.providerName} · ${prof.target.modelDisplayName}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showInviteDialog = false }) {
                    Text(L10n.text("关闭", "Close"))
                }
            }
        )
    }
}

@Composable
private fun GroupMemberEditorDialog(
    initial: GroupMember,
    providers: List<ProviderItem>,
    onConfirm: (GroupMember) -> Unit,
    onDismiss: () -> Unit
) {
    var name by remember(initial.id) { mutableStateOf(initial.name) }
    var title by remember(initial.id) { mutableStateOf(initial.title) }
    var emoji by remember(initial.id) { mutableStateOf(initial.avatarEmoji) }
    var accentHex by remember(initial.id) { mutableStateOf(initial.accentHex) }
    var rolePrompt by remember(initial.id) { mutableStateOf(initial.rolePrompt) }
    var temperature by remember(initial.id) { mutableDoubleStateOf(initial.temperature) }
    var target by remember(initial.id) { mutableStateOf(initial.target) }
    var feeds by remember(initial.id) { mutableStateOf(initial.persona?.feeds.orEmpty()) }
    var showTargetPicker by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(L10n.text("编辑群成员", "Edit Member")) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
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
                        label = { Text(L10n.text("昵称", "Name")) },
                        singleLine = true,
                        modifier = Modifier.weight(0.72f)
                    )
                }
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text(L10n.text("头衔（如：产品经理）", "Title / Role")) },
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
                        .clickable { showTargetPicker = true }
                ) {
                    Column(modifier = Modifier.padding(DS.Spacing.sm)) {
                        Text(
                            text = L10n.text("驱动模型（点击切换）", "Model (tap to change)"),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "${target.providerName} · ${target.modelDisplayName}",
                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium)
                        )
                    }
                }
                OutlinedTextField(
                    value = rolePrompt,
                    onValueChange = { rolePrompt = it },
                    label = { Text(L10n.text("人设立场与性格", "Persona & Stance")) },
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
                feeds.forEachIndexed { index, feed ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(feed.address, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                        Switch(checked = feed.enabled, onCheckedChange = { enabled ->
                            feeds = feeds.toMutableList().also { it[index] = feed.copy(enabled = enabled) }
                        })
                    }
                }
            }
        },
        confirmButton = {
            Button(
                enabled = name.trim().isNotEmpty(),
                onClick = {
                    onConfirm(
                        initial.copy(
                            name = name.trim(),
                            title = title.trim(),
                            avatarEmoji = emoji.trim().ifEmpty { "🤖" },
                            accentHex = accentHex,
                            rolePrompt = rolePrompt.trim(),
                            target = target,
                            temperature = temperature,
                            persona = initial.persona?.copy(feeds = feeds)
                        )
                    )
                }
            ) {
                Text(L10n.text("确定", "OK"))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(L10n.text("取消", "Cancel"))
            }
        }
    )

    if (showTargetPicker) {
        ModelPickerSheet(
            providers = providers,
            selectedTargetId = target.id,
            title = L10n.text("选择成员模型", "Select Member Model"),
            onSelect = { target = it },
            onDismiss = { showTargetPicker = false }
        )
    }
}
