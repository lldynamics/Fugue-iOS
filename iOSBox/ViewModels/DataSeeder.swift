import Foundation
import SwiftData

@MainActor
enum DataSeeder {
    private static let seededKey = "com.iosbox.hasSeededInitialData.v1"
    private static let presetsSeededKey = "com.iosbox.hasSeededPresets.v1"

    static func seedIfNeeded(context: ModelContext) {
        // Seed presets once per install, so deleting all of them doesn't bring them back.
        if !UserDefaults.standard.bool(forKey: presetsSeededKey) {
            let existingPresets = (try? context.fetchCount(FetchDescriptor<AssistantPreset>())) ?? 0
            if existingPresets == 0 {
                for preset in AssistantPreset.defaultPresets {
                    context.insert(preset)
                }
            }
            UserDefaults.standard.set(true, forKey: presetsSeededKey)
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
            UserDefaults.standard.set(true, forKey: seededKey)
        }

        // Move credentials saved in plaintext custom headers (pre-secret-header data) into the Keychain.
        if let providers = try? context.fetch(FetchDescriptor<ProviderConfig>()) {
            for provider in providers {
                provider.moveSensitiveHeadersToKeychain()
            }
        }

        try? context.save()
    }
}
