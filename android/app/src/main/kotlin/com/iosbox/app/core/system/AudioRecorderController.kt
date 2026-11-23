package com.iosbox.app.core.system

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import com.iosbox.app.core.model.L10n
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.log10

object AudioMeteringNormalizer {
    const val MAX_SAMPLES = 36

    fun normalizeDecibels(decibels: Float): Float {
        if (!decibels.isFinite() || decibels <= -55f) return 0.08f
        if (decibels >= 0f) return 1.0f
        val ratio = (decibels + 55f) / 55f
        return 0.08f + ratio * 0.92f
    }

    fun normalizeAmplitude(maxAmplitude: Int): Float {
        if (maxAmplitude <= 0) return 0.08f
        val clamped = maxAmplitude.coerceIn(1, 32_767)
        val decibels = (20.0 * log10(clamped / 32_767.0)).toFloat()
        return normalizeDecibels(decibels)
    }

    fun appendSample(
        sample: Float,
        history: List<Float>,
        capacity: Int = MAX_SAMPLES
    ): List<Float> {
        val next = ArrayList<Float>(minOf(history.size + 1, capacity))
        val keepFrom = (history.size + 1 - capacity).coerceAtLeast(0)
        for (i in keepFrom until history.size) {
            next.add(history[i])
        }
        next.add(sample.coerceIn(0.08f, 1.0f))
        return next
    }
}

