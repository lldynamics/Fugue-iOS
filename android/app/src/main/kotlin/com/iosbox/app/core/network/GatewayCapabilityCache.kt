package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.security.MessageDigest

interface CapabilityCacheBackingStore {
    fun loadRaw(): String?
    fun saveRaw(raw: String?)
}

class InMemoryCapabilityCacheStore : CapabilityCacheBackingStore {
    @Volatile
    private var raw: String? = null
    override fun loadRaw(): String? = raw
    override fun saveRaw(raw: String?) {
        this.raw = raw
    }
}

class GatewayCapabilityCache(
    private val backingStore: CapabilityCacheBackingStore = InMemoryCapabilityCacheStore(),
    private val ttlMs: Long = 7L * 24 * 3600 * 1000L,
    private val maxEntries: Int = 256
) {
    @Serializable
    data class Entry(
        val features: Set<GatewayUnsupportedFeature>,
        val updatedAtEpochMs: Long
    )

    private val lock = Any()
    private val json = Json { ignoreUnknownKeys = true }
    private val entries: MutableMap<String, Entry>

    init {
        val decoded = backingStore.loadRaw()?.let { raw ->
            runCatching { json.decodeFromString<Map<String, Entry>>(raw) }.getOrNull()
        }
        entries = decoded?.toMutableMap() ?: mutableMapOf()
    }

    fun isUnsupported(
        feature: GatewayUnsupportedFeature,
        protocolType: APIProtocolType,
        baseURL: String,
        modelID: String,
        nowMs: Long = System.currentTimeMillis()
    ): Boolean {
        val key = cacheKey(protocolType, baseURL, modelID)
        var snapshotToPersist: Map<String, Entry>? = null
        val result: Boolean
        synchronized(lock) {
            val entry = entries[key]
            if (entry == null) {
                result = false
            } else if (nowMs - entry.updatedAtEpochMs > ttlMs) {
                entries.remove(key)
                snapshotToPersist = entries.toMap()
                result = false
            } else {
                result = entry.features.contains(feature)
            }
        }
        snapshotToPersist?.let { persist(it) }
        return result
    }

    fun markUnsupported(
        features: Set<GatewayUnsupportedFeature>,
        protocolType: APIProtocolType,
        baseURL: String,
        modelID: String,
        nowMs: Long = System.currentTimeMillis()
    ) {
        if (features.isEmpty()) return
        val key = cacheKey(protocolType, baseURL, modelID)
        val snapshotToPersist: Map<String, Entry>
        synchronized(lock) {
            val merged = (entries[key]?.features ?: emptySet()) + features
            entries[key] = Entry(features = merged, updatedAtEpochMs = nowMs)
            if (entries.size > maxEntries) {
                val oldestKeys = entries.entries.sortedBy { it.value.updatedAtEpochMs }
                    .take(entries.size - maxEntries)
                    .map { it.key }
                for (k in oldestKeys) entries.remove(k)
            }
            snapshotToPersist = entries.toMap()
        }
        persist(snapshotToPersist)
    }

    fun clearAll() {
        synchronized(lock) {
            entries.clear()
        }
        backingStore.saveRaw(null)
    }

    private fun persist(snapshot: Map<String, Entry>) {
        if (snapshot.isEmpty()) {
            backingStore.saveRaw(null)
            return
        }
        runCatching { json.encodeToString(snapshot) }.getOrNull()?.let { backingStore.saveRaw(it) }
    }

    companion object {
        fun cacheKey(protocolType: APIProtocolType, baseURL: String, modelID: String): String {
            val cleanURL = baseURL.trim().trimEnd('/')
            val cleanModel = modelID.trim().lowercase()
            val raw = "${protocolType.rawValue}|$cleanURL|$cleanModel"
            val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { "%02x".format(it) }
        }
    }
}
