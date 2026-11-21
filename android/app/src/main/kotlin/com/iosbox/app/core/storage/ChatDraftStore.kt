package com.iosbox.app.core.storage

import com.iosbox.app.core.model.MessageAttachment
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

@Serializable
data class ChatDraft(
    val text: String = "",
    val attachments: List<MessageAttachment> = emptyList(),
    val quotedExcerpt: String? = null
) {
    val isEmpty: Boolean
        get() = text.isEmpty() && attachments.isEmpty() && quotedExcerpt.isNullOrEmpty()
}

/**
 * Stores unsent per-conversation composer drafts atomically inside app-private files (`drafts/`),
 * mirroring iOS `ChatDraftStore` with corrupt-file quarantine so damaged drafts never block chat.
 */
class ChatDraftStore(private val directory: File) {
    private val lock = Any()
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    internal fun draftFile(conversationId: String): File =
        File(directory, "${safeFileName(conversationId)}.json")

    fun load(conversationId: String): ChatDraft = synchronized(lock) {
        val target = draftFile(conversationId)
        if (!target.exists() || !target.isFile) return@synchronized ChatDraft()
        return@synchronized try {
            json.decodeFromString<ChatDraft>(target.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            quarantineCorruptFile(target, safeFileName(conversationId))
            ChatDraft()
        }
    }

    fun save(conversationId: String, draft: ChatDraft): Unit = synchronized(lock) {
        val safeName = safeFileName(conversationId)
        val target = File(directory, "$safeName.json")
        val tmp = File(directory, "$safeName.json.tmp")
        if (draft.isEmpty) {
            target.delete()
            tmp.delete()
            return@synchronized
        }
        if (!directory.exists()) {
            directory.mkdirs()
        }
        val payload = json.encodeToString(draft)
        tmp.writeText(payload, Charsets.UTF_8)
        moveReplacing(tmp, target)
    }

    fun remove(conversationId: String): Unit = synchronized(lock) {
        val safeName = safeFileName(conversationId)
        File(directory, "$safeName.json").delete()
        File(directory, "$safeName.json.tmp").delete()
    }

    private fun quarantineCorruptFile(corruptFile: File, safeName: String) {
        val stamp = System.currentTimeMillis() / 1000L
        var archived = File(directory, "$safeName.corrupt-$stamp.json")
        if (archived.exists()) {
            archived = File(directory, "$safeName.corrupt-$stamp-${System.nanoTime()}.json")
        }
        val moved = runCatching {
            Files.move(corruptFile.toPath(), archived.toPath(), StandardCopyOption.REPLACE_EXISTING)
            true
        }.getOrDefault(false)
        if (!moved) {
            corruptFile.delete()
        }
    }

    private fun moveReplacing(source: File, target: File) {
        try {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE
            )
        } catch (_: Exception) {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    companion object {
        private val SAFE_ID_CHARS = Regex("[^A-Z0-9_-]")

        fun safeFileName(conversationId: String): String =
            conversationId
                .trim()
                .uppercase()
                .replace(SAFE_ID_CHARS, "_")
                .take(128)
                .ifEmpty { "DEFAULT" }
    }
}
