package com.iosbox.app.core.storage

import androidx.room.withTransaction
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookFriend
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.ConversationAssistanceSettings
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.GroupMember
import com.iosbox.app.core.model.GroupSpeakingMode
import com.iosbox.app.core.model.GroupSpeechStyle
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.PersonalMemoryPrompt
import com.iosbox.app.core.model.PreparedBook
import com.iosbox.app.core.model.RequestKind
import com.iosbox.app.core.model.RequestMetrics
import com.iosbox.app.core.model.RequestStatus
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.network.ArenaSynthesis
import com.iosbox.app.core.network.EndpointResolver
import com.iosbox.app.core.network.LLMFinishReason
import com.iosbox.app.core.network.LLMPromptMessage
import com.iosbox.app.core.network.NetworkLocation
import com.iosbox.app.core.security.SecretStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import java.util.UUID

data class ProviderItem(
    val id: String,
    val name: String,
    val protocolType: APIProtocolType,
    val baseURL: String,
    val iconSymbol: String,
    val accentHex: String,
    val isEnabled: Boolean,
    val sortOrder: Int,
    val models: List<ModelSpec>,
    val customHeaders: List<CustomHeader>,
    val notes: String,
    val createdAtEpochMs: Long,
    val updatedAtEpochMs: Long,
    val hasAuthentication: Boolean,
    val idleTimeoutSeconds: Int
) {
    val enabledModels: List<ModelSpec>
        get() = models.filter { it.isSelectable }

    val hasConfiguredChatAPI: Boolean
        get() {
            if (!isEnabled) return false
            val url = runCatching { EndpointResolver.chatEndpoint(baseURL, protocolType) }.getOrNull() ?: return false
            val scheme = url.scheme?.lowercase() ?: return false
            if (scheme != "http" && scheme != "https") return false
            if (url.host.equals("api.example.com", ignoreCase = true)) return false
            if (NetworkLocation.isPlainHTTPToPublicHost(baseURL)) return false
            return NetworkLocation.isLocalOrPrivate(baseURL) || hasAuthentication
        }

    val isReadyForChat: Boolean
        get() = hasConfiguredChatAPI && enabledModels.isNotEmpty()

    fun makeTarget(spec: ModelSpec): ResolvedModelTarget = ResolvedModelTarget(
        providerID = id,
        providerName = name,
        protocolType = protocolType,
        modelID = spec.id,
        modelDisplayName = spec.displayName,
        accentHex = accentHex,
        supportsVision = spec.supportsVision,
        supportsReasoning = spec.supportsReasoning
    )

    fun resolvedCustomHeaders(secretStore: SecretStore): List<CustomHeader> =
        customHeaders.map { h ->
            if (!h.isSecret) h
            else h.copy(value = secretStore.loadSecret(SecretStore.headerAccount(id, h.id)))
        }
}

data class PersonalMemoryItem(
    val id: String,
    val content: String,
    val isEnabled: Boolean,
    val createdAtEpochMs: Long
)

data class BookVolumeItem(
    val id: String,
    val title: String,
    val chapterTitles: List<String>,
    val manuscriptBlobKey: String,
    val byteCount: Long,
    val importedAtEpochMs: Long
) {
    val formattedSize: String
        get() = when {
            byteCount >= 1024L * 1024L -> String.format(java.util.Locale.US, "%.1f MB", byteCount / (1024.0 * 1024.0))
            byteCount >= 1024L -> String.format(java.util.Locale.US, "%.1f KB", byteCount / 1024.0)
            else -> "$byteCount B"
        }
}

data class ShelfReadingStateItem(
    val bookID: String,
    val conversationID: String?,
    val chapter: Int,
    val paragraph: Int
)

data class PresetItem(
    val id: String,
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
    val knowledgeVolumeIDs: List<String> = emptyList(),
    val createdAtEpochMs: Long
)

data class ConversationItem(
    val id: String,
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
    val primaryTarget: ResolvedModelTarget?,
    val arenaTargets: List<ResolvedModelTarget>,
    val assistanceSettings: ConversationAssistanceSettings = ConversationAssistanceSettings(),
    val folderTag: String?,
    val createdAtEpochMs: Long,
    val updatedAtEpochMs: Long
) {
    val isGroupMode: Boolean
        get() = assistanceSettings.isGroupMode

    val groupMembers: List<GroupMember>
        get() = assistanceSettings.groupMembers

    val activeGroupMembers: List<GroupMember>
        get() = assistanceSettings.groupMembers.filter { !it.isMuted }

    val activeBookFriend: BookFriend?
        get() = assistanceSettings.bookFriend

    val companionBookID: String?
        get() = assistanceSettings.companionBookID

    fun isCompanion(forBookID: String): Boolean {
        if (isGroupMode || isArenaMode || activeBookFriend != null || assistanceSettings.privatePersona != null) {
            return false
        }
        val cid = assistanceSettings.companionBookID
        if (cid != null) return cid.equals(forBookID, ignoreCase = true)
        return assistantID == null &&
            assistantEmoji == "📚" &&
            assistanceSettings.knowledgeVolumeIDs.size == 1 &&
            assistanceSettings.knowledgeVolumeIDs[0].equals(forBookID, ignoreCase = true)
    }

    companion object {
        val defaultTitle: String
            get() = L10n.text("新对话", "New Chat")

        fun isDefaultTitle(title: String): Boolean =
            title == defaultTitle || title == "新对话" || title == "New Chat"
    }
}

data class ChatMessageItem(
    val id: String,
    val conversationID: String,
    val role: MessageRole,
    val content: String,
    val reasoningContent: String,
    val attachments: List<MessageAttachment>,
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
    val synthesisSourceDigest: String? = null,
    val latestRequestID: String?,
    val assistanceMetadata: MessageAssistanceMetadata = MessageAssistanceMetadata(),
    val parentMessageID: String?,
    val sortIndex: Int,
    val createdAtEpochMs: Long
) {
    val isSynthesis: Boolean
        get() = synthesisSourceDigest != null

    val finishReasonValue: LLMFinishReason?
        get() = finishReason?.let { raw -> LLMFinishReason.entries.firstOrNull { it.rawValue == raw } }
}

