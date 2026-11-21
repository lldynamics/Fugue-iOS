package com.iosbox.app.ui.chat

import android.content.ContentResolver
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.ArenaBallot
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.RequestKind
import com.iosbox.app.core.model.RequestMetrics
import com.iosbox.app.core.model.RequestStatus
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.network.ArenaSynthesis
import com.iosbox.app.core.network.LLMChatRequest
import com.iosbox.app.core.network.LLMError
import com.iosbox.app.core.network.LLMPromptMessage
import com.iosbox.app.core.network.LLMStreamEvent
import com.iosbox.app.core.storage.AttachmentProcessor
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ConversationItem
import com.iosbox.app.core.storage.PresetItem
import com.iosbox.app.core.storage.PromptTemplateEngine
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.core.storage.RequestRecordItem
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
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

data class ChatDetailUiState(
    val conversation: ConversationItem? = null,
    val messages: List<ChatMessageItem> = emptyList(),
    val providers: List<ProviderItem> = emptyList(),
    val presets: List<PresetItem> = emptyList(),
    val draftText: String = "",
    val draftAttachments: List<MessageAttachment> = emptyList(),
    val isGenerating: Boolean = false,
    val bannerError: String? = null,
    val pendingConsent: PendingConsentAction? = null
)

class ChatViewModel(
    private val conversationId: String,
    private val container: AppContainer
) : ViewModel() {
    private val repo = container.chatRepository

    private val draftText = MutableStateFlow("")
    private val draftAttachments = MutableStateFlow<List<MessageAttachment>>(emptyList())
    private val streamingOverlays = MutableStateFlow<Map<String, ChatMessageItem>>(emptyMap())
    private val bannerError = MutableStateFlow<String?>(null)
    private val pendingConsent = MutableStateFlow<PendingConsentAction?>(null)

    private var activeJob: Job? = null

    private val baseDataFlow = combine(
        repo.observeConversation(conversationId),
        repo.observeMessages(conversationId),
        repo.observeProviders(),
        repo.observePresets()
    ) { conv, msgs, providers, presets ->
        BaseData(conv, msgs, providers, presets)
    }

    val uiState: StateFlow<ChatDetailUiState> = combine(
        baseDataFlow,
        draftText,
        draftAttachments,
        streamingOverlays,
        combine(bannerError, pendingConsent) { err, consent -> err to consent }
    ) { base, draft, atts, overlays, (err, consent) ->
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
        ChatDetailUiState(
            conversation = base.conversation,
            messages = mergedMessages,
            providers = base.providers,
            presets = base.presets,
            draftText = draft,
            draftAttachments = atts,
            isGenerating = overlays.isNotEmpty() || mergedMessages.any { it.isStreaming },
            bannerError = err,
            pendingConsent = consent
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ChatDetailUiState())

    private data class BaseData(
        val conversation: ConversationItem?,
        val messages: List<ChatMessageItem>,
        val providers: List<ProviderItem>,
        val presets: List<PresetItem>
    )

    private data class StreamSlot(
        val message: ChatMessageItem,
        val target: ResolvedModelTarget,
        val provider: ProviderItem,
        val history: List<LLMPromptMessage>,
        val kind: RequestKind,
        val systemPromptOverride: String? = null
    )

    fun updateDraftText(text: String) {
        draftText.value = text
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
        if (state.isGenerating) return
        val conv = state.conversation ?: return
        val text = state.draftText.trim()
        val attachments = state.draftAttachments
        if (text.isEmpty() && attachments.isEmpty()) return

        val ready = ChatRepository.readyTargets(state.providers)

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
                executeSendArenaMessage(text, attachments, conv, resolvedPairs)
            }
            return
        }

        val target = resolveActiveTarget(conv, state.providers, ready)
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
            executeSendSingleMessage(text, attachments, conv, target, provider)
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

        val resolved = resolveReplyTarget(assistantMessage, conv, state.providers, ready)
        val provider = resolved?.let { r -> state.providers.firstOrNull { it.id.equals(r.providerID, ignoreCase = true) } }
        if (resolved == null || provider == null) {
            bannerError.value = L10n.text("没有可用的模型用于重答。", "No ready model available to regenerate.")
            return
        }

        val priorMessages = state.messages.subList(0, sliceIndex)
        val history = ChatRepository.buildPromptHistory(priorMessages, conv.contextMessageLimit)
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
                parentMessageID = assistantMessage.parentMessageID,
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
                parentMessageID = allOriginals.firstOrNull()?.parentMessageID,
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
        val groupMembers = messages.filter { it.comparisonGroupID.equals(groupID, ignoreCase = true) }
        val groupWinner = groupMembers.firstOrNull { it.isSelectedInGroup } ?: groupMembers.firstOrNull()
        val nextSort = (messages.maxOfOrNull { it.sortIndex } ?: 0) + 1
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
            parentMessageID = groupWinner?.id,
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
                parentMessageID = critiquePromptMsg.id,
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
                conversation = conv.copy(updatedAtEpochMs = now),
                extraMessagesToInsert = listOf(critiquePromptMsg),
                slots = slots
            )
        }
    }

    fun stopGeneration() {
        activeJob?.cancel()
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

    private fun executeSendSingleMessage(
        text: String,
        attachments: List<MessageAttachment>,
        conv: ConversationItem,
        target: ResolvedModelTarget,
        provider: ProviderItem
    ) {
        draftText.value = ""
        draftAttachments.value = emptyList()
        bannerError.value = null

        val currentMessages = uiState.value.messages
        val nextSort = (currentMessages.maxOfOrNull { it.sortIndex } ?: 0) + 1
        val now = System.currentTimeMillis()
        val userMsg = makeUserMessage(conv.id, text, attachments, nextSort, now)
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
            parentMessageID = userMsg.id,
            sortIndex = nextSort + 1,
            createdAtEpochMs = now + 1L
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
            primaryTarget = conv.primaryTarget ?: target,
            updatedAtEpochMs = now
        )
        val history = ChatRepository.buildPromptHistory(currentMessages + userMsg, conv.contextMessageLimit)

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
            )
        )
    }

    private fun executeSendArenaMessage(
        text: String,
        attachments: List<MessageAttachment>,
        conv: ConversationItem,
        resolvedPairs: List<Pair<ResolvedModelTarget, ProviderItem>>
    ) {
        draftText.value = ""
        draftAttachments.value = emptyList()
        bannerError.value = null

        val currentMessages = uiState.value.messages
        val nextSort = (currentMessages.maxOfOrNull { it.sortIndex } ?: 0) + 1
        val now = System.currentTimeMillis()
        val userMsg = makeUserMessage(conv.id, text, attachments, nextSort, now)
        val groupID = UUID.randomUUID().toString().uppercase()
        val history = ChatRepository.buildPromptHistory(currentMessages + userMsg, conv.contextMessageLimit)

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
                parentMessageID = userMsg.id,
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

        val updatedTitle = if (currentMessages.none { it.role == MessageRole.USER } &&
            ConversationItem.isDefaultTitle(conv.title)
        ) {
            ChatRepository.makeConversationTitle(text, attachments)
        } else {
            conv.title
        }
        val updatedConv = conv.copy(
            title = updatedTitle,
            arenaTargets = resolvedPairs.map { it.first },
            updatedAtEpochMs = now
        )

        launchSlots(
            conversation = updatedConv,
            extraMessagesToInsert = listOf(userMsg),
            slots = slots
        )
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
            synthesisSourceDigest = if (existingAssistant.isSynthesis) existingAssistant.synthesisSourceDigest else null
        )
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
            )
        )
    }

    private fun launchSlots(
        conversation: ConversationItem,
        extraMessagesToInsert: List<ChatMessageItem>,
        slots: List<StreamSlot>
    ) {
        activeJob?.cancel()
        activeJob = viewModelScope.launch {
            repo.saveConversation(conversation)
            for (msg in extraMessagesToInsert) {
                repo.saveMessage(msg)
            }
            val initialOverlays = slots.associate { it.message.id to it.message }
            streamingOverlays.update { it + initialOverlays }
            for (slot in slots) {
                repo.saveMessage(slot.message)
            }

            try {
                coroutineScope {
                    slots.map { slot ->
                        async { runSingleSlot(slot, conversation) }
                    }.awaitAll()
                }
            } finally {
                val ids = slots.mapTo(HashSet()) { it.message.id }
                streamingOverlays.update { current -> current - ids }
                repo.saveConversation(conversation.copy(updatedAtEpochMs = System.currentTimeMillis()))
            }
        }
    }

    private suspend fun runSingleSlot(
        slot: StreamSlot,
        conversation: ConversationItem
    ) {
        var liveReply = slot.message
        val target = slot.target
        val provider = slot.provider
        val modelSpec = provider.models.firstOrNull { it.id == target.modelID }
        val startEpochMs = System.currentTimeMillis()
        val startNanos = System.nanoTime()
        var record = RequestRecordItem(
            id = UUID.randomUUID().toString().uppercase(),
            operationID = UUID.randomUUID().toString().uppercase(),
            attempt = 1,
            conversationID = conversation.id,
            messageID = liveReply.id,
            providerID = provider.id,
            providerName = provider.name,
            modelID = target.modelID,
            modelDisplayName = target.modelDisplayName,
            protocolType = target.protocolType,
            kind = slot.kind,
            status = RequestStatus.RUNNING,
            startedAtEpochMs = startEpochMs,
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

        val systemSource = slot.systemPromptOverride ?: conversation.systemPrompt
        val renderedSystem = PromptTemplateEngine.render(systemSource, target)
        val allKeys = container.secretStore.loadAllAPIKeys(provider.id)
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
            messages = slot.history,
            temperature = if (conversation.useCustomTemperature) conversation.temperature else null,
            topP = conversation.topP,
            maxOutputTokens = conversation.maxOutputTokens.takeIf { it > 0 },
            enableThinking = conversation.enableThinking,
            thinkingBudgetTokens = conversation.thinkingBudgetTokens,
            enablePromptCaching = conversation.assistanceSettings.enablePromptCaching,
            idleTimeoutSeconds = provider.idleTimeoutSeconds.takeIf { it > 0 }?.toDouble()
        )

        var reasoningStartMs: Int? = null
        var thinkingEndMs: Int? = null
        var lastDbFlushMs = 0L
        var abnormalFinish = false

        try {
            container.llmClient.streamChat(llmRequest).collect { event ->
                val elapsedMs = ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
                when (event) {
                    is LLMStreamEvent.NonStreamingResponse -> {
                        record = record.copy(isStreamed = false)
                    }
                    is LLMStreamEvent.ReasoningDelta -> if (event.text.isNotEmpty()) {
                        if (reasoningStartMs == null) reasoningStartMs = elapsedMs
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
                    is LLMStreamEvent.ContentDelta -> if (event.text.isNotEmpty()) {
                        if (reasoningStartMs != null && thinkingEndMs == null) {
                            thinkingEndMs = elapsedMs
                        }
                        if (record.firstContentMs == null) {
                            record = record.copy(firstContentMs = elapsedMs)
                        }
                        record = record.copy(
                            lastOutputMs = elapsedMs,
                            outputChunkCount = record.outputChunkCount + 1
                        )
                        liveReply = liveReply.copy(
                            content = liveReply.content + event.text,
                            thinkingDurationMs = thinkingEndMs?.let { end ->
                                reasoningStartMs?.let { start -> maxOf(0, end - start) }
                            } ?: liveReply.thinkingDurationMs
                        )
                        streamingOverlays.update { it + (liveReply.id to liveReply) }
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
                    is LLMStreamEvent.ThinkingBlock,
                    is LLMStreamEvent.ToolCall,
                    is LLMStreamEvent.GroundingSource,
                    is LLMStreamEvent.Done -> Unit
                }

                val nowClock = System.currentTimeMillis()
                if (nowClock - lastDbFlushMs >= 150L) {
                    lastDbFlushMs = nowClock
                    repo.saveMessage(liveReply)
                }
            }

            val totalMs = ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
            val firstMs = RequestMetrics.firstOutputMs(record.firstReasoningMs, record.firstContentMs)
            val finalThinkingMs = liveReply.thinkingDurationMs
                ?: reasoningStartMs?.let { rs -> maxOf(0, (thinkingEndMs ?: totalMs) - rs) }
            val finalStatus = if (abnormalFinish) RequestStatus.INCOMPLETE else RequestStatus.SUCCEEDED

            liveReply = liveReply.copy(
                isStreaming = false,
                latencyMs = firstMs ?: totalMs,
                thinkingDurationMs = finalThinkingMs,
                latestRequestID = record.id
            )
            record = record.copy(
                status = finalStatus,
                durationMs = totalMs,
                endedAtEpochMs = System.currentTimeMillis()
            )
        } catch (_: CancellationException) {
            val totalMs = ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
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
        } catch (t: Throwable) {
            val totalMs = ((System.nanoTime() - startNanos) / 1_000_000L).toInt().coerceAtLeast(0)
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
        } finally {
            repo.saveMessage(liveReply)
            repo.saveRequestRecord(record)
            streamingOverlays.update { it - liveReply.id }
        }
    }

    private fun makeUserMessage(
        conversationID: String,
        text: String,
        attachments: List<MessageAttachment>,
        sortIndex: Int,
        createdAtEpochMs: Long
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
        parentMessageID = null,
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
