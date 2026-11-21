package com.iosbox.app.ui.usage

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.iosbox.app.AppContainer
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.RequestKind
import com.iosbox.app.core.model.RequestStatus
import com.iosbox.app.core.storage.RequestRecordItem
import com.iosbox.app.ui.theme.DS
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

private enum class UsagePeriod {
    TODAY, MONTH, ALL;

    val title: String
        get() = when (this) {
            TODAY -> L10n.text("按日", "Today")
            MONTH -> L10n.text("按月", "Month")
            ALL -> L10n.text("全部", "All")
        }

    fun includes(epochMs: Long): Boolean {
        if (this == ALL) return true
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, 0)
        cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        if (this == MONTH) cal.set(Calendar.DAY_OF_MONTH, 1)
        return epochMs >= cal.timeInMillis
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UsageScreen(container: AppContainer) {
    val allRecords by container.chatRepository.observeRequestRecords().collectAsStateWithLifecycle(initialValue = emptyList())
    var period by remember { mutableStateOf(UsagePeriod.MONTH) }
    var selectedProviderId by remember { mutableStateOf<String?>(null) }

    val providerOptions = remember(allRecords) {
        allRecords.distinctBy { it.providerID }.map { it.providerID to it.providerName }
    }

    val filtered = remember(allRecords, period, selectedProviderId) {
        allRecords.filter { rec ->
            period.includes(rec.startedAtEpochMs) &&
                (selectedProviderId == null || rec.providerID == selectedProviderId)
        }
    }

    val modelRows = remember(filtered) { filtered.filter { it.kind != RequestKind.WEB_SEARCH } }
    val succeededCount = remember(filtered) { filtered.count { it.status == RequestStatus.SUCCEEDED } }
    val totalPrompt = remember(filtered) { filtered.sumOf { it.promptTokens ?: 0 } }
    val totalCompletion = remember(filtered) { filtered.sumOf { it.completionTokens ?: 0 } }
    val totalCached = remember(filtered) { filtered.sumOf { it.cachedTokens ?: 0 } }
    val medianTps = remember(modelRows) {
        val samples = modelRows.mapNotNull { it.tokensPerSecond }.sorted()
        if (samples.isEmpty()) null else {
            val mid = samples.size / 2
            val med = if (samples.size % 2 == 0) (samples[mid - 1] + samples[mid]) / 2.0 else samples[mid]
            med to samples.size
        }
    }
    val costSummary = remember(modelRows) {
        val byCurrency = LinkedHashMap<String, Double>()
        for (rec in modelRows) {
            if (rec.status == RequestStatus.RUNNING) continue
            val cur = rec.currency ?: continue
            val cost = rec.estimatedCost ?: continue
            byCurrency[cur] = (byCurrency[cur] ?: 0.0) + cost
        }
        val first = byCurrency.entries.firstOrNull()
        first?.let { "${it.key} ${String.format(Locale.US, "%.4f", it.value).trimEnd('0').trimEnd('.')}" } ?: "—"
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = L10n.text("用量与测速账本", "Usage & Ledger"),
                        style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold)
                    )
                }
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = PaddingValues(DS.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.md)
        ) {
            item {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    for (p in UsagePeriod.entries) {
                        FilterChip(
                            selected = period == p,
                            onClick = { period = p },
                            label = { Text(p.title) }
                        )
                    }
                }
            }

            if (providerOptions.isNotEmpty()) {
                item {
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        FilterChip(
                            selected = selectedProviderId == null,
                            onClick = { selectedProviderId = null },
                            label = { Text(L10n.text("全部服务商", "All Providers")) }
                        )
                        for ((pid, pName) in providerOptions) {
                            FilterChip(
                                selected = selectedProviderId == pid,
                                onClick = { selectedProviderId = if (selectedProviderId == pid) null else pid },
                                label = { Text(pName) }
                            )
                        }
                    }
                }
            }

            item {
                Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
                        MetricTile(
                            title = L10n.text("预估费用", "Est. Cost"),
                            value = costSummary,
                            detail = null,
                            modifier = Modifier.weight(1f)
                        )
                        MetricTile(
                            title = L10n.text("中位速率", "Median Speed"),
                            value = medianTps?.let { String.format(Locale.US, "%.1f tok/s", it.first) } ?: "—",
                            detail = medianTps?.let { L10n.text("${it.second} 样本", "${it.second} samples") },
                            modifier = Modifier.weight(1f)
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.sm)) {
                        MetricTile(
                            title = L10n.text("请求次数", "Requests"),
                            value = filtered.size.toString(),
                            detail = L10n.text("完整 $succeededCount", "$succeededCount succeeded"),
                            modifier = Modifier.weight(1f)
                        )
                        MetricTile(
                            title = L10n.text("已知 Token", "Known Tokens"),
                            value = compactTokens(totalPrompt + totalCompletion),
                            detail = if (totalCached > 0) L10n.text("缓存 ${compactTokens(totalCached)}", "Cached ${compactTokens(totalCached)}") else null,
                            modifier = Modifier.weight(1f)
                        )
                    }
                }
            }

            item {
                Text(
                    text = L10n.text("最近请求记录", "Recent Requests"),
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold)
                )
            }

            if (filtered.isEmpty()) {
                item {
                    Text(
                        text = L10n.text("当前周期暂无请求记录。", "No request records in this period."),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                items(filtered.take(100), key = { it.id }) { rec ->
                    RequestLogRow(rec)
                    HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.45f))
                }
            }
        }
    }
}

@Composable
private fun MetricTile(
    title: String,
    value: String,
    detail: String?,
    modifier: Modifier = Modifier
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        modifier = modifier
    ) {
        Column(
            modifier = Modifier.padding(DS.Spacing.md),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = value,
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold)
            )
            if (!detail.isNullOrEmpty()) {
                Text(
                    text = detail,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary
                )
            }
        }
    }
}

@Composable
private fun RequestLogRow(rec: RequestRecordItem) {
    val dateStr = remember(rec.startedAtEpochMs) {
        DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
            .format(Date(rec.startedAtEpochMs))
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = "${rec.providerName} · ${rec.modelDisplayName}",
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                modifier = Modifier.weight(1f)
            )
            Text(
                text = rec.status.title,
                style = MaterialTheme.typography.labelSmall,
                color = when (rec.status) {
                    RequestStatus.SUCCEEDED -> MaterialTheme.colorScheme.primary
                    RequestStatus.FAILED -> MaterialTheme.colorScheme.error
                    else -> MaterialTheme.colorScheme.onSurfaceVariant
                }
            )
        }
        val metrics = buildList {
            add(rec.kind.title)
            rec.firstOutputMs?.let { add("TTFT ${it}ms") }
            rec.durationMs?.let { add("${String.format(Locale.US, "%.2fs", it / 1000.0)}") }
            rec.tokensPerSecond?.let { add("${String.format(Locale.US, "%.1f", it)} tok/s") }
            if (rec.promptTokens != null || rec.completionTokens != null) {
                add("${rec.promptTokens ?: 0}→${rec.completionTokens ?: 0} tok")
            }
            rec.httpStatus?.let { add("HTTP $it") }
            add(dateStr)
        }
        Text(
            text = metrics.joinToString(" · "),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

private fun compactTokens(count: Int): String = when {
    count >= 1_000_000 -> String.format(Locale.US, "%.1fM", count / 1_000_000.0)
    count >= 1_000 -> String.format(Locale.US, "%.1fK", count / 1_000.0)
    else -> count.toString()
}
