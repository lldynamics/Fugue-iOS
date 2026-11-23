package com.iosbox.app.ui.providers

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ModelPricingCatalog
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.PricingMultiplierPolicy
import com.iosbox.app.core.model.ProviderTemplate
import com.iosbox.app.core.network.EndpointResolver
import com.iosbox.app.core.network.NetworkLocation
import com.iosbox.app.core.security.SecretStore
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.ui.theme.DS
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderDetailScreen(
    providerId: String,
    container: AppContainer,
    onBack: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val prefs by container.preferences.state.collectAsStateWithLifecycle()
    var loaded by remember { mutableStateOf<ProviderItem?>(null) }

    var name by remember { mutableStateOf("") }
    var isEnabled by remember { mutableStateOf(true) }
    var protocolType by remember { mutableStateOf(APIProtocolType.OPEN_AI_COMPATIBLE) }
    var baseURL by remember { mutableStateOf("") }
    var idleTimeout by remember { mutableIntStateOf(0) }
    var primaryKey by remember { mutableStateOf("") }
    var revealKey by remember { mutableStateOf(false) }
    var extraKeys by remember { mutableStateOf<List<String>>(emptyList()) }
    var headers by remember { mutableStateOf<List<CustomHeader>>(emptyList()) }
    var models by remember { mutableStateOf<List<ModelSpec>>(emptyList()) }

    var modelSearch by remember { mutableStateOf("") }
    var isFetchingModels by remember { mutableStateOf(false) }
    var isPinging by remember { mutableStateOf(false) }
    var statusBanner by remember { mutableStateOf<Pair<Boolean, String>?>(null) }

    var showAddModelDialog by remember { mutableStateOf(false) }
    var newModelId by remember { mutableStateOf("") }
    var newModelName by remember { mutableStateOf("") }
    var newModelVision by remember { mutableStateOf(true) }
    var newModelReasoning by remember { mutableStateOf(false) }

    var showAddExtraKeyDialog by remember { mutableStateOf(false) }
    var newExtraKey by remember { mutableStateOf("") }

    var showAddHeaderDialog by remember { mutableStateOf(false) }
    var newHeaderKey by remember { mutableStateOf("") }
    var newHeaderValue by remember { mutableStateOf("") }
    var newHeaderSecret by remember { mutableStateOf(false) }

    var customMultiplierInput by remember { mutableStateOf("1") }
    var multiplierMessage by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(providerId) {
        val item = container.chatRepository.getProvider(providerId) ?: return@LaunchedEffect
        loaded = item
        name = item.name
        isEnabled = item.isEnabled
        protocolType = item.protocolType
        baseURL = item.baseURL
        idleTimeout = item.idleTimeoutSeconds
        primaryKey = container.secretStore.loadAPIKey(item.id)
        extraKeys = container.secretStore.loadExtraAPIKeys(item.id)
        headers = item.customHeaders
        models = item.models
        val mult = container.preferences.pricingMultiplierFor(item.id)
        customMultiplierInput = PricingMultiplierPolicy.format(mult).removeSuffix("x")
    }

    fun persistProvider(
        updatedModels: List<ModelSpec> = models,
        updatedHeaders: List<CustomHeader> = headers,
        updatedEnabled: Boolean = isEnabled,
        updatedProto: APIProtocolType = protocolType,
        updatedURL: String = baseURL,
        updatedName: String = name
    ) {
        val base = loaded ?: return
        val next = base.copy(
            name = updatedName.trim().ifEmpty { base.name },
            isEnabled = updatedEnabled,
            protocolType = updatedProto,
            baseURL = updatedURL.trim(),
            models = ModelSpec.deduplicated(updatedModels),
            customHeaders = updatedHeaders,
            hasAuthentication = primaryKey.trim().isNotEmpty() || extraKeys.isNotEmpty()
        )
        loaded = next
        scope.launch {
            container.chatRepository.saveProvider(next)
        }
    }

    val filteredModels = remember(models, modelSearch) {
        val q = modelSearch.trim().lowercase()
        if (q.isEmpty()) models
        else models.filter { it.id.lowercase().contains(q) || it.displayName.lowercase().contains(q) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = {
                        container.secretStore.saveAPIKey(providerId, primaryKey)
                        persistProvider()
                        onBack()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = L10n.text("返回", "Back"))
                    }
                },
                title = {
                    Text(
                        text = name.ifBlank { L10n.text("服务商配置", "Provider Config") },
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold)
                    )
                }
            )
        }
    ) { innerPadding ->
        if (loaded == null) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                CircularProgressIndicator()
            }
            return@Scaffold
        }

        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(DS.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(L10n.text("启用该服务商", "Enabled"), fontWeight = FontWeight.Medium)
                            Switch(
                                checked = isEnabled,
                                onCheckedChange = {
                                    isEnabled = it
                                    persistProvider(updatedEnabled = it)
                                }
                            )
                        }

                        OutlinedTextField(
                            value = name,
                            onValueChange = {
                                name = it
                                persistProvider(updatedName = it)
                            },
                            label = { Text(L10n.text("服务商名称", "Provider Name")) },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth()
                        )

                        Text(L10n.text("接口协议", "Protocol"), style = MaterialTheme.typography.labelLarge)
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            for (proto in APIProtocolType.entries) {
                                FilterChip(
                                    selected = protocolType == proto,
                                    onClick = {
                                        val nextUrl = ProviderTemplate.baseURLAfterProtocolChange(baseURL, protocolType, proto)
                                        protocolType = proto
                                        baseURL = nextUrl
                                        persistProvider(updatedProto = proto, updatedURL = nextUrl)
                                    },
                                    label = { Text(proto.shortBadge) }
                                )
                            }
                        }

                        OutlinedTextField(
                            value = baseURL,
                            onValueChange = {
                                baseURL = it
                                persistProvider(updatedURL = it)
                            },
                            label = { Text("Base URL") },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                            modifier = Modifier.fillMaxWidth()
                        )

                        val sampleModel = models.firstOrNull()?.id ?: "model-id"
                        Text(
                            text = L10n.text(
                                "请求预览：${EndpointResolver.previewChatEndpoint(baseURL, protocolType, sampleModel)}",
                                "Preview: ${EndpointResolver.previewChatEndpoint(baseURL, protocolType, sampleModel)}"
                            ),
                            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        if (NetworkLocation.isPlainHTTPToPublicHost(baseURL)) {
                            Text(
                                text = L10n.text(
                                    "公网地址必须使用 HTTPS，仅局域网或本机地址允许 HTTP。",
                                    "Public hosts require HTTPS; plain HTTP is allowed only for local/LAN hosts."
                                ),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.error
                            )
                        }

                        Text(L10n.text("流式空闲超时", "Stream Idle Timeout"), style = MaterialTheme.typography.labelLarge)
                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            for (sec in SecretStore.SUPPORTED_TIMEOUT_OPTIONS) {
                                FilterChip(
                                    selected = idleTimeout == sec,
                                    onClick = {
                                        idleTimeout = sec
                                        container.secretStore.saveIdleTimeoutSeconds(providerId, sec)
                                    },
                                    label = {
                                        Text(
                                            if (sec == 0) L10n.text("自动", "Auto") else "${sec}s"
                                        )
                                    }
                                )
                            }
                        }
                    }
                }
            }

            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
                    ) {
                        Text(
                            text = L10n.text("API Key（Keystore + Tink 加密存储）", "API Keys (Encrypted)"),
                            style = MaterialTheme.typography.labelLarge
                        )
                        OutlinedTextField(
                            value = primaryKey,
                            onValueChange = {
                                primaryKey = it
                                container.secretStore.saveAPIKey(providerId, it)
                            },
                            label = { Text(L10n.text("主 API Key", "Primary API Key")) },
                            singleLine = true,
                            visualTransformation = if (revealKey) VisualTransformation.None else PasswordVisualTransformation(),
                            trailingIcon = {
                                IconButton(onClick = { revealKey = !revealKey }) {
                                    Icon(
                                        imageVector = if (revealKey) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                                        contentDescription = null
                                    )
                                }
                            },
                            modifier = Modifier.fillMaxWidth()
                        )

                        extraKeys.forEachIndexed { idx, extra ->
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    text = "${L10n.text("轮询 Key #${idx + 2}", "Pool Key #${idx + 2}")}: ${SecretStore.maskedKeyPreview(extra)}",
                                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                                )
                                IconButton(onClick = {
                                    val next = extraKeys.toMutableList().apply { removeAt(idx) }
                                    extraKeys = next
                                    container.secretStore.saveExtraAPIKeys(providerId, next)
                                }) {
                                    Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                                }
                            }
                        }

                        TextButton(onClick = {
                            newExtraKey = ""
                            showAddExtraKeyDialog = true
                        }) {
                            Icon(Icons.Filled.Key, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.size(6.dp))
                            Text(L10n.text("添加轮询 / 备用 Key", "Add Rotation Pool Key"))
                        }
                    }
                }
            }

            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
                    ) {
                        Text(
                            text = L10n.text("自定义 HTTP Header（可选）", "Custom Headers"),
                            style = MaterialTheme.typography.labelLarge
                        )
                        for (header in headers) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = header.key,
                                        style = MaterialTheme.typography.bodySmall.copy(
                                            fontFamily = FontFamily.Monospace,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                    )
                                    Text(
                                        text = if (header.isSecret) "•••••••• (Encrypted)" else header.value,
                                        style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                IconButton(onClick = {
                                    if (header.isSecret) {
                                        container.secretStore.deleteSecret(SecretStore.headerAccount(providerId, header.id))
                                    }
                                    val next = headers.filterNot { it.id == header.id }
                                    headers = next
                                    persistProvider(updatedHeaders = next)
                                }) {
                                    Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                                }
                            }
                        }
                        TextButton(onClick = {
                            newHeaderKey = ""
                            newHeaderValue = ""
                            newHeaderSecret = false
                            showAddHeaderDialog = true
                        }) {
                            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.size(6.dp))
                            Text(L10n.text("添加自定义 Header", "Add Header"))
                        }
                    }
                }
            }

            item {
                val activeMultiplier = remember(prefs.providerPricingMultipliers, providerId) {
                    container.preferences.pricingMultiplierFor(providerId)
                }
                fun applyMultiplier(raw: Double) {
                    val clean = PricingMultiplierPolicy.sanitize(raw)
                    val label = PricingMultiplierPolicy.format(clean)
                    customMultiplierInput = label.removeSuffix("x")
                    multiplierMessage = L10n.text(
                        "已设置当前服务商倍率为 $label（仅影响新请求费用估算）。",
                        "Set provider pricing multiplier to $label."
                    )
                    scope.launch {
                        container.preferences.setProviderPricingMultiplier(providerId, clean)
                    }
                }

                Card(
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(DS.Spacing.md),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = L10n.text("中转站计价倍率", "Provider Pricing Multiplier"),
                                style = MaterialTheme.typography.labelLarge
                            )
                            Text(
                                text = PricingMultiplierPolicy.format(activeMultiplier),
                                style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.primary
                            )
                        }

                        Row(
                            modifier = Modifier.horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            for (preset in PricingMultiplierPolicy.PRESETS) {
                                FilterChip(
                                    selected = kotlin.math.abs(activeMultiplier - preset) < 0.001,
                                    onClick = { applyMultiplier(preset) },
                                    label = { Text(PricingMultiplierPolicy.format(preset)) }
                                )
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            OutlinedTextField(
                                value = customMultiplierInput,
                                onValueChange = { customMultiplierInput = it },
                                label = { Text(L10n.text("自定义倍率 (如 0.5 / 7.2)", "Custom (e.g. 0.5 / 7.2)")) },
                                singleLine = true,
                                modifier = Modifier.weight(1f)
                            )
                            Button(onClick = {
                                val parsed = customMultiplierInput.trim().replace(',', '.').toDoubleOrNull()
                                if (parsed != null && parsed.isFinite() && parsed > 0.0) {
                                    applyMultiplier(parsed)
                                } else {
                                    multiplierMessage = L10n.text("请输入大于 0 的有效倍率。", "Enter a positive multiplier.")
                                }
                            }) {
                                Text(L10n.text("应用", "Apply"))
                            }
                        }

                        if (models.isNotEmpty()) {
                            OutlinedButton(
                                onClick = {
                                    var updatedCount = 0
                                    val next = models.map { spec ->
                                        if (spec.inputPricePerMillion == null) {
                                            val matched = ModelPricingCatalog.match(spec.id)
                                            if (matched != null) {
                                                updatedCount += 1
                                                ModelPricingCatalog.apply(matched, spec)
                                            } else {
                                                spec
                                            }
                                        } else {
                                            spec
                                        }
                                    }
                                    models = next
                                    persistProvider(updatedModels = next)
                                    multiplierMessage = L10n.text(
                                        "已为 $updatedCount 个未设价模型自动匹配主流参考单价。",
                                        "Matched reference pricing for $updatedCount models."
                                    )
                                },
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(L10n.text("一键填充主流模型参考单价", "Auto-Fill Reference Model Prices"))
                            }
                        }

                        multiplierMessage?.let { msg ->
                            Text(
                                text = msg,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }

            item {
                Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            enabled = !isFetchingModels && !isPinging,
                            onClick = {
                                scope.launch {
                                    isFetchingModels = true
                                    statusBanner = null
                                    val currentHeaders = loaded?.resolvedCustomHeaders(container.secretStore) ?: emptyList()
                                    val allKeys = container.secretStore.loadAllAPIKeys(providerId)
                                    runCatching {
                                        container.llmClient.fetchModels(
                                            providerName = name,
                                            protocolType = protocolType,
                                            baseURL = baseURL,
                                            apiKey = allKeys.firstOrNull() ?: "",
                                            apiKeys = allKeys.drop(1),
                                            customHeaders = currentHeaders
                                        )
                                    }.onSuccess { fetched ->
                                        val existingIds = models.map { it.id }.toSet()
                                        val liveById = fetched.associateBy { it.id }
                                        val updatedExisting = models.map { saved ->
                                            if (saved.catalogStatus == ModelSpec.CatalogStatus.MANUAL) saved
                                            else {
                                                val found = liveById[saved.id]
                                                saved.copy(
                                                    catalogStatus = if (found != null) ModelSpec.CatalogStatus.LISTED else ModelSpec.CatalogStatus.UNLISTED,
                                                    displayName = if (found != null && saved.displayName == saved.id) found.displayName else saved.displayName
                                                )
                                            }
                                        }
                                        val newOnes = fetched.filter { !existingIds.contains(it.id) }
                                            .map { it.copy(isEnabled = false, catalogStatus = ModelSpec.CatalogStatus.LISTED) }
                                        val merged = ModelSpec.deduplicated(updatedExisting + newOnes)
                                        models = merged
                                        persistProvider(updatedModels = merged)
                                        statusBanner = false to L10n.text(
                                            "拉取成功，共 ${fetched.size} 个可用模型。",
                                            "Fetched ${fetched.size} models."
                                        )
                                    }.onFailure { err ->
                                        statusBanner = true to (err.message ?: "Fetch failed")
                                    }
                                    isFetchingModels = false
                                }
                            },
                            modifier = Modifier.weight(1f)
                        ) {
                            if (isFetchingModels) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Filled.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                            }
                            Spacer(modifier = Modifier.size(6.dp))
                            Text(L10n.text("拉取 /models", "Fetch Models"))
                        }

                        val probeModel = models.firstOrNull { it.isSelectable }
                        OutlinedButton(
                            enabled = !isPinging && !isFetchingModels && probeModel != null,
                            onClick = {
                                val probe = probeModel ?: return@OutlinedButton
                                scope.launch {
                                    isPinging = true
                                    statusBanner = null
                                    val currentHeaders = loaded?.resolvedCustomHeaders(container.secretStore) ?: emptyList()
                                    val allKeys = container.secretStore.loadAllAPIKeys(providerId)
                                    runCatching {
                                        container.llmClient.pingModel(
                                            providerName = name,
                                            protocolType = protocolType,
                                            baseURL = baseURL,
                                            apiKey = allKeys.firstOrNull() ?: "",
                                            apiKeys = allKeys.drop(1),
                                            customHeaders = currentHeaders,
                                            modelID = probe.id,
                                            supportsReasoning = probe.supportsReasoning,
                                            idleTimeoutSeconds = idleTimeout.takeIf { it > 0 }?.toDouble()
                                        )
                                    }.onSuccess { ping ->
                                        statusBanner = false to L10n.text(
                                            "连接成功 (${ping.modelID}) · TTFT ${ping.ttftMs}ms · 总耗时 ${ping.totalMs}ms",
                                            "Connected (${ping.modelID}) · TTFT ${ping.ttftMs}ms · Total ${ping.totalMs}ms"
                                        )
                                    }.onFailure { err ->
                                        statusBanner = true to (err.message ?: "Ping failed")
                                    }
                                    isPinging = false
                                }
                            },
                            modifier = Modifier.weight(1f)
                        ) {
                            if (isPinging) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Filled.Speed, contentDescription = null, modifier = Modifier.size(18.dp))
                            }
                            Spacer(modifier = Modifier.size(6.dp))
                            Text(L10n.text("测速验证", "Test Ping"))
                        }
                    }

                    statusBanner?.let { (isErr, msg) ->
                        Text(
                            text = msg,
                            style = MaterialTheme.typography.bodySmall,
                            color = if (isErr) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
                        )
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        val enabledCount = models.count { it.isSelectable }
                        Text(
                            text = L10n.text("模型列表 ($enabledCount/${models.size})", "Models ($enabledCount/${models.size})"),
                            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                        )
                        Row {
                            TextButton(onClick = {
                                newModelId = ""
                                newModelName = ""
                                newModelVision = true
                                newModelReasoning = false
                                showAddModelDialog = true
                            }) {
                                Text(L10n.text("+ 手动添加", "+ Add"))
                            }
                            if (models.isNotEmpty()) {
                                TextButton(onClick = {
                                    val allEnabled = models.all { it.isEnabled }
                                    val next = models.map { it.copy(isEnabled = !allEnabled) }
                                    models = next
                                    persistProvider(updatedModels = next)
                                }) {
                                    Text(if (models.all { it.isEnabled }) L10n.text("全停", "None") else L10n.text("全启", "All"))
                                }
                            }
                        }
                    }

                    if (models.size > 5) {
                        OutlinedTextField(
                            value = modelSearch,
                            onValueChange = { modelSearch = it },
                            singleLine = true,
                            placeholder = { Text(L10n.text("搜索模型…", "Search models…")) },
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
            }

            items(filteredModels, key = { it.id }) { spec ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = spec.displayName,
                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium)
                        )
                        if (spec.displayName != spec.id) {
                            Text(
                                text = spec.id,
                                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            FilterChip(
                                selected = spec.supportsVision,
                                onClick = {
                                    val next = models.map {
                                        if (it.id == spec.id) it.copy(supportsVision = !it.supportsVision) else it
                                    }
                                    models = next
                                    persistProvider(updatedModels = next)
                                },
                                label = { Text(L10n.text("识图", "Vision")) }
                            )
                            FilterChip(
                                selected = spec.supportsReasoning,
                                onClick = {
                                    val next = models.map {
                                        if (it.id == spec.id) it.copy(supportsReasoning = !it.supportsReasoning) else it
                                    }
                                    models = next
                                    persistProvider(updatedModels = next)
                                },
                                label = { Text(L10n.text("思考", "Reasoning")) }
                            )
                        }
                    }
                    Switch(
                        checked = spec.isEnabled,
                        onCheckedChange = { checked ->
                            val next = models.map { if (it.id == spec.id) it.copy(isEnabled = checked) else it }
                            models = next
                            persistProvider(updatedModels = next)
                        }
                    )
                    IconButton(onClick = {
                        val next = models.filterNot { it.id == spec.id }
                        models = next
                        persistProvider(updatedModels = next)
                    }) {
                        Icon(Icons.Filled.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.4f))
            }
        }
    }

    if (showAddModelDialog) {
        AlertDialog(
            onDismissRequest = { showAddModelDialog = false },
            title = { Text(L10n.text("手动添加模型 ID", "Add Model ID")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = newModelId,
                        onValueChange = {
                            newModelId = it
                            newModelReasoning = ModelSpec.inferReasoningSupport(it)
                            newModelVision = ModelSpec.inferVisionSupport(it)
                        },
                        label = { Text("Model ID") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = newModelName,
                        onValueChange = { newModelName = it },
                        label = { Text(L10n.text("显示名称（可选）", "Display Name (optional)")) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(L10n.text("支持识图", "Supports Vision"))
                        Switch(checked = newModelVision, onCheckedChange = { newModelVision = it })
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(L10n.text("支持深度思考", "Supports Reasoning"))
                        Switch(checked = newModelReasoning, onCheckedChange = { newModelReasoning = it })
                    }
                }
            },
            confirmButton = {
                Button(
                    enabled = newModelId.trim().isNotEmpty(),
                    onClick = {
                        val id = newModelId.trim()
                        val spec = ModelSpec.create(
                            id = id,
                            displayName = newModelName.trim().ifEmpty { id },
                            isEnabled = true,
                            supportsVision = newModelVision,
                            supportsReasoning = newModelReasoning,
                            catalogStatus = ModelSpec.CatalogStatus.MANUAL
                        )
                        val next = ModelSpec.deduplicated(listOf(spec) + models)
                        models = next
                        persistProvider(updatedModels = next)
                        showAddModelDialog = false
                    }
                ) {
                    Text(L10n.text("添加", "Add"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddModelDialog = false }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    if (showAddExtraKeyDialog) {
        AlertDialog(
            onDismissRequest = { showAddExtraKeyDialog = false },
            title = { Text(L10n.text("添加轮询 Key", "Add Pool API Key")) },
            text = {
                OutlinedTextField(
                    value = newExtraKey,
                    onValueChange = { newExtraKey = it },
                    label = { Text("API Key") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                Button(
                    enabled = newExtraKey.trim().isNotEmpty(),
                    onClick = {
                        val next = SecretStore.deduplicateKeys(extraKeys + newExtraKey.trim())
                        extraKeys = next
                        container.secretStore.saveExtraAPIKeys(providerId, next)
                        showAddExtraKeyDialog = false
                    }
                ) {
                    Text(L10n.text("保存", "Save"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddExtraKeyDialog = false }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }

    if (showAddHeaderDialog) {
        AlertDialog(
            onDismissRequest = { showAddHeaderDialog = false },
            title = { Text(L10n.text("添加自定义 Header", "Add Custom Header")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = newHeaderKey,
                        onValueChange = {
                            newHeaderKey = it
                            if (CustomHeader.looksSensitive(it)) newHeaderSecret = true
                        },
                        label = { Text("Header Name") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    OutlinedTextField(
                        value = newHeaderValue,
                        onValueChange = { newHeaderValue = it },
                        label = { Text("Header Value") },
                        singleLine = true,
                        visualTransformation = if (newHeaderSecret) PasswordVisualTransformation() else VisualTransformation.None,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(L10n.text("加密保存为敏感值", "Store as Secret"))
                        Switch(checked = newHeaderSecret, onCheckedChange = { newHeaderSecret = it })
                    }
                }
            },
            confirmButton = {
                Button(
                    enabled = newHeaderKey.trim().isNotEmpty() && newHeaderValue.trim().isNotEmpty(),
                    onClick = {
                        val headerId = java.util.UUID.randomUUID().toString().uppercase()
                        val k = newHeaderKey.trim()
                        val v = newHeaderValue.trim()
                        val storedValue = if (newHeaderSecret) {
                            container.secretStore.saveSecret(v, SecretStore.headerAccount(providerId, headerId))
                            ""
                        } else {
                            v
                        }
                        val next = headers + CustomHeader(
                            id = headerId,
                            key = k,
                            value = storedValue,
                            isEnabled = true,
                            isSecret = newHeaderSecret
                        )
                        headers = next
                        persistProvider(updatedHeaders = next)
                        showAddHeaderDialog = false
                    }
                ) {
                    Text(L10n.text("添加", "Add"))
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddHeaderDialog = false }) {
                    Text(L10n.text("取消", "Cancel"))
                }
            }
        )
    }
}
