package com.iosbox.app.core.security

import android.content.Context
import android.util.Base64
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.google.crypto.tink.Aead
import com.google.crypto.tink.KeyTemplates
import com.google.crypto.tink.RegistryConfiguration
import com.google.crypto.tink.aead.AeadConfig
import com.google.crypto.tink.integration.android.AndroidKeysetManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.concurrent.ConcurrentHashMap

interface SecretStore {
    val versionFlow: StateFlow<Long>

    fun loadAPIKey(providerID: String): String = loadSecret(providerID.uppercase())

    fun saveAPIKey(providerID: String, rawKey: String): Boolean =
        saveSecret(rawKey, providerID.uppercase())

    fun loadExtraAPIKeys(providerID: String): List<String> {
        val raw = loadSecret(extraKeysAccount(providerID))
        if (raw.isEmpty()) return emptyList()
        val decoded = runCatching { Json.decodeFromString<List<String>>(raw) }.getOrNull() ?: return emptyList()
        val seen = HashSet<String>()
        return decoded.mapNotNull { item ->
            val t = item.trim()
            if (t.isNotEmpty() && seen.add(t)) t else null
        }
    }

    fun saveExtraAPIKeys(providerID: String, keys: List<String>): Boolean {
        val cleaned = deduplicateKeys(keys)
        val encoded = if (cleaned.isEmpty()) "" else Json.encodeToString(cleaned)
        return saveSecret(encoded, extraKeysAccount(providerID))
    }

    fun loadAllAPIKeys(providerID: String): List<String> {
        return deduplicateKeys(listOf(loadAPIKey(providerID)) + loadExtraAPIKeys(providerID))
    }

    fun hasAPIKey(providerID: String): Boolean = loadAllAPIKeys(providerID).isNotEmpty()

    fun deleteAPIKey(providerID: String) {
        deleteSecret(providerID.uppercase())
        deleteSecret(extraKeysAccount(providerID))
    }

    fun loadIdleTimeoutSeconds(providerID: String): Int {
        val raw = loadSecret(timeoutAccount(providerID)).toIntOrNull() ?: 0
        return if (raw > 0) raw.coerceIn(5, 3600) else 0
    }

    fun saveIdleTimeoutSeconds(providerID: String, seconds: Int) {
        val normalized = if (seconds > 0) seconds.coerceIn(5, 3600) else 0
        if (normalized == 0) {
            deleteSecret(timeoutAccount(providerID))
        } else {
            saveSecret(normalized.toString(), timeoutAccount(providerID))
        }
    }

    fun deleteProviderSecrets(providerID: String, headerIDs: List<String>) {
        deleteAPIKey(providerID)
        for (headerID in headerIDs) {
            deleteSecret(headerAccount(providerID, headerID))
        }
        deleteSecret(timeoutAccount(providerID))
    }

    fun loadSecret(account: String): String
    fun saveSecret(rawValue: String, account: String): Boolean
    fun restoreSecretIfMissing(value: String, account: String): Boolean
    fun deleteSecret(account: String)

    companion object {
        const val TAVILY_KEY_ACCOUNT = "search/tavily"
        const val PERSONA_X_TOKEN_ACCOUNT = "persona-x-read-bearer"
        val SUPPORTED_TIMEOUT_OPTIONS = listOf(0, 30, 60, 120, 300)

        fun extraKeysAccount(providerID: String): String = "${providerID.uppercase()}/extra-keys"
        fun headerAccount(providerID: String, headerID: String): String =
            "${providerID.uppercase()}/header/${headerID.uppercase()}"
        fun timeoutAccount(providerID: String): String = "${providerID.uppercase()}/idle-timeout"

        fun deduplicateKeys(keys: List<String>): List<String> {
            val seen = HashSet<String>()
            return keys.mapNotNull { raw ->
                val t = raw.trim()
                if (t.isNotEmpty() && seen.add(t)) t else null
            }
        }

        fun maskedKeyPreview(rawKey: String): String {
            val trimmed = rawKey.trim()
            if (trimmed.isEmpty()) return ""
            if (trimmed.length <= 8) return "•".repeat(maxOf(4, trimmed.length))
            return "${trimmed.take(4)}••••${trimmed.takeLast(4)}"
        }
    }
}

private val Context.secretsDataStore: DataStore<Preferences> by preferencesDataStore(name = "fugue_secrets")

