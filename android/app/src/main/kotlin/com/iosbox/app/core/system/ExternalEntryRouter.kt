package com.iosbox.app.core.system

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Process
import android.net.Uri
import androidx.core.content.IntentCompat
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.network.WebpageReader
import com.iosbox.app.core.storage.AttachmentProcessor
import com.iosbox.app.core.storage.ChatRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

enum class ShareReadingAction {
    DEEP_SUMMARY,
    TRANSLATE,
    CRITICAL_REVIEW,
    KEY_TAKEAWAYS,
    DIRECT_CHAT;

    val label: String
        get() = when (this) {
            DEEP_SUMMARY -> L10n.text("深度总结", "Summarize")
            TRANSLATE -> L10n.text("地道翻译", "Translate")
            CRITICAL_REVIEW -> L10n.text("深度追问", "Critical Critique")
            KEY_TAKEAWAYS -> L10n.text("行动清单", "Action Items")
            DIRECT_CHAT -> L10n.text("直接发送", "Send As-Is")
        }

    fun buildPrompt(
        body: String,
        pageTitle: String? = null,
        sourceUrl: String? = null
    ): String {
        val header = buildList {
            if (!pageTitle.isNullOrBlank()) add("Title: ${pageTitle.trim()}")
            if (!sourceUrl.isNullOrBlank()) add("Source: ${sourceUrl.trim()}")
        }.joinToString("\n")
        val contentBlock = if (header.isEmpty()) body.trim() else "$header\n\n${body.trim()}"
        if (this == DIRECT_CHAT) return contentBlock
        val prefix = when (this) {
            DEEP_SUMMARY -> L10n.text(
                "请对以下内容进行结构化深度总结，提炼核心观点、论据脉络与关键细节：",
                "Please provide a structured deep summary of the content below, highlighting the thesis, reasoning, and key details:"
            )
            TRANSLATE -> L10n.text(
                "请将以下内容翻译为地道自然的表达（外文译简体中文，中文译英文），并简要解释专业术语：",
                "Please translate the content below naturally (to Simplified Chinese or English) and clarify key technical terms:"
            )
            CRITICAL_REVIEW -> L10n.text(
                "请对以下观点进行批判性审视：指出隐含假设、逻辑漏洞、潜在反例与值得继续追问的问题：",
                "Please critically examine the material below: surface hidden assumptions, potential counterarguments, and deeper questions:"
            )
            KEY_TAKEAWAYS -> L10n.text(
                "请从以下内容中提炼可执行的要点清单与下一步建议：",
                "Please extract concrete key takeaways and recommended next steps from the content below:"
            )
            DIRECT_CHAT -> ""
        }
        return if (contentBlock.isEmpty()) prefix else "$prefix\n\n$contentBlock"
    }
}

data class ExternalSharePayload(
    val sharedText: String = "",
    val subject: String? = null,
    val streamUris: List<String> = emptyList(),
    val detectedHttpsUrl: String? = null,
    val isProcessText: Boolean = false,
    val attachmentsRejected: Boolean = false
)

data class InitialConversationDraft(
    val text: String,
    val attachments: List<MessageAttachment> = emptyList(),
    val autoSend: Boolean = false,
    val userAuthored: Boolean = false
)

sealed interface IncomingEntryRequest {
    data class OpenConversation(val conversationId: String) : IncomingEntryRequest
    data object NewChat : IncomingEntryRequest
    data object NewArena : IncomingEntryRequest
    data object OpenFlashcards : IncomingEntryRequest
    data class SharedContent(val payload: ExternalSharePayload) : IncomingEntryRequest
}

object ExternalEntryParser {
    private val HTTPS_URL_REGEX = Regex("https?://[^\\s<>\"'()]+", RegexOption.IGNORE_CASE)

    fun extractSinglePublicHttpsUrl(text: String): String? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return null
        val matches = HTTPS_URL_REGEX.findAll(trimmed).map { it.value.trimEnd('.', ',', ';', ')', ']') }.toList()
        if (matches.size != 1) return null
        val uri = runCatching { URI(matches[0]) }.getOrNull() ?: return null
        return runCatching {
            WebpageReader.validate(uri)
            uri.toASCIIString()
        }.getOrNull()
    }

    fun parseDeepLink(uriString: String?): IncomingEntryRequest? {
        val raw = uriString?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val uri = runCatching { URI(raw) }.getOrNull() ?: return null
        if (!uri.scheme.equals("fugue", ignoreCase = true)) return null
        val host = uri.host?.lowercase().orEmpty()
        val path = uri.path.orEmpty().removePrefix("/")
        return when (host) {
            "chat" -> ChatRepository.canonicalConversationID(path)?.let { IncomingEntryRequest.OpenConversation(it) }
            "new-chat" -> IncomingEntryRequest.NewChat
            "new-arena" -> IncomingEntryRequest.NewArena
            "flashcards" -> IncomingEntryRequest.OpenFlashcards
            else -> null
        }
    }
}

