package com.iosbox.app.core.storage

import com.iosbox.app.core.model.CustomHeader
import com.iosbox.app.core.model.DefaultPresets
import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.ProviderTemplate
import com.iosbox.app.core.security.SecretStore
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class DataSeeder(
    private val db: FugueDatabase,
    private val preferences: AppPreferences,
    private val secretStore: SecretStore
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; explicitNulls = false }

    suspend fun seedIfNeeded() {
        val prefs = preferences.state.value
        val now = System.currentTimeMillis()

        if (!prefs.presetsSeeded) {
            if (db.assistantPresetDao().count() == 0) {
                val entities = DefaultPresets.items.map { p ->
                    AssistantPresetEntity(
                        id = p.id,
                        name = p.name,
                        iconEmoji = p.iconEmoji,
                        subtitle = p.subtitle,
                        systemPrompt = p.systemPrompt,
                        temperature = p.temperature,
                        useCustomTemperature = p.useCustomTemperature,
                        topP = p.topP,
                        maxOutputTokens = p.maxOutputTokens,
                        contextMessageLimit = p.contextMessageLimit,
                        enableThinking = p.enableThinking,
                        thinkingBudgetTokens = p.thinkingBudgetTokens,
                        isBuiltIn = p.isBuiltIn,
                        sortOrder = p.sortOrder,
                        knowledgeVolumeIDsJson = null,
                        createdAtEpochMs = now
                    )
                }
                db.assistantPresetDao().upsertAll(entities)
            }
            preferences.markPresetsSeeded()
        }

        if (!prefs.providersSeeded) {
            if (db.providerDao().count() == 0) {
                val starterIDs = listOf("deepseek", "openrouter", "anthropic", "gemini")
                val entities = starterIDs.mapIndexedNotNull { idx, tplID ->
                    val tpl = ProviderTemplate.catalog.firstOrNull { it.id == tplID } ?: return@mapIndexedNotNull null
                    ProviderEntity(
                        id = stableStarterProviderId(tplID),
                        name = tpl.name,
                        protocolRaw = tpl.protocolType.rawValue,
                        baseURL = tpl.baseURL,
                        iconSymbol = tpl.iconSymbol,
                        accentHex = tpl.accentHex,
                        isEnabled = true,
                        sortOrder = idx,
                        modelsJson = json.encodeToString(ModelSpec.deduplicated(tpl.suggestedModels)),
                        headersJson = "[]",
                        notes = tpl.note,
                        createdAtEpochMs = now,
                        updatedAtEpochMs = now
                    )
                }
                db.providerDao().upsertAll(entities)
            }
            preferences.markProvidersSeeded()
        }

        // Migrate any sensitive headers to SecretStore & recover interrupted streams cleanly on launch.
        val existingProviders = db.providerDao().getAll()
        for (provider in existingProviders) {
            val headers = runCatching { json.decodeFromString<List<CustomHeader>>(provider.headersJson) }.getOrNull() ?: emptyList()
            var changed = false
            val secured = headers.map { h ->
                if (!h.isSecret && h.value.isNotEmpty() && CustomHeader.looksSensitive(h.key)) {
                    if (secretStore.saveSecret(h.value, SecretStore.headerAccount(provider.id, h.id))) {
                        changed = true
                        h.copy(isSecret = true, value = "")
                    } else {
                        h
                    }
                } else {
                    h
                }
            }
            if (changed) {
                db.providerDao().upsert(provider.copy(headersJson = json.encodeToString(secured), updatedAtEpochMs = now))
            }
        }

        db.chatMessageDao().recoverInterruptedStreams(
            L10n.text("连接已中断，请重试。", "Connection was interrupted. Please retry.")
        )
        db.requestRecordDao().recoverRunningRecords()
    }

    private fun stableStarterProviderId(templateId: String): String = when (templateId) {
        "deepseek" -> "10000000-0000-4000-8000-000000000001"
        "openrouter" -> "10000000-0000-4000-8000-000000000002"
        "anthropic" -> "10000000-0000-4000-8000-000000000003"
        "gemini" -> "10000000-0000-4000-8000-000000000004"
        else -> java.util.UUID.randomUUID().toString().uppercase()
    }
}
