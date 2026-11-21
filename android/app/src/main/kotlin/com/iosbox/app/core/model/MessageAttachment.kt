package com.iosbox.app.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.Locale
import java.util.UUID

@Serializable
enum class MessageRole(val rawValue: String) {
    @SerialName("system")
    SYSTEM("system"),

    @SerialName("user")
    USER("user"),

    @SerialName("assistant")
    ASSISTANT("assistant"),

    @SerialName("tool")
    TOOL("tool");

    companion object {
        fun fromRaw(raw: String): MessageRole =
            entries.firstOrNull { it.rawValue == raw } ?: USER
    }
}

@Serializable
enum class AttachmentKind(val rawValue: String) {
    @SerialName("image")
    IMAGE("image"),

    @SerialName("document")
    DOCUMENT("document")
}

@Serializable
data class MessageAttachment(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val kind: AttachmentKind,
    val fileName: String,
    val mimeType: String,
    val dataBase64: String? = null,
    val extractedText: String? = null,
    val byteSize: Int
) {
    val formattedSize: String
        get() = formatByteCount(byteSize.toLong())

    companion object {
        fun formatByteCount(bytes: Long): String {
            if (bytes < 1000) return "$bytes B"
            val kb = bytes / 1000.0
            if (kb < 1000) return String.format(Locale.US, "%.1f KB", kb)
            val mb = kb / 1000.0
            if (mb < 1000) return String.format(Locale.US, "%.1f MB", mb)
            val gb = mb / 1000.0
            return String.format(Locale.US, "%.1f GB", gb)
        }
    }
}
