package com.iosbox.app.core.system

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.iosbox.app.core.model.L10n
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale
import java.util.UUID

object SpeechTextCleaner {
    private val FENCED_CODE_REGEX = Regex("```[\\s\\S]*?```")
    private val LINK_REGEX = Regex("\\[([^\\]]+)]\\(([^)]+)\\)")
    private val HEADING_REGEX = Regex("(?m)^#{1,6}\\s+")
    private val BLOCKQUOTE_REGEX = Regex("(?m)^>\\s*")
    private val URL_REGEX = Regex("https?://\\S+")

    fun cleanForSpeech(markdown: String): String {
        val codeReplacement = L10n.text("代码片段。", "Code block.")
        var cleaned = FENCED_CODE_REGEX.replace(markdown, " $codeReplacement ")
        cleaned = LINK_REGEX.replace(cleaned) { it.groupValues[1] }
        cleaned = HEADING_REGEX.replace(cleaned, "")
        cleaned = BLOCKQUOTE_REGEX.replace(cleaned, "")
        cleaned = URL_REGEX.replace(cleaned, "")
        cleaned = cleaned
            .replace("$$", " ")
            .replace("\\(", " ")
            .replace("\\)", " ")
            .replace("\\[", " ")
            .replace("\\]", " ")
            .replace("`", "")
            .replace("**", "")
            .replace("__", "")
            .replace("~~", "")
            .replace("*", "")
            .replace("$", "")
        return cleaned.replace(Regex("\\s+"), " ").trim()
    }

    fun detectPreferredLocale(text: String): Locale {
        var hanCount = 0
        var letterCount = 0
        var idx = 0
        while (idx < text.length) {
            val cp = text.codePointAt(idx)
            idx += Character.charCount(cp)
            if (Character.isLetter(cp)) {
                letterCount++
                if (Character.UnicodeScript.of(cp) == Character.UnicodeScript.HAN) {
                    hanCount++
                }
            }
        }
        val isChinese = hanCount >= 4 || (letterCount > 0 && hanCount.toDouble() / letterCount >= 0.15)
        return if (isChinese) Locale.SIMPLIFIED_CHINESE else Locale.US
    }
}

class SpeechController(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _speakingMessageID = MutableStateFlow<String?>(null)
    val speakingMessageID: StateFlow<String?> = _speakingMessageID.asStateFlow()

    @Volatile
    private var tts: TextToSpeech? = null

    @Volatile
    private var isReady: Boolean = false

    @Volatile
    private var pendingUtterance: Pair<String, String>? = null

    private var cloudJob: Job? = null
    private var mediaPlayer: MediaPlayer? = null
    private var activeTempAudioFile: File? = null

    fun toggleSpeak(
        messageID: String,
        rawMarkdown: String,
        cloudSynthesizer: (suspend (cleanedText: String) -> ByteArray?)? = null
    ) {
        if (_speakingMessageID.value == messageID) {
            stopSpeaking()
            return
        }
        val spokenText = SpeechTextCleaner.cleanForSpeech(rawMarkdown)
        if (spokenText.isEmpty()) return

        stopSpeaking()
        _speakingMessageID.value = messageID

        if (cloudSynthesizer == null) {
            speakLocally(messageID, spokenText)
            return
        }

        cloudJob = scope.launch {
            val audioBytes = withContext(Dispatchers.IO) {
                try {
                    cloudSynthesizer(spokenText)
                } catch (c: CancellationException) {
                    throw c
                } catch (_: Throwable) {
                    null
                }
            }
            if (_speakingMessageID.value != messageID) return@launch
            if (audioBytes != null && audioBytes.isNotEmpty() && playMp3Bytes(messageID, audioBytes, spokenText)) {
                return@launch
            }
            if (_speakingMessageID.value == messageID) {
                speakLocally(messageID, spokenText)
            }
        }
    }

    private fun speakLocally(messageID: String, spokenText: String) {
        val instance = tts
        if (instance == null) {
            pendingUtterance = messageID to spokenText
            initTts()
            return
        }
        if (!isReady) {
            pendingUtterance = messageID to spokenText
            return
        }
        speakInternal(instance, messageID, spokenText)
    }

    private fun playMp3Bytes(messageID: String, bytes: ByteArray, fallbackText: String): Boolean {
        return runCatching {
            val ttsDir = File(appContext.cacheDir, "tts").apply { mkdirs() }
            ttsDir.listFiles()?.forEach { stale ->
                if (System.currentTimeMillis() - stale.lastModified() > 60 * 60 * 1000L) {
                    stale.delete()
                }
            }
            val file = File(ttsDir, "speech_${UUID.randomUUID()}.mp3")
            file.writeBytes(bytes)
            activeTempAudioFile = file
            val player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                setDataSource(file.absolutePath)
                setOnCompletionListener {
                    scope.launch {
                        cleanupMediaPlayer()
                        if (_speakingMessageID.value == messageID) {
                            _speakingMessageID.value = null
                        }
                    }
                }
                setOnErrorListener { _, _, _ ->
                    scope.launch {
                        cleanupMediaPlayer()
                        if (_speakingMessageID.value == messageID) {
                            speakLocally(messageID, fallbackText)
                        }
                    }
                    true
                }
                prepare()
                start()
            }
            mediaPlayer = player
            true
        }.getOrElse {
            cleanupMediaPlayer()
            false
        }
    }

    private fun cleanupMediaPlayer() {
        runCatching {
            mediaPlayer?.stop()
        }
        runCatching {
            mediaPlayer?.release()
        }
        mediaPlayer = null
        runCatching { activeTempAudioFile?.delete() }
        activeTempAudioFile = null
    }

    fun stopSpeaking() {
        cloudJob?.cancel()
        cloudJob = null
        pendingUtterance = null
        _speakingMessageID.value = null
        cleanupMediaPlayer()
        runCatching { tts?.stop() }
    }

    fun shutdown() {
        stopSpeaking()
        runCatching {
            tts?.stop()
            tts?.shutdown()
        }
        tts = null
        isReady = false
        scope.cancel()
    }

    private fun initTts() {
        lateinit var created: TextToSpeech
        created = TextToSpeech(appContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                isReady = true
                created.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        _speakingMessageID.value = utteranceId
                    }

                    override fun onDone(utteranceId: String?) {
                        if (_speakingMessageID.value == utteranceId) {
                            _speakingMessageID.value = null
                        }
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        if (_speakingMessageID.value == utteranceId) {
                            _speakingMessageID.value = null
                        }
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        if (_speakingMessageID.value == utteranceId) {
                            _speakingMessageID.value = null
                        }
                    }

                    override fun onStop(utteranceId: String?, interrupted: Boolean) {
                        if (_speakingMessageID.value == utteranceId) {
                            _speakingMessageID.value = null
                        }
                    }
                })
                val pending = pendingUtterance
                pendingUtterance = null
                if (pending != null && _speakingMessageID.value == pending.first) {
                    speakInternal(created, pending.first, pending.second)
                }
            } else {
                isReady = false
                pendingUtterance = null
                _speakingMessageID.value = null
            }
        }
        tts = created
    }

    private fun speakInternal(engine: TextToSpeech, messageID: String, text: String) {
        val locale = SpeechTextCleaner.detectPreferredLocale(text)
        runCatching {
            val langResult = engine.setLanguage(locale)
            if (langResult == TextToSpeech.LANG_MISSING_DATA || langResult == TextToSpeech.LANG_NOT_SUPPORTED) {
                engine.language = Locale.getDefault()
            }
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, messageID)
        }.onFailure {
            _speakingMessageID.value = null
        }
    }
}
