package com.iosbox.app.core.backup

import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.ResolvedModelTarget
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

object Iso8601EpochMillisSerializer : KSerializer<Long> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("Iso8601EpochMillis", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Long) {
        // Swift's JSONDecoder.DateDecodingStrategy.iso8601 expects whole-second UTC ISO-8601 (`Z`).
        val instant = Instant.ofEpochMilli(value).truncatedTo(ChronoUnit.SECONDS)
        encoder.encodeString(DateTimeFormatter.ISO_INSTANT.format(instant))
    }

    override fun deserialize(decoder: Decoder): Long {
        val raw = decoder.decodeString().trim()
        return runCatching { Instant.parse(raw).toEpochMilli() }.getOrElse {
            runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrElse {
                0L
            }
        }
    }
}

object BackupJson {
    val codec: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }

    val prettyCodec: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
        prettyPrint = true
    }
}

@Serializable
data class BackupArchive(
    val formatVersion: Int = CURRENT_FORMAT_VERSION,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val exportedAt: Long,
    val appVersion: String = "",
    val providers: List<ProviderBackup> = emptyList(),
    val presets: List<PresetBackup> = emptyList(),
    val conversations: List<ConversationBackup> = emptyList(),
    val requests: List<RequestRecordSnapshot>? = null,
    val memories: List<PersonalMemorySnapshot>? = null,
    val books: List<BookVolumeSnapshot>? = null,
    val flashcards: List<JsonElement>? = null,
    val personaProfiles: List<JsonElement>? = null,
    val shelfPositions: List<ShelfPositionSnapshot>? = null
) {
    companion object {
        const val CURRENT_FORMAT_VERSION = 7
    }
}

@Serializable
data class ProviderBackup(
    val id: String,
    val name: String,
    val protocolRaw: String,
    val baseURL: String,
    val iconSymbol: String = "server.rack",
    val accentHex: String = "#3F6EF6",
    val isEnabled: Boolean = true,
    val sortOrder: Int = 0,
    val models: List<ModelSpec> = emptyList(),
    val customHeaders: List<CustomHeader> = emptyList(),
    val notes: String = ""
)

@Serializable
data class PresetBackup(
    val id: String,
    val name: String,
    val iconEmoji: String = "🤖",
    val subtitle: String = "",
    val systemPrompt: String = "",
    val temperature: Double = 0.7,
    val useCustomTemperature: Boolean = true,
    val topP: Double = 1.0,
    val maxOutputTokens: Int = 0,
    val contextMessageLimit: Int = 20,
    val enableThinking: Boolean = true,
    val thinkingBudgetTokens: Int = 4096,
    val isBuiltIn: Boolean = false,
    val sortOrder: Int = 0,
    val knowledgeVolumeIDs: List<String>? = null
)

@Serializable
data class ConversationBackup(
    val id: String,
    val title: String,
    val isPinned: Boolean = false,
    val assistantID: String? = null,
    val assistantEmoji: String = "✨",
    val systemPrompt: String = "",
    val temperature: Double = 0.7,
    val useCustomTemperature: Boolean = true,
    val topP: Double = 1.0,
    val maxOutputTokens: Int = 0,
    val contextMessageLimit: Int = 20,
    val enableThinking: Boolean = true,
    val thinkingBudgetTokens: Int = 4096,
    val isArenaMode: Boolean = false,
    val primaryTarget: ResolvedModelTarget? = null,
    val arenaTargets: List<ResolvedModelTarget> = emptyList(),
    val assistanceSettings: JsonElement? = null,
    val activeLeafMessageID: String? = null,
    val folderTag: String? = null,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val createdAt: Long,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val updatedAt: Long,
    val messages: List<MessageBackup> = emptyList(),
    val organizationEdits: JsonElement? = null,
    val legacyImportID: String? = null
)

@Serializable
data class MessageBackup(
    val id: String,
    val role: String,
    val content: String = "",
    val reasoningContent: String = "",
    val attachments: List<MessageAttachment> = emptyList(),
    val providerID: String? = null,
    val providerName: String = "",
    val modelID: String = "",
    val modelDisplayName: String = "",
    val accentHex: String = "#3F6EF6",
    val comparisonGroupID: String? = null,
    val isSelectedInGroup: Boolean = true,
    val errorMessage: String? = null,
    val finishReason: String? = null,
    val promptTokens: Int? = null,
    val completionTokens: Int? = null,
    val cachedTokens: Int? = null,
    val latencyMs: Int? = null,
    val thinkingDurationMs: Int? = null,
    val synthesisSourceDigest: String? = null,
    val latestRequestID: String? = null,
    val assistanceMetadata: JsonElement? = null,
    val parentMessageID: String? = null,
    val sortIndex: Int = 0,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val createdAt: Long
)

