package com.iosbox.app.core.storage

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(tableName = "providers")
data class ProviderEntity(
    @PrimaryKey val id: String,
    val name: String,
    val protocolRaw: String,
    val baseURL: String,
    val iconSymbol: String,
    val accentHex: String,
    val isEnabled: Boolean,
    val sortOrder: Int,
    val modelsJson: String,
    val headersJson: String,
    val notes: String,
    val createdAtEpochMs: Long,
    val updatedAtEpochMs: Long
)

@Entity(tableName = "assistant_presets")
data class AssistantPresetEntity(
    @PrimaryKey val id: String,
    val name: String,
    val iconEmoji: String,
    val subtitle: String,
    val systemPrompt: String,
    val temperature: Double,
    val useCustomTemperature: Boolean,
    val topP: Double,
    val maxOutputTokens: Int,
    val contextMessageLimit: Int,
    val enableThinking: Boolean,
    val thinkingBudgetTokens: Int,
    val isBuiltIn: Boolean,
    val sortOrder: Int,
    val knowledgeVolumeIDsJson: String?,
    val createdAtEpochMs: Long
)

@Entity(tableName = "conversations")
data class ConversationEntity(
    @PrimaryKey val id: String,
    val title: String,
    val isPinned: Boolean,
    val assistantID: String?,
    val assistantEmoji: String,
    val systemPrompt: String,
    val temperature: Double,
    val useCustomTemperature: Boolean,
    val topP: Double,
    val maxOutputTokens: Int,
    val contextMessageLimit: Int,
    val enableThinking: Boolean,
    val thinkingBudgetTokens: Int,
    val isArenaMode: Boolean,
    val primaryTargetJson: String,
    val arenaTargetsJson: String,
    val assistanceSettingsBlobKey: String?,
    val activeLeafMessageID: String?,
    val folderTag: String?,
    val organizationEditsJson: String?,
    val legacyImportID: String?,
    val createdAtEpochMs: Long,
    val updatedAtEpochMs: Long
)

@Entity(
    tableName = "chat_messages",
    foreignKeys = [
        ForeignKey(
            entity = ConversationEntity::class,
            parentColumns = ["id"],
            childColumns = ["conversationID"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["conversationID"]),
        Index(value = ["conversationID", "sortIndex"])
    ]
)
data class ChatMessageEntity(
    @PrimaryKey val id: String,
    val conversationID: String,
    val roleRaw: String,
    val content: String,
    val reasoningContent: String,
    val attachmentsBlobKey: String?,
    val providerID: String?,
    val providerName: String,
    val modelID: String,
    val modelDisplayName: String,
    val accentHex: String,
    val comparisonGroupID: String?,
    val isSelectedInGroup: Boolean,
    val isStreaming: Boolean,
    val errorMessage: String?,
    val finishReason: String?,
    val promptTokens: Int?,
    val completionTokens: Int?,
    val cachedTokens: Int?,
    val latencyMs: Int?,
    val thinkingDurationMs: Int?,
    val synthesisSourceDigest: String?,
    val latestRequestID: String?,
    val assistanceMetadataBlobKey: String?,
    val parentMessageID: String?,
    val sortIndex: Int,
    val createdAtEpochMs: Long
)

@Entity(
    tableName = "request_records",
    indices = [
        Index(value = ["startedAtEpochMs"]),
        Index(value = ["providerID", "modelID"])
    ]
)
data class RequestRecordEntity(
    @PrimaryKey val id: String,
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
    val startedAtEpochMs: Long,
    val endedAtEpochMs: Long?,
    val firstReasoningMs: Int?,
    val firstContentMs: Int?,
    val lastOutputMs: Int?,
    val durationMs: Int?,
    val outputChunkCount: Int,
    val isStreamed: Boolean,
    val promptTokens: Int?,
    val completionTokens: Int?,
    val cachedTokens: Int?,
    val cacheWriteTokens: Int?,
    val httpStatus: Int?,
    val inputPricePerMillion: Double?,
    val outputPricePerMillion: Double?,
    val cacheReadPricePerMillion: Double?,
    val cacheWritePricePerMillion: Double?,
    val currency: String?
)

@Entity(tableName = "personal_memories")
data class PersonalMemoryEntity(
    @PrimaryKey val id: String,
    val content: String,
    val isEnabled: Boolean,
    val createdAtEpochMs: Long
)

@Entity(tableName = "book_volumes")
data class BookVolumeEntity(
    @PrimaryKey val id: String,
    val title: String,
    val chapterTitlesJson: String,
    val manuscriptBlobKey: String,
    val byteCount: Long,
    val importedAtEpochMs: Long
)

@Entity(tableName = "persona_profiles")
data class PersonaProfileEntity(
    @PrimaryKey val id: String,
    val payloadBlobKey: String,
    val updatedAtEpochMs: Long
)

@Entity(tableName = "shelf_reading_states")
data class ShelfReadingStateEntity(
    @PrimaryKey val bookID: String,
    val conversationID: String?,
    val chapter: Int,
    val paragraph: Int
)
