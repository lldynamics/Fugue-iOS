package com.iosbox.app

import com.iosbox.app.core.backup.BackupJson
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.ArenaBallot
import com.iosbox.app.core.model.ConversationAssistanceSettings
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.network.ArenaSynthesis
import com.iosbox.app.core.storage.ChatMessageItem
import com.iosbox.app.core.storage.ChatRepository
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArenaTest {
    private val groupId = "11111111-1111-4111-8111-111111111111"
    private val convId = "99999999-9999-4999-8999-999999999999"

    private fun sampleMessage(
        id: String,
        role: MessageRole = MessageRole.ASSISTANT,
        content: String = "Answer from $id",
        providerID: String? = "P1",
        providerName: String = "OpenAI",
        modelID: String = "gpt-4.1",
        modelDisplayName: String = "GPT-4.1",
        comparisonGroupID: String? = groupId,
        isSelectedInGroup: Boolean = false,
        isStreaming: Boolean = false,
        errorMessage: String? = null,
        finishReason: String? = null,
        synthesisSourceDigest: String? = null,
        assistanceMetadata: MessageAssistanceMetadata = MessageAssistanceMetadata(),
        sortIndex: Int = 1
    ): ChatMessageItem = ChatMessageItem(
        id = id,
        conversationID = convId,
        role = role,
        content = content,
        reasoningContent = "",
        attachments = emptyList(),
        providerID = providerID,
        providerName = providerName,
        modelID = modelID,
        modelDisplayName = modelDisplayName,
        accentHex = "#3F6EF6",
        comparisonGroupID = comparisonGroupID,
        isSelectedInGroup = isSelectedInGroup,
        isStreaming = isStreaming,
        errorMessage = errorMessage,
        finishReason = finishReason,
        promptTokens = null,
        completionTokens = null,
        cachedTokens = null,
        latencyMs = null,
        thinkingDurationMs = null,
        synthesisSourceDigest = synthesisSourceDigest,
        latestRequestID = null,
        assistanceMetadata = assistanceMetadata,
        parentMessageID = null,
        sortIndex = sortIndex,
        createdAtEpochMs = 1_795_239_000_000L + sortIndex
    )

    @Test
    fun arenaDigestDetectsUpdatesAndValidatesCurrency() {
        val m1 = sampleMessage(id = "M1", content = "Candidate 1", sortIndex = 1)
        val m2 = sampleMessage(id = "M2", content = "Candidate 2", modelID = "claude-3-7-sonnet", modelDisplayName = "Claude 3.7", sortIndex = 2)
        val initialDigest = ArenaSynthesis.digest(listOf(m1, m2))
        val synthesis = sampleMessage(
            id = "SYNTH",
            content = "Synthesized answer",
            modelID = "gemini-2.5-pro",
            modelDisplayName = "Gemini 2.5 Pro",
            synthesisSourceDigest = initialDigest,
            sortIndex = 3
        )

        assertTrue(ArenaSynthesis.isCurrent(synthesis, listOf(m1, m2, synthesis)))

        // Modifying source content invalidates synthesis currency
        val updatedM2 = m2.copy(content = "Candidate 2 revised")
        assertFalse(ArenaSynthesis.isCurrent(synthesis, listOf(m1, updatedM2, synthesis)))
        assertNotEquals(initialDigest, ArenaSynthesis.digest(listOf(m1, updatedM2)))

        // Order-independent digest
        assertEquals(initialDigest, ArenaSynthesis.digest(listOf(m2, m1)))
    }

    @Test
    fun blindDisplayOrderIsDeterministicAndIndependentOfInputOrder() {
        val mA = sampleMessage(id = "AAAA", modelDisplayName = "Model One", sortIndex = 1)
        val mB = sampleMessage(id = "BBBB", modelDisplayName = "Model Two", sortIndex = 2)
        val mC = sampleMessage(id = "CCCC", modelDisplayName = "Model Three", sortIndex = 3)
        val synth = sampleMessage(id = "SSSS", content = "Summary", synthesisSourceDigest = "abc", sortIndex = 4)

        val orderForward = ArenaSynthesis.blindDisplayOrder(listOf(mA, mB, mC, synth), groupId)
        val orderReversed = ArenaSynthesis.blindDisplayOrder(listOf(synth, mC, mB, mA), groupId)

        assertEquals(orderForward.map { it.id }, orderReversed.map { it.id })
        // Syntheses always stay at the end
        assertEquals("SSSS", orderForward.last().id)
    }

    @Test
    fun candidateAndCritiquePromptsHideIdentitiesInBlindMode() {
        val m1 = sampleMessage(id = "A1", content = "First response", providerName = "SecretProviderOne", modelID = "secret-gpt", modelDisplayName = "SecretGPT")
        val m2 = sampleMessage(id = "A2", content = "Second response", providerID = "P2", providerName = "SecretProviderTwo", modelID = "secret-claude", modelDisplayName = "SecretClaude")

        val blindSynthPrompt = ArenaSynthesis.candidatePrompt(
            eligible = listOf(m1, m2),
            totalCount = 2,
            blind = true,
            allGroupCandidates = listOf(m1, m2)
        )
        assertFalse(blindSynthPrompt.contains("SecretGPT"))
        assertFalse(blindSynthPrompt.contains("SecretClaude"))
        assertFalse(blindSynthPrompt.contains("SecretProviderOne"))

        val revealedSynthPrompt = ArenaSynthesis.candidatePrompt(
            eligible = listOf(m1, m2),
            totalCount = 2,
            blind = false
        )
        assertTrue(revealedSynthPrompt.contains("SecretGPT"))
        assertTrue(revealedSynthPrompt.contains("SecretClaude"))

        val target1 = ResolvedModelTarget(
            providerID = "P1",
            providerName = "SecretProviderOne",
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            modelID = "secret-gpt",
            modelDisplayName = "SecretGPT",
            accentHex = "#3F6EF6",
            supportsVision = false,
            supportsReasoning = false
        )
        val blindCritique = ArenaSynthesis.critiquePrompt(target1, listOf(m1, m2), blind = true)
        assertTrue(blindCritique.contains("Your previous answer"))
        assertFalse(blindCritique.contains("SecretClaude"))
        assertFalse(blindCritique.contains("SecretGPT"))
    }

    @Test
    fun arenaBallotStandingsAggregatesAndSortsDeterministically() {
        val ballotRound1 = ArenaBallot(
            winnerID = "G1_M1",
            candidates = listOf(
                ArenaBallot.Candidate("G1_M1", "P1", "OpenAI", "gpt-4.1", "GPT-4.1"),
                ArenaBallot.Candidate("G1_M2", "P2", "Anthropic", "claude-3-7", "Claude 3.7")
            )
        )
        val ballotRound2 = ArenaBallot(
            winnerID = "G2_M2",
            candidates = listOf(
                ArenaBallot.Candidate("G2_M1", "P1", "OpenAI", "gpt-4.1", "GPT-4.1"),
                ArenaBallot.Candidate("G2_M2", "P2", "Anthropic", "claude-3-7", "Claude 3.7")
            )
        )
        val ballotRound3 = ArenaBallot(
            winnerID = "G3_M1",
            candidates = listOf(
                ArenaBallot.Candidate("G3_M1", "P1", "OpenAI", "gpt-4.1", "GPT-4.1"),
                ArenaBallot.Candidate("G3_M2", "P2", "Anthropic", "claude-3-7", "Claude 3.7")
            )
        )

        val messages = listOf(
            // Round 1 winner (also include losing message to verify ballot isn't double-counted)
            sampleMessage(
                id = "G1_M1",
                comparisonGroupID = "G1",
                assistanceMetadata = MessageAssistanceMetadata(blindArenaRevealed = true, blindArenaBallot = ballotRound1)
            ),
            sampleMessage(
                id = "G1_M2",
                comparisonGroupID = "G1",
                assistanceMetadata = MessageAssistanceMetadata(blindArenaRevealed = true)
            ),
            // Round 2 winner
            sampleMessage(
                id = "G2_M2",
                comparisonGroupID = "G2",
                assistanceMetadata = MessageAssistanceMetadata(blindArenaRevealed = true, blindArenaBallot = ballotRound2)
            ),
            // Round 3 winner
            sampleMessage(
                id = "G3_M1",
                comparisonGroupID = "G3",
                assistanceMetadata = MessageAssistanceMetadata(blindArenaRevealed = true, blindArenaBallot = ballotRound3)
            )
        )

        val standings = ArenaBallot.standings(messages)
        assertEquals(2, standings.size)
        // GPT-4.1 won 2/3, Claude 3.7 won 1/3
        assertEquals("gpt-4.1", standings[0].modelID)
        assertEquals(2, standings[0].wins)
        assertEquals(3, standings[0].rounds)
        assertEquals("claude-3-7", standings[1].modelID)
        assertEquals(1, standings[1].wins)
        assertEquals(3, standings[1].rounds)
    }

    @Test
    fun assistanceModelsMergePreservesUnknownIosBackupFields() {
        val codec = BackupJson.codec
        val existingConvJson = codec.parseToJsonElement(
            """{"backupState":{"legacyImportID":"AAAA"},"autoGenerateTitle":true,"blindArenaMode":false}"""
        ).jsonObject
        val convSettings = ConversationAssistanceSettings(blindArenaMode = true, usePersonalMemory = true)
        val mergedConv = convSettings.mergeInto(existingConvJson, codec)
        assertEquals("true", mergedConv["blindArenaMode"]?.jsonPrimitive?.content)
        assertEquals("true", mergedConv["autoGenerateTitle"]?.jsonPrimitive?.content)
        assertEquals("AAAA", mergedConv["backupState"]?.jsonObject?.get("legacyImportID")?.jsonPrimitive?.content)

        val ballot = ArenaBallot(winnerID = "M1")
        val existingMsgJson = codec.parseToJsonElement(
            """{"studyFlashcards":[{"id":"t1","name":"calc"}],"blindArenaBallot":{"winnerID":"OLD"}}"""
        ).jsonObject
        val msgMetaWithBallot = MessageAssistanceMetadata(blindArenaRevealed = true, blindArenaBallot = ballot)
        val mergedWithBallot = msgMetaWithBallot.mergeInto(existingMsgJson, codec)
        assertEquals("calc", mergedWithBallot["studyFlashcards"].toString().let { if (it.contains("calc")) "calc" else "" })
        assertEquals("M1", mergedWithBallot["blindArenaBallot"]?.jsonObject?.get("winnerID")?.jsonPrimitive?.content)

        val clearedBallotMeta = MessageAssistanceMetadata(blindArenaRevealed = true, blindArenaBallot = null)
        val mergedCleared = clearedBallotMeta.mergeInto(mergedWithBallot, codec)
        assertNull(mergedCleared["blindArenaBallot"])
        assertTrue(mergedCleared.containsKey("studyFlashcards"))
    }

    @Test
    fun buildPromptHistoryPicksSelectedWinnerAndSkipsStaleSynthesis() {
        val userQ = sampleMessage(id = "U1", role = MessageRole.USER, content = "Question 1", comparisonGroupID = null, sortIndex = 0)
        val cand1 = sampleMessage(id = "C1", content = "Answer A", isSelectedInGroup = false, sortIndex = 1)
        val cand2 = sampleMessage(id = "C2", content = "Answer B", isSelectedInGroup = false, sortIndex = 2)
        val staleDigest = "outdated-sha256"
        val staleSynthesisSelected = sampleMessage(
            id = "S1",
            content = "Stale judge summary",
            isSelectedInGroup = true,
            synthesisSourceDigest = staleDigest,
            sortIndex = 3
        )

        val historyWithStaleSynth = ChatRepository.buildPromptHistory(
            listOf(userQ, cand1, cand2, staleSynthesisSelected),
            limit = 20
        )
        assertEquals(2, historyWithStaleSynth.size)
        // Must skip stale synthesis even though isSelectedInGroup = true, falling back to first original candidate
        assertEquals("Answer A", historyWithStaleSynth[1].content)

        // With current digest, selected synthesis MUST be used
        val validDigest = ArenaSynthesis.digest(listOf(cand1, cand2))
        val currentSynthesisSelected = staleSynthesisSelected.copy(synthesisSourceDigest = validDigest)
        val historyWithValidSynth = ChatRepository.buildPromptHistory(
            listOf(userQ, cand1, cand2, currentSynthesisSelected),
            limit = 20
        )
        assertEquals(2, historyWithValidSynth.size)
        assertEquals("Stale judge summary", historyWithValidSynth[1].content)
    }
}
