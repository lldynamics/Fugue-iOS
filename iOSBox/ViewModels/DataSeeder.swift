import Foundation
import SwiftData

@MainActor
enum DataSeeder {
    private static let seededKey = "com.iosbox.hasSeededInitialData.v1"

    static func seedIfNeeded(context: ModelContext) {
        let presetDescriptor = FetchDescriptor<AssistantPreset>()
        let existingPresets = (try? context.fetchCount(presetDescriptor)) ?? 0
        if existingPresets == 0 {
            for preset in AssistantPreset.defaultPresets {
                context.insert(preset)
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
            UserDefaults.standard.set(true, forKey: seededKey)
        }

        try? context.save()
    }
}
