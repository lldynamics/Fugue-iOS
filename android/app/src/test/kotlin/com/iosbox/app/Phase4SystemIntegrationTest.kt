package com.iosbox.app

import com.iosbox.app.core.backup.BackupJson
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.ProposedScheduleItem
import com.iosbox.app.core.model.ProposedScheduleKind
import com.iosbox.app.core.network.ScheduleExtractorService
import com.iosbox.app.core.system.ExternalEntryParser
import com.iosbox.app.core.system.GenerationNotificationState
import com.iosbox.app.core.system.GenerationProgressFormatter
import com.iosbox.app.core.system.IncomingEntryRequest
import com.iosbox.app.core.system.ShareReadingAction
import com.iosbox.app.core.system.SpeechTextCleaner
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Locale

class Phase4SystemIntegrationTest {

    @Test
    fun externalEntryRouterParsesShareProcessTextUrlsAndDeepLinks() {
        // Public HTTPS URL extraction strips trailing punctuation and rejects private/multiple/non-HTTP URLs
        assertEquals(
            "https://example.com/articles/fugue-android",
            ExternalEntryParser.extractSinglePublicHttpsUrl("  Check this: https://example.com/articles/fugue-android). ")
        )
        assertNull(ExternalEntryParser.extractSinglePublicHttpsUrl("https://127.0.0.1/admin"))
        assertNull(ExternalEntryParser.extractSinglePublicHttpsUrl("http://192.168.1.5:8080/api"))
        assertNull(ExternalEntryParser.extractSinglePublicHttpsUrl("http://localhost:3000"))
        assertNull(ExternalEntryParser.extractSinglePublicHttpsUrl("ftp://example.com/file.txt"))
        assertNull(ExternalEntryParser.extractSinglePublicHttpsUrl("https://a.example.com https://b.example.com"))
        assertNull(ExternalEntryParser.extractSinglePublicHttpsUrl("plain highlighted note without links"))

        // Deep links
        assertEquals(
            IncomingEntryRequest.OpenConversation("conv-42"),
            ExternalEntryParser.parseDeepLink("fugue://chat/conv-42")
        )
        assertEquals(
            IncomingEntryRequest.NewChat,
            ExternalEntryParser.parseDeepLink("fugue://new-chat")
        )
        assertEquals(
            IncomingEntryRequest.NewArena,
            ExternalEntryParser.parseDeepLink("fugue://new-arena")
        )
        assertEquals(
            IncomingEntryRequest.OpenFlashcards,
            ExternalEntryParser.parseDeepLink("fugue://flashcards")
        )
        assertNull(ExternalEntryParser.parseDeepLink("fugue://chat"))
        assertNull(ExternalEntryParser.parseDeepLink("https://example.com/chat/conv-42"))
        assertNull(ExternalEntryParser.parseDeepLink("fugue://unknown-route"))
        assertNull(ExternalEntryParser.parseDeepLink("   "))

        // ShareReadingAction prompt formatting
        val summaryPrompt = ShareReadingAction.DEEP_SUMMARY.buildPrompt(
            body = "Paragraph body content",
            pageTitle = "Design Doc",
            sourceUrl = "https://example.com/doc"
        )
        assertTrue(summaryPrompt.contains("Title: Design Doc"))
        assertTrue(summaryPrompt.contains("Source: https://example.com/doc"))
        assertTrue(summaryPrompt.endsWith("Paragraph body content"))

        val directPrompt = ShareReadingAction.DIRECT_CHAT.buildPrompt(
            body = "Selected sentence",
            pageTitle = null,
            sourceUrl = null
        )
        assertEquals("Selected sentence", directPrompt)
    }

    @Test
    fun generationProgressFormatterRespectsBlindModeAndPrivacy() {
        val longTitle = "A".repeat(50)
        val normal = GenerationNotificationState(
            conversationID = "conv-1",
            chatTitle = longTitle,
            modeBadge = "Arena",
            speakerOrModel = "Claude 3.7",
            phaseText = "第 2 轮 · 正文生成",
            isBlind = false
        )
        val normalTitle = GenerationProgressFormatter.formatTitle(normal)
        assertTrue(normalTitle.startsWith("Arena · "))
        assertEquals("Arena · " + "A".repeat(36), normalTitle)
        assertEquals("Claude 3.7 · 第 2 轮 · 正文生成", GenerationProgressFormatter.formatBody(normal))

        val blankTitleState = GenerationNotificationState(
            conversationID = "conv-2",
            chatTitle = "   ",
            modeBadge = "",
            speakerOrModel = "",
            phaseText = "",
            isBlind = false
        )
        val blankTitle = GenerationProgressFormatter.formatTitle(blankTitleState)
        assertTrue(blankTitle == "新对话" || blankTitle == "New Chat")
        val blankBody = GenerationProgressFormatter.formatBody(blankTitleState)
        assertTrue(blankBody == "正在流式接收回复…" || blankBody == "Streaming response…")

        val blindState = GenerationNotificationState(
            conversationID = "conv-blind",
            chatTitle = "Confidential Strategy",
            modeBadge = "Arena",
            speakerOrModel = "GPT-Hidden-Model",
            phaseText = "Phase 1",
            isBlind = true
        )
        val blindTitle = GenerationProgressFormatter.formatTitle(blindState)
        val blindBody = GenerationProgressFormatter.formatBody(blindState)
        assertFalse(blindTitle.contains("Confidential Strategy"))
        assertFalse(blindBody.contains("GPT-Hidden-Model"))
        assertTrue(blindTitle == "夜奔 · 正在生成" || blindTitle == "Fugue · Generating")
        assertTrue(blindBody == "双盲对比生成中…" || blindBody == "Blind comparison in progress…")
    }

