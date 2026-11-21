package com.iosbox.app.ui.chat

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.L10n

@Composable
fun AIConsentDialog(
    targetSummary: String,
    onAccept: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = L10n.text("第三方 AI 数据直连说明", "AI Data Transmission Notice"),
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    text = L10n.text(
                        "本次发送将把您的提问、选用的上下文消息、附件与系统提示词直接发送至以下配置接口：",
                        "Sending will transmit your prompt, selected history, attachments, and system prompt directly to:"
                    ),
                    style = MaterialTheme.typography.bodySmall
                )
                Text(
                    text = targetSummary,
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.primary
                )
                Text(
                    text = L10n.text(
                        "API Key 与敏感请求头均采用 Android Keystore + Tink 加密存储于本机，不经过任何第三方中转服务器。AI 生成内容仅供参考，重要决策请独立核实。",
                        "API keys and sensitive headers are encrypted locally via Android Keystore & Tink and sent directly without intermediary servers."
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        },
        confirmButton = {
            Button(onClick = onAccept) {
                Text(L10n.text("同意并继续发送", "Agree & Send"))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(L10n.text("暂不发送", "Cancel"))
            }
        }
    )
}
