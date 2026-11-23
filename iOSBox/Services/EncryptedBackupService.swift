import CommonCrypto
import CryptoKit
import Foundation
import Security
import SwiftData

enum EncryptedBackupError: LocalizedError {
    case emptyPassword
    case wrongPasswordOrCorrupted
    case invalidEnvelope
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return String(localized: "请设置至少 8 位字符的备份密码。")
        case .wrongPasswordOrCorrupted:
            return String(localized: "备份密码不正确，或加密备份文件已损坏。")
        case .invalidEnvelope:
            return String(localized: "无法识别该加密备份文件。")
        case .keyDerivationFailed:
            return String(localized: "密钥派生失败，请重试。")
        }
    }
}

enum EncryptedBackupService {
    static let envelopeMagic = "IOSBOX_ENCRYPTED_BACKUP_V1"
    static let minimumPasswordCharacters = 8
    private static let pbkdf2Iterations: UInt32 = 600_000

    struct Envelope: Codable {
        var magic: String
        var iterations: UInt32
        var saltBase64: String
        var combinedCiphertextBase64: String
    }

    struct ProviderSecretBundle: Codable {
        var providerID: UUID
        var rawBaseURL: String
        var isEnabled: Bool
        var apiKey: String
        var extraAPIKeys: [String]? = nil
        var idleTimeoutSeconds: Int? = nil
        var secretHeaders: [String: String]
    }

    struct FullPayload: Codable {
        var archive: BackupArchive
        var providerSecrets: [ProviderSecretBundle]
        var tavilyAPIKey: String
        var personaXBearerToken: String? = nil
    }

    private struct MagicProbe: Decodable {
        var magic: String
    }

    static func isValidExportPassword(_ password: String) -> Bool {
        password.count >= minimumPasswordCharacters
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isEncryptedBackup(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= BackupService.maximumFileBytes else { return false }
        let magicBytes = Data(envelopeMagic.utf8)
        let headEnd = min(data.count, 4096)
        let tailStart = max(0, data.count - 4096)
        let hasMagicInHead = data.range(of: magicBytes, in: 0..<headEnd) != nil
        let hasMagicInTail = tailStart > 0 && data.range(of: magicBytes, in: tailStart..<data.count) != nil
        guard hasMagicInHead || hasMagicInTail else { return false }
        guard let probe = try? JSONDecoder().decode(MagicProbe.self, from: data) else {
            return false
        }
        return probe.magic == envelopeMagic
    }

    @MainActor
    static func makeExportPayload(
        context: ModelContext,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) throws -> FullPayload {
        let archive = try BackupService.makeArchive(
            context: context,
            flashcardStore: flashcardStore,
            knowledgeStore: knowledgeStore
        )
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))

        let bundles: [ProviderSecretBundle] = providers.map { p in
            var headerSecrets: [String: String] = [:]
            for header in p.customHeaders {
                if header.isSecret {
                    let secret = KeychainService.shared.loadSecret(
                        account: KeychainService.headerAccount(providerID: p.credentialID, headerID: header.id)
                    )
                    if !secret.isEmpty {
                        headerSecrets[header.id.uuidString] = secret
                    }
                } else if CustomHeader.looksSensitive(header.key) && !header.value.isEmpty {
                    headerSecrets[header.id.uuidString] = header.value
                }
            }
            let extras = p.extraAPIKeys
            let customTimeout = p.idleTimeoutSeconds
            return ProviderSecretBundle(
                providerID: p.id,
                rawBaseURL: p.baseURL,
                isEnabled: p.isEnabled,
                apiKey: p.apiKey,
                extraAPIKeys: extras.isEmpty ? nil : extras,
                idleTimeoutSeconds: customTimeout > 0 ? customTimeout : nil,
                secretHeaders: headerSecrets
            )
        }

