package com.iosbox.app.core.system

import android.content.Context
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

class AudioRecorderController(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _elapsedSeconds = MutableStateFlow(0)
    val elapsedSeconds: StateFlow<Int> = _elapsedSeconds.asStateFlow()

    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var timerJob: Job? = null

    fun startRecording(): Result<File> {
        if (_isRecording.value) {
            return Result.failure(IllegalStateException("Already recording"))
        }
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
            _isRecording.value = true
            timerJob?.cancel()
            timerJob = scope.launch {
                while (_isRecording.value) {
                    delay(1_000)
                    if (_isRecording.value) {
                        _elapsedSeconds.value += 1
                    }
                }
            }
            file
        }
    }

    fun stopRecording(): Result<File> {
        timerJob?.cancel()
        timerJob = null
        val activeRecorder = recorder
        val targetFile = outputFile
        recorder = null
        outputFile = null
        _isRecording.value = false

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
        _elapsedSeconds.value = 0
        if (activeRecorder != null) {
            runCatching { activeRecorder.stop() }
            runCatching { activeRecorder.release() }
        }
        runCatching { targetFile?.delete() }
    }

    fun release() {
        cancelAndDelete()
        scope.cancel()
    }
}
