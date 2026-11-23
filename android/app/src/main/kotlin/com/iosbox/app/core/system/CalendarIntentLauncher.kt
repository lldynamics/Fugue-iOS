package com.iosbox.app.core.system

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.CalendarContract
import com.iosbox.app.core.model.ProposedScheduleItem

object CalendarIntentLauncher {
    data class Destination(val component: ComponentName, val name: String)

    fun availableEditors(context: Context): List<Destination> {
        val manager = context.packageManager
        val probe = Intent(Intent.ACTION_INSERT, CalendarContract.Events.CONTENT_URI)
        return manager.queryIntentActivities(probe, PackageManager.MATCH_DEFAULT_ONLY).map { result ->
            val info = result.activityInfo
            Destination(ComponentName(info.packageName, info.name), result.loadLabel(manager).toString())
        }.distinctBy { it.component }.sortedBy { it.name }
    }

    private fun buildInsertEventIntent(
        item: ProposedScheduleItem,
        destination: Destination,
        nowMs: Long = System.currentTimeMillis()
    ): Intent {
        val window = ProposedScheduleItem.computeCalendarWindow(item, nowMs)
        return Intent(Intent.ACTION_INSERT).apply {
            data = CalendarContract.Events.CONTENT_URI
            component = destination.component
            putExtra(CalendarContract.Events.TITLE, item.title)
            if (item.notes.isNotBlank()) {
                putExtra(CalendarContract.Events.DESCRIPTION, item.notes)
            }
            putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, window.beginTimeMs)
            putExtra(CalendarContract.EXTRA_EVENT_END_TIME, window.endTimeMs)
            putExtra(CalendarContract.EXTRA_EVENT_ALL_DAY, window.allDay)
        }
    }

    fun launchCalendarInsert(context: Context, item: ProposedScheduleItem, destination: Destination): Boolean {
        if (availableEditors(context).none { it.component == destination.component }) return false
        val intent = buildInsertEventIntent(item, destination)
        if (context !is Activity) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            context.startActivity(intent)
            true
        }.getOrDefault(false)
    }
}