        let tavilyKey = KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount)
        let xToken = KeychainService.shared.loadSecret(account: PersonaFeedReader.xTokenAccount)
        return FullPayload(
            archive: archive,
            providerSecrets: bundles,
            tavilyAPIKey: tavilyKey,
            personaXBearerToken: xToken.isEmpty ? nil : xToken
        )
    }

    nonisolated static func encryptPayload(_ payload: FullPayload, password: String) throws -> Data {
        guard isValidExportPassword(password) else { throw EncryptedBackupError.emptyPassword }
        // Base64 needs at least four bytes per three bytes of ciphertext.
        let maximumPlaintext = BackupService.maximumFileBytes / 4 * 3
        try BackupService.checkContentSize(payload.archive, limit: maximumPlaintext)

        var salt = Data(count: 16)
        let saltStatus = salt.withUnsafeMutableBytes { buf in
            SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
        }
        guard saltStatus == errSecSuccess else { throw EncryptedBackupError.keyDerivationFailed }

        let key = try deriveKey(password: password, salt: salt, iterations: pbkdf2Iterations)
        let aad = Data(envelopeMagic.utf8)

        let combinedBase64: String = try autoreleasepool {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(payload)
            guard plaintext.count <= maximumPlaintext else { throw BackupError.fileTooLarge }
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
            guard let combined = sealed.combined else { throw EncryptedBackupError.keyDerivationFailed }
            return combined.base64EncodedString()
        }

        let envelope = Envelope(
            magic: envelopeMagic,
            iterations: pbkdf2Iterations,
            saltBase64: salt.base64EncodedString(),
            combinedCiphertextBase64: combinedBase64
        )
        let outEncoder = JSONEncoder()
        outEncoder.outputFormatting = [.sortedKeys]
        let data = try outEncoder.encode(envelope)
        try BackupService.validateFileSize(data.count)
        return data
    }

    @MainActor
    static func exportEncryptedData(
        context: ModelContext,
        password: String,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) throws -> Data {
        guard isValidExportPassword(password) else { throw EncryptedBackupError.emptyPassword }
        let payload = try makeExportPayload(
            context: context,
            flashcardStore: flashcardStore,
            knowledgeStore: knowledgeStore
        )
        return try encryptPayload(payload, password: password)
    }

    @MainActor
    static func exportEncryptedTemporaryFile(
        context: ModelContext,
        password: String,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) async throws -> URL {
        guard isValidExportPassword(password) else { throw EncryptedBackupError.emptyPassword }
        let payload = try makeExportPayload(
            context: context,
            flashcardStore: flashcardStore,
            knowledgeStore: knowledgeStore
        )
        return try await Task.detached(priority: .userInitiated) {
            let encryptedData = try encryptPayload(payload, password: password)
            return try writeEncryptedTemporaryFile(encryptedData)
        }.value
    }

    static func writeEncryptedTemporaryFile(_ data: Data) throws -> URL {
        try BackupService.validateFileSize(data.count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Fugue-EncryptedBackup-\(formatter.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    nonisolated static func decryptPayload(data: Data, password: String) throws -> FullPayload {
        try BackupService.validateFileSize(data.count)
        guard !password.isEmpty else { throw EncryptedBackupError.wrongPasswordOrCorrupted }

        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.magic == envelopeMagic,
              envelope.iterations >= 10_000,
              envelope.iterations <= 2_000_000,
              let salt = Data(base64Encoded: envelope.saltBase64),
              salt.count >= 16,
              let combined = Data(base64Encoded: envelope.combinedCiphertextBase64) else {
            throw EncryptedBackupError.invalidEnvelope
        }

        let aad = Data(envelopeMagic.utf8)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw EncryptedBackupError.invalidEnvelope
        }

        let plaintext: Data
        let primaryKey = try deriveKey(password: password, salt: salt, iterations: envelope.iterations)
        if let opened = try? AES.GCM.open(box, using: primaryKey, authenticating: aad) {
            plaintext = opened
        } else {
            // Backward compatibility for earlier backups that trimmed leading/trailing whitespace on export.
            let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != password, !trimmed.isEmpty,
                  let fallbackKey = try? deriveKey(password: trimmed, salt: salt, iterations: envelope.iterations),
                  let opened = try? AES.GCM.open(box, using: fallbackKey, authenticating: aad) else {
                throw EncryptedBackupError.wrongPasswordOrCorrupted
            }
            plaintext = opened
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var payload = try decoder.decode(FullPayload.self, from: plaintext)
        for index in payload.archive.conversations.indices {
            payload.archive.conversations[index].assistanceSettings = payload.archive.conversations[index].assistanceSettings?.forPersonaBackup
        }
        return payload
    }

    @MainActor
    static func applyDecryptedPayload(
        _ payload: FullPayload,
        to context: ModelContext,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared,
        restoreSecret: (String, String) -> Bool = KeychainService.shared.restoreSecretIfMissing
    ) throws -> ImportSummary {
        guard PersistenceController.canCommitUserData(in: context) else { throw BackupError.storageUnavailable }
        guard Set(payload.providerSecrets.map(\.providerID)).count == payload.providerSecrets.count else {
            throw BackupError.conflictingIDs
        }
        let bundles = Dictionary(uniqueKeysWithValues: payload.providerSecrets.map { ($0.providerID, $0) })
        var archive = payload.archive
        // Import the unredacted destination in the same transaction as a new provider.
        // The normal merge preserves the endpoint and enabled state of every existing provider.
        for i in archive.providers.indices where archive.providers[i].baseURL.isEmpty {
            guard let bundle = bundles[archive.providers[i].id], validDestination(bundle.rawBaseURL) else { continue }
            archive.providers[i].baseURL = bundle.rawBaseURL
        }
        var summary = try BackupService.apply(.full(archive), to: context,
                                              flashcardStore: flashcardStore, knowledgeStore: knowledgeStore)
        let archived = Dictionary(uniqueKeysWithValues: archive.providers.map { ($0.id, $0) })
        let local = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ProviderConfig>()).map { ($0.id, $0) })

        func restore(_ value: String, account: String) {
            guard !value.isEmpty else { return }
            if restoreSecret(value, account) { summary.confirmedCredentials += 1 }
            else { summary.failedCredentialWrites += 1 }
        }

        for bundle in payload.providerSecrets {
            let id = bundle.providerID
            let raw = bundle.rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let source = archived[id], let provider = local[id],
                  APIProtocolType(rawValue: source.protocolRaw) != nil, provider.protocolRaw == source.protocolRaw,
                  validDestination(raw), source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == raw,
                  provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == raw else {
                if !bundle.apiKey.isEmpty || bundle.extraAPIKeys?.isEmpty == false || !bundle.secretHeaders.isEmpty {
                    summary.credentialConflicts.append(local[id]?.name ?? archived[id]?.name ?? id.uuidString)
                }
                continue
            }

            let credentialID = provider.credentialID
            restore(bundle.apiKey, account: credentialID.uuidString)
            if let keys = bundle.extraAPIKeys, !keys.isEmpty {
                if let value = KeychainService.encodedExtraAPIKeys(keys) {
                    restore(value, account: KeychainService.extraKeysAccount(providerID: credentialID))
                } else { summary.failedCredentialWrites += 1 }
            }
            if let timeout = bundle.idleTimeoutSeconds, timeout > 0,
               ProviderConnectionSettingsStore.shared.idleTimeoutSeconds(for: id) == 0 {
                ProviderConnectionSettingsStore.shared.setIdleTimeoutSeconds(timeout, for: id)
            }
            var headerConflict = false
            for (key, value) in bundle.secretHeaders where !value.isEmpty {
                guard let headerID = UUID(uuidString: key),
                      let original = source.customHeaders.first(where: { $0.id == headerID && $0.isSecret }),
                      provider.customHeaders.contains(where: {
                          $0.id == headerID && $0.isSecret && $0.key.caseInsensitiveCompare(original.key) == .orderedSame
                      }) else {
                    headerConflict = true
                    continue
                }
                restore(value, account: KeychainService.headerAccount(providerID: credentialID, headerID: headerID))
            }
            if headerConflict { summary.credentialConflicts.append(provider.name) }
        }
        restore(payload.tavilyAPIKey, account: TavilySearchClient.keychainAccount)
        restore(payload.personaXBearerToken ?? "", account: PersonaFeedReader.xTokenAccount)
        NotificationCenter.default.post(name: .init("IOSBoxCredentialsChanged"), object: nil)
        return summary
    }

    private static func validDestination(_ raw: String) -> Bool {
        guard let url = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else { return false }
        return url.host?.isEmpty == false
    }

    @MainActor
    static func decryptAndApply(
        data: Data,
        password: String,
        to context: ModelContext,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) throws -> ImportSummary {
        let payload = try decryptPayload(data: data, password: password)
        return try applyDecryptedPayload(
            payload,
            to: context,
            flashcardStore: flashcardStore,
            knowledgeStore: knowledgeStore
        )
    }

    @MainActor
    static func decryptAndApplyAsync(
        data: Data,
        password: String,
        to context: ModelContext,
        flashcardStore: FlashcardStore? = nil,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) async throws -> ImportSummary {
        let payload = try await Task.detached(priority: .userInitiated) {
            try decryptPayload(data: data, password: password)
        }.value
        return try applyDecryptedPayload(
            payload,
            to: context,
            flashcardStore: flashcardStore,
            knowledgeStore: knowledgeStore
        )
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw EncryptedBackupError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }
}
