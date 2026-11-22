package com.iosbox.app.core.storage

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.network.CapabilityCacheBackingStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

enum class AccentTheme(val rawValue: String) {
    COBALT("cobalt"),
    GRAPHITE("graphite"),
    INDIGO("indigo"),
    TEAL("teal"),
    AMBER("amber");

    val displayName: String
        get() = when (this) {
            COBALT -> L10n.text("钴蓝", "Cobalt")
            GRAPHITE -> L10n.text("石墨", "Graphite")
            INDIGO -> L10n.text("靛青", "Indigo")
            TEAL -> L10n.text("松青", "Teal")
            AMBER -> L10n.text("暖珀", "Amber")
        }

    companion object {
        fun fromRaw(raw: String?): AccentTheme =
            entries.firstOrNull { it.rawValue == raw } ?: COBALT
    }
}

enum class ThemeAppearanceMode(val rawValue: String) {
    SYSTEM("system"),
    LIGHT("light"),
    DARK("dark");

    val displayName: String
        get() = when (this) {
            SYSTEM -> L10n.text("跟随系统", "System")
            LIGHT -> L10n.text("浅色", "Light")
            DARK -> L10n.text("深色", "Dark")
        }

    companion object {
        fun fromRaw(raw: String?): ThemeAppearanceMode =
            entries.firstOrNull { it.rawValue == raw } ?: SYSTEM
    }
}

data class UserPreferencesSnapshot(
    val accentTheme: AccentTheme = AccentTheme.COBALT,
    val appearanceMode: ThemeAppearanceMode = ThemeAppearanceMode.SYSTEM,
    val aiConsentAccepted: Boolean = false,
    val presetsSeeded: Boolean = false,
    val providersSeeded: Boolean = false,
    val defaultTargetID: String? = null,
    val defaultAssistantID: String? = null,
    val audioTranscriptionProviderID: String? = null,
    val audioTranscriptionModel: String = "whisper-1",
    val audioTranscriptionLanguage: String = "",
    val useCloudTTS: Boolean = false,
    val cloudTTSProviderID: String? = null,
    val cloudTTSModel: String = "tts-1",
    val cloudTTSVoice: String = "alloy",
    val simpleDailyMode: Boolean = false,
    val dailyPresetsSeededV2: Boolean = false
)

private val Context.prefsDataStore: DataStore<Preferences> by preferencesDataStore(name = "fugue_preferences")

class AppPreferences(context: Context) : CapabilityCacheBackingStore {
    private val appContext = context.applicationContext

    private object Keys {
        val ACCENT_THEME = stringPreferencesKey("accent_theme")
        val APPEARANCE_MODE = stringPreferencesKey("appearance_mode")
        val AI_CONSENT = booleanPreferencesKey("ai_data_consent_v2")
        val PRESETS_SEEDED = booleanPreferencesKey("has_seeded_presets_v1")
        val PROVIDERS_SEEDED = booleanPreferencesKey("has_seeded_providers_v1")
        val DEFAULT_TARGET = stringPreferencesKey("default_target_id")
        val DEFAULT_ASSISTANT = stringPreferencesKey("default_assistant_id")
        val CAPABILITY_CACHE = stringPreferencesKey("gateway_capability_negations_v1")
        val AUDIO_TRANSCRIPTION_PROVIDER = stringPreferencesKey("audio_transcription_provider_id")
        val AUDIO_TRANSCRIPTION_MODEL = stringPreferencesKey("audio_transcription_model")
        val AUDIO_TRANSCRIPTION_LANGUAGE = stringPreferencesKey("audio_transcription_language")
        val USE_CLOUD_TTS = booleanPreferencesKey("use_cloud_tts")
        val CLOUD_TTS_PROVIDER = stringPreferencesKey("cloud_tts_provider_id")
        val CLOUD_TTS_MODEL = stringPreferencesKey("cloud_tts_model")
        val CLOUD_TTS_VOICE = stringPreferencesKey("cloud_tts_voice")
        val SIMPLE_DAILY_MODE = booleanPreferencesKey("simple_daily_mode")
        val DAILY_PRESETS_SEEDED_V2 = booleanPreferencesKey("has_seeded_daily_presets_v2")
    }