@Serializable
data class RequestRecordSnapshot(
    val id: String,
    val operationID: String,
    val attempt: Int,
    val conversationID: String,
    val messageID: String,
    val providerID: String,
    val providerName: String,
    val modelID: String,
    val modelDisplayName: String,
    val protocolRaw: String,
    val kindRaw: String,
    val statusRaw: String,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val startedAt: Long,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val endedAt: Long? = null,
    val firstReasoningMs: Int? = null,
    val firstContentMs: Int? = null,
    val lastOutputMs: Int? = null,
    val durationMs: Int? = null,
    val outputChunkCount: Int = 0,
    val isStreamed: Boolean = true,
    val promptTokens: Int? = null,
    val completionTokens: Int? = null,
    val cachedTokens: Int? = null,
    val cacheWriteTokens: Int? = null,
    val httpStatus: Int? = null,
    val inputPricePerMillion: Double? = null,
    val outputPricePerMillion: Double? = null,
    val cacheReadPricePerMillion: Double? = null,
    val cacheWritePricePerMillion: Double? = null,
    val currency: String? = null
)

@Serializable
data class PersonalMemorySnapshot(
    val id: String,
    val content: String,
    val isEnabled: Boolean,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val createdAt: Long
)

@Serializable
data class BookChapterSnapshot(
    val title: String,
    val text: String
)

@Serializable
data class BookVolumeSnapshot(
    val id: String,
    val title: String,
    val chapters: List<BookChapterSnapshot> = emptyList(),
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val importedAt: Long
)

@Serializable
data class ShelfPositionSnapshot(
    val bookID: String,
    val conversationID: String? = null,
    val chapter: Int = 0,
    val paragraph: Int = 0
)

@Serializable
data class EncryptedBackupEnvelope(
    val magic: String,
    val iterations: Int,
    val saltBase64: String,
    val combinedCiphertextBase64: String
)

@Serializable
data class ProviderSecretBundle(
    val providerID: String,
    val rawBaseURL: String,
    val isEnabled: Boolean,
    val apiKey: String,
    val extraAPIKeys: List<String>? = null,
    val idleTimeoutSeconds: Int? = null,
    val secretHeaders: Map<String, String> = emptyMap()
)

@Serializable
data class FullEncryptedPayload(
    val archive: BackupArchive,
    val providerSecrets: List<ProviderSecretBundle> = emptyList(),
    val tavilyAPIKey: String = "",
    val personaXBearerToken: String? = null
)

sealed class BackupException(override val message: String) : Exception(message) {
    class ImportMemoryLimit(maximumBytes: Int) : BackupException(
        L10n.text("此设备可安全导入的备份上限为 ${maximumBytes / (1024 * 1024)} MB。",
            "This device can safely import backups up to ${maximumBytes / (1024 * 1024)} MB.")
    )

    class ConversationMessageLimit : BackupException(
        L10n.text("单个对话超过 50,000 条消息的导入上限。", "A conversation exceeds the 50,000-message import limit.")
    )

    class UnrecognizedFormat : BackupException(
        L10n.text(
            "无法识别该文件，请选择由「夜奔 / Fugue」导出的 JSON 备份。",
            "Unrecognized backup file. Please choose a Fugue JSON backup."
        )
    )

    class NewerFormat(version: Int) : BackupException(
        L10n.text(
            "该备份来自更新版本的「夜奔」（格式 v$version），请先升级 App 再导入。",
            "This backup comes from a newer version of Fugue (format v$version). Update the app first."
        )
    )

    class ConflictingIDs : BackupException(
        L10n.text("备份包含冲突的标识，未导入任何数据。", "Backup contains conflicting IDs. Nothing was imported.")
    )

    class FileTooLarge : BackupException(
        L10n.text("备份文件超过 256 MiB 上限。", "Backup file exceeds the 256 MiB limit.")
    )