class TinkSecretStore(context: Context) : SecretStore {
    private val appContext = context.applicationContext
    private val lock = Any()
    private val cache = ConcurrentHashMap<String, String>()
    private val json = Json { ignoreUnknownKeys = true }
    private val vaultKey = stringPreferencesKey("encrypted_vault")
    private val _versionFlow = MutableStateFlow(0L)
    override val versionFlow: StateFlow<Long> = _versionFlow.asStateFlow()

    private val aead: Aead by lazy {
        AeadConfig.register()
        val keysetManager = AndroidKeysetManager.Builder()
            .withSharedPref(appContext, "fugue_tink_keyset", "fugue_tink_prefs")
            .withKeyTemplate(KeyTemplates.get("AES256_GCM"))
            .withMasterKeyUri("android-keystore://fugue_master_key")
            .build()
        keysetManager.keysetHandle.getPrimitive(RegistryConfiguration.get(), Aead::class.java)
    }

    init {
        loadVaultIntoCache()
    }

    private fun loadVaultIntoCache() {
        synchronized(lock) {
            val encoded = runBlocking(Dispatchers.IO) {
                appContext.secretsDataStore.data.first()[vaultKey]
            } ?: return
            val decoded = runCatching {
                val cipherBytes = Base64.decode(encoded, Base64.NO_WRAP)
                val plainBytes = aead.decrypt(cipherBytes, VAULT_AAD)
                json.decodeFromString<Map<String, String>>(plainBytes.toString(Charsets.UTF_8))
            }.getOrNull() ?: return
            cache.clear()
            cache.putAll(decoded)
        }
    }

    private fun persistVaultLocked(): Boolean {
        return runCatching {
            val plainBytes = json.encodeToString(cache.toMap()).toByteArray(Charsets.UTF_8)
            val cipherBytes = aead.encrypt(plainBytes, VAULT_AAD)
            val encoded = Base64.encodeToString(cipherBytes, Base64.NO_WRAP)
            runBlocking(Dispatchers.IO) {
                appContext.secretsDataStore.edit { prefs ->
                    prefs[vaultKey] = encoded
                }
            }
            true
        }.getOrDefault(false)
    }

    override fun loadSecret(account: String): String = cache[account] ?: ""

    override fun saveSecret(rawValue: String, account: String): Boolean {
        val trimmed = rawValue.trim()
        synchronized(lock) {
            val existing = cache[account] ?: ""
            if (existing == trimmed) return true
            val prev = cache[account]
            if (trimmed.isEmpty()) {
                cache.remove(account)
            } else {
                cache[account] = trimmed
            }
            val ok = persistVaultLocked()
            if (!ok) {
                if (prev == null) cache.remove(account) else cache[account] = prev
                return false
            }
            _versionFlow.value += 1
            return true
        }
    }

    override fun restoreSecretIfMissing(value: String, account: String): Boolean {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return true
        synchronized(lock) {
            if (!cache[account].isNullOrEmpty()) return true
            cache[account] = trimmed
            val ok = persistVaultLocked()
            if (!ok) {
                cache.remove(account)
                return false
            }
            _versionFlow.value += 1
            return true
        }
    }

    override fun deleteSecret(account: String) {
        synchronized(lock) {
            if (!cache.containsKey(account)) return
            val prev = cache.remove(account)
            if (!persistVaultLocked()) {
                if (prev != null) cache[account] = prev
            } else {
                _versionFlow.value += 1
            }
        }
    }

    companion object {
        private val VAULT_AAD = "com.iosbox.app.secrets.v1".toByteArray(Charsets.UTF_8)
    }
}

class InMemorySecretStore : SecretStore {
    private val lock = Any()
    private val map = HashMap<String, String>()
    private val _versionFlow = MutableStateFlow(0L)
    override val versionFlow: StateFlow<Long> = _versionFlow.asStateFlow()

    override fun loadSecret(account: String): String = synchronized(lock) {
        map[account] ?: ""
    }

    override fun saveSecret(rawValue: String, account: String): Boolean {
        val trimmed = rawValue.trim()
        synchronized(lock) {
            if (trimmed.isEmpty()) map.remove(account) else map[account] = trimmed
            _versionFlow.value += 1
        }
        return true
    }

    override fun restoreSecretIfMissing(value: String, account: String): Boolean {
        val trimmed = value.trim()
        if (trimmed.isEmpty()) return true
        synchronized(lock) {
            if (map[account].isNullOrEmpty()) {
                map[account] = trimmed
                _versionFlow.value += 1
            }
        }
        return true
    }

    override fun deleteSecret(account: String) {
        synchronized(lock) {
            if (map.remove(account) != null) {
                _versionFlow.value += 1
            }
        }
    }
}
