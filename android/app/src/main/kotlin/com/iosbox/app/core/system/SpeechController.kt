package com.iosbox.app.core.system

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.iosbox.app.core.model.L10n
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale

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
    private val _speakingMessageID = MutableStateFlow<String?>(null)
    val speakingMessageID: StateFlow<String?> = _speakingMessageID.asStateFlow()

    @Volatile
    private var tts: TextToSpeech? = null

    @Volatile
    private var isReady: Boolean = false

    @Volatile
    private var pendingUtterance: Pair<String, String>? = null

    fun toggleSpeak(messageID: String, rawMarkdown: String) {
        if (_speakingMessageID.value == messageID) {
            stopSpeaking()
            return
        }
        val spokenText = SpeechTextCleaner.cleanForSpeech(rawMarkdown)
        if (spokenText.isEmpty()) return

        _speakingMessageID.value = messageID
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

    fun stopSpeaking() {
        pendingUtterance = null
        _speakingMessageID.value = null
        runCatching { tts?.stop() }
    }

    fun shutdown() {
        pendingUtterance = null
        _speakingMessageID.value = null
        runCatching {
            tts?.stop()
            tts?.shutdown()
        }
        tts = null
        isReady = false
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
