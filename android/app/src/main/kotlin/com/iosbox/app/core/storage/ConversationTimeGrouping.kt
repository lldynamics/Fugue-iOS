package com.iosbox.app.core.storage

import com.iosbox.app.core.model.L10n
import java.util.Calendar
import java.util.TimeZone

enum class ConversationTimeBucket {
    TODAY,
    LAST_7_DAYS,
    EARLIER;

    val title: String
        get() = when (this) {
            TODAY -> L10n.text("今天", "Today")
            LAST_7_DAYS -> L10n.text("近 7 天", "Last 7 Days")
            EARLIER -> L10n.text("更早", "Earlier")
        }
}

object ConversationTimeGrouping {
    fun bucketFor(
        epochMs: Long,
        nowMs: Long = System.currentTimeMillis(),
        timeZone: TimeZone = TimeZone.getDefault()
    ): ConversationTimeBucket {
        val calNow = Calendar.getInstance(timeZone).apply {
            timeInMillis = nowMs
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val todayStart = calNow.timeInMillis
        if (epochMs >= todayStart) {
            return ConversationTimeBucket.TODAY
        }
        calNow.add(Calendar.DAY_OF_YEAR, -7)
        val sevenDaysStart = calNow.timeInMillis
        return if (epochMs >= sevenDaysStart) {
            ConversationTimeBucket.LAST_7_DAYS
        } else {
            ConversationTimeBucket.EARLIER
        }
    }

    fun <T> groupByTime(
        items: List<T>,
        timestampOf: (T) -> Long,
        nowMs: Long = System.currentTimeMillis(),
        timeZone: TimeZone = TimeZone.getDefault()
    ): List<Pair<ConversationTimeBucket, List<T>>> {
        val today = ArrayList<T>()
        val last7 = ArrayList<T>()
        val earlier = ArrayList<T>()

        for (item in items) {
            when (bucketFor(timestampOf(item), nowMs = nowMs, timeZone = timeZone)) {
                ConversationTimeBucket.TODAY -> today.add(item)
                ConversationTimeBucket.LAST_7_DAYS -> last7.add(item)
                ConversationTimeBucket.EARLIER -> earlier.add(item)
            }
        }

        val out = ArrayList<Pair<ConversationTimeBucket, List<T>>>()
        if (today.isNotEmpty()) out.add(ConversationTimeBucket.TODAY to today)
        if (last7.isNotEmpty()) out.add(ConversationTimeBucket.LAST_7_DAYS to last7)
        if (earlier.isNotEmpty()) out.add(ConversationTimeBucket.EARLIER to earlier)
        return out
    }
}
