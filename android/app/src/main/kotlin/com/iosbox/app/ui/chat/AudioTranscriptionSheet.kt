package com.iosbox.app.ui.chat

import android.Manifest
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.OpenableColumns
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.EventAvailable
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.network.AudioTranscriptionService
import com.iosbox.app.core.network.TranscriptActionMode
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.core.system.AudioMeteringNormalizer
import com.iosbox.app.core.system.AudioRecorderController
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URI
import java.util.Locale

private class StagedAudioClip(
    val fileName: String,
    val mimeType: String,
    val bytes: ByteArray,
    val tempFile: File? = null
) {
    val formattedSize: String
        get() = when {
            bytes.size >= 1024 * 1024 -> String.format(Locale.US, "%.1f MB", bytes.size / (1024.0 * 1024.0))
            bytes.size >= 1024 -> String.format(Locale.US, "%.1f KB", bytes.size / 1024.0)
            else -> "${bytes.size} B"
        }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AudioTranscriptionSheet(
    container: AppContainer,
    provider: ProviderItem?,
    onGoToProviders: () -> Unit,
    onTranscribe: suspend (fileName: String, mimeType: String, bytes: ByteArray) -> Result<String>,
    onSubmit: (transcript: String, sourceLabel: String?, mode: TranscriptActionMode, autoExtractSchedule: Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs by container.preferences.state.collectAsStateWithLifecycle()
    val recorder = remember(context) { AudioRecorderController(context) }
    val isRecording by recorder.isRecording.collectAsStateWithLifecycle()
    val isPaused by recorder.isPaused.collectAsStateWithLifecycle()
    val elapsedSeconds by recorder.elapsedSeconds.collectAsStateWithLifecycle()
    val levelHistory by recorder.levelHistory.collectAsStateWithLifecycle()
    val isPlayingPreview by recorder.isPlayingPreview.collectAsStateWithLifecycle()

    var stagedAudio by remember { mutableStateOf<StagedAudioClip?>(null) }
    var transcriptText by remember { mutableStateOf("") }
    var isTranscribing by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var autoExtractSchedule by remember { mutableStateOf(true) }
    var pendingConsentSummary by remember { mutableStateOf<String?>(null) }

    DisposableEffect(recorder) {
        onDispose {
            recorder.stopPreviewPlayback()
            stagedAudio?.tempFile?.delete()
            recorder.release()
        }
    }

    val dictationLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val dictated = result.data
            ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            ?.firstOrNull()
            ?.trim()
        if (!dictated.isNullOrBlank()) {
            transcriptText = if (transcriptText.isBlank()) dictated else "$transcriptText\n\n$dictated"
            errorMessage = null
        }
    }

    fun launchDeviceDictation() {
        recorder.stopPreviewPlayback()
        errorMessage = null
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            val configuredLang = prefs.audioTranscriptionLanguage.trim()
            val locale = if (configuredLang.isNotEmpty()) {
                Locale.forLanguageTag(configuredLang.replace('_', '-'))
            } else {
                Locale.getDefault()
            }
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.toLanguageTag())
            putExtra(
                RecognizerIntent.EXTRA_PROMPT,
                L10n.text("请开始口述或会议发言（免费系统识别）", "Speak to dictate notes (free on-device)")
            )
        }
        runCatching { dictationLauncher.launch(intent) }.onFailure {
            errorMessage = L10n.text(
                "当前设备暂不支持系统语音听写服务，可录音后使用 Whisper 转写。",
                "System speech recognition is unavailable on this device. Please record and transcribe via Whisper."
            )
        }
    }

    fun startVoiceCapture() {
        errorMessage = null
        stagedAudio?.tempFile?.delete()
        stagedAudio = null
        recorder.startRecording().onFailure { err ->
            errorMessage = err.message ?: L10n.text("无法开始录音。", "Failed to start recording.")
        }
    }

    val micPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            startVoiceCapture()
        } else {
            errorMessage = L10n.text(
                "未获得麦克风权限，可在系统设置中开启，或直接点击右侧「导入音频文件」。",
                "Microphone permission denied. Grant it in Settings or tap Import Audio File."
            )
        }
    }

    val audioFileLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            errorMessage = null
            try {
                val clip = withContext(Dispatchers.IO) {
                    readAudioClipFromUri(context.contentResolver, uri)
                }
                stagedAudio?.tempFile?.delete()
                stagedAudio = clip
            } catch (t: Throwable) {
                if (t is CancellationException) throw t
                errorMessage = t.message ?: L10n.text("读取音频文件失败。", "Failed to read audio file.")
            }
        }
    }

    fun executeTranscribe() {
        val clip = stagedAudio ?: return
        scope.launch {
            isTranscribing = true
            errorMessage = null
            onTranscribe(clip.fileName, clip.mimeType, clip.bytes).fold(
                onSuccess = { text ->
                    transcriptText = if (transcriptText.isBlank()) text else "$transcriptText\n\n$text"
                    clip.tempFile?.delete()
                },
                onFailure = { err ->
                    errorMessage = err.message ?: L10n.text("音频转写失败。", "Audio transcription failed.")
                }
            )
            isTranscribing = false
        }
    }

    fun requestTranscribeWithConsent() {
        val activeProvider = provider
        if (activeProvider == null) {
            errorMessage = L10n.text(
                "请先配置并启用一个 OpenAI 兼容服务商。",
                "Please configure and enable an OpenAI-compatible provider first."
            )
            return
        }
        if (!container.preferences.isConsentAccepted) {
            val host = runCatching { URI(activeProvider.baseURL.trim().trimEnd('#')).host ?: "" }.getOrDefault("")
            val model = prefs.audioTranscriptionModel
            pendingConsentSummary = if (host.isEmpty()) {
                "${activeProvider.name} · $model"
            } else {
                "${activeProvider.name} · $model ($host)"
            }
            return
        }
        executeTranscribe()
    }

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
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.GraphicEq,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = L10n.text("录音与音频转会议纪要", "Voice & Audio Transcription"),
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                    )
                    Text(
                        text = L10n.text(
                            "支持现场录音或导入 m4a / mp3 / wav，调用 Whisper 接口转文字并提炼纪要与待办。",
                            "Record live or import audio, transcribe via Whisper, and extract meeting action items."
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            if (provider != null) {
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.55f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    val langHint = prefs.audioTranscriptionLanguage.ifBlank { L10n.text("自动检测", "Auto") }
                    Text(
                        text = L10n.text(
                            "转写接口：${provider.name} · ${prefs.audioTranscriptionModel}（语言：$langHint）",
                            "Endpoint: ${provider.name} · ${prefs.audioTranscriptionModel} (Lang: $langHint)"
                        ),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                        modifier = Modifier.padding(horizontal = DS.Spacing.md, vertical = 8.dp)
                    )
                }
            } else {
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.7f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = L10n.text(
                                "未连接 Whisper 服务商（OpenAI / Groq / 硅基流动）：可直接使用下方「设备免费听写」，或先配置 Whisper Key。",
                                "No Whisper provider connected: use Free Device Dictation below or configure an endpoint."
                            ),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.weight(1f)
                        )
                        TextButton(onClick = {
                            onDismiss()
                            onGoToProviders()
                        }) {
                            Text(L10n.text("去配置", "Setup"))
                        }
                    }
                }
            }

            if (isRecording) {
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(horizontal = DS.Spacing.md, vertical = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        AudioWaveformBars(
                            levels = levelHistory,
                            isPaused = isPaused,
                            modifier = Modifier.fillMaxWidth()
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = if (isPaused) L10n.text("录音已暂停", "Paused") else L10n.text("正在录音", "Recording"),
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = if (isPaused) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.error
                            )
                            val mins = elapsedSeconds / 60
                            val secs = elapsedSeconds % 60
                            Text(
                                text = String.format(Locale.US, "%02d:%02d", mins, secs),
                                style = MaterialTheme.typography.labelMedium
                            )
                        }
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                if (isRecording) {
                    OutlinedButton(
                        enabled = !isTranscribing,
                        onClick = {
                            if (isPaused) {
                                recorder.resumeRecording().onFailure { errorMessage = it.message }
                            } else {
                                recorder.pauseRecording().onFailure { errorMessage = it.message }
                            }
                        },
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(
                            imageVector = if (isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(modifier = Modifier.size(6.dp))
                        Text(if (isPaused) L10n.text("继续", "Resume") else L10n.text("暂停", "Pause"))
                    }

                    Button(
                        onClick = {
                            recorder.stopRecording().fold(
                                onSuccess = { file ->
                                    val bytes = runCatching { file.readBytes() }.getOrElse { ByteArray(0) }
                                    if (bytes.isEmpty()) {
                                        errorMessage = L10n.text("录音文件为空。", "Recorded file is empty.")
                                        runCatching { file.delete() }
                                    } else {
                                        stagedAudio = StagedAudioClip(
                                            fileName = file.name,
                                            mimeType = "audio/mp4",
                                            bytes = bytes,
                                            tempFile = file
                                        )
                                    }
                                },
                                onFailure = { err ->
                                    errorMessage = err.message
                                }
                            )
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.size(6.dp))
                        val mins = elapsedSeconds / 60
                        val secs = elapsedSeconds % 60
                        Text(String.format(Locale.US, "%s %02d:%02d", L10n.text("停止", "Stop"), mins, secs))
                    }
                } else {
                    Button(
                        enabled = !isTranscribing,
                        onClick = {
                            val granted = ContextCompat.checkSelfPermission(
                                context,
                                Manifest.permission.RECORD_AUDIO
                            ) == PackageManager.PERMISSION_GRANTED
                            if (granted) {
                                startVoiceCapture()
                            } else {
                                micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                            }
                        },
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Filled.Mic, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.size(6.dp))
                        Text(L10n.text("开始录音", "Record"))
                    }

                    OutlinedButton(
                        enabled = !isTranscribing,
                        onClick = {
                            recorder.stopPreviewPlayback()
                            audioFileLauncher.launch(arrayOf("audio/*", "video/mp4", "application/ogg"))
                        },
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Filled.AudioFile, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.size(6.dp))
                        Text(L10n.text("导入音频", "Import Audio"))
                    }
                }
            }

            OutlinedButton(
                enabled = !isRecording && !isTranscribing,
                onClick = { launchDeviceDictation() },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.RecordVoiceOver, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.size(6.dp))
                Text(L10n.text("设备免费听写（免 Whisper Key）", "Free Device Dictation (No Key Required)"))
            }

            stagedAudio?.let { clip ->
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.md, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(Icons.Filled.AudioFile, contentDescription = null, modifier = Modifier.size(18.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = clip.fileName,
                                style = MaterialTheme.typography.labelLarge,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = "${clip.formattedSize} · ${clip.mimeType}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        FilledTonalIconButton(
                            enabled = !isRecording && !isTranscribing,
                            onClick = {
                                recorder.togglePreviewPlayback(clip.tempFile, clip.bytes).onFailure { err ->
                                    errorMessage = err.message
                                }
                            }
                        ) {
                            Icon(
                                imageVector = if (isPlayingPreview) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                                contentDescription = if (isPlayingPreview) {
                                    L10n.text("停止试听", "Stop Preview")
                                } else {
                                    L10n.text("试听", "Preview")
                                }
                            )
                        }
                        Button(
                            enabled = provider != null && !isTranscribing && !isRecording,
                            onClick = {
                                recorder.stopPreviewPlayback()
                                requestTranscribeWithConsent()
                            }
                        ) {
                            Text(
                                if (isTranscribing) L10n.text("转写中…", "Transcribing…")
                                else L10n.text("转成文字", "Transcribe")
                            )
                        }
                    }
                }
            }

            if (isTranscribing) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            errorMessage?.let { msg ->
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(DS.Radius.xs),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = msg,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(DS.Spacing.sm)
                    )
                }
            }

            OutlinedTextField(
                value = transcriptText,
                onValueChange = { transcriptText = it },
                label = { Text(L10n.text("转写文本（可直接核对修改）", "Transcript (Editable)")) },
                placeholder = {
                    Text(
                        L10n.text(
                            "录音或导入音频后点击「转成文字」，也可直接在此粘贴会议速记文本…",
                            "Transcribe an audio clip above or paste raw notes here…"
                        )
                    )
                },
                minLines = 4,
                maxLines = 10,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 120.dp, max = 260.dp)
            )

            if (transcriptText.isNotBlank()) {
                HorizontalDivider()
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Row(
                        modifier = Modifier.weight(1f),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.EventAvailable,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(18.dp)
                        )
                        Text(
                            text = L10n.text("纪要生成后自动提取待办写入日历", "Auto-extract calendar items after minutes"),
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    Switch(
                        checked = autoExtractSchedule,
                        onCheckedChange = { autoExtractSchedule = it }
                    )
                }

                Button(
                    enabled = !isTranscribing,
                    onClick = {
                        onSubmit(
                            transcriptText,
                            stagedAudio?.fileName,
                            TranscriptActionMode.MEETING_MINUTES,
                            autoExtractSchedule
                        )
                        onDismiss()
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(L10n.text("生成会议纪要并发送", "Generate Meeting Minutes"))
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
                ) {
                    OutlinedButton(
                        enabled = !isTranscribing,
                        onClick = {
                            onSubmit(
                                transcriptText,
                                stagedAudio?.fileName,
                                TranscriptActionMode.VOICE_NOTE_CLEANUP,
                                false
                            )
                            onDismiss()
                        },
                        modifier = Modifier.weight(1f)
                    ) {
                        Text(L10n.text("整理口述笔记", "Clean Voice Note"))
                    }
                    TextButton(
                        enabled = !isTranscribing,
                        onClick = {
                            onSubmit(
                                transcriptText,
                                stagedAudio?.fileName,
                                TranscriptActionMode.INSERT_RAW,
                                false
                            )
                            onDismiss()
                        },
                        modifier = Modifier.weight(1f)
                    ) {
                        Text(L10n.text("仅填入输入框", "Insert Transcript"))
                    }
                }
            }
        }
    }

    pendingConsentSummary?.let { summary ->
        AIConsentDialog(
            targetSummary = summary,
            onAccept = {
                pendingConsentSummary = null
                scope.launch {
                    container.preferences.setAIConsentAccepted(true)
                    executeTranscribe()
                }
            },
            onDismiss = { pendingConsentSummary = null }
        )
    }
}

