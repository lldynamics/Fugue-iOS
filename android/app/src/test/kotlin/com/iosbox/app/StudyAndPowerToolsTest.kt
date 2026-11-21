package com.iosbox.app

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.AttachmentKind
import com.iosbox.app.core.model.ConversationAssistanceSettings
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.MessageAttachment
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.model.StudyCardDraft
import com.iosbox.app.core.model.StudyCoachMode
import com.iosbox.app.core.model.StudyFlashcard
import com.iosbox.app.core.model.StudyReviewRating
import com.iosbox.app.core.network.ArenaSynthesis
import com.iosbox.app.core.network.StudyGenerationError
import com.iosbox.app.core.network.StudyGeneratorService
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.ConversationExporter
import com.iosbox.app.core.storage.ConversationItem
import com.iosbox.app.core.storage.ConversationSearch
import com.iosbox.app.core.storage.FlashcardRepository
import com.iosbox.app.core.storage.InMemoryBlobStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StudyAndPowerToolsTest {
    @Test
    fun sm2FlashcardSchedulingComputesIntervalsEaseAndMasteryDeterministically() {
        val t0 = 1_795_239_000_000L
        val card = StudyFlashcard(
            deckName = "Kotlin",
            front = "What does StateFlow guarantee?",
            back = "Conflated hot observable state holder with an initial value.",
            dueAt = t0,
            createdAt = t0
        )
        assertFalse(card.isMastered)
        assertTrue(card.isDue(t0))

        // First Good -> 1 day, reps = 1
        val afterGood1 = card.applying(StudyReviewRating.GOOD, nowEpochMs = t0)
        assertEquals(1, afterGood1.repetitions)
        assertEquals(1.0, afterGood1.intervalDays, 0.001)
        assertEquals(t0 + StudyFlashcard.DAY_MILLIS, afterGood1.dueAt)
        assertFalse(afterGood1.isMastered)

        // Second Good -> 3 days, reps = 2 (interval 3 < 6 -> still not mastered)
        val afterGood2 = afterGood1.applying(StudyReviewRating.GOOD, nowEpochMs = t0)
        assertEquals(2, afterGood2.repetitions)
        assertEquals(3.0, afterGood2.intervalDays, 0.001)
        assertFalse(afterGood2.isMastered)

        // Third Good -> 3 * 2.5 = 8 days, reps = 3 -> mastered!
        val afterGood3 = afterGood2.applying(StudyReviewRating.GOOD, nowEpochMs = t0)
        assertEquals(3, afterGood3.repetitions)
        assertEquals(8.0, afterGood3.intervalDays, 0.001)
        assertTrue(afterGood3.isMastered)

        // Again -> resets reps, lapses+1, ease drops by 0.2, due in 10 minutes
        val lapsed = afterGood3.applying(StudyReviewRating.AGAIN, nowEpochMs = t0)
        assertEquals(0, lapsed.repetitions)
        assertEquals(1, lapsed.lapses)
        assertEquals(2.3, lapsed.easeFactor, 0.001)
        assertEquals(t0 + 10L * 60_000L, lapsed.dueAt)
    }

    @Test
    fun flashcardRepositoryPersistsRoundTripMergesAndExportsAnkiTSV() {
        val blobStore = InMemoryBlobStore()
        val repo1 = FlashcardRepository(blobStore)
        val drafts = listOf(
            StudyCardDraft(front = "What is <T>?\tHint", back = "Line 1\nLine 2 & <check>", hint = "Generics & syntax"),
            StudyCardDraft(front = "Coalescing buffer", back = "Drops older intermediate values.")
        )
        val added = repo1.addDrafts(drafts, deckName = "Kotlin Flow", conversationID = "conv1", messageID = "m1", nowEpochMs = 1_795_239_000_000L)
        assertEquals(2, added)
        assertTrue(repo1.contains("What is <T>?\tHint", deckName = "Kotlin Flow"))

        // Review one card to verify nullable lastReviewedAt ISO-8601 round-trips cleanly across reloads
        val cardId = repo1.cards.value.first().id
        repo1.recordReview(cardId, StudyReviewRating.EASY, nowEpochMs = 1_795_239_000_000L)

        val repo2 = FlashcardRepository(blobStore)
        assertEquals(2, repo2.cards.value.size)
        val reloadedReviewed = repo2.cards.value.first { it.id == cardId }
        assertNotNull(reloadedReviewed.lastReviewedAt)
        assertEquals(4.0, reloadedReviewed.intervalDays, 0.001)

        // Deduplicated merge from imported backup ignores identical existing card IDs
        val importedSame = reloadedReviewed.copy(back = "Overwritten? No")
        val importedNew = StudyFlashcard(id = "EXT_CARD_1", deckName = "Rust", front = "Borrow checker", back = "Enforces aliasing rules.")
        val mergedCount = repo2.mergeImported(listOf(importedSame, importedNew))
        assertEquals(1, mergedCount)
        assertEquals(3, repo2.cards.value.size)

        val tsv = repo2.exportAnkiTSV(deckFilter = "Kotlin Flow")
        assertTrue(tsv.startsWith("#separator:tab\n#html:true\n#tags column:3\n"))
        assertTrue(tsv.contains("&lt;T&gt;"))
        assertTrue(tsv.contains("Line 1<br>Line 2 &amp; &lt;check&gt;"))
        assertTrue(tsv.endsWith("\tKotlin_Flow\n") || tsv.contains("\tKotlin_Flow\n"))
    }

    @Test
    fun studyGeneratorParsersHandleThinkTagsFencesMalformedOptionsAndQuizScoring() {
        val rawCards = """
            <think>Let's distill the most useful cards.</think>
            Here is your deck:
            ```json
            {"cards":[
              {"front":"Q1","back":"A1","hint":"H1"},
              {"front":"  ","back":"Skipped empty front"},
              {"question":"Q2","answer":"A2"}
            ]}
            ```
        """.trimIndent()
        val parsedCards = StudyGeneratorService.parseFlashcardsJSON(rawCards)
        assertEquals(2, parsedCards.size)
        assertEquals("Q1", parsedCards[0].front)
        assertEquals("H1", parsedCards[0].hint)
        assertEquals("Q2", parsedCards[1].front)
        assertEquals("A2", parsedCards[1].back)

        val rawQuiz = """
            ```json
            {
              "title": "Coroutines Quick Check",
              "questions": [
                {
                  "question": "Which builder launches a fire-and-forget coroutine?",
                  "options": ["launch", "", "async", "withContext", "runBlocking"],
                  "correctIndex": 0,
                  "explanation": "launch returns a Job without a typed result."
                },
                {
                  "question": "Broken question pointing to empty option",
                  "options": ["A", ""],
                  "correctIndex": 1,
                  "explanation": "Should be skipped"
                }
              ]
            }
            ```
        """.trimIndent()
        val quiz = StudyGeneratorService.parseQuizJSON(rawQuiz)
        assertEquals("Coroutines Quick Check", quiz.title)
        assertEquals(1, quiz.questions.size)
        assertEquals(listOf("launch", "async", "withContext", "runBlocking"), quiz.questions[0].options)
        assertEquals(0, quiz.answeredCount)

        val answered = quiz.copy(questions = listOf(quiz.questions[0].copy(selectedIndex = 0)))
        assertEquals(1, answered.answeredCount)
        assertEquals(1, answered.correctCount)

        assertThrows(StudyGenerationError.ParseFailed::class.java) {
            StudyGeneratorService.parseFlashcardsJSON("not valid json")
        }
    }

    @Test
    fun buildPromptHistoryHonorsContextDividersAndExcludedMessages() {
        val u1 = sampleMessage("U1", MessageRole.USER, "Old Q", sortIndex = 0)
        val a1 = sampleMessage("A1", MessageRole.ASSISTANT, "Old A", sortIndex = 1)
        val divider = sampleMessage(
            id = "DIV",
            role = MessageRole.SYSTEM,
            content = "以上内容不计入后续上下文",
            sortIndex = 2,
            metadata = MessageAssistanceMetadata(isContextDivider = true)
        )
        val u2 = sampleMessage("U2", MessageRole.USER, "Excluded Q", sortIndex = 3, metadata = MessageAssistanceMetadata(isExcludedFromContext = true))
        val u3 = sampleMessage("U3", MessageRole.USER, "Active Q", sortIndex = 4)
        val a3 = sampleMessage("A3", MessageRole.ASSISTANT, "Active A", sortIndex = 5)

        val history = ChatRepository.buildPromptHistory(listOf(u1, a1, divider, u2, u3, a3), limit = 20)
        assertEquals(listOf("Active Q", "Active A"), history.map { it.content })
    }

    @Test
    fun conversationSearchFindsTitlesTagsMessageBodiesAndBookmarks() {
        val target = ResolvedModelTarget("P1", "OpenAI", APIProtocolType.OPEN_AI_COMPATIBLE, "gpt-4o", "GPT-4o", "#3F6EF6", supportsVision = false, supportsReasoning = false)
        val conv1 = ConversationItem(
            id = "C1", title = "Architecture Notes", isPinned = false, assistantID = null, assistantEmoji = "📐",
            systemPrompt = "", temperature = 0.7, useCustomTemperature = true, topP = 1.0, maxOutputTokens = 0,
            contextMessageLimit = 20, enableThinking = true, thinkingBudgetTokens = 4096, isArenaMode = false,
            primaryTarget = target, arenaTargets = emptyList(), folderTag = "Work",
            createdAtEpochMs = 100L, updatedAtEpochMs = 200L
        )
        val conv2 = conv1.copy(id = "C2", title = "Cooking", folderTag = "Personal")
        val msgs = mapOf(
            "C1" to listOf(
                sampleMessage("M1", MessageRole.USER, "How do we handle backpressure in Kotlin Flow?", convID = "C1"),
                sampleMessage(
                    "M2", MessageRole.ASSISTANT, "Use buffer() or conflate().", convID = "C1",
                    metadata = MessageAssistanceMetadata(isBookmarked = true)
                ),
                sampleMessage(
                    "M_DIV", MessageRole.SYSTEM, "backpressure divider", convID = "C1",
                    metadata = MessageAssistanceMetadata(isContextDivider = true)
                )
            ),
            "C2" to listOf(
                sampleMessage(
                    "M3", MessageRole.ASSISTANT, "Bake sourdough bread", convID = "C2",
                    attachments = listOf(MessageAttachment(kind = AttachmentKind.DOCUMENT, fileName = "flow-diagram.txt", mimeType = "text/plain", byteSize = 128))
                )
            )
        )

        val results = ConversationSearch.search(listOf(conv1, conv2), msgs, query = "flow", folderTag = null, bookmarkedChatsOnly = false)
        assertEquals(listOf("C1", "C2"), results.map { it.conversationID })
        assertEquals(1, results[0].hits.size) // divider ignored

        val bookmarkedOnly = ConversationSearch.search(listOf(conv1, conv2), msgs, query = "", folderTag = "Work", bookmarkedChatsOnly = true)
        assertEquals(listOf("C1"), bookmarkedOnly.map { it.conversationID })

        val inChat = ConversationSearch.inConversation(msgs.getValue("C1"), query = "", bookmarksOnly = true)
        assertEquals(listOf("M2"), inChat.map { it.messageID })
    }

    @Test
    fun conversationExporterGeneratesMarkdownWithReasoningCitationsAndBlindArenaLabels() {
        val conv = ConversationItem(
            id = "C1", title = "Blind Study Session", isPinned = false, assistantID = null, assistantEmoji = "🎓",
            systemPrompt = "Think carefully", temperature = 0.7, useCustomTemperature = true, topP = 1.0, maxOutputTokens = 0,
            contextMessageLimit = 20, enableThinking = true, thinkingBudgetTokens = 4096, isArenaMode = true,
            primaryTarget = null, arenaTargets = emptyList(),
            assistanceSettings = ConversationAssistanceSettings(blindArenaMode = true, studyCoachMode = StudyCoachMode.SOCRATIC),
            folderTag = null, createdAtEpochMs = 100L, updatedAtEpochMs = 1_795_239_000_000L
        )
        val u1 = sampleMessage("U1", MessageRole.USER, "Explain tail recursion", convID = "C1", sortIndex = 0)
        val candA = sampleMessage(
            id = "A1", role = MessageRole.ASSISTANT, content = "Answer One", reasoningContent = "Trace frames",
            convID = "C1", groupID = "G1", isSelectedInGroup = true, sortIndex = 1, modelDisplayName = "SecretClaude"
        )
        val candB = sampleMessage(
            id = "B1", role = MessageRole.ASSISTANT, content = "Answer Two",
            convID = "C1", groupID = "G1", isSelectedInGroup = false, sortIndex = 2, modelDisplayName = "SecretGPT"
        )
        val ordered = ArenaSynthesis.blindDisplayOrder(listOf(candA, candB), "G1")
        assertEquals(2, ordered.size)

        val md = ConversationExporter.makeMarkdown(conv, listOf(u1, candA, candB))
        assertTrue(md.contains("# Blind Study Session"))
        assertTrue(md.contains("> Think carefully"))
        assertTrue(md.contains("<details><summary>"))
        assertTrue(md.contains("Trace frames"))
        assertFalse(md.contains("SecretClaude"))
        assertFalse(md.contains("SecretGPT"))
        assertEquals("Chat-Report", ConversationExporter.sanitizedFileName("Chat/Report:?*"))
    }

    private fun sampleMessage(
        id: String,
        role: MessageRole,
        content: String,
        reasoningContent: String = "",
        convID: String = "C1",
        groupID: String? = null,
        isSelectedInGroup: Boolean = true,
        sortIndex: Int = 0,
        modelDisplayName: String = "Model",
        attachments: List<MessageAttachment> = emptyList(),
        metadata: MessageAssistanceMetadata = MessageAssistanceMetadata()
    ): ChatMessageItem = ChatMessageItem(
        id = id,
        conversationID = convID,
        role = role,
        content = content,
        reasoningContent = reasoningContent,
        attachments = attachments,
        providerID = "P1",
        providerName = if (role == MessageRole.ASSISTANT) "Provider" else "",
        modelID = "m1",
        modelDisplayName = if (role == MessageRole.ASSISTANT) modelDisplayName else "",
        accentHex = "#3F6EF6",
        comparisonGroupID = groupID,
        isSelectedInGroup = isSelectedInGroup,
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
        assistanceMetadata = metadata,
        parentMessageID = null,
        sortIndex = sortIndex,
        createdAtEpochMs = 100L + sortIndex
    )
}
