import Foundation
import SwiftData

@Model
final class ProviderConfig {
    @Attribute(.unique) var id: UUID
    var name: String
    var protocolRaw: String
    var baseURL: String
    var iconSymbol: String
    var accentHex: String
    var isEnabled: Bool
    var sortOrder: Int
    var modelsData: Data
    var headersData: Data
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        protocolType: APIProtocolType,
        baseURL: String,
        iconSymbol: String = "server.rack",
        accentHex: String = "#3F6EF6",
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        models: [ModelSpec] = [],
        customHeaders: [CustomHeader] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.protocolRaw = protocolType.rawValue
        self.baseURL = baseURL
        self.iconSymbol = iconSymbol
        self.accentHex = accentHex
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.modelsData = (try? JSONEncoder().encode(Self.deduplicated(models))) ?? Data()
        self.headersData = (try? JSONEncoder().encode(customHeaders)) ?? Data()
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var protocolType: APIProtocolType {
        get { APIProtocolType(rawValue: protocolRaw) ?? .openAICompatible }
        set {
            protocolRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    /// Always unique by `id`: duplicates (from older data or remote lists) would crash
    /// `Dictionary(uniqueKeysWithValues:)` and confuse `ForEach` identity.
    var models: [ModelSpec] {
        get {
            guard !modelsData.isEmpty else { return [] }
            let decoded = (try? JSONDecoder().decode([ModelSpec].self, from: modelsData)) ?? []
            return Self.deduplicated(decoded)
        }
        set {
            modelsData = (try? JSONEncoder().encode(Self.deduplicated(newValue))) ?? Data()
            updatedAt = Date()
        }
    }

    /// Keeps the first occurrence of each model ID, preserving order.
    static func deduplicated(_ specs: [ModelSpec]) -> [ModelSpec] {
        var seen = Set<String>()
        return specs.filter { seen.insert($0.id).inserted }
    }

    var enabledModels: [ModelSpec] {
        models.filter(\.isEnabled)
    }

    var customHeaders: [CustomHeader] {
        get {
            guard !headersData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([CustomHeader].self, from: headersData)) ?? []
        }
        set {
            headersData = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }

    /// Headers ready to send: secret values are loaded from the Keychain.
    var resolvedCustomHeaders: [CustomHeader] {
        customHeaders.map { header in
            guard header.isSecret else { return header }
            var resolved = header
            resolved.value = KeychainService.shared.loadSecret(
                account: KeychainService.headerAccount(providerID: id, headerID: header.id)
            )
            return resolved
        }
    }

    /// Adds a header; secret values go to the Keychain and are never written to the database.
    func addCustomHeader(key: String, value: String, isSecret: Bool) {
        var header = CustomHeader(key: key, value: value, isSecret: isSecret)
        if isSecret {
            KeychainService.shared.saveSecret(
                value,
                account: KeychainService.headerAccount(providerID: id, headerID: header.id)
            )
            header.value = ""
        }
        customHeaders = customHeaders + [header]
    }

    func removeCustomHeader(id headerID: UUID) {
        guard let header = customHeaders.first(where: { $0.id == headerID }) else { return }
        if header.isSecret {
            KeychainService.shared.deleteSecret(
                account: KeychainService.headerAccount(providerID: id, headerID: headerID)
            )
        }
        customHeaders = customHeaders.filter { $0.id != headerID }
    }

    /// Removes every Keychain item owned by this provider (API key + secret headers).
    func deleteAllSecrets() {
        KeychainService.shared.deleteAPIKey(for: id)
        for header in customHeaders where header.isSecret {
            KeychainService.shared.deleteSecret(
                account: KeychainService.headerAccount(providerID: id, headerID: header.id)
            )
        }
    }

    /// One-time hardening for data saved before secret headers existed: credentials stored
    /// in plaintext headers (e.g. `Authorization`) are moved into the Keychain.
    /// Returns true if anything changed.
    @discardableResult
    func moveSensitiveHeadersToKeychain() -> Bool {
        var changed = false
        let updated = customHeaders.map { header -> CustomHeader in
            guard !header.isSecret, !header.value.isEmpty, CustomHeader.looksSensitive(header.key) else {
                return header
            }
            let saved = KeychainService.shared.saveSecret(
                header.value,
                account: KeychainService.headerAccount(providerID: id, headerID: header.id)
            )
            guard saved else { return header } // keep plaintext rather than lose the credential
            var secured = header
            secured.isSecret = true
            secured.value = ""
            changed = true
            return secured
        }
        if changed {
            customHeaders = updated
        }
        return changed
    }

    func makeTarget(for spec: ModelSpec) -> ResolvedModelTarget {
        ResolvedModelTarget(
            providerID: id,
            providerName: name,
            protocolType: protocolType,
            modelID: spec.id,
            modelDisplayName: spec.displayName,
            accentHex: accentHex,
            supportsVision: spec.supportsVision,
            supportsReasoning: spec.supportsReasoning
        )
    }
}
