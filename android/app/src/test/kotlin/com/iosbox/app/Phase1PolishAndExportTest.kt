package com.iosbox.app

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.RequestKind
import com.iosbox.app.core.model.RequestStatus
import com.iosbox.app.core.storage.ConversationTimeBucket
import com.iosbox.app.core.storage.ConversationTimeGrouping
import com.iosbox.app.core.storage.RequestRecordItem
import com.iosbox.app.core.storage.UsageTrendCalculator
import com.iosbox.app.core.storage.UsageTrendGranularity
import com.iosbox.app.core.system.ExportBlock
import com.iosbox.app.core.system.MessageExportLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

class Phase1PolishAndExportTest {

    @Test
    fun messageExportLayoutParsesHeadingsCodeQuotesBulletsAndParagraphs() {
        val md = """
            # Weekly Sync

            > Remember **Friday** deadline.

            - Ship PDF export
            2. Add usage trend bar chart

            ```kotlin
            fun ok() = true
            ```

            ---

            All checks complete.
        """.trimIndent()

        val blocks = MessageExportLayout.parseBlocks(md)
        assertTrue(blocks[0] is ExportBlock.Heading)
        assertEquals("Weekly Sync", (blocks[0] as ExportBlock.Heading).text)

        assertTrue(blocks[1] is ExportBlock.Quote)
        assertEquals("Remember Friday deadline.", (blocks[1] as ExportBlock.Quote).text)

        assertTrue(blocks[2] is ExportBlock.Bullet)
        assertEquals("•", (blocks[2] as ExportBlock.Bullet).marker)
        assertEquals("Ship PDF export", (blocks[2] as ExportBlock.Bullet).text)

        assertTrue(blocks[3] is ExportBlock.Bullet)
        assertEquals("2.", (blocks[3] as ExportBlock.Bullet).marker)

        assertTrue(blocks[4] is ExportBlock.CodeBlock)
        assertEquals("kotlin", (blocks[4] as ExportBlock.CodeBlock).language)
        assertEquals("fun ok() = true", (blocks[4] as ExportBlock.CodeBlock).code)

        assertEquals(ExportBlock.Divider, blocks[5])
        assertTrue(blocks[6] is ExportBlock.Paragraph)
        assertEquals("All checks complete.", (blocks[6] as ExportBlock.Paragraph).text)
    }

    @Test
    fun conversationTimeGroupingBucketsTodayLast7DaysAndEarlier() {
        val tz = TimeZone.getTimeZone("UTC")
        fun utcMs(year: Int, month: Int, day: Int, hour: Int): Long = Calendar.getInstance(tz).apply {
            set(year, month - 1, day, hour, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        val now = utcMs(2026, 11, 23, 14)
        val items = listOf(
            "t1" to utcMs(2026, 11, 23, 9),
            "r1" to utcMs(2026, 11, 21, 18),
            "r2" to utcMs(2026, 11, 18, 12),
            "e1" to utcMs(2026, 11, 10, 10)
        )

        val grouped = ConversationTimeGrouping.groupByTime(
            items = items,
            timestampOf = { it.second },
            nowMs = now,
            timeZone = tz
        )
        assertEquals(
            listOf(ConversationTimeBucket.TODAY, ConversationTimeBucket.LAST_7_DAYS, ConversationTimeBucket.EARLIER),
            grouped.map { it.first }
        )
        assertEquals(listOf("t1"), grouped[0].second.map { it.first })
        assertEquals(listOf("r1", "r2"), grouped[1].second.map { it.first })
        assertEquals(listOf("e1"), grouped[2].second.map { it.first })
    }

    @Test
    fun usageTrendCalculatorAggregatesHourDayAndMonthBuckets() {
        val tz = TimeZone.getTimeZone("UTC")
        fun utcMs(year: Int, month: Int, day: Int, hour: Int, min: Int): Long = Calendar.getInstance(tz).apply {
            set(year, month - 1, day, hour, min, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis

        fun sampleRecord(id: String, epochMs: Long, prompt: Int, completion: Int) = RequestRecordItem(
            id = id,
            operationID = "op-$id",
            attempt = 1,
            conversationID = "conv-1",
            messageID = "msg-$id",
            providerID = "prov-1",
            providerName = "OpenAI",
            modelID = "gpt-4o",
            modelDisplayName = "GPT-4o",
            protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
            kind = RequestKind.ANSWER,
            status = RequestStatus.SUCCEEDED,
            startedAtEpochMs = epochMs,
            endedAtEpochMs = epochMs + 1000,
            firstReasoningMs = null,
            firstContentMs = 200,
            lastOutputMs = 900,
            durationMs = 1000,
            outputChunkCount = 5,
            isStreamed = true,
            promptTokens = prompt,
            completionTokens = completion,
            cachedTokens = null,
            cacheWriteTokens = null,
            httpStatus = 200,
            inputPricePerMillion = null,
            outputPricePerMillion = null,
            cacheReadPricePerMillion = null,
            cacheWritePricePerMillion = null,
            currency = null
        )

        val records = listOf(
            sampleRecord("1", utcMs(2026, 11, 20, 9, 10), 100, 50),
            sampleRecord("2", utcMs(2026, 11, 20, 9, 45), 200, 100),
            sampleRecord("3", utcMs(2026, 11, 21, 14, 20), 300, 150),
            sampleRecord("4", utcMs(2026, 10, 5, 11, 0), 400, 100)
        )

        val hourly = UsageTrendCalculator.buildBuckets(records.take(3), UsageTrendGranularity.HOUR, tz)
        assertEquals(2, hourly.size)
        assertEquals("09:00", hourly[0].label)
        assertEquals(2, hourly[0].requestCount)
        assertEquals(450L, hourly[0].totalTokens)
        assertEquals("14:00", hourly[1].label)
        assertEquals(450L, hourly[1].totalTokens)

        val daily = UsageTrendCalculator.buildBuckets(records.take(3), UsageTrendGranularity.DAY, tz)
        assertEquals(listOf("11-20", "11-21"), daily.map { it.label })
        assertEquals(listOf(450L, 450L), daily.map { it.totalTokens })

        val monthly = UsageTrendCalculator.buildBuckets(records, UsageTrendGranularity.MONTH, tz)
        assertEquals(listOf("26/10", "26/11"), monthly.map { it.label })
        assertEquals(listOf(500L, 900L), monthly.map { it.totalTokens })
    }
}