    @Test
    fun speechTextCleanerStripsMarkdownCodeLatexAndDetectsLocale() {
        val markdown = """
            # Weekly Review
            > Quote line with **bold** and *italic* and `inline()` plus ~~strike~~.
            See [Reference Docs](https://example.com/docs) or https://raw.example.com/ignore
            Formula: $$ E = mc^2 $$ and inline \(x + y = z\)
            ```kotlin
            fun hiddenCode() = 42
            ```
            Done!
        """.trimIndent()

        val cleaned = SpeechTextCleaner.cleanForSpeech(markdown)
        assertFalse(cleaned.contains("fun hiddenCode()"))
        assertFalse(cleaned.contains("https://"))
        assertFalse(cleaned.contains("**"))
        assertFalse(cleaned.contains("$$"))
        assertFalse(cleaned.contains("\\("))
        assertFalse(cleaned.contains("`"))
        assertTrue(cleaned.contains("Weekly Review"))
        assertTrue(cleaned.contains("Reference Docs"))
        assertTrue(cleaned.contains("代码片段。") || cleaned.contains("Code block."))

        assertEquals(
            Locale.SIMPLIFIED_CHINESE,
            SpeechTextCleaner.detectPreferredLocale("这是一段中文技术总结，包含 English API 关键词。")
        )
        assertEquals(
            Locale.US,
            SpeechTextCleaner.detectPreferredLocale("This is purely an English response describing Fugue features.")
        )
    }

    @Test
    fun scheduleExtractorParsesFlexibleDatesThinkTagsAndMalformedJson() {
        val shanghai = ZoneId.of("Asia/Shanghai")

        val (utcMs, utcDateOnly) = ProposedScheduleItem.parseFlexibleDateWithPrecision("2026-06-15T09:30:00Z", shanghai)
        assertEquals(Instant.parse("2026-06-15T09:30:00Z").toEpochMilli(), utcMs)
        assertFalse(utcDateOnly)

        val (localMs, localDateOnly) = ProposedScheduleItem.parseFlexibleDateWithPrecision("2026-06-15 14:30", shanghai)
        assertEquals(
            LocalDateTime.of(2026, 6, 15, 14, 30).atZone(shanghai).toInstant().toEpochMilli(),
            localMs
        )
        assertFalse(localDateOnly)

        val (dateMs, dateOnlyFlag) = ProposedScheduleItem.parseFlexibleDateWithPrecision("2026-06-15", shanghai)
        assertEquals(
            LocalDate.of(2026, 6, 15).atStartOfDay(shanghai).toInstant().toEpochMilli(),
            dateMs
        )
        assertTrue(dateOnlyFlag)

        val (invalidMs, invalidFlag) = ProposedScheduleItem.parseFlexibleDateWithPrecision("next Friday afternoon", shanghai)
        assertNull(invalidMs)
        assertFalse(invalidFlag)

        val rawResponse = """
            <think>Let me analyze the action items first.</think>
            ```json
            {
              "items": [
                {
                  "kind": "calendar",
                  "title": "Design Review Meeting",
                  "notes": "Discuss Android Phase 4 release",
                  "scheduledAt": "2026-06-15 14:30",
                  "durationMinutes": 900
                },
                {
                  "kind": "reminder",
                  "title": "Submit App Store Checklist",
                  "notes": "Verify manifest and ProGuard",
                  "scheduledAt": "2026-06-16",
                  "durationMinutes": 5
                },
                {
                  "kind": "reminder",
                  "title": "   ",
                  "notes": "Should be ignored because title is blank"
                }
              ]
            }
            ```
        """.trimIndent()

        val parsed = ScheduleExtractorService.parseScheduleItemsJSON(rawResponse, shanghai)
        assertEquals(2, parsed.size)

        assertEquals(ProposedScheduleKind.CALENDAR_EVENT, parsed[0].kind)
        assertEquals("Design Review Meeting", parsed[0].title)
        assertEquals(localMs, parsed[0].scheduledAt)
        assertFalse(parsed[0].isDateOnly)
        assertEquals(720, parsed[0].durationMinutes)

        assertEquals(ProposedScheduleKind.REMINDER, parsed[1].kind)
        assertEquals("Submit App Store Checklist", parsed[1].title)
        assertTrue(parsed[1].isDateOnly)
        assertEquals(15, parsed[1].durationMinutes)

        assertTrue(ScheduleExtractorService.parseScheduleItemsJSON("not valid json at all").isEmpty())
        assertTrue(ScheduleExtractorService.parseScheduleItemsJSON("""{"items":[]}""").isEmpty())
    }