data class RequestRecordItem(
    val id: String,
    val operationID: String,
    val attempt: Int,
    val conversationID: String,
    val messageID: String,
    val providerID: String,
    val providerName: String,
    val modelID: String,
    val modelDisplayName: String,
    val protocolType: APIProtocolType,
    val kind: RequestKind,
    val status: RequestStatus,
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
) {
    val firstOutputMs: Int?
        get() = RequestMetrics.firstOutputMs(firstReasoningMs, firstContentMs)

    val tokensPerSecond: Double?
        get() = RequestMetrics.tokensPerSecond(
            status = status,
            isStreamed = isStreamed,
            outputChunkCount = outputChunkCount,
            completionTokens = completionTokens,
            firstReasoningMs = firstReasoningMs,
            firstContentMs = firstContentMs,
            lastOutputMs = lastOutputMs
        )

    val estimatedCost: Double?
        get() = RequestMetrics.estimatedCost(
            promptTokens = promptTokens,
            completionTokens = completionTokens,
            cachedTokens = cachedTokens,
            cacheWriteTokens = cacheWriteTokens,
            inputPricePerMillion = inputPricePerMillion,
            outputPricePerMillion = outputPricePerMillion,
            cacheReadPricePerMillion = cacheReadPricePerMillion,
            cacheWritePricePerMillion = cacheWritePricePerMillion,
            currency = currency
        )
}

