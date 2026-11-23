package com.iosbox.app.core.storage

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

enum class UsageTrendGranularity {
    HOUR,
    DAY,
    MONTH
}

data class UsageTrendBucket(
    val bucketStartMs: Long,
    val label: String,
    val requestCount: Int,
    val totalTokens: Long
)

object UsageTrendCalculator {
    fun buildBuckets(
        records: List<RequestRecordItem>,
        granularity: UsageTrendGranularity,
        timeZone: TimeZone = TimeZone.getDefault()
    ): List<UsageTrendBucket> {
        if (records.isEmpty()) return emptyList()
        val pattern = when (granularity) {
            UsageTrendGranularity.HOUR -> "HH:00"
            UsageTrendGranularity.DAY -> "MM-dd"
            UsageTrendGranularity.MONTH -> "yy/MM"
        }
        val formatter = SimpleDateFormat(pattern, Locale.US).apply {
            this.timeZone = timeZone
        }
        val cal = Calendar.getInstance(timeZone)

        data class Acc(var count: Int = 0, var tokens: Long = 0L)

        val buckets = HashMap<Long, Acc>()
        for (record in records) {
            cal.timeInMillis = record.startedAtEpochMs
            when (granularity) {
                UsageTrendGranularity.HOUR -> {
                    cal.set(Calendar.MINUTE, 0)
                    cal.set(Calendar.SECOND, 0)
                    cal.set(Calendar.MILLISECOND, 0)
                }
                UsageTrendGranularity.DAY -> {
                    cal.set(Calendar.HOUR_OF_DAY, 0)
                    cal.set(Calendar.MINUTE, 0)
                    cal.set(Calendar.SECOND, 0)
                    cal.set(Calendar.MILLISECOND, 0)
                }
                UsageTrendGranularity.MONTH -> {
                    cal.set(Calendar.DAY_OF_MONTH, 1)
                    cal.set(Calendar.HOUR_OF_DAY, 0)
                    cal.set(Calendar.MINUTE, 0)
                    cal.set(Calendar.SECOND, 0)
                    cal.set(Calendar.MILLISECOND, 0)
                }
            }
            val start = cal.timeInMillis
            val acc = buckets.getOrPut(start) { Acc() }
            acc.count += 1
            val prompt = (record.promptTokens ?: 0).coerceAtLeast(0).toLong()
            val completion = (record.completionTokens ?: 0).coerceAtLeast(0).toLong()
            acc.tokens += prompt + completion
        }

        return buckets.entries
            .sortedBy { it.key }
            .map { (start, acc) ->
                UsageTrendBucket(
                    bucketStartMs = start,
                    label = formatter.format(Date(start)),
                    requestCount = acc.count,
                    totalTokens = acc.tokens
                )
            }
    }
}
