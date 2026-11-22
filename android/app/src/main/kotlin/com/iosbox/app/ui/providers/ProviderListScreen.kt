package com.iosbox.app.ui.providers

import android.content.Context
import android.util.JsonReader
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.School
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
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
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.backup.EncryptedBackupCrypto
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.network.AudioTranscriptionService
import com.iosbox.app.core.network.CloudSpeechSynthesizer
import com.iosbox.app.core.network.NetworkLocation
import com.iosbox.app.core.security.SecretStore
import com.iosbox.app.core.storage.AccentTheme
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.core.storage.ThemeAppearanceMode
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderListScreen(
    container: AppContainer,
    onOpenProvider: (String) -> Unit,
    onOpenMemories: () -> Unit,
    onOpenFlashcards: () -> Unit
) {
    val providers by container.chatRepository.observeProviders().collectAsStateWithLifecycle(initialValue = emptyList())
    val memories by container.chatRepository.observePersonalMemories().collectAsStateWithLifecycle(initialValue = emptyList())
    val flashcards by container.flashcardRepository.cards.collectAsStateWithLifecycle()
    val prefs by container.preferences.state.collectAsStateWithLifecycle()
    val secretVersion by container.secretStore.versionFlow.collectAsStateWithLifecycle()
    val savedTavilyKey = remember(secretVersion) {
        container.secretStore.loadSecret(SecretStore.TAVILY_KEY_ACCOUNT)
    }
    var tavilyKeyDraft by remember { mutableStateOf("") }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var showAddSheet by remember { mutableStateOf(false) }
    var providerToDelete by remember { mutableStateOf<ProviderItem?>(null) }
    var alertInfo by remember { mutableStateOf<Pair<String, String>?>(null) }

    var pendingExportBytes by remember { mutableStateOf<ByteArray?>(null) }
    var showExportPasswordDialog by remember { mutableStateOf(false) }
    var exportPassword by remember { mutableStateOf("") }
    var pendingEncryptedImport by remember { mutableStateOf<File?>(null) }
    var importPassword by remember { mutableStateOf("") }
    var isBusyBackup by remember { mutableStateOf(false) }

    fun discardPendingBackup() {
        pendingEncryptedImport?.delete()
        pendingEncryptedImport = null
        importPassword = ""
    }

    DisposableEffect(Unit) { onDispose { discardPendingBackup() } }

    val saveBackupLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        val bytes = pendingExportBytes
        pendingExportBytes = null
        if (uri == null || bytes == null) return@rememberLauncherForActivityResult
        scope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                        ?: error("Cannot open output stream")
                }
            }.onSuccess {
                val localLimit = EncryptedBackupCrypto.safeImportBytes
                val maxSize = android.text.format.Formatter.formatShortFileSize(context, localLimit.toLong())
                val description = if (bytes.size > localLimit) {
                    L10n.text("备份文件已保存。本设备的导入上限为 $maxSize，这份备份需在支持更大文件的设备上恢复。",
                        "Backup saved. This device can import up to $maxSize. Restore this backup on a device that supports larger imports.")
                } else {
                    L10n.text("备份文件已保存。", "Backup file saved successfully.")
                }
                alertInfo = L10n.text("导出成功", "Export Complete") to
                    description
            }.onFailure { err ->
                alertInfo = L10n.text("导出失败", "Export Failed") to (err.message ?: "Error")
            }
        }
    }

    val openBackupLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            isBusyBackup = true
            val staged = File(context.cacheDir, "backup-import-${UUID.randomUUID()}.tmp")
            try {
                val encrypted = withContext(Dispatchers.IO) {
                    stageBackup(context, uri, staged)
                    isStagedEncryptedBackup(staged)
                }
                if (encrypted) {
                    discardPendingBackup()
                    pendingEncryptedImport = staged
                } else {
                    val summary = withContext(Dispatchers.IO) {
                        container.backupRepository.importPlainJsonBytes(staged.readBytes())
                    }
                    container.flashcardRepository.reload()
                    alertInfo = summary.title to summary.description
                }
            } catch (t: Throwable) {
                if (t is CancellationException) throw t
                alertInfo = L10n.text("导入失败", "Import Failed") to (t.message ?: "Error")
            } finally {
                if (pendingEncryptedImport != staged) staged.delete()
                isBusyBackup = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = L10n.text("服务商与设置", "Providers & Settings"),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                    )
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showAddSheet = true }) {
                Icon(Icons.Filled.Add, contentDescription = L10n.text("添加服务商", "Add Provider"))
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
            item {
                Text(
                    text = L10n.text("API 服务商与自定义中转站", "API Providers & Custom Gateways"),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            items(providers, key = { it.id }) { provider ->
                ProviderCard(
                    provider = provider,
                    onClick = { onOpenProvider(provider.id) },
                    onDelete = { providerToDelete = provider }
                )
            }

            item {
                Text(
                    text = L10n.text("个人长期记忆", "Personal Memory"),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = DS.Spacing.sm)
                )
            }

            item {
                val enabledCount = memories.count { it.isEnabled && it.content.isNotBlank() }
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpenMemories() }
                ) {
                    Row(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Psychology,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(28.dp)
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = L10n.text("管理个人长期记忆", "Manage Personal Memories"),
                                style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold)
                            )
                            Text(
                                text = L10n.text(
                                    "已启用 $enabledCount 条 · 共 ${memories.size} / 20 条",
                                    "$enabledCount active · ${memories.size} / 20 total"
                                ),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Text(
                            text = L10n.text("编辑", "Edit"),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                }
            }

            item {
                val dueCount = remember(flashcards) {
                    val now = System.currentTimeMillis()
                    flashcards.count { it.isDue(now) }
                }
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onOpenFlashcards() }
                ) {
                    Row(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.School,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(28.dp)
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = L10n.text("学习闪卡库 (SM-2)", "Study Flashcard Library (SM-2)"),
                                style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold)
                            )
                            Text(
                                text = L10n.text(
                                    "待复习 $dueCount 张 · 共 ${flashcards.size} 张",
                                    "$dueCount due · ${flashcards.size} total"
                                ),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Text(
                            text = L10n.text("复习", "Study"),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                }
            }

            item {
                Text(
                    text = L10n.text("联网搜索 (Tavily)", "Web Search (Tavily)"),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = DS.Spacing.sm)
                )
            }

            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = L10n.text(
                                "用于发送前显式联网搜索或 Agent 工具调用 `web_search`（导出密码加密备份时会一并妥善打包）。",
                                "Used for one-tap Web Search and the Agent `web_search` tool (included in encrypted backups)."
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        if (savedTavilyKey.isNotEmpty()) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    text = L10n.text(
                                        "已保存：${SecretStore.maskedKeyPreview(savedTavilyKey)}",
                                        "Saved: ${SecretStore.maskedKeyPreview(savedTavilyKey)}"
                                    ),
                                    style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.primary
                                )
                                TextButton(onClick = {
                                    container.secretStore.deleteSecret(SecretStore.TAVILY_KEY_ACCOUNT)
                                }) {
                                    Text(L10n.text("清除", "Clear"), color = MaterialTheme.colorScheme.error)
                                }
                            }
                        }
                        OutlinedTextField(
                            value = tavilyKeyDraft,
                            onValueChange = { tavilyKeyDraft = it },
                            visualTransformation = PasswordVisualTransformation(),
                            singleLine = true,
                            label = { Text(L10n.text("Tavily API Key (tvly-...)", "Tavily API Key")) },
                            modifier = Modifier.fillMaxWidth()
                        )
                        Button(
                            enabled = tavilyKeyDraft.trim().isNotEmpty(),
                            onClick = {
                                val cleaned = tavilyKeyDraft.trim()
                                container.secretStore.saveSecret(cleaned, SecretStore.TAVILY_KEY_ACCOUNT)
                                tavilyKeyDraft = ""
                            },
                            modifier = Modifier.align(Alignment.End)
                        ) {
                            Text(L10n.text("保存 Tavily Key", "Save Tavily Key"))
                        }
                    }
                }
            }

            item {
                Text(
                    text = L10n.text("语音转写与自然朗读 (Whisper / TTS)", "Voice Transcription & Cloud TTS"),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = DS.Spacing.sm)
                )
            }

            item {
                val openAIProviders = remember(providers) {
                    providers.filter {
                        it.isEnabled &&
                            it.protocolType == APIProtocolType.OPEN_AI_COMPATIBLE &&
                            it.hasConfiguredChatAPI
                    }
                }
                var whisperModelDraft by remember(prefs.audioTranscriptionModel) {
                    mutableStateOf(prefs.audioTranscriptionModel)
                }
                var ttsModelDraft by remember(prefs.cloudTTSModel) {
                    mutableStateOf(prefs.cloudTTSModel)
                }

                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.GraphicEq,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(20.dp)
                            )
                            Text(
                                text = L10n.text("录音 / 音频转写 (/audio/transcriptions)", "Audio Transcription (/audio/transcriptions)"),
                                style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold)
                            )
                        }

                        if (openAIProviders.isEmpty()) {
                            Text(
                                text = L10n.text(
                                    "请先添加并启用 OpenAI 兼容服务商（如 OpenAI、Groq、硅基流动或本地 Whisper），即可使用录音转文字与会议纪要。",
                                    "Add and enable any OpenAI-compatible provider to unlock Whisper transcription and Cloud TTS."
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        } else {
                            Text(
                                text = L10n.text("转写服务商", "Transcription Provider"),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                FilterChip(
                                    selected = prefs.audioTranscriptionProviderID == null,
                                    onClick = { scope.launch { container.preferences.setAudioTranscriptionProviderID(null) } },
                                    label = { Text(L10n.text("自动（首选兼容商）", "Auto")) }
                                )
                                for (p in openAIProviders) {
                                    FilterChip(
                                        selected = prefs.audioTranscriptionProviderID.equals(p.id, ignoreCase = true),
                                        onClick = { scope.launch { container.preferences.setAudioTranscriptionProviderID(p.id) } },
                                        label = { Text(p.name) }
                                    )
                                }
                            }

                            Text(
                                text = L10n.text("转写模型", "Whisper / ASR Model"),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                for (presetModel in AudioTranscriptionService.PRESET_MODELS) {
                                    FilterChip(
                                        selected = prefs.audioTranscriptionModel == presetModel,
                                        onClick = {
                                            whisperModelDraft = presetModel
                                            scope.launch { container.preferences.setAudioTranscriptionModel(presetModel) }
                                        },
                                        label = { Text(presetModel) }
                                    )
                                }
                            }
                            OutlinedTextField(
                                value = whisperModelDraft,
                                onValueChange = { whisperModelDraft = it },
                                singleLine = true,
                                label = { Text(L10n.text("自定义转写模型名", "Custom Transcription Model")) },
                                trailingIcon = {
                                    if (whisperModelDraft.trim() != prefs.audioTranscriptionModel && whisperModelDraft.isNotBlank()) {
                                        TextButton(onClick = {
                                            scope.launch { container.preferences.setAudioTranscriptionModel(whisperModelDraft) }
                                        }) {
                                            Text(L10n.text("应用", "Apply"))
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth()
                            )

                            Text(
                                text = L10n.text("语言偏好", "Language Hint"),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                for ((code, label) in AudioTranscriptionService.PRESET_LANGUAGES) {
                                    FilterChip(
                                        selected = prefs.audioTranscriptionLanguage == code,
                                        onClick = { scope.launch { container.preferences.setAudioTranscriptionLanguage(code) } },
                                        label = { Text(label) }
                                    )
                                }
                            }
                        }

                        HorizontalDivider()

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = L10n.text("启用云端自然语音朗读 (/audio/speech)", "Enable Cloud Natural TTS"),
                                    style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold)
                                )
                                Text(
                                    text = L10n.text(
                                        "开启后优先调用云端自然人声，失败或离线时自动回退免费系统 TTS。",
                                        "Uses OpenAI-compatible /audio/speech when enabled, with automatic free system TTS fallback."
                                    ),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            Switch(
                                checked = prefs.useCloudTTS,
                                onCheckedChange = { enabled ->
                                    scope.launch { container.preferences.setUseCloudTTS(enabled) }
                                }
                            )
                        }

                        if (prefs.useCloudTTS && openAIProviders.isNotEmpty()) {
                            Text(
                                text = L10n.text("朗读服务商", "TTS Provider"),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                FilterChip(
                                    selected = prefs.cloudTTSProviderID == null,
                                    onClick = { scope.launch { container.preferences.setCloudTTSProviderID(null) } },
                                    label = { Text(L10n.text("自动（首选兼容商）", "Auto")) }
                                )
                                for (p in openAIProviders) {
                                    FilterChip(
                                        selected = prefs.cloudTTSProviderID.equals(p.id, ignoreCase = true),
                                        onClick = { scope.launch { container.preferences.setCloudTTSProviderID(p.id) } },
                                        label = { Text(p.name) }
                                    )
                                }
                            }

                            Text(
                                text = L10n.text("语音模型与音色", "TTS Model & Voice"),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                for (m in CloudSpeechSynthesizer.PRESET_MODELS) {
                                    FilterChip(
                                        selected = prefs.cloudTTSModel == m,
                                        onClick = {
                                            ttsModelDraft = m
                                            scope.launch { container.preferences.setCloudTTSModel(m) }
                                        },
                                        label = { Text(m) }
                                    )
                                }
                            }
                            Row(
                                modifier = Modifier.horizontalScroll(rememberScrollState()),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                for (v in CloudSpeechSynthesizer.PRESET_VOICES) {
                                    FilterChip(
                                        selected = prefs.cloudTTSVoice == v,
                                        onClick = { scope.launch { container.preferences.setCloudTTSVoice(v) } },
                                        label = { Text(v) }
                                    )
                                }
                            }
                            OutlinedTextField(
                                value = ttsModelDraft,
                                onValueChange = { ttsModelDraft = it },
                                singleLine = true,
                                label = { Text(L10n.text("自定义 TTS 模型名", "Custom TTS Model")) },
                                trailingIcon = {
                                    if (ttsModelDraft.trim() != prefs.cloudTTSModel && ttsModelDraft.isNotBlank()) {
                                        TextButton(onClick = {
                                            scope.launch { container.preferences.setCloudTTSModel(ttsModelDraft) }
                                        }) {
                                            Text(L10n.text("应用", "Apply"))
                                        }
                                    }
                                },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }
                }
            }

            item {
                Text(
                    text = L10n.text("外观主题", "Appearance"),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = DS.Spacing.sm)
                )
            }

            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
                    ) {
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            for (mode in ThemeAppearanceMode.entries) {
                                FilterChip(
                                    selected = prefs.appearanceMode == mode,
                                    onClick = { scope.launch { container.preferences.setAppearanceMode(mode) } },
                                    label = { Text(mode.displayName) }
                                )
                            }
                        }

                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            for (theme in AccentTheme.entries) {
                                val swatch = DS.colorsFor(theme, dark = false).solidFill
                                val selected = prefs.accentTheme == theme
                                Column(
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(4.dp),
                                    modifier = Modifier.clickable {
                                        scope.launch { container.preferences.setAccentTheme(theme) }
                                    }
                                ) {
                                    Box(
                                        modifier = Modifier
                                            .size(34.dp)
                                            .clip(CircleShape)
                                            .background(swatch)
                                            .border(
                                                width = if (selected) 2.5.dp else 0.dp,
                                                color = if (selected) MaterialTheme.colorScheme.onSurface else Color.Transparent,
                                                shape = CircleShape
                                            )
                                    )
                                    Text(
                                        text = theme.displayName,
                                        style = MaterialTheme.typography.labelSmall,
                                        fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal
                                    )
                                }
                            }
                        }
                    }
                }
            }

            item {
                Text(
                    text = L10n.text("数据备份与安全（兼容 iOS 版互通）", "Backup & Security (iOS Interop)"),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = DS.Spacing.sm)
                )
            }

            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Text(
                            text = L10n.text(
                                "API Key 使用 Android Keystore + Google Tink AES-256-GCM 加密保存在本机，直接连向你配置的接口。支持与 iOS 版「夜奔」双向导入导出 JSON v7 备份与密码加密完整备份。",
                                "API keys are encrypted locally with Android Keystore + Tink. Supports two-way v7 JSON and password-encrypted backups with Fugue for iOS."
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        OutlinedButton(
                            enabled = !isBusyBackup,
                            onClick = {
                                scope.launch {
                                    isBusyBackup = true
                                    try {
                                        val bytes = container.backupRepository.exportPlainJsonBytes()
                                        pendingExportBytes = bytes
                                        val ts = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
                                        saveBackupLauncher.launch("Fugue_Backup_$ts.json")
                                    } catch (t: Throwable) {
                                        alertInfo = L10n.text("导出失败", "Export Failed") to (t.message ?: "Error")
                                    } finally {
                                        isBusyBackup = false
                                    }
                                }
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Filled.Upload, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.size(8.dp))
                            Text(L10n.text("导出普通备份 (JSON v7，不含密钥)", "Export JSON v7 Backup (No Secrets)"))
                        }

                        Button(
                            enabled = !isBusyBackup,
                            onClick = {
                                exportPassword = ""
                                showExportPasswordDialog = true
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Filled.Lock, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.size(8.dp))
                            Text(L10n.text("导出密码加密备份 (含 API Key)", "Export Encrypted Backup (With Keys)"))
                        }

                        OutlinedButton(
                            enabled = !isBusyBackup,
                            onClick = { openBackupLauncher.launch(arrayOf("application/json", "*/*")) },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Filled.Download, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.size(8.dp))
                            Text(L10n.text("从备份文件导入（自动识别加密包）", "Import Backup File"))
                        }

                        if (prefs.aiConsentAccepted) {
                            TextButton(
                                onClick = {
                                    scope.launch {
                                        container.preferences.setAIConsentAccepted(false)
                                        alertInfo = L10n.text("已撤回授权", "Consent Reset") to
                                            L10n.text("下次发送消息前将再次请您确认接收方。", "You will be prompted again before the next send.")
                                    }
                                },
                                modifier = Modifier.align(Alignment.End)
                            ) {
                                Text(L10n.text("撤回 AI 发送授权", "Revoke AI Data Consent"))
                            }
                        }
                    }
                }
            }
        }
    }

    if (showAddSheet) {
        AddProviderSheet(
            onCreate = { item, key ->
                scope.launch {
                    if (key.isNotEmpty()) container.secretStore.saveAPIKey(item.id, key)
                    container.chatRepository.saveProvider(item)
                    onOpenProvider(item.id)
                }
            },
            onDismiss = { showAddSheet = false }
        )
    }

    providerToDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { providerToDelete = null },
            title = { Text(L10n.text("确认删除服务商？", "Delete Provider?")) },
            text = {
                Text(
                    L10n.text(
                        "将移除「${target.name}」及保存在本机的 API Key 与敏感请求头。",
                        "This removes \"${target.name}\" and its stored API keys and secret headers."
                    )
                )
            },
            confirmButton = {
                Button(onClick = {
                    val p = target
                    providerToDelete = null
                    scope.launch { container.chatRepository.deleteProvider(p) }
                }) {
                    Text(L10n.text("删除", "Delete"))
                }
            },
            dismissButton = {
                TextButton(onClick = { providerToDelete = null }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    if (showExportPasswordDialog) {
        AlertDialog(
            onDismissRequest = { showExportPasswordDialog = false },
            title = { Text(L10n.text("设置加密备份密码", "Encrypted Backup Password")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = L10n.text(
                            "使用 PBKDF2-HMAC-SHA256 + AES-256-GCM 加密所有对话、自定义地址与 API Key（兼容 iOS 版解密）。请设置至少 8 位密码。",
                            "Uses PBKDF2-HMAC-SHA256 + AES-256-GCM (compatible with iOS). Enter at least 8 characters."
                        ),
                        style = MaterialTheme.typography.bodySmall
                    )
                    OutlinedTextField(
                        value = exportPassword,
                        onValueChange = { exportPassword = it },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        label = { Text(L10n.text("至少 8 位密码", "Password (8+ chars)")) },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = EncryptedBackupCrypto.isValidExportPassword(exportPassword),
                    onClick = {
                        val pwd = exportPassword
                        showExportPasswordDialog = false
                        exportPassword = ""
                        scope.launch {
                            isBusyBackup = true
                            try {
                                val bytes = container.backupRepository.exportEncryptedJsonBytes(pwd)
                                pendingExportBytes = bytes
                                val ts = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
                                saveBackupLauncher.launch("Fugue-EncryptedBackup-$ts.json")
                            } catch (t: Throwable) {
                                alertInfo = L10n.text("导出失败", "Export Failed") to (t.message ?: "Error")
                            } finally {
                                isBusyBackup = false
                            }
                        }
                    }
                ) {
                    Text(L10n.text("加密生成", "Encrypt & Save"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showExportPasswordDialog = false }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    pendingEncryptedImport?.let { staged ->
        AlertDialog(
            onDismissRequest = { if (!isBusyBackup) discardPendingBackup() },
            title = { Text(L10n.text("输入备份解密密码", "Enter Backup Password")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = L10n.text("检测到加密备份包，请输入密码以解密并恢复数据与凭据。", "Encrypted backup detected. Enter password to decrypt and import."),
                        style = MaterialTheme.typography.bodySmall
                    )
                    OutlinedTextField(
                        value = importPassword,
                        onValueChange = { importPassword = it },
                        visualTransformation = PasswordVisualTransformation(),
                        singleLine = true,
                        label = { Text(L10n.text("密码", "Password")) },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = importPassword.isNotEmpty() && !isBusyBackup,
                    onClick = {
                        val pwd = importPassword
                        scope.launch {
                            isBusyBackup = true
                            pendingEncryptedImport = null
                            importPassword = ""
                            try {
                                val summary = withContext(Dispatchers.IO) {
                                    container.backupRepository.importEncryptedBytes(staged.readBytes(), pwd)
                                }
                                container.flashcardRepository.reload()
                                alertInfo = summary.title to summary.description
                            } catch (t: Throwable) {
                                if (t is CancellationException) throw t
                                alertInfo = L10n.text("导入失败", "Import Failed") to (t.message ?: "Error")
                            } finally {
                                staged.delete()
                                isBusyBackup = false
                            }
                        }
                    }
                ) {
                    Text(L10n.text("解密并导入", "Decrypt & Import"))
                }
            },
            dismissButton = {
                TextButton(onClick = { discardPendingBackup() }, enabled = !isBusyBackup) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    alertInfo?.let { (title, message) ->
        AlertDialog(
            onDismissRequest = { alertInfo = null },
            title = { Text(title) },
            text = { Text(message) },
            confirmButton = {
                Button(onClick = { alertInfo = null }) {
                    Text(L10n.text("好", "OK"))
                }
            }
        )
    }
}

@Composable
private fun ProviderCard(
    provider: ProviderItem,
    onClick: () -> Unit,
    onDelete: () -> Unit
) {
    val isLocal = NetworkLocation.isLocalOrPrivate(provider.baseURL)
    val statusText = when {
        provider.hasAuthentication -> L10n.text("Key 已配置", "Key Ready")
        isLocal -> L10n.text("本地地址", "Local LAN")
        else -> L10n.text("待填 Key", "Needs Key")
    }
    val statusColor = if (provider.hasAuthentication || isLocal) Color(0xFF16A34A) else Color(0xFFEA580C)

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Row(
            modifier = Modifier.padding(DS.Spacing.md),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(RoundedCornerShape(DS.Radius.sm))
                    .background(DS.parseHexColor(provider.accentHex).copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = provider.protocolType.shortBadge.take(2),
                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                    color = DS.parseHexColor(provider.accentHex)
                )
            }

            Column(modifier = Modifier.weight(1f)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = provider.name,
                        style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold),
                        color = if (provider.isEnabled) MaterialTheme.colorScheme.onSurface
                        else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.surfaceVariant
                    ) {
                        Text(
                            text = provider.protocolType.shortBadge,
                            style = MaterialTheme.typography.labelSmall,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                        )
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(statusColor)
                    )
                    Text(
                        text = "$statusText · ${L10n.text("已启用 ${provider.enabledModels.size} 个模型", "${provider.enabledModels.size} enabled")}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            IconButton(onClick = onDelete) {
                Icon(
                    imageVector = Icons.Filled.Delete,
                    contentDescription = L10n.text("删除", "Delete"),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

private suspend fun stageBackup(context: Context, uri: android.net.Uri, destination: File) {
    val stream = context.contentResolver.openInputStream(uri) ?: error("Cannot read file")
    stream.use { input ->
        destination.outputStream().buffered().use { output ->
            val buf = ByteArray(32_768)
            val limit = EncryptedBackupCrypto.safeImportBytes
            var bytes = 0
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = input.read(buf)
                if (read < 0) break
                bytes += read
                EncryptedBackupCrypto.requireImportSize(bytes, limit)
                output.write(buf, 0, read)
            }
        }
    }
}

private fun isStagedEncryptedBackup(file: File): Boolean {
    val marker = EncryptedBackupCrypto.ENVELOPE_MAGIC
    val hasMarker = RandomAccessFile(file, "r").use { input ->
        val header = ByteArray(minOf(input.length(), 4096L).toInt())
        input.readFully(header)
        if (header.toString(Charsets.UTF_8).contains(marker)) return@use true
        if (input.length() <= header.size) return@use false
        input.seek(input.length() - header.size)
        input.readFully(header)
        header.toString(Charsets.UTF_8).contains(marker)
    }
    if (!hasMarker) return false
    // iOS sorts its JSON keys, so the ciphertext can appear before the magic field.
    // Skip it with the streaming reader before the password dialog allocates any archive buffers.
    return runCatching {
        JsonReader(file.reader(Charsets.UTF_8)).use { json ->
            json.beginObject()
            while (json.hasNext()) {
                if (json.nextName() == "magic") return@use json.nextString() == marker
                json.skipValue()
            }
            false
        }
    }.getOrDefault(false)
}
