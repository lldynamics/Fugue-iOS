package com.iosbox.app.ui.providers

import android.content.ClipboardManager
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.ProviderTemplate
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.network.ClipboardProviderParser
import com.iosbox.app.core.network.NetworkLocation
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuickKeySetupSheet(
    container: AppContainer,
    existingProviders: List<ProviderItem>,
    onConnected: (ResolvedModelTarget?) -> Unit = {},
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var pasteInput by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("OpenAI") }
    var protocolType by remember { mutableStateOf(APIProtocolType.OPEN_AI_COMPATIBLE) }
    var baseURL by remember { mutableStateOf("https://api.openai.com/v1") }
    var apiKey by remember { mutableStateOf("") }
    var manualModelID by remember { mutableStateOf("") }
    var accentHex by remember { mutableStateOf("#10A37F") }
    var iconSymbol by remember { mutableStateOf("circle.hexagongrid.fill") }
    var parseNote by remember { mutableStateOf<String?>(null) }

    var isBusy by remember { mutableStateOf(false) }
    var statusBanner by remember { mutableStateOf<Pair<Boolean, String>?>(null) }
    var connectedTarget by remember { mutableStateOf<ResolvedModelTarget?>(null) }

    fun applyParsedText(raw: String) {
        pasteInput = raw
        statusBanner = null
        val parsed = ClipboardProviderParser.parse(raw)
        if (parsed == null) {
            parseNote = L10n.text(
                "未检测到有效 API Key 或安全链接（注：公网明文 http:// 地址已拦截）。请手动核对下方字段。",
                "No valid key or HTTPS/LAN URL detected (insecure public http:// is blocked)."
            )
            return
        }
        name = parsed.providerName
        protocolType = parsed.protocolType
        baseURL = parsed.baseURL
        if (parsed.apiKey.isNotEmpty()) {
            apiKey = parsed.apiKey
        }
        accentHex = parsed.accentHex
        iconSymbol = parsed.iconSymbol
        parseNote = parsed.confidenceNote
        if (parsed.suggestedModels.isNotEmpty() && manualModelID.isBlank()) {
            manualModelID = ClipboardProviderParser.pickBestStarterModel(
                parsed.suggestedModels,
                parsed.protocolType
            )?.id.orEmpty()
        }
    }

    val quickTemplateIDs = listOf("deepseek", "siliconflow", "openai", "openrouter", "anthropic", "gemini")

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = DS.Spacing.lg)
                .padding(bottom = DS.Spacing.xxl),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Icon(
                    imageVector = Icons.Filled.Bolt,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = L10n.text("剪贴板一键配 Key 并测通", "Quick Key Setup & Verify"),
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                    )
                    Text(
                        text = L10n.text(
                            "支持整段环境变量、中转站信息或裸 Key，自动拉取并测通首个可用对话模型。",
                            "Paste an API key or gateway snippet to fetch models and verify a working starter model."
                        ),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            OutlinedButton(
                enabled = !isBusy,
                onClick = {
                    val cm = context.getSystemService(ClipboardManager::class.java)
                    val clipText = cm?.primaryClip?.takeIf { it.itemCount > 0 }
                        ?.getItemAt(0)?.coerceToText(context)?.toString()?.trim().orEmpty()
                    if (clipText.isEmpty()) {
                        parseNote = L10n.text("系统剪贴板暂无文本内容，请在下方直接粘贴。", "Clipboard has no text content.")
                    } else {
                        applyParsedText(clipText)
                    }
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Filled.ContentPaste, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(modifier = Modifier.size(6.dp))
                Text(L10n.text("从剪贴板识别", "Read from Clipboard"))
            }

            OutlinedTextField(
                value = pasteInput,
                onValueChange = { applyParsedText(it) },
                label = { Text(L10n.text("粘贴 API Key 或中转配置片段", "Paste Key or Config Snippet")) },
                placeholder = {
                    Text("sk-...  或  OPENAI_BASE_URL=https://...\nOPENAI_API_KEY=sk-...")
                },
                minLines = 2,
                maxLines = 4,
                modifier = Modifier.fillMaxWidth()
            )

            parseNote?.let { note ->
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.6f),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = note,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSecondaryContainer,
                        modifier = Modifier.padding(DS.Spacing.sm)
                    )
                }
            }

            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (tplID in quickTemplateIDs) {
                    val tpl = ProviderTemplate.catalog.firstOrNull { it.id == tplID } ?: continue
                    FilterChip(
                        selected = baseURL.trim().trimEnd('/').equals(tpl.baseURL.trimEnd('/'), ignoreCase = true) &&
                            protocolType == tpl.protocolType,
                        onClick = {
                            name = tpl.name
                            protocolType = tpl.protocolType
                            baseURL = tpl.baseURL
                            accentHex = tpl.accentHex
                            iconSymbol = tpl.iconSymbol
                            manualModelID = tpl.suggestedModels.firstOrNull()?.id.orEmpty()
                        },
                        label = { Text(tpl.name) }
                    )
                }
            }

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                singleLine = true,
                label = { Text(L10n.text("服务商名称", "Provider Name")) },
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = baseURL,
                onValueChange = { baseURL = it },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                label = { Text(L10n.text("Base URL", "Base URL")) },
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = apiKey,
                onValueChange = { apiKey = it },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                label = { Text(L10n.text("API Key（本地加密存放，局域网可留空）", "API Key")) },
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = manualModelID,
                onValueChange = { manualModelID = it },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                label = { Text(L10n.text("指定模型 ID（留空则自动拉取并优选）", "Model ID (optional auto-pick)")) },
                modifier = Modifier.fillMaxWidth()
            )

            if (isBusy) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            statusBanner?.let { (ok, msg) ->
                Surface(
                    shape = RoundedCornerShape(DS.Radius.sm),
                    color = if (ok) MaterialTheme.colorScheme.primaryContainer
                    else MaterialTheme.colorScheme.errorContainer,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier.padding(DS.Spacing.sm),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (ok) {
                            Icon(
                                imageVector = Icons.Filled.CheckCircle,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        Text(
                            text = msg,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (ok) MaterialTheme.colorScheme.onPrimaryContainer
                            else MaterialTheme.colorScheme.onErrorContainer
                        )
                    }
                }
            }

            val cleanURL = baseURL.trim()
            val cleanKey = apiKey.trim()
            val isLocal = NetworkLocation.isLocalOrPrivate(cleanURL)
            val isPublicHttp = NetworkLocation.isPlainHTTPToPublicHost(cleanURL)

            if (connectedTarget == null) {
                Button(
                    enabled = !isBusy && cleanURL.isNotEmpty() && !isPublicHttp && (cleanKey.isNotEmpty() || isLocal),
                    onClick = {
                        scope.launch {
                            isBusy = true
                            statusBanner = null
                            try {
                                val fetched = runCatching {
                                    container.llmClient.fetchModels(
                                        providerName = name.trim().ifEmpty { "Provider" },
                                        protocolType = protocolType,
                                        baseURL = cleanURL,
                                        apiKey = cleanKey
                                    )
                                }.getOrNull().orEmpty()

                                val tplSuggestions = ProviderTemplate.matching(cleanURL, protocolType)
                                    ?.suggestedModels.orEmpty()
                                val manualTrimmed = manualModelID.trim()
                                val picked = if (manualTrimmed.isNotEmpty()) {
                                    ModelSpec.create(
                                        id = manualTrimmed,
                                        catalogStatus = if (fetched.any { it.id == manualTrimmed }) {
                                            ModelSpec.CatalogStatus.LISTED
                                        } else {
                                            ModelSpec.CatalogStatus.MANUAL
                                        }
                                    )
                                } else {
                                    ClipboardProviderParser.pickBestStarterModel(
                                        fetched.ifEmpty { tplSuggestions },
                                        protocolType
                                    )
                                } ?: error(
                                    L10n.text(
                                        "未从接口获取到模型列表，请手动填写一个模型 ID 后重试。",
                                        "No models returned by gateway. Enter a model ID and retry."
                                    )
                                )

                                val ping = container.llmClient.pingModel(
                                    providerName = name.trim().ifEmpty { "Provider" },
                                    protocolType = protocolType,
                                    baseURL = cleanURL,
                                    apiKey = cleanKey,
                                    modelID = picked.id,
                                    supportsReasoning = picked.supportsReasoning
                                )

                                val allModels = ModelSpec.deduplicated(
                                    listOf(picked.copy(isEnabled = true)) +
                                        fetched.map { it.copy(isEnabled = it.id == picked.id) }
                                )
                                val matchedExisting = existingProviders.firstOrNull {
                                    it.protocolType == protocolType &&
                                        it.baseURL.trim().trimEnd('/').equals(cleanURL.trimEnd('/'), ignoreCase = true)
                                }
                                val now = System.currentTimeMillis()
                                val savedProvider = if (matchedExisting != null) {
                                    val mergedModels = ModelSpec.deduplicated(
                                        listOf(picked.copy(isEnabled = true)) + matchedExisting.models + allModels
                                    )
                                    matchedExisting.copy(
                                        name = name.trim().ifEmpty { matchedExisting.name },
                                        isEnabled = true,
                                        models = mergedModels,
                                        hasAuthentication = cleanKey.isNotEmpty() || matchedExisting.hasAuthentication,
                                        updatedAtEpochMs = now
                                    )
                                } else {
                                    ProviderItem(
                                        id = UUID.randomUUID().toString().uppercase(),
                                        name = name.trim().ifEmpty { "Provider" },
                                        protocolType = protocolType,
                                        baseURL = cleanURL,
                                        iconSymbol = iconSymbol,
                                        accentHex = accentHex,
                                        isEnabled = true,
                                        sortOrder = (now / 1000L).toInt(),
                                        models = allModels,
                                        customHeaders = emptyList(),
                                        notes = "",
                                        createdAtEpochMs = now,
                                        updatedAtEpochMs = now,
                                        hasAuthentication = cleanKey.isNotEmpty(),
                                        idleTimeoutSeconds = 0
                                    )
                                }

                                if (cleanKey.isNotEmpty()) {
                                    container.secretStore.saveAPIKey(savedProvider.id, cleanKey)
                                }
                                container.chatRepository.saveProvider(savedProvider)

                                val target = savedProvider.makeTarget(picked.copy(isEnabled = true))
                                if (container.preferences.state.value.defaultTargetID.isNullOrBlank()) {
                                    container.preferences.setDefaultTargetID(target.id)
                                }
                                connectedTarget = target
                                val countNote = if (fetched.isNotEmpty()) "（拉取 ${fetched.size} 个模型）" else ""
                                statusBanner = true to L10n.text(
                                    "已测通 ${picked.displayName}（首字 ${ping.ttftMs} ms）$countNote，已保存并设为可用！",
                                    "Verified ${picked.displayName} (TTFT ${ping.ttftMs} ms)."
                                )
                            } catch (t: Throwable) {
                                if (t is CancellationException) throw t
                                statusBanner = false to (t.message ?: L10n.text("连接测通失败，请检查地址与 Key。", "Verification failed."))
                            } finally {
                                isBusy = false
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        if (isBusy) L10n.text("正在拉取并测通…", "Testing & Saving…")
                        else L10n.text("一键拉取并测通模型", "Fetch & Verify Model")
                    )
                }
            } else {
                Button(
                    onClick = {
                        val target = connectedTarget
                        onDismiss()
                        onConnected(target)
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(L10n.text("完成并开始对话", "Done & Start Chatting"))
                }
            }
        }
    }
}
