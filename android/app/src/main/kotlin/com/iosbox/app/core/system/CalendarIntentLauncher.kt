package com.iosbox.app.core.system

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.provider.CalendarContract
import com.iosbox.app.core.model.ProposedScheduleItem

object CalendarIntentLauncher {
    fun buildInsertEventIntent(
        item: ProposedScheduleItem,
        nowMs: Long = System.currentTimeMillis()
    ): Intent {
        val window = ProposedScheduleItem.computeCalendarWindow(item, nowMs)
        return Intent(Intent.ACTION_INSERT).apply {
            data = CalendarContract.Events.CONTENT_URI
            putExtra(CalendarContract.Events.TITLE, item.title)
            if (item.notes.isNotBlank()) {
                putExtra(CalendarContract.Events.DESCRIPTION, item.notes)
            }
            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, window.beginTimeMs)
            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, window.endTimeMs)
            putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, window.allDay)
        }
    }

    fun launchCalendarInsert(context: Context, item: ProposedScheduleItem): Boolean {
        val intent = buildInsertEventIntent(item)
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }
}
