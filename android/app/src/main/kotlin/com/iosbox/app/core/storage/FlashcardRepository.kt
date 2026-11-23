package com.iosbox.app.core.storage

import com.iosbox.app.core.backup.BackupJson
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.StudyCardDraft
import com.iosbox.app.core.model.StudyFlashcard
import com.iosbox.app.core.model.StudyReviewRating
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import java.util.UUID

class FlashcardRepository(
    private val blobStore: ExternalBlobStore
) {
    private val lock = Any()
    private val _cards = MutableStateFlow(loadFromStore())
    val cards: StateFlow<List<StudyFlashcard>> = _cards.asStateFlow()

    fun reload() {
        synchronized(lock) {
            _cards.value = loadFromStore()
        }
    }

    fun deckNames(source: List<StudyFlashcard> = _cards.value): List<String> {
        val seen = LinkedHashSet<String>()
        for (card in source) {
            seen.add(normalizeDeckName(card.deckName))
        }
        return seen.sortedWith(String.CASE_INSENSITIVE_ORDER)
    }

    fun dueCards(
        deck: String? = null,
        nowEpochMs: Long = System.currentTimeMillis()
    ): List<StudyFlashcard> = _cards.value
        .filter { card ->
            (deck.isNullOrBlank() || normalizeDeckName(card.deckName) == normalizeDeckName(deck)) &&
                card.isDue(nowEpochMs)
        }
        .sortedBy { it.dueAt }

    fun filteredCards(deck: String? = null, query: String = ""): List<StudyFlashcard> {
        val q = query.trim().lowercase()
        return _cards.value.filter { card ->
            val deckOk = deck.isNullOrBlank() || normalizeDeckName(card.deckName) == normalizeDeckName(deck)
            if (!deckOk) return@filter false
            if (q.isEmpty()) return@filter true
            card.front.lowercase().contains(q) ||
                card.back.lowercase().contains(q) ||
                card.deckName.lowercase().contains(q)
        }
    }

    fun contains(front: String, deckName: String? = null): Boolean {
        val normalizedFront = front.trim().lowercase()
        if (normalizedFront.isEmpty()) return false
        return _cards.value.any { card ->
            if (deckName != null && normalizeDeckName(card.deckName) != normalizeDeckName(deckName)) {
                false
            } else {
                card.front.trim().lowercase() == normalizedFront
            }
        }
    }

    fun addCard(
        deckName: String,
        front: String,
        back: String,
        hint: String? = null,
        sourceConversationID: String? = null,
        sourceMessageID: String? = null,
        nowEpochMs: Long = System.currentTimeMillis()
    ): StudyFlashcard? = change { list ->
        upsertCard(
            list = list,
            deckName = deckName,
            front = front,
            back = back,
            hint = hint,
            sourceConversationID = sourceConversationID,
            sourceMessageID = sourceMessageID,
            nowEpochMs = nowEpochMs
        )
    }

    fun addDrafts(
        drafts: List<StudyCardDraft>,
        deckName: String,
        conversationID: String? = null,
        messageID: String? = null,
        nowEpochMs: Long = System.currentTimeMillis()
    ): Int = change { list ->
        val before = list.size
        for (draft in drafts.asReversed()) {
            upsertCard(
                list = list,
                deckName = deckName,
                front = draft.front,
                back = draft.back,
                hint = draft.hint,
                sourceConversationID = conversationID,
                sourceMessageID = messageID,
                nowEpochMs = nowEpochMs
            )
        }
        list.size - before
    }

    fun mergeImported(incoming: List<StudyFlashcard>): Int {
        if (incoming.isEmpty()) return 0
        return change(requireReadableStore = true) { list ->
            val existingIDs = list.mapTo(HashSet()) { it.id.uppercase() }
            var added = 0
            for (card in incoming) {
                val cleanFront = card.front.trim()
                val cleanBack = card.back.trim()
                if (cleanFront.isEmpty() || cleanBack.isEmpty()) continue
                if (!existingIDs.add(card.id.uppercase())) continue
                val cleanHint = card.hint?.trim()?.takeIf { it.isNotEmpty() }?.take(300)
                list.add(
                    card.copy(
                        id = card.id.uppercase(),
                        deckName = normalizeDeckName(card.deckName),
                        front = cleanFront.take(600),
                        back = cleanBack.take(2000),
                        hint = cleanHint,
                        easeFactor = if (card.easeFactor.isFinite()) card.easeFactor.coerceIn(1.3, 5.0) else 2.5,
                        intervalDays = if (card.intervalDays.isFinite()) card.intervalDays.coerceIn(0.0, 3650.0) else 0.0,
                        repetitions = card.repetitions.coerceAtLeast(0),
                        lapses = card.lapses.coerceAtLeast(0)
                    )
                )
                added++
            }
            if (added > 0) {
                list.sortByDescending { it.createdAt }
            }
            added
        }
    }

    fun updateCard(id: String, deckName: String, front: String, back: String, hint: String?) {
        change { list ->
            val idx = list.indexOfFirst { it.id.equals(id, ignoreCase = true) }
            if (idx < 0) return@change
            val cleanFront = front.trim()
            val cleanBack = back.trim()
            if (cleanFront.isEmpty() || cleanBack.isEmpty()) return@change
            val cleanHint = hint?.trim()?.takeIf { it.isNotEmpty() }?.take(300)
            list[idx] = list[idx].copy(
                deckName = normalizeDeckName(deckName),
                front = cleanFront.take(600),
                back = cleanBack.take(2000),
                hint = cleanHint
            )
        }
    }

    fun recordReview(
        cardID: String,
        rating: StudyReviewRating,
        nowEpochMs: Long = System.currentTimeMillis()
    ) {
        change { list ->
            val idx = list.indexOfFirst { it.id.equals(cardID, ignoreCase = true) }
            if (idx < 0) return@change
            list[idx] = list[idx].applying(rating, nowEpochMs = nowEpochMs)
        }
    }

    fun deleteCard(id: String) {
        change { list ->
            list.removeAll { it.id.equals(id, ignoreCase = true) }
        }
    }

    fun deleteDeck(deckName: String) {
        val target = normalizeDeckName(deckName)
        change { list ->
            list.removeAll { normalizeDeckName(it.deckName) == target }
        }
    }

    fun exportAnkiTSV(deckFilter: String? = null): String {
        val selected = filteredCards(deck = deckFilter)
        val lines = mutableListOf(
            "#separator:tab",
            "#html:true",
            "#tags column:3"
        )
        for (card in selected) {
            val front = escapeTSVField(card.front)
            var back = escapeTSVField(card.back)
            val hint = card.hint
            if (!hint.isNullOrBlank()) {
                back += "<br><br><small>💡 " + escapeTSVField(hint) + "</small>"
            }
            val tag = card.deckName.trim().replace(Regex("\\s+"), "_").replace("\t", "_")
            lines.add("$front\t$back\t$tag")
        }
        return lines.joinToString("\n") + "\n"
    }

    private fun upsertCard(
        list: MutableList<StudyFlashcard>,
        deckName: String,
        front: String,
        back: String,
        hint: String?,
        sourceConversationID: String?,
        sourceMessageID: String?,
        nowEpochMs: Long
    ): StudyFlashcard? {
        val cleanFront = front.trim()
        val cleanBack = back.trim()
        if (cleanFront.isEmpty() || cleanBack.isEmpty()) return null
        val cleanDeck = normalizeDeckName(deckName)
        val cleanHint = hint?.trim()?.takeIf { it.isNotEmpty() }?.take(300)

        val existingIdx = list.indexOfFirst {
            normalizeDeckName(it.deckName) == cleanDeck && it.front.trim().equals(cleanFront, ignoreCase = true)
        }
        if (existingIdx >= 0) {
            val updated = list[existingIdx].copy(
                back = cleanBack.take(2000),
                hint = cleanHint ?: list[existingIdx].hint
            )
            list[existingIdx] = updated
            return updated
        }

        val created = StudyFlashcard(
            id = UUID.randomUUID().toString().uppercase(),
            deckName = cleanDeck,
            front = cleanFront.take(600),
            back = cleanBack.take(2000),
            hint = cleanHint,
            sourceConversationID = sourceConversationID?.uppercase(),
            sourceMessageID = sourceMessageID?.uppercase(),
            dueAt = nowEpochMs,
            createdAt = nowEpochMs
        )
        list.add(0, created)
        return created
    }

    private inline fun <R> change(requireReadableStore: Boolean = false, edit: (MutableList<StudyFlashcard>) -> R): R {
        synchronized(lock) {
            val previous = if (requireReadableStore) decodeStoredCards() else _cards.value
            val current = previous.toMutableList()
            val result = edit(current)
            if (current != previous) {
                val encoded = BackupJson.prettyCodec.encodeToString(current)
                blobStore.writeText(FLASHCARDS_BLOB_KEY, encoded)
                _cards.value = current.toList()
            }
            return result
        }
    }

    private fun loadFromStore(): List<StudyFlashcard> = runCatching { decodeStoredCards() }.getOrDefault(emptyList())

    private fun decodeStoredCards(): List<StudyFlashcard> {
        val raw = blobStore.readText(FLASHCARDS_BLOB_KEY) ?: return emptyList()
        return BackupJson.codec.decodeFromString<List<StudyFlashcard>>(raw)
    }

    companion object {
        const val FLASHCARDS_BLOB_KEY = "sidecar_flashcards.json"

        fun normalizeDeckName(raw: String): String {
            val trimmed = raw.trim()
            if (trimmed.isEmpty() || trimmed == "新对话" || trimmed == "New Chat") {
                return L10n.text("默认卡组", "Default Deck")
            }
            return trimmed.take(60)
        }

        private fun escapeTSVField(text: String): String = text
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\t", "    ")
            .replace("\r\n", "<br>")
            .replace("\n", "<br>")
    }
}
