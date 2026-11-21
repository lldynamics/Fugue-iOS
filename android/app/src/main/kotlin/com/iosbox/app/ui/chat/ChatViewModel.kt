package com.iosbox.app.ui.chat

import android.content.ContentResolver
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.RequestKind
import com.iosbox.app.core.model.RequestMetrics
import com.iosbox.app.core.model.RequestStatus
import com.iosbox.app.core.model.ResolvedModelTarget
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
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
    private val streamingOverlay = MutableStateFlow<ChatMessageItem?>(null)
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
        streamingOverlay,
        combine(bannerError, pendingConsent) { err, consent -> err to consent }
    ) { base, draft, atts, overlay, (err, consent) ->
        val mergedMessages = if (overlay != null) {
            var found = false
            val updated = base.messages.map { m ->
                if (m.id == overlay.id) {
                    found = true
                    overlay
                } else {
                    m
                }
            }
            if (found) updated else updated + overlay
        } else {
            base.messages
        }
        ChatDetailUiState(
            conversation = base.conversation,
            messages = mergedMessages,
            providers = base.providers,
            presets = base.presets,
            draftText = draft,
            draftAttachments = atts,
            isGenerating = overlay != null || mergedMessages.any { it.isStreaming },
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
            repo.saveConversation(conv.copy(primaryTarget = target, updatedAtEpochMs = System.currentTimeMillis()))
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

        if (!container.preferences.isConsentAccepted) {
            val host = runCatching { URI(provider.baseURL.trim().trimEnd('#')).host ?: "" }.getOrDefault("")
            val summary = if (host.isEmpty()) "${provider.name} · ${target.modelDisplayName}"
            else "${provider.name} · ${target.modelDisplayName} ($host)"
            pendingConsent.value = PendingConsentAction(summary) {
                executeSendUserMessage(text, attachments, conv, target, provider)
            }
            return
        }

        executeSendUserMessage(text, attachments, conv, target, provider)
    }

    fun regenerateMessage(assistantMessage: ChatMessageItem) {
        val state = uiState.value
        if (state.isGenerating) return
        val conv = state.conversation ?: return
        val idx = state.messages.indexOfFirst { it.id == assistantMessage.id }
        if (idx <= 0) return

        val ready = ChatRepository.readyTargets(state.providers)
        val requestedTarget = conv.primaryTarget
            ?: assistantMessage.providerID?.let { pid ->
                ready.firstOrNull { it.providerID == pid && it.modelID == assistantMessage.modelID }
            }
            ?: ready.firstOrNull()
        val resolved = requestedTarget?.let { t -> ready.firstOrNull { it.id == t.id } } ?: ready.firstOrNull()
        val provider = resolved?.let { r -> state.providers.firstOrNull { it.id.equals(r.providerID, ignoreCase = true) } }
        if (resolved == null || provider == null) {
            bannerError.value = L10n.text("没有可用的模型用于重答。", "No ready model available to regenerate.")
            return
        }

        val priorMessages = state.messages.subList(0, idx)
        val history = ChatRepository.buildPromptHistory(priorMessages, conv.contextMessageLimit)
        if (history.isEmpty()) return

        if (!container.preferences.isConsentAccepted) {
            val host = runCatching { URI(provider.baseURL.trim().trimEnd('#')).host ?: "" }.getOrDefault("")
            val summary = if (host.isEmpty()) "${provider.name} · ${resolved.modelDisplayName}"
            else "${provider.name} · ${resolved.modelDisplayName} ($host)"
            pendingConsent.value = PendingConsentAction(summary) {
                executeRegenerate(assistantMessage, history, conv, resolved, provider)
            }
            return
        }

        executeRegenerate(assistantMessage, history, conv, resolved, provider)
    }

    fun stopGeneration() {
        activeJob?.cancel()
    }

    private fun executeSendUserMessage(
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
        val userMsg = ChatMessageItem(
            id = UUID.randomUUID().toString().uppercase(),
            conversationID = conv.id,
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
            latestRequestID = null,
            parentMessageID = null,
            sortIndex = nextSort,
            createdAtEpochMs = now
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
            latestRequestID = null,
            parentMessageID = userMsg.id,
            sortIndex = nextSort + 1,
            createdAtEpochMs = now + 1
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

        launchStream(
            conversation = updatedConv,
            userMessageToInsert = userMsg,
            replyMessage = assistantMsg,
            history = history,
            target = target,
            provider = provider,
            kind = RequestKind.ANSWER
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
            thinkingDurationMs = null
        )
        launchStream(
            conversation = conv.copy(updatedAtEpochMs = System.currentTimeMillis()),
            userMessageToInsert = null,
            replyMessage = resetReply,
            history = history,
            target = target,
            provider = provider,
            kind = RequestKind.REGENERATION
        )
    }

    private fun launchStream(
        conversation: ConversationItem,
        userMessageToInsert: ChatMessageItem?,
        replyMessage: ChatMessageItem,
        history: List<LLMPromptMessage>,
        target: ResolvedModelTarget,
        provider: ProviderItem,
        kind: RequestKind
    ) {
        activeJob?.cancel()
        activeJob = viewModelScope.launch {
            repo.saveConversation(conversation)
            if (userMessageToInsert != null) {
                repo.saveMessage(userMessageToInsert)
            }
            var liveReply = replyMessage
            streamingOverlay.value = liveReply
            repo.saveMessage(liveReply)

            val modelSpec = provider.models.firstOrNull { it.id == target.modelID }
            val startEpochMs = System.currentTimeMillis()
            val startNanos = System.nanoTime()
            var record = RequestRecordItem(
                id = UUID.randomUUID().toString().uppercase(),
                operationID = UUID.randomUUID().toString().uppercase(),
                attempt = 1,
                conversationID = conversation.id,
                messageID = replyMessage.id,
                providerID = provider.id,
                providerName = provider.name,
                modelID = target.modelID,
                modelDisplayName = target.modelDisplayName,
                protocolType = target.protocolType,
                kind = kind,
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

            val renderedSystem = PromptTemplateEngine.render(conversation.systemPrompt, target)
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
                messages = history,
                temperature = if (conversation.useCustomTemperature) conversation.temperature else null,
                topP = conversation.topP,
                maxOutputTokens = conversation.maxOutputTokens.takeIf { it > 0 },
                enableThinking = conversation.enableThinking,
                thinkingBudgetTokens = conversation.thinkingBudgetTokens,
                enablePromptCaching = true,
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
                            streamingOverlay.value = liveReply
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
                            streamingOverlay.value = liveReply
                        }
                        is LLMStreamEvent.AttachmentDelta -> {
                            record = record.copy(
                                firstContentMs = record.firstContentMs ?: elapsedMs,
                                lastOutputMs = elapsedMs,
                                outputChunkCount = record.outputChunkCount + 1
                            )
                            liveReply = liveReply.copy(attachments = liveReply.attachments + event.attachment)
                            streamingOverlay.value = liveReply
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
                            streamingOverlay.value = liveReply
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
                repo.saveConversation(conversation.copy(updatedAtEpochMs = System.currentTimeMillis()))
                streamingOverlay.value = null
            }
        }
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