private fun readAudioClipFromUri(contentResolver: ContentResolver, uri: Uri): StagedAudioClip {
    var displayName: String? = null
    contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) {
            val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) displayName = cursor.getString(idx)
        }
    }
    val rawName = displayName?.takeIf { it.isNotBlank() } ?: (uri.lastPathSegment ?: "audio.m4a")
    val safeName = AudioTranscriptionService.sanitizeFileName(rawName)
    val mimeType = AudioTranscriptionService.mimeTypeForExtension(safeName, contentResolver.getType(uri))
    val bytes = contentResolver.openInputStream(uri)?.use { stream ->
        AudioTranscriptionService.readBoundedAudioBytes(stream)
    } ?: throw IllegalStateException(L10n.text("无法打开所选音频文件。", "Unable to open selected audio file."))
    return StagedAudioClip(
        fileName = safeName,
        mimeType = mimeType,
        bytes = bytes,
        tempFile = null
    )
}

@Composable
private fun AudioWaveformBars(
    levels: List<Float>,
    isPaused: Boolean,
    modifier: Modifier = Modifier
) {
    val capacity = AudioMeteringNormalizer.MAX_SAMPLES
    val padCount = (capacity - levels.size).coerceAtLeast(0)
    val recent = if (levels.size > capacity) levels.takeLast(capacity) else levels
    val activeColor = if (isPaused) {
        MaterialTheme.colorScheme.tertiary
    } else {
        MaterialTheme.colorScheme.primary
    }
    val placeholderColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.24f)

    Row(
        modifier = modifier.height(30.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        repeat(padCount) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(4.dp)
                    .background(placeholderColor, CircleShape)
            )
        }
        recent.forEach { level ->
            val barHeight = (level.coerceIn(0.08f, 1.0f) * 28f).coerceAtLeast(3f)
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(barHeight.dp)
                    .background(activeColor, CircleShape)
            )
        }
    }
}