class AudioRecorderController(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _isPaused = MutableStateFlow(false)
    val isPaused: StateFlow<Boolean> = _isPaused.asStateFlow()

    private val _elapsedSeconds = MutableStateFlow(0)
    val elapsedSeconds: StateFlow<Int> = _elapsedSeconds.asStateFlow()

    private val _levelHistory = MutableStateFlow<List<Float>>(emptyList())
    val levelHistory: StateFlow<List<Float>> = _levelHistory.asStateFlow()

    private val _isPlayingPreview = MutableStateFlow(false)
    val isPlayingPreview: StateFlow<Boolean> = _isPlayingPreview.asStateFlow()

    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var mediaPlayer: MediaPlayer? = null
    private var previewTempFile: File? = null
    private var timerJob: Job? = null
    private var activeSubticks = 0

    fun startRecording(): Result<File> {
        if (_isRecording.value) {
            return Result.failure(IllegalStateException("Already recording"))
        }
        stopPreviewPlayback()
        return runCatching {
            val audioDir = File(appContext.cacheDir, "audio").apply { mkdirs() }
            val now = System.currentTimeMillis()
            audioDir.listFiles()?.forEach { stale ->
                if (now - stale.lastModified() > 2 * 60 * 60 * 1000L) {
                    stale.delete()
                }
            }
            val file = File.createTempFile("voice_", ".m4a", audioDir)
            val created = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(appContext)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            try {
                created.setAudioSource(MediaRecorder.AudioSource.MIC)
                created.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                created.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                created.setAudioSamplingRate(16_000)
                created.setAudioEncodingBitRate(64_000)
                created.setAudioChannels(1)
                created.setOutputFile(file.absolutePath)
                created.prepare()
                created.start()
            } catch (t: Throwable) {
                runCatching { created.release() }
                runCatching { file.delete() }
                throw t
            }
            recorder = created
            outputFile = file
            _elapsedSeconds.value = 0
            _isPaused.value = false
            _levelHistory.value = emptyList()
            activeSubticks = 0
            _isRecording.value = true
            timerJob?.cancel()
            timerJob = scope.launch {
                while (_isRecording.value) {
                    delay(100)
                    if (_isRecording.value && !_isPaused.value) {
                        val amp = runCatching { recorder?.maxAmplitude ?: 0 }.getOrDefault(0)
                        val normalized = AudioMeteringNormalizer.normalizeAmplitude(amp)
                        _levelHistory.value = AudioMeteringNormalizer.appendSample(normalized, _levelHistory.value)
                        activeSubticks += 1
                        if (activeSubticks >= 10) {
                            activeSubticks = 0
                            _elapsedSeconds.value += 1
                        }
                    }
                }
            }
            file
        }
    }

    fun pauseRecording(): Result<Unit> {
        val active = recorder
        if (active == null || !_isRecording.value || _isPaused.value) {
            return Result.failure(IllegalStateException(L10n.text("当前无法暂停录音。", "Cannot pause recording.")))
        }
        return runCatching {
            active.pause()
            _isPaused.value = true
        }
    }

    fun resumeRecording(): Result<Unit> {
        val active = recorder
        if (active == null || !_isRecording.value || !_isPaused.value) {
            return Result.failure(IllegalStateException(L10n.text("当前无法恢复录音。", "Cannot resume recording.")))
        }
        return runCatching {
            active.resume()
            _isPaused.value = false
        }
    }

    fun togglePreviewPlayback(file: File?, bytes: ByteArray?): Result<Unit> {
        if (_isPlayingPreview.value) {
            stopPreviewPlayback()
            return Result.success(Unit)
        }
        if (_isRecording.value) {
            return Result.failure(
                IllegalStateException(L10n.text("请先停止录音后再试听。", "Stop recording before previewing."))
            )
        }
        stopPreviewPlayback()
        return runCatching {
            val sourceFile = when {
                file != null && file.exists() -> file
                bytes != null && bytes.isNotEmpty() -> {
                    val audioDir = File(appContext.cacheDir, "audio").apply { mkdirs() }
                    File.createTempFile("preview_", ".m4a", audioDir).also { created ->
                        created.writeBytes(bytes)
                        previewTempFile = created
                    }
                }
                else -> throw IllegalStateException(L10n.text("没有可试听的音频数据。", "No audio data to preview."))
            }

            val createdPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .build()
                )
                setDataSource(sourceFile.absolutePath)
                setOnCompletionListener { stopPreviewPlayback() }
                setOnErrorListener { _, _, _ ->
                    stopPreviewPlayback()
                    true
                }
                prepare()
                start()
            }
            mediaPlayer = createdPlayer
            _isPlayingPreview.value = true
        }.onFailure {
            stopPreviewPlayback()
        }
    }

    fun stopPreviewPlayback() {
        val activePlayer = mediaPlayer
        mediaPlayer = null
        _isPlayingPreview.value = false
        if (activePlayer != null) {
            runCatching {
                if (activePlayer.isPlaying) {
                    activePlayer.stop()
                }
            }
            runCatching { activePlayer.release() }
        }
        previewTempFile?.let { file ->
            runCatching { file.delete() }
        }
        previewTempFile = null
    }

    fun stopRecording(): Result<File> {
        timerJob?.cancel()
        timerJob = null
        val activeRecorder = recorder
        val targetFile = outputFile
        recorder = null
        outputFile = null
        _isRecording.value = false
        _isPaused.value = false
        activeSubticks = 0

        if (activeRecorder == null || targetFile == null) {
            return Result.failure(
                IllegalStateException(L10n.text("当前未在录音。", "No active recording."))
            )
        }
        return try {
            activeRecorder.stop()
            activeRecorder.release()
            if (!targetFile.exists() || targetFile.length() == 0L) {
                runCatching { targetFile.delete() }
                Result.failure(
                    IllegalStateException(L10n.text("录音时间太短，未录到有效声音。", "Recording too short."))
                )
            } else {
                Result.success(targetFile)
            }
        } catch (_: RuntimeException) {
            runCatching { activeRecorder.release() }
            runCatching { targetFile.delete() }
            Result.failure(
                IllegalStateException(L10n.text("录音时间太短，未录到有效声音。", "Recording too short."))
            )
        }
    }

    fun cancelAndDelete() {
        timerJob?.cancel()
        timerJob = null
        val activeRecorder = recorder
        val targetFile = outputFile
        recorder = null
        outputFile = null
        _isRecording.value = false
        _isPaused.value = false
        _elapsedSeconds.value = 0
        activeSubticks = 0
        _levelHistory.value = emptyList()
        stopPreviewPlayback()
        if (activeRecorder != null) {
            runCatching { activeRecorder.stop() }
            runCatching { activeRecorder.release() }
        }
        runCatching { targetFile?.delete() }
    }

    fun release() {
        stopPreviewPlayback()
        cancelAndDelete()
        scope.cancel()
    }
}
