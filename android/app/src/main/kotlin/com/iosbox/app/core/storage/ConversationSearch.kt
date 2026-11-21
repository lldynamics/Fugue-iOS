package com.iosbox.app.core.storage

import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.network.ArenaSynthesis

data class SearchExcerpt(
    val before: String,
    val match: String,
    val after: String
) {
    companion object {
        fun find(text: String, query: String): SearchExcerpt? {
            if (query.isEmpty() || text.isEmpty()) return null
            val idx = text.indexOf(query, ignoreCase = true)
            if (idx < 0) return null
            val end = idx + query.length
            val start = (idx - 24).coerceAtLeast(0)
            val tail = (end + 64).coerceAtMost(text.length)
            return SearchExcerpt(
                before = (if (start == 0) "" else "…") + text.substring(start, idx),
                match = text.substring(idx, end),
                after = text.substring(end, tail) + (if (tail == text.length) "" else "…")
            )
        }
    }
}

data class ConversationSearchHit(
    val messageID: String,
    val createdAtEpochMs: Long,
    val comparisonGroupID: String?,
    val excerpt: SearchExcerpt,
    val speaker: String
)

data class ConversationSearchResult(
    val conversationID: String,
    val matchesDetails: Boolean,
    val hits: List<ConversationSearchHit>
)

data class InChatSearchHit(
    val messageID: String,
    val excerpt: SearchExcerpt?
)

object ConversationSearch {
    fun search(
        conversations: List<ConversationItem>,
        messagesByConversation: Map<String, List<ChatMessageItem>>,
        query: String,
        folderTag: String? = null,
        bookmarkedChatsOnly: Boolean = false
    ): List<ConversationSearchResult> {
        val trimmedQuery = query.trim()
        val normalizedTag = folderTag?.trim()?.takeIf { it.isNotEmpty() }

        val results = mutableListOf<ConversationSearchResult>()
        for (conv in conversations) {
            if (normalizedTag != null && conv.folderTag?.trim() != normalizedTag) continue
            val convMsgs = messagesByConversation[conv.id.uppercase()] ?: messagesByConversation[conv.id] ?: emptyList()
            if (bookmarkedChatsOnly && convMsgs.none { it.assistanceMetadata.isBookmarked }) continue

            if (trimmedQuery.isEmpty()) {
                results.add(ConversationSearchResult(conv.id, matchesDetails = true, hits = emptyList()))
                continue
            }

            val detailsMatch = conv.title.contains(trimmedQuery, ignoreCase = true) ||
                conv.folderTag?.contains(trimmedQuery, ignoreCase = true) == true ||
                conv.primaryTarget?.modelDisplayName?.contains(trimmedQuery, ignoreCase = true) == true ||
                conv.groupMembers.any { it.displayLabel.contains(trimmedQuery, ignoreCase = true) }

            val blind = conv.assistanceSettings.blindArenaMode
            val groups = if (blind) convMsgs.filter { it.comparisonGroupID != null }.groupBy { it.comparisonGroupID?.uppercase().orEmpty() }
            else emptyMap()

            val hits = convMsgs.asSequence()
                .filter { !it.assistanceMetadata.isContextDivider }
                .mapNotNull { msg ->
                    val excerpt = SearchExcerpt.find(msg.content, trimmedQuery)
                        ?: SearchExcerpt.find(msg.reasoningContent, trimmedQuery)
                        ?: msg.attachments.firstNotNullOfOrNull { SearchExcerpt.find(it.fileName, trimmedQuery) }
                        ?: return@mapNotNull null
                    val speaker = when (msg.role) {
                        MessageRole.USER -> L10n.text("提问", "You")
                        MessageRole.SYSTEM -> L10n.text("系统", "System")
                        else -> ArenaSynthesis.visibleSpeakerName(
                            message = msg,
                            allGroupCandidates = msg.comparisonGroupID?.let { groups[it.uppercase()] }.orEmpty(),
                            blindArenaMode = blind
                        )
                    }
                    ConversationSearchHit(
                        messageID = msg.id,
                        createdAtEpochMs = msg.createdAtEpochMs,
                        comparisonGroupID = msg.comparisonGroupID,
                        excerpt = excerpt,
                        speaker = speaker
                    )
                }
                .sortedByDescending { it.createdAtEpochMs }
                .toList()

            if (detailsMatch || hits.isNotEmpty()) {
                results.add(ConversationSearchResult(conv.id, matchesDetails = detailsMatch, hits = hits))
            }
        }
        return results
    }

    fun inConversation(
        messages: List<ChatMessageItem>,
        query: String,
        bookmarksOnly: Boolean
    ): List<InChatSearchHit> {
        val cleanQuery = query.trim()
        val results = mutableListOf<InChatSearchHit>()
        for (msg in messages) {
            val meta = msg.assistanceMetadata
            if (meta.isContextDivider) continue
            if (bookmarksOnly && !meta.isBookmarked) continue
            if (cleanQuery.isEmpty()) {
                if (bookmarksOnly) results.add(InChatSearchHit(msg.id, excerpt = null))
                continue
            }
            val excerpt = SearchExcerpt.find(msg.content, cleanQuery)
                ?: SearchExcerpt.find(msg.reasoningContent, cleanQuery)
                ?: msg.attachments.firstNotNullOfOrNull { SearchExcerpt.find(it.fileName, cleanQuery) }
            if (excerpt != null) {
                results.add(InChatSearchHit(msg.id, excerpt = excerpt))
            }
        }
        return results
    }
}
