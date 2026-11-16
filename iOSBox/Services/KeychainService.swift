import Foundation
import Security

final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private let serviceName = "com.iosbox.app.provider-keys"
    private let lock = NSLock()
    private var cache: [UUID: String] = [:]

    private init() {}

    func saveAPIKey(_ rawKey: String, for providerID: UUID) {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        cache[providerID] = trimmed
        lock.unlock()

        let account = providerID.uuidString
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func loadAPIKey(for providerID: UUID) -> String {
        lock.lock()
        if let cached = cache[providerID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let account = providerID.uuidString
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
        if status == errSecSuccess,
           let data = result as? Data,
           let decoded = String(data: data, encoding: .utf8) {
            value = decoded
        } else {
            value = ""
        }

        lock.lock()
        cache[providerID] = value
        lock.unlock()
        return value
    }

    func hasAPIKey(for providerID: UUID) -> Bool {
        !loadAPIKey(for: providerID).isEmpty
    }

    func deleteAPIKey(for providerID: UUID) {
        lock.lock()
        cache.removeValue(forKey: providerID)
        lock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: providerID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
