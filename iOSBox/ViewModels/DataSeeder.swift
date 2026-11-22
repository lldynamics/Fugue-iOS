import Foundation
import SwiftData

@MainActor
enum DataSeeder {
    nonisolated private static let seededKey = "com.iosbox.hasSeededInitialData.v1"
    nonisolated private static let presetsSeededKey = "com.iosbox.hasSeededPresets.v1"
    nonisolated private static let dailyPresetsSeededKey = "com.iosbox.hasSeededDailyPresets.v2"

    nonisolated static func resetSeedFlagsForRebuiltStore(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: seededKey)
        defaults.removeObject(forKey: presetsSeededKey)
        defaults.removeObject(forKey: dailyPresetsSeededKey)
    }

    static func seedIfNeeded(context: ModelContext) {
        let canPersistFlags = PersistenceController.canCommitUserData(in: context)

        // Seed presets once per install, so deleting all of them doesn't bring them back.
        if !UserDefaults.standard.bool(forKey: presetsSeededKey) {
            let existingPresets = (try? context.fetchCount(FetchDescriptor<AssistantPreset>())) ?? 0
            if existingPresets == 0 {
                for preset in AssistantPreset.defaultPresets {
                    context.insert(preset)
                }
            }
            if canPersistFlags {
                UserDefaults.standard.set(true, forKey: presetsSeededKey)
                UserDefaults.standard.set(true, forKey: dailyPresetsSeededKey)
            }
        } else if !UserDefaults.standard.bool(forKey: dailyPresetsSeededKey) {
            // Additive migration for existing installs upgrading to Stage C everyday presets.
            let existing = (try? context.fetch(FetchDescriptor<AssistantPreset>())) ?? []
            let existingIDs = Set(existing.map(\.id))
            let existingNames = Set(existing.map(\.name))
            for preset in AssistantPreset.dailyLifePresets {
                if !existingIDs.contains(preset.id) && !existingNames.contains(preset.name) {
                    context.insert(preset)
                }
            }
            if canPersistFlags {
                UserDefaults.standard.set(true, forKey: dailyPresetsSeededKey)
            }
        }

        if !UserDefaults.standard.bool(forKey: seededKey) {
            let providerDescriptor = FetchDescriptor<ProviderConfig>()
            let existingProviders = (try? context.fetchCount(providerDescriptor)) ?? 0
            if existingProviders == 0 {
                let starterIDs = ["deepseek", "openrouter", "anthropic", "gemini"]
                for (idx, templateID) in starterIDs.enumerated() {
                    if let tpl = ProviderTemplate.catalog.first(where: { $0.id == templateID }) {
                        let provider = ProviderConfig(
                            name: tpl.name,
                            protocolType: tpl.protocolType,
                            baseURL: tpl.baseURL,
                            iconSymbol: tpl.iconSymbol,
                            accentHex: tpl.accentHex,
                            isEnabled: true,
                            sortOrder: idx,
                            models: tpl.suggestedModels,
                            notes: tpl.note
                        )
                        context.insert(provider)
                    }
                }
            }
            if canPersistFlags {
                UserDefaults.standard.set(true, forKey: seededKey)
            }
        }

        // Move credentials saved in plaintext custom headers (pre-secret-header data) into the Keychain.
        for provider in (try? context.fetch(FetchDescriptor<ProviderConfig>())) ?? [] {
            provider.moveSensitiveHeadersToKeychain()
            updateStarterModels(in: provider)
        }
        try? context.save()
    }

    static func updateStarterModels(in provider: ProviderConfig) {
        guard let template = ProviderTemplate.matching(baseURL: provider.baseURL, protocolType: provider.protocolType),
              let original = previousModels[template.id] else { return }
        let saved = provider.models
        let previouslyUpgraded = ProviderConfig.deduplicated(template.suggestedModels + original)
        guard saved == original || saved == previouslyUpgraded else { return }
        // Keep old IDs for history, but offer the current defaults for new conversations.
        let currentIDs = Set(template.suggestedModels.map(\.id))
        provider.models = previouslyUpgraded.map { model in
            var updated = model
            if !currentIDs.contains(model.id) {
                updated.catalogStatus = .unlisted
                updated.retiredStarterDefault = true
                updated.displayName = model.id
            }
            return updated
        }
        if template.id == "deepseek", provider.notes == String(localized: "官方直连，支持 DeepSeek-V3 与 DeepSeek-R1 深度思考链") {
            provider.notes = template.note
        }
    }

    // Exact defaults shipped before live discovery. Custom names, flags, prices and favorites break the match.
    private static let previousModels: [String: [ModelSpec]] = [
        "deepseek": [ModelSpec(id: "deepseek-chat", displayName: "DeepSeek V3", supportsVision: false, supportsReasoning: false),
                     ModelSpec(id: "deepseek-reasoner", displayName: "DeepSeek R1", supportsVision: false, supportsReasoning: true)],
        "openrouter": [ModelSpec(id: "openai/gpt-4.1", displayName: "GPT-4.1", supportsVision: true, supportsReasoning: false),
                       ModelSpec(id: "anthropic/claude-sonnet-4", displayName: "Claude Sonnet 4", supportsVision: true, supportsReasoning: true),
                       ModelSpec(id: "google/gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsVision: true, supportsReasoning: true),
                       ModelSpec(id: "deepseek/deepseek-r1", displayName: "DeepSeek R1", supportsVision: false, supportsReasoning: true)],
        "siliconflow": [ModelSpec(id: "deepseek-ai/DeepSeek-R1", displayName: "DeepSeek-R1", supportsVision: false, supportsReasoning: true),
                        ModelSpec(id: "deepseek-ai/DeepSeek-V3", displayName: "DeepSeek-V3", supportsVision: false, supportsReasoning: false),
                        ModelSpec(id: "Qwen/Qwen2.5-VL-72B-Instruct", displayName: "Qwen2.5-VL-72B", supportsVision: true, supportsReasoning: false)],
        "openai": [ModelSpec(id: "gpt-4.1", displayName: "GPT-4.1", supportsVision: true, supportsReasoning: false),
                   ModelSpec(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", supportsVision: true, supportsReasoning: false),
                   ModelSpec(id: "o4-mini", displayName: "o4-mini", supportsVision: true, supportsReasoning: true)],
        "anthropic": [ModelSpec(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", supportsVision: true, supportsReasoning: true),
                      ModelSpec(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", supportsVision: true, supportsReasoning: true),
                      ModelSpec(id: "claude-haiku-4-5-20251001", displayName: "Claude Haiku 4.5", supportsVision: true, supportsReasoning: true)],
        "gemini": [ModelSpec(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsVision: true, supportsReasoning: true),
                   ModelSpec(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", supportsVision: true, supportsReasoning: true)]
    ]
}
