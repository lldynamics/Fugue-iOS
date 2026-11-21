package com.iosbox.app.core.network

import com.iosbox.app.core.model.APIProtocolType
import java.security.MessageDigest
import kotlin.math.roundToLong

/**
 * Distributes traffic across a provider's API key pool via Round-Robin and temporarily
 * cools down keys that hit rate-limit (429) or auth/quota errors (401/402/403).
 */
class APIKeyPoolRouter(
    private val clockNanos: () -> Long = { System.nanoTime() }
) {
    private val lock = Any()
    private val cursors = HashMap<String, Int>()
    private val cooldowns = HashMap<String, Long>()

    fun orderedKeys(
        rawKeys: List<String>,
        protocolType: APIProtocolType,
        baseURL: String,
        nowNanos: Long = clockNanos()
    ): List<String> {
        val unique = mutableListOf<String>()
        val seen = HashSet<String>()
        for (raw in rawKeys) {
            val trimmed = raw.trim()
            if (trimmed.isNotEmpty() && seen.add(trimmed)) {
                unique.add(trimmed)
            }
        }
        if (unique.isEmpty()) return listOf("")
        if (unique.size == 1) return unique

        val poolID = poolHash(protocolType, baseURL)
        val healthy = mutableListOf<String>()
        val cooling = mutableListOf<Pair<String, Long>>()

        synchronized(lock) {
            val start = (cursors[poolID] ?: 0) % unique.size
            cursors[poolID] = (start + 1) % unique.size

            val rotated = List(unique.size) { offset -> unique[(start + offset) % unique.size] }
            for (key in rotated) {
                val kHash = keyHash(poolID, key)
                val until = cooldowns[kHash]
                if (until != null) {
                    if (nowNanos < until) {
                        cooling.add(key to until)
                    } else {
                        cooldowns.remove(kHash)
                        healthy.add(key)
                    }
                } else {
                    healthy.add(key)
                }
            }
        }

        cooling.sortBy { it.second }
        return healthy + cooling.map { it.first }
    }

    fun markUnhealthy(
        key: String,
        protocolType: APIProtocolType,
        baseURL: String,
        statusCode: Int,
        retryAfterSeconds: Double? = null,
        nowNanos: Long = clockNanos()
    ) {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) return
        val poolID = poolHash(protocolType, baseURL)
        val kHash = keyHash(poolID, trimmed)
        val cooldownSec = if (statusCode == 429) {
            (retryAfterSeconds ?: 30.0).coerceIn(5.0, 600.0)
        } else {
            300.0
        }
        val durationNanos = (cooldownSec * 1_000_000_000.0).roundToLong()
        synchronized(lock) {
            cooldowns[kHash] = nowNanos + durationNanos
        }
    }

    fun markHealthy(
        key: String,
        protocolType: APIProtocolType,
        baseURL: String
    ) {
        val trimmed = key.trim()
        if (trimmed.isEmpty()) return
        val poolID = poolHash(protocolType, baseURL)
        val kHash = keyHash(poolID, trimmed)
        synchronized(lock) {
            cooldowns.remove(kHash)
        }
    }

    fun resetAll() {
        synchronized(lock) {
            cursors.clear()
            cooldowns.clear()
        }
    }

    companion object {
        private fun poolHash(protocolType: APIProtocolType, baseURL: String): String {
            val clean = baseURL.trim().trimEnd('/')
            return sha256Prefix16("${protocolType.rawValue}|$clean")
        }

        private fun keyHash(poolID: String, key: String): String =
            sha256Prefix16("$poolID|$key")

        private fun sha256Prefix16(input: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
            return digest.take(16).joinToString("") { "%02x".format(it) }
        }
    }
}
