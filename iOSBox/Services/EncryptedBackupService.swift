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

    struct CredentialMatch {
        var totalCount: Int
        var skippedCount: Int
        var destinationMatches: Bool
        var headerIDs: [String: UUID] = [:]
    }

    /// The preview also covers a provider that the archive will create during this restore.
    @MainActor
    static func credentialMatch(_ bundle: ProviderSecretBundle, source: ProviderBackup?, local: ProviderConfig?) -> CredentialMatch {
        let raw = bundle.rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraCount = Set((bundle.extraAPIKeys ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).count
        let headers = bundle.secretHeaders.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let count = (bundle.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1) + extraCount + headers.count
        guard let source else { return CredentialMatch(totalCount: count, skippedCount: count, destinationMatches: false) }
        let sourceURL = source.baseURL.isEmpty ? raw : source.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let localURL = local?.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? sourceURL
        guard APIProtocolType(rawValue: source.protocolRaw) != nil, (local?.protocolRaw ?? source.protocolRaw) == source.protocolRaw,
              validDestination(raw), sourceURL == raw, localURL == raw else {
            return CredentialMatch(totalCount: count, skippedCount: count, destinationMatches: false)
        }
        let localHeaders = local?.customHeaders ?? source.customHeaders
        var match = CredentialMatch(totalCount: count, skippedCount: 0, destinationMatches: true)
        for key in headers.keys {
            guard let id = UUID(uuidString: key),
                  let original = source.customHeaders.first(where: { $0.id == id && $0.isSecret }),
                  localHeaders.contains(where: { $0.id == id && $0.isSecret && $0.key.caseInsensitiveCompare(original.key) == .orderedSame }) else {
                match.skippedCount += 1
                continue
            }
            match.headerIDs[key] = id
        }
        return match
    }

    enum DraftRecoveryTarget {
        case original, unchanged, previouslyRecovered
        case separate(UUID, needsConversation: Bool)
    }

    @MainActor
    static func draftRecoveryTarget(for draft: ChatDraft, id: UUID, store: ChatDraftStore, in context: ModelContext) throws -> DraftRecoveryTarget {
        let local = try store.draftForRecovery(id)
        if local == draft { return .unchanged }
        let recoveredID = try draft.recoveryConversationID(for: id)
        let query = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == recoveredID })
        guard let existing = try context.fetch(query).first else {
            return local.isEmpty ? .original : .separate(recoveredID, needsConversation: true)
        }
        // The original draft may have been sent or cleared since a separate copy was recovered.
        if !existing.messages.isEmpty { return .previouslyRecovered }
        let recoveredDraft = try store.draftForRecovery(recoveredID)
        return recoveredDraft.isEmpty ? .separate(recoveredID, needsConversation: false) : .previouslyRecovered
    }

    struct FullPayload: Codable {
        var archive: BackupArchive
        var providerSecrets: [ProviderSecretBundle]
        var tavilyAPIKey: String
        var drafts: [UUID: ChatDraft]? = nil

        enum CodingKeys: String, CodingKey { case archive, versionedArchive, providerSecrets, tavilyAPIKey, drafts }

        init(archive: BackupArchive, providerSecrets: [ProviderSecretBundle], tavilyAPIKey: String, drafts: [UUID: ChatDraft]? = nil) {
            self.archive = archive
            self.providerSecrets = providerSecrets
            self.tavilyAPIKey = tavilyAPIKey
            self.drafts = drafts
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let key: CodingKeys = values.contains(.versionedArchive) ? .versionedArchive : .archive
            let header = try values.nestedContainer(keyedBy: ArchiveHeader.self, forKey: key)
            let version = try header.decode(Int.self, forKey: .formatVersion)
            guard version <= BackupArchive.currentFormatVersion else { throw BackupError.newerFormat(version) }
            archive = try values.decode(BackupArchive.self, forKey: key)
            providerSecrets = try values.decode([ProviderSecretBundle].self, forKey: .providerSecrets)
            tavilyAPIKey = try values.decode(String.self, forKey: .tavilyAPIKey)
            drafts = try values.decodeIfPresent([UUID: ChatDraft].self, forKey: .drafts)
        }

        private enum ArchiveHeader: String, CodingKey { case formatVersion }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            // The v7 encrypted reader ignored archive.formatVersion. Omitting its required
            // archive key makes older clients stop before merging or updating the remote file.
            try values.encode(archive, forKey: archive.formatVersion >= 8 ? .versionedArchive : .archive)
            try values.encode(providerSecrets, forKey: .providerSecrets)
            try values.encode(tavilyAPIKey, forKey: .tavilyAPIKey)
            try values.encodeIfPresent(drafts, forKey: .drafts)
        }
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
        knowledgeStore: PresetKnowledgeStore = .shared,
        tombstoneStore: SyncTombstoneStore? = nil,
        draftStore: ChatDraftStore? = nil
    ) throws -> FullPayload {
        let archive = try BackupService.makeArchive(
            context: context,
            knowledgeStore: knowledgeStore,
            tombstoneStore: tombstoneStore
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
        return FullPayload(
            archive: archive,
            providerSecrets: bundles,
            tavilyAPIKey: tavilyKey,
            drafts: try draftStore?.snapshots(for: archive.conversations.map(\.id))
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

        let combined: Data = try autoreleasepool {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var plaintext = try encoder.encode(payload)
            defer { plaintext.removeAll(keepingCapacity: false) }
            guard plaintext.count <= maximumPlaintext else { throw BackupError.fileTooLarge }
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
            guard let combinedBytes = sealed.combined else { throw EncryptedBackupError.keyDerivationFailed }
            return combinedBytes
        }

        let data: Data = autoreleasepool {
            let ciphertextBase64Data = combined.base64EncodedData()
            let saltBase64 = salt.base64EncodedString()
            let prefix = Data(#"{"combinedCiphertextBase64":""#.utf8)
            let suffix = Data(#"","iterations":\#(pbkdf2Iterations),"magic":"\#(envelopeMagic)","saltBase64":"\#(saltBase64)"}"#.utf8)
            var out = Data()
            out.reserveCapacity(prefix.count + ciphertextBase64Data.count + suffix.count)
            out.append(prefix)
            out.append(ciphertextBase64Data)
            out.append(suffix)
            return out
        }
        try BackupService.validateFileSize(data.count)
        return data
    }

    @MainActor
    static func exportEncryptedData(
        context: ModelContext,
        password: String,
        knowledgeStore: PresetKnowledgeStore = .shared
    ) throws -> Data {
        guard isValidExportPassword(password) else { throw EncryptedBackupError.emptyPassword }
        let payload = try makeExportPayload(
            context: context,
            knowledgeStore: knowledgeStore
        )
        return try encryptPayload(payload, password: password)
    }

    @MainActor
    static func exportEncryptedTemporaryFile(
        context: ModelContext,
        password: String,
        knowledgeStore: PresetKnowledgeStore = .shared,
        includeDrafts: Bool = false
    ) async throws -> URL {
        guard isValidExportPassword(password) else { throw EncryptedBackupError.emptyPassword }
        let payload = try makeExportPayload(
            context: context,
            knowledgeStore: knowledgeStore,
            draftStore: includeDrafts ? .shared : nil
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

        let (iterations, salt, box): (UInt32, Data, AES.GCM.SealedBox) = try autoreleasepool {
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                  envelope.magic == envelopeMagic,
                  envelope.iterations >= 10_000,
                  envelope.iterations <= 2_000_000,
                  let decodedSalt = Data(base64Encoded: envelope.saltBase64),
                  decodedSalt.count >= 16,
                  let combined = Data(base64Encoded: envelope.combinedCiphertextBase64) else {
                throw EncryptedBackupError.invalidEnvelope
            }
            do {
                let sealedBox = try AES.GCM.SealedBox(combined: combined)
                return (envelope.iterations, decodedSalt, sealedBox)
            } catch {
                throw EncryptedBackupError.invalidEnvelope
            }
        }

        let aad = Data(envelopeMagic.utf8)
        let plaintext: Data = try autoreleasepool {
            let primaryKey = try deriveKey(password: password, salt: salt, iterations: iterations)
            if let opened = try? AES.GCM.open(box, using: primaryKey, authenticating: aad) {
                return opened
            }
            // Backward compatibility for earlier backups that trimmed leading/trailing whitespace on export.
            let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != password, !trimmed.isEmpty,
                  let fallbackKey = try? deriveKey(password: trimmed, salt: salt, iterations: iterations),
                  let opened = try? AES.GCM.open(box, using: fallbackKey, authenticating: aad) else {
                throw EncryptedBackupError.wrongPasswordOrCorrupted
            }
            return opened
        }

        var payload: FullPayload = try autoreleasepool {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(FullPayload.self, from: plaintext)
        }
        for index in payload.archive.conversations.indices {
            payload.archive.conversations[index].assistanceSettings = payload.archive.conversations[index].assistanceSettings?.forPersonaBackup
        }
        return payload
    }

    @MainActor
    static func applyDecryptedPayload(
        _ payload: FullPayload,
        to context: ModelContext,
        knowledgeStore: PresetKnowledgeStore = .shared,
        tombstonePolicy: SyncTombstonePolicy = .ignore,
        draftStore: ChatDraftStore? = nil,
        restoreSecret: (String, String) -> Bool = KeychainService.shared.restoreSecretIfMissing
    ) throws -> ImportSummary {
        guard PersistenceController.canCommitUserData(in: context) else { throw BackupError.storageUnavailable }
        guard Set(payload.providerSecrets.map(\.providerID)).count == payload.providerSecrets.count else {
            throw BackupError.conflictingIDs
        }
        let preExistingProviders = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<ProviderConfig>()).map { ($0.id, $0.updatedAt) }
        )
        let bundles = Dictionary(uniqueKeysWithValues: payload.providerSecrets.map { ($0.providerID, $0) })
        var archive = payload.archive
        // Import the unredacted destination in the same transaction as a new provider.
        // The normal merge preserves the endpoint and enabled state of every existing provider.
        for i in archive.providers.indices where archive.providers[i].baseURL.isEmpty {
            guard let bundle = bundles[archive.providers[i].id], validDestination(bundle.rawBaseURL) else { continue }
            archive.providers[i].baseURL = bundle.rawBaseURL
        }
        var summary = try BackupService.apply(
            .full(archive),
            to: context,
            knowledgeStore: knowledgeStore,
            tombstonePolicy: tombstonePolicy
        )
        let archived = Dictionary(uniqueKeysWithValues: archive.providers.map { ($0.id, $0) })
        let local = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ProviderConfig>()).map { ($0.id, $0) })
        var mutatedProviders = false

        @discardableResult
        func restore(_ value: String, account: String) -> Bool {
            guard !value.isEmpty else { return true }
            if restoreSecret(value, account) {
                summary.confirmedCredentials += 1
                return true
            } else {
                summary.failedCredentialWrites += 1
                return false
            }
        }

        for bundle in payload.providerSecrets {
            let id = bundle.providerID
            if case .enforce(let tombstoneStore) = tombstonePolicy,
               tombstoneStore.latestDeletion(kind: .provider, id: id) != nil {
                continue
            }
            let match = credentialMatch(bundle, source: archived[id], local: local[id])
            if match.skippedCount > 0 {
                summary.credentialConflicts.append(local[id]?.name ?? archived[id]?.name ?? id.uuidString)
            }
            guard match.destinationMatches, let provider = local[id] else { continue }

            var bundleSucceeded = match.skippedCount == 0
            let credentialID = provider.credentialID
            if !restore(bundle.apiKey, account: credentialID.uuidString) {
                bundleSucceeded = false
            }
            if let keys = bundle.extraAPIKeys, !keys.isEmpty {
                if let value = KeychainService.encodedExtraAPIKeys(keys) {
                    if !restore(value, account: KeychainService.extraKeysAccount(providerID: credentialID)) {
                        bundleSucceeded = false
                    }
                } else {
                    summary.failedCredentialWrites += 1
                    bundleSucceeded = false
                }
            }
            if let timeout = bundle.idleTimeoutSeconds, timeout > 0,
               ProviderConnectionSettingsStore.shared.idleTimeoutSeconds(for: id) == 0 {
                ProviderConnectionSettingsStore.shared.setIdleTimeoutSeconds(timeout, for: id)
            }
            for (key, headerID) in match.headerIDs {
                if let value = bundle.secretHeaders[key] {
                    if !restore(value, account: KeychainService.headerAccount(providerID: credentialID, headerID: headerID)) {
                        bundleSucceeded = false
                    }
                }
            }

            // Respect `bundle.isEnabled`: disabled providers are never forced to `true`, while
            // WebDAV sync (`tombstonePolicy == .enforce`) propagates `bundle.isEnabled` accurately.
            if !bundle.isEnabled {
                if preExistingProviders[id] == nil && provider.isEnabled {
                    provider.isEnabled = false
                    mutatedProviders = true
                } else if case .enforce = tombstonePolicy {
                    let incomingUpdated = archived[id]?.updatedAt
                    let localPriorUpdated = preExistingProviders[id] ?? .distantPast
                    if (incomingUpdated == nil || incomingUpdated! >= localPriorUpdated) && provider.isEnabled {
                        provider.isEnabled = false
                        if let incomingUpdated { provider.updatedAt = incomingUpdated }
                        mutatedProviders = true
                    }
                }
            } else if case .enforce = tombstonePolicy, bundleSucceeded {
                let isNew = preExistingProviders[id] == nil
                let isNewer = (archived[id]?.updatedAt ?? .distantPast) > (preExistingProviders[id] ?? .distantPast)
                if (isNew || isNewer) && !provider.isEnabled
                    && (provider.hasAuthentication || NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)) {
                    provider.isEnabled = true
                    if let incomingUpdated = archived[id]?.updatedAt { provider.updatedAt = incomingUpdated }
                    mutatedProviders = true
                }
            }
        }
        if mutatedProviders {
            try context.save()
        }
        restore(payload.tavilyAPIKey, account: TavilySearchClient.keychainAccount)
        if case .ignore = tombstonePolicy, let drafts = payload.drafts, !drafts.isEmpty {
            let store = draftStore ?? (context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) ? nil : ChatDraftStore.shared)
            if let store {
                let chatTitles = Dictionary(uniqueKeysWithValues: archive.conversations.map { ($0.id, $0.title) })
                for (id, draft) in drafts {
                    guard let title = chatTitles[id], !draft.isEmpty else { continue }
                    do {
                        switch try draftRecoveryTarget(for: draft, id: id, store: store, in: context) {
                        case .original:
                            if try store.restoreIfEmpty(draft, for: id) { summary.drafts += 1 }
                        case .unchanged, .previouslyRecovered:
                            summary.skipped += 1
                        case .separate(let recoveredID, let needsConversation):
                            if needsConversation {
                                let recovered = Conversation(id: recoveredID, title: String(localized: "找回的草稿 · \(title)"))
                                recovered.setFolderTag(String(localized: "找回的草稿"))
                                context.insert(recovered)
                                try context.save()
                            }
                            if try store.restoreIfEmpty(draft, for: recoveredID) { summary.conflictingDrafts += 1 }
                        }
                    } catch { summary.draftFailures += 1 }
                }
            }
        }
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
        knowledgeStore: PresetKnowledgeStore = .shared,
        tombstonePolicy: SyncTombstonePolicy = .ignore
    ) throws -> ImportSummary {
        let payload = try decryptPayload(data: data, password: password)
        return try applyDecryptedPayload(
            payload,
            to: context,
            knowledgeStore: knowledgeStore,
            tombstonePolicy: tombstonePolicy
        )
    }

    @MainActor
    static func decryptAndApplyAsync(
        data: Data,
        password: String,
        to context: ModelContext,
        knowledgeStore: PresetKnowledgeStore = .shared,
        tombstonePolicy: SyncTombstonePolicy = .ignore
    ) async throws -> ImportSummary {
        let payload = try await Task.detached(priority: .userInitiated) {
            try decryptPayload(data: data, password: password)
        }.value
        return try applyDecryptedPayload(
            payload,
            to: context,
            knowledgeStore: knowledgeStore,
            tombstonePolicy: tombstonePolicy
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
