import Foundation
import SwiftData

/// The result of probing a draft. Verification performs no writes. Only the user's
/// save action may create an account or replace the explicitly selected account's key.
@MainActor
struct VerifiedProviderConnection {
    let draft: ProviderSetupDraft
    let chosenModel: ModelSpec
    let fetched: [ModelSpec]
    let updateAccountID: UUID?
    let previousConnection: SharedConnection?
    var additionalEnabledModelIDs: Set<String> = []

    static func matches(_ provider: ProviderConfig, draft: ProviderSetupDraft) -> Bool {
        guard !provider.isDeleted, provider.protocolType == draft.protocolType,
              let left = try? EndpointResolver.chatEndpoint(baseURL: provider.baseURL, protocolType: provider.protocolType),
              let right = try? EndpointResolver.chatEndpoint(baseURL: draft.baseURL, protocolType: draft.protocolType),
              let leftDirectory = try? EndpointResolver.modelsEndpoint(baseURL: provider.baseURL, protocolType: provider.protocolType),
              let rightDirectory = try? EndpointResolver.modelsEndpoint(baseURL: draft.baseURL, protocolType: draft.protocolType) else { return false }
        return left == right && leftDirectory == rightDirectory
    }

    func save(in context: ModelContext) throws -> (ProviderConfig, ResolvedModelTarget) {
        let accounts = try context.fetch(FetchDescriptor<ProviderConfig>())
        let current: ProviderConfig?
        if let updateAccountID {
            guard let account = accounts.first(where: { $0.id == updateAccountID }), Self.matches(account, draft: draft),
                  SystemIntegration.connection(account) == previousConnection else {
                throw LLMError.apiError(String(localized: "连接配置已更改，请重新验证。"))
            }
            current = account
        } else {
            current = nil
        }
        let cleanName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = LLMClient.sanitizedAPIKey(draft.apiKey)
        let name = cleanName.isEmpty ? "Provider" : cleanName
        var models = ProviderModelCatalog.merging(fetched.isEmpty ? draft.suggestedModels : fetched,
                                                  with: current?.models ?? [], choosing: chosenModel.id,
                                                  fromAPI: !fetched.isEmpty)
        if !additionalEnabledModelIDs.isEmpty {
            for idx in models.indices where additionalEnabledModelIDs.contains(models[idx].id) && models[idx].catalogStatus != .unlisted {
                models[idx].isEnabled = true
            }
        }
        if !draft.manualModelID.isEmpty && !fetched.contains(where: { $0.id == chosenModel.id }),
           let index = models.firstIndex(where: { $0.id == chosenModel.id }) {
            models[index].catalogStatus = .manual
        }
        let provider: ProviderConfig
        if let current {
            provider = current
        } else {
            var availableName = name
            var suffix = 2
            let usedNames = Set(accounts.map(\.name))
            while usedNames.contains(availableName) {
                availableName = "\(name) (\(suffix))"
                suffix += 1
            }
            provider = ProviderConfig(name: availableName, protocolType: draft.protocolType, baseURL: cleanURL,
                                      iconSymbol: draft.iconSymbol, accentHex: draft.accentHex, isEnabled: true,
                                      sortOrder: Int(Date().timeIntervalSince1970), models: [])
        }
        let oldModels = provider.models
        let oldEnabled = provider.isEnabled
        let oldUpdated = provider.updatedAt
        let oldKey = previousConnection?.apiKey ?? ""
        if !cleanKey.isEmpty && cleanKey != oldKey {
            guard KeychainService.shared.saveAPIKey(cleanKey, for: provider.credentialID) else {
                throw LLMError.apiError(String(localized: "钥匙串保存失败，请重试。"))
            }
        }
        provider.models = models
        provider.isEnabled = true
        if current == nil { context.insert(provider) }
        do {
            try context.save()
        } catch {
            if current == nil { context.delete(provider) }
            else {
                provider.models = oldModels
                provider.isEnabled = oldEnabled
                provider.updatedAt = oldUpdated
            }
            if !cleanKey.isEmpty && cleanKey != oldKey {
                if oldKey.isEmpty { KeychainService.shared.deleteAPIKey(for: provider.credentialID) }
                else { KeychainService.shared.saveAPIKey(oldKey, for: provider.credentialID) }
            }
            throw error
        }
        return (provider, provider.makeTarget(for: provider.enabledModels.first { $0.id == chosenModel.id } ?? chosenModel))
    }
}
