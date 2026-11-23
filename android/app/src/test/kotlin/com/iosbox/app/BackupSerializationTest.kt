package com.iosbox.app.core.backup

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookManuscript
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.PreparedBook
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.storage.ChatRepository
import com.iosbox.app.core.storage.FlashcardRepository
import com.iosbox.app.core.storage.InMemoryBlobStore
import com.iosbox.app.core.storage.RestoreBlobBatch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class BackupSerializationTest {
    @Test
    fun stagedRestoreCleanupLeavesCommittedAndLegacyFiles() {
        val store = InMemoryBlobStore()
        store.writeText("book_existing.json", "old")
        val batch = RestoreBlobBatch(store)
        val committed = batch.writeText("committed data")
        val orphan = batch.writeText("incomplete restore")
        store.writeText("$orphan.tmp", "temporary data")
        RestoreBlobBatch.reconcile(store, setOf(committed))
        assertEquals(setOf("book_existing.json", committed), store.keys())
        assertEquals("committed data", store.readText(committed))
    }

    @Test
    fun restoredPersonaFeedsRequireLocalOptInAndStartWithoutPollingState() {
        val member = BackupJson.codec.parseToJsonElement("""
            {"name":"Editor","persona":{"feeds":[{"id":"FEED","kind":"blog","address":"https://example.com/feed",
            "enabled":true,"checkpoint":{"recentIDs":["old"]},"lastChecked":15,"lastError":"old status","futureField":true}]}}
        """).jsonObject
        val settings = BackupJson.codec.parseToJsonElement("{\"groupMembers\":[$member],\"privatePersona\":$member}")
        val safeSettings = requireNotNull(BackupRepository.restoredAssistanceSettings(settings))
        for (restored in listOf(
            BackupRepository.restoredMember(member),
            safeSettings["groupMembers"]!!.jsonArray.single().jsonObject,
            safeSettings["privatePersona"]!!.jsonObject
        )) {
            val feed = restored["persona"]!!.jsonObject["feeds"]!!.jsonArray.single().jsonObject
            assertEquals(JsonPrimitive(false), feed["enabled"])
            assertEquals(JsonPrimitive(true), feed["futureField"])
            assertEquals(JsonPrimitive("https://example.com/feed"), feed["address"])
            for (field in listOf("checkpoint", "lastChecked", "lastError")) assertNull(feed[field])
        }
    }
    @Test
    fun restoredBooksPreserveVerifiedNativeAndIosChapterIdentities() {
        val entries = listOf(BookChapterSnapshot("Introducción", "A book / a notebook."))
        val manuscript = BookManuscript("Notes", entries.map { BookChapter(it.title, it.text) })
        val prepared = PreparedBook.from(manuscript)
        val snapshot = BookVolumeSnapshot(prepared.id, manuscript.title, entries, 42L)
        assertEquals(prepared.id, BackupRepository.prepareRestoredBook(snapshot).id)
        // Produced by the iOS sorted-key JSON encoder and its SHA-256 content identifier.
        val iosID = "22497030-B344-803A-B9AF-0E94682CEA89"
        assertEquals(prepared.id, BackupRepository.prepareRestoredBook(snapshot.copy(id = iosID)).id)
        assertThrows(BackupException.ConflictingIDs::class.java) {
            BackupRepository.prepareRestoredBook(snapshot.copy(id = "unverified-identity"))
        }
    }

    @Test
    fun flashcardMergeRetainsExistingEditsAndDeduplicatesRestoredCards() {
        val store = FlashcardRepository(InMemoryBlobStore())
        val local = checkNotNull(store.addCard("Reading", "Local question", "Local answer"))
        val archived = local.copy(id = "restored-card", front = "Archived question", back = "Archived answer")
        assertEquals(1, store.mergeImported(listOf(local.copy(back = "Older answer"), archived)))
        assertEquals(0, store.mergeImported(listOf(archived)))
        assertEquals("Local answer", store.cards.value.first { it.id == local.id }.back)
        assertEquals(2, store.cards.value.size)
        assertThrows(BackupException.UnrecognizedFormat::class.java) {
            BackupRepository.decodeRestoredFlashcards(listOf(JsonPrimitive("not a card")))
        }
    }
    @Test
    fun restoredProviderKeepsItsAddressAndModelsAndRequiresLocalActivation() {
        val archived = ProviderBackup(
            id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            name = "Home provider",
            protocolRaw = APIProtocolType.OPEN_AI_COMPATIBLE.rawValue,
            baseURL = "http://127.0.0.1:11434/v1",
            isEnabled = true,
            models = listOf(ModelSpec(id = "local-model"))
        )
        val restored = BackupRepository.restoredProvider(archived, now = 42L)
        assertFalse(restored.isEnabled)
        assertEquals(archived.id.uppercase(), restored.id)
        assertEquals(archived.baseURL, restored.baseURL)
        assertEquals(archived.models, BackupJson.codec.decodeFromString<List<ModelSpec>>(restored.modelsJson))
    }

    @Test
    fun selectedModelMustStillBeReadyAndUnselectedChatsCanUseTheDefault() {
        val live = ResolvedModelTarget(
            providerID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            providerName = "Home provider",
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            modelID = "local-model",
            modelDisplayName = "Current name",
            accentHex = "#FFFFFF",
            supportsVision = false,
            supportsReasoning = false
        )
        val saved = live.copy(providerID = live.providerID.lowercase(), modelDisplayName = "Old name")
        assertEquals(live, ChatRepository.resolveChatTarget(saved, listOf(live)))
        assertNull(ChatRepository.resolveChatTarget(saved.copy(modelID = "retired-model"), listOf(live)))
        assertNull(ChatRepository.resolveChatTarget(saved.copy(providerID = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"), listOf(live)))
        assertEquals(live, ChatRepository.resolveChatTarget(null, listOf(live)))
    }

    @Test
    fun portableBaseURLMatchesIosRedactionRules() {
        assertEquals("https://api.openai.com/v1", BackupRepository.portableBaseURL("https://api.openai.com/v1"))
        assertEquals("https://openrouter.ai/api/v1", BackupRepository.portableBaseURL("https://openrouter.ai/api/v1"))
        assertEquals("http://192.168.1.10:11434/v1", BackupRepository.portableBaseURL("http://192.168.1.10:11434/v1"))
        // Custom gateway paths, query strings, fragments, or userinfo must be redacted
        assertEquals("", BackupRepository.portableBaseURL("https://relay.example.com/secret-token/v1"))
        assertEquals("", BackupRepository.portableBaseURL("https://api.openai.com/v1?api_key=abc"))
        assertEquals("https://api.openai.com/v1#", BackupRepository.portableBaseURL("https://api.openai.com/v1#"))
        assertEquals("", BackupRepository.portableBaseURL("https://api.openai.com/v1#secret"))
        assertEquals("", BackupRepository.portableBaseURL("https://user:pass@api.openai.com/v1"))
    }

    @Test
    fun preservesPhase2And3NestedFieldsAndExportsWholeSecondIsoDates() {
        val iosArchiveJson = """
            {
              "formatVersion": 7,
              "exportedAt": "2026-11-21T05:30:00Z",
              "appVersion": "2.0",
              "providers": [],
              "presets": [],
              "conversations": [
                {
                  "id": "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                  "title": "Test Chat",
                  "isPinned": true,
                  "assistantEmoji": "✨",
                  "systemPrompt": "Hi",
                  "temperature": 0.7,
                  "useCustomTemperature": true,
                  "topP": 1.0,
                  "maxOutputTokens": 0,
                  "contextMessageLimit": 20,
                  "enableThinking": true,
                  "thinkingBudgetTokens": 4096,
                  "isArenaMode": false,
                  "arenaTargets": [],
                  "assistanceSettings": {
                    "usePersonalMemory": true,
                    "knowledgeVolumeIDs": ["BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"]
                  },
                  "createdAt": "2026-11-21T05:00:00Z",
                  "updatedAt": "2026-11-21T05:30:00Z",
                  "messages": [
                    {
                      "id": "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
                      "role": "assistant",
                      "content": "Hello",
                      "reasoningContent": "",
                      "attachments": [],
                      "providerName": "OpenAI",
                      "modelID": "gpt-4.1",
                      "modelDisplayName": "GPT-4.1",
                      "accentHex": "#10A37F",
                      "isSelectedInGroup": true,
                      "assistanceMetadata": { "isBookmarked": true },
                      "sortIndex": 0,
                      "createdAt": "2026-11-21T05:10:00.500Z"
                    }
                  ]
                }
              ],
              "flashcards": [{ "id": "F1", "front": "Q", "back": "A" }]
            }
        """.trimIndent()

        val decoded = BackupJson.codec.decodeFromString<BackupArchive>(iosArchiveJson)
        assertEquals(7, decoded.formatVersion)
        assertEquals(1, decoded.conversations.size)
        val conv = decoded.conversations.first()
        assertNotNull(conv.assistanceSettings)
        assertEquals("true", conv.assistanceSettings?.jsonObject?.get("usePersonalMemory")?.jsonPrimitive?.content)
        val restoredSettings = BackupRepository.restoredAssistanceSettings(conv.assistanceSettings)
        assertEquals(JsonPrimitive(false), restoredSettings?.get("usePersonalMemory"))
        assertEquals(conv.assistanceSettings?.jsonObject?.get("knowledgeVolumeIDs"), restoredSettings?.get("knowledgeVolumeIDs"))
        assertNull(BackupRepository.restoredAssistanceSettings(JsonPrimitive(true)))
        assertEquals("true", conv.messages.first().assistanceMetadata?.jsonObject?.get("isBookmarked")?.jsonPrimitive?.content)
        assertEquals(1, decoded.flashcards?.size)

        val reencoded = BackupJson.codec.encodeToString(BackupArchive.serializer(), decoded)
        // Fractional seconds from input must normalize to whole-second UTC `Z` for iOS JSONDecoder compatibility
        assertTrue(reencoded.contains("\"createdAt\":\"2026-11-21T05:10:00Z\""))
        assertTrue(reencoded.contains("\"isBookmarked\":true"))
        assertTrue(reencoded.contains("\"usePersonalMemory\":true"))
    }
}
