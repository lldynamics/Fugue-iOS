package com.iosbox.app.ui.providers

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.backup.EncryptedBackupCrypto
import com.iosbox.app.core.backup.WebDAVSyncClient
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.security.SecretStore
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WebDAVSyncSheet(
    container: AppContainer,
    onDismiss: () -> Unit
) {
    val prefs by container.preferences.state.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val client = remember { WebDAVSyncClient() }

    var serverUrl by remember(prefs.webDAVServerURL) { mutableStateOf(prefs.webDAVServerURL) }
    var username by remember(prefs.webDAVUsername) { mutableStateOf(prefs.webDAVUsername) }
    var remotePath by remember(prefs.webDAVRemotePath) { mutableStateOf(prefs.webDAVRemotePath) }
    var password by remember { mutableStateOf(container.secretStore.loadSecret(SecretStore.WEBDAV_PASSWORD_ACCOUNT)) }
    var passphrase by remember { mutableStateOf(container.secretStore.loadSecret(SecretStore.WEBDAV_SYNC_PASSPHRASE_ACCOUNT)) }

    var isBusy by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf<Pair<Boolean, String>?>(null) }

    val canAuth = serverUrl.trim().isNotEmpty() && username.trim().isNotEmpty() && password.isNotEmpty()
    val canSync = canAuth && EncryptedBackupCrypto.isValidExportPassword(passphrase)

    suspend fun saveConfigAndSecrets() {
        container.preferences.setWebDAVConfig(
            serverUrl = serverUrl.trim(),
            username = username.trim(),
            remotePath = remotePath.trim().ifEmpty { "Fugue/fugue-sync.enc.json" }
        )
        container.secretStore.saveSecret(password, SecretStore.WEBDAV_PASSWORD_ACCOUNT)
        container.secretStore.saveSecret(passphrase, SecretStore.WEBDAV_SYNC_PASSPHRASE_ACCOUNT)
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DS.Spacing.lg)
                .padding(bottom = DS.Spacing.xxl),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
        ) {
            Text(
                text = L10n.text("WebDAV 加密云同步", "Encrypted WebDAV Cloud Sync"),
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
            )
            Text(
                text = L10n.text(
                    "密码与加密口令保存在 Android Keystore + Tink，云端仅上传 AES-GCM 密文。",
                    "Credentials stay in Android Keystore + Tink; only AES-GCM encrypted data is uploaded."
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            OutlinedTextField(
                value = serverUrl,
                onValueChange = { serverUrl = it },
                label = { Text(L10n.text("WebDAV 地址 (如 https://dav.jianguoyun.com/dav/)", "Server URL")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                label = { Text(L10n.text("账号 / 用户名", "Username")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                label = { Text(L10n.text("WebDAV 密码 / 应用密码", "WebDAV Password")) },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = remotePath,
                onValueChange = { remotePath = it },
                label = { Text(L10n.text("远端文件路径", "Remote Path")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = passphrase,
                onValueChange = { passphrase = it },
                label = { Text(L10n.text("备份加密口令（至少 8 位）", "Backup Passphrase (8+ chars)")) },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            if (isBusy) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            statusMessage?.let { (isErr, msg) ->
                Text(
                    text = msg,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (isErr) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
                )
            }

            if (prefs.webDAVLastSyncEpochMs > 0L) {
                val formatted = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                    .format(Date(prefs.webDAVLastSyncEpochMs))
                Text(
                    text = L10n.text("上次同步：$formatted", "Last sync: $formatted"),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
            ) {
                OutlinedButton(
                    enabled = !isBusy,
                    onClick = {
                        scope.launch {
                            saveConfigAndSecrets()
                            statusMessage = false to L10n.text("已保存配置与密钥。", "Configuration saved.")
                        }
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Filled.CloudDone, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.size(4.dp))
                    Text(L10n.text("保存配置", "Save"))
                }
                OutlinedButton(
                    enabled = canAuth && !isBusy,
                    onClick = {
                        scope.launch {
                            isBusy = true
                            statusMessage = null
                            saveConfigAndSecrets()
                            client.testConnection(serverUrl, username, password).fold(
                                onSuccess = {
                                    statusMessage = false to L10n.text("连接验证成功。", "Connection verified.")
                                },
                                onFailure = { err ->
                                    statusMessage = true to (err.message ?: L10n.text("连接失败。", "Connection failed."))
                                }
                            )
                            isBusy = false
                        }
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Text(L10n.text("测试连接", "Test"))
                }
            }

            Button(
                enabled = canSync && !isBusy,
                onClick = {
                    scope.launch {
                        isBusy = true
                        statusMessage = null
                        saveConfigAndSecrets()
                        runCatching {
                            val encryptedBytes = container.backupRepository.exportEncryptedJsonBytes(passphrase)
                            client.uploadEncryptedBytes(serverUrl, remotePath, username, password, encryptedBytes)
                                .getOrThrow()
                            container.preferences.setWebDAVLastSyncEpochMs(System.currentTimeMillis())
                        }.fold(
                            onSuccess = {
                                statusMessage = false to L10n.text(
                                    "已加密上传到 ${remotePath.trim().ifEmpty { "Fugue/fugue-sync.enc.json" }}。",
                                    "Encrypted backup uploaded."
                                )
                            },
                            onFailure = { err ->
                                statusMessage = true to (err.message ?: L10n.text("上传失败。", "Upload failed."))
                            }
                        )
                        isBusy = false
                    }
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.CloudUpload, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.size(6.dp))
                Text(L10n.text("加密上传到云端", "Encrypt & Upload"))
            }

            OutlinedButton(
                enabled = canSync && !isBusy,
                onClick = {
                    scope.launch {
                        isBusy = true
                        statusMessage = null
                        saveConfigAndSecrets()
                        runCatching {
                            val bytes = client.downloadEncryptedBytes(serverUrl, remotePath, username, password)
                                .getOrThrow()
                            val summary = container.backupRepository.importEncryptedBytes(bytes, passphrase)
                            container.flashcardRepository.reload()
                            container.preferences.setWebDAVLastSyncEpochMs(System.currentTimeMillis())
                            summary
                        }.fold(
                            onSuccess = { summary ->
                                statusMessage = summary.hasWarnings to "${summary.title}：${summary.description}"
                            },
                            onFailure = { err ->
                                statusMessage = true to (err.message ?: L10n.text("拉取导入失败。", "Download & import failed."))
                            }
                        )
                        isBusy = false
                    }
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.CloudDownload, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.size(6.dp))
                Text(L10n.text("从云端拉取并合并", "Download & Merge"))
            }

            TextButton(
                onClick = onDismiss,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(L10n.text("关闭", "Close"))
            }
        }
    }
}
