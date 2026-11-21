package com.iosbox.app.ui.chat

import android.content.ContentResolver
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.ArenaBallot
import com.iosbox.app.core.model.BookFriend
import com.iosbox.app.core.model.BookReplyEvidence
import com.iosbox.app.core.model.GroupMember
import com.iosbox.app.core.model.GroupSourceNotice
import com.iosbox.app.core.model.GroupSpeakingMode
import com.iosbox.app.core.model.GroupSpeechIntent
import com.iosbox.app.core.model.GroupSpeechStyle
import com.iosbox.app.core.model.KnowledgeEvidence
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.PersonaExcerpt
import com.iosbox.app.core.model.PersonalMemoryPrompt
import com.iosbox.app.core.model.RequestKind
import com.iosbox.app.core.model.RequestMetrics
import com.iosbox.app.core.model.RequestStatus
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.model.StudyCardDraft
import com.iosbox.app.core.model.StudyCoachMode
import com.iosbox.app.core.network.AgentToolRunner
import com.iosbox.app.core.network.ArenaSynthesis
import com.iosbox.app.core.network.GroupDiscussionCoordinator
import com.iosbox.app.core.network.GroupStreamSanitizer
import com.iosbox.app.core.network.GroupTurnDirective
import com.iosbox.app.core.network.LLMChatRequest
import com.iosbox.app.core.network.LLMError
import com.iosbox.app.core.network.LLMPromptMessage
import com.iosbox.app.core.network.LLMStreamEvent
import com.iosbox.app.core.network.LLMThinkingBlock
import com.iosbox.app.core.network.LLMToolCall
import com.iosbox.app.core.network.PersonaFeedReader
import com.iosbox.app.core.network.PersonaMaterials
import com.iosbox.app.core.network.ScheduleExtractorService
import com.iosbox.app.core.network.SearchError
import com.iosbox.app.core.network.SearchEvidence
import com.iosbox.app.core.network.SearchSource
import com.iosbox.app.core.network.StudyGeneratorService
import com.iosbox.app.core.network.TavilySearchClient
import com.iosbox.app.core.network.WebpageApprovalDecision
import com.iosbox.app.core.security.SecretStore
import com.iosbox.app.core.system.GenerationNotificationState
import com.iosbox.app.core.system.GenerationServiceBridge
import com.iosbox.app.core.storage.AttachmentProcessor
import com.iosbox.app.core.storage.BookImporter
import com.iosbox.app.core.storage.BookReferenceSearch
import com.iosbox.app.core.storage.BookVolumeItem
import com.iosbox.app.core.storage.ChatDraft
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ConversationItem
import com.iosbox.app.core.storage.ConversationTree
import com.iosbox.app.core.storage.KnowledgeDocumentInput
import com.iosbox.app.core.storage.ModelMentionParser
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.core.storage.ProjectKnowledgeSearch
import com.iosbox.app.core.storage.PromptTemplateEngine
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.core.storage.RequestRecordItem
import com.iosbox.app.core.storage.SlashPromptCommand
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.URI
import java.util.UUID

data class PendingConsentAction(
    val recipientSummary: String,
    val onConfirm: () -> Unit
)

data class PendingWebpageApproval(
    val id: String,
    val url: String,
    val host: String,
    val hasQuery: Boolean,
    val onResolve: (allow: Boolean, rememberHost: Boolean) -> Unit
)

data class ChatDetailUiState(
    val conversation: ConversationItem? = null,
    val messages: List<ChatMessageItem> = emptyList(),
    val branchSiblings: Map<String, List<ChatMessageItem>> = emptyMap(),
    val providers: List<ProviderItem> = emptyList(),
    val presets: List<PresetItem> = emptyList(),
    val personaProfiles: List<GroupMember> = emptyList(),
    val books: List<BookVolumeItem> = emptyList(),
    val enabledMemoryCount: Int = 0,
    val draftText: String = "",
    val draftAttachments: List<MessageAttachment> = emptyList(),
    val quotedExcerpt: String? = null,
    val temporaryTargetOverride: ResolvedModelTarget? = null,
    val isGenerating: Boolean = false,
    val isRefreshingFeeds: Boolean = false,
    val studyGeneratingMessageID: String? = null,
    val speakingMessageID: String? = null,
    val scheduleExtractingMessageID: String? = null,
    val activeGroupSpeaker: String? = null,
    val useWebSearchOnce: Boolean = false,
    val hasTavilyKey: Boolean = false,
    val bannerError: String? = null,
    val feedStatusNotice: String? = null,
    val pendingConsent: PendingConsentAction? = null,
    val pendingWebpageApproval: PendingWebpageApproval? = null
)