class ExternalEntryRouter {
    private val _pendingRequest = MutableStateFlow<IncomingEntryRequest?>(null)
    val pendingRequest: StateFlow<IncomingEntryRequest?> = _pendingRequest.asStateFlow()

    private val stagedDrafts = ConcurrentHashMap<String, InitialConversationDraft>()

    fun ingestIntent(intent: Intent?, context: Context) {
        if (intent == null) return

        val explicitConvId = ChatRepository.canonicalConversationID(
            runCatching { intent.getStringExtra(EXTRA_CONVERSATION_ID) }.getOrNull()
        )
        if (explicitConvId != null) {
            _pendingRequest.value = IncomingEntryRequest.OpenConversation(explicitConvId)
            return
        }

        when (intent.action) {
            ACTION_NEW_CHAT -> {
                _pendingRequest.value = IncomingEntryRequest.NewChat
            }
            Intent.ACTION_VIEW -> {
                ExternalEntryParser.parseDeepLink(intent.dataString)?.let { req ->
                    _pendingRequest.value = req
                }
            }
            Intent.ACTION_PROCESS_TEXT -> {
                val selectedText = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.trim().orEmpty()
                if (selectedText.isNotEmpty()) {
                    _pendingRequest.value = IncomingEntryRequest.SharedContent(
                        ExternalSharePayload(
                            sharedText = selectedText,
                            detectedHttpsUrl = ExternalEntryParser.extractSinglePublicHttpsUrl(selectedText),
                            isProcessText = true
                        )
                    )
                }
            }
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val payload = try {
                    sharedPayload(context, intent)
                } catch (_: RuntimeException) {
                    ExternalSharePayload(attachmentsRejected = true)
                }
                if (payload.sharedText.isNotEmpty() || payload.streamUris.isNotEmpty() || payload.attachmentsRejected) {
                    _pendingRequest.value = IncomingEntryRequest.SharedContent(payload)
                }
            }
        }
    }

    private fun sharedPayload(context: Context, intent: Intent): ExternalSharePayload {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        val subject = intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT)?.toString()?.trim()
        val items: List<*>? = if (intent.action == Intent.ACTION_SEND) {
            IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)?.let { listOf(it) }
        } else {
            IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
        }
        val clip = intent.clipData
        val clipCount = clip?.itemCount ?: 0
        // Older Android versions do not verify the types inside a Parcelable list.
        val rejected = if (items == null) {
            intent.hasExtra(Intent.EXTRA_STREAM)
        } else {
            items.size > AttachmentProcessor.MAXIMUM_ATTACHMENT_COUNT ||
                (items.isNotEmpty() && ((intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION) == 0 ||
                    clipCount > AttachmentProcessor.MAXIMUM_ATTACHMENT_COUNT ||
                    items.any { item ->
                        item !is Uri || (intent.data != item && (0 until clipCount).none { clip?.getItemAt(it)?.uri == item }) ||
                            !canReadSharedAttachment(context, item)
                    }))
        }
        return ExternalSharePayload(
            sharedText = text,
            subject = subject,
            streamUris = if (rejected) emptyList() else items.orEmpty().map { it.toString() },
            detectedHttpsUrl = ExternalEntryParser.extractSinglePublicHttpsUrl(text),
            attachmentsRejected = rejected
        )
    }

    companion object {
        const val ACTION_NEW_CHAT = "com.iosbox.app.action.NEW_CHAT"
        const val EXTRA_CONVERSATION_ID = "extra_conversation_id"

        fun canReadSharedAttachment(context: Context, uri: Uri): Boolean {
            if (uri.scheme != "content") return false
            val authority = uri.authority?.takeIf { it.isNotEmpty() } ?: return false
            val provider = context.packageManager.resolveContentProvider(authority, 0) ?: return false
            if (provider.packageName == context.packageName || provider.applicationInfo.uid == Process.myUid()) return false
            return context.checkUriPermission(uri, Process.myPid(), Process.myUid(),
                Intent.FLAG_GRANT_READ_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun clearPendingRequest() {
        _pendingRequest.value = null
    }

    fun consumeRequest(expected: IncomingEntryRequest): Boolean =
        _pendingRequest.compareAndSet(expected, null)

    fun stageInitialDraft(conversationId: String, draft: InitialConversationDraft) {
        stagedDrafts[conversationId.uppercase()] = draft
    }

    fun consumeInitialDraft(conversationId: String): InitialConversationDraft? =
        stagedDrafts.remove(conversationId.uppercase())

}
