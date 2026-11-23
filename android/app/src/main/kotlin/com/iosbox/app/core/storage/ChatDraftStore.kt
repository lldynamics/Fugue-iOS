package com.iosbox.app.core.storage

import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.PickedGroupMention
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

@Serializable
data class ChatDraft(
    val text: String = "",
    val attachments: List<MessageAttachment> = emptyList(),
    val quotedExcerpt: String? = null,
    val pickedMentions: List<PickedGroupMention> = emptyList()
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
    private val currentDirectory = File(directory, "v2")
    private var migrated = false
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = false
    }

    internal fun draftFile(conversationId: String): File =
        File(currentDirectory, "${stableKey(conversationId)}.json")

    fun migrateLegacy(conversationIDs: List<String>) = synchronized(lock) {
        if (migrated) return@synchronized
        val owners = conversationIDs.distinct().groupBy(::safeFileName)
        val files = if (directory.exists()) {
            directory.listFiles() ?: throw java.io.IOException("Cannot list legacy drafts")
        } else emptyArray()
        for (file in files) {
            val name = file.nameWithoutExtension
            if (!file.isFile || Files.isSymbolicLink(file.toPath()) || file.extension != "json" ||
                name.isEmpty() || name.length > 128 || SAFE_ID_CHARS.containsMatchIn(name)) continue
            val owner = owners[name]?.singleOrNull()
            val target = owner?.let(::draftFile)
            if (target != null && !target.exists()) {
                currentDirectory.mkdirs()
                moveReplacing(file, target)
            } else {
                val recovery = File(directory, "recovery")
                recovery.mkdirs()
                moveReplacing(file, File(recovery, "${file.nameWithoutExtension}-${UUID.randomUUID()}.json"))
            }
        }
        migrated = true
    }

    fun load(conversationId: String): ChatDraft = synchronized(lock) {
        val target = draftFile(conversationId)
        if (!target.exists() || !target.isFile) return@synchronized ChatDraft()
        return@synchronized try {
            json.decodeFromString<ChatDraft>(target.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            quarantineCorruptFile(target, target.nameWithoutExtension)
            ChatDraft()
        }
    }

    fun save(conversationId: String, draft: ChatDraft): Unit = synchronized(lock) {
        val target = draftFile(conversationId)
        val tmp = File(currentDirectory, "${target.name}.tmp")
        if (draft.isEmpty) {
            target.delete()
            tmp.delete()
            return@synchronized
        }
        if (!currentDirectory.exists()) currentDirectory.mkdirs()
        val payload = json.encodeToString(draft)
        tmp.writeText(payload, Charsets.UTF_8)
        moveReplacing(tmp, target)
    }

    fun remove(conversationId: String): Unit = synchronized(lock) {
        val target = draftFile(conversationId)
        target.delete()
        File(currentDirectory, "${target.name}.tmp").delete()
    }

    private fun quarantineCorruptFile(corruptFile: File, safeName: String) {
        val stamp = System.currentTimeMillis() / 1000L
        var archived = File(currentDirectory, "$safeName.corrupt-$stamp.json")
        if (archived.exists()) {
            archived = File(currentDirectory, "$safeName.corrupt-$stamp-${System.nanoTime()}.json")
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

        private fun stableKey(id: String): String =
            MessageDigest.getInstance("SHA-256").digest(id.uppercase().toByteArray(Charsets.UTF_8))
                .joinToString("") { "%02x".format(it) }

        fun safeFileName(conversationId: String): String =
            conversationId
                .trim()
                .uppercase()
                .replace(SAFE_ID_CHARS, "_")
                .take(128)
                .ifEmpty { "DEFAULT" }
    }
}
