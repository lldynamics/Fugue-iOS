package com.iosbox.app.core.model

import com.iosbox.app.core.backup.Iso8601EpochMillisSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID

@Serializable
enum class ProposedScheduleKind(val rawValue: String) {
    @SerialName("reminder")
    REMINDER("reminder"),

    @SerialName("calendar")
    CALENDAR_EVENT("calendar");

    val badgeTitle: String
        get() = when (this) {
            REMINDER -> L10n.text("提醒事项", "Reminder")
            CALENDAR_EVENT -> L10n.text("日历日程", "Calendar Event")
        }

    val confirmButtonTitle: String
        get() = when (this) {
            REMINDER -> L10n.text("加入系统日程", "Add to Calendar")
            CALENDAR_EVENT -> L10n.text("加入系统日历", "Add to Calendar")
        }
}

@Serializable
data class ProposedScheduleItem(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val kind: ProposedScheduleKind = ProposedScheduleKind.REMINDER,
    val title: String,
    val notes: String = "",
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val scheduledAt: Long? = null,
    val durationMinutes: Int = 60,
    val isDateOnly: Boolean = false
) {
    data class CalendarWindow(
        val beginTimeMs: Long,
        val endTimeMs: Long,
        val allDay: Boolean
    )

    companion object {
        private val TIMED_FORMATTERS = listOf(
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss", Locale.US),
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm", Locale.US),
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US),
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm", Locale.US)
        )
        private val DATE_ONLY_FORMATTER = DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.US)
        private val DISPLAY_TIME_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm", Locale.US)
        private val DISPLAY_DATE_FMT = DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.US)

        fun parseFlexibleDateWithPrecision(
            raw: String?,
            zoneId: ZoneId = ZoneId.systemDefault()
        ): Pair<Long?, Boolean> {
            val trimmed = raw?.trim().orEmpty()
            if (trimmed.isEmpty()) return null to false

            runCatching { return Instant.parse(trimmed).toEpochMilli() to false }
            runCatching { return OffsetDateTime.parse(trimmed).toInstant().toEpochMilli() to false }

            for (fmt in TIMED_FORMATTERS) {
                runCatching {
                    val ldt = LocalDateTime.parse(trimmed, fmt)
                    return ldt.atZone(zoneId).toInstant().toEpochMilli() to false
                }
            }

            runCatching {
                val date = LocalDate.parse(trimmed, DATE_ONLY_FORMATTER)
                return date.atStartOfDay(zoneId).toInstant().toEpochMilli() to true
            }

            return null to false
        }

        fun computeCalendarWindow(
            item: ProposedScheduleItem,
            nowMs: Long = System.currentTimeMillis()
        ): CalendarWindow {
            if (item.isDateOnly && item.scheduledAt != null) {
                return CalendarWindow(
                    beginTimeMs = item.scheduledAt,
                    endTimeMs = item.scheduledAt + 86_400_000L,
                    allDay = true
                )
            }
            val start = item.scheduledAt ?: (nowMs + 3_600_000L)
            val clampedMinutes = item.durationMinutes.coerceIn(15, 720)
            return CalendarWindow(
                beginTimeMs = start,
                endTimeMs = start + clampedMinutes * 60_000L,
                allDay = false
            )
        }

        fun formatDisplaySchedule(
            item: ProposedScheduleItem,
            zoneId: ZoneId = ZoneId.systemDefault()
        ): String? {
            val epochMs = item.scheduledAt ?: return null
            val zoned = Instant.ofEpochMilli(epochMs).atZone(zoneId)
            return if (item.isDateOnly) {
                DISPLAY_DATE_FMT.format(zoned) + " " + L10n.text("全天", "All day")
            } else {
                DISPLAY_TIME_FMT.format(zoned)
            }
        }
    }
}
