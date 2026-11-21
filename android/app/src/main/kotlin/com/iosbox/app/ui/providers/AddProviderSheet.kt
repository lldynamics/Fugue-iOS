package com.iosbox.app.ui.providers

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.ProviderTemplate
import com.iosbox.app.core.network.EndpointResolver
import com.iosbox.app.core.network.NetworkLocation
import com.iosbox.app.core.storage.ProviderItem
import com.iosbox.app.ui.theme.DS
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddProviderSheet(
    onCreate: (provider: ProviderItem, apiKey: String) -> Unit,
    onDismiss: () -> Unit
) {
    var selectedTemplateId by remember { mutableStateOf("custom_openai") }
    var name by remember { mutableStateOf(L10n.text("自定义服务商", "Custom Provider")) }
    var protocolType by remember { mutableStateOf(APIProtocolType.OPEN_AI_COMPATIBLE) }
    var baseURL by remember { mutableStateOf("https://api.example.com/v1") }
    var apiKey by remember { mutableStateOf("") }
    var manualModelID by remember { mutableStateOf("") }
    var accentHex by remember { mutableStateOf("#3F6EF6") }
    var iconSymbol by remember { mutableStateOf("slider.horizontal.below.square.and.square.filled") }
    var note by remember { mutableStateOf("") }

    val templateMatch = remember(baseURL, protocolType) {
        ProviderTemplate.matching(baseURL, protocolType)
    }

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
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = L10n.text("添加服务商", "Add Provider"),
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
                )
                Button(
                    enabled = name.trim().isNotEmpty() && baseURL.trim().isNotEmpty(),
                    onClick = {
                        val manual = manualModelID.trim()
                        val baseModels = templateMatch?.suggestedModels.orEmpty()
                        val merged = if (manual.isNotEmpty()) {
                            ModelSpec.deduplicated(
                                listOf(ModelSpec.create(manual, catalogStatus = ModelSpec.CatalogStatus.MANUAL)) + baseModels
                            )
                        } else {
                            baseModels
                        }
                        val now = System.currentTimeMillis()
                        val item = ProviderItem(
                            id = UUID.randomUUID().toString().uppercase(),
                            name = name.trim(),
                            protocolType = protocolType,
                            baseURL = baseURL.trim(),
                            iconSymbol = iconSymbol,
                            accentHex = accentHex,
                            isEnabled = true,
                            sortOrder = (now / 1000L).toInt(),
                            models = merged,
                            customHeaders = emptyList(),
                            notes = note,
                            createdAtEpochMs = now,
                            updatedAtEpochMs = now,
                            hasAuthentication = apiKey.trim().isNotEmpty(),
                            idleTimeoutSeconds = 0
                        )
                        onCreate(item, apiKey.trim())
                        onDismiss()
                    }
                ) {
                    Text(L10n.text("创建", "Create"))
                }
            }

            Text(
                text = L10n.text("快速选择模板", "Quick Templates"),
                style = MaterialTheme.typography.labelLarge
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (tpl in ProviderTemplate.catalog) {
                    val chosen = selectedTemplateId == tpl.id
                    Surface(
                        shape = RoundedCornerShape(DS.Radius.md),
                        color = if (chosen) MaterialTheme.colorScheme.primaryContainer
                        else MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier
                            .width(148.dp)
                            .border(
                                width = if (chosen) 1.5.dp else 0.dp,
                                color = if (chosen) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline.copy(alpha = 0f),
                                shape = RoundedCornerShape(DS.Radius.md)
                            )
                            .clickable {
                                selectedTemplateId = tpl.id
                                name = if (tpl.id == "custom_openai") L10n.text("自定义服务商", "Custom Provider") else tpl.name
                                protocolType = tpl.protocolType
                                baseURL = tpl.baseURL
                                accentHex = tpl.accentHex
                                iconSymbol = tpl.iconSymbol
                                note = tpl.note
                            }
                    ) {
                        Column(
                            modifier = Modifier.padding(10.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            Text(
                                text = tpl.protocolType.shortBadge,
                                style = MaterialTheme.typography.labelSmall,
                                color = DS.parseHexColor(tpl.accentHex)
                            )
                            Text(
                                text = tpl.name,
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(L10n.text("服务商显示名称", "Display Name")) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Text(
                text = L10n.text("API 协议类型", "Protocol"),
                style = MaterialTheme.typography.labelLarge
            )
            Row(
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                for (proto in APIProtocolType.entries) {
                    FilterChip(
                        selected = protocolType == proto,
                        onClick = {
                            baseURL = ProviderTemplate.baseURLAfterProtocolChange(baseURL, protocolType, proto)
                            protocolType = proto
                        },
                        label = { Text(proto.shortBadge) }
                    )
                }
            }

            OutlinedTextField(
                value = baseURL,
                onValueChange = { baseURL = it },
                label = { Text("Base URL") },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth()
            )
            Text(
                text = L10n.text(
                    "端点预览：${EndpointResolver.previewChatEndpoint(baseURL, protocolType)}",
                    "Endpoint: ${EndpointResolver.previewChatEndpoint(baseURL, protocolType)}"
                ),
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            if (NetworkLocation.isPlainHTTPToPublicHost(baseURL)) {
                Text(
                    text = L10n.text(
                        "安全提示：公网地址必须使用 HTTPS，仅局域网或本机地址允许明文 HTTP。",
                        "Public endpoints require HTTPS. Plain HTTP is permitted only for local/LAN hosts."
                    ),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            OutlinedTextField(
                value = apiKey,
                onValueChange = { apiKey = it },
                label = { Text("API Key") },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = manualModelID,
                onValueChange = { manualModelID = it },
                label = { Text(L10n.text("初始模型 ID（可选，也可创建后拉取 /models）", "Initial Model ID (optional)")) },
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}
