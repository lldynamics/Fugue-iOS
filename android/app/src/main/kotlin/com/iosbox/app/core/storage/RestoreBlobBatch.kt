package com.iosbox.app.core.storage

import java.util.UUID

/** Restore blobs use fresh keys. A committed Room reference is their publication marker. */
internal class RestoreBlobBatch(private val store: ExternalBlobStore) {
    private val id = UUID.randomUUID().toString()
    private var next = 0

    fun writeText(text: String): String {
        val key = "restore_${id}_${next++}.json"
        store.writeText(key, text)
        return key
    }

    companion object {
        private val RESTORE_KEY = Regex("restore_[0-9a-f-]{36}_[0-9]+\\.json(?:\\.tmp)?")

        fun owns(key: String): Boolean = RESTORE_KEY.matches(key)

        fun reconcile(store: ExternalBlobStore, committedKeys: Set<String>) {
            for (key in store.keys()) {
                if (owns(key) && key !in committedKeys) store.delete(key)
            }
        }
    }
}
