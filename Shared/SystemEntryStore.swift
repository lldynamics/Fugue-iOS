import Foundation
import Security

enum SystemEntryError: LocalizedError {
    case unavailable, noModel, invalidInput, timeout, storage, importFailed, credentials(OSStatus)
    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "共享空间不可用，请检查主 App 与分享扩展的 App Group 签名配置。")
        case .noModel: return String(localized: "没有可用模型，请先在「夜奔」的服务商设置中启用模型与系统分享。")
        case .invalidInput: return String(localized: "请提供文字、网页链接或有效图片。")
        case .timeout: return String(localized: "分享处理已超时，已保留收到的内容。可回到「夜奔」查看并重答。")
        case .storage: return String(localized: "结果保存失败，请保留当前窗口并重试。")
        case .importFailed: return String(localized: "部分分享结果尚未导入，将在下次打开时重试。")
        case .credentials: return String(localized: "共享钥匙串不可用，请解锁设备并在主 App 中重新启用系统分享。")
        }
    }
}

enum SystemEntryLocation {
    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "IOSBoxAppGroup") as? String ?? "group.com.iosbox.app"
    }

    static func sharedDirectory() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw SystemEntryError.unavailable
        }
        return url.appendingPathComponent("SystemEntries", isDirectory: true)
    }
}

/// Only this manifest goes into the shared file container. Endpoints, headers and keys
/// are kept together in the shared Keychain, so even URL query credentials stay off disk.
struct SharedModelEntry: Codable, Hashable, Identifiable {
    var target: ResolvedModelTarget
    var spec: ModelSpec
    var connectionID: UUID
    var id: String { target.id }
}

struct SharedConnection: Codable, Equatable {
    var baseURL: String
    var apiKey: String
    var extraAPIKeys: [String]? = nil
    var idleTimeoutSeconds: Int? = nil
    var headers: [CustomHeader]

    var allAPIKeys: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in [apiKey] + (extraAPIKeys ?? []) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    func request(for entry: SharedModelEntry, text: String, systemPrompt: String,
                 attachments: [MessageAttachment] = []) throws -> LLMChatRequest {
        guard !allAPIKeys.isEmpty || headers.contains(where: {
            $0.isEnabled && CustomHeader.looksSensitive($0.key) && !$0.value.isEmpty
        }) || NetworkLocation.isLocalOrPrivate(baseURL: baseURL) else {
            throw LLMError.missingAPIKey(entry.target.providerName)
        }
        let customTimeout = idleTimeoutSeconds.flatMap { $0 > 0 ? TimeInterval($0) : nil }
        return LLMChatRequest(providerName: entry.target.providerName, protocolType: entry.target.protocolType,
                              baseURL: baseURL, apiKey: apiKey, apiKeys: extraAPIKeys ?? [], customHeaders: headers,
                              modelID: entry.target.modelID, supportsReasoning: entry.spec.supportsReasoning,
                              systemPrompt: systemPrompt,
                              messages: [.init(role: .user, content: text, attachments: attachments)],
                              temperature: nil, topP: 1, maxOutputTokens: nil,
                              enableThinking: false, thinkingBudgetTokens: 0,
                              idleTimeoutSeconds: customTimeout)
    }
}

struct SharedConnectionKeychain {
    var groupID = SystemEntryLocation.groupID
    private let service = "com.iosbox.system-entry-connections"

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecAttrAccessGroup as String: groupID]
    }

    func save(_ connection: SharedConnection, id: UUID) throws {
        let encoded = try JSONEncoder().encode(connection)
        let matchQuery = query(id)
        var addQuery = matchQuery
        addQuery[kSecValueData as String] = encoded
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: encoded,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            status = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        }
        guard status == errSecSuccess else { throw SystemEntryError.credentials(status) }
    }

    func load(id: UUID) throws -> SharedConnection {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { throw SystemEntryError.credentials(status) }
        return try JSONDecoder().decode(SharedConnection.self, from: data)
    }

    func delete(id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}

struct SystemEntryStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    init() throws { directory = try SystemEntryLocation.sharedDirectory() }

    func models() throws -> [SharedModelEntry] {
        let url = directory.appendingPathComponent("models.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SharedModelEntry].self, from: boundedData(url, limit: 2_000_000))
    }

    func saveModels(_ models: [SharedModelEntry]) throws {
        try write(JSONEncoder().encode(models), to: directory.appendingPathComponent("models.json"))
    }

    func save(_ receipt: ExternalRunReceipt) throws {
        let url = directory.appendingPathComponent("Results", isDirectory: true)
            .appendingPathComponent(receipt.id.uuidString + ".json")
        try write(JSONEncoder().encode(receipt), to: url)
    }

    func receiptBatch(now: Date = Date()) throws -> (entries: [(URL, ExternalRunReceipt)], failed: [URL]) {
        let folder = directory.appendingPathComponent("Results", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return ([], []) }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entries: [(URL, ExternalRunReceipt)] = []
        var failed: [URL] = []
        for url in files {
            do {
                var receipt = try JSONDecoder().decode(ExternalRunReceipt.self, from: boundedData(url, limit: 12_000_000))
                if receipt.isRunning {
                    // Never import a file that a live extension may still be updating.
                    guard now.timeIntervalSince(receipt.updatedAt) > 180 else { continue }
                    receipt.isRunning = false
                    receipt.error = String(localized: "分享处理被系统中断，已保留收到的内容。")
                    if let last = receipt.records.indices.last {
                        receipt.records[last].statusRaw = RequestStatus.interrupted.rawValue
                    }
                }
                entries.append((url, receipt))
            } catch { failed.append(url) }
        }
        return (entries, failed)
    }

    func receipts(now: Date = Date()) throws -> [(URL, ExternalRunReceipt)] {
        let batch = try receiptBatch(now: now)
        guard batch.failed.isEmpty else { throw SystemEntryError.importFailed }
        return batch.entries
    }

    private func boundedData(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SystemEntryError.storage }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}