    private val _state = MutableStateFlow(UserPreferencesSnapshot())
    val state: StateFlow<UserPreferencesSnapshot> = _state.asStateFlow()

    @Volatile
    private var capabilityRaw: String? = null

    init {
        val prefs = runBlocking(Dispatchers.IO) {
            appContext.prefsDataStore.data.first()
        }
        capabilityRaw = prefs[Keys.CAPABILITY_CACHE]
        _state.value = UserPreferencesSnapshot(
            accentTheme = AccentTheme.fromRaw(prefs[Keys.ACCENT_THEME]),
            appearanceMode = ThemeAppearanceMode.fromRaw(prefs[Keys.APPEARANCE_MODE]),
            aiConsentAccepted = prefs[Keys.AI_CONSENT] ?: false,
            presetsSeeded = prefs[Keys.PRESETS_SEEDED] ?: false,
            providersSeeded = prefs[Keys.PROVIDERS_SEEDED] ?: false,
            defaultTargetID = prefs[Keys.DEFAULT_TARGET],
            defaultAssistantID = prefs[Keys.DEFAULT_ASSISTANT],
            audioTranscriptionProviderID = prefs[Keys.AUDIO_TRANSCRIPTION_PROVIDER],
            audioTranscriptionModel = prefs[Keys.AUDIO_TRANSCRIPTION_MODEL]?.takeIf { it.isNotBlank() } ?: "whisper-1",
            audioTranscriptionLanguage = prefs[Keys.AUDIO_TRANSCRIPTION_LANGUAGE].orEmpty(),
            useCloudTTS = prefs[Keys.USE_CLOUD_TTS] ?: false,
            cloudTTSProviderID = prefs[Keys.CLOUD_TTS_PROVIDER],
            cloudTTSModel = prefs[Keys.CLOUD_TTS_MODEL]?.takeIf { it.isNotBlank() } ?: "tts-1",
            cloudTTSVoice = prefs[Keys.CLOUD_TTS_VOICE]?.takeIf { it.isNotBlank() } ?: "alloy",
            simpleDailyMode = prefs[Keys.SIMPLE_DAILY_MODE] ?: false,
            dailyPresetsSeededV2 = prefs[Keys.DAILY_PRESETS_SEEDED_V2] ?: false
        )
    }

    val isConsentAccepted: Boolean
        get() = _state.value.aiConsentAccepted

    suspend fun setAccentTheme(theme: AccentTheme) {
        _state.value = _state.value.copy(accentTheme = theme)
        appContext.prefsDataStore.edit { it[Keys.ACCENT_THEME] = theme.rawValue }
    }

    suspend fun setAppearanceMode(mode: ThemeAppearanceMode) {
        _state.value = _state.value.copy(appearanceMode = mode)
        appContext.prefsDataStore.edit { it[Keys.APPEARANCE_MODE] = mode.rawValue }
    }

    suspend fun setAIConsentAccepted(accepted: Boolean) {
        _state.value = _state.value.copy(aiConsentAccepted = accepted)
        appContext.prefsDataStore.edit { it[Keys.AI_CONSENT] = accepted }
    }

    suspend fun markPresetsSeeded() {
        _state.value = _state.value.copy(presetsSeeded = true)
        appContext.prefsDataStore.edit { it[Keys.PRESETS_SEEDED] = true }
    }

    suspend fun markProvidersSeeded() {
        _state.value = _state.value.copy(providersSeeded = true)
        appContext.prefsDataStore.edit { it[Keys.PROVIDERS_SEEDED] = true }
    }

