import Foundation
import Security
import os

final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private let serviceName = "com.iosbox.app.provider-keys"
    private let lock = NSLock()
    /// Only holds values that were confirmed by the Keychain (successful read/write or a
    /// definite "not found"), so a transient failure is never cached as "no key".
    private var cache: [String: String] = [:]
    private let logger = Logger(subsystem: "com.iosbox.app", category: "Keychain")

    private init() {}

    // MARK: - Provider API keys (account = provider UUID, unchanged for existing installs)

    static func extraKeysAccount(providerID: UUID) -> String {
        "\(providerID.uuidString)/extra-keys"
    }

    static func maskedKeyPreview(_ rawKey: String) -> String {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 8 {
            return String(repeating: "•", count: max(4, trimmed.count))
        }
        let prefix = String(trimmed.prefix(4))
        let suffix = String(trimmed.suffix(4))
        return "\(prefix)••••\(suffix)"
    }

    @discardableResult
    func saveAPIKey(_ rawKey: String, for providerID: UUID) -> Bool {
        saveSecret(rawKey, account: providerID.uuidString)
    }

    func loadAPIKey(for providerID: UUID) -> String {
        loadSecret(account: providerID.uuidString)
    }

    func loadExtraAPIKeys(for providerID: UUID) -> [String] {
        let raw = loadSecret(account: Self.extraKeysAccount(providerID: providerID))
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.compactMap { item in
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { return nil }
            return t
        }
    }

    @discardableResult
    func saveExtraAPIKeys(_ keys: [String], for providerID: UUID) -> Bool {
        guard let value = Self.encodedExtraAPIKeys(keys) else { return false }
        return saveSecret(value, account: Self.extraKeysAccount(providerID: providerID))
    }

    static func encodedExtraAPIKeys(_ keys: [String]) -> String? {
        var seen = Set<String>()
        let cleaned = keys.compactMap { item -> String? in
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted else { return nil }
            return t
        }
        guard !cleaned.isEmpty else { return "" }
        return (try? JSONEncoder().encode(cleaned)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func loadAllAPIKeys(for providerID: UUID) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for candidate in [loadAPIKey(for: providerID)] + loadExtraAPIKeys(for: providerID) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    func hasAPIKey(for providerID: UUID) -> Bool {
        !loadAllAPIKeys(for: providerID).isEmpty
    }

    func deleteAPIKey(for providerID: UUID) {
        deleteSecret(account: providerID.uuidString)
        deleteSecret(account: Self.extraKeysAccount(providerID: providerID))
    }

    // MARK: - Secret custom header values

    static func headerAccount(providerID: UUID, headerID: UUID) -> String {
        "\(providerID.uuidString)/header/\(headerID.uuidString)"
    }

    // MARK: - Generic secrets

    /// Insert-only restore preserves a local credential even during an unavailable read or a concurrent write.
    func restoreSecretIfMissing(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(trimmed.utf8)
        ]
        lock.lock()
        let status = SecItemAdd(item as CFDictionary, nil)
        cache[account] = status == errSecSuccess ? trimmed : nil
        lock.unlock()
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    /// Saves (or, for an empty value, deletes) a secret. Returns false if the Keychain rejected it.
    @discardableResult
    func saveSecret(_ rawValue: String, account: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if cache[account] == trimmed {
            lock.unlock()
            return true
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let ok: Bool
        let status: OSStatus
        if trimmed.isEmpty || trimmed.data(using: .utf8) == nil {
            status = SecItemDelete(baseQuery as CFDictionary)
            ok = status == errSecSuccess || status == errSecItemNotFound
            cache[account] = ok ? "" : nil
        } else {
            let data = Data(trimmed.utf8)
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecItemNotFound {
                var addQuery = baseQuery
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(addQuery as CFDictionary, nil)
            } else {
                status = updateStatus
            }
            ok = status == errSecSuccess
            cache[account] = ok ? trimmed : nil
        }
        lock.unlock()

        if !ok {
            if trimmed.isEmpty {
                logger.error("Keychain delete failed: \(status)")
            } else {
                logger.error("Keychain save failed: \(status)")
            }
        } else {
            NotificationCenter.default.post(name: .init("IOSBoxCredentialsChanged"), object: nil)
        }
        return ok
    }

    func loadSecret(account: String) -> String {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String
        switch status {
        case errSecSuccess:
            value = (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            cache[account] = value
        case errSecItemNotFound:
            value = ""
            cache[account] = ""
        default:
            // e.g. errSecInteractionNotAllowed before first unlock: don't cache, retry next time.
            value = ""
        }
        lock.unlock()
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain read failed: \(status)")
        }
        return value
    }

    func deleteSecret(account: String) {
        lock.lock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        let ok = status == errSecSuccess || status == errSecItemNotFound
        cache[account] = ok ? "" : nil
        lock.unlock()
        if !ok {
            logger.error("Keychain delete failed: \(status)")
        }
        NotificationCenter.default.post(name: .init("IOSBoxCredentialsChanged"), object: nil)
    }
}

/// Coalesces rapid keystrokes in API key fields so typing does not write to the Keychain
/// and republish App Group credentials on every character, while guaranteeing immediate
/// persistence on paste, focus loss, verification, or view dismissal.
@MainActor
final class APIKeySaveCoordinator {
    private let saveHandler: (String) -> Bool
    private let delay: Duration
    private var pendingTask: Task<Void, Never>?
    private(set) var pendingValue: String?
    private(set) var lastSavedValue: String

    var onResult: ((Bool, String) -> Void)?

    init(
        initialValue: String = "",
        delay: Duration = .milliseconds(350),
        saveHandler: @escaping (String) -> Bool
    ) {
        self.lastSavedValue = initialValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.delay = delay
        self.saveHandler = saveHandler
    }

    var hasUnsavedChanges: Bool {
        pendingValue != nil
    }

    func resetInitial(_ loadedValue: String) {
        pendingTask?.cancel()
        pendingTask = nil
        pendingValue = nil
        lastSavedValue = loadedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scheduleSave(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTask?.cancel()
        pendingTask = nil
        guard trimmed != lastSavedValue else {
            pendingValue = nil
            return
        }
        pendingValue = rawValue
        let wait = delay
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: wait)
            } catch {
                return
            }
            _ = self?.flushNow()
        }
    }

    @discardableResult
    func flushNow(overrideValue: String? = nil) -> Bool? {
        pendingTask?.cancel()
        pendingTask = nil
        guard let raw = overrideValue ?? pendingValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if overrideValue == nil && trimmed == lastSavedValue {
            pendingValue = nil
            return true
        }
        pendingValue = nil
        let ok = saveHandler(trimmed)
        if ok {
            lastSavedValue = trimmed
        } else {
            pendingValue = raw
        }
        onResult?(ok, trimmed)
        return ok
    }
}