class ChatRepository(
    private val db: FugueDatabase,
    private val blobStore: ExternalBlobStore,
    private val secretStore: SecretStore
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

    fun observeProviders(): Flow<List<ProviderItem>> =
        combine(db.providerDao().observeAll(), secretStore.versionFlow) { list, _ ->
            list.map { toProviderItem(it) }
        }.flowOn(Dispatchers.IO)

    suspend fun getProviders(): List<ProviderItem> = withContext(Dispatchers.IO) {
        db.providerDao().getAll().map { toProviderItem(it) }
    }

    suspend fun getProvider(id: String): ProviderItem? = withContext(Dispatchers.IO) {
        db.providerDao().getById(id.uppercase())?.let { toProviderItem(it) }
    }

    suspend fun saveProvider(item: ProviderItem) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        db.providerDao().upsert(
            ProviderEntity(
                id = item.id.uppercase(),
                name = item.name,
                protocolRaw = item.protocolType.rawValue,
                baseURL = item.baseURL,
                iconSymbol = item.iconSymbol,
                accentHex = item.accentHex,
                isEnabled = item.isEnabled,
                sortOrder = item.sortOrder,
                modelsJson = json.encodeToString(ModelSpec.deduplicated(item.models)),
                headersJson = json.encodeToString(item.customHeaders),
                notes = item.notes,
                createdAtEpochMs = item.createdAtEpochMs,
                updatedAtEpochMs = now
            )
        )
    }

    suspend fun deleteProvider(item: ProviderItem) = withContext(Dispatchers.IO) {
        secretStore.deleteProviderSecrets(item.id, item.customHeaders.map { it.id })
        db.providerDao().deleteById(item.id.uppercase())
    }

    fun observePresets(): Flow<List<PresetItem>> =
        db.assistantPresetDao().observeAll().map { list -> list.map { toPresetItem(it) } }.flowOn(Dispatchers.IO)

    suspend fun savePreset(item: PresetItem) = withContext(Dispatchers.IO) {
        val cleanedVolumes = item.knowledgeVolumeIDs
            .map { it.trim().uppercase() }
            .filter { it.isNotEmpty() }
            .distinct()
            .take(12)
        db.assistantPresetDao().upsert(
            AssistantPresetEntity(
                id = item.id.uppercase(),
                name = item.name,
                iconEmoji = item.iconEmoji,
                subtitle = item.subtitle,
                systemPrompt = item.systemPrompt,
                temperature = item.temperature,
                useCustomTemperature = item.useCustomTemperature,
                topP = item.topP,
                maxOutputTokens = item.maxOutputTokens,
                contextMessageLimit = item.contextMessageLimit,
                enableThinking = item.enableThinking,
                thinkingBudgetTokens = item.thinkingBudgetTokens,
                isBuiltIn = item.isBuiltIn,
                sortOrder = item.sortOrder,
                knowledgeVolumeIDsJson = cleanedVolumes.takeIf { it.isNotEmpty() }?.let { json.encodeToString(it) },
                createdAtEpochMs = item.createdAtEpochMs
            )
        )
    }

    suspend fun deletePreset(id: String) = withContext(Dispatchers.IO) {
        db.assistantPresetDao().deleteById(id.uppercase())
    }

    fun observeConversations(): Flow<List<ConversationItem>> =
        db.conversationDao().observeAll().map { list -> list.map { toConversationItem(it) } }.flowOn(Dispatchers.IO)

    fun observeConversation(id: String): Flow<ConversationItem?> =
        db.conversationDao().observeById(id.uppercase()).map { it?.let(::toConversationItem) }.flowOn(Dispatchers.IO)

    suspend fun getConversation(id: String): ConversationItem? = withContext(Dispatchers.IO) {
        db.conversationDao().getById(id.uppercase())?.let(::toConversationItem)
    }

    suspend fun createConversation(
        preset: PresetItem? = null,
        primaryTarget: ResolvedModelTarget? = null,
        isArenaMode: Boolean = false,
        arenaTargets: List<ResolvedModelTarget> = emptyList(),
        blindArenaMode: Boolean = false
    ): ConversationItem = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val id = UUID.randomUUID().toString().uppercase()
        val item = ConversationItem(
            id = id,
            title = ConversationItem.defaultTitle,
            isPinned = false,
            assistantID = preset?.id,
            assistantEmoji = preset?.iconEmoji ?: "✨",
            systemPrompt = preset?.systemPrompt ?: "",
            temperature = preset?.temperature ?: 0.7,
            useCustomTemperature = preset?.useCustomTemperature ?: true,
            topP = preset?.topP ?: 1.0,
            maxOutputTokens = preset?.maxOutputTokens ?: 0,
            contextMessageLimit = preset?.contextMessageLimit ?: 20,
            enableThinking = preset?.enableThinking ?: true,
            thinkingBudgetTokens = preset?.thinkingBudgetTokens ?: 4096,
            isArenaMode = isArenaMode,
            primaryTarget = primaryTarget,
            arenaTargets = arenaTargets,
            assistanceSettings = ConversationAssistanceSettings(
                blindArenaMode = blindArenaMode,
                knowledgeVolumeIDs = preset?.knowledgeVolumeIDs.orEmpty()
            ),
            folderTag = null,
            createdAtEpochMs = now,
            updatedAtEpochMs = now
        )
        saveConversation(item)
        item
    }

    suspend fun createGroupConversation(
        title: String,
        emoji: String = "👥",
        systemPrompt: String = "",
        members: List<GroupMember>,
        speakingMode: GroupSpeakingMode = GroupSpeakingMode.SMART_RELAY,
        speechStyle: GroupSpeechStyle = GroupSpeechStyle.NATURAL_SHORT,
        maxRelayTurns: Int = 3,
        splitShortBubbles: Boolean = true
    ): ConversationItem = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val id = UUID.randomUUID().toString().uppercase()
        val item = ConversationItem(
            id = id,
            title = title.trim().ifEmpty { L10n.text("圆桌群聊", "Group Chat") },
            isPinned = false,
            assistantID = null,
            assistantEmoji = emoji.trim().ifEmpty { "👥" },
            systemPrompt = systemPrompt.trim(),
            temperature = 0.75,
            useCustomTemperature = true,
            topP = 1.0,
            maxOutputTokens = 0,
            contextMessageLimit = 24,
            enableThinking = true,
            thinkingBudgetTokens = 4096,
            isArenaMode = false,
            primaryTarget = members.firstOrNull()?.target,
            arenaTargets = emptyList(),
            assistanceSettings = ConversationAssistanceSettings(
                isGroupMode = true,
                groupMembers = members,
                groupSpeakingMode = speakingMode,
                groupSpeechStyle = speechStyle,
                groupMaxRelayTurns = maxRelayTurns.coerceIn(1, 6),
                groupSplitShortBubbles = splitShortBubbles
            ),
            folderTag = null,
            createdAtEpochMs = now,
            updatedAtEpochMs = now
        )
        saveConversation(item)
        item
    }

    fun observePersonaProfiles(): Flow<List<GroupMember>> =
        db.personaProfileDao().observeAll().map { entities ->
            entities.mapNotNull { entity ->
                blobStore.readText(entity.payloadBlobKey)?.let { raw ->
                    runCatching { json.decodeFromString<GroupMember>(raw) }.getOrNull()
                }
            }
        }.flowOn(Dispatchers.IO)

    suspend fun savePersonaProfile(draft: GroupMember): GroupMember = withContext(Dispatchers.IO) {
        val saved = draft.portableProfile().let { p ->
            p.copy(name = p.name.trim())
        }
        val key = "persona_${saved.id}.json"
        val now = System.currentTimeMillis()
        blobStore.writeText(key, json.encodeToString(saved))
        db.personaProfileDao().upsert(
            PersonaProfileEntity(
                id = saved.id,
                payloadBlobKey = key,
                updatedAtEpochMs = now
            )
        )

        val conversations = db.conversationDao().getAll().map(::toConversationItem)
        for (conv in conversations) {
            var changed = false
            var settings = conv.assistanceSettings
            val updatedMembers = settings.groupMembers.map { existing ->
                if (existing.profileID.equals(saved.id, ignoreCase = true)) {
                    changed = true
                    saved.inRoom(replacing = existing)
                } else {
                    existing
                }
            }
            if (changed) {
                settings = settings.copy(groupMembers = updatedMembers)
            }
            var updatedConv = conv
            val oldPrivate = settings.privatePersona
            if (oldPrivate != null && oldPrivate.profileID.equals(saved.id, ignoreCase = true)) {
                settings = settings.copy(privatePersona = saved)
                updatedConv = updatedConv.copy(
                    title = if (conv.title == oldPrivate.name) saved.name else conv.title,
                    assistantEmoji = saved.avatarEmoji,
                    primaryTarget = if (conv.primaryTarget?.id == oldPrivate.target.id) saved.target else conv.primaryTarget
                )
                changed = true
            }
            if (changed) {
                saveConversation(updatedConv.copy(assistanceSettings = settings, updatedAtEpochMs = now))
            }
        }
        saved
    }

    suspend fun deletePersonaProfile(id: String) = withContext(Dispatchers.IO) {
        val pid = id.uppercase()
        db.personaProfileDao().getById(pid)?.payloadBlobKey?.let { blobStore.delete(it) }
        db.personaProfileDao().deleteById(pid)
    }

    suspend fun openOrCreatePrivatePersonaChat(profile: GroupMember): ConversationItem = withContext(Dispatchers.IO) {
        val member = profile.portableProfile()
        val existing = db.conversationDao().getAll().map(::toConversationItem).firstOrNull { conv ->
            !conv.isArenaMode &&
                !conv.isGroupMode &&
                conv.assistanceSettings.privatePersona?.profileID.equals(member.profileID, ignoreCase = true)
        }
        if (existing != null) return@withContext existing

        val now = System.currentTimeMillis()
        val id = UUID.randomUUID().toString().uppercase()
        val created = ConversationItem(
            id = id,
            title = member.name.ifBlank { L10n.text("角色私聊", "Persona Chat") },
            isPinned = false,
            assistantID = null,
            assistantEmoji = member.avatarEmoji,
            systemPrompt = member.rolePrompt,
            temperature = member.temperature,
            useCustomTemperature = true,
            topP = 1.0,
            maxOutputTokens = 0,
            contextMessageLimit = 20,
            enableThinking = true,
            thinkingBudgetTokens = 4096,
            isArenaMode = false,
            primaryTarget = member.target,
            arenaTargets = emptyList(),
            assistanceSettings = ConversationAssistanceSettings(privatePersona = member),
            folderTag = null,
            createdAtEpochMs = now,
            updatedAtEpochMs = now
        )
        saveConversation(created)
        created
    }

    suspend fun deleteMessage(messageID: String) = withContext(Dispatchers.IO) {
        val mid = messageID.uppercase()
        val existing = db.chatMessageDao().getById(mid)
        existing?.attachmentsBlobKey?.let { blobStore.delete(it) }
        existing?.assistanceMetadataBlobKey?.let { blobStore.delete(it) }
        db.chatMessageDao().deleteById(mid)
    }

    fun observePersonalMemories(): Flow<List<PersonalMemoryItem>> =
        db.personalMemoryDao().observeAll().map { list ->
            list.map(::toPersonalMemoryItem)
        }.flowOn(Dispatchers.IO)

    suspend fun getPersonalMemories(): List<PersonalMemoryItem> = withContext(Dispatchers.IO) {
        db.personalMemoryDao().getAll().map(::toPersonalMemoryItem)
    }

    suspend fun getEnabledPersonalMemories(): List<PersonalMemoryItem> = withContext(Dispatchers.IO) {
        db.personalMemoryDao().getAll()
            .filter { it.isEnabled && it.content.isNotBlank() }
            .take(PersonalMemoryPrompt.MAXIMUM_COUNT)
            .map(::toPersonalMemoryItem)
    }

    suspend fun addPersonalMemory(content: String): PersonalMemoryItem = withContext(Dispatchers.IO) {
        val bounded = content.trim().take(PersonalMemoryPrompt.MAXIMUM_CHARACTERS)
        val all = db.personalMemoryDao().getAll()
        val existing = all.firstOrNull { it.content.trim().equals(bounded, ignoreCase = true) }
        if (existing != null) {
            val enabled = if (existing.isEnabled) existing else existing.copy(isEnabled = true)
            db.personalMemoryDao().upsert(enabled)
            return@withContext toPersonalMemoryItem(enabled)
        }
        if (all.size >= PersonalMemoryPrompt.MAXIMUM_COUNT || bounded.isEmpty()) {
            return@withContext toPersonalMemoryItem(all.firstOrNull() ?: PersonalMemoryEntity("", "", false, 0L))
        }
        val entity = PersonalMemoryEntity(
            id = UUID.randomUUID().toString().uppercase(),
            content = bounded,
            isEnabled = true,
            createdAtEpochMs = System.currentTimeMillis()
        )
        db.personalMemoryDao().upsert(entity)
        toPersonalMemoryItem(entity)
    }

    suspend fun savePersonalMemory(item: PersonalMemoryItem): Boolean = withContext(Dispatchers.IO) {
        val clean = item.content.trim().take(PersonalMemoryPrompt.MAXIMUM_CHARACTERS)
        if (clean.isEmpty()) return@withContext false
        val all = db.personalMemoryDao().getAll()
        val existing = all.firstOrNull { it.id.equals(item.id, ignoreCase = true) }
        if (existing == null && all.size >= PersonalMemoryPrompt.MAXIMUM_COUNT) {
            return@withContext false
        }
        db.personalMemoryDao().upsert(
            PersonalMemoryEntity(
                id = item.id.uppercase(),
                content = clean,
                isEnabled = item.isEnabled,
                createdAtEpochMs = existing?.createdAtEpochMs ?: item.createdAtEpochMs
            )
        )
        true
    }

    suspend fun setPersonalMemoryEnabled(id: String, enabled: Boolean) = withContext(Dispatchers.IO) {
        val target = db.personalMemoryDao().getAll().firstOrNull { it.id.equals(id, ignoreCase = true) }
            ?: return@withContext
        db.personalMemoryDao().upsert(target.copy(isEnabled = enabled))
    }

    suspend fun deletePersonalMemory(id: String) = withContext(Dispatchers.IO) {
        db.personalMemoryDao().deleteById(id.uppercase())
    }

    fun observeBooks(): Flow<List<BookVolumeItem>> =
        db.bookVolumeDao().observeAll().map { list ->
            list.map(::toBookVolumeItem)
        }.flowOn(Dispatchers.IO)

    suspend fun getBooks(): List<BookVolumeItem> = withContext(Dispatchers.IO) {
        db.bookVolumeDao().getAll().map(::toBookVolumeItem)
    }

    suspend fun getBook(id: String): BookVolumeItem? = withContext(Dispatchers.IO) {
        db.bookVolumeDao().getById(id.uppercase())?.let(::toBookVolumeItem)
    }

    suspend fun loadBookChapters(bookID: String): List<BookChapter> = withContext(Dispatchers.IO) {
        val bid = bookID.uppercase()
        val key = db.bookVolumeDao().getById(bid)?.manuscriptBlobKey ?: "book_$bid.json"
        val raw = blobStore.readText(key) ?: return@withContext emptyList()
        runCatching { json.decodeFromString<List<BookChapter>>(raw) }.getOrDefault(emptyList())
    }

    suspend fun storePreparedBook(prepared: PreparedBook): BookVolumeItem = withContext(Dispatchers.IO) {
        val id = prepared.id.uppercase()
        db.bookVolumeDao().getById(id)?.let { return@withContext toBookVolumeItem(it) }
        val key = "book_$id.json"
        blobStore.writeText(key, prepared.encodedJson)
        val entity = BookVolumeEntity(
            id = id,
            title = prepared.title,
            chapterTitlesJson = json.encodeToString(prepared.chapterTitles),
            manuscriptBlobKey = key,
            byteCount = prepared.byteCount,
            importedAtEpochMs = System.currentTimeMillis()
        )
        db.bookVolumeDao().upsert(entity)
        toBookVolumeItem(entity)
    }

    suspend fun deleteBook(bookID: String) = withContext(Dispatchers.IO) {
        val bid = bookID.uppercase()
        val existing = db.bookVolumeDao().getById(bid)
        existing?.manuscriptBlobKey?.let { blobStore.delete(it) }
        db.withTransaction {
            db.shelfReadingStateDao().deleteByBookId(bid)
            db.bookVolumeDao().deleteById(bid)
            val presets = db.assistantPresetDao().getAll()
            for (preset in presets) {
                val ids = preset.knowledgeVolumeIDsJson?.let {
                    runCatching { json.decodeFromString<List<String>>(it) }.getOrNull()
                } ?: continue
                val remaining = ids.filterNot { it.equals(bid, ignoreCase = true) }
                if (remaining.size != ids.size) {
                    db.assistantPresetDao().upsert(
                        preset.copy(
                            knowledgeVolumeIDsJson = remaining.takeIf { it.isNotEmpty() }?.let { json.encodeToString(it) }
                        )
                    )
                }
            }
        }
        ProjectKnowledgeSearch.invalidate(bid)
    }

    fun observeShelfStates(): Flow<List<ShelfReadingStateItem>> =
        db.shelfReadingStateDao().observeAll().map { list ->
            list.map(::toShelfStateItem)
        }.flowOn(Dispatchers.IO)

    suspend fun getShelfState(bookID: String): ShelfReadingStateItem? = withContext(Dispatchers.IO) {
        db.shelfReadingStateDao().getByBookId(bookID.uppercase())?.let(::toShelfStateItem)
    }

    suspend fun saveShelfState(state: ShelfReadingStateItem) = withContext(Dispatchers.IO) {
        db.shelfReadingStateDao().upsert(
            ShelfReadingStateEntity(
                bookID = state.bookID.uppercase(),
                conversationID = state.conversationID?.uppercase(),
                chapter = state.chapter.coerceAtLeast(0),
                paragraph = state.paragraph.coerceAtLeast(0)
            )
        )
    }

    suspend fun openOrCreateBookCompanion(
        book: BookVolumeItem,
        newDiscussion: Boolean = false,
        target: ResolvedModelTarget?
    ): ConversationItem = withContext(Dispatchers.IO) {
        val bid = book.id.uppercase()
        val state = db.shelfReadingStateDao().getByBookId(bid)
            ?: ShelfReadingStateEntity(bid, null, 0, 0)
        val chats = db.conversationDao().getAll().map(::toConversationItem)
        val candidates = if (newDiscussion) emptyList() else chats.filter { it.isCompanion(bid) }
        val chosen = state.conversationID?.let { cid -> candidates.firstOrNull { it.id.equals(cid, ignoreCase = true) } }
            ?: candidates.firstOrNull()
        val now = System.currentTimeMillis()
        val chat = chosen?.copy(
            assistanceSettings = chosen.assistanceSettings.copy(
                companionBookID = bid,
                knowledgeVolumeIDs = chosen.assistanceSettings.knowledgeVolumeIDs.ifEmpty { listOf(bid) }
            ),
            updatedAtEpochMs = now
        ) ?: ConversationItem(
            id = UUID.randomUUID().toString().uppercase(),
            title = L10n.text("《${book.title}》伴读", "Reading Companion: ${book.title}"),
            isPinned = false,
            assistantID = null,
            assistantEmoji = "📚",
            systemPrompt = L10n.text(
                "你是一位细腻博学的共读伴侣，陪用户一起阅读《${book.title}》。结合检索到的原著章节上下文回答问题，遇到无依据之处坦诚说明。",
                "You are a thoughtful reading companion helping the user read \"${book.title}\". Base answers on cited passages from the book."
            ),
            temperature = 0.7,
            useCustomTemperature = true,
            topP = 1.0,
            maxOutputTokens = 0,
            contextMessageLimit = 20,
            enableThinking = true,
            thinkingBudgetTokens = 4096,
            isArenaMode = false,
            primaryTarget = target,
            arenaTargets = emptyList(),
            assistanceSettings = ConversationAssistanceSettings(
                knowledgeVolumeIDs = listOf(bid),
                companionBookID = bid
            ),
            folderTag = null,
            createdAtEpochMs = now,
            updatedAtEpochMs = now
        )
        saveConversation(chat)
        db.shelfReadingStateDao().upsert(state.copy(conversationID = chat.id.uppercase()))
        chat
    }

    suspend fun openOrCreateBookFriendChat(
        friend: BookFriend,
        target: ResolvedModelTarget?
    ): ConversationItem = withContext(Dispatchers.IO) {
        val book = getBook(friend.bookID) ?: throw BookImportError.Unavailable()
        val last = (book.chapterTitles.size - 1).coerceAtLeast(0)
        if (friend.throughChapter != null && !book.chapterTitles.indices.contains(friend.throughChapter)) {
            throw BookImportError.InvalidBook()
        }
        val chats = db.conversationDao().getAll().map(::toConversationItem)
        val matches = chats.filter { it.activeBookFriend?.isSameCharacter(friend) == true }
        val exact = matches.firstOrNull { it.activeBookFriend?.throughChapter == friend.throughChapter }
        val compatible = exact ?: matches.firstOrNull {
            val prev = it.activeBookFriend?.throughChapter ?: last
            val next = friend.throughChapter ?: last
            prev <= next
        }
        if (compatible != null) {
            val updated = compatible.copy(
                assistanceSettings = compatible.assistanceSettings.copy(bookFriend = friend),
                updatedAtEpochMs = System.currentTimeMillis()
            )
            saveConversation(updated)
            return@withContext updated
        }
        val now = System.currentTimeMillis()
        val created = ConversationItem(
            id = UUID.randomUUID().toString().uppercase(),
            title = friend.name,
            isPinned = false,
            assistantID = null,
            assistantEmoji = "📖",
            systemPrompt = "",
            temperature = 0.7,
            useCustomTemperature = true,
            topP = 1.0,
            maxOutputTokens = 0,
            contextMessageLimit = 20,
            enableThinking = true,
            thinkingBudgetTokens = 4096,
            isArenaMode = false,
            primaryTarget = target,
            arenaTargets = emptyList(),
            assistanceSettings = ConversationAssistanceSettings(bookFriend = friend),
            folderTag = null,
            createdAtEpochMs = now,
            updatedAtEpochMs = now
        )
        saveConversation(created)
        created
    }

    suspend fun changeBookFriendProgress(
        conv: ConversationItem,
        throughChapter: Int?
    ): ConversationItem = withContext(Dispatchers.IO) {
        val oldFriend = conv.activeBookFriend ?: throw BookImportError.Unavailable()
        val book = getBook(oldFriend.bookID) ?: throw BookImportError.Unavailable()
        if (throughChapter != null && !book.chapterTitles.indices.contains(throughChapter)) {
            throw BookImportError.InvalidBook()
        }
        val last = (book.chapterTitles.size - 1).coerceAtLeast(0)
        val rewind = (throughChapter ?: last) < (oldFriend.throughChapter ?: last)
        val updatedFriend = oldFriend.copy(throughChapter = throughChapter)
        if (rewind) {
            val now = System.currentTimeMillis()
            val fresh = ConversationItem(
                id = UUID.randomUUID().toString().uppercase(),
                title = updatedFriend.name,
                isPinned = false,
                assistantID = null,
                assistantEmoji = "📖",
                systemPrompt = "",
                temperature = conv.temperature,
                useCustomTemperature = conv.useCustomTemperature,
                topP = conv.topP,
                maxOutputTokens = conv.maxOutputTokens,
                contextMessageLimit = conv.contextMessageLimit,
                enableThinking = conv.enableThinking,
                thinkingBudgetTokens = conv.thinkingBudgetTokens,
                isArenaMode = false,
                primaryTarget = conv.primaryTarget,
                arenaTargets = emptyList(),
                assistanceSettings = ConversationAssistanceSettings(bookFriend = updatedFriend),
                folderTag = conv.folderTag,
                createdAtEpochMs = now,
                updatedAtEpochMs = now
            )
            saveConversation(fresh)
            return@withContext fresh
        }
        val updated = conv.copy(
            assistanceSettings = conv.assistanceSettings.copy(bookFriend = updatedFriend),
            updatedAtEpochMs = System.currentTimeMillis()
        )
        saveConversation(updated)
        updated
    }

    suspend fun saveConversation(item: ConversationItem) = withContext(Dispatchers.IO) {
        val cid = item.id.uppercase()
        val existing = db.conversationDao().getById(cid)
        val settingsKey = if (!item.assistanceSettings.isDefault || existing?.assistanceSettingsBlobKey != null) {
            val key = existing?.assistanceSettingsBlobKey ?: "conv_settings_$cid.json"
            val existingObj = blobStore.readText(existing?.assistanceSettingsBlobKey)?.let { raw ->
                runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
            }
            val merged = item.assistanceSettings.mergeInto(existingObj, json)
            blobStore.writeText(key, json.encodeToString(JsonObject.serializer(), merged))
            key
        } else {
            null
        }
        db.conversationDao().upsert(
            ConversationEntity(
                id = cid,
                title = item.title,
                isPinned = item.isPinned,
                assistantID = item.assistantID?.uppercase(),
                assistantEmoji = item.assistantEmoji,
                systemPrompt = item.systemPrompt,
                temperature = item.temperature,
                useCustomTemperature = item.useCustomTemperature,
                topP = item.topP,
                maxOutputTokens = item.maxOutputTokens,
                contextMessageLimit = item.contextMessageLimit,
                enableThinking = item.enableThinking,
                thinkingBudgetTokens = item.thinkingBudgetTokens,
                isArenaMode = item.isArenaMode,
                primaryTargetJson = item.primaryTarget?.let { json.encodeToString(it) } ?: "null",
                arenaTargetsJson = json.encodeToString(item.arenaTargets),
                assistanceSettingsBlobKey = settingsKey,
                activeLeafMessageID = existing?.activeLeafMessageID,
                folderTag = item.folderTag,
                organizationEditsJson = existing?.organizationEditsJson,
                legacyImportID = existing?.legacyImportID,
                createdAtEpochMs = item.createdAtEpochMs,
                updatedAtEpochMs = item.updatedAtEpochMs
            )
        )
    }

    suspend fun deleteConversation(conversationID: String) = withContext(Dispatchers.IO) {
        val cid = conversationID.uppercase()
        val conv = db.conversationDao().getById(cid)
        val msgs = db.chatMessageDao().getByConversation(cid)
        for (m in msgs) {
            m.attachmentsBlobKey?.let { blobStore.delete(it) }
            m.assistanceMetadataBlobKey?.let { blobStore.delete(it) }
        }
        conv?.assistanceSettingsBlobKey?.let { blobStore.delete(it) }
        db.conversationDao().deleteById(cid)
    }

    fun observeMessages(conversationID: String): Flow<List<ChatMessageItem>> =
        db.chatMessageDao().observeByConversation(conversationID.uppercase())
            .map { list -> list.map { toChatMessageItem(it) } }
            .flowOn(Dispatchers.IO)

    suspend fun getMessages(conversationID: String): List<ChatMessageItem> = withContext(Dispatchers.IO) {
        db.chatMessageDao().getByConversation(conversationID.uppercase()).map { toChatMessageItem(it) }
    }

    fun observeArenaMessages(): Flow<List<ChatMessageItem>> =
        db.chatMessageDao().observeArenaMessages()
            .map { list -> list.map(::toChatMessageItem) }
            .flowOn(Dispatchers.IO)

    suspend fun saveMessage(item: ChatMessageItem) = withContext(Dispatchers.IO) {
        val mid = item.id.uppercase()
        val existing = db.chatMessageDao().getById(mid)
        val attKey = if (item.attachments.isNotEmpty()) {
            val key = "msg_att_$mid.json"
            blobStore.writeText(key, json.encodeToString(item.attachments))
            key
        } else {
            existing?.attachmentsBlobKey?.let { blobStore.delete(it) }
            null
        }
        val metaKey = if (!item.assistanceMetadata.isDefault || existing?.assistanceMetadataBlobKey != null) {
            val key = existing?.assistanceMetadataBlobKey ?: "msg_meta_$mid.json"
            val existingObj = blobStore.readText(existing?.assistanceMetadataBlobKey)?.let { raw ->
                runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
            }
            val merged = item.assistanceMetadata.mergeInto(existingObj, json)
            blobStore.writeText(key, json.encodeToString(JsonObject.serializer(), merged))
            key
        } else {
            null
        }
        db.chatMessageDao().upsert(
            ChatMessageEntity(
                id = mid,
                conversationID = item.conversationID.uppercase(),
                roleRaw = item.role.rawValue,
                content = item.content,
                reasoningContent = item.reasoningContent,
                attachmentsBlobKey = attKey,
                providerID = item.providerID?.uppercase(),
                providerName = item.providerName,
                modelID = item.modelID,
                modelDisplayName = item.modelDisplayName,
                accentHex = item.accentHex,
                comparisonGroupID = item.comparisonGroupID?.uppercase(),
                isSelectedInGroup = item.isSelectedInGroup,
                isStreaming = item.isStreaming,
                errorMessage = item.errorMessage,
                finishReason = item.finishReason,
                promptTokens = item.promptTokens,
                completionTokens = item.completionTokens,
                cachedTokens = item.cachedTokens,
                latencyMs = item.latencyMs,
                thinkingDurationMs = item.thinkingDurationMs,
                synthesisSourceDigest = item.synthesisSourceDigest,
                latestRequestID = item.latestRequestID?.uppercase(),
                assistanceMetadataBlobKey = metaKey,
                parentMessageID = item.parentMessageID?.uppercase(),
                sortIndex = item.sortIndex,
                createdAtEpochMs = item.createdAtEpochMs
            )
        )
    }

    fun observeRequestRecords(): Flow<List<RequestRecordItem>> =
        db.requestRecordDao().observeAll().map { list -> list.map(::toRequestRecordItem) }.flowOn(Dispatchers.IO)

    suspend fun saveRequestRecord(item: RequestRecordItem) = withContext(Dispatchers.IO) {
        db.requestRecordDao().upsert(
            RequestRecordEntity(
                id = item.id.uppercase(),
                operationID = item.operationID.uppercase(),
                attempt = item.attempt,
                conversationID = item.conversationID.uppercase(),
                messageID = item.messageID.uppercase(),
                providerID = item.providerID.uppercase(),
                providerName = item.providerName,
                modelID = item.modelID,
                modelDisplayName = item.modelDisplayName,
                protocolRaw = item.protocolType.rawValue,
                kindRaw = item.kind.rawValue,
                statusRaw = item.status.rawValue,
                startedAtEpochMs = item.startedAtEpochMs,
                endedAtEpochMs = item.endedAtEpochMs,
                firstReasoningMs = item.firstReasoningMs,
                firstContentMs = item.firstContentMs,
                lastOutputMs = item.lastOutputMs,
                durationMs = item.durationMs,
                outputChunkCount = item.outputChunkCount,
                isStreamed = item.isStreamed,
                promptTokens = item.promptTokens,
                completionTokens = item.completionTokens,
                cachedTokens = item.cachedTokens,
                cacheWriteTokens = item.cacheWriteTokens,
                httpStatus = item.httpStatus,
                inputPricePerMillion = RequestMetrics.validPrice(item.inputPricePerMillion),
                outputPricePerMillion = RequestMetrics.validPrice(item.outputPricePerMillion),
                cacheReadPricePerMillion = RequestMetrics.validPrice(item.cacheReadPricePerMillion),
                cacheWritePricePerMillion = RequestMetrics.validPrice(item.cacheWritePricePerMillion),
                currency = item.currency
            )
        )
    }

    private fun toProviderItem(e: ProviderEntity): ProviderItem {
        val models = runCatching { json.decodeFromString<List<ModelSpec>>(e.modelsJson) }.getOrDefault(emptyList())
        val headers = runCatching { json.decodeFromString<List<CustomHeader>>(e.headersJson) }.getOrDefault(emptyList())
        val hasSecretHeader = headers.any { h ->
            if (!h.isEnabled || !CustomHeader.looksSensitive(h.key)) return@any false
            val valStr = if (h.isSecret) secretStore.loadSecret(SecretStore.headerAccount(e.id, h.id)) else h.value
            valStr.trim().isNotEmpty()
        }
        return ProviderItem(
            id = e.id,
            name = e.name,
            protocolType = APIProtocolType.fromRaw(e.protocolRaw),
            baseURL = e.baseURL,
            iconSymbol = e.iconSymbol,
            accentHex = e.accentHex,
            isEnabled = e.isEnabled,
            sortOrder = e.sortOrder,
            models = ModelSpec.deduplicated(models),
            customHeaders = headers,
            notes = e.notes,
            createdAtEpochMs = e.createdAtEpochMs,
            updatedAtEpochMs = e.updatedAtEpochMs,
            hasAuthentication = secretStore.hasAPIKey(e.id) || hasSecretHeader,
            idleTimeoutSeconds = secretStore.loadIdleTimeoutSeconds(e.id)
        )
    }

    private fun toPersonalMemoryItem(e: PersonalMemoryEntity): PersonalMemoryItem = PersonalMemoryItem(
        id = e.id,
        content = e.content,
        isEnabled = e.isEnabled,
        createdAtEpochMs = e.createdAtEpochMs
    )

    private fun toBookVolumeItem(e: BookVolumeEntity): BookVolumeItem {
        val titles = runCatching { json.decodeFromString<List<String>>(e.chapterTitlesJson) }.getOrDefault(emptyList())
        return BookVolumeItem(
            id = e.id,
            title = e.title,
            chapterTitles = titles,
            manuscriptBlobKey = e.manuscriptBlobKey,
            byteCount = e.byteCount,
            importedAtEpochMs = e.importedAtEpochMs
        )
    }

    private fun toShelfStateItem(e: ShelfReadingStateEntity): ShelfReadingStateItem = ShelfReadingStateItem(
        bookID = e.bookID,
        conversationID = e.conversationID,
        chapter = e.chapter,
        paragraph = e.paragraph
    )

    private fun toPresetItem(e: AssistantPresetEntity): PresetItem {
        val volumeIDs = e.knowledgeVolumeIDsJson?.let {
            runCatching { json.decodeFromString<List<String>>(it) }.getOrNull()
        } ?: emptyList()
        return PresetItem(
            id = e.id,
            name = e.name,
            iconEmoji = e.iconEmoji,
            subtitle = e.subtitle,
            systemPrompt = e.systemPrompt,
            temperature = e.temperature,
            useCustomTemperature = e.useCustomTemperature,
            topP = e.topP,
            maxOutputTokens = e.maxOutputTokens,
            contextMessageLimit = e.contextMessageLimit,
            enableThinking = e.enableThinking,
            thinkingBudgetTokens = e.thinkingBudgetTokens,
            isBuiltIn = e.isBuiltIn,
            sortOrder = e.sortOrder,
            knowledgeVolumeIDs = volumeIDs,
            createdAtEpochMs = e.createdAtEpochMs
        )
    }

    private fun toConversationItem(e: ConversationEntity): ConversationItem {
        val primary = e.primaryTargetJson.takeIf { it.isNotBlank() && it != "null" }?.let {
            runCatching { json.decodeFromString<ResolvedModelTarget>(it) }.getOrNull()
        }
        val arena = e.arenaTargetsJson.takeIf { it.isNotBlank() }?.let {
            runCatching { json.decodeFromString<List<ResolvedModelTarget>>(it) }.getOrNull()
        } ?: emptyList()
        val assistanceSettings = blobStore.readText(e.assistanceSettingsBlobKey)?.let {
            runCatching { json.decodeFromString<ConversationAssistanceSettings>(it) }.getOrNull()
        } ?: ConversationAssistanceSettings()
        return ConversationItem(
            id = e.id,
            title = e.title,
            isPinned = e.isPinned,
            assistantID = e.assistantID,
            assistantEmoji = e.assistantEmoji,
            systemPrompt = e.systemPrompt,
            temperature = e.temperature,
            useCustomTemperature = e.useCustomTemperature,
            topP = e.topP,
            maxOutputTokens = e.maxOutputTokens,
            contextMessageLimit = e.contextMessageLimit,
            enableThinking = e.enableThinking,
            thinkingBudgetTokens = e.thinkingBudgetTokens,
            isArenaMode = e.isArenaMode,
            primaryTarget = primary,
            arenaTargets = arena,
            assistanceSettings = assistanceSettings,
            folderTag = e.folderTag,
            createdAtEpochMs = e.createdAtEpochMs,
            updatedAtEpochMs = e.updatedAtEpochMs
        )
    }

    private fun toChatMessageItem(e: ChatMessageEntity): ChatMessageItem {
        val attachments = blobStore.readText(e.attachmentsBlobKey)?.let {
            runCatching { json.decodeFromString<List<MessageAttachment>>(it) }.getOrNull()
        } ?: emptyList()
        val assistanceMetadata = blobStore.readText(e.assistanceMetadataBlobKey)?.let {
            runCatching { json.decodeFromString<MessageAssistanceMetadata>(it) }.getOrNull()
        } ?: MessageAssistanceMetadata()
        return ChatMessageItem(
            id = e.id,
            conversationID = e.conversationID,
            role = MessageRole.fromRaw(e.roleRaw),
            content = e.content,
            reasoningContent = e.reasoningContent,
            attachments = attachments,
            providerID = e.providerID,
            providerName = e.providerName,
            modelID = e.modelID,
            modelDisplayName = e.modelDisplayName,
            accentHex = e.accentHex,
            comparisonGroupID = e.comparisonGroupID,
            isSelectedInGroup = e.isSelectedInGroup,
            isStreaming = e.isStreaming,
            errorMessage = e.errorMessage,
            finishReason = e.finishReason,
            promptTokens = e.promptTokens,
            completionTokens = e.completionTokens,
            cachedTokens = e.cachedTokens,
            latencyMs = e.latencyMs,
            thinkingDurationMs = e.thinkingDurationMs,
            synthesisSourceDigest = e.synthesisSourceDigest,
            latestRequestID = e.latestRequestID,
            assistanceMetadata = assistanceMetadata,
            parentMessageID = e.parentMessageID,
            sortIndex = e.sortIndex,
            createdAtEpochMs = e.createdAtEpochMs
        )
    }

    private fun toRequestRecordItem(e: RequestRecordEntity): RequestRecordItem = RequestRecordItem(
        id = e.id,
        operationID = e.operationID,
        attempt = e.attempt,
        conversationID = e.conversationID,
        messageID = e.messageID,
        providerID = e.providerID,
        providerName = e.providerName,
        modelID = e.modelID,
        modelDisplayName = e.modelDisplayName,
        protocolType = APIProtocolType.fromRaw(e.protocolRaw),
        kind = RequestKind.fromRaw(e.kindRaw),
        status = RequestStatus.fromRaw(e.statusRaw),
        startedAtEpochMs = e.startedAtEpochMs,
        endedAtEpochMs = e.endedAtEpochMs,
        firstReasoningMs = e.firstReasoningMs,
        firstContentMs = e.firstContentMs,
        lastOutputMs = e.lastOutputMs,
        durationMs = e.durationMs,
        outputChunkCount = e.outputChunkCount,
        isStreamed = e.isStreamed,
        promptTokens = e.promptTokens,
        completionTokens = e.completionTokens,
        cachedTokens = e.cachedTokens,
        cacheWriteTokens = e.cacheWriteTokens,
        httpStatus = e.httpStatus,
        inputPricePerMillion = e.inputPricePerMillion,
        outputPricePerMillion = e.outputPricePerMillion,
        cacheReadPricePerMillion = e.cacheReadPricePerMillion,
        cacheWritePricePerMillion = e.cacheWritePricePerMillion,
        currency = e.currency
    )

    companion object {
        const val MEDIA_TURNS_TO_KEEP = 2

        fun readyTargets(providers: List<ProviderItem>): List<ResolvedModelTarget> =
            providers.filter { it.hasConfiguredChatAPI }.flatMap { p ->
                p.enabledModels.map { p.makeTarget(it) }
            }

        fun buildPromptHistory(messages: List<ChatMessageItem>, limit: Int): List<LLMPromptMessage> {
            val collapsed = mutableListOf<ChatMessageItem>()
            val processedGroups = HashSet<String>()

            for (msg in messages) {
                if (msg.role == MessageRole.SYSTEM) continue
                val gid = msg.comparisonGroupID
                if (gid != null) {
                    if (!processedGroups.add(gid)) continue
                    val candidates = messages.filter { c ->
                        c.comparisonGroupID == gid &&
                            (c.content.isNotEmpty() || c.attachments.isNotEmpty()) &&
                            (!c.isSynthesis || (ArenaSynthesis.isComplete(c) && ArenaSynthesis.isCurrent(c, messages)))
                    }
                    val winner = candidates.firstOrNull { it.isSelectedInGroup }
                        ?: candidates.firstOrNull { !it.isSynthesis }
                        ?: candidates.firstOrNull()
                    if (winner != null) collapsed.add(winner)
                } else {
                    if (msg.role == MessageRole.ASSISTANT && msg.content.isEmpty() && msg.attachments.isEmpty()) {
                        continue
                    }
                    collapsed.add(msg)
                }
            }

            val sliced = if (limit > 0 && collapsed.size > limit) {
                collapsed.takeLast(limit)
            } else {
                collapsed
            }

            var mediaTurnsKept = 0
            val historyReversed = mutableListOf<LLMPromptMessage>()
            for (msg in sliced.asReversed()) {
                var atts = msg.attachments
                if (atts.any { it.dataBase64 != null }) {
                    if (mediaTurnsKept < MEDIA_TURNS_TO_KEEP) {
                        mediaTurnsKept++
                    } else {
                        atts = atts.map(::textOnlyVersion)
                    }
                }
                historyReversed.add(
                    LLMPromptMessage(
                        role = msg.role,
                        content = msg.content,
                        attachments = atts
                    )
                )
            }
            return historyReversed.asReversed()
        }

        private fun textOnlyVersion(att: MessageAttachment): MessageAttachment {
            return if (att.kind == AttachmentKind.IMAGE) {
                att.copy(kind = AttachmentKind.DOCUMENT, dataBase64 = null, extractedText = null)
            } else {
                att.copy(dataBase64 = null)
            }
        }

        fun makeConversationTitle(text: String, attachments: List<MessageAttachment>): String {
            val oneLine = text.replace("\n", " ").trim()
            if (oneLine.isNotEmpty()) {
                return if (oneLine.length > 22) oneLine.take(22) + "…" else oneLine
            }
            val first = attachments.firstOrNull()
            if (first != null) {
                return if (first.kind == AttachmentKind.IMAGE) {
                    L10n.text("识图：${first.fileName}", "Image: ${first.fileName}")
                } else {
                    L10n.text("文档：${first.fileName}", "Doc: ${first.fileName}")
                }
            }
            return ConversationItem.defaultTitle
        }
    }
}
