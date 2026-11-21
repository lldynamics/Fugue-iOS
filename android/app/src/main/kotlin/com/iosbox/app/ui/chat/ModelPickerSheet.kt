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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.ui.theme.DS

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelPickerSheet(
    providers: List<ProviderItem>,
    selectedTargetId: String?,
    onSelect: (ResolvedModelTarget) -> Unit,
    onDismiss: () -> Unit
) {
    var query by remember { mutableStateOf("") }
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
                    text = L10n.text("选择回答模型", "Select Model"),
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
                Text(
                    text = L10n.text(
                        "暂无可用模型，请先在「服务商」配置 API Key 并启用模型。",
                        "No ready models. Configure an API key and enable models in Providers."
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = DS.Spacing.xl)
                )
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(DS.Spacing.xs)) {
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
                                    }
                                    if (spec.supportsReasoning) {
                                        Text(
                                            text = L10n.text("推理", "Think"),
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.padding(end = 8.dp)
                                        )
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