class ChatViewModel(
    private val conversationId: String,
    private val container: AppContainer
) : ViewModel() {
    private val repo = container.chatRepository

    private val draftText = MutableStateFlow("")
    private val draftAttachments = MutableStateFlow<List<MessageAttachment>>(emptyList())
    private val streamingOverlays = MutableStateFlow<Map<String, ChatMessageItem>>(emptyMap())
    private val activeGroupSpeaker = MutableStateFlow<String?>(null)
    private val useWebSearchOnce = MutableStateFlow(false)
    private val bannerError = MutableStateFlow<String?>(null)
    private val pendingConsent = MutableStateFlow<PendingConsentAction?>(null)
    private val pendingWebpageApproval = MutableStateFlow<PendingWebpageApproval?>(null)
    private val studyGeneratingMessageID = MutableStateFlow<String?>(null)
    private val quotedExcerpt = MutableStateFlow<String?>(null)
    private val temporaryTargetOverride = MutableStateFlow<ResolvedModelTarget?>(null)
    private val feedStatusNotice = MutableStateFlow<String?>(null)
    private val isRefreshingFeeds = MutableStateFlow(false)
    private val scheduleExtractingMessageID = MutableStateFlow<String?>(null)

    @Volatile
    private var latestAllMessages: List<ChatMessageItem> = emptyList()

    @Volatile
    private var draftLoaded: Boolean = false

    private val approvedWebpageHosts = HashSet<String>()
    private var pendingApprovalDeferred: CompletableDeferred<WebpageApprovalDecision>? = null
    private var activeJob: Job? = null

    private val libraryFlow = combine(
        repo.observeBooks(),
        repo.observePersonalMemories(),
        studyGeneratingMessageID
    ) { books, memories, studyMsgId ->
        Triple(
            books,
            memories.count { it.isEnabled && it.content.isNotBlank() }
                .coerceAtMost(PersonalMemoryPrompt.MAXIMUM_COUNT),
            studyMsgId
        )
    }

    private val baseDataFlow = combine(
        repo.observeConversation(conversationId),
        repo.observeMessages(conversationId),
        repo.observeProviders(),
        repo.observePresets(),
        combine(repo.observePersonaProfiles(), libraryFlow) { profiles, lib -> profiles to lib }
    ) { conv, msgs, providers, presets, (profiles, lib) ->
        BaseData(conv, msgs, providers, presets, profiles, lib.first, lib.second, lib.third)
    }

    private val powerToolsFlow = combine(
        quotedExcerpt,
        temporaryTargetOverride,
        feedStatusNotice,
        isRefreshingFeeds,
        combine(container.speechController.speakingMessageID, scheduleExtractingMessageID) { s, sc -> s to sc }
    ) { quote, targetOverride, notice, refreshing, (speakingId, scheduleId) ->
        PowerToolsState(quote, targetOverride, notice, refreshing, speakingId, scheduleId)
    }

    private val extrasFlow = combine(
        bannerError,
        pendingConsent,
        activeGroupSpeaker,
        useWebSearchOnce,
        combine(
            pendingWebpageApproval,
            container.secretStore.versionFlow.map {
                container.secretStore.loadSecret(SecretStore.TAVILY_KEY_ACCOUNT).isNotEmpty()
            },
            powerToolsFlow
        ) { approval, hasKey, powerTools -> Triple(approval, hasKey, powerTools) }
    ) { err, consent, speaker, webSearchOnce, (approval, hasKey, powerTools) ->
        ExtraUiState(err, consent, speaker, webSearchOnce, approval, hasKey, powerTools)
    }

    val uiState: StateFlow<ChatDetailUiState> = combine(
        baseDataFlow,
        draftText,
        draftAttachments,
        streamingOverlays,
        extrasFlow
    ) { base, draft, atts, overlays, extras ->
        val mergedMessages = if (overlays.isEmpty()) {
            base.messages
        } else {
            val remaining = overlays.toMutableMap()
            val updated = base.messages.map { m ->
                remaining.remove(m.id) ?: m
            }
            (updated + remaining.values).sortedWith(
                compareBy<ChatMessageItem> { it.sortIndex }.thenBy { it.createdAtEpochMs }
            )
        }
        latestAllMessages = mergedMessages
        val activeLeaf = base.conversation?.activeLeafMessageID
        val visibleMessages = ConversationTree.activeMessages(activeLeaf, mergedMessages)
        val siblingsMap = ConversationTree.branchSiblingsMap(activeLeaf, mergedMessages)
        ChatDetailUiState(
            conversation = base.conversation,
            messages = visibleMessages,
            branchSiblings = siblingsMap,
            providers = base.providers,
            presets = base.presets,
            personaProfiles = base.personaProfiles,
            books = base.books,
            enabledMemoryCount = base.enabledMemoryCount,
            draftText = draft,
            draftAttachments = atts,
            quotedExcerpt = extras.powerTools.quotedExcerpt,
            temporaryTargetOverride = extras.powerTools.temporaryTargetOverride,
            isGenerating = overlays.isNotEmpty() || extras.speaker != null || mergedMessages.any { it.isStreaming },
            isRefreshingFeeds = extras.powerTools.isRefreshingFeeds,
            studyGeneratingMessageID = base.studyGeneratingMessageID,
            speakingMessageID = extras.powerTools.speakingMessageID,
            scheduleExtractingMessageID = extras.powerTools.scheduleExtractingMessageID,
            activeGroupSpeaker = extras.speaker,
            useWebSearchOnce = extras.useWebSearchOnce,
            hasTavilyKey = extras.hasTavilyKey,
            bannerError = extras.bannerError,
            feedStatusNotice = extras.powerTools.feedStatusNotice,
            pendingConsent = extras.pendingConsent,
            pendingWebpageApproval = extras.pendingWebpageApproval
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ChatDetailUiState())

    init {
        viewModelScope.launch {
            GenerationServiceBridge.stopRequests.collect { targetConvId ->
                if (targetConvId.equals(conversationId, ignoreCase = true)) {
                    stopGeneration()
                }
            }
        }
        val staged = container.externalEntryRouter.consumeInitialDraft(conversationId)
        if (staged != null) {
            draftText.value = staged.text
            draftAttachments.value = staged.attachments
            draftLoaded = true
            if (staged.autoSend && container.preferences.isConsentAccepted) {
                viewModelScope.launch {
                    uiState.first { it.conversation != null && it.providers.isNotEmpty() }
                    sendCurrentDraft()
                }
            } else {
                viewModelScope.launch(Dispatchers.IO) {
                    runCatching {
                        container.draftStore.save(
                            conversationId,
                            ChatDraft(text = staged.text, attachments = staged.attachments)
                        )
                    }
                }
            }
        } else {
            viewModelScope.launch {
                val restored = withContext(Dispatchers.IO) {
                    runCatching { container.draftStore.load(conversationId) }.getOrNull()
                }
                if (
                    restored != null &&
                    !restored.isEmpty &&
                    draftText.value.isEmpty() &&
                    draftAttachments.value.isEmpty() &&
                    quotedExcerpt.value == null
                ) {
                    draftText.value = restored.text
                    draftAttachments.value = restored.attachments
                    quotedExcerpt.value = restored.quotedExcerpt
                }
                draftLoaded = true
            }
        }

        viewModelScope.launch(Dispatchers.IO) {
            combine(draftText, draftAttachments, quotedExcerpt) { t, a, q ->
                ChatDraft(text = t, attachments = a, quotedExcerpt = q)
            }.collectLatest { draft ->
                if (draftLoaded) {
                    delay(400)
                    runCatching { container.draftStore.save(conversationId, draft) }
                }
            }
        }
    }

    private data class BaseData(
        val conversation: ConversationItem?,
        val messages: List<ChatMessageItem>,
        val providers: List<ProviderItem>,
        val presets: List<PresetItem>,
        val personaProfiles: List<GroupMember>,
        val books: List<BookVolumeItem>,
        val enabledMemoryCount: Int,
        val studyGeneratingMessageID: String?
    )

    private data class PowerToolsState(
        val quotedExcerpt: String?,
        val temporaryTargetOverride: ResolvedModelTarget?,
        val feedStatusNotice: String?,
        val isRefreshingFeeds: Boolean,
        val speakingMessageID: String?,
        val scheduleExtractingMessageID: String?
    )

    private data class ExtraUiState(
        val bannerError: String?,
        val pendingConsent: PendingConsentAction?,
        val speaker: String?,
        val useWebSearchOnce: Boolean,
        val pendingWebpageApproval: PendingWebpageApproval?,
        val hasTavilyKey: Boolean,
        val powerTools: PowerToolsState
    )

    private data class StreamSlot(
        val message: ChatMessageItem,
        val target: ResolvedModelTarget,
        val provider: ProviderItem,
        val history: List<LLMPromptMessage>,
        val kind: RequestKind,
        val systemPromptOverride: String? = null,
        val temperatureOverride: Double? = null,
        val groupSanitizer: GroupStreamSanitizer? = null
    )

    private data class SlotOutcome(
        val message: ChatMessageItem,
        val directive: GroupTurnDirective?
    )

    private sealed interface GroupRunMode {
        data class AfterUserMessage(
            val userMessage: ChatMessageItem,
            val searchQuery: String? = null
        ) : GroupRunMode

        data object ContinueDiscussion : GroupRunMode
        data object GroupVote : GroupRunMode
        data class Summarize(val preferred: GroupMember?) : GroupRunMode
    }

    override fun onCleared() {
        cancelPendingWebpageApproval()
        container.speechController.stopSpeaking()
        if (draftLoaded) {
            val snapshot = ChatDraft(
                text = draftText.value,
                attachments = draftAttachments.value,
                quotedExcerpt = quotedExcerpt.value
            )
            runCatching { container.draftStore.save(conversationId, snapshot) }
        }
        super.onCleared()
    }

    fun updateDraftText(text: String) {
        draftText.value = text
    }

    fun appendMentionToDraft(member: GroupMember) {
        val token = "@${member.mentionToken} "
        val current = draftText.value
        draftText.value = if (current.isEmpty() || current.endsWith(' ') || current.endsWith('\n')) {
            current + token
        } else {
            "$current $token"
        }
    }

    fun toggleUseWebSearchOnce() {
        val tavilyKey = container.secretStore.loadSecret(SecretStore.TAVILY_KEY_ACCOUNT)
        if (tavilyKey.isEmpty()) {
            useWebSearchOnce.value = false
            bannerError.value = L10n.text(
                "请先在「服务商 → 联网搜索」配置 Tavily API Key。",
                "Configure a Tavily API key in Providers -> Web Search first."
            )
            return
        }
        useWebSearchOnce.value = !useWebSearchOnce.value
    }

    fun toggleAgentTools() {
        val conv = uiState.value.conversation ?: return
        viewModelScope.launch {
            val toggled = !conv.assistanceSettings.enableAgentTools
            repo.saveConversation(
                conv.copy(
                    assistanceSettings = conv.assistanceSettings.copy(enableAgentTools = toggled),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun toggleNativeGrounding() {
        val conv = uiState.value.conversation ?: return
        viewModelScope.launch {
            val toggled = !conv.assistanceSettings.enableNativeGrounding
            repo.saveConversation(
                conv.copy(
                    assistanceSettings = conv.assistanceSettings.copy(enableNativeGrounding = toggled),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun togglePersonalMemory() {
        val conv = uiState.value.conversation ?: return
        viewModelScope.launch {
            val toggled = !conv.assistanceSettings.usePersonalMemory
            repo.saveConversation(
                conv.copy(
                    assistanceSettings = conv.assistanceSettings.copy(usePersonalMemory = toggled),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun updateBoundKnowledgeVolumes(volumeIDs: List<String>) {
        val conv = uiState.value.conversation ?: return
        val cleaned = volumeIDs.map { it.trim().uppercase() }
            .filter { it.isNotEmpty() }
            .distinct()
            .take(12)
        viewModelScope.launch {
            repo.saveConversation(
                conv.copy(
                    assistanceSettings = conv.assistanceSettings.copy(knowledgeVolumeIDs = cleaned),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun quotePassageToDraft(excerpt: String) {
        val clean = excerpt.trim().take(400)
        if (clean.isEmpty()) return
        val quoted = "> ${clean.replace("\n", "\n> ")}\n\n"
        val current = draftText.value
        draftText.value = if (current.isBlank()) quoted else "$quoted$current"
    }

    fun changeBookFriendProgress(throughChapter: Int?, onOpenConversation: (String) -> Unit) {
        val conv = uiState.value.conversation ?: return
        if (conv.activeBookFriend == null) return
        viewModelScope.launch {
            runCatching {
                repo.changeBookFriendProgress(conv, throughChapter)
            }.onSuccess { result ->
                if (!result.id.equals(conv.id, ignoreCase = true)) {
                    onOpenConversation(result.id)
                }
            }.onFailure { err ->
                bannerError.value = err.message ?: L10n.text("调整阅读进度失败", "Failed to update reading progress")
            }
        }
    }

    suspend fun importBookSync(contentResolver: ContentResolver, uri: Uri): BookVolumeItem {
        val prepared = withContext(Dispatchers.IO) {
            BookImporter.readUri(contentResolver, uri)
        }
        return repo.storePreparedBook(prepared)
    }

    fun setStudyCoachMode(mode: StudyCoachMode) {
        val conv = uiState.value.conversation ?: return
        viewModelScope.launch {
            repo.saveConversation(
                conv.copy(
                    assistanceSettings = conv.assistanceSettings.copy(studyCoachMode = mode),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun toggleBookmark(message: ChatMessageItem) {
        val meta = message.assistanceMetadata
        viewModelScope.launch {
            repo.saveMessage(
                message.copy(
                    assistanceMetadata = meta.copy(isBookmarked = !meta.isBookmarked)
                )
            )
        }
    }

    fun toggleExcludedFromContext(message: ChatMessageItem) {
        val meta = message.assistanceMetadata
        viewModelScope.launch {
            repo.saveMessage(
                message.copy(
                    assistanceMetadata = meta.copy(isExcludedFromContext = !meta.isExcludedFromContext)
                )
            )
        }
    }

    fun insertContextDivider() {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (state.isGenerating) return
        viewModelScope.launch {
            val allMsgs = repo.getMessages(conv.id)
            val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
            val parentId = if (treeActive) ConversationTree.currentAnchorID(conv.activeLeafMessageID, allMsgs) else null
            val nextSort = (allMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
            val now = System.currentTimeMillis()
            val dividerId = UUID.randomUUID().toString().uppercase()
            val divider = ChatMessageItem(
                id = dividerId,
                conversationID = conv.id,
                role = MessageRole.SYSTEM,
                content = L10n.text("以上内容不计入后续上下文", "Context cleared above"),
                reasoningContent = "",
                attachments = emptyList(),
                providerID = null,
                providerName = "",
                modelID = "",
                modelDisplayName = "",
                accentHex = "#3F6EF6",
                comparisonGroupID = null,
                isSelectedInGroup = true,
                isStreaming = false,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = null,
                latestRequestID = null,
                assistanceMetadata = MessageAssistanceMetadata(isContextDivider = true),
                parentMessageID = parentId,
                sortIndex = nextSort,
                createdAtEpochMs = now
            )
            if (treeActive) {
                repo.saveConversationAndMessages(
                    conv.copy(activeLeafMessageID = dividerId, updatedAtEpochMs = now),
                    listOf(divider)
                )
            } else {
                repo.saveMessage(divider)
            }
        }
    }

    fun deleteContextDivider(message: ChatMessageItem) {
        if (!message.assistanceMetadata.isContextDivider) return
        viewModelScope.launch {
            val conv = uiState.value.conversation
            val allMsgs = if (conv != null) repo.getMessages(conv.id) else emptyList()
            val treeActive = conv != null && ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
            if (conv != null && treeActive) {
                val parentNorm = message.parentMessageID?.trim()?.uppercase()
                val reParented = allMsgs.filter {
                    it.parentMessageID?.trim()?.uppercase() == message.id.uppercase()
                }.map { it.copy(parentMessageID = message.parentMessageID) }
                val nextLeaf = if (conv.activeLeafMessageID.equals(message.id, ignoreCase = true)) {
                    if (parentNorm == ConversationTree.VIRTUAL_ROOT_ID) null else parentNorm
                } else {
                    conv.activeLeafMessageID
                }
                repo.saveConversationAndMessages(
                    conv.copy(activeLeafMessageID = nextLeaf, updatedAtEpochMs = System.currentTimeMillis()),
                    reParented
                )
            }
            repo.deleteMessage(message.id)
        }
    }

    fun setQuotedExcerpt(excerpt: String?) {
        quotedExcerpt.value = excerpt?.trim()?.take(280)?.takeIf { it.isNotEmpty() }
    }

    fun quoteMessageForFollowUp(message: ChatMessageItem) {
        setQuotedExcerpt(message.content)
    }

    fun clearFeedStatusNotice() {
        feedStatusNotice.value = null
    }

    fun setTemporaryTargetOverride(target: ResolvedModelTarget?) {
        temporaryTargetOverride.value = target
    }

    fun selectMentionOverride(target: ResolvedModelTarget) {
        temporaryTargetOverride.value = target
        draftText.value = ModelMentionParser.stripTrailingMention(draftText.value)
    }

    fun applySlashCommand(command: SlashPromptCommand) {
        if (command.id == "clear-context") {
            draftText.value = ""
            insertContextDivider()
            return
        }
        if (command.id == "socratic-coach") {
            setStudyCoachMode(StudyCoachMode.SOCRATIC)
        } else if (command.id == "feynman-coach") {
            setStudyCoachMode(StudyCoachMode.FEYNMAN)
        }
        draftText.value = command.templatePrefix
    }

    fun switchBranch(targetMessage: ChatMessageItem) {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (state.isGenerating) return
        viewModelScope.launch {
            val allMsgs = repo.getMessages(conv.id)
            val newLeaf = ConversationTree.resolveBranchLeaf(targetMessage, allMsgs)
            repo.saveConversation(conv.copy(activeLeafMessageID = newLeaf))
        }
    }

    fun editAndBranchUserMessage(original: ChatMessageItem, newContent: String) {
        val state = uiState.value
        val conv = state.conversation ?: return
        val trimmed = newContent.trim()
        if (state.isGenerating || trimmed.isEmpty() || original.role != MessageRole.USER) return

        val ready = ChatRepository.readyTargets(state.providers)

        if (conv.isGroupMode) {
            val activePairs = resolveGroupPairs(conv, state.providers, ready)
            if (activePairs.isEmpty()) {
                bannerError.value = L10n.text(
                    "群内暂无未静音且模型可用的成员，请检查群设置或服务商 API Key。",
                    "No unmuted group member has a ready model configured."
                )
                return
            }
            val summary = consentSummaryFor(activePairs.map { it.second to it.third }.distinctBy { it.first.id })
            runWithConsent(summary) {
                executeEditBranchGroup(original, trimmed, conv)
            }
            return
        }

        if (conv.isArenaMode) {
            val resolvedPairs = conv.arenaTargets.mapNotNull { chosen ->
                val target = ready.firstOrNull { it.id == chosen.id } ?: return@mapNotNull null
                val provider = state.providers.firstOrNull { it.id.equals(target.providerID, ignoreCase = true) }
                    ?: return@mapNotNull null
                target to provider
            }
            if (resolvedPairs.size < 2) {
                bannerError.value = L10n.text(
                    "竞技场模式需至少选择 2 个可用模型（点击顶部模型栏配置）。",
                    "Arena mode requires at least 2 ready models."
                )
                return
            }
            runWithConsent(consentSummaryFor(resolvedPairs)) {
                executeEditBranchArena(original, trimmed, conv, resolvedPairs)
            }
            return
        }

        val target = resolveActiveTarget(conv, state.providers, ready)
        val provider = target?.let { t ->
            state.providers.firstOrNull { it.id.equals(t.providerID, ignoreCase = true) }
        }
        if (target == null || provider == null) {
            bannerError.value = L10n.text(
                "请先在「服务商」配置 API Key 并启用至少一个模型。",
                "Configure an API key and enable at least one model in Providers first."
            )
            return
        }
        runWithConsent(consentSummaryFor(listOf(target to provider))) {
            executeEditBranchSingle(original, trimmed, conv, target, provider)
        }
    }

    fun refreshPersonaFeeds() {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (!conv.isGroupMode || state.isGenerating || isRefreshingFeeds.value) return
        val hasEnabledFeeds = conv.groupMembers.any { m ->
            !m.isMuted && m.persona?.feeds?.any { it.enabled } == true
        }
        if (!hasEnabledFeeds) {
            feedStatusNotice.value = L10n.text(
                "群成员暂未配置并启用博客 RSS 或 X 订阅源，可在「助手 -> 人物档案」中添加。",
                "No enabled blog RSS or X feeds on group members. Add feeds in Assistants -> Personas."
            )
            return
        }

        viewModelScope.launch {
            isRefreshingFeeds.value = true
            bannerError.value = null
            try {
                val reader = PersonaFeedReader(
                    tokenProvider = { container.secretStore.loadSecret(SecretStore.PERSONA_X_TOKEN_ACCOUNT) }
                )
                val now = System.currentTimeMillis()
                var checked = 0
                var added = 0
                var baselines = 0
                val errors = mutableListOf<String>()

                val liveConv = repo.getConversation(conv.id) ?: conv
                val currentAllMsgs = repo.getMessages(liveConv.id)
                val treeActive = ConversationTree.usesTree(liveConv.activeLeafMessageID, currentAllMsgs)
                var currentLeaf = if (treeActive) ConversationTree.currentAnchorID(liveConv.activeLeafMessageID, currentAllMsgs) else null
                var nextSort = (currentAllMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
                val noticesToInsert = mutableListOf<ChatMessageItem>()

                val updatedMembers = liveConv.groupMembers.map { member ->
                    val persona = member.persona ?: return@map member
                    if (member.isMuted || persona.feeds.none { it.enabled }) return@map member
                    val nextFeeds = persona.feeds.map { feed ->
                        if (!feed.enabled) {
                            feed
                        } else {
                            checked++
                            val wasInitial = feed.checkpoint == null
                            val res = runCatching { reader.read(feed, nowMs = now) }
                            res.fold(
                                onSuccess = { batch ->
                                    if (wasInitial) {
                                        baselines++
                                    } else {
                                        for (item in batch.items) {
                                            added++
                                            val notice = GroupSourceNotice(
                                                memberName = member.displayLabel,
                                                title = item.title,
                                                url = item.url,
                                                published = item.published,
                                                excerpt = item.excerpt
                                            )
                                            val noticeId = UUID.randomUUID().toString().uppercase()
                                            val noticeMsg = ChatMessageItem(
                                                id = noticeId,
                                                conversationID = liveConv.id,
                                                role = MessageRole.ASSISTANT,
                                                content = notice.body,
                                                reasoningContent = "",
                                                attachments = emptyList(),
                                                providerID = null,
                                                providerName = feed.kind.displayName,
                                                modelID = feed.kind.rawValue,
                                                modelDisplayName = member.displayLabel,
                                                accentHex = member.accentHex,
                                                comparisonGroupID = null,
                                                isSelectedInGroup = true,
                                                isStreaming = false,
                                                errorMessage = null,
                                                finishReason = null,
                                                promptTokens = null,
                                                completionTokens = null,
                                                cachedTokens = null,
                                                latencyMs = null,
                                                thinkingDurationMs = null,
                                                synthesisSourceDigest = null,
                                                latestRequestID = null,
                                                assistanceMetadata = MessageAssistanceMetadata(
                                                    groupMemberID = member.id,
                                                    groupMemberName = member.name,
                                                    groupMemberTitle = member.title,
                                                    groupMemberEmoji = member.avatarEmoji,
                                                    isPersonaSimulation = member.isSimulatedPersona,
                                                    sourceNotice = notice
                                                ),
                                                parentMessageID = currentLeaf,
                                                sortIndex = nextSort++,
                                                createdAtEpochMs = now + added
                                            )
                                            if (treeActive) currentLeaf = noticeId
                                            noticesToInsert.add(noticeMsg)
                                        }
                                    }
                                    feed.copy(
                                        checkpoint = batch.checkpoint,
                                        lastChecked = now,
                                        lastError = null
                                    )
                                },
                                onFailure = { err ->
                                    val msg = err.message ?: L10n.text("读取失败", "Fetch failed")
                                    errors.add("${member.name} · $msg")
                                    feed.copy(
                                        lastChecked = now,
                                        lastError = msg
                                    )
                                }
                            )
                        }
                    }
                    member.copy(persona = persona.copy(feeds = nextFeeds))
                }

                val savedConv = liveConv.copy(
                    assistanceSettings = liveConv.assistanceSettings.copy(groupMembers = updatedMembers),
                    activeLeafMessageID = if (treeActive) currentLeaf else liveConv.activeLeafMessageID,
                    updatedAtEpochMs = System.currentTimeMillis()
                )
                repo.saveConversationAndMessages(savedConv, noticesToInsert)

                val summaryParts = mutableListOf<String>()
                if (checked > 0) {
                    summaryParts.add(
                        L10n.text("已检查 $checked 个订阅，新增 $added 条动态。", "Checked $checked feeds; $added new updates.")
                    )
                }
                if (baselines > 0) {
                    summaryParts.add(
                        L10n.text("首次检查已记录现有内容基线，之后仅推送新动态。", "Baseline recorded on initial check; future checks will post new items.")
                    )
                }
                summaryParts.addAll(errors)
                feedStatusNotice.value = summaryParts.joinToString("\n").ifEmpty {
                    L10n.text("没有待检查的订阅。", "No feeds checked.")
                }
            } finally {
                isRefreshingFeeds.value = false
            }
        }
    }

    fun sendQuickPrompt(promptText: String) {
        if (uiState.value.isGenerating) return
        draftText.value = promptText
        sendCurrentDraft()
    }

    fun toggleSpeakMessage(message: ChatMessageItem) {
        container.speechController.toggleSpeak(message.id, message.content)
    }

    fun appendDictatedText(spoken: String) {
        val clean = spoken.trim()
        if (clean.isEmpty()) return
        val cur = draftText.value
        draftText.value = when {
            cur.isBlank() -> clean
            cur.endsWith(' ') || cur.endsWith('\n') -> "$cur$clean"
            else -> "$cur $clean"
        }
    }

    fun reportBannerError(message: String) {
        bannerError.value = message
    }

    fun extractSchedulesForMessage(message: ChatMessageItem) {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (state.scheduleExtractingMessageID != null || state.isGenerating) return
        val ready = ChatRepository.readyTargets(state.providers)
        val target = resolveReplyTarget(message, conv, state.providers, ready)
        val provider = target?.let { t ->
            state.providers.firstOrNull { it.id.equals(t.providerID, ignoreCase = true) }
        }
        if (target == null || provider == null) {
            bannerError.value = L10n.text("没有可用的模型用于提炼日程。", "No ready model available to extract schedules.")
            return
        }
        runWithConsent(consentSummaryFor(listOf(target to provider))) {
            bannerError.value = null
            viewModelScope.launch {
                scheduleExtractingMessageID.value = message.id
                try {
                    val items = ScheduleExtractorService.requestScheduleItems(
                        sourceText = message.content,
                        target = target,
                        provider = provider,
                        conversationID = conv.id,
                        messageID = message.id,
                        repo = repo,
                        secretStore = container.secretStore,
                        llmClient = container.llmClient
                    )
                    repo.saveMessage(
                        message.copy(
                            assistanceMetadata = message.assistanceMetadata.copy(proposedSchedules = items)
                        )
                    )
                } catch (t: Throwable) {
                    if (t !is CancellationException) {
                        bannerError.value = t.message ?: L10n.text("提取日程失败", "Failed to extract schedules")
                    }
                } finally {
                    scheduleExtractingMessageID.value = null
                }
            }
        }
    }

    fun generateFlashcardsForMessage(message: ChatMessageItem) {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (state.studyGeneratingMessageID != null || state.isGenerating) return
        val ready = ChatRepository.readyTargets(state.providers)
        val target = resolveReplyTarget(message, conv, state.providers, ready)
        val provider = target?.let { t ->
            state.providers.firstOrNull { it.id.equals(t.providerID, ignoreCase = true) }
        }
        if (target == null || provider == null) {
            bannerError.value = L10n.text("没有可用的模型用于生成闪卡。", "No ready model available to generate flashcards.")
            return
        }
        runWithConsent(consentSummaryFor(listOf(target to provider))) {
            bannerError.value = null
            viewModelScope.launch {
                studyGeneratingMessageID.value = message.id
                try {
                    val cards = StudyGeneratorService.requestFlashcards(
                        sourceText = message.content,
                        target = target,
                        provider = provider,
                        conversationID = conv.id,
                        messageID = message.id,
                        repo = repo,
                        secretStore = container.secretStore,
                        llmClient = container.llmClient
                    )
                    repo.saveMessage(
                        message.copy(
                            assistanceMetadata = message.assistanceMetadata.copy(generatedFlashcards = cards)
                        )
                    )
                } catch (t: Throwable) {
                    if (t !is CancellationException) {
                        bannerError.value = t.message ?: L10n.text("生成闪卡失败", "Failed to generate flashcards")
                    }
                } finally {
                    studyGeneratingMessageID.value = null
                }
            }
        }
    }

    fun generateQuizForMessage(message: ChatMessageItem) {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (state.studyGeneratingMessageID != null || state.isGenerating) return
        val ready = ChatRepository.readyTargets(state.providers)
        val target = resolveReplyTarget(message, conv, state.providers, ready)
        val provider = target?.let { t ->
            state.providers.firstOrNull { it.id.equals(t.providerID, ignoreCase = true) }
        }
        if (target == null || provider == null) {
            bannerError.value = L10n.text("没有可用的模型用于生成测验。", "No ready model available to generate quiz.")
            return
        }
        runWithConsent(consentSummaryFor(listOf(target to provider))) {
            bannerError.value = null
            viewModelScope.launch {
                studyGeneratingMessageID.value = message.id
                try {
                    val quiz = StudyGeneratorService.requestQuiz(
                        sourceText = message.content,
                        fallbackTitle = conv.title,
                        target = target,
                        provider = provider,
                        conversationID = conv.id,
                        messageID = message.id,
                        repo = repo,
                        secretStore = container.secretStore,
                        llmClient = container.llmClient
                    )
                    repo.saveMessage(
                        message.copy(
                            assistanceMetadata = message.assistanceMetadata.copy(generatedQuiz = quiz)
                        )
                    )
                } catch (t: Throwable) {
                    if (t !is CancellationException) {
                        bannerError.value = t.message ?: L10n.text("生成测验失败", "Failed to generate quiz")
                    }
                } finally {
                    studyGeneratingMessageID.value = null
                }
            }
        }
    }

    fun selectQuizOption(message: ChatMessageItem, questionID: String, optionIndex: Int) {
        val quiz = message.assistanceMetadata.generatedQuiz ?: return
        val updatedQuestions = quiz.questions.map { q ->
            if (q.id == questionID) q.copy(selectedIndex = optionIndex) else q
        }
        viewModelScope.launch {
            repo.saveMessage(
                message.copy(
                    assistanceMetadata = message.assistanceMetadata.copy(
                        generatedQuiz = quiz.copy(questions = updatedQuestions)
                    )
                )
            )
        }
    }

    fun saveDraftCardsToDeck(message: ChatMessageItem, drafts: List<StudyCardDraft>) {
        val convTitle = uiState.value.conversation?.title ?: ""
        container.flashcardRepository.addDrafts(
            drafts = drafts,
            deckName = convTitle,
            conversationID = message.conversationID,
            messageID = message.id
        )
    }

    fun approveProposedMemory(message: ChatMessageItem, fact: String) {
        viewModelScope.launch {
            repo.addPersonalMemory(fact)
            val currentHandled = message.assistanceMetadata.handledMemories
            if (!currentHandled.contains(fact)) {
                repo.saveMessage(
                    message.copy(
                        assistanceMetadata = message.assistanceMetadata.copy(
                            handledMemories = currentHandled + fact
                        )
                    )
                )
            }
        }
    }

    fun dismissProposedMemory(message: ChatMessageItem, fact: String) {
        viewModelScope.launch {
            val currentHandled = message.assistanceMetadata.handledMemories
            if (!currentHandled.contains(fact)) {
                repo.saveMessage(
                    message.copy(
                        assistanceMetadata = message.assistanceMetadata.copy(
                            handledMemories = currentHandled + fact
                        )
                    )
                )
            }
        }
    }

    fun clearBannerError() {
        bannerError.value = null
    }

    fun dismissConsent() {
        pendingConsent.value = null
    }

    fun acceptConsent() {
        val action = pendingConsent.value ?: return
        pendingConsent.value = null
        viewModelScope.launch {
            container.preferences.setAIConsentAccepted(true)
            action.onConfirm()
        }
    }

    fun attachUris(contentResolver: ContentResolver, uris: List<Uri>, imageOnly: Boolean) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            val current = draftAttachments.value.toMutableList()
            val added = runCatching {
                withContext(Dispatchers.IO) {
                    val parsed = uris.map { AttachmentProcessor.processUri(contentResolver, it, imageOnly) }
                    val combined = current + parsed
                    AttachmentProcessor.validate(combined)
                    combined
                }
            }
            added.onSuccess { draftAttachments.value = it }
                .onFailure { bannerError.value = it.message ?: L10n.text("附件添加失败", "Failed to add attachment") }
        }
    }

    fun removeDraftAttachment(id: String) {
        draftAttachments.value = draftAttachments.value.filterNot { it.id == id }
    }

    fun selectModel(target: ResolvedModelTarget) {
        val conv = uiState.value.conversation ?: return
        viewModelScope.launch {
            repo.saveConversation(
                conv.copy(
                    isArenaMode = false,
                    primaryTarget = target,
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun setArenaConfiguration(
        enabled: Boolean,
        targets: List<ResolvedModelTarget>,
        blindMode: Boolean
    ) {
        val conv = uiState.value.conversation ?: return
        viewModelScope.launch {
            repo.saveConversation(
                conv.copy(
                    isArenaMode = enabled,
                    arenaTargets = targets,
                    assistanceSettings = conv.assistanceSettings.copy(blindArenaMode = blindMode),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun toggleBlindArenaMode() {
        val conv = uiState.value.conversation ?: return
        viewModelScope.launch {
            val toggled = !conv.assistanceSettings.blindArenaMode
            repo.saveConversation(
                conv.copy(
                    assistanceSettings = conv.assistanceSettings.copy(blindArenaMode = toggled),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun updateGroupConfiguration(
        title: String,
        emoji: String,
        systemPrompt: String,
        members: List<GroupMember>,
        speakingMode: GroupSpeakingMode,
        speechStyle: GroupSpeechStyle,
        maxRelayTurns: Int,
        splitShortBubbles: Boolean
    ) {
        val conv = uiState.value.conversation ?: return
        val existingById = conv.groupMembers.associateBy { it.id.uppercase() }
        val preservedMembers = members.map { m ->
            m.preservingFeedProgress(existingById[m.id.uppercase()], keepEnabled = false)
        }
        viewModelScope.launch {
            repo.saveConversation(
                conv.copy(
                    title = title.trim().ifEmpty { conv.title },
                    assistantEmoji = emoji.trim().ifEmpty { conv.assistantEmoji },
                    systemPrompt = systemPrompt.trim(),
                    isArenaMode = false,
                    primaryTarget = preservedMembers.firstOrNull()?.target ?: conv.primaryTarget,
                    assistanceSettings = conv.assistanceSettings.copy(
                        isGroupMode = true,
                        groupMembers = preservedMembers,
                        groupSpeakingMode = speakingMode,
                        groupSpeechStyle = speechStyle,
                        groupMaxRelayTurns = maxRelayTurns.coerceIn(1, 6),
                        groupSplitShortBubbles = splitShortBubbles
                    ),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun toggleGroupMemberMuted(memberID: String) {
        val conv = uiState.value.conversation ?: return
        val updatedMembers = conv.groupMembers.map { m ->
            if (m.id.equals(memberID, ignoreCase = true)) m.copy(isMuted = !m.isMuted) else m
        }
        viewModelScope.launch {
            repo.saveConversation(
                conv.copy(
                    assistanceSettings = conv.assistanceSettings.copy(groupMembers = updatedMembers),
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    fun updateConversationSettings(updated: ConversationItem) {
        viewModelScope.launch {
            repo.saveConversation(updated)
        }
    }

    fun renameConversation(title: String) {
        val conv = uiState.value.conversation ?: return
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            repo.saveConversation(conv.copy(title = trimmed, updatedAtEpochMs = System.currentTimeMillis()))
        }
    }

    fun sendCurrentDraft() {
        val state = uiState.value
        val conv = state.conversation ?: return
        val text = state.draftText.trim()
        val attachments = state.draftAttachments
        val activeQuote = state.quotedExcerpt
        if (text.isEmpty() && attachments.isEmpty() && activeQuote.isNullOrBlank()) return

        val ready = ChatRepository.readyTargets(state.providers)

        if (conv.isGroupMode) {
            val activePairs = resolveGroupPairs(conv, state.providers, ready)
            if (activePairs.isEmpty()) {
                bannerError.value = L10n.text(
                    "群内暂无未静音且模型可用的成员，请检查群设置或服务商 API Key。",
                    "No unmuted group member has a ready model configured."
                )
                return
            }
            val summary = consentSummaryFor(activePairs.map { it.second to it.third }.distinctBy { it.first.id })
            runWithConsent(summary) {
                executeSendGroupMessage(text, attachments, conv, activeQuote)
            }
            return
        }

        if (state.isGenerating) return

        val capturedSearch = if (useWebSearchOnce.value) {
            text.take(TavilySearchClient.MAXIMUM_QUERY_CHARACTERS).ifBlank { null }
        } else null

        if (conv.isArenaMode) {
            val resolvedTargets = conv.arenaTargets.mapNotNull { chosen ->
                ready.firstOrNull { it.id == chosen.id }
            }
            if (resolvedTargets.size < 2) {
                bannerError.value = L10n.text(
                    "竞技场模式需至少选择 2 个可用模型（点击顶部模型栏配置）。",
                    "Arena mode requires at least 2 ready models (tap the top bar to configure)."
                )
                return
            }
            val resolvedPairs = resolvedTargets.mapNotNull { t ->
                val p = state.providers.firstOrNull { it.id.equals(t.providerID, ignoreCase = true) }
                if (p != null) t to p else null
            }
            if (resolvedPairs.size < 2) {
                bannerError.value = L10n.text("所选竞技场服务商不可用。", "Selected arena providers are unavailable.")
                return
            }
            val summary = consentSummaryFor(resolvedPairs)
            runWithConsent(summary) {
                useWebSearchOnce.value = false
                executeSendArenaMessage(text, attachments, conv, resolvedPairs, capturedSearch, activeQuote)
            }
            return
        }

        val overrideTarget = state.temporaryTargetOverride?.let { ov ->
            ready.firstOrNull { it.id == ov.id }
        }
        val target = overrideTarget ?: resolveActiveTarget(conv, state.providers, ready)
        if (target == null) {
            bannerError.value = L10n.text(
                "请先在「服务商」配置 API Key 并启用至少一个模型。",
                "Configure an API key and enable at least one model in Providers first."
            )
            return
        }
        val provider = state.providers.firstOrNull { it.id.equals(target.providerID, ignoreCase = true) }
        if (provider == null) {
            bannerError.value = L10n.text("所选服务商不可用。", "Selected provider is unavailable.")
            return
        }

        runWithConsent(consentSummaryFor(listOf(target to provider))) {
            useWebSearchOnce.value = false
            executeSendSingleMessage(
                text = text,
                attachments = attachments,
                conv = conv,
                target = target,
                provider = provider,
                searchQuery = capturedSearch,
                quotedExcerptText = activeQuote,
                isTemporaryOverride = (overrideTarget != null)
            )
        }
    }

    fun continueGroupDiscussion() {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (!conv.isGroupMode || state.isGenerating) return
        val ready = ChatRepository.readyTargets(state.providers)
        val activePairs = resolveGroupPairs(conv, state.providers, ready)
        if (activePairs.isEmpty()) {
            bannerError.value = L10n.text("群内暂无可发言成员。", "No active group member available.")
            return
        }
        val summary = consentSummaryFor(activePairs.map { it.second to it.third }.distinctBy { it.first.id })
        runWithConsent(summary) {
            bannerError.value = null
            launchGroupRelayJob(conv, GroupRunMode.ContinueDiscussion)
        }
    }

    fun startGroupVote() {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (!conv.isGroupMode || state.isGenerating) return
        val ready = ChatRepository.readyTargets(state.providers)
        val activePairs = resolveGroupPairs(conv, state.providers, ready)
        if (activePairs.isEmpty()) {
            bannerError.value = L10n.text("群内暂无可发言成员。", "No active group member available.")
            return
        }
        val summary = consentSummaryFor(activePairs.map { it.second to it.third }.distinctBy { it.first.id })
        runWithConsent(summary) {
            bannerError.value = null
            viewModelScope.launch {
                val now = System.currentTimeMillis()
                val allMsgs = repo.getMessages(conv.id)
                val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
                val parentId = if (treeActive) ConversationTree.currentAnchorID(conv.activeLeafMessageID, allMsgs) else null
                val nextSort = (allMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
                val votePrompt = makeUserMessage(
                    conversationID = conv.id,
                    text = L10n.text(
                        "🗳️ 发起圆桌表决：请各位明确亮牌（赞成 / 反对 / 中立），并用 1～3 句话说明核心理由。",
                        "🗳️ Roundtable Vote: State your stance (Agree / Disagree / Neutral) and explain your core reasoning in 1–3 sentences."
                    ),
                    attachments = emptyList(),
                    sortIndex = nextSort,
                    createdAtEpochMs = now,
                    parentMessageID = parentId
                )
                val updatedConv = if (treeActive) {
                    conv.copy(activeLeafMessageID = votePrompt.id, updatedAtEpochMs = now)
                } else conv
                repo.saveConversationAndMessages(updatedConv, listOf(votePrompt))
                launchGroupRelayJob(updatedConv, GroupRunMode.GroupVote)
            }
        }
    }

    fun summarizeGroupDiscussion(preferred: GroupMember? = null) {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (!conv.isGroupMode || state.isGenerating) return
        val ready = ChatRepository.readyTargets(state.providers)
        val activePairs = resolveGroupPairs(conv, state.providers, ready)
        if (activePairs.isEmpty()) {
            bannerError.value = L10n.text("群内暂无可发言成员。", "No active group member available.")
            return
        }
        val chosen = preferred?.let { p -> activePairs.firstOrNull { it.first.id == p.id }?.first }
            ?: activePairs.last().first
        val summary = consentSummaryFor(activePairs.map { it.second to it.third }.distinctBy { it.first.id })
        runWithConsent(summary) {
            bannerError.value = null
            viewModelScope.launch {
                val now = System.currentTimeMillis()
                val allMsgs = repo.getMessages(conv.id)
                val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
                val parentId = if (treeActive) ConversationTree.currentAnchorID(conv.activeLeafMessageID, allMsgs) else null
                val nextSort = (allMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
                val sumPrompt = makeUserMessage(
                    conversationID = conv.id,
                    text = L10n.text(
                        "📋 @${chosen.mentionToken} 请帮大家梳理总结目前讨论的核心共识、关键分歧与下一步行动建议。",
                        "📋 @${chosen.mentionToken} Please synthesize our core consensus, key disagreements, and recommended next steps."
                    ),
                    attachments = emptyList(),
                    sortIndex = nextSort,
                    createdAtEpochMs = now,
                    parentMessageID = parentId
                )
                val updatedConv = if (treeActive) {
                    conv.copy(activeLeafMessageID = sumPrompt.id, updatedAtEpochMs = now)
                } else conv
                repo.saveConversationAndMessages(updatedConv, listOf(sumPrompt))
                launchGroupRelayJob(updatedConv, GroupRunMode.Summarize(chosen))
            }
        }
    }

    fun regenerateMessage(assistantMessage: ChatMessageItem) {
        val state = uiState.value
        if (state.isGenerating) return
        val conv = state.conversation ?: return
        val ready = ChatRepository.readyTargets(state.providers)

        if (assistantMessage.isSynthesis && assistantMessage.comparisonGroupID != null) {
            val judgeTarget = resolveReplyTarget(assistantMessage, conv, state.providers, ready)
            if (judgeTarget == null) {
                bannerError.value = L10n.text("原裁判模型当前不可用。", "The judge model is currently unavailable.")
                return
            }
            synthesizeGroup(assistantMessage.comparisonGroupID, judgeTarget)
            return
        }

        val idx = state.messages.indexOfFirst { it.id == assistantMessage.id }
        if (idx <= 0) return

        val sliceIndex = assistantMessage.comparisonGroupID?.let { gid ->
            state.messages.indexOfFirst { it.comparisonGroupID.equals(gid, ignoreCase = true) }
        }?.takeIf { it >= 0 } ?: idx

        val groupSpeaker = if (conv.isGroupMode) {
            assistantMessage.assistanceMetadata.groupMemberID?.let { gid ->
                conv.groupMembers.firstOrNull { it.id.equals(gid, ignoreCase = true) }
            }
        } else null

        val resolved = groupSpeaker?.target?.let { gt -> ready.firstOrNull { it.id == gt.id } }
            ?: resolveReplyTarget(assistantMessage, conv, state.providers, ready)
        val provider = resolved?.let { r -> state.providers.firstOrNull { it.id.equals(r.providerID, ignoreCase = true) } }
        if (resolved == null || provider == null) {
            bannerError.value = L10n.text("没有可用的模型用于重答。", "No ready model available to regenerate.")
            return
        }

        val priorMessages = state.messages.subList(0, sliceIndex)
        if (groupSpeaker != null) {
            val preferEng = GroupDiscussionCoordinator.prefersEnglishPrompts(priorMessages)
            val intent = assistantMessage.assistanceMetadata.groupSpeechIntent ?: GroupSpeechIntent.OPEN_PERSPECTIVE
            var excerpts: List<PersonaExcerpt>? = null
            val memberHistory = GroupDiscussionCoordinator.buildPromptHistory(
                messages = priorMessages,
                speaker = groupSpeaker,
                limit = conv.contextMessageLimit,
                preferEnglish = preferEng,
                recordReferences = { excerpts = it }
            )
            val sysPrompt = GroupDiscussionCoordinator.buildSystemPrompt(
                speaker = groupSpeaker,
                activeMembers = conv.activeGroupMembers.ifEmpty { listOf(groupSpeaker) },
                speechStyle = conv.assistanceSettings.groupSpeechStyle,
                intent = intent,
                baseSystemPrompt = conv.systemPrompt,
                allowPass = false,
                preferEnglish = preferEng
            )
            val resetReply = assistantMessage.copy(
                providerID = resolved.providerID,
                providerName = resolved.providerName,
                modelID = resolved.modelID,
                modelDisplayName = resolved.modelDisplayName,
                accentHex = groupSpeaker.accentHex,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                assistanceMetadata = assistantMessage.assistanceMetadata.copy(
                    personaExcerpts = excerpts,
                    toolCalls = emptyList(),
                    search = null
                )
            )
            runWithConsent(consentSummaryFor(listOf(resolved to provider))) {
                bannerError.value = null
                launchSlots(
                    conversation = conv.copy(updatedAtEpochMs = System.currentTimeMillis()),
                    extraMessagesToInsert = emptyList(),
                    slots = listOf(
                        StreamSlot(
                            message = resetReply,
                            target = resolved,
                            provider = provider,
                            history = memberHistory,
                            kind = RequestKind.REGENERATION,
                            systemPromptOverride = sysPrompt,
                            temperatureOverride = groupSpeaker.temperature,
                            groupSanitizer = GroupStreamSanitizer(groupSpeaker.name, groupSpeaker.displayLabel)
                        )
                    )
                )
            }
            return
        }

        if (!conv.isArenaMode && !conv.isGroupMode &&
            !assistantMessage.isSynthesis && assistantMessage.comparisonGroupID == null
        ) {
            runWithConsent(consentSummaryFor(listOf(resolved to provider))) {
                executeBranchRegenerate(assistantMessage, conv, resolved, provider)
            }
            return
        }

        val history = buildSinglePromptHistoryWithPersona(priorMessages, conv)
        if (history.isEmpty()) return

        runWithConsent(consentSummaryFor(listOf(resolved to provider))) {
            executeRegenerate(assistantMessage, history, conv, resolved, provider)
        }
    }

    fun compareWithAnotherModel(assistantMessage: ChatMessageItem, secondTarget: ResolvedModelTarget) {
        val state = uiState.value
        if (state.isGenerating) return
        val conv = state.conversation ?: return
        if (assistantMessage.role != MessageRole.ASSISTANT || assistantMessage.comparisonGroupID != null) return

        val ready = ChatRepository.readyTargets(state.providers)
        val resolvedSecond = ready.firstOrNull { it.id == secondTarget.id }
        val secondProvider = resolvedSecond?.let { t ->
            state.providers.firstOrNull { it.id.equals(t.providerID, ignoreCase = true) }
        }
        if (resolvedSecond == null || secondProvider == null) {
            bannerError.value = L10n.text("所选对比模型不可用。", "Selected comparison model is unavailable.")
            return
        }

        val targetIdx = state.messages.indexOfFirst { it.id == assistantMessage.id }
        if (targetIdx <= 0) return
        val priorMessages = state.messages.subList(0, targetIdx)
        val history = ChatRepository.buildPromptHistory(priorMessages, conv.contextMessageLimit)
        if (history.isEmpty()) return

        runWithConsent(consentSummaryFor(listOf(resolvedSecond to secondProvider))) {
            bannerError.value = null
            val allMsgs = latestAllMessages.ifEmpty { state.messages }
            val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
            val groupID = UUID.randomUUID().toString().uppercase()
            val promotedOriginal = assistantMessage.copy(
                comparisonGroupID = groupID,
                isSelectedInGroup = true
            )
            val secondReply = ChatMessageItem(
                id = UUID.randomUUID().toString().uppercase(),
                conversationID = conv.id,
                role = MessageRole.ASSISTANT,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                providerID = resolvedSecond.providerID,
                providerName = resolvedSecond.providerName,
                modelID = resolvedSecond.modelID,
                modelDisplayName = resolvedSecond.modelDisplayName,
                accentHex = resolvedSecond.accentHex,
                comparisonGroupID = groupID,
                isSelectedInGroup = false,
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = null,
                latestRequestID = null,
                parentMessageID = if (treeActive) assistantMessage.parentMessageID else null,
                sortIndex = assistantMessage.sortIndex,
                createdAtEpochMs = assistantMessage.createdAtEpochMs + 1L
            )
            val slot = StreamSlot(
                message = secondReply,
                target = resolvedSecond,
                provider = secondProvider,
                history = history,
                kind = RequestKind.ANSWER
            )
            launchSlots(
                conversation = conv.copy(updatedAtEpochMs = System.currentTimeMillis()),
                extraMessagesToInsert = listOf(promotedOriginal),
                slots = listOf(slot)
            )
        }
    }

    fun selectContextReply(reply: ChatMessageItem) {
        val state = uiState.value
        if (state.isGenerating) return
        val gid = reply.comparisonGroupID ?: return
        val group = state.messages.filter { it.comparisonGroupID.equals(gid, ignoreCase = true) }
        if (group.none { it.id == reply.id }) return
        if (reply.isSynthesis && (!ArenaSynthesis.isComplete(reply) || !ArenaSynthesis.isCurrent(reply, state.messages))) {
            return
        }
        viewModelScope.launch {
            for (msg in group) {
                val shouldSelect = msg.id == reply.id
                if (msg.isSelectedInGroup != shouldSelect) {
                    repo.saveMessage(msg.copy(isSelectedInGroup = shouldSelect))
                }
            }
        }
    }

    fun castBlindVote(winner: ChatMessageItem) {
        val state = uiState.value
        val conv = state.conversation ?: return
        if (!conv.assistanceSettings.blindArenaMode || state.isGenerating) return
        val gid = winner.comparisonGroupID ?: return
        val group = ArenaSynthesis.sources(state.messages, gid)
        if (group.any { it.assistanceMetadata.blindArenaRevealed }) return
        val eligible = group.filter(ArenaSynthesis::isComplete)
        if (eligible.size < 2 || eligible.none { it.id == winner.id }) return

        val ballot = ArenaBallot(
            winnerID = winner.id,
            candidates = eligible.map {
                ArenaBallot.Candidate(
                    messageID = it.id,
                    providerID = it.providerID,
                    providerName = it.providerName,
                    modelID = it.modelID,
                    modelName = it.modelDisplayName
                )
            }
        )
        viewModelScope.launch {
            for (msg in group) {
                val updatedMeta = msg.assistanceMetadata.copy(
                    blindArenaRevealed = true,
                    blindArenaBallot = if (msg.id == winner.id) ballot else msg.assistanceMetadata.blindArenaBallot
                )
                repo.saveMessage(
                    msg.copy(
                        isSelectedInGroup = (msg.id == winner.id),
                        assistanceMetadata = updatedMeta
                    )
                )
            }
        }
    }

    fun synthesizeGroup(groupID: String, judgeTarget: ResolvedModelTarget) {
        val state = uiState.value
        if (state.isGenerating) return
        val conv = state.conversation ?: return
        val ready = ChatRepository.readyTargets(state.providers)
        val resolvedJudge = ready.firstOrNull { it.id == judgeTarget.id }
        val judgeProvider = resolvedJudge?.let { t ->
            state.providers.firstOrNull { it.id.equals(t.providerID, ignoreCase = true) }
        }
        if (resolvedJudge == null || judgeProvider == null) {
            bannerError.value = L10n.text("所选裁判模型当前不可用。", "Selected judge model is unavailable.")
            return
        }

        val messages = state.messages
        val allOriginals = ArenaSynthesis.sources(messages, groupID)
        val eligible = ArenaSynthesis.eligibleSources(messages, groupID)
        if (eligible.size < 2) {
            bannerError.value = L10n.text("至少需要两条完整回答才能由裁判汇总。", "At least 2 complete answers are required to synthesize.")
            return
        }

        val firstGroupIdx = messages.indexOfFirst { it.comparisonGroupID.equals(groupID, ignoreCase = true) }
        if (firstGroupIdx <= 0) return
        val priorMessages = messages.subList(0, firstGroupIdx)
        if (priorMessages.lastOrNull()?.role != MessageRole.USER) {
            bannerError.value = L10n.text("找不到对应的问题消息，无法汇总。", "Cannot locate the original question for this group.")
            return
        }

        val isUnrevealedBlind = conv.assistanceSettings.blindArenaMode &&
            allOriginals.none { it.assistanceMetadata.blindArenaRevealed }
        val historySnapshot = ChatRepository.buildPromptHistory(priorMessages, conv.contextMessageLimit) +
            LLMPromptMessage(
                role = MessageRole.USER,
                content = ArenaSynthesis.candidatePrompt(
                    eligible = eligible,
                    totalCount = allOriginals.size,
                    blind = isUnrevealedBlind,
                    allGroupCandidates = allOriginals
                )
            )
        val digest = ArenaSynthesis.digest(allOriginals)
        val existingSynthesis = messages.firstOrNull {
            it.comparisonGroupID.equals(groupID, ignoreCase = true) && it.isSynthesis
        }
        val groupMaxSort = messages
            .filter { it.comparisonGroupID.equals(groupID, ignoreCase = true) }
            .maxOfOrNull { it.sortIndex }
            ?: (messages.maxOfOrNull { it.sortIndex } ?: 0)
        val now = System.currentTimeMillis()

        val summaryMessage = if (existingSynthesis != null) {
            existingSynthesis.copy(
                providerID = resolvedJudge.providerID,
                providerName = resolvedJudge.providerName,
                modelID = resolvedJudge.modelID,
                modelDisplayName = resolvedJudge.modelDisplayName,
                accentHex = resolvedJudge.accentHex,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = digest
            )
        } else {
            ChatMessageItem(
                id = UUID.randomUUID().toString().uppercase(),
                conversationID = conv.id,
                role = MessageRole.ASSISTANT,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                providerID = resolvedJudge.providerID,
                providerName = resolvedJudge.providerName,
                modelID = resolvedJudge.modelID,
                modelDisplayName = resolvedJudge.modelDisplayName,
                accentHex = resolvedJudge.accentHex,
                comparisonGroupID = groupID.uppercase(),
                isSelectedInGroup = false,
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = digest,
                latestRequestID = null,
                parentMessageID = if (ConversationTree.usesTree(conv.activeLeafMessageID, latestAllMessages.ifEmpty { messages })) {
                    allOriginals.firstOrNull()?.parentMessageID
                } else null,
                sortIndex = groupMaxSort + 1,
                createdAtEpochMs = now
            )
        }

        runWithConsent(consentSummaryFor(listOf(resolvedJudge to judgeProvider))) {
            bannerError.value = null
            launchSlots(
                conversation = conv.copy(updatedAtEpochMs = System.currentTimeMillis()),
                extraMessagesToInsert = emptyList(),
                slots = listOf(
                    StreamSlot(
                        message = summaryMessage,
                        target = resolvedJudge,
                        provider = judgeProvider,
                        history = historySnapshot,
                        kind = RequestKind.SYNTHESIS,
                        systemPromptOverride = ArenaSynthesis.SYSTEM_PROMPT
                    )
                )
            )
        }
    }

    fun crossCritiqueGroup(groupID: String) {
        val state = uiState.value
        if (state.isGenerating) return
        val conv = state.conversation ?: return
        val ready = ChatRepository.readyTargets(state.providers)

        val messages = state.messages
        val eligible = ArenaSynthesis.eligibleSources(messages, groupID)
        if (eligible.size < 2) {
            bannerError.value = L10n.text("至少需要两条完整回答才能互评修正。", "At least 2 complete answers are required for cross-critique.")
            return
        }

        val resolvedPairs = eligible.mapNotNull { src ->
            val pid = src.providerID ?: return@mapNotNull null
            val target = ready.firstOrNull { it.providerID.equals(pid, ignoreCase = true) && it.modelID == src.modelID }
                ?: return@mapNotNull null
            val provider = state.providers.firstOrNull { it.id.equals(target.providerID, ignoreCase = true) }
                ?: return@mapNotNull null
            target to provider
        }
        if (resolvedPairs.size != eligible.size) {
            bannerError.value = L10n.text(
                "同组中部分候选模型已禁用或移除，无法发起全部互评。",
                "Some candidate models in this group are unavailable for cross-critique."
            )
            return
        }

        val firstGroupIdx = messages.indexOfFirst { it.comparisonGroupID.equals(groupID, ignoreCase = true) }
        if (firstGroupIdx <= 0) return
        val priorMessages = messages.subList(0, firstGroupIdx)
        if (priorMessages.lastOrNull()?.role != MessageRole.USER) {
            bannerError.value = L10n.text("找不到对应的问题消息，无法发起互评。", "Cannot locate the original question.")
            return
        }

        val baseHistory = ChatRepository.buildPromptHistory(priorMessages, conv.contextMessageLimit)
        val isUnrevealedBlind = conv.assistanceSettings.blindArenaMode &&
            eligible.none { it.assistanceMetadata.blindArenaRevealed }
        val allMsgs = latestAllMessages.ifEmpty { messages }
        val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
        val groupMembers = messages.filter { it.comparisonGroupID.equals(groupID, ignoreCase = true) }
        val groupWinner = groupMembers.firstOrNull { it.isSelectedInGroup } ?: groupMembers.firstOrNull()
        val nextSort = (allMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
        val now = System.currentTimeMillis()

        val critiquePromptMsg = ChatMessageItem(
            id = UUID.randomUUID().toString().uppercase(),
            conversationID = conv.id,
            role = MessageRole.USER,
            content = L10n.text(
                "请各模型审阅同组其他候选答案，吸收优点并修正遗漏或错误，给出完善后的最终回答。",
                "Please review the other candidate answers, adopt their strengths, fix any errors or gaps, and provide a refined final answer."
            ),
            reasoningContent = "",
            attachments = emptyList(),
            providerID = null,
            providerName = "",
            modelID = "",
            modelDisplayName = "",
            accentHex = "#3F6EF6",
            comparisonGroupID = null,
            isSelectedInGroup = true,
            isStreaming = false,
            errorMessage = null,
            finishReason = null,
            promptTokens = null,
            completionTokens = null,
            cachedTokens = null,
            latencyMs = null,
            thinkingDurationMs = null,
            synthesisSourceDigest = null,
            latestRequestID = null,
            parentMessageID = if (treeActive) groupWinner?.id else null,
            sortIndex = nextSort,
            createdAtEpochMs = now
        )

        val newGroupID = UUID.randomUUID().toString().uppercase()
        val slots = resolvedPairs.mapIndexed { idx, (target, provider) ->
            val reply = ChatMessageItem(
                id = UUID.randomUUID().toString().uppercase(),
                conversationID = conv.id,
                role = MessageRole.ASSISTANT,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                providerID = target.providerID,
                providerName = target.providerName,
                modelID = target.modelID,
                modelDisplayName = target.modelDisplayName,
                accentHex = target.accentHex,
                comparisonGroupID = newGroupID,
                isSelectedInGroup = (idx == 0),
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = null,
                latestRequestID = null,
                parentMessageID = if (treeActive) critiquePromptMsg.id else null,
                sortIndex = nextSort + 1 + idx,
                createdAtEpochMs = now + 1L + idx
            )
            val slotHistory = baseHistory + LLMPromptMessage(
                role = MessageRole.USER,
                content = ArenaSynthesis.critiquePrompt(target, eligible, blind = isUnrevealedBlind)
            )
            StreamSlot(
                message = reply,
                target = target,
                provider = provider,
                history = slotHistory,
                kind = RequestKind.ANSWER,
                systemPromptOverride = ArenaSynthesis.CRITIQUE_SYSTEM_PROMPT
            )
        }

        runWithConsent(consentSummaryFor(resolvedPairs)) {
            bannerError.value = null
            launchSlots(
                conversation = conv.copy(
                    activeLeafMessageID = if (treeActive) slots.first().message.id else conv.activeLeafMessageID,
                    updatedAtEpochMs = now
                ),
                extraMessagesToInsert = listOf(critiquePromptMsg),
                slots = slots
            )
        }
    }

    fun stopGeneration() {
        cancelPendingWebpageApproval()
        activeJob?.cancel()
    }

    private fun cancelPendingWebpageApproval() {
        val deferred = pendingApprovalDeferred
        pendingApprovalDeferred = null
        pendingWebpageApproval.value = null
        deferred?.complete(WebpageApprovalDecision.DENY)
    }

    private suspend fun requestWebpageApproval(
        uri: URI,
        userProvidedURLs: Set<String>
    ): WebpageApprovalDecision {
        val canonicalKey = AgentToolRunner.canonicalURLKey(uri)
        if (userProvidedURLs.contains(canonicalKey)) {
            return WebpageApprovalDecision.ALLOW
        }
        val host = uri.host?.lowercase().orEmpty()
        if (uri.rawQuery == null && host.isNotEmpty() && approvedWebpageHosts.contains(host)) {
            return WebpageApprovalDecision.ALLOW
        }

        val deferred = CompletableDeferred<WebpageApprovalDecision>()
        cancelPendingWebpageApproval()
        pendingApprovalDeferred = deferred
        val requestId = UUID.randomUUID().toString()
        pendingWebpageApproval.value = PendingWebpageApproval(
            id = requestId,
            url = uri.toASCIIString(),
            host = host,
            hasQuery = uri.rawQuery != null,
            onResolve = { allow, rememberHost ->
                if (allow && rememberHost && uri.rawQuery == null && host.isNotEmpty()) {
                    approvedWebpageHosts.add(host)
                }
                pendingWebpageApproval.value = null
                deferred.complete(if (allow) WebpageApprovalDecision.ALLOW else WebpageApprovalDecision.DENY)
            }
        )

        return try {
            deferred.await()
        } finally {
            if (pendingApprovalDeferred === deferred) {
                pendingApprovalDeferred = null
                pendingWebpageApproval.value = null
            }
        }
    }

    private fun runWithConsent(summary: String, block: () -> Unit) {
        if (!container.preferences.isConsentAccepted) {
            pendingConsent.value = PendingConsentAction(summary, block)
        } else {
            block()
        }
    }

    private fun consentSummaryFor(pairs: List<Pair<ResolvedModelTarget, ProviderItem>>): String {
        if (pairs.size == 1) {
            val (target, provider) = pairs[0]
            val host = runCatching { URI(provider.baseURL.trim().trimEnd('#')).host ?: "" }.getOrDefault("")
            return if (host.isEmpty()) "${provider.name} · ${target.modelDisplayName}"
            else "${provider.name} · ${target.modelDisplayName} ($host)"
        }
        return L10n.text(
            "${pairs.size} 个模型：" + pairs.joinToString(" / ") { it.first.modelDisplayName },
            "${pairs.size} models: " + pairs.joinToString(" / ") { it.first.modelDisplayName }
        )
    }

    private fun executeSendGroupMessage(
        text: String,
        attachments: List<MessageAttachment>,
        conv: ConversationItem,
        quotedExcerptText: String? = null
    ) {
        val capturedSearch = if (useWebSearchOnce.value) {
            text.take(TavilySearchClient.MAXIMUM_QUERY_CHARACTERS).ifBlank { null }
        } else null
        useWebSearchOnce.value = false
        draftText.value = ""
        draftAttachments.value = emptyList()
        quotedExcerpt.value = null
        bannerError.value = null

        val previousJob = activeJob
        activeJob = viewModelScope.launch {
            if (previousJob != null && previousJob.isActive) {
                cancelPendingWebpageApproval()
                previousJob.cancelAndJoin()
                cleanupInterruptedGroupTail(conv.id)
            }
            val currentMessages = repo.getMessages(conv.id)
            val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, currentMessages)
            val parentId = if (treeActive) ConversationTree.currentAnchorID(conv.activeLeafMessageID, currentMessages) else null
            val nextSort = (currentMessages.maxOfOrNull { it.sortIndex } ?: 0) + 1
            val now = System.currentTimeMillis()
            val userMsg = makeUserMessage(
                conversationID = conv.id,
                text = text,
                attachments = attachments,
                sortIndex = nextSort,
                createdAtEpochMs = now,
                quotedExcerpt = quotedExcerptText,
                parentMessageID = parentId
            )

            val updatedTitle = if (currentMessages.none { it.role == MessageRole.USER } &&
                ConversationItem.isDefaultTitle(conv.title)
            ) {
                ChatRepository.makeConversationTitle(text, attachments)
            } else {
                conv.title
            }
            val updatedConv = conv.copy(
                title = updatedTitle,
                activeLeafMessageID = if (treeActive) userMsg.id else conv.activeLeafMessageID,
                updatedAtEpochMs = now
            )
            repo.saveConversationAndMessages(updatedConv, listOf(userMsg))

            runGroupRelaySession(updatedConv, GroupRunMode.AfterUserMessage(userMsg, capturedSearch))
        }
    }

    private fun launchGroupRelayJob(
        conv: ConversationItem,
        mode: GroupRunMode
    ) {
        activeJob?.cancel()
        activeJob = viewModelScope.launch {
            runGroupRelaySession(conv, mode)
        }
    }

    private suspend fun cleanupInterruptedGroupTail(convId: String) {
        val last = repo.getMessages(convId).lastOrNull() ?: return
        if (last.role != MessageRole.ASSISTANT) return
        if (last.content.isBlank() && last.reasoningContent.isBlank() && last.attachments.isEmpty()) {
            repo.deleteMessage(last.id)
        } else if (last.errorMessage == L10n.text("已停止生成", "Generation stopped") ||
            last.errorMessage == "Generation stopped" ||
            last.errorMessage == "已停止生成"
        ) {
            repo.saveMessage(last.copy(errorMessage = null))
        }
    }

    private suspend fun performTavilySearchWithLedger(
        query: String,
        conversationId: String,
        messageId: String
    ): SearchEvidence {
        val searchStartEpoch = System.currentTimeMillis()
        val searchStartNanos = System.nanoTime()
        var record = RequestRecordItem(
            id = UUID.randomUUID().toString().uppercase(),
            operationID = UUID.randomUUID().toString().uppercase(),
            attempt = 1,
            conversationID = conversationId,
            messageID = messageId,
            providerID = TavilySearchClient.PROVIDER_ID,
            providerName = "Tavily",
            modelID = "web-search",
            modelDisplayName = "Tavily Search",
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            kind = RequestKind.WEB_SEARCH,
            status = RequestStatus.RUNNING,
            startedAtEpochMs = searchStartEpoch,
            endedAtEpochMs = null,
            firstReasoningMs = null,
            firstContentMs = null,
            lastOutputMs = null,
            durationMs = null,
            outputChunkCount = 0,
            isStreamed = false,
            promptTokens = null,
            completionTokens = null,
            cachedTokens = null,
            cacheWriteTokens = null,
            httpStatus = null,
            inputPricePerMillion = null,
            outputPricePerMillion = null,
            cacheReadPricePerMillion = null,
            cacheWritePricePerMillion = null,
            currency = null
        )
        repo.saveRequestRecord(record)

        try {
            val apiKey = container.secretStore.loadSecret(SecretStore.TAVILY_KEY_ACCOUNT)
            val evidence = TavilySearchClient.search(query, apiKey)
            val elapsed = ((System.nanoTime() - searchStartNanos) / 1_000_000L).toInt().coerceAtLeast(0)
            record = record.copy(
                status = RequestStatus.SUCCEEDED,
                durationMs = elapsed,
                endedAtEpochMs = System.currentTimeMillis()
            )
            repo.saveRequestRecord(record)
            return evidence
        } catch (t: Throwable) {
            val elapsed = ((System.nanoTime() - searchStartNanos) / 1_000_000L).toInt().coerceAtLeast(0)
            val httpCode = (t as? SearchError.Http)?.statusCode
            val status = if (t is CancellationException) RequestStatus.CANCELLED else RequestStatus.FAILED
            record = record.copy(
                status = status,
                httpStatus = httpCode,
                durationMs = elapsed,
                endedAtEpochMs = System.currentTimeMillis()
            )
            repo.saveRequestRecord(record)
            throw t
        }
    }

    private suspend fun runGroupRelaySession(
        initialConversation: ConversationItem,
        mode: GroupRunMode
    ) {
        val providers = repo.getProviders()
        val ready = ChatRepository.readyTargets(providers)
        val initialPairs = resolveGroupPairs(initialConversation, providers, ready)
        if (initialPairs.isEmpty()) return

        val settings = initialConversation.assistanceSettings
        val activeMembers = initialPairs.map { it.first }

        data class RelayStep(
            val member: GroupMember,
            val intent: GroupSpeechIntent,
            val allowPass: Boolean
        )

        var preSearchQuery: String? = null
        var searchEvidence: SearchEvidence? = null
        if (mode is GroupRunMode.AfterUserMessage && !mode.searchQuery.isNullOrBlank()) {
            preSearchQuery = mode.searchQuery
            try {
                searchEvidence = performTavilySearchWithLedger(
                    query = mode.searchQuery,
                    conversationId = initialConversation.id,
                    messageId = mode.userMessage.id
                )
            } catch (t: Throwable) {
                if (t !is CancellationException) {
                    bannerError.value = t.message ?: L10n.text("联网搜索失败", "Web search failed")
                }
                return
            }
        }

        val allBeforeRound = repo.getMessages(initialConversation.id)
        var currentLeafID: String? = initialConversation.activeLeafMessageID
        val treeActive = ConversationTree.usesTree(currentLeafID, allBeforeRound)
        val priorBeforeRound = if (treeActive) {
            ConversationTree.activeMessages(currentLeafID, allBeforeRound)
        } else allBeforeRound
        val knowledgeQuery = when (mode) {
            is GroupRunMode.AfterUserMessage -> mode.userMessage.content
            else -> priorBeforeRound.lastOrNull { it.role == MessageRole.USER }?.content.orEmpty()
        }
        val groupKnowledge = if (settings.knowledgeVolumeIDs.isNotEmpty() && knowledgeQuery.isNotBlank()) {
            retrieveKnowledgeForTurn(settings.knowledgeVolumeIDs, knowledgeQuery)
        } else null

        val explicitQueue = ArrayDeque<RelayStep>()
        var maxRelayTurns = 1
        var dynamicSmartRelay = false

        when (mode) {
            is GroupRunMode.AfterUserMessage -> {
                val priorOnly = priorBeforeRound.filterNot { it.id == mode.userMessage.id }
                val planned = GroupDiscussionCoordinator.selectInitialPlan(
                    userText = mode.userMessage.content,
                    activeMembers = activeMembers,
                    speakingMode = settings.groupSpeakingMode,
                    maxRelayTurns = settings.groupMaxRelayTurns,
                    priorMessages = priorOnly
                )
                if (planned.isEmpty()) {
                    if (settings.groupSpeakingMode == GroupSpeakingMode.MENTION_ONLY) {
                        bannerError.value = L10n.text(
                            "仅 @点名模式下，使用 @成员名 点名才会触发发言。",
                            "In @Mention Only mode, use @MemberName to trigger a reply."
                        )
                    }
                    return
                }
                val hasExplicitMentions = planned.any { it.explicitMention }
                if (settings.groupSpeakingMode == GroupSpeakingMode.SMART_RELAY && !hasExplicitMentions) {
                    explicitQueue.add(RelayStep(planned[0].member, planned[0].intent, allowPass = false))
                    maxRelayTurns = minOf(maxOf(settings.groupMaxRelayTurns, 1), maxOf(activeMembers.size + 1, 2))
                    dynamicSmartRelay = true
                } else if (settings.groupSpeakingMode == GroupSpeakingMode.SMART_RELAY && hasExplicitMentions) {
                    planned.forEach { explicitQueue.add(RelayStep(it.member, it.intent, allowPass = false)) }
                    maxRelayTurns = maxOf(planned.size, settings.groupMaxRelayTurns)
                    dynamicSmartRelay = true
                } else {
                    planned.forEach { explicitQueue.add(RelayStep(it.member, it.intent, allowPass = !hasExplicitMentions)) }
                    maxRelayTurns = planned.size
                    dynamicSmartRelay = false
                }
            }
            GroupRunMode.ContinueDiscussion -> {
                val lastSpeakerID = priorBeforeRound.lastOrNull { it.role == MessageRole.ASSISTANT }
                    ?.assistanceMetadata?.groupMemberID
                val lastIdx = lastSpeakerID?.let { lid ->
                    activeMembers.indexOfFirst { it.id.equals(lid, ignoreCase = true) }
                } ?: -1
                val startIdx = if (lastIdx >= 0) (lastIdx + 1) % activeMembers.size else 0
                explicitQueue.add(RelayStep(activeMembers[startIdx], GroupSpeechIntent.REBUTTAL, allowPass = false))
                maxRelayTurns = minOf(maxOf(settings.groupMaxRelayTurns, 2), maxOf(activeMembers.size, 2))
                dynamicSmartRelay = true
            }
            GroupRunMode.GroupVote -> {
                activeMembers.forEach { explicitQueue.add(RelayStep(it, GroupSpeechIntent.VOTE, allowPass = false)) }
                maxRelayTurns = activeMembers.size
                dynamicSmartRelay = false
            }
            is GroupRunMode.Summarize -> {
                val chosen = mode.preferred?.let { p ->
                    activeMembers.firstOrNull { it.id.equals(p.id, ignoreCase = true) }
                } ?: activeMembers.last()
                explicitQueue.add(RelayStep(chosen, GroupSpeechIntent.SUMMARIZE, allowPass = false))
                maxRelayTurns = 1
                dynamicSmartRelay = false
            }
        }

        val englishPreferred = GroupDiscussionCoordinator.prefersEnglishPrompts(priorBeforeRound)
        var turnsCompleted = 0
        val spokenMemberIDs = HashSet<String>()
        val roundMessages = mutableListOf<ChatMessageItem>()
        var nextStep: RelayStep? = if (explicitQueue.isEmpty()) null else explicitQueue.removeFirst()

        try {
            while (nextStep != null && turnsCompleted < maxRelayTurns) {
                coroutineScope { ensureActive() }
                val step = nextStep
                val liveConv = repo.getConversation(initialConversation.id) ?: initialConversation
                val livePairs = resolveGroupPairs(liveConv, providers, ready)
                val matchedPair = livePairs.firstOrNull { it.first.id.equals(step.member.id, ignoreCase = true) }
                if (!liveConv.isGroupMode || matchedPair == null) {
                    nextStep = if (explicitQueue.isEmpty()) null else explicitQueue.removeFirst()
                    continue
                }

                val (member, target, provider) = matchedPair
                val liveActiveMembers = livePairs.map { it.first }
                activeGroupSpeaker.value = "${member.avatarEmoji} ${member.displayLabel}"
                GenerationServiceBridge.start(
                    container.appContext,
                    buildNotificationState(
                        conv = liveConv,
                        speakerOrModel = "${member.avatarEmoji} ${member.displayLabel}",
                        phaseText = L10n.text("正在发言…", "Speaking…")
                    )
                )

                val allCurrentMessages = repo.getMessages(liveConv.id)
                val priorMessages = if (treeActive) {
                    ConversationTree.activeMessages(currentLeafID, allCurrentMessages)
                } else allCurrentMessages
                val nextSort = (allCurrentMessages.maxOfOrNull { it.sortIndex } ?: 0) + 1
                val parentIdForTurn = if (treeActive) ConversationTree.currentAnchorID(currentLeafID, allCurrentMessages) else null
                val now = System.currentTimeMillis()
                var replyMeta = MessageAssistanceMetadata(
                    groupMemberID = member.id,
                    groupMemberName = member.name,
                    groupMemberTitle = member.title,
                    groupMemberEmoji = member.avatarEmoji,
                    isPersonaSimulation = member.isSimulatedPersona,
                    groupSpeechIntent = step.intent,
                    requestedSearchQuery = if (turnsCompleted == 0) preSearchQuery else null,
                    search = if (turnsCompleted == 0) searchEvidence else null,
                    knowledgeEvidence = if (turnsCompleted == 0) groupKnowledge else null
                )

                val trailingCue = when (step.intent) {
                    GroupSpeechIntent.VOTE -> if (englishPreferred) {
                        "[State your explicit vote now (Agree / Disagree / Neutral) and briefly explain why]"
                    } else {
                        "[请现在亮出你的表决态度（赞成 / 反对 / 中立）并简述理由]"
                    }
                    GroupSpeechIntent.SUMMARIZE -> if (englishPreferred) {
                        "[Synthesize and output the key consensus, disagreements, and next steps from the discussion now]"
                    } else {
                        "[请现在梳理并输出本轮群讨论纪要]"
                    }
                    else -> null
                }

                var recordedExcerpts: List<PersonaExcerpt>? = null
                var memberHistory = GroupDiscussionCoordinator.buildPromptHistory(
                    messages = priorMessages,
                    speaker = member,
                    limit = liveConv.contextMessageLimit,
                    trailingCueIfNeeded = trailingCue,
                    preferEnglish = englishPreferred,
                    recordReferences = { recordedExcerpts = it }
                )
                if (searchEvidence != null && memberHistory.isNotEmpty()) {
                    val last = memberHistory.last()
                    memberHistory = memberHistory.dropLast(1) + last.copy(
                        content = if (last.content.isEmpty()) searchEvidence.prompt else "${last.content}\n\n${searchEvidence.prompt}"
                    )
                }
                if (groupKnowledge != null && groupKnowledge.passages.isNotEmpty() && memberHistory.isNotEmpty()) {
                    val last = memberHistory.last()
                    val kPrompt = groupKnowledge.promptText()
                    memberHistory = memberHistory.dropLast(1) + last.copy(
                        content = if (last.content.isEmpty()) kPrompt else "${last.content}\n\n$kPrompt"
                    )
                }
                if (recordedExcerpts != null) {
                    replyMeta = replyMeta.copy(personaExcerpts = recordedExcerpts)
                }

                val replyPlaceholder = ChatMessageItem(
                    id = UUID.randomUUID().toString().uppercase(),
                    conversationID = liveConv.id,
                    role = MessageRole.ASSISTANT,
                    content = "",
                    reasoningContent = "",
                    attachments = emptyList(),
                    providerID = target.providerID,
                    providerName = target.providerName,
                    modelID = target.modelID,
                    modelDisplayName = target.modelDisplayName,
                    accentHex = member.accentHex,
                    comparisonGroupID = null,
                    isSelectedInGroup = true,
                    isStreaming = true,
                    errorMessage = null,
                    finishReason = null,
                    promptTokens = null,
                    completionTokens = null,
                    cachedTokens = null,
                    latencyMs = null,
                    thinkingDurationMs = null,
                    synthesisSourceDigest = null,
                    latestRequestID = null,
                    assistanceMetadata = replyMeta,
                    parentMessageID = parentIdForTurn,
                    sortIndex = nextSort,
                    createdAtEpochMs = now
                )

                streamingOverlays.update { it + (replyPlaceholder.id to replyPlaceholder) }
                if (treeActive) {
                    currentLeafID = replyPlaceholder.id
                    repo.saveConversationAndMessages(
                        liveConv.copy(activeLeafMessageID = currentLeafID, updatedAtEpochMs = now),
                        listOf(replyPlaceholder)
                    )
                } else {
                    repo.saveMessage(replyPlaceholder)
                }

                val systemPrompt = GroupDiscussionCoordinator.buildSystemPrompt(
                    speaker = member,
                    activeMembers = liveActiveMembers,
                    speechStyle = liveConv.assistanceSettings.groupSpeechStyle,
                    intent = step.intent,
                    baseSystemPrompt = liveConv.systemPrompt,
                    allowPass = step.allowPass || turnsCompleted > 0,
                    preferEnglish = englishPreferred
                )

                val slot = StreamSlot(
                    message = replyPlaceholder,
                    target = target,
                    provider = provider,
                    history = memberHistory,
                    kind = if (step.intent == GroupSpeechIntent.SUMMARIZE) RequestKind.SYNTHESIS else RequestKind.ANSWER,
                    systemPromptOverride = systemPrompt,
                    temperatureOverride = if (step.intent == GroupSpeechIntent.SUMMARIZE) 0.3 else member.temperature,
                    groupSanitizer = GroupStreamSanitizer(member.name, member.displayLabel)
                )

                val outcome = runSingleSlot(slot, liveConv)
                val directive = outcome.directive ?: GroupTurnDirective()
                var replyMsg = outcome.message

                val canHonorPass = (step.allowPass || turnsCompleted > 0 || explicitQueue.isNotEmpty()) && directive.isPass
                if (canHonorPass && replyMsg.errorMessage == null) {
                    repo.deleteMessage(replyMsg.id)
                    if (treeActive) {
                        currentLeafID = parentIdForTurn
                    }
                    if (explicitQueue.isNotEmpty()) {
                        nextStep = explicitQueue.removeFirst()
                    } else {
                        spokenMemberIDs.add(member.id.uppercase())
                        val remaining = liveActiveMembers.filter {
                            !spokenMemberIDs.contains(it.id.uppercase()) && !it.id.equals(member.id, ignoreCase = true)
                        }
                        nextStep = remaining.firstOrNull()?.let { RelayStep(it, step.intent, allowPass = false) }
                    }
                    continue
                }

                if (replyMsg.errorMessage != null) {
                    if (explicitQueue.isNotEmpty()) {
                        nextStep = explicitQueue.removeFirst()
                    } else if (dynamicSmartRelay) {
                        spokenMemberIDs.add(member.id.uppercase())
                        val remaining = liveActiveMembers.filter { !spokenMemberIDs.contains(it.id.uppercase()) }
                        nextStep = remaining.firstOrNull()?.let { RelayStep(it, step.intent, allowPass = true) }
                    } else {
                        nextStep = null
                    }
                    continue
                }

                val quote = GroupDiscussionCoordinator.resolveReplyQuote(
                    speaker = member,
                    visibleReply = replyMsg.content,
                    directive = directive,
                    intent = step.intent,
                    roundMessages = roundMessages,
                    activeMembers = liveActiveMembers
                )
                val updatedMeta = replyMsg.assistanceMetadata.copy(
                    groupAskedHost = directive.asksHost,
                    groupReplyToMessageID = quote?.messageID,
                    groupReplyToSpeaker = quote?.speakerName,
                    groupReplyToExcerpt = quote?.excerpt
                )

                if (directive.reactionEmoji != null) {
                    val targetForReaction = roundMessages.lastOrNull() ?: priorMessages.lastOrNull()
                    if (targetForReaction != null) {
                        val tMeta = targetForReaction.assistanceMetadata
                        if (tMeta.groupReactions.size < 2) {
                            val excluding = tMeta.groupReactions.map { it.memberID }.toSet() + member.id
                            val reaction = GroupDiscussionCoordinator.pickBystanderReaction(
                                emojiHint = directive.reactionEmoji,
                                excludingMemberIDs = excluding,
                                activeMembers = liveActiveMembers
                            )
                            if (reaction != null) {
                                val updatedTarget = targetForReaction.copy(
                                    assistanceMetadata = tMeta.copy(groupReactions = tMeta.groupReactions + reaction)
                                )
                                repo.saveMessage(updatedTarget)
                                val idx = roundMessages.indexOfFirst { it.id == updatedTarget.id }
                                if (idx >= 0) roundMessages[idx] = updatedTarget
                            }
                        }
                    }
                }

                val fullTextForRouting = replyMsg.content
                val burstParts = GroupDiscussionCoordinator.splitShortBubbles(
                    text = fullTextForRouting,
                    style = liveConv.assistanceSettings.groupSpeechStyle,
                    enabled = liveConv.assistanceSettings.groupSplitShortBubbles,
                    intent = step.intent
                )
                if (burstParts.size == 2) {
                    val firstMeta = if (directive.asksHost) updatedMeta.copy(groupAskedHost = false) else updatedMeta
                    val firstBubble = replyMsg.copy(content = burstParts[0], assistanceMetadata = firstMeta)
                    repo.saveMessage(firstBubble)
                    delay(200)
                    val burstSort = (repo.getMessages(liveConv.id).maxOfOrNull { it.sortIndex } ?: replyMsg.sortIndex) + 1
                    val secondBubble = replyMsg.copy(
                        id = UUID.randomUUID().toString().uppercase(),
                        content = burstParts[1],
                        reasoningContent = "",
                        parentMessageID = if (treeActive) firstBubble.id else null,
                        sortIndex = burstSort,
                        createdAtEpochMs = System.currentTimeMillis(),
                        assistanceMetadata = MessageAssistanceMetadata(
                            groupMemberID = member.id,
                            groupMemberName = member.name,
                            groupMemberTitle = member.title,
                            groupMemberEmoji = member.avatarEmoji,
                            isPersonaSimulation = member.isSimulatedPersona,
                            personaExcerpts = firstMeta.personaExcerpts,
                            groupAskedHost = directive.asksHost
                        )
                    )
                    repo.saveMessage(secondBubble)
                    if (treeActive) {
                        currentLeafID = secondBubble.id
                    }
                    roundMessages.add(firstBubble)
                    roundMessages.add(secondBubble)
                } else {
                    replyMsg = replyMsg.copy(assistanceMetadata = updatedMeta)
                    repo.saveMessage(replyMsg)
                    if (treeActive) {
                        currentLeafID = replyMsg.id
                    }
                    roundMessages.add(replyMsg)
                }

                spokenMemberIDs.add(member.id.uppercase())
                turnsCompleted++

                nextStep = if (directive.asksHost) {
                    null
                } else if (explicitQueue.isNotEmpty()) {
                    explicitQueue.removeFirst()
                } else if (dynamicSmartRelay) {
                    GroupDiscussionCoordinator.selectNextRelaySpeaker(
                        after = member,
                        visibleReply = fullTextForRouting,
                        directive = directive,
                        activeMembers = liveActiveMembers,
                        spokenMemberIDs = spokenMemberIDs,
                        turnsCompleted = turnsCompleted,
                        maxRelayTurns = maxRelayTurns,
                        speakingMode = liveConv.assistanceSettings.groupSpeakingMode
                    )?.let { (nextM, nextI) -> RelayStep(nextM, nextI, allowPass = true) }
                } else {
                    null
                }

                if (nextStep != null) {
                    delay(160)
                }
            }
        } finally {
            activeGroupSpeaker.value = null
            streamingOverlays.value = emptyMap()
            GenerationServiceBridge.stop(container.appContext)
            val fresh = repo.getConversation(initialConversation.id) ?: initialConversation
            repo.saveConversation(
                fresh.copy(
                    activeLeafMessageID = if (treeActive) currentLeafID else fresh.activeLeafMessageID,
                    updatedAtEpochMs = System.currentTimeMillis()
                )
            )
        }
    }

    private fun executeSendSingleMessage(
        text: String,
        attachments: List<MessageAttachment>,
        conv: ConversationItem,
        target: ResolvedModelTarget,
        provider: ProviderItem,
        searchQuery: String? = null,
        quotedExcerptText: String? = null,
        isTemporaryOverride: Boolean = false
    ) {
        draftText.value = ""
        draftAttachments.value = emptyList()
        quotedExcerpt.value = null
        if (isTemporaryOverride) {
            temporaryTargetOverride.value = null
        }
        bannerError.value = null

        val activeMessages = uiState.value.messages
        val allMsgs = latestAllMessages.ifEmpty { activeMessages }
        val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
        val parentId = if (treeActive) ConversationTree.currentAnchorID(conv.activeLeafMessageID, allMsgs) else null
        val nextSort = (allMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
        val now = System.currentTimeMillis()
        val userMsg = makeUserMessage(
            conversationID = conv.id,
            text = text,
            attachments = attachments,
            sortIndex = nextSort,
            createdAtEpochMs = now,
            quotedExcerpt = quotedExcerptText,
            parentMessageID = parentId
        )
        val assistantMsg = ChatMessageItem(
            id = UUID.randomUUID().toString().uppercase(),
            conversationID = conv.id,
            role = MessageRole.ASSISTANT,
            content = "",
            reasoningContent = "",
            attachments = emptyList(),
            providerID = target.providerID,
            providerName = target.providerName,
            modelID = target.modelID,
            modelDisplayName = target.modelDisplayName,
            accentHex = target.accentHex,
            comparisonGroupID = null,
            isSelectedInGroup = true,
            isStreaming = true,
            errorMessage = null,
            finishReason = null,
            promptTokens = null,
            completionTokens = null,
            cachedTokens = null,
            latencyMs = null,
            thinkingDurationMs = null,
            synthesisSourceDigest = null,
            latestRequestID = null,
            assistanceMetadata = MessageAssistanceMetadata(requestedSearchQuery = searchQuery),
            parentMessageID = if (treeActive) userMsg.id else null,
            sortIndex = nextSort + 1,
            createdAtEpochMs = now + 1L
        )

        val updatedTitle = if (activeMessages.none { it.role == MessageRole.USER } &&
            ConversationItem.isDefaultTitle(conv.title)
        ) {
            ChatRepository.makeConversationTitle(text, attachments)
        } else {
            conv.title
        }
        val updatedConv = conv.copy(
            title = updatedTitle,
            primaryTarget = if (isTemporaryOverride) conv.primaryTarget else (conv.primaryTarget ?: target),
            activeLeafMessageID = if (treeActive) assistantMsg.id else conv.activeLeafMessageID,
            updatedAtEpochMs = now
        )
        val history = buildSinglePromptHistoryWithPersona(activeMessages + userMsg, conv)

        launchSlots(
            conversation = updatedConv,
            extraMessagesToInsert = listOf(userMsg),
            slots = listOf(
                StreamSlot(
                    message = assistantMsg,
                    target = target,
                    provider = provider,
                    history = history,
                    kind = RequestKind.ANSWER
                )
            ),
            preTurnSearchQuery = searchQuery,
            preTurnEvidenceQuery = text
        )
    }

    private fun buildSinglePromptHistoryWithPersona(
        messages: List<ChatMessageItem>,
        conv: ConversationItem
    ): List<LLMPromptMessage> {
        val base = ChatRepository.buildPromptHistory(messages, conv.contextMessageLimit)
        val privatePersona = conv.assistanceSettings.privatePersona ?: return base
        val materials = privatePersona.persona?.materials.orEmpty()
        if (materials.isEmpty() || base.isEmpty()) return base
        val last = base.last()
        val ref = PersonaMaterials.referenceBlock(materials, last.content) ?: return base
        return base.dropLast(1) + last.copy(content = "${last.content}\n\n$ref")
    }

    private fun executeSendArenaMessage(
        text: String,
        attachments: List<MessageAttachment>,
        conv: ConversationItem,
        resolvedPairs: List<Pair<ResolvedModelTarget, ProviderItem>>,
        searchQuery: String? = null,
        quotedExcerptText: String? = null
    ) {
        draftText.value = ""
        draftAttachments.value = emptyList()
        quotedExcerpt.value = null
        bannerError.value = null

        val activeMessages = uiState.value.messages
        val allMsgs = latestAllMessages.ifEmpty { activeMessages }
        val treeActive = ConversationTree.usesTree(conv.activeLeafMessageID, allMsgs)
        val parentId = if (treeActive) ConversationTree.currentAnchorID(conv.activeLeafMessageID, allMsgs) else null
        val nextSort = (allMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
        val now = System.currentTimeMillis()
        val userMsg = makeUserMessage(
            conversationID = conv.id,
            text = text,
            attachments = attachments,
            sortIndex = nextSort,
            createdAtEpochMs = now,
            quotedExcerpt = quotedExcerptText,
            parentMessageID = parentId
        )
        val groupID = UUID.randomUUID().toString().uppercase()
        val history = ChatRepository.buildPromptHistory(activeMessages + userMsg, conv.contextMessageLimit)

        val slots = resolvedPairs.mapIndexed { idx, (target, provider) ->
            val reply = ChatMessageItem(
                id = UUID.randomUUID().toString().uppercase(),
                conversationID = conv.id,
                role = MessageRole.ASSISTANT,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                providerID = target.providerID,
                providerName = target.providerName,
                modelID = target.modelID,
                modelDisplayName = target.modelDisplayName,
                accentHex = target.accentHex,
                comparisonGroupID = groupID,
                isSelectedInGroup = (idx == 0),
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = null,
                latestRequestID = null,
                assistanceMetadata = MessageAssistanceMetadata(requestedSearchQuery = searchQuery),
                parentMessageID = if (treeActive) userMsg.id else null,
                sortIndex = nextSort + 1 + idx,
                createdAtEpochMs = now + 1L + idx
            )
            StreamSlot(
                message = reply,
                target = target,
                provider = provider,
                history = history,
                kind = RequestKind.ANSWER
            )
        }

        val updatedTitle = if (activeMessages.none { it.role == MessageRole.USER } &&
            ConversationItem.isDefaultTitle(conv.title)
        ) {
            ChatRepository.makeConversationTitle(text, attachments)
        } else {
            conv.title
        }
        val updatedConv = conv.copy(
            title = updatedTitle,
            arenaTargets = resolvedPairs.map { it.first },
            activeLeafMessageID = if (treeActive) slots.firstOrNull()?.message?.id else conv.activeLeafMessageID,
            updatedAtEpochMs = now
        )

        launchSlots(
            conversation = updatedConv,
            extraMessagesToInsert = listOf(userMsg),
            slots = slots,
            preTurnSearchQuery = searchQuery,
            preTurnEvidenceQuery = text
        )
    }

    private data class BranchedTurn(
        val changedLinks: List<ChatMessageItem>,
        val branchedUser: ChatMessageItem,
        val branchHistoryMessages: List<ChatMessageItem>
    )

    private fun prepareBranchedUserTurn(
        allMsgs: List<ChatMessageItem>,
        original: ChatMessageItem,
        newContent: String,
        convID: String,
        now: Long
    ): BranchedTurn {
        val origParents = allMsgs.associate { it.id to it.parentMessageID }
        val (linkedMsgs, _) = ConversationTree.linkHistory(allMsgs)
        val changedLinks = linkedMsgs.filter { it.parentMessageID != origParents[it.id] }
        val linkedOrig = linkedMsgs.firstOrNull { it.id.equals(original.id, ignoreCase = true) } ?: original
        val parentID = linkedOrig.parentMessageID ?: ConversationTree.VIRTUAL_ROOT_ID
        val nextSort = (linkedMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
        val branchedUser = makeUserMessage(
            conversationID = convID,
            text = newContent,
            attachments = original.attachments,
            sortIndex = nextSort,
            createdAtEpochMs = now,
            quotedExcerpt = original.assistanceMetadata.quotedExcerpt,
            parentMessageID = parentID
        )
        val branchHistory = ConversationTree.activeMessages(branchedUser.id, linkedMsgs + branchedUser)
        return BranchedTurn(changedLinks, branchedUser, branchHistory)
    }

    private fun executeEditBranchSingle(
        original: ChatMessageItem,
        newContent: String,
        conv: ConversationItem,
        target: ResolvedModelTarget,
        provider: ProviderItem
    ) {
        bannerError.value = null
        activeJob?.cancel()
        activeJob = viewModelScope.launch {
            val allMsgs = repo.getMessages(conv.id)
            val now = System.currentTimeMillis()
            val turn = prepareBranchedUserTurn(allMsgs, original, newContent, conv.id, now)
            val assistantMsg = ChatMessageItem(
                id = UUID.randomUUID().toString().uppercase(),
                conversationID = conv.id,
                role = MessageRole.ASSISTANT,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                providerID = target.providerID,
                providerName = target.providerName,
                modelID = target.modelID,
                modelDisplayName = target.modelDisplayName,
                accentHex = target.accentHex,
                comparisonGroupID = null,
                isSelectedInGroup = true,
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = null,
                latestRequestID = null,
                parentMessageID = turn.branchedUser.id,
                sortIndex = turn.branchedUser.sortIndex + 1,
                createdAtEpochMs = now + 1L
            )
            val updatedConv = conv.copy(
                activeLeafMessageID = assistantMsg.id,
                updatedAtEpochMs = now
            )
            val history = buildSinglePromptHistoryWithPersona(turn.branchHistoryMessages, updatedConv)
            launchSlotsInCurrentScope(
                conversation = updatedConv,
                extraMessagesToInsert = turn.changedLinks + turn.branchedUser,
                slots = listOf(
                    StreamSlot(
                        message = assistantMsg,
                        target = target,
                        provider = provider,
                        history = history,
                        kind = RequestKind.ANSWER
                    )
                ),
                preTurnEvidenceQuery = newContent
            )
        }
    }

    private fun executeEditBranchArena(
        original: ChatMessageItem,
        newContent: String,
        conv: ConversationItem,
        resolvedPairs: List<Pair<ResolvedModelTarget, ProviderItem>>
    ) {
        bannerError.value = null
        activeJob?.cancel()
        activeJob = viewModelScope.launch {
            val allMsgs = repo.getMessages(conv.id)
            val now = System.currentTimeMillis()
            val turn = prepareBranchedUserTurn(allMsgs, original, newContent, conv.id, now)
            val groupID = UUID.randomUUID().toString().uppercase()
            val history = ChatRepository.buildPromptHistory(turn.branchHistoryMessages, conv.contextMessageLimit)
            val slots = resolvedPairs.mapIndexed { idx, (target, provider) ->
                val reply = ChatMessageItem(
                    id = UUID.randomUUID().toString().uppercase(),
                    conversationID = conv.id,
                    role = MessageRole.ASSISTANT,
                    content = "",
                    reasoningContent = "",
                    attachments = emptyList(),
                    providerID = target.providerID,
                    providerName = target.providerName,
                    modelID = target.modelID,
                    modelDisplayName = target.modelDisplayName,
                    accentHex = target.accentHex,
                    comparisonGroupID = groupID,
                    isSelectedInGroup = (idx == 0),
                    isStreaming = true,
                    errorMessage = null,
                    finishReason = null,
                    promptTokens = null,
                    completionTokens = null,
                    cachedTokens = null,
                    latencyMs = null,
                    thinkingDurationMs = null,
                    synthesisSourceDigest = null,
                    latestRequestID = null,
                    parentMessageID = turn.branchedUser.id,
                    sortIndex = turn.branchedUser.sortIndex + 1 + idx,
                    createdAtEpochMs = now + 1L + idx
                )
                StreamSlot(
                    message = reply,
                    target = target,
                    provider = provider,
                    history = history,
                    kind = RequestKind.ANSWER
                )
            }
            val updatedConv = conv.copy(
                activeLeafMessageID = slots.first().message.id,
                updatedAtEpochMs = now
            )
            launchSlotsInCurrentScope(
                conversation = updatedConv,
                extraMessagesToInsert = turn.changedLinks + turn.branchedUser,
                slots = slots,
                preTurnEvidenceQuery = newContent
            )
        }
    }

    private fun executeEditBranchGroup(
        original: ChatMessageItem,
        newContent: String,
        conv: ConversationItem
    ) {
        bannerError.value = null
        val previousJob = activeJob
        activeJob = viewModelScope.launch {
            if (previousJob != null && previousJob.isActive) {
                cancelPendingWebpageApproval()
                previousJob.cancelAndJoin()
                cleanupInterruptedGroupTail(conv.id)
            }
            val allMsgs = repo.getMessages(conv.id)
            val now = System.currentTimeMillis()
            val turn = prepareBranchedUserTurn(allMsgs, original, newContent, conv.id, now)
            val updatedConv = conv.copy(
                activeLeafMessageID = turn.branchedUser.id,
                updatedAtEpochMs = now
            )
            repo.saveConversationAndMessages(updatedConv, turn.changedLinks + turn.branchedUser)
            runGroupRelaySession(updatedConv, GroupRunMode.AfterUserMessage(turn.branchedUser))
        }
    }

    private fun executeBranchRegenerate(
        existingAssistant: ChatMessageItem,
        conv: ConversationItem,
        target: ResolvedModelTarget,
        provider: ProviderItem
    ) {
        bannerError.value = null
        activeJob?.cancel()
        activeJob = viewModelScope.launch {
            val allMsgs = repo.getMessages(conv.id)
            val origParents = allMsgs.associate { it.id to it.parentMessageID }
            val (linkedMsgs, _) = ConversationTree.linkHistory(allMsgs)
            val changedLinks = linkedMsgs.filter { it.parentMessageID != origParents[it.id] }
            val linkedOrig = linkedMsgs.firstOrNull { it.id.equals(existingAssistant.id, ignoreCase = true) }
                ?: existingAssistant
            val parentID = linkedOrig.parentMessageID ?: ConversationTree.VIRTUAL_ROOT_ID
            val branchPrior = if (parentID == ConversationTree.VIRTUAL_ROOT_ID) {
                emptyList()
            } else {
                ConversationTree.activeMessages(parentID, linkedMsgs)
            }
            val history = buildSinglePromptHistoryWithPersona(branchPrior, conv)
            if (history.isEmpty()) return@launch
            val nextSort = (linkedMsgs.maxOfOrNull { it.sortIndex } ?: 0) + 1
            val now = System.currentTimeMillis()
            val newReply = ChatMessageItem(
                id = UUID.randomUUID().toString().uppercase(),
                conversationID = conv.id,
                role = MessageRole.ASSISTANT,
                content = "",
                reasoningContent = "",
                attachments = emptyList(),
                providerID = target.providerID,
                providerName = target.providerName,
                modelID = target.modelID,
                modelDisplayName = target.modelDisplayName,
                accentHex = target.accentHex,
                comparisonGroupID = null,
                isSelectedInGroup = true,
                isStreaming = true,
                errorMessage = null,
                finishReason = null,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                latencyMs = null,
                thinkingDurationMs = null,
                synthesisSourceDigest = null,
                latestRequestID = null,
                assistanceMetadata = MessageAssistanceMetadata(
                    requestedSearchQuery = existingAssistant.assistanceMetadata.requestedSearchQuery
                ),
                parentMessageID = parentID,
                sortIndex = nextSort,
                createdAtEpochMs = now
            )
            val updatedConv = conv.copy(
                activeLeafMessageID = newReply.id,
                updatedAtEpochMs = now
            )
            val lastUserText = history.lastOrNull { it.role == MessageRole.USER }?.content
            launchSlotsInCurrentScope(
                conversation = updatedConv,
                extraMessagesToInsert = changedLinks,
                slots = listOf(
                    StreamSlot(
                        message = newReply,
                        target = target,
                        provider = provider,
                        history = history,
                        kind = RequestKind.REGENERATION
                    )
                ),
                preTurnSearchQuery = existingAssistant.assistanceMetadata.requestedSearchQuery,
                preTurnEvidenceQuery = lastUserText
            )
        }
    }

    private fun executeRegenerate(
        existingAssistant: ChatMessageItem,
        history: List<LLMPromptMessage>,
        conv: ConversationItem,
        target: ResolvedModelTarget,
        provider: ProviderItem
    ) {
        bannerError.value = null
        val resetReply = existingAssistant.copy(
            providerID = target.providerID,
            providerName = target.providerName,
            modelID = target.modelID,
            modelDisplayName = target.modelDisplayName,
            accentHex = target.accentHex,
            content = "",
            reasoningContent = "",
            attachments = emptyList(),
            isStreaming = true,
            errorMessage = null,
            finishReason = null,
            promptTokens = null,
            completionTokens = null,
            cachedTokens = null,
            latencyMs = null,
            thinkingDurationMs = null,
            synthesisSourceDigest = if (existingAssistant.isSynthesis) existingAssistant.synthesisSourceDigest else null,
            assistanceMetadata = existingAssistant.assistanceMetadata.copy(
                toolCalls = emptyList(),
                search = null,
                knowledgeEvidence = null,
                bookReply = null,
                proposedMemories = emptyList(),
                handledMemories = emptyList()
            )
        )
        val lastUserText = history.lastOrNull { it.role == MessageRole.USER }?.content
        launchSlots(
            conversation = conv.copy(updatedAtEpochMs = System.currentTimeMillis()),
            extraMessagesToInsert = emptyList(),
            slots = listOf(
                StreamSlot(
                    message = resetReply,
                    target = target,
                    provider = provider,
                    history = history,
                    kind = RequestKind.REGENERATION
                )
            ),
            preTurnSearchQuery = existingAssistant.assistanceMetadata.requestedSearchQuery,
            preTurnEvidenceQuery = lastUserText
        )
    }

    private fun launchSlots(
        conversation: ConversationItem,
        extraMessagesToInsert: List<ChatMessageItem>,
        slots: List<StreamSlot>,
        preTurnSearchQuery: String? = null,
        preTurnEvidenceQuery: String? = null
    ) {
        activeJob?.cancel()
        activeJob = viewModelScope.launch {
            launchSlotsInCurrentScope(
                conversation = conversation,
                extraMessagesToInsert = extraMessagesToInsert,
                slots = slots,
                preTurnSearchQuery = preTurnSearchQuery,
                preTurnEvidenceQuery = preTurnEvidenceQuery
            )
        }
    }

    private suspend fun launchSlotsInCurrentScope(
        conversation: ConversationItem,
        extraMessagesToInsert: List<ChatMessageItem>,
        slots: List<StreamSlot>,
        preTurnSearchQuery: String? = null,
        preTurnEvidenceQuery: String? = null
    ) {
        repo.saveConversationAndMessages(conversation, extraMessagesToInsert)
        val initialOverlays = slots.associate { it.message.id to it.message }
        streamingOverlays.update { it + initialOverlays }
        for (slot in slots) {
            repo.saveMessage(slot.message)
        }

        GenerationServiceBridge.start(
            container.appContext,
            buildNotificationState(
                conv = conversation,
                speakerOrModel = slots.firstOrNull()?.target?.modelDisplayName.orEmpty(),
                phaseText = L10n.text("正在流式生成…", "Streaming…")
            )
        )

        try {
            var effectiveSlots = slots
            if (!preTurnSearchQuery.isNullOrBlank() && effectiveSlots.isNotEmpty()) {
                try {
                    val evidence = performTavilySearchWithLedger(
                        query = preTurnSearchQuery,
                        conversationId = conversation.id,
                        messageId = effectiveSlots.first().message.id
                    )
                    effectiveSlots = effectiveSlots.map { s ->
                        val updatedMsg = s.message.copy(
                            assistanceMetadata = s.message.assistanceMetadata.copy(search = evidence)
                        )
                        streamingOverlays.update { it + (updatedMsg.id to updatedMsg) }
                        repo.saveMessage(updatedMsg)
                        val updatedHistory = appendPromptSuffix(s.history, evidence.prompt)
                        s.copy(message = updatedMsg, history = updatedHistory)
                    }
                } catch (t: Throwable) {
                    val errText = if (t is CancellationException) {
                        L10n.text("已停止生成", "Generation stopped")
                    } else {
                        t.message ?: L10n.text("联网搜索失败", "Web search failed")
                    }
                    for (s in effectiveSlots) {
                        repo.saveMessage(s.message.copy(isStreaming = false, errorMessage = errText))
                    }
                    return
                }
            }

            if (!preTurnEvidenceQuery.isNullOrBlank() &&
                conversation.assistanceSettings.knowledgeVolumeIDs.isNotEmpty() &&
                effectiveSlots.isNotEmpty()
            ) {
                val knowledge = runCatching {
                    retrieveKnowledgeForTurn(conversation.assistanceSettings.knowledgeVolumeIDs, preTurnEvidenceQuery)
                }.getOrNull()
                if (knowledge != null && knowledge.passages.isNotEmpty()) {
                    val kPrompt = knowledge.promptText()
                    effectiveSlots = effectiveSlots.map { s ->
                        val updatedMsg = s.message.copy(
                            assistanceMetadata = s.message.assistanceMetadata.copy(knowledgeEvidence = knowledge)
                        )
                        streamingOverlays.update { it + (updatedMsg.id to updatedMsg) }
                        repo.saveMessage(updatedMsg)
                        val updatedHistory = appendPromptSuffix(s.history, kPrompt)
                        s.copy(message = updatedMsg, history = updatedHistory)
                    }
                }
            }

            val friend = conversation.activeBookFriend
            if (friend != null && !conversation.isArenaMode && !conversation.isGroupMode && effectiveSlots.isNotEmpty()) {
                try {
                    val query = preTurnEvidenceQuery.orEmpty()
                    val bookReply = retrieveBookFriendForTurn(friend, query)
                    if (bookReply != null) {
                        val preferEng = GroupDiscussionCoordinator.prefersEnglishPrompts(repo.getMessages(conversation.id))
                        val refPrompt = bookReply.referenceText(preferEng)
                        val friendSystem = buildBookFriendSystemPrompt(friend, conversation.systemPrompt, preferEng)
                        effectiveSlots = effectiveSlots.map { s ->
                            val updatedMsg = s.message.copy(
                                assistanceMetadata = s.message.assistanceMetadata.copy(bookReply = bookReply)
                            )
                            streamingOverlays.update { it + (updatedMsg.id to updatedMsg) }
                            repo.saveMessage(updatedMsg)
                            val updatedHistory = appendPromptSuffix(s.history, refPrompt)
                            s.copy(
                                message = updatedMsg,
                                history = updatedHistory,
                                systemPromptOverride = s.systemPromptOverride ?: friendSystem
                            )
                        }
                    }
                } catch (t: Throwable) {
                    val errText = if (t is CancellationException) {
                        L10n.text("已停止生成", "Generation stopped")
                    } else {
                        t.message ?: L10n.text("查找书中人物失败", "Failed to load book character references")
                    }
                    for (s in effectiveSlots) {
                        repo.saveMessage(s.message.copy(isStreaming = false, errorMessage = errText))
                    }
                    return
                }
            }

            coroutineScope {
                effectiveSlots.map { slot ->
                    async { runSingleSlot(slot, conversation) }
                }.awaitAll()
            }
        } finally {
            val ids = slots.mapTo(HashSet()) { it.message.id }
            streamingOverlays.update { current -> current - ids }
            GenerationServiceBridge.stop(container.appContext)
            repo.saveConversation(conversation.copy(updatedAtEpochMs = System.currentTimeMillis()))
        }
    }

    private fun buildNotificationState(
        conv: ConversationItem,
        speakerOrModel: String,
        phaseText: String
    ): GenerationNotificationState {
        val modeBadge = when {
            conv.isGroupMode -> L10n.text("圆桌群聊", "Group")
            conv.isArenaMode -> L10n.text("模型竞技场", "Arena")
            else -> L10n.text("夜奔对话", "Fugue")
        }
        return GenerationNotificationState(
            conversationID = conv.id,
            chatTitle = conv.title,
            modeBadge = modeBadge,
            speakerOrModel = speakerOrModel,
            phaseText = phaseText,
            isBlind = conv.isArenaMode && conv.assistanceSettings.blindArenaMode
        )
    }

    private suspend fun runSingleSlot(
        slot: StreamSlot,
        conversation: ConversationItem
    ): SlotOutcome {
        var liveReply = slot.message
        val target = slot.target
        val provider = slot.provider
        val modelSpec = provider.models.firstOrNull { it.id == target.modelID }
        val operationID = UUID.randomUUID().toString().uppercase()

        val systemSource = slot.systemPromptOverride ?: conversation.systemPrompt
        var renderedSystem = PromptTemplateEngine.render(systemSource, target)
        if (conversation.assistanceSettings.usePersonalMemory && slot.kind != RequestKind.SYNTHESIS) {
            val memories = repo.getEnabledPersonalMemories()
            val (memPrompt, memCount) = PersonalMemoryPrompt.buildPrompt(memories.map { it.content })
            if (memCount > 0) {
                renderedSystem = if (renderedSystem.isBlank()) memPrompt else "$renderedSystem\n\n$memPrompt"
                liveReply = liveReply.copy(
                    assistanceMetadata = liveReply.assistanceMetadata.copy(memoryCount = memCount)
                )
                streamingOverlays.update { it + (liveReply.id to liveReply) }
            }
        }
        val coachMode = conversation.assistanceSettings.studyCoachMode
        if (!conversation.isGroupMode && slot.kind != RequestKind.SYNTHESIS && coachMode != StudyCoachMode.OFF) {
            renderedSystem = if (renderedSystem.isBlank()) {
                coachMode.systemInstruction
            } else {
                "$renderedSystem\n\n${coachMode.systemInstruction}"
            }
        }
        val allKeys = container.secretStore.loadAllAPIKeys(provider.id)
        val userProvidedURLs = AgentToolRunner.extractUserProvidedURLs(
            slot.history.filter { it.role == MessageRole.USER }.map { it.content } + conversation.systemPrompt
        )

        var workingHistory = slot.history
        var toolRound = 0
        var reasoningStartMs: Int? = null
        var thinkingEndMs: Int? = null
        var lastDbFlushMs = 0L
        var abnormalFinish = false
        var finalizedDirective: GroupTurnDirective? = null
        val groundedSources = mutableListOf<SearchSource>()

        val startNanos = System.nanoTime()

        while (true) {
            val roundStartEpochMs = System.currentTimeMillis()
            val roundStartNanos = System.nanoTime()
            val roundKind = if (toolRound == 0) slot.kind else RequestKind.AGENT_TOOL
            var record = RequestRecordItem(
                id = UUID.randomUUID().toString().uppercase(),
                operationID = operationID,
                attempt = toolRound + 1,
                conversationID = conversation.id,
                messageID = liveReply.id,
                providerID = provider.id,
                providerName = provider.name,
                modelID = target.modelID,
                modelDisplayName = target.modelDisplayName,
                protocolType = target.protocolType,
                kind = roundKind,
                status = RequestStatus.RUNNING,
                startedAtEpochMs = roundStartEpochMs,
                endedAtEpochMs = null,
                firstReasoningMs = null,
                firstContentMs = null,
                lastOutputMs = null,
                durationMs = null,
                outputChunkCount = 0,
                isStreamed = true,
                promptTokens = null,
                completionTokens = null,
                cachedTokens = null,
                cacheWriteTokens = null,
                httpStatus = null,
                inputPricePerMillion = modelSpec?.inputPricePerMillion,
                outputPricePerMillion = modelSpec?.outputPricePerMillion,
                cacheReadPricePerMillion = modelSpec?.cacheReadPricePerMillion,
                cacheWritePricePerMillion = modelSpec?.cacheWritePricePerMillion,
                currency = modelSpec?.priceCurrency
            )
            repo.saveRequestRecord(record)

            val allowToolsNow = !conversation.isGroupMode &&
                !conversation.isArenaMode &&
                slot.kind != RequestKind.SYNTHESIS &&
                conversation.assistanceSettings.enableAgentTools &&
                toolRound < AgentToolRunner.MAX_TOOL_ROUNDS
            val tavilyKey = container.secretStore.loadSecret(SecretStore.TAVILY_KEY_ACCOUNT)
            val toolDefinitions = if (allowToolsNow) {
                AgentToolRunner.definitions(
                    hasTavilyKey = tavilyKey.isNotEmpty(),
                    hasKnowledgeBase = conversation.assistanceSettings.knowledgeVolumeIDs.isNotEmpty()
                )
            } else {
                emptyList()
            }
            val enableNativeSearch = slot.kind != RequestKind.SYNTHESIS &&
                !conversation.isGroupMode &&
                conversation.assistanceSettings.enableNativeGrounding

            val llmRequest = LLMChatRequest(
                providerName = provider.name,
                protocolType = provider.protocolType,
                baseURL = provider.baseURL,
                apiKey = allKeys.firstOrNull() ?: "",
                apiKeys = allKeys.drop(1),
                customHeaders = provider.resolvedCustomHeaders(container.secretStore),
                modelID = target.modelID,
                supportsReasoning = target.supportsReasoning,
                systemPrompt = renderedSystem,
                messages = workingHistory,
                temperature = slot.temperatureOverride ?: if (conversation.useCustomTemperature) conversation.temperature else null,
                topP = conversation.topP,
                maxOutputTokens = conversation.maxOutputTokens.takeIf { it > 0 },
                enableThinking = conversation.enableThinking,
                thinkingBudgetTokens = conversation.thinkingBudgetTokens,
                enablePromptCaching = conversation.assistanceSettings.enablePromptCaching,
                enableNativeSearch = enableNativeSearch,
                idleTimeoutSeconds = provider.idleTimeoutSeconds.takeIf { it > 0 }?.toDouble(),
                tools = toolDefinitions
            )

            val roundText = StringBuilder()
            val roundReasoning = StringBuilder()
            val roundThinkingBlocks = mutableListOf<LLMThinkingBlock>()
            val roundToolCalls = mutableListOf<LLMToolCall>()

            try {
                container.llmClient.streamChat(llmRequest).collect { event ->
                    val elapsedMs = ((System.nanoTime() - roundStartNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                    when (event) {
                        is LLMStreamEvent.NonStreamingResponse -> {
                            record = record.copy(isStreamed = false)
                        }
                        is LLMStreamEvent.ReasoningDelta -> if (event.text.isNotEmpty()) {
                            roundReasoning.append(event.text)
                            if (reasoningStartMs == null) {
                                reasoningStartMs = ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                            }
                            if (record.firstReasoningMs == null) {
                                record = record.copy(firstReasoningMs = elapsedMs)
                            }
                            record = record.copy(
                                lastOutputMs = elapsedMs,
                                outputChunkCount = record.outputChunkCount + 1
                            )
                            liveReply = liveReply.copy(reasoningContent = liveReply.reasoningContent + event.text)
                            streamingOverlays.update { it + (liveReply.id to liveReply) }
                        }
                        is LLMStreamEvent.ThinkingBlock -> {
                            roundThinkingBlocks.add(event.block)
                        }
                        is LLMStreamEvent.ContentDelta -> {
                            val visibleDelta = slot.groupSanitizer?.ingest(event.text) ?: event.text
                            if (visibleDelta.isNotEmpty()) {
                                roundText.append(visibleDelta)
                                if (reasoningStartMs != null && thinkingEndMs == null) {
                                    thinkingEndMs = ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                                }
                                if (record.firstContentMs == null) {
                                    record = record.copy(firstContentMs = elapsedMs)
                                }
                                record = record.copy(
                                    lastOutputMs = elapsedMs,
                                    outputChunkCount = record.outputChunkCount + 1
                                )
                                liveReply = liveReply.copy(
                                    content = liveReply.content + visibleDelta,
                                    thinkingDurationMs = thinkingEndMs?.let { end ->
                                        reasoningStartMs?.let { start -> maxOf(0, end - start) }
                                    } ?: liveReply.thinkingDurationMs
                                )
                                streamingOverlays.update { it + (liveReply.id to liveReply) }
                            }
                        }
                        is LLMStreamEvent.AttachmentDelta -> {
                            record = record.copy(
                                firstContentMs = record.firstContentMs ?: elapsedMs,
                                lastOutputMs = elapsedMs,
                                outputChunkCount = record.outputChunkCount + 1
                            )
                            liveReply = liveReply.copy(attachments = liveReply.attachments + event.attachment)
                            streamingOverlays.update { it + (liveReply.id to liveReply) }
                        }
                        is LLMStreamEvent.ToolCall -> {
                            roundToolCalls.add(event.call)
                        }
                        is LLMStreamEvent.GroundingSource -> {
                            if (event.url.isNotBlank() && groundedSources.none { it.url == event.url }) {
                                groundedSources.add(
                                    SearchSource(
                                        id = groundedSources.size + 1,
                                        title = event.title.ifBlank { event.url },
                                        url = event.url,
                                        snippet = L10n.text("来自模型原生联网检索", "From model native web grounding")
                                    )
                                )
                                val mergedSearch = mergeSearchEvidence(
                                    existing = liveReply.assistanceMetadata.search,
                                    query = L10n.text("原生联网检索", "Native Grounding"),
                                    addedSources = groundedSources
                                )
                                liveReply = liveReply.copy(
                                    assistanceMetadata = liveReply.assistanceMetadata.copy(search = mergedSearch)
                                )
                                streamingOverlays.update { it + (liveReply.id to liveReply) }
                            }
                        }
                        is LLMStreamEvent.Usage -> {
                            record = record.copy(
                                promptTokens = event.promptTokens ?: record.promptTokens,
                                completionTokens = event.completionTokens ?: record.completionTokens
                            )
                            liveReply = liveReply.copy(
                                promptTokens = event.promptTokens ?: liveReply.promptTokens,
                                completionTokens = event.completionTokens ?: liveReply.completionTokens
                            )
                        }
                        is LLMStreamEvent.CacheUsage -> {
                            record = record.copy(
                                cachedTokens = event.cachedTokens ?: record.cachedTokens,
                                cacheWriteTokens = event.cacheWriteTokens ?: record.cacheWriteTokens
                            )
                            liveReply = liveReply.copy(
                                cachedTokens = event.cachedTokens ?: liveReply.cachedTokens
                            )
                        }
                        is LLMStreamEvent.Finished -> {
                            abnormalFinish = true
                            liveReply = liveReply.copy(finishReason = event.reason.rawValue)
                            streamingOverlays.update { it + (liveReply.id to liveReply) }
                        }
                        is LLMStreamEvent.Retrying,
                        is LLMStreamEvent.Done -> Unit
                    }

                    val nowClock = System.currentTimeMillis()
                    if (nowClock - lastDbFlushMs >= 150L) {
                        lastDbFlushMs = nowClock
                        repo.saveMessage(liveReply)
                    }
                }

                val roundDurationMs = ((System.nanoTime() - roundStartNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                if (roundToolCalls.isNotEmpty() && allowToolsNow) {
                    record = record.copy(
                        status = RequestStatus.SUCCEEDED,
                        durationMs = roundDurationMs,
                        endedAtEpochMs = System.currentTimeMillis()
                    )
                    repo.saveRequestRecord(record)

                    workingHistory = workingHistory + LLMPromptMessage(
                        role = MessageRole.ASSISTANT,
                        content = roundText.toString(),
                        reasoningContent = roundReasoning.toString(),
                        thinkingBlocks = roundThinkingBlocks,
                        toolCalls = roundToolCalls
                    )

                    for (call in roundToolCalls) {
                        coroutineScope { ensureActive() }
                        val exec = AgentToolRunner.execute(
                            call = call,
                            searchHandler = { q ->
                                performTavilySearchWithLedger(
                                    query = q,
                                    conversationId = conversation.id,
                                    messageId = liveReply.id
                                )
                            },
                            webpageApproval = { uri ->
                                requestWebpageApproval(uri, userProvidedURLs)
                            },
                            knowledgeHandler = if (conversation.assistanceSettings.knowledgeVolumeIDs.isNotEmpty()) {
                                { q ->
                                    retrieveKnowledgeForTurn(conversation.assistanceSettings.knowledgeVolumeIDs, q)
                                        ?: KnowledgeEvidence(query = q, passages = emptyList())
                                }
                            } else null
                        )
                        val updatedCalls = liveReply.assistanceMetadata.toolCalls + exec.record
                        val updatedSearch = exec.searchEvidence?.let { newEv ->
                            val existing = liveReply.assistanceMetadata.search
                            if (existing == null) newEv else mergeSearchEvidence(existing, newEv.query, newEv.sources)
                        } ?: liveReply.assistanceMetadata.search
                        val updatedKnowledge = exec.knowledgeEvidence?.let { newKEv ->
                            val existing = liveReply.assistanceMetadata.knowledgeEvidence
                            existing?.merged(newKEv) ?: newKEv
                        } ?: liveReply.assistanceMetadata.knowledgeEvidence
                        val updatedMemories = exec.proposedMemory?.let { fact ->
                            val cur = liveReply.assistanceMetadata.proposedMemories
                            if (cur.contains(fact)) cur else cur + fact
                        } ?: liveReply.assistanceMetadata.proposedMemories

                        liveReply = liveReply.copy(
                            assistanceMetadata = liveReply.assistanceMetadata.copy(
                                toolCalls = updatedCalls,
                                search = updatedSearch,
                                knowledgeEvidence = updatedKnowledge,
                                proposedMemories = updatedMemories
                            )
                        )
                        streamingOverlays.update { it + (liveReply.id to liveReply) }
                        repo.saveMessage(liveReply)

                        workingHistory = workingHistory + LLMPromptMessage(
                            role = MessageRole.TOOL,
                            content = exec.toolOutputJSON,
                            toolCallID = call.id,
                            toolName = call.name
                        )
                    }

                    if (liveReply.content.isNotEmpty() && !liveReply.content.endsWith("\n")) {
                        liveReply = liveReply.copy(content = liveReply.content + "\n\n")
                        streamingOverlays.update { it + (liveReply.id to liveReply) }
                    }
                    toolRound++
                    continue
                }

                if (slot.groupSanitizer != null) {
                    val finalized = slot.groupSanitizer.finalize()
                    liveReply = liveReply.copy(content = finalized.visibleText)
                    finalizedDirective = finalized.directive
                }

                val firstMs = RequestMetrics.firstOutputMs(record.firstReasoningMs, record.firstContentMs)
                val finalThinkingMs = liveReply.thinkingDurationMs
                    ?: reasoningStartMs?.let { rs ->
                        val totalSoFar = ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                        maxOf(0, (thinkingEndMs ?: totalSoFar) - rs)
                    }
                val finalStatus = if (abnormalFinish) RequestStatus.INCOMPLETE else RequestStatus.SUCCEEDED

                liveReply = liveReply.copy(
                    isStreaming = false,
                    latencyMs = firstMs ?: roundDurationMs,
                    thinkingDurationMs = finalThinkingMs,
                    latestRequestID = record.id
                )
                record = record.copy(
                    status = finalStatus,
                    durationMs = roundDurationMs,
                    endedAtEpochMs = System.currentTimeMillis()
                )
                repo.saveMessage(liveReply)
                repo.saveRequestRecord(record)
                streamingOverlays.update { it - liveReply.id }
                break
            } catch (_: CancellationException) {
                val totalMs = ((System.nanoTime() - roundStartNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                liveReply = liveReply.copy(
                    isStreaming = false,
                    errorMessage = if (liveReply.content.isEmpty() && liveReply.reasoningContent.isEmpty()) {
                        L10n.text("已停止生成", "Generation stopped")
                    } else null,
                    latestRequestID = record.id
                )
                record = record.copy(
                    status = RequestStatus.CANCELLED,
                    durationMs = totalMs,
                    endedAtEpochMs = System.currentTimeMillis()
                )
                repo.saveMessage(liveReply)
                repo.saveRequestRecord(record)
                streamingOverlays.update { it - liveReply.id }
                break
            } catch (t: Throwable) {
                val totalMs = ((System.nanoTime() - roundStartNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                val httpCode = (t as? LLMError.HttpError)?.statusCode
                liveReply = liveReply.copy(
                    isStreaming = false,
                    errorMessage = t.message ?: L10n.text("请求失败", "Request failed"),
                    latestRequestID = record.id
                )
                record = record.copy(
                    status = RequestStatus.FAILED,
                    httpStatus = httpCode,
                    durationMs = totalMs,
                    endedAtEpochMs = System.currentTimeMillis()
                )
                repo.saveMessage(liveReply)
                repo.saveRequestRecord(record)
                streamingOverlays.update { it - liveReply.id }
                break
            }
        }
        return SlotOutcome(liveReply, finalizedDirective)
    }

    private fun appendPromptSuffix(
        history: List<LLMPromptMessage>,
        suffix: String
    ): List<LLMPromptMessage> {
        if (suffix.isBlank() || history.isEmpty()) return history
        val last = history.last()
        val augmented = if (last.content.isEmpty()) suffix else "${last.content}\n\n$suffix"
        return history.dropLast(1) + last.copy(content = augmented)
    }

    private suspend fun retrieveKnowledgeForTurn(
        volumeIDs: List<String>,
        query: String,
        maxPassages: Int = 5
    ): KnowledgeEvidence? = withContext(Dispatchers.IO) {
        val cleanIDs = volumeIDs.map { it.trim().uppercase() }.filter { it.isNotEmpty() }.distinct().take(12)
        if (cleanIDs.isEmpty() || query.isBlank()) return@withContext null
        val inputs = cleanIDs.mapNotNull { id ->
            val book = repo.getBook(id) ?: return@mapNotNull null
            val chapters = repo.loadBookChapters(id)
            if (chapters.isEmpty()) return@mapNotNull null
            KnowledgeDocumentInput(
                id = book.id,
                title = book.title,
                chaptersProvider = { chapters }
            )
        }
        if (inputs.isEmpty()) return@withContext null
        ProjectKnowledgeSearch.retrieve(inputs, query = query, maxPassages = maxPassages)
            .takeIf { it.passages.isNotEmpty() }
    }

    private suspend fun retrieveBookFriendForTurn(
        friend: BookFriend,
        query: String
    ): BookReplyEvidence? = withContext(Dispatchers.IO) {
        val chapters = repo.loadBookChapters(friend.bookID)
        if (chapters.isEmpty()) return@withContext null
        BookReferenceSearch.reference(friend, chapters, query)
    }

    private fun buildBookFriendSystemPrompt(
        friend: BookFriend,
        customSystemPrompt: String,
        preferEnglish: Boolean
    ): String {
        val base = friend.systemInstruction(preferEnglish)
        val extra = customSystemPrompt.trim()
        return if (extra.isEmpty()) base else "$base\n\n$extra"
    }

    private fun mergeSearchEvidence(
        existing: SearchEvidence?,
        query: String,
        addedSources: List<SearchSource>
    ): SearchEvidence {
        val merged = existing?.sources.orEmpty().toMutableList()
        val seenUrls = merged.mapTo(HashSet()) { it.url }
        for (src in addedSources) {
            if (seenUrls.add(src.url)) {
                merged.add(src.copy(id = merged.size + 1))
            }
        }
        return SearchEvidence(
            query = existing?.query?.takeIf { it.isNotBlank() } ?: query,
            searchedAt = existing?.searchedAt ?: System.currentTimeMillis(),
            sources = merged,
            credits = existing?.credits
        )
    }

    private fun resolveGroupPairs(
        conv: ConversationItem,
        providers: List<ProviderItem>,
        ready: List<ResolvedModelTarget>
    ): List<Triple<GroupMember, ResolvedModelTarget, ProviderItem>> =
        conv.activeGroupMembers.mapNotNull { member ->
            val resolved = ready.firstOrNull { it.id == member.target.id } ?: return@mapNotNull null
            val provider = providers.firstOrNull { it.id.equals(resolved.providerID, ignoreCase = true) }
                ?: return@mapNotNull null
            Triple(member.copy(target = resolved), resolved, provider)
        }

    private fun makeUserMessage(
        conversationID: String,
        text: String,
        attachments: List<MessageAttachment>,
        sortIndex: Int,
        createdAtEpochMs: Long,
        quotedExcerpt: String? = null,
        parentMessageID: String? = null
    ): ChatMessageItem = ChatMessageItem(
        id = UUID.randomUUID().toString().uppercase(),
        conversationID = conversationID,
        role = MessageRole.USER,
        content = text,
        reasoningContent = "",
        attachments = attachments,
        providerID = null,
        providerName = "",
        modelID = "",
        modelDisplayName = "",
        accentHex = "#3F6EF6",
        comparisonGroupID = null,
        isSelectedInGroup = true,
        isStreaming = false,
        errorMessage = null,
        finishReason = null,
        promptTokens = null,
        completionTokens = null,
        cachedTokens = null,
        latencyMs = null,
        thinkingDurationMs = null,
        synthesisSourceDigest = null,
        latestRequestID = null,
        assistanceMetadata = if (quotedExcerpt.isNullOrBlank()) {
            MessageAssistanceMetadata()
        } else {
            MessageAssistanceMetadata(quotedExcerpt = quotedExcerpt)
        },
        parentMessageID = parentMessageID,
        sortIndex = sortIndex,
        createdAtEpochMs = createdAtEpochMs
    )

    private fun resolveReplyTarget(
        message: ChatMessageItem,
        conv: ConversationItem,
        providers: List<ProviderItem>,
        ready: List<ResolvedModelTarget>
    ): ResolvedModelTarget? {
        val ownTarget = message.providerID?.let { pid ->
            ready.firstOrNull { it.providerID.equals(pid, ignoreCase = true) && it.modelID == message.modelID }
        }
        return ownTarget ?: resolveActiveTarget(conv, providers, ready)
    }

    private fun resolveActiveTarget(
        conv: ConversationItem,
        providers: List<ProviderItem>,
        ready: List<ResolvedModelTarget>
    ): ResolvedModelTarget? {
        val current = conv.primaryTarget
        if (current != null) {
            ready.firstOrNull { it.id == current.id }?.let { return it }
            val provider = providers.firstOrNull { it.id.equals(current.providerID, ignoreCase = true) }
            if (provider != null && provider.isReadyForChat &&
                provider.enabledModels.any { it.id == current.modelID }
            ) {
                return current
            }
        }
        return ready.firstOrNull()
    }

    companion object {
        fun factory(conversationId: String, container: AppContainer): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    ChatViewModel(conversationId, container) as T
            }
    }
}
