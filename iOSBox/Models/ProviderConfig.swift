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
    private var restoredCredentialID: UUID?

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
        notes: String = "",
        isRestored: Bool = false
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
        self.restoredCredentialID = isRestored ? UUID() : nil
    }

    // Backup IDs preserve conversation references. Only a locally generated ID can
    // select a new Keychain namespace when that backup recreates a missing provider.
    var credentialID: UUID { restoredCredentialID ?? id }

    var isRestoredFromBackup: Bool { restoredCredentialID != nil }

    var apiKey: String { KeychainService.shared.loadAPIKey(for: credentialID) }

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

    var hasAuthentication: Bool {
        KeychainService.shared.hasAPIKey(for: credentialID) || resolvedCustomHeaders.contains {
            $0.isEnabled && CustomHeader.looksSensitive($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasConfiguredChatAPI: Bool {
        guard !isDeleted, isEnabled,
              let url = try? EndpointResolver.chatEndpoint(baseURL: baseURL, protocolType: protocolType),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.lowercased() != "api.example.com",
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: baseURL) else { return false }
        return NetworkLocation.isLocalOrPrivate(baseURL: baseURL) || hasAuthentication
    }

    var isReadyForChat: Bool { hasConfiguredChatAPI && !enabledModels.isEmpty }

    static func readyTargets(in providers: [ProviderConfig]) -> [ResolvedModelTarget] {
        providers.filter(\.hasConfiguredChatAPI).flatMap { provider in provider.enabledModels.map { provider.makeTarget(for: $0) } }
    }

    var enabledModels: [ModelSpec] {
        models.filter(\.isSelectable)
    }

    @MainActor
    func transmissionCheck(for modelID: String) -> @MainActor @Sendable () throws -> Void {
        let address = baseURL
        let protocolName = protocolRaw
        return { [weak self] in
            guard let self, self.modelContext != nil, !self.isDeleted, self.isEnabled,
                  self.baseURL == address, self.protocolRaw == protocolName,
                  self.enabledModels.contains(where: { $0.id == modelID }) else {
                throw LLMError.unavailableModel
            }
        }
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
                account: KeychainService.headerAccount(providerID: credentialID, headerID: header.id)
            )
            return resolved
        }
    }

    /// Adds a header; secret values go to the Keychain and are never written to the database.
    @discardableResult
    func addCustomHeader(key: String, value: String, isSecret: Bool, save: (String, String) -> Bool = { KeychainService.shared.saveSecret($0, account: $1) }) -> Bool {
        var header = CustomHeader(key: key, value: value, isSecret: isSecret)
        if isSecret {
            guard save(value, KeychainService.headerAccount(providerID: credentialID, headerID: header.id)) else { return false }
            header.value = ""
        }
        customHeaders = customHeaders + [header]
        return true
    }

    func removeCustomHeader(id headerID: UUID) {
        guard let header = customHeaders.first(where: { $0.id == headerID }) else { return }
        if header.isSecret {
            KeychainService.shared.deleteSecret(
                account: KeychainService.headerAccount(providerID: credentialID, headerID: headerID)
            )
        }
        customHeaders = customHeaders.filter { $0.id != headerID }
    }

    /// Removes every Keychain item owned by this provider (API keys + secret headers) and connection overrides.
    func deleteAllSecrets() {
        KeychainService.shared.deleteAPIKey(for: credentialID)
        for header in customHeaders where header.isSecret {
            KeychainService.shared.deleteSecret(
                account: KeychainService.headerAccount(providerID: credentialID, headerID: header.id)
            )
        }
        ProviderConnectionSettingsStore.shared.remove(for: id)
    }

    var extraAPIKeys: [String] {
        KeychainService.shared.loadExtraAPIKeys(for: credentialID)
    }

    var allAPIKeys: [String] {
        KeychainService.shared.loadAllAPIKeys(for: credentialID)
    }

    /// 0 means automatic (45s standard / 120s reasoning & LAN); > 0 overrides stream idle timeout in seconds.
    var idleTimeoutSeconds: Int {
        get { ProviderConnectionSettingsStore.shared.idleTimeoutSeconds(for: id) }
        set {
            ProviderConnectionSettingsStore.shared.setIdleTimeoutSeconds(newValue, for: id)
            updatedAt = Date()
        }
    }

    var customIdleTimeout: TimeInterval? {
        let secs = idleTimeoutSeconds
        return secs > 0 ? TimeInterval(secs) : nil
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
                account: KeychainService.headerAccount(providerID: credentialID, headerID: header.id)
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

/// Persists optional per-provider connection overrides (such as custom stream idle timeouts)
/// without modifying frozen SwiftData SQLite entity columns.
final class ProviderConnectionSettingsStore: @unchecked Sendable {
    static let shared = ProviderConnectionSettingsStore()
    static let storageKey = "com.iosbox.providerConnectionSettings.v1"
    static let supportedTimeoutOptions = [0, 30, 60, 120, 300]

    struct Settings: Codable, Equatable {
        var idleTimeoutSeconds: Int = 0
    }

    private let lock = NSLock()
    private var entries: [String: Settings]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Settings].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    func idleTimeoutSeconds(for providerID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let val = entries[providerID.uuidString]?.idleTimeoutSeconds ?? 0
        return val > 0 ? min(max(val, 5), 3600) : 0
    }

    func setIdleTimeoutSeconds(_ seconds: Int, for providerID: UUID) {
        let normalized = seconds > 0 ? min(max(seconds, 5), 3600) : 0
        lock.lock()
        if normalized == 0 {
            entries.removeValue(forKey: providerID.uuidString)
        } else {
            entries[providerID.uuidString] = Settings(idleTimeoutSeconds: normalized)
        }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
    }

    func remove(for providerID: UUID) {
        lock.lock()
        let removed = entries.removeValue(forKey: providerID.uuidString) != nil
        let snapshot = entries
        lock.unlock()
        if removed {
            persist(snapshot)
        }
    }

    static func timeoutLabel(for seconds: Int) -> String {
        if seconds <= 0 {
            return String(localized: "自动（常规 45s / 推理与本地 120s）")
        }
        return String(localized: "\(seconds) 秒")
    }

    private func persist(_ snapshot: [String: Settings]) {
        if snapshot.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
