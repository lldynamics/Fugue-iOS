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

    @discardableResult
    func saveAPIKey(_ rawKey: String, for providerID: UUID) -> Bool {
        saveSecret(rawKey, account: providerID.uuidString)
    }

    func loadAPIKey(for providerID: UUID) -> String {
        loadSecret(account: providerID.uuidString)
    }

    func hasAPIKey(for providerID: UUID) -> Bool {
        !loadAPIKey(for: providerID).isEmpty
    }

    func deleteAPIKey(for providerID: UUID) {
        deleteSecret(account: providerID.uuidString)
    }

    // MARK: - Secret custom header values

    static func headerAccount(providerID: UUID, headerID: UUID) -> String {
        "\(providerID.uuidString)/header/\(headerID.uuidString)"
    }

    // MARK: - Generic secrets

    /// Saves (or, for an empty value, deletes) a secret. Returns false if the Keychain rejected it.
    @discardableResult
    func saveSecret(_ rawValue: String, account: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            let ok = status == errSecSuccess || status == errSecItemNotFound
            updateCache(account: account, value: ok ? "" : nil)
            if !ok { logger.error("Keychain delete failed: \(status)") }
            return ok
        }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        var status = updateStatus
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        let ok = status == errSecSuccess
        updateCache(account: account, value: ok ? trimmed : nil)
        if !ok { logger.error("Keychain save failed: \(status)") }
        return ok
    }

    func loadSecret(account: String) -> String {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let value = (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            updateCache(account: account, value: value)
            return value
        case errSecItemNotFound:
            updateCache(account: account, value: "")
            return ""
        default:
            // e.g. errSecInteractionNotAllowed before first unlock: don't cache, retry next time.
            logger.error("Keychain read failed: \(status)")
            return ""
        }
    }

    func deleteSecret(account: String) {
        updateCache(account: account, value: nil)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func updateCache(account: String, value: String?) {
        lock.lock()
        cache[account] = value
        lock.unlock()
    }
}
