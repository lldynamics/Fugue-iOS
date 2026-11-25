package com.iosbox.app.core.backup

import androidx.room.withTransaction
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookManuscript
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.RequestMetrics
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.model.PreparedBook
import com.iosbox.app.core.model.StudyFlashcard
import com.iosbox.app.core.security.SecretStore
import com.iosbox.app.core.storage.AssistantPresetEntity
import com.iosbox.app.core.storage.AttachmentProcessor
import com.iosbox.app.core.storage.BookVolumeEntity
import com.iosbox.app.core.storage.ChatMessageEntity
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ChatDraftStore
import com.iosbox.app.core.storage.ConversationEntity
import com.iosbox.app.core.storage.ExternalBlobStore
import com.iosbox.app.core.storage.FugueDatabase
import com.iosbox.app.core.storage.FlashcardRepository
import com.iosbox.app.core.storage.PersonalMemoryEntity
import com.iosbox.app.core.storage.PersonaProfileEntity
import com.iosbox.app.core.storage.ProjectKnowledgeSearch
import com.iosbox.app.core.storage.ProviderEntity
import com.iosbox.app.core.storage.RequestRecordEntity
import com.iosbox.app.core.storage.RestoreBlobBatch
import com.iosbox.app.core.storage.ShelfReadingStateEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URI

