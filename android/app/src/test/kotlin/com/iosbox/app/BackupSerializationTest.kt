package com.iosbox.app.core.backup

import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackupSerializationTest {
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
        assertEquals("true", conv.messages.first().assistanceMetadata?.jsonObject?.get("isBookmarked")?.jsonPrimitive?.content)
        assertEquals(1, decoded.flashcards?.size)

        val reencoded = BackupJson.codec.encodeToString(BackupArchive.serializer(), decoded)
        // Fractional seconds from input must normalize to whole-second UTC `Z` for iOS JSONDecoder compatibility
        assertTrue(reencoded.contains("\"createdAt\":\"2026-11-21T05:10:00Z\""))
        assertTrue(reencoded.contains("\"isBookmarked\":true"))
        assertTrue(reencoded.contains("\"usePersonalMemory\":true"))
    }
}