    @Test
    fun proposedScheduleItemsRoundTripThroughAssistanceMetadataJson() {
        val scheduledEpoch = Instant.parse("2026-07-01T08:00:00Z").toEpochMilli()
        val schedules = listOf(
            ProposedScheduleItem(
                id = "SCHED-1",
                kind = ProposedScheduleKind.CALENDAR_EVENT,
                title = "Architecture Sync",
                notes = "Review API contracts",
                scheduledAt = scheduledEpoch,
                durationMinutes = 45,
                isDateOnly = false
            ),
            ProposedScheduleItem(
                id = "SCHED-2",
                kind = ProposedScheduleKind.REMINDER,
                title = "Renew domain certificate",
                notes = "",
                scheduledAt = null,
                durationMinutes = 30,
                isDateOnly = false
            )
        )
        val meta = MessageAssistanceMetadata(proposedSchedules = schedules)
        val existingObj = BackupJson.codec.parseToJsonElement(
            """{"iosCustomFlag":"keep-me","isBookmarked":true}"""
        ) as JsonObject
        val mergedObj = meta.mergeInto(existing = existingObj, json = BackupJson.codec)
        val mergedJson = BackupJson.codec.encodeToString(JsonObject.serializer(), mergedObj)

        assertEquals("keep-me", mergedObj["iosCustomFlag"]?.jsonPrimitive?.content)

        val decoded = BackupJson.codec.decodeFromString<MessageAssistanceMetadata>(mergedJson)
        assertEquals(2, decoded.proposedSchedules.size)
        assertEquals("SCHED-1", decoded.proposedSchedules[0].id)
        assertEquals(ProposedScheduleKind.CALENDAR_EVENT, decoded.proposedSchedules[0].kind)
        assertEquals("Architecture Sync", decoded.proposedSchedules[0].title)
        assertEquals(scheduledEpoch, decoded.proposedSchedules[0].scheduledAt)
        assertEquals(45, decoded.proposedSchedules[0].durationMinutes)
        assertEquals("SCHED-2", decoded.proposedSchedules[1].id)
        assertEquals(ProposedScheduleKind.REMINDER, decoded.proposedSchedules[1].kind)
        assertNull(decoded.proposedSchedules[1].scheduledAt)
    }

    @Test
    fun calendarWindowComputesAllDayTimedAndDefaultFallbackCorrectly() {
        val dayStartMs = 1_780_000_000_000L
        val allDayItem = ProposedScheduleItem(
            kind = ProposedScheduleKind.CALENDAR_EVENT,
            title = "Conference Day",
            scheduledAt = dayStartMs,
            durationMinutes = 60,
            isDateOnly = true
        )
        val allDayWindow = ProposedScheduleItem.computeCalendarWindow(allDayItem, nowMs = 5_000L)
        assertTrue(allDayWindow.allDay)
        assertEquals(dayStartMs, allDayWindow.beginTimeMs)
        assertEquals(dayStartMs + 86_400_000L, allDayWindow.endTimeMs)

        val timedItem = ProposedScheduleItem(
            kind = ProposedScheduleKind.CALENDAR_EVENT,
            title = "Quick Standup",
            scheduledAt = dayStartMs,
            durationMinutes = 5, // clamped up to 15 min
            isDateOnly = false
        )
        val timedWindow = ProposedScheduleItem.computeCalendarWindow(timedItem, nowMs = 5_000L)
        assertFalse(timedWindow.allDay)
        assertEquals(dayStartMs, timedWindow.beginTimeMs)
        assertEquals(dayStartMs + 15 * 60_000L, timedWindow.endTimeMs)

        val fallbackNow = 10_000_000L
        val unscheduledItem = ProposedScheduleItem(
            kind = ProposedScheduleKind.REMINDER,
            title = "Follow up on docs",
            scheduledAt = null,
            durationMinutes = 900, // clamped down to 720 min
            isDateOnly = false
        )
        val fallbackWindow = ProposedScheduleItem.computeCalendarWindow(unscheduledItem, nowMs = fallbackNow)
        assertFalse(fallbackWindow.allDay)
        assertEquals(fallbackNow + 3_600_000L, fallbackWindow.beginTimeMs)
        assertEquals(fallbackWindow.beginTimeMs + 720 * 60_000L, fallbackWindow.endTimeMs)
    }
}