class BackupRepository(
    private val db: FugueDatabase,
    private val blobStore: ExternalBlobStore,
    private val secretStore: SecretStore,
    private val flashcardRepository: FlashcardRepository,
    private val appVersion: String = "1.0.0",
    private val draftStore: ChatDraftStore? = null,
    private val tombstoneStore: SyncTombstoneStore? = null
) {
    private val codec = BackupJson.codec
    private val prettyCodec = BackupJson.prettyCodec

    suspend fun exportPlainJsonBytes(): ByteArray = withContext(Dispatchers.IO) {
        val archive = makeArchive()
        val encoded = prettyCodec.encodeToString(BackupArchive.serializer(), archive)
            .toByteArray(Charsets.UTF_8)
        if (encoded.size > EncryptedBackupCrypto.MAXIMUM_FILE_BYTES) {
            throw BackupException.FileTooLarge()
        }
        encoded
    }

    suspend fun exportEncryptedJsonBytes(password: String): ByteArray = withContext(Dispatchers.IO) {
        if (!EncryptedBackupCrypto.isValidExportPassword(password)) {
            throw BackupException.EmptyPassword()
        }
        val payload = makeFullEncryptedPayload()
        EncryptedBackupCrypto.encryptPayload(payload, password)
    }

    suspend fun makeArchive(
        tombstoneStore: SyncTombstoneStore? = this.tombstoneStore
    ): BackupArchive = withContext(Dispatchers.IO) {
        val providers = db.providerDao().getAll()
        val presets = db.assistantPresetDao().getAll()
        val conversations = db.conversationDao().getAll()
        val allMessages = db.chatMessageDao().getAll().groupBy { it.conversationID }
        val requests = db.requestRecordDao().getAllAsc()
        val memories = db.personalMemoryDao().getAll()
        val books = db.bookVolumeDao().getAll()
        val profiles = db.personaProfileDao().getAll()
        val shelfStates = db.shelfReadingStateDao().getAll()

        val flashcards: List<JsonElement>? = blobStore.readText(FLASHCARDS_BLOB_KEY)?.let { raw ->
            runCatching { codec.decodeFromString<List<JsonElement>>(raw) }.getOrNull()
        }

        val providerBackups = providers.map { p ->
            val models = runCatching { codec.decodeFromString<List<ModelSpec>>(p.modelsJson) }.getOrDefault(emptyList())
            val headers = runCatching { codec.decodeFromString<List<CustomHeader>>(p.headersJson) }.getOrDefault(emptyList())
                .map { h ->
                    if (h.isSecret || CustomHeader.looksSensitive(h.key)) {
                        h.copy(isSecret = true, value = "")
                    } else {
                        h
                    }
                }
            ProviderBackup(
                id = p.id,
                name = p.name,
                protocolRaw = p.protocolRaw,
                baseURL = portableBaseURL(p.baseURL),
                iconSymbol = p.iconSymbol,
                accentHex = p.accentHex,
                isEnabled = p.isEnabled,
                sortOrder = p.sortOrder,
                models = models,
                customHeaders = headers,
                notes = p.notes
            )
        }

        val presetBackups = presets.map { p ->
            val volumeIDs = p.knowledgeVolumeIDsJson?.let {
                runCatching { codec.decodeFromString<List<String>>(it) }.getOrNull()
            }
            PresetBackup(
                id = p.id,
                name = p.name,
                iconEmoji = p.iconEmoji,
                subtitle = p.subtitle,
                systemPrompt = p.systemPrompt,
                temperature = p.temperature,
                useCustomTemperature = p.useCustomTemperature,
                topP = p.topP,
                maxOutputTokens = p.maxOutputTokens,
                contextMessageLimit = p.contextMessageLimit,
                enableThinking = p.enableThinking,
                thinkingBudgetTokens = p.thinkingBudgetTokens,
                isBuiltIn = p.isBuiltIn,
                sortOrder = p.sortOrder,
                knowledgeVolumeIDs = volumeIDs?.takeIf { it.isNotEmpty() }
            )
        }

        val conversationBackups = conversations.map { c ->
            val primaryTarget = c.primaryTargetJson.takeIf { it.isNotBlank() && it != "null" }?.let {
                runCatching { codec.decodeFromString<ResolvedModelTarget>(it) }.getOrNull()
            }
            val arenaTargets = c.arenaTargetsJson.takeIf { it.isNotBlank() }?.let {
                runCatching { codec.decodeFromString<List<ResolvedModelTarget>>(it) }.getOrNull()
            } ?: emptyList()
            val assistanceSettings = blobStore.readText(c.assistanceSettingsBlobKey)?.let {
                runCatching { codec.parseToJsonElement(it) }.getOrNull()
            }
            val organizationEdits = c.organizationEditsJson?.let {
                runCatching { codec.parseToJsonElement(it) }.getOrNull()
            }
            val messages = (allMessages[c.id] ?: emptyList())
                .sortedWith(compareBy<ChatMessageEntity> { it.sortIndex }.thenBy { it.createdAtEpochMs })
                .map { m ->
                    val attachments = blobStore.readText(m.attachmentsBlobKey)?.let {
                        runCatching { codec.decodeFromString<List<MessageAttachment>>(it) }.getOrNull()
                    } ?: emptyList()
                    val metadata = blobStore.readText(m.assistanceMetadataBlobKey)?.let {
                        runCatching { codec.parseToJsonElement(it) }.getOrNull()
                    }
                    MessageBackup(
                        id = m.id,
                        role = m.roleRaw,
                        content = m.content,
                        reasoningContent = m.reasoningContent,
                        attachments = attachments,
                        providerID = m.providerID,
                        providerName = m.providerName,
                        modelID = m.modelID,
                        modelDisplayName = m.modelDisplayName,
                        accentHex = m.accentHex,
                        comparisonGroupID = m.comparisonGroupID,
                        isSelectedInGroup = m.isSelectedInGroup,
                        errorMessage = m.errorMessage?.let { "请求失败，详细错误仅保留在原设备。" },
                        finishReason = m.finishReason,
                        promptTokens = m.promptTokens,
                        completionTokens = m.completionTokens,
                        cachedTokens = m.cachedTokens,
                        latencyMs = m.latencyMs,
                        thinkingDurationMs = m.thinkingDurationMs,
                        synthesisSourceDigest = m.synthesisSourceDigest,
                        latestRequestID = m.latestRequestID,
                        assistanceMetadata = metadata,
                        parentMessageID = m.parentMessageID,
                        sortIndex = m.sortIndex,
                        createdAt = m.createdAtEpochMs
                    )
                }
            ConversationBackup(
                id = c.id,
                title = c.title,
                isPinned = c.isPinned,
                assistantID = c.assistantID,
                assistantEmoji = c.assistantEmoji,
                systemPrompt = c.systemPrompt,
                temperature = c.temperature,
                useCustomTemperature = c.useCustomTemperature,
                topP = c.topP,
                maxOutputTokens = c.maxOutputTokens,
                contextMessageLimit = c.contextMessageLimit,
                enableThinking = c.enableThinking,
                thinkingBudgetTokens = c.thinkingBudgetTokens,
                isArenaMode = c.isArenaMode,
                primaryTarget = primaryTarget,
                arenaTargets = arenaTargets,
                assistanceSettings = assistanceSettings,
                activeLeafMessageID = c.activeLeafMessageID,
                folderTag = c.folderTag,
                createdAt = c.createdAtEpochMs,
                updatedAt = c.updatedAtEpochMs,
                messages = messages,
                organizationEdits = organizationEdits,
                legacyImportID = c.legacyImportID
            )
        }

        val requestSnapshots = requests.map { r ->
            RequestRecordSnapshot(
                id = r.id,
                operationID = r.operationID,
                attempt = r.attempt,
                conversationID = r.conversationID,
                messageID = r.messageID,
                providerID = r.providerID,
                providerName = r.providerName,
                modelID = r.modelID,
                modelDisplayName = r.modelDisplayName,
                protocolRaw = r.protocolRaw,
                kindRaw = r.kindRaw,
                statusRaw = r.statusRaw,
                startedAt = r.startedAtEpochMs,
                endedAt = r.endedAtEpochMs,
                firstReasoningMs = r.firstReasoningMs,
                firstContentMs = r.firstContentMs,
                lastOutputMs = r.lastOutputMs,
                durationMs = r.durationMs,
                outputChunkCount = r.outputChunkCount,
                isStreamed = r.isStreamed,
                promptTokens = r.promptTokens,
                completionTokens = r.completionTokens,
                cachedTokens = r.cachedTokens,
                cacheWriteTokens = r.cacheWriteTokens,
                httpStatus = r.httpStatus,
                inputPricePerMillion = r.inputPricePerMillion,
                outputPricePerMillion = r.outputPricePerMillion,
                cacheReadPricePerMillion = r.cacheReadPricePerMillion,
                cacheWritePricePerMillion = r.cacheWritePricePerMillion,
                currency = r.currency
            )
        }

        val memorySnapshots = memories.map { m ->
            PersonalMemorySnapshot(
                id = m.id,
                content = m.content,
                isEnabled = m.isEnabled,
                createdAt = m.createdAtEpochMs
            )
        }

        val bookSnapshots = books.mapNotNull { b ->
            val raw = blobStore.readText(b.manuscriptBlobKey) ?: return@mapNotNull null
            val chapters = runCatching { codec.decodeFromString<List<BookChapterSnapshot>>(raw) }.getOrNull()
                ?: return@mapNotNull null
            BookVolumeSnapshot(
                id = b.id,
                title = b.title,
                chapters = chapters,
                importedAt = b.importedAtEpochMs
            )
        }

        val profileElements = profiles.mapNotNull { p ->
            blobStore.readText(p.payloadBlobKey)?.let { raw ->
                runCatching { codec.parseToJsonElement(raw) }.getOrNull()
            }
        }

        val shelfSnapshots = shelfStates.map { s ->
            ShelfPositionSnapshot(
                bookID = s.bookID,
                conversationID = s.conversationID,
                chapter = s.chapter,
                paragraph = s.paragraph
            )
        }

        val tombstones = tombstoneStore?.allTombstones()?.takeIf { it.isNotEmpty() }

        BackupArchive(
            formatVersion = BackupArchive.CURRENT_FORMAT_VERSION,
            exportedAt = System.currentTimeMillis(),
            appVersion = appVersion,
            providers = providerBackups,
            presets = presetBackups,
            conversations = conversationBackups,
            requests = requestSnapshots,
            memories = memorySnapshots,
            books = bookSnapshots,
            flashcards = flashcards?.takeIf { it.isNotEmpty() },
            personaProfiles = profileElements.takeIf { it.isNotEmpty() },
            shelfPositions = shelfSnapshots.takeIf { it.isNotEmpty() },
            tombstones = tombstones
        )
    }

    suspend fun makeFullEncryptedPayload(
        tombstoneStore: SyncTombstoneStore? = this.tombstoneStore
    ): FullEncryptedPayload = withContext(Dispatchers.IO) {
        val archive = makeArchive(tombstoneStore = tombstoneStore)
        val providers = db.providerDao().getAll()
        val bundles = providers.map { p ->
            val headers = runCatching { codec.decodeFromString<List<CustomHeader>>(p.headersJson) }.getOrDefault(emptyList())
            val headerSecrets = HashMap<String, String>()
            for (header in headers) {
                if (header.isSecret) {
                    val secret = secretStore.loadSecret(SecretStore.headerAccount(p.id, header.id))
                    if (secret.isNotEmpty()) headerSecrets[header.id.uppercase()] = secret
                } else if (CustomHeader.looksSensitive(header.key) && header.value.isNotEmpty()) {
                    headerSecrets[header.id.uppercase()] = header.value
                }
            }
            val extras = secretStore.loadExtraAPIKeys(p.id)
            val customTimeout = secretStore.loadIdleTimeoutSeconds(p.id)
            ProviderSecretBundle(
                providerID = p.id,
                rawBaseURL = p.baseURL,
                isEnabled = p.isEnabled,
                apiKey = secretStore.loadAPIKey(p.id),
                extraAPIKeys = extras.takeIf { it.isNotEmpty() },
                idleTimeoutSeconds = customTimeout.takeIf { it > 0 },
                secretHeaders = headerSecrets
            )
        }
        val tavilyKey = secretStore.loadSecret(SecretStore.TAVILY_KEY_ACCOUNT)
        val xToken = secretStore.loadSecret(SecretStore.PERSONA_X_TOKEN_ACCOUNT)
        FullEncryptedPayload(
            archive = archive,
            providerSecrets = bundles,
            tavilyAPIKey = tavilyKey,
            personaXBearerToken = xToken.takeIf { it.isNotEmpty() }
        )
    }

    suspend fun localBookSnapshots(): Map<String, BookVolumeSnapshot> = withContext(Dispatchers.IO) {
        val result = HashMap<String, BookVolumeSnapshot>()
        for (b in db.bookVolumeDao().getAll()) {
            val raw = blobStore.readText(b.manuscriptBlobKey) ?: continue
            val chapters = runCatching { codec.decodeFromString<List<BookChapterSnapshot>>(raw) }.getOrNull()
                ?: continue
            result[b.id.uppercase()] = BookVolumeSnapshot(
                id = b.id,
                title = b.title,
                chapters = chapters,
                importedAt = b.importedAtEpochMs
            )
        }
        result
    }

    suspend fun localAttachmentBlobs(): Map<String, ByteArray> = withContext(Dispatchers.IO) {
        val result = HashMap<String, ByteArray>()
        for (m in db.chatMessageDao().getAll()) {
            val attRaw = m.attachmentsBlobKey?.let { blobStore.readText(it) }
            if (attRaw != null) {
                val atts = runCatching { codec.decodeFromString<List<MessageAttachment>>(attRaw) }.getOrDefault(emptyList())
                for (att in atts) {
                    val b64 = att.dataBase64 ?: continue
                    val raw = b64.toByteArray(Charsets.UTF_8)
                    if (raw.size >= WebDAVPayloadSharder.ATTACHMENT_SHARD_THRESHOLD_BYTES) {
                        result[WebDAVPayloadSharder.sha256Hex(raw)] = raw
                    }
                }
            }
            val metaRaw = m.assistanceMetadataBlobKey?.let { blobStore.readText(it) }
            if (metaRaw != null) {
                val revisions = (runCatching { codec.parseToJsonElement(metaRaw) }.getOrNull() as? JsonObject)
                    ?.get("revisions") as? JsonArray
                if (revisions != null) {
                    for (revEl in revisions) {
                        val atts = (revEl as? JsonObject)?.get("attachments") as? JsonArray ?: continue
                        for (attEl in atts) {
                            val b64 = ((attEl as? JsonObject)?.get("dataBase64") as? JsonPrimitive)
                                ?.takeIf { it.isString }?.content ?: continue
                            val raw = b64.toByteArray(Charsets.UTF_8)
                            if (raw.size >= WebDAVPayloadSharder.ATTACHMENT_SHARD_THRESHOLD_BYTES) {
                                result[WebDAVPayloadSharder.sha256Hex(raw)] = raw
                            }
                        }
                    }
                }
            }
        }
        result
    }

    suspend fun importPlainJsonBytes(data: ByteArray): ImportSummary = withContext(Dispatchers.IO) {
        if (data.size > EncryptedBackupCrypto.MAXIMUM_FILE_BYTES) throw BackupException.FileTooLarge()
        val archive = decodePlainArchive(data)
        applyArchive(archive)
    }

    suspend fun importEncryptedBytes(
        data: ByteArray,
        password: String,
        tombstonePolicy: SyncTombstonePolicy = SyncTombstonePolicy.Ignore
    ): ImportSummary = withContext(Dispatchers.IO) {
        val payload = EncryptedBackupCrypto.decryptPayload(data, password)
        applyEncryptedPayload(payload, tombstonePolicy = tombstonePolicy)
    }

    fun decodePlainArchive(data: ByteArray): BackupArchive {
        EncryptedBackupCrypto.requireImportSize(data.size)
        val text = data.toString(Charsets.UTF_8)
        val archive = runCatching { codec.decodeFromString<BackupArchive>(text) }.getOrNull()
        if (archive != null) {
            if (archive.formatVersion > BackupArchive.CURRENT_FORMAT_VERSION) {
                throw BackupException.NewerFormat(archive.formatVersion)
            }
            return archive
        }
        @kotlinx.serialization.Serializable
        data class Probe(val formatVersion: Int)
        val probe = runCatching { codec.decodeFromString<Probe>(text) }.getOrNull()
        if (probe != null && probe.formatVersion > BackupArchive.CURRENT_FORMAT_VERSION) {
            throw BackupException.NewerFormat(probe.formatVersion)
        }
        throw BackupException.UnrecognizedFormat()
    }

    suspend fun applyEncryptedPayload(
        payload: FullEncryptedPayload,
        tombstonePolicy: SyncTombstonePolicy = SyncTombstonePolicy.Ignore
    ): ImportSummary = withContext(Dispatchers.IO) {
        if (payload.providerSecrets.map { it.providerID.uppercase() }.toSet().size != payload.providerSecrets.size) {
            throw BackupException.ConflictingIDs()
        }
        val bundles = payload.providerSecrets.associateBy { it.providerID.uppercase() }
        val patchedProviders = payload.archive.providers.map { p ->
            if (p.baseURL.isBlank()) {
                val bundle = bundles[p.id.uppercase()]
                if (bundle != null && isValidDestination(bundle.rawBaseURL)) {
                    p.copy(baseURL = bundle.rawBaseURL)
                } else {
                    p
                }
            } else {
                p
            }
        }
        val patchedArchive = payload.archive.copy(providers = patchedProviders)
        val baseSummary = applyArchive(patchedArchive, tombstonePolicy = tombstonePolicy)

        val archivedProviders = patchedArchive.providers.associateBy { it.id.uppercase() }
        val localProviders = db.providerDao().getAll().associateBy { it.id.uppercase() }
        val enforcedStore = (tombstonePolicy as? SyncTombstonePolicy.Enforce)?.store

        var confirmedCredentials = 0
        var failedCredentialWrites = 0
        val conflicts = mutableListOf<String>()

        fun restore(value: String, account: String) {
            if (value.isEmpty()) return
            if (secretStore.restoreSecretIfMissing(value, account)) confirmedCredentials++
            else failedCredentialWrites++
        }

        for (bundle in payload.providerSecrets) {
            val id = bundle.providerID.uppercase()
            val raw = bundle.rawBaseURL.trim()
            val source = archivedProviders[id]
            val local = localProviders[id]
            if (local == null && enforcedStore?.latestDeletion(SyncEntityKinds.PROVIDER, id) != null) {
                continue
            }
            val matchesDestination = source != null && local != null &&
                APIProtocolType.entries.any { it.rawValue == source.protocolRaw } &&
                local.protocolRaw == source.protocolRaw &&
                isValidDestination(raw) &&
                source.baseURL.trim() == raw &&
                local.baseURL.trim() == raw

            if (!matchesDestination) {
                if (bundle.apiKey.isNotEmpty() || !bundle.extraAPIKeys.isNullOrEmpty() || bundle.secretHeaders.isNotEmpty()) {
                    conflicts.add(local?.name ?: source?.name ?: bundle.providerID)
                }
                continue
            }

            restore(bundle.apiKey, id)
            val extraKeys = bundle.extraAPIKeys?.let { SecretStore.deduplicateKeys(it) }.orEmpty()
            if (extraKeys.isNotEmpty()) {
                restore(codec.encodeToString(extraKeys), SecretStore.extraKeysAccount(id))
            }
            val timeout = bundle.idleTimeoutSeconds
            if (timeout != null && timeout > 0 && secretStore.loadIdleTimeoutSeconds(id) == 0) {
                secretStore.saveIdleTimeoutSeconds(id, timeout)
            }

            var headerConflict = false
            val localHeaders = runCatching { codec.decodeFromString<List<CustomHeader>>(local.headersJson) }.getOrDefault(emptyList())
            for ((headerKeyRaw, value) in bundle.secretHeaders) {
                if (value.isEmpty()) continue
                val headerID = headerKeyRaw.uppercase()
                val original = source.customHeaders.firstOrNull { it.id.uppercase() == headerID && it.isSecret }
                val localMatch = original != null && localHeaders.any {
                    it.id.uppercase() == headerID && it.isSecret && it.key.equals(original.key, ignoreCase = true)
                }
                if (!localMatch) {
                    headerConflict = true
                    continue
                }
                restore(value, SecretStore.headerAccount(id, headerID))
            }
            if (headerConflict) conflicts.add(local.name)
        }

        restore(payload.tavilyAPIKey, SecretStore.TAVILY_KEY_ACCOUNT)
        restore(payload.personaXBearerToken ?: "", SecretStore.PERSONA_X_TOKEN_ACCOUNT)

        baseSummary.copy(
            confirmedCredentials = confirmedCredentials,
            failedCredentialWrites = failedCredentialWrites,
            credentialConflicts = conflicts
        )
    }

    internal suspend fun reconcileRestoreBlobs() = withContext(Dispatchers.IO) {
        db.withTransaction {
            val referenced = db.conversationDao().getRestoreBlobKeys().toSet()
            RestoreBlobBatch.reconcile(blobStore, referenced)
        }
    }

    private suspend fun importWithStagedBlobs(write: suspend (RestoreBlobBatch) -> Unit) {
        val batch = RestoreBlobBatch(blobStore)
        try {
            db.withTransaction { write(batch) }
        } catch (failure: Exception) {
            // SQLite might have committed just before cancellation. Keep any keys it actually published.
            withContext(NonCancellable) { runCatching { reconcileRestoreBlobs() } }
            throw failure
        }
    }

    suspend fun applyArchive(
        archive: BackupArchive,
        tombstonePolicy: SyncTombstonePolicy = SyncTombstonePolicy.Ignore
    ): ImportSummary = withContext(Dispatchers.IO) {
        if (archive.conversations.any { it.messages.size > MAX_IMPORTED_MESSAGES_PER_CONVERSATION }) {
            throw BackupException.ConversationMessageLimit()
        }
        val incomingMessages = archive.conversations.flatMap { it.messages }
        val incomingRequests = archive.requests.orEmpty()
        val incomingMemories = archive.memories.orEmpty()
        val incomingBooks = archive.books.orEmpty()
        val preparedBooks = incomingBooks.associate { it.id.uppercase() to prepareRestoredBook(it) }
        val incomingCards = decodeRestoredFlashcards(archive.flashcards.orEmpty())
        val incomingProfiles = archive.personaProfiles.orEmpty().map { value ->
            val profile = value as? JsonObject ?: throw BackupException.UnrecognizedFormat()
            val rawID = (profile["id"] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val id = ChatRepository.canonicalConversationID(rawID) ?: throw BackupException.UnrecognizedFormat()
            val linkedId = profile["profileID"]
            if (linkedId != null && linkedId != JsonNull &&
                ChatRepository.canonicalConversationID((linkedId as? JsonPrimitive)?.takeIf { it.isString }?.content) != id) {
                throw BackupException.UnrecognizedFormat()
            }
            id to restoredMember(JsonObject(profile + mapOf("id" to JsonPrimitive(id), "profileID" to JsonPrimitive(id))))
        }

        fun <T> hasUnique(items: List<T>, selector: (T) -> String): Boolean =
            items.map { selector(it).uppercase() }.toSet().size == items.size

        if (!hasUnique(archive.providers) { it.id } ||
            !hasUnique(archive.presets) { it.id } ||
            !hasUnique(archive.conversations) { it.id } ||
            !hasUnique(incomingMessages) { it.id } ||
            !hasUnique(incomingRequests) { it.id } ||
            !hasUnique(incomingMemories) { it.id } ||
            !hasUnique(incomingBooks) { it.id } ||
            !hasUnique(incomingProfiles) { it.first }
        ) {
            throw BackupException.ConflictingIDs()
        }

        for (mem in incomingMemories) {
            if (mem.content.trim().isEmpty() || mem.content.length > 500) {
                throw BackupException.UnrecognizedFormat()
            }
        }

        val now = System.currentTimeMillis()
        val enforcedStore = (tombstonePolicy as? SyncTombstonePolicy.Enforce)?.store
        val incomingTombstones = archive.tombstones.orEmpty()
        val effectiveTombstones: Map<SyncTombstoneKey, Long> = if (enforcedStore != null) {
            val merged = HashMap(enforcedStore.tombstoneMap(now))
            val cutoff = now - SyncTombstoneStore.RETENTION_MS
            for (item in incomingTombstones) {
                if (item.deletedAt < cutoff) continue
                val k = item.key
                val prev = merged[k]
                if (prev == null || item.deletedAt > prev) {
                    merged[k] = item.deletedAt
                }
            }
            merged
        } else {
            emptyMap()
        }
        val tombstonesToClear = mutableListOf<SyncTombstoneKey>()

        fun isBlockedByTombstone(kind: String, id: String, entityTimestampMs: Long): Boolean {
            if (enforcedStore == null) return false
            val key = SyncTombstoneKey(kind, id.uppercase())
            val deletedAt = effectiveTombstones[key] ?: return false
            if (entityTimestampMs > deletedAt) {
                tombstonesToClear.add(key)
                return false
            }
            return true
        }

        var providersCount = 0
        var presetsCount = 0
        var conversationsCount = 0
        var restoredConversationsCount = 0
        var messagesCount = 0
        var requestsCount = 0
        var memoriesCount = 0
        var booksCount = 0
        var skippedCount = 0
        var deletedCount = 0

        val blobsToDeleteAfterCommit = mutableListOf<String>()
        val providersToPurgeSecrets = mutableListOf<Pair<String, List<String>>>()
        val invalidatedBookIDs = mutableListOf<String>()
        val draftsToRemove = mutableListOf<String>()

        importWithStagedBlobs { staged ->
            draftStore?.migrateLegacy(db.conversationDao().getIDs())
            val existingProviders = db.providerDao().getAll().associateBy { it.id.uppercase() }
            val existingPresets = db.assistantPresetDao().getAll().associateBy { it.id.uppercase() }
            val existingConversations = db.conversationDao().getAll().associateBy { it.id.uppercase() }
            val existingMessages = db.chatMessageDao().getAll().associateBy { it.id.uppercase() }
            val existingMessageCounts = existingMessages.values.groupingBy { it.conversationID.uppercase() }.eachCount()
            val existingRequests = db.requestRecordDao().getAllAsc().associateBy { it.id.uppercase() }
            val existingMemoriesMap = db.personalMemoryDao().getAll().associateBy { it.id.uppercase() }
            val existingBooksMap = db.bookVolumeDao().getAll().associateBy { it.id.uppercase() }
            val existingProfilesMap = db.personaProfileDao().getAll().associateBy { it.id.uppercase() }

            for (conv in archive.conversations) {
                if (ChatRepository.canonicalConversationID(conv.id) == null && conv.id.uppercase() !in existingConversations) {
                    throw BackupException.UnrecognizedFormat()
                }
                var addedCount = 0
                for (msg in conv.messages) {
                    val localMsg = existingMessages[msg.id.uppercase()]
                    if (localMsg != null && !localMsg.conversationID.equals(conv.id, ignoreCase = true)) {
                        throw BackupException.ConflictingIDs()
                    }
                    if (localMsg == null) {
                        if (ChatRepository.canonicalConversationID(msg.id) == null) throw BackupException.UnrecognizedFormat()
                        addedCount++
                    }
                }
                if (addedCount > 0 && addedCount > MAX_IMPORTED_MESSAGES_PER_CONVERSATION - (existingMessageCounts[conv.id.uppercase()] ?: 0)) {
                    throw BackupException.ConversationMessageLimit()
                }
            }

            // 1. Propagate tombstones to local records when enforcing sync policy
            val deletedBookIDs = HashSet<String>()
            val deletedConvIDs = HashSet<String>()
            val deletedMemIDs = HashSet<String>()
            val deletedProviderIDs = HashSet<String>()
            val deletedPresetIDs = HashSet<String>()
            val deletedProfileIDs = HashSet<String>()

            if (enforcedStore != null && effectiveTombstones.isNotEmpty()) {
                for ((id, conv) in existingConversations) {
                    val deletedAt = effectiveTombstones[SyncTombstoneKey(SyncEntityKinds.CONVERSATION, id)] ?: continue
                    if (conv.updatedAtEpochMs > deletedAt) {
                        tombstonesToClear.add(SyncTombstoneKey(SyncEntityKinds.CONVERSATION, id))
                    } else {
                        for (m in db.chatMessageDao().getByConversation(id)) {
                            m.attachmentsBlobKey?.let(blobsToDeleteAfterCommit::add)
                            m.assistanceMetadataBlobKey?.let(blobsToDeleteAfterCommit::add)
                        }
                        conv.assistanceSettingsBlobKey?.let(blobsToDeleteAfterCommit::add)
                        draftsToRemove.add(id)
                        db.conversationDao().deleteById(id)
                        deletedConvIDs.add(id)
                        deletedCount++
                    }
                }
                for ((id, mem) in existingMemoriesMap) {
                    val deletedAt = effectiveTombstones[SyncTombstoneKey(SyncEntityKinds.MEMORY, id)] ?: continue
                    if (mem.createdAtEpochMs > deletedAt) {
                        tombstonesToClear.add(SyncTombstoneKey(SyncEntityKinds.MEMORY, id))
                    } else {
                        db.personalMemoryDao().deleteById(id)
                        deletedMemIDs.add(id)
                        deletedCount++
                    }
                }
                for ((id, book) in existingBooksMap) {
                    val deletedAt = effectiveTombstones[SyncTombstoneKey(SyncEntityKinds.BOOK, id)] ?: continue
                    if (book.importedAtEpochMs > deletedAt) {
                        tombstonesToClear.add(SyncTombstoneKey(SyncEntityKinds.BOOK, id))
                    } else {
                        blobsToDeleteAfterCommit.add(book.manuscriptBlobKey)
                        db.shelfReadingStateDao().deleteByBookId(id)
                        db.bookVolumeDao().deleteById(id)
                        invalidatedBookIDs.add(id)
                        deletedBookIDs.add(id)
                        deletedCount++
                    }
                }
                for ((id, profile) in existingProfilesMap) {
                    val deletedAt = effectiveTombstones[SyncTombstoneKey(SyncEntityKinds.PERSONA_PROFILE, id)] ?: continue
                    if (profile.updatedAtEpochMs > deletedAt) {
                        tombstonesToClear.add(SyncTombstoneKey(SyncEntityKinds.PERSONA_PROFILE, id))
                    } else {
                        blobsToDeleteAfterCommit.add(profile.payloadBlobKey)
                        db.personaProfileDao().deleteById(id)
                        deletedProfileIDs.add(id)
                        deletedCount++
                    }
                }
                for ((id, provider) in existingProviders) {
                    val deletedAt = effectiveTombstones[SyncTombstoneKey(SyncEntityKinds.PROVIDER, id)] ?: continue
                    if (provider.updatedAtEpochMs > deletedAt) {
                        tombstonesToClear.add(SyncTombstoneKey(SyncEntityKinds.PROVIDER, id))
                    } else {
                        val headerIDs = runCatching {
                            codec.decodeFromString<List<CustomHeader>>(provider.headersJson).map { it.id }
                        }.getOrDefault(emptyList())
                        providersToPurgeSecrets.add(id to headerIDs)
                        db.providerDao().deleteById(id)
                        deletedProviderIDs.add(id)
                        deletedCount++
                    }
                }
                for ((id, preset) in existingPresets) {
                    val deletedAt = effectiveTombstones[SyncTombstoneKey(SyncEntityKinds.PRESET, id)] ?: continue
                    if (preset.createdAtEpochMs > deletedAt) {
                        tombstonesToClear.add(SyncTombstoneKey(SyncEntityKinds.PRESET, id))
                    } else {
                        db.assistantPresetDao().deleteById(id)
                        deletedPresetIDs.add(id)
                        deletedCount++
                    }
                }
            }

            // 2. Insert incoming entities (skipping anything blocked by an effective tombstone)
            val booksToInsert = mutableListOf<BookVolumeEntity>()
            for (b in incomingBooks) {
                val id = b.id.uppercase()
                if (existingBooksMap.containsKey(id) && id !in deletedBookIDs) continue
                if (isBlockedByTombstone(SyncEntityKinds.BOOK, id, b.importedAt)) {
                    skippedCount++
                    continue
                }
                val prepared = preparedBooks.getValue(id)
                val key = staged.writeText(prepared.encodedJson)
                booksToInsert.add(
                    BookVolumeEntity(
                        id = id,
                        title = b.title,
                        chapterTitlesJson = codec.encodeToString(prepared.chapterTitles),
                        manuscriptBlobKey = key,
                        byteCount = prepared.byteCount,
                        importedAtEpochMs = b.importedAt
                    )
                )
                booksCount++
            }
            for (book in booksToInsert) db.bookVolumeDao().upsert(book)

            if (incomingProfiles.isNotEmpty()) {
                val toInsert = incomingProfiles.mapNotNull { (id, profile) ->
                    if (existingProfilesMap.containsKey(id) && id !in deletedProfileIDs) return@mapNotNull null
                    if (isBlockedByTombstone(SyncEntityKinds.PERSONA_PROFILE, id, archive.exportedAt)) {
                        skippedCount++
                        return@mapNotNull null
                    }
                    val key = staged.writeText(codec.encodeToString(JsonObject.serializer(), profile))
                    PersonaProfileEntity(id = id, payloadBlobKey = key, updatedAtEpochMs = now)
                }
                if (toInsert.isNotEmpty()) db.personaProfileDao().upsertAll(toInsert)
            }

            val shelfPositions = archive.shelfPositions.orEmpty()
            if (shelfPositions.isNotEmpty()) {
                val existingShelf = db.shelfReadingStateDao().getAll().map { it.bookID.uppercase() }.toSet()
                val toInsert = shelfPositions.mapNotNull { pos ->
                    val bid = pos.bookID.uppercase()
                    if (existingShelf.contains(bid) || bid in deletedBookIDs) null
                    else if (enforcedStore != null && effectiveTombstones.containsKey(SyncTombstoneKey(SyncEntityKinds.BOOK, bid))) null
                    else ShelfReadingStateEntity(bid, pos.conversationID?.uppercase(), pos.chapter, pos.paragraph)
                }
                if (toInsert.isNotEmpty()) db.shelfReadingStateDao().upsertAll(toInsert)
            }

            val requestsToInsert = incomingRequests.filter { !existingRequests.containsKey(it.id.uppercase()) }
                .map { s ->
                    requestsCount++
                    RequestRecordEntity(
                        id = s.id.uppercase(),
                        operationID = s.operationID.uppercase(),
                        attempt = s.attempt,
                        conversationID = s.conversationID.uppercase(),
                        messageID = s.messageID.uppercase(),
                        providerID = s.providerID.uppercase(),
                        providerName = s.providerName,
                        modelID = s.modelID,
                        modelDisplayName = s.modelDisplayName,
                        protocolRaw = s.protocolRaw,
                        kindRaw = s.kindRaw,
                        statusRaw = if (s.statusRaw == "running") "interrupted" else s.statusRaw,
                        startedAtEpochMs = s.startedAt,
                        endedAtEpochMs = s.endedAt,
                        firstReasoningMs = s.firstReasoningMs,
                        firstContentMs = s.firstContentMs,
                        lastOutputMs = s.lastOutputMs,
                        durationMs = s.durationMs,
                        outputChunkCount = s.outputChunkCount,
                        isStreamed = s.isStreamed,
                        promptTokens = s.promptTokens,
                        completionTokens = s.completionTokens,
                        cachedTokens = s.cachedTokens,
                        cacheWriteTokens = s.cacheWriteTokens,
                        httpStatus = s.httpStatus,
                        inputPricePerMillion = RequestMetrics.validPrice(s.inputPricePerMillion),
                        outputPricePerMillion = RequestMetrics.validPrice(s.outputPricePerMillion),
                        cacheReadPricePerMillion = RequestMetrics.validPrice(s.cacheReadPricePerMillion),
                        cacheWritePricePerMillion = RequestMetrics.validPrice(s.cacheWritePricePerMillion),
                        currency = s.currency
                    )
                }
            if (requestsToInsert.isNotEmpty()) db.requestRecordDao().upsertAll(requestsToInsert)

            val memoriesToInsert = mutableListOf<PersonalMemoryEntity>()
            for (m in incomingMemories) {
                val id = m.id.uppercase()
                if (existingMemoriesMap.containsKey(id) && id !in deletedMemIDs) continue
                if (isBlockedByTombstone(SyncEntityKinds.MEMORY, id, m.createdAt)) {
                    skippedCount++
                    continue
                }
                memoriesCount++
                memoriesToInsert.add(
                    PersonalMemoryEntity(
                        id = id,
                        content = m.content,
                        isEnabled = m.isEnabled,
                        createdAtEpochMs = m.createdAt
                    )
                )
            }
            if (memoriesToInsert.isNotEmpty()) db.personalMemoryDao().upsertAll(memoriesToInsert)

            val providersToInsert = mutableListOf<ProviderEntity>()
            for (p in archive.providers) {
                val id = p.id.uppercase()
                if (existingProviders.containsKey(id) && id !in deletedProviderIDs) {
                    skippedCount++
                    continue
                }
                if (isBlockedByTombstone(SyncEntityKinds.PROVIDER, id, archive.exportedAt)) {
                    skippedCount++
                    continue
                }
                providersToInsert.add(restoredProvider(p, now))
                providersCount++
            }
            if (providersToInsert.isNotEmpty()) db.providerDao().upsertAll(providersToInsert)

            val presetsToInsert = mutableListOf<AssistantPresetEntity>()
            for (p in archive.presets) {
                val id = p.id.uppercase()
                if (existingPresets.containsKey(id) && id !in deletedPresetIDs) {
                    skippedCount++
                    continue
                }
                if (isBlockedByTombstone(SyncEntityKinds.PRESET, id, archive.exportedAt)) {
                    skippedCount++
                    continue
                }
                presetsToInsert.add(
                    AssistantPresetEntity(
                        id = id,
                        name = p.name,
                        iconEmoji = p.iconEmoji,
                        subtitle = p.subtitle,
                        systemPrompt = p.systemPrompt,
                        temperature = p.temperature,
                        useCustomTemperature = p.useCustomTemperature,
                        topP = p.topP,
                        maxOutputTokens = p.maxOutputTokens,
                        contextMessageLimit = p.contextMessageLimit,
                        enableThinking = p.enableThinking,
                        thinkingBudgetTokens = p.thinkingBudgetTokens,
                        isBuiltIn = p.isBuiltIn,
                        sortOrder = p.sortOrder,
                        knowledgeVolumeIDsJson = p.knowledgeVolumeIDs?.let { codec.encodeToString(it) },
                        createdAtEpochMs = now
                    )
                )
                presetsCount++
            }
            if (presetsToInsert.isNotEmpty()) db.assistantPresetDao().upsertAll(presetsToInsert)

            val latestByMessage = incomingRequests
                .groupBy { it.messageID.uppercase() }
                .mapValues { (_, list) -> list.maxByOrNull { it.attempt }?.id?.uppercase() }

            for (c in archive.conversations) {
                val cid = c.id.uppercase()
                if (isBlockedByTombstone(SyncEntityKinds.CONVERSATION, cid, c.updatedAt)) {
                    skippedCount++
                    continue
                }
                val existingConv = if (cid in deletedConvIDs) null else existingConversations[cid]
                val missing = c.messages.filter { !existingMessages.containsKey(it.id.uppercase()) || cid in deletedConvIDs }

                if (existingConv != null) {
                    if (missing.isEmpty()) {
                        skippedCount++
                        continue
                    }
                    restoredConversationsCount++
                } else {
                    val settingsKey = restoredAssistanceSettings(c.assistanceSettings)?.let { settings ->
                        staged.writeText(codec.encodeToString(JsonObject.serializer(), settings))
                    }
                    val convEntity = ConversationEntity(
                        id = cid,
                        title = c.title,
                        isPinned = c.isPinned,
                        assistantID = c.assistantID?.uppercase(),
                        assistantEmoji = c.assistantEmoji,
                        systemPrompt = c.systemPrompt,
                        temperature = c.temperature,
                        useCustomTemperature = c.useCustomTemperature,
                        topP = c.topP,
                        maxOutputTokens = c.maxOutputTokens,
                        contextMessageLimit = c.contextMessageLimit,
                        enableThinking = c.enableThinking,
                        thinkingBudgetTokens = c.thinkingBudgetTokens,
                        isArenaMode = c.isArenaMode,
                        primaryTargetJson = c.primaryTarget?.let { codec.encodeToString(it) } ?: "null",
                        arenaTargetsJson = codec.encodeToString(c.arenaTargets),
                        assistanceSettingsBlobKey = settingsKey,
                        activeLeafMessageID = c.activeLeafMessageID?.uppercase(),
                        folderTag = c.folderTag,
                        organizationEditsJson = c.organizationEdits?.let { codec.encodeToString(JsonElement.serializer(), it) },
                        legacyImportID = c.legacyImportID?.uppercase(),
                        createdAtEpochMs = c.createdAt,
                        updatedAtEpochMs = c.updatedAt
                    )
                    db.conversationDao().upsert(convEntity)
                    conversationsCount++
                }

                val messageEntities = missing.map { m ->
                    val mid = m.id.uppercase()
                    val attKey = if (m.attachments.isNotEmpty()) {
                        staged.writeText(codec.encodeToString(AttachmentProcessor.validateRestoredImages(m.attachments)))
                    } else null
                    val metaKey = m.assistanceMetadata?.let { meta ->
                        staged.writeText(codec.encodeToString(JsonElement.serializer(), meta))
                    }
                    messagesCount++
                    ChatMessageEntity(
                        id = mid,
                        conversationID = cid,
                        roleRaw = m.role,
                        content = m.content,
                        reasoningContent = m.reasoningContent,
                        attachmentsBlobKey = attKey,
                        providerID = m.providerID?.uppercase(),
                        providerName = m.providerName,
                        modelID = m.modelID,
                        modelDisplayName = m.modelDisplayName,
                        accentHex = m.accentHex,
                        comparisonGroupID = m.comparisonGroupID?.uppercase(),
                        isSelectedInGroup = m.isSelectedInGroup,
                        isStreaming = false,
                        errorMessage = m.errorMessage,
                        finishReason = m.finishReason,
                        promptTokens = m.promptTokens,
                        completionTokens = m.completionTokens,
                        cachedTokens = m.cachedTokens,
                        latencyMs = m.latencyMs,
                        thinkingDurationMs = m.thinkingDurationMs,
                        synthesisSourceDigest = m.synthesisSourceDigest,
                        latestRequestID = m.latestRequestID?.uppercase() ?: latestByMessage[mid],
                        assistanceMetadataBlobKey = metaKey,
                        parentMessageID = m.parentMessageID?.uppercase(),
                        sortIndex = m.sortIndex,
                        createdAtEpochMs = m.createdAt
                    )
                }
                if (messageEntities.isNotEmpty()) {
                    db.chatMessageDao().upsertAll(messageEntities)
                }
            }
        }

        // Clean up sidecar blobs/secrets/drafts for tombstoned local records post-commit
        for (key in blobsToDeleteAfterCommit) runCatching { blobStore.delete(key) }
        for ((pid, headerIDs) in providersToPurgeSecrets) runCatching { secretStore.deleteProviderSecrets(pid, headerIDs) }
        for (cid in draftsToRemove) runCatching { draftStore?.remove(cid) }
        for (bid in invalidatedBookIDs) ProjectKnowledgeSearch.invalidate(bid)

        // Flashcards tombstone propagation & filtered import
        val filteredCards = if (enforcedStore != null) {
            val localCardsToDelete = HashSet<String>()
            for (localCard in flashcardRepository.cards.value) {
                val id = localCard.id.uppercase()
                val deletedAt = effectiveTombstones[SyncTombstoneKey(SyncEntityKinds.FLASHCARD, id)] ?: continue
                val cardTs = maxOf(localCard.createdAt, localCard.lastReviewedAt ?: localCard.createdAt)
                if (cardTs > deletedAt) {
                    tombstonesToClear.add(SyncTombstoneKey(SyncEntityKinds.FLASHCARD, id))
                } else {
                    localCardsToDelete.add(id)
                }
            }
            if (localCardsToDelete.isNotEmpty()) {
                deletedCount += runCatching { flashcardRepository.deleteCards(localCardsToDelete) }.getOrDefault(0)
            }
            incomingCards.filter { card ->
                val cardTs = maxOf(card.createdAt, card.lastReviewedAt ?: card.createdAt)
                !isBlockedByTombstone(SyncEntityKinds.FLASHCARD, card.id, cardTs)
            }
        } else {
            incomingCards
        }

        val flashcards = runCatching { flashcardRepository.mergeImported(filteredCards) }

        // Persist tombstone state
        if (enforcedStore != null) {
            enforcedStore.merge(incoming = incomingTombstones, removing = tombstonesToClear, nowMs = now)
        } else if (this.tombstoneStore != null) {
            // Manual restore clears stale tombstones for entities explicitly restored from backup
            val restoredKeys = mutableListOf<Pair<String, String>>()
            archive.conversations.forEach { restoredKeys.add(SyncEntityKinds.CONVERSATION to it.id) }
            incomingMemories.forEach { restoredKeys.add(SyncEntityKinds.MEMORY to it.id) }
            incomingBooks.forEach { restoredKeys.add(SyncEntityKinds.BOOK to it.id) }
            incomingProfiles.forEach { restoredKeys.add(SyncEntityKinds.PERSONA_PROFILE to it.first) }
            archive.providers.forEach { restoredKeys.add(SyncEntityKinds.PROVIDER to it.id) }
            archive.presets.forEach { restoredKeys.add(SyncEntityKinds.PRESET to it.id) }
            incomingCards.forEach { restoredKeys.add(SyncEntityKinds.FLASHCARD to it.id) }
            this.tombstoneStore.removeTombstones(restoredKeys)
        }

        ImportSummary(
            providers = providersCount,
            presets = presetsCount,
            conversations = conversationsCount,
            messages = messagesCount,
            restoredConversations = restoredConversationsCount,
            requests = requestsCount,
            memories = memoriesCount,
            books = booksCount,
            flashcards = flashcards.getOrDefault(0),
            flashcardRestoreFailed = flashcards.isFailure,
            skipped = skippedCount,
            deleted = deletedCount
        )
    }

    companion object {
        private const val MAX_IMPORTED_MESSAGES_PER_CONVERSATION = 50_000

        internal fun prepareRestoredBook(snapshot: BookVolumeSnapshot): PreparedBook {
            val manuscript = BookManuscript(snapshot.title, snapshot.chapters.map { BookChapter(it.title, it.text) })
            return PreparedBook.forIdentifier(manuscript, snapshot.id) ?: throw BackupException.ConflictingIDs()
        }

        internal fun decodeRestoredFlashcards(elements: List<JsonElement>): List<StudyFlashcard> {
            return try {
                elements.map { BackupJson.codec.decodeFromJsonElement(StudyFlashcard.serializer(), it) }.also { cards ->
                    if (cards.any { it.id.isBlank() || it.front.isBlank() || it.back.isBlank() }) {
                        throw BackupException.UnrecognizedFormat()
                    }
                }
            } catch (_: IllegalArgumentException) {
                throw BackupException.UnrecognizedFormat()
            }
        }

        internal fun restoredProvider(backup: ProviderBackup, now: Long): ProviderEntity = ProviderEntity(
            id = backup.id.uppercase(),
            name = backup.name,
            protocolRaw = backup.protocolRaw,
            baseURL = backup.baseURL,
            iconSymbol = backup.iconSymbol,
            accentHex = backup.accentHex,
            isEnabled = false,
            sortOrder = backup.sortOrder,
            modelsJson = BackupJson.codec.encodeToString(ModelSpec.deduplicated(backup.models)),
            headersJson = BackupJson.codec.encodeToString(backup.customHeaders),
            notes = backup.notes,
            createdAtEpochMs = now,
            updatedAtEpochMs = now
        )

        internal fun restoredAssistanceSettings(settings: JsonElement?): JsonObject? {
            val source = settings as? JsonObject ?: return null
            val normalized = source.toMutableMap()
            normalized["usePersonalMemory"] = JsonPrimitive(false)
            (source["groupMembers"] as? JsonArray)?.let { members ->
                normalized["groupMembers"] = JsonArray(members.map { (it as? JsonObject)?.let(::restoredMember) ?: it })
            }
            (source["privatePersona"] as? JsonObject)?.let { normalized["privatePersona"] = restoredMember(it) }
            return JsonObject(normalized)
        }

        internal fun restoredMember(member: JsonObject): JsonObject {
            val persona = member["persona"] as? JsonObject ?: return member
            val feeds = persona["feeds"] as? JsonArray ?: return member
            val disabled = JsonArray(feeds.map { element ->
                val feed = element as? JsonObject ?: return@map element
                JsonObject(feed - setOf("checkpoint", "lastChecked", "lastError") + ("enabled" to JsonPrimitive(false)))
            })
            return JsonObject(member + ("persona" to JsonObject(persona + ("feeds" to disabled))))
        }

        private const val FLASHCARDS_BLOB_KEY = "sidecar_flashcards.json"

        private val portablePaths = setOf(
            "", "v1", "v2", "v3", "v4", "v1beta", "api/v1",
            "openai/v1", "anthropic/v1", "chat/completions", "v1/chat/completions",
            "messages", "v1/messages"
        )

        /**
         * Matches iOS `BackupService.portableBaseURL`: only conventional API paths are carried
         * verbatim in unencrypted JSON backups; custom gateway paths are omitted for safety.
         */
        fun portableBaseURL(raw: String): String {
            val address = raw.trim()
            val uri = runCatching { URI(address) }.getOrNull() ?: return ""
            val scheme = uri.scheme?.lowercase() ?: return ""
            if (scheme != "http" && scheme != "https") return ""
            if (uri.host.isNullOrEmpty()) return ""
            if (!uri.rawUserInfo.isNullOrEmpty() || uri.rawQuery != null || !uri.rawFragment.isNullOrEmpty()) {
                return ""
            }
            val path = (uri.rawPath ?: "").trim('/')
            return if (portablePaths.contains(path)) address else ""
        }

        private fun isValidDestination(raw: String): Boolean {
            val uri = runCatching { URI(raw.trim()) }.getOrNull() ?: return false
            val scheme = uri.scheme?.lowercase() ?: return false
            return (scheme == "http" || scheme == "https") && !uri.host.isNullOrEmpty()
        }
    }
}
