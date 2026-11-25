package com.iosbox.app.ui.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.RequestMetrics
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.ui.theme.DS
import java.math.BigDecimal
import java.math.MathContext

internal data class ModelPriceRates(val currency: String, val input: Double, val output: Double)

internal fun configuredModelRates(model: ModelSpec): ModelPriceRates? {
    val input = RequestMetrics.validPrice(model.inputPricePerMillion) ?: return null
    val output = RequestMetrics.validPrice(model.outputPricePerMillion) ?: return null
    val currency = model.priceCurrency?.takeIf { it in RequestMetrics.supportedCurrencies } ?: return null
    return ModelPriceRates(currency, input, output)
}

internal fun displayRate(value: Double): String {
    val decimal = BigDecimal.valueOf(value).round(MathContext(6)).stripTrailingZeros()
    return if (decimal.scale() > 9) decimal.toString() else decimal.toPlainString()
}

@Composable
private fun ModelDetails(model: ModelSpec) {
    val capabilities = buildList {
        if (model.supportsReasoning) add(L10n.text("思考", "Reasoning"))
        if (model.supportsVision) add(L10n.text("识图", "Vision"))
    }
    if (capabilities.isNotEmpty()) {
        Text(capabilities.joinToString(" · "), style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.primary)
    }
    val rates = configuredModelRates(model)
    val price = if (rates == null) L10n.text("单价未完整设置", "Price not fully set") else {
        val input = displayRate(rates.input)
        val output = displayRate(rates.output)
        L10n.text("${rates.currency} 输入 $input / 输出 $output · 每百万 Token",
            "${rates.currency} input $input / output $output · per 1M tokens")
    }
    Text(price, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun ModelDetailsExplanation() {
    Text(
        text = L10n.text(
            "显示已保存的模型。能力是本地标记，可能按名称推测；基础单价不含服务商倍率。",
            "Showing saved models. Capability labels are local and may be inferred from names; base prices exclude provider multipliers."
        ),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelPickerSheet(
    providers: List<ProviderItem>,
    selectedTargetId: String?,
    onSelect: (ResolvedModelTarget) -> Unit,
    onDismiss: () -> Unit,
    title: String = L10n.text("选择回答模型", "Select Model")
) {
    var query by remember { mutableStateOf("") }
    val hasReadyModels = remember(providers) { providers.any { it.isReadyForChat } }
    val readyProviders = remember(providers, query) {
        val q = query.trim().lowercase()
        providers.filter { it.isReadyForChat }.mapNotNull { provider ->
            val models = provider.enabledModels.filter {
                q.isEmpty() || it.id.lowercase().contains(q) || it.displayName.lowercase().contains(q) ||
                    provider.name.lowercase().contains(q)
            }
            if (models.isEmpty()) null else provider to models
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 260.dp, max = 560.dp)
                .padding(horizontal = DS.Spacing.lg)
                .padding(bottom = DS.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Filled.Close, contentDescription = L10n.text("关闭", "Close"))
                }
            }

            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                placeholder = { Text(L10n.text("搜索模型名称或服务商…", "Search models or providers…")) }
            )

            if (readyProviders.isEmpty()) {
                Column(modifier = Modifier.padding(vertical = DS.Spacing.xl)) {
                    Text(
                        text = if (query.isNotBlank() && hasReadyModels) {
                            L10n.text("没有匹配的模型", "No matching models")
                        } else {
                            L10n.text("暂无可用模型，请在「设置」中连接服务商并启用模型。",
                                "No ready models. Connect a provider and enable models in Settings.")
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    if (query.isNotBlank() && hasReadyModels) {
                        TextButton(onClick = { query = "" }) { Text(L10n.text("清除搜索", "Clear search")) }
                    }
                }
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(DS.Spacing.xs)) {
                    item { ModelDetailsExplanation() }
                    for ((provider, models) in readyProviders) {
                        item(key = "hdr_${provider.id}") {
                            Text(
                                text = "${provider.name} · ${provider.protocolType.shortBadge}",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = DS.parseHexColor(provider.accentHex),
                                modifier = Modifier.padding(top = DS.Spacing.sm, bottom = 2.dp)
                            )
                        }
                        items(models, key = { "${provider.id}::${it.id}" }) { spec ->
                            val target = provider.makeTarget(spec)
                            val isSelected = target.id == selectedTargetId
                            Surface(
                                shape = MaterialTheme.shapes.small,
                                color = if (isSelected) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.55f)
                                else MaterialTheme.colorScheme.surface
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable {
                                            onSelect(target)
                                            onDismiss()
                                        }
                                        .padding(horizontal = DS.Spacing.md, vertical = DS.Spacing.sm),
                                    verticalAlignment = Alignment.CenterVertically
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
                                        ModelDetails(spec)
                                    }
                                    if (isSelected) {
                                        Icon(
                                            imageVector = Icons.Filled.Check,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(18.dp)
                                        )
                                    }
                                }
                            }
                            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.4f))
                        }
                    }
                    item { Spacer(modifier = Modifier.size(16.dp)) }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArenaConfigSheet(
    providers: List<ProviderItem>,
    isArenaMode: Boolean,
    selectedTargets: List<ResolvedModelTarget>,
    blindArenaMode: Boolean,
    onApply: (enabled: Boolean, targets: List<ResolvedModelTarget>, blindMode: Boolean) -> Unit,
    onDismiss: () -> Unit
) {
    var arenaEnabled by remember(isArenaMode) { mutableStateOf(isArenaMode) }
    var blindEnabled by remember(blindArenaMode) { mutableStateOf(blindArenaMode) }
    var query by remember { mutableStateOf("") }
    val hasReadyModels = remember(providers) { providers.any { it.isReadyForChat } }
    val chosen = remember(selectedTargets) {
        mutableStateListOf<ResolvedModelTarget>().apply {
            addAll(selectedTargets)
        }
    }

    val readyProviders = remember(providers, query) {
        val q = query.trim().lowercase()
        providers.filter { it.isReadyForChat }.mapNotNull { provider ->
            val models = provider.enabledModels.filter {
                q.isEmpty() || it.id.lowercase().contains(q) || it.displayName.lowercase().contains(q) ||
                    provider.name.lowercase().contains(q)
            }
            if (models.isEmpty()) null else provider to models
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 320.dp, max = 620.dp)
                .padding(horizontal = DS.Spacing.lg)
                .padding(bottom = DS.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = L10n.text("对话模式与竞技场", "Chat Mode & Model Arena"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(
                    onClick = {
                        onApply(arenaEnabled, chosen.toList(), blindEnabled)
                        onDismiss()
                    },
                    enabled = !arenaEnabled || chosen.size >= 2
                ) {
                    Text(L10n.text("应用", "Apply"))
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
                FilterChip(
                    selected = !arenaEnabled,
                    onClick = { arenaEnabled = false },
                    label = { Text(L10n.text("单模型对话", "Single Model")) }
                )
                FilterChip(
                    selected = arenaEnabled,
                    onClick = { arenaEnabled = true },
                    label = { Text(L10n.text("模型竞技场 (${chosen.size}/4)", "Arena (${chosen.size}/4)")) }
                )
            }

            if (arenaEnabled) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = L10n.text("双盲对比与投票", "Blind Arena Voting"),
                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Medium)
                        )
                        Text(
                            text = L10n.text(
                                "隐藏模型名称，投票选出最佳答案后再揭晓并计入胜率榜。",
                                "Hide model identities until you vote for the best reply."
                            ),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Switch(checked = blindEnabled, onCheckedChange = { blindEnabled = it })
                }

                Text(
                    text = L10n.text(
                        "选择 2–4 个并发对比模型（当前已选 ${chosen.size} 个）",
                        "Select 2–4 models to run side-by-side (${chosen.size} selected)"
                    ),
                    style = MaterialTheme.typography.labelMedium,
                    color = if (chosen.size >= 2) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error
                )

                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    placeholder = { Text(L10n.text("筛选可用模型…", "Filter ready models…")) }
                )

                if (readyProviders.isEmpty()) {
                    Column(modifier = Modifier.padding(vertical = DS.Spacing.lg)) {
                        Text(
                            text = if (query.isNotBlank() && hasReadyModels) {
                                L10n.text("没有匹配的模型", "No matching models")
                            } else {
                                L10n.text("暂无可用模型，请在「设置」中连接服务商并启用模型。",
                                    "No ready models. Connect a provider and enable models in Settings.")
                            },
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        if (query.isNotBlank() && hasReadyModels) {
                            TextButton(onClick = { query = "" }) { Text(L10n.text("清除搜索", "Clear search")) }
                        }
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.weight(1f, fill = false),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.xs)
                    ) {
                        item { ModelDetailsExplanation() }
                        for ((provider, models) in readyProviders) {
                            item(key = "arena_hdr_${provider.id}") {
                                Text(
                                    text = "${provider.name} · ${provider.protocolType.shortBadge}",
                                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                    color = DS.parseHexColor(provider.accentHex),
                                    modifier = Modifier.padding(top = DS.Spacing.sm, bottom = 2.dp)
                                )
                            }
                            items(models, key = { "arena_${provider.id}::${it.id}" }) { spec ->
                                val target = provider.makeTarget(spec)
                                val isChecked = chosen.any { it.id == target.id }
                                val toggle: () -> Unit = {
                                    if (isChecked) {
                                        chosen.removeAll { it.id == target.id }
                                    } else if (chosen.size < 4) {
                                        chosen.add(target)
                                    }
                                }
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable(enabled = isChecked || chosen.size < 4, onClick = toggle)
                                        .padding(vertical = DS.Spacing.xs),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Checkbox(
                                        checked = isChecked,
                                        onCheckedChange = { toggle() },
                                        enabled = isChecked || chosen.size < 4
                                    )
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
                                        ModelDetails(spec)
                                    }
                                }
                                HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f))
                            }
                        }
                    }
                }
            } else {
                Text(
                    text = L10n.text(
                        "当前处于单模型对话模式。点击「模型竞技场」可同时向最多 4 个模型提问并双盲投票或交由裁判模型汇总。",
                        "Single-model chat is active. Switch to Model Arena to compare up to 4 models concurrently."
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = DS.Spacing.md)
                )
            }
        }
    }
}
