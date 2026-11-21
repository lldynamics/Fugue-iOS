package com.iosbox.app.core.system

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.iosbox.app.MainActivity
import com.iosbox.app.R
import com.iosbox.app.core.model.L10n
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

data class GenerationNotificationState(
    val conversationID: String,
    val chatTitle: String,
    val modeBadge: String,
    val speakerOrModel: String,
    val phaseText: String,
    val isBlind: Boolean = false
)

object GenerationProgressFormatter {
    fun formatTitle(state: GenerationNotificationState): String {
        if (state.isBlind) {
            return L10n.text("夜奔 · 正在生成", "Fugue · Generating")
        }
        val cleanTitle = state.chatTitle.trim().take(36).ifEmpty {
            L10n.text("新对话", "New Chat")
        }
        val prefix = state.modeBadge.trim()
        return if (prefix.isEmpty()) cleanTitle else "$prefix · $cleanTitle"
    }

    fun formatBody(state: GenerationNotificationState): String {
        if (state.isBlind) {
            return L10n.text("双盲对比生成中…", "Blind comparison in progress…")
        }
        return listOf(state.speakerOrModel.trim(), state.phaseText.trim())
            .filter { it.isNotEmpty() }
            .joinToString(" · ")
            .ifEmpty { L10n.text("正在流式接收回复…", "Streaming response…") }
    }
}

object GenerationServiceBridge {
    private val _stopRequests = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val stopRequests: SharedFlow<String> = _stopRequests.asSharedFlow()

    fun requestStop(conversationID: String) {
        if (conversationID.isNotBlank()) {
            _stopRequests.tryEmit(conversationID)
        }
    }

    fun start(context: Context, state: GenerationNotificationState) {
        val intent = Intent(context, GenerationForegroundService::class.java).apply {
            action = GenerationForegroundService.ACTION_START_OR_UPDATE
            putExtra(ExternalEntryRouter.EXTRA_CONVERSATION_ID, state.conversationID)
            putExtra(GenerationForegroundService.EXTRA_CHAT_TITLE, state.chatTitle)
            putExtra(GenerationForegroundService.EXTRA_MODE_BADGE, state.modeBadge)
            putExtra(GenerationForegroundService.EXTRA_SPEAKER_OR_MODEL, state.speakerOrModel)
            putExtra(GenerationForegroundService.EXTRA_PHASE_TEXT, state.phaseText)
            putExtra(GenerationForegroundService.EXTRA_IS_BLIND, state.isBlind)
        }
        runCatching {
            ContextCompat.startForegroundService(context, intent)
        }
    }

    fun stop(context: Context) {
        runCatching {
            context.stopService(Intent(context, GenerationForegroundService::class.java))
        }
    }
}

class GenerationForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val convId = intent?.getStringExtra(ExternalEntryRouter.EXTRA_CONVERSATION_ID).orEmpty()
        if (intent?.action == ACTION_STOP) {
            GenerationServiceBridge.requestStop(convId)
            stopSelf()
            return START_NOT_STICKY
        }

        val state = GenerationNotificationState(
            conversationID = convId,
            chatTitle = intent?.getStringExtra(EXTRA_CHAT_TITLE).orEmpty(),
            modeBadge = intent?.getStringExtra(EXTRA_MODE_BADGE).orEmpty(),
            speakerOrModel = intent?.getStringExtra(EXTRA_SPEAKER_OR_MODEL).orEmpty(),
            phaseText = intent?.getStringExtra(EXTRA_PHASE_TEXT).orEmpty(),
            isBlind = intent?.getBooleanExtra(EXTRA_IS_BLIND, false) == true
        )

        ensureChannel()

        val openIntent = Intent(this, MainActivity::class.java).apply {
            setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (convId.isNotEmpty()) {
                putExtra(ExternalEntryRouter.EXTRA_CONVERSATION_ID, convId)
            }
        }
        val openPending = PendingIntent.getActivity(
            this,
            1001,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, GenerationForegroundService::class.java).apply {
            action = ACTION_STOP
            putExtra(ExternalEntryRouter.EXTRA_CONVERSATION_ID, convId)
        }
        val stopPending = PendingIntent.getService(
            this,
            1002,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_fugue)
            .setContentTitle(GenerationProgressFormatter.formatTitle(state))
            .setContentText(GenerationProgressFormatter.formatBody(state))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setContentIntent(openPending)
            .addAction(
                android.R.drawable.ic_media_pause,
                L10n.text("停止生成", "Stop"),
                stopPending
            )
            .build()

        runCatching {
            val fgsType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            }
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, fgsType)
        }
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                L10n.text("流式生成进度", "Streaming Progress"),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "fugue_generation"
        const val NOTIFICATION_ID = 4102
        const val ACTION_START_OR_UPDATE = "com.iosbox.app.action.GENERATION_START"
        const val ACTION_STOP = "com.iosbox.app.action.GENERATION_STOP"
        const val EXTRA_CHAT_TITLE = "extra_chat_title"
        const val EXTRA_MODE_BADGE = "extra_mode_badge"
        const val EXTRA_SPEAKER_OR_MODEL = "extra_speaker_or_model"
        const val EXTRA_PHASE_TEXT = "extra_phase_text"
        const val EXTRA_IS_BLIND = "extra_is_blind"
    }
}
