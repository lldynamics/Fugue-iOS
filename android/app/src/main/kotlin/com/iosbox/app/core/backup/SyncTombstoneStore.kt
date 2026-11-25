package com.iosbox.app.core.backup

import com.iosbox.app.core.storage.ExternalBlobStore
import kotlinx.serialization.Serializable

object SyncEntityKinds {
    const val CONVERSATION = "conversation"
    const val MEMORY = "memory"
    const val BOOK = "book"
    const val FLASHCARD = "flashcard"
    const val PRESET = "preset"
    const val PERSONA_PROFILE = "personaProfile"
    const val PROVIDER = "provider"
}

data class SyncTombstoneKey(
    val kind: String,
    val id: String
) {
    val canonical: SyncTombstoneKey
        get() = SyncTombstoneKey(kind, id.uppercase())
}

@Serializable
data class SyncTombstone(
    val kind: String,
    val id: String,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val deletedAt: Long
) {
    val key: SyncTombstoneKey
        get() = SyncTombstoneKey(kind, id.uppercase())
}

sealed interface SyncTombstonePolicy {
    data object Ignore : SyncTombstonePolicy
    data class Enforce(val store: SyncTombstoneStore) : SyncTombstonePolicy
}

/**
 * Byte-compatible with iOS `SyncTombstoneStore.swift`.
 * Persists entity deletion tombstones in `ExternalBlobStore` (or memory for unit tests)
 * without altering Room database schemas.
 */
class SyncTombstoneStore(
    private val blobStore: ExternalBlobStore? = null
) {
    companion object {
        const val BLOB_KEY = "sync-tombstones.json"
        const val RETENTION_MS: Long = 180L * 24L * 3600L * 1000L
        const val MAXIMUM_ENTRIES: Int = 10_000
    }

    private val lock = Any()
    private var inMemory: MutableMap<SyncTombstoneKey, Long> = HashMap()

    fun recordDeletion(kind: String, id: String, deletedAtMs: Long = System.currentTimeMillis()) {
        recordDeletions(kind, listOf(id), deletedAtMs)
    }

    fun recordDeletions(kind: String, ids: List<String>, deletedAtMs: Long = System.currentTimeMillis()) {
        if (ids.isEmpty()) return
        synchronized(lock) {
            val map = loadLocked(deletedAtMs)
            var mutated = false
            for (raw in ids) {
                val clean = raw.trim().uppercase()
                if (clean.isEmpty()) continue
                val key = SyncTombstoneKey(kind, clean)
                val existing = map[key]
                if (existing != null && existing >= deletedAtMs) continue
                map[key] = deletedAtMs
                mutated = true
            }
            if (mutated) {
                pruneLocked(map, deletedAtMs)
                persistLocked(map)
            }
        }
    }

    fun removeTombstone(kind: String, id: String) {
        removeTombstones(listOf(kind to id))
    }

    fun removeTombstones(items: List<Pair<String, String>>) {
        if (items.isEmpty()) return
        synchronized(lock) {
            val map = loadLocked(System.currentTimeMillis())
            var mutated = false
            for ((kind, id) in items) {
                if (map.remove(SyncTombstoneKey(kind, id.trim().uppercase())) != null) {
                    mutated = true
                }
            }
            if (mutated) persistLocked(map)
        }
    }

    fun latestDeletion(kind: String, id: String, nowMs: Long = System.currentTimeMillis()): Long? =
        synchronized(lock) {
            loadLocked(nowMs)[SyncTombstoneKey(kind, id.trim().uppercase())]
        }

    fun tombstoneMap(nowMs: Long = System.currentTimeMillis()): Map<SyncTombstoneKey, Long> =
        synchronized(lock) {
            HashMap(loadLocked(nowMs))
        }

    fun allTombstones(nowMs: Long = System.currentTimeMillis()): List<SyncTombstone> =
        sortedList(tombstoneMap(nowMs))

    fun count(nowMs: Long = System.currentTimeMillis()): Int =
        tombstoneMap(nowMs).size

    fun merge(
        incoming: List<SyncTombstone>,
        removing: List<SyncTombstoneKey> = emptyList(),
        nowMs: Long = System.currentTimeMillis()
    ): List<SyncTombstone> = synchronized(lock) {
        val map = loadLocked(nowMs)
        val cutoff = nowMs - RETENTION_MS
        var mutated = false
        for (item in incoming) {
            if (item.deletedAt < cutoff) continue
            val key = item.key
            val existing = map[key]
            if (existing != null && existing >= item.deletedAt) continue
            map[key] = item.deletedAt
            mutated = true
        }
        for (cleared in removing) {
            if (map.remove(cleared.canonical) != null) {
                mutated = true
            }
        }
        val pruned = pruneLocked(map, nowMs)
        if (mutated || pruned) persistLocked(map)
        sortedList(map)
    }

    fun clearAll() {
        synchronized(lock) {
            inMemory.clear()
            blobStore?.delete(BLOB_KEY)
        }
    }

    private fun loadLocked(nowMs: Long): MutableMap<SyncTombstoneKey, Long> {
        val map = HashMap<SyncTombstoneKey, Long>()
        if (blobStore != null) {
            val raw = blobStore.readText(BLOB_KEY)
            if (!raw.isNullOrBlank()) {
                val decoded = runCatching {
                    BackupJson.codec.decodeFromString<List<SyncTombstone>>(raw)
                }.getOrDefault(emptyList())
                for (item in decoded) {
                    val key = item.key
                    val prev = map[key]
                    if (prev == null || item.deletedAt > prev) {
                        map[key] = item.deletedAt
                    }
                }
            }
        } else {
            map.putAll(inMemory)
        }
        pruneLocked(map, nowMs)
        return map
    }

    private fun pruneLocked(map: MutableMap<SyncTombstoneKey, Long>, nowMs: Long): Boolean {
        val before = map.size
        val cutoff = nowMs - RETENTION_MS
        val iter = map.entries.iterator()
        while (iter.hasNext()) {
            if (iter.next().value < cutoff) iter.remove()
        }
        if (map.size > MAXIMUM_ENTRIES) {
            val kept = sortedList(map).take(MAXIMUM_ENTRIES)
            map.clear()
            for (item in kept) map[item.key] = item.deletedAt
        }
        return map.size != before
    }

    private fun persistLocked(map: Map<SyncTombstoneKey, Long>) {
        if (blobStore != null) {
            val list = sortedList(map)
            val encoded = BackupJson.codec.encodeToString(
                kotlinx.serialization.builtins.ListSerializer(SyncTombstone.serializer()),
                list
            )
            blobStore.writeText(BLOB_KEY, encoded)
        } else {
            inMemory = HashMap(map)
        }
    }

    private fun sortedList(map: Map<SyncTombstoneKey, Long>): List<SyncTombstone> =
        map.entries.map { (k, v) -> SyncTombstone(kind = k.kind, id = k.id, deletedAt = v) }
            .sortedWith(
                compareByDescending<SyncTombstone> { it.deletedAt }
                    .thenBy { it.kind }
                    .thenBy { it.id }
            )
}