    class EmptyPassword : BackupException(
        L10n.text("请设置至少 8 位字符的备份密码。", "Set a backup password of at least 8 characters.")
    )

    class WrongPasswordOrCorrupted : BackupException(
        L10n.text("备份密码不正确，或加密备份文件已损坏。", "Incorrect backup password, or the encrypted file is corrupted.")
    )

    class InvalidEnvelope : BackupException(
        L10n.text("无法识别该加密备份文件。", "Unrecognized encrypted backup envelope.")
    )
}

data class ImportSummary(
    val providers: Int = 0,
    val presets: Int = 0,
    val conversations: Int = 0,
    val messages: Int = 0,
    val restoredConversations: Int = 0,
    val requests: Int = 0,
    val memories: Int = 0,
    val books: Int = 0,
    val flashcards: Int = 0,
    val skipped: Int = 0,
    val confirmedCredentials: Int = 0,
    val failedCredentialWrites: Int = 0,
    val credentialConflicts: List<String> = emptyList(),
    val flashcardRestoreFailed: Boolean = false
) {
    val hasWarnings: Boolean
        get() = credentialConflicts.isNotEmpty() || failedCredentialWrites > 0 || flashcardRestoreFailed

    val title: String
        get() = if (hasWarnings) {
            L10n.text("备份需继续处理", "Backup Imported with Warnings")
        } else {
            L10n.text("导入完成", "Import Complete")
        }

    val description: String
        get() {
            val parts = mutableListOf<String>()
            if (restoredConversations > 0) parts.add(L10n.text("已恢复 $restoredConversations 个原对话", "$restoredConversations restored chats"))
            if (conversations > 0) parts.add(L10n.text("新建对话 $conversations 个", "$conversations new chats"))
            if (messages > 0) parts.add(L10n.text("消息 $messages 条", "$messages messages"))
            if (providers > 0) parts.add(L10n.text("服务商 $providers 个", "$providers providers"))
            if (presets > 0) parts.add(L10n.text("助手 $presets 个", "$presets presets"))
            if (requests > 0) parts.add(L10n.text("请求记录 $requests 条", "$requests requests"))
            if (books > 0) parts.add(L10n.text("书籍 $books 本", "$books books"))
            if (memories > 0) parts.add(L10n.text("记忆 $memories 条", "$memories memories"))
            if (skipped > 0) parts.add(L10n.text("跳过已存在的 $skipped 项", "$skipped existing items skipped"))

            val lines = mutableListOf<String>()
            if (parts.isNotEmpty()) {
                val sep = L10n.text("，", ", ")
                lines.add(L10n.text("已导入：${parts.joinToString(sep)}。", "Imported: ${parts.joinToString(sep)}."))
            }
            if (providers > 0) {
                lines.add(L10n.text(
                    "请在服务商设置中核对导入的连接地址，再启用服务商。",
                    "Review each imported endpoint in Providers before enabling it."
                ))
            }
            if (flashcardRestoreFailed) {
                lines.add(L10n.text("闪卡未能保存。请检查闪卡库和设备存储，再重新导入备份。",
                    "Flashcards could not be saved. Check the flashcard library and device storage, then retry the import."))
            }
            if (confirmedCredentials > 0) {
                lines.add(
                    L10n.text(
                        "已确认 $confirmedCredentials 项凭据保存在安全密钥库中。",
                        "Confirmed $confirmedCredentials credentials in secure storage."
                    )
                )
            }
            if (credentialConflicts.isNotEmpty()) {
                val names = credentialConflicts.joinToString(L10n.text("，", ", "))
                lines.add(
                    L10n.text(
                        "以下服务商的连接或请求头与备份不一致，请在服务商设置中核对并重新填写凭据：$names。",
                        "Provider settings differed for: $names. Check endpoints and re-enter credentials."
                    )
                )
            }
            if (failedCredentialWrites > 0) {
                lines.add(
                    L10n.text(
                        "有 $failedCredentialWrites 项凭据未能存入安全存储，请重试。",
                        "$failedCredentialWrites credentials could not be saved."
                    )
                )
            }
            return if (lines.isEmpty()) {
                L10n.text("备份中没有需要导入的内容。", "Nothing new to import from this backup.")
            } else {
                lines.joinToString("\n")
            }
        }
}
