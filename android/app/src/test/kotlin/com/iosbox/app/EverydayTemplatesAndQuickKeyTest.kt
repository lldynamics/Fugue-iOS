package com.iosbox.app

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.DefaultPresets
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.network.ClipboardProviderParser
import com.iosbox.app.core.storage.SlashPromptCommand
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class EverydayTemplatesAndQuickKeyTest {

    @Test
    fun clipboardParserRecognizesMajorProvidersKeysAndCustomRelays() {
        val anthropic = ClipboardProviderParser.parse("Here is my key: sk-ant-api03-abcdefghijklmnop12345")
        assertNotNull(anthropic)
        assertEquals(APIProtocolType.ANTHROPIC, anthropic?.protocolType)
        assertEquals("https://api.anthropic.com/v1", anthropic?.baseURL)
        assertEquals("sk-ant-api03-abcdefghijklmnop12345", anthropic?.apiKey)

        val gemini = ClipboardProviderParser.parse("GEMINI_API_KEY=AIzaSyD1234567890abcdefghijkLMN")
        assertNotNull(gemini)
        assertEquals(APIProtocolType.GEMINI, gemini?.protocolType)
        assertTrue(gemini?.baseURL?.contains("generativelanguage.googleapis.com") == true)

        val openRouter = ClipboardProviderParser.parse("sk-or-v1-0123456789abcdef0123456789abcdef")
        assertNotNull(openRouter)
        assertEquals("OpenRouter", openRouter?.providerName)
        assertEquals("https://openrouter.ai/api/v1", openRouter?.baseURL)

        val deepseek = ClipboardProviderParser.parse(
            "url: https://api.deepseek.com/v1\nkey: sk-1234567890abcdef123456"
        )
        assertNotNull(deepseek)
        assertEquals("deepseek", deepseek?.templateID)
        assertTrue(deepseek?.providerName?.contains("DeepSeek") == true)
        assertEquals("https://api.deepseek.com/v1", deepseek?.baseURL)
        assertEquals("sk-1234567890abcdef123456", deepseek?.apiKey)
        assertFalse(deepseek?.isGenericOpenAIKey ?: true)

        val relay = ClipboardProviderParser.parse(
            "Base URL: https://relay.example.org/v1\nAuthorization: Bearer tok-abcdef1234567890"
        )
        assertNotNull(relay)
        assertEquals(APIProtocolType.OPEN_AI_COMPATIBLE, relay?.protocolType)
        assertEquals("https://relay.example.org/v1", relay?.baseURL)
        assertEquals("tok-abcdef1234567890", relay?.apiKey)
    }

    @Test
    fun clipboardParserAllowsLocalHttpAndRejectsPublicHttpOrNoise() {
        val local = ClipboardProviderParser.parse("http://127.0.0.1:11434/v1")
        assertNotNull(local)
        assertEquals("http://127.0.0.1:11434/v1", local?.baseURL)
        assertEquals("", local?.apiKey)

        assertNull(ClipboardProviderParser.parse("http://api.relay.example.org/v1 sk-1234567890abcdef12"))
        assertNull(ClipboardProviderParser.parse("just some plain text without key or endpoint"))
        assertNull(ClipboardProviderParser.parse("   "))
    }

    @Test
    fun pickBestStarterModelSkipsAudioImageAndEmbeddingModels() {
        val raw = listOf(
            ModelSpec.create("whisper-1", "whisper-1"),
            ModelSpec.create("tts-1-hd", "tts-1-hd"),
            ModelSpec.create("dall-e-3", "dall-e-3"),
            ModelSpec.create("text-embedding-3-small", "text-embedding-3-small"),
            ModelSpec.create("gpt-4o-mini", "gpt-4o-mini")
        )
        val picked = ClipboardProviderParser.pickBestStarterModel(raw, APIProtocolType.OPEN_AI_COMPATIBLE)
        assertEquals("gpt-4o-mini", picked?.id)

        val customOnly = listOf(
            ModelSpec.create("whisper-1", "whisper-1"),
            ModelSpec.create("my-custom-chat-v2", "my-custom-chat-v2")
        )
        val fallbackPicked = ClipboardProviderParser.pickBestStarterModel(
            customOnly,
            APIProtocolType.OPEN_AI_COMPATIBLE
        )
        assertEquals("my-custom-chat-v2", fallbackPicked?.id)
    }

    @Test
    fun defaultPresetsAndEverydaySlashCommandsAreCompleteAndSearchable() {
        val all = DefaultPresets.items
        val daily = DefaultPresets.dailyLifeItems
        assertEquals(5, daily.size)
        assertEquals(10, all.size)
        assertEquals(10, all.map { it.id }.distinct().size)
        assertEquals((0..9).toList(), all.map { it.sortOrder }.sorted())

        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.ENGLISH)
            val builtInsEn = SlashPromptCommand.builtIns
            assertEquals(16, builtInsEn.size)
            assertTrue(
                builtInsEn.map { it.command }.containsAll(
                    listOf("/meeting", "/reply", "/weekly", "/solve", "/contract", "/plan")
                )
            )
            val calendarSubMatches = SlashPromptCommand.matching("/calendar")
            assertEquals(listOf("/meeting"), calendarSubMatches.map { it.command })

            Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
            val zhTitleMatches = SlashPromptCommand.matching("/会议")
            assertTrue(zhTitleMatches.any { it.command == "/meeting" })
            val zhSubMatches = SlashPromptCommand.matching("/微信")
            assertTrue(zhSubMatches.any { it.command == "/reply" })
        } finally {
            Locale.setDefault(previous)
        }
    }
}