    suspend fun setDefaultTargetID(id: String?) {
        _state.value = _state.value.copy(defaultTargetID = id)
        appContext.prefsDataStore.edit {
            if (id.isNullOrBlank()) it.remove(Keys.DEFAULT_TARGET) else it[Keys.DEFAULT_TARGET] = id
        }
    }

    suspend fun setDefaultAssistantID(id: String?) {
        _state.value = _state.value.copy(defaultAssistantID = id)
        appContext.prefsDataStore.edit {
            if (id.isNullOrBlank()) it.remove(Keys.DEFAULT_ASSISTANT) else it[Keys.DEFAULT_ASSISTANT] = id
        }
    }

    suspend fun setAudioTranscriptionProviderID(id: String?) {
        val clean = id?.trim()?.takeIf { it.isNotEmpty() }
        _state.value = _state.value.copy(audioTranscriptionProviderID = clean)
        appContext.prefsDataStore.edit {
            if (clean == null) it.remove(Keys.AUDIO_TRANSCRIPTION_PROVIDER) else it[Keys.AUDIO_TRANSCRIPTION_PROVIDER] = clean
        }
    }

    suspend fun setAudioTranscriptionModel(model: String) {
        val clean = model.trim().ifEmpty { "whisper-1" }
        _state.value = _state.value.copy(audioTranscriptionModel = clean)
        appContext.prefsDataStore.edit { it[Keys.AUDIO_TRANSCRIPTION_MODEL] = clean }
    }

    suspend fun setAudioTranscriptionLanguage(language: String) {
        val clean = language.trim()
        _state.value = _state.value.copy(audioTranscriptionLanguage = clean)
        appContext.prefsDataStore.edit {
            if (clean.isEmpty()) it.remove(Keys.AUDIO_TRANSCRIPTION_LANGUAGE) else it[Keys.AUDIO_TRANSCRIPTION_LANGUAGE] = clean
        }
    }

    suspend fun setUseCloudTTS(enabled: Boolean) {
        _state.value = _state.value.copy(useCloudTTS = enabled)
        appContext.prefsDataStore.edit { it[Keys.USE_CLOUD_TTS] = enabled }
    }

    suspend fun setCloudTTSProviderID(id: String?) {
        val clean = id?.trim()?.takeIf { it.isNotEmpty() }
        _state.value = _state.value.copy(cloudTTSProviderID = clean)
        appContext.prefsDataStore.edit {
            if (clean == null) it.remove(Keys.CLOUD_TTS_PROVIDER) else it[Keys.CLOUD_TTS_PROVIDER] = clean
        }
    }

    suspend fun setCloudTTSModel(model: String) {
        val clean = model.trim().ifEmpty { "tts-1" }
        _state.value = _state.value.copy(cloudTTSModel = clean)
        appContext.prefsDataStore.edit { it[Keys.CLOUD_TTS_MODEL] = clean }
    }

    suspend fun setCloudTTSVoice(voice: String) {
        val clean = voice.trim().ifEmpty { "alloy" }
        _state.value = _state.value.copy(cloudTTSVoice = clean)
        appContext.prefsDataStore.edit { it[Keys.CLOUD_TTS_VOICE] = clean }
    }

    suspend fun setSimpleDailyMode(enabled: Boolean) {
        _state.value = _state.value.copy(simpleDailyMode = enabled)
        appContext.prefsDataStore.edit { it[Keys.SIMPLE_DAILY_MODE] = enabled }
    }

    suspend fun markDailyPresetsSeededV2() {
        _state.value = _state.value.copy(dailyPresetsSeededV2 = true)
        appContext.prefsDataStore.edit { it[Keys.DAILY_PRESETS_SEEDED_V2] = true }
    }

    override fun loadRaw(): String? = capabilityRaw

    override fun saveRaw(raw: String?) {
        capabilityRaw = raw
        runBlocking(Dispatchers.IO) {
            appContext.prefsDataStore.edit {
                if (raw == null) it.remove(Keys.CAPABILITY_CACHE) else it[Keys.CAPABILITY_CACHE] = raw
            }
        }
    }
}
