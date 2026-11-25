import CommonCrypto
import CryptoKit
import Foundation

// MARK: - Sharded Payload Splitting & Reassembly

enum WebDAVPayloadSharder {
    /// Attachments whose Base64 payload reaches or exceeds this threshold are extracted into
    /// content-addressed encrypted blobs and deduplicated across messages and revisions.
    static let attachmentShardThresholdBytes = 16 * 1024
    static let blobSentinelPrefix = "$iosbox-blob:"

    struct BookBlobRef: Codable, Equatable, Sendable {
        var id: UUID
        var title: String
        var importedAt: Date
        var blobHash: String
        var byteCount: Int
    }

    struct ManifestPayload: Codable {
        var corePayload: EncryptedBackupService.FullPayload
        var bookRefs: [BookBlobRef]
        var attachmentBlobSizes: [String: Int]
    }

    struct ExtractedBundle {
        var manifest: ManifestPayload
        var blobs: [String: Data]
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidBlobHash(_ raw: String) -> Bool {
        raw.count == 64 && raw.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    static func blobHash(fromSentinel value: String?) -> String? {
        guard let value, value.hasPrefix(blobSentinelPrefix) else { return nil }
        let hash = String(value.dropFirst(blobSentinelPrefix.count))
        return isValidBlobHash(hash) ? hash : nil
    }

    static func split(_ payload: EncryptedBackupService.FullPayload) throws -> ExtractedBundle {
        var core = payload
        var blobs: [String: Data] = [:]
        var bookRefs: [BookBlobRef] = []
        var attachmentBlobSizes: [String: Int] = [:]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        // 1. Extract all book manuscripts into immutable content-addressed shards.
        if let books = payload.archive.books, !books.isEmpty {
            for book in books {
                let rawChapters = try encoder.encode(book.chapters)
                let hash = sha256Hex(rawChapters)
                blobs[hash] = rawChapters
                bookRefs.append(BookBlobRef(
                    id: book.id,
                    title: book.title,
                    importedAt: book.importedAt,
                    blobHash: hash,
                    byteCount: rawChapters.count
                ))
            }
            core.archive.books = []
        }

        // 2. Extract large message and revision attachment payloads into deduplicated blobs.
        func shardAttachment(_ attachment: inout MessageAttachment) {
            guard let base64 = attachment.dataBase64,
                  base64.utf8.count >= attachmentShardThresholdBytes,
                  !base64.hasPrefix(blobSentinelPrefix) else {
                return
            }
            let raw = Data(base64.utf8)
            let hash = sha256Hex(raw)
            blobs[hash] = raw
            attachmentBlobSizes[hash] = raw.count
            attachment.dataBase64 = blobSentinelPrefix + hash
        }

        for cIdx in core.archive.conversations.indices {
            for mIdx in core.archive.conversations[cIdx].messages.indices {
                for aIdx in core.archive.conversations[cIdx].messages[mIdx].attachments.indices {
                    shardAttachment(&core.archive.conversations[cIdx].messages[mIdx].attachments[aIdx])
                }
                if var meta = core.archive.conversations[cIdx].messages[mIdx].assistanceMetadata {
                    var metaChanged = false
                    for rIdx in meta.revisions.indices {
                        for aIdx in meta.revisions[rIdx].attachments.indices {
                            let before = meta.revisions[rIdx].attachments[aIdx].dataBase64
                            shardAttachment(&meta.revisions[rIdx].attachments[aIdx])
                            if meta.revisions[rIdx].attachments[aIdx].dataBase64 != before {
                                metaChanged = true
                            }
                        }
                    }
                    if metaChanged {
                        core.archive.conversations[cIdx].messages[mIdx].assistanceMetadata = meta
                    }
                }
            }
        }

        let manifest = ManifestPayload(
            corePayload: core,
            bookRefs: bookRefs,
            attachmentBlobSizes: attachmentBlobSizes
        )
        return ExtractedBundle(manifest: manifest, blobs: blobs)
    }

    /// Lists all attachment blob hashes referenced by a manifest payload.
    static func referencedAttachmentHashes(in manifest: ManifestPayload) -> Set<String> {
        var hashes = Set<String>(manifest.attachmentBlobSizes.keys)
        for chat in manifest.corePayload.archive.conversations {
            for msg in chat.messages {
                for att in msg.attachments {
                    if let h = blobHash(fromSentinel: att.dataBase64) { hashes.insert(h) }
                }
                if let revisions = msg.assistanceMetadata?.revisions {
                    for rev in revisions {
                        for att in rev.attachments {
                            if let h = blobHash(fromSentinel: att.dataBase64) { hashes.insert(h) }
                        }
                    }
                }
            }
        }
        return hashes
    }

    static func reassemble(
        _ manifest: ManifestPayload,
        blobs: [String: Data],
        existingBooks: [UUID: BookVolume.Snapshot] = [:]
    ) throws -> EncryptedBackupService.FullPayload {
        var full = manifest.corePayload
        let decoder = JSONDecoder()

        // 1. Reassemble books from local existing volumes or downloaded shards.
        if !manifest.bookRefs.isEmpty {
            var restoredBooks: [BookVolume.Snapshot] = []
            restoredBooks.reserveCapacity(manifest.bookRefs.count)
            for ref in manifest.bookRefs {
                if let local = existingBooks[ref.id] {
                    restoredBooks.append(local)
                    continue
                }
                guard let raw = blobs[ref.blobHash], sha256Hex(raw) == ref.blobHash else {
                    throw WebDAVSyncError.shardedBlobMissing(ref.blobHash)
                }
                let chapters = try decoder.decode([BookChapter].self, from: raw)
                restoredBooks.append(BookVolume.Snapshot(
                    id: ref.id,
                    title: ref.title,
                    chapters: chapters,
                    importedAt: ref.importedAt
                ))
            }
            full.archive.books = restoredBooks
        }

        // 2. Restore sharded attachment payloads.
        func restoreAttachment(_ attachment: inout MessageAttachment) throws {
            guard let hash = blobHash(fromSentinel: attachment.dataBase64) else { return }
            guard let raw = blobs[hash], sha256Hex(raw) == hash else {
                throw WebDAVSyncError.shardedBlobMissing(hash)
            }
            attachment.dataBase64 = String(decoding: raw, as: UTF8.self)
        }

        for cIdx in full.archive.conversations.indices {
            for mIdx in full.archive.conversations[cIdx].messages.indices {
                for aIdx in full.archive.conversations[cIdx].messages[mIdx].attachments.indices {
                    try restoreAttachment(&full.archive.conversations[cIdx].messages[mIdx].attachments[aIdx])
                }
                if var meta = full.archive.conversations[cIdx].messages[mIdx].assistanceMetadata {
                    var changed = false
                    for rIdx in meta.revisions.indices {
                        for aIdx in meta.revisions[rIdx].attachments.indices {
                            if blobHash(fromSentinel: meta.revisions[rIdx].attachments[aIdx].dataBase64) != nil {
                                try restoreAttachment(&meta.revisions[rIdx].attachments[aIdx])
                                changed = true
                            }
                        }
                    }
                    if changed {
                        full.archive.conversations[cIdx].messages[mIdx].assistanceMetadata = meta
                    }
                }
            }
        }

        return full
    }
}

// MARK: - Shard Envelope & HKDF Blob Crypto

enum WebDAVShardCrypto {
    static let manifestMagic = "IOSBOX_SHARDED_MANIFEST_V1"
    static let blobDomain = "IOSBOX_SYNC_BLOB_V1"
    private static let defaultIterations: UInt32 = 600_000

    struct ManifestEnvelope: Codable {
        var magic: String
        var iterations: UInt32
        var saltBase64: String
        var keyFingerprint: String
        var presentBlobs: [String]
        var combinedCiphertextBase64: String
    }

    struct DerivedVaultKey {
        let masterKey: SymmetricKey
        let salt: Data
        let saltBase64: String
        let iterations: UInt32
        let keyFingerprint: String
    }

    private struct MagicProbe: Decodable {
        var magic: String
    }

    nonisolated static func isShardedManifest(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= BackupService.maximumFileBytes else { return false }
        guard let probe = try? JSONDecoder().decode(MagicProbe.self, from: data) else { return false }
        return probe.magic == manifestMagic
    }

    nonisolated static func deriveVaultKey(
        password: String,
        salt: Data? = nil,
        iterations: UInt32 = defaultIterations
    ) throws -> DerivedVaultKey {
        guard EncryptedBackupService.isValidExportPassword(password) || salt != nil else {
            throw EncryptedBackupError.emptyPassword
        }
        let resolvedSalt: Data
        if let salt {
            guard salt.count >= 16 else { throw EncryptedBackupError.invalidEnvelope }
            resolvedSalt = salt
        } else {
            var generated = Data(count: 16)
            let status = generated.withUnsafeMutableBytes { buf in
                SecRandomCopyBytes(kSecRandomDefault, 16, buf.baseAddress!)
            }
            guard status == errSecSuccess else { throw EncryptedBackupError.keyDerivationFailed }
            resolvedSalt = generated
        }

        let passwordData = Data(password.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            resolvedSalt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        resolvedSalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw EncryptedBackupError.keyDerivationFailed }

        let masterKey = SymmetricKey(data: derived)
        let fpKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: resolvedSalt,
            info: Data("IOSBOX_VAULT_KEY_FINGERPRINT_V1".utf8),
            outputByteCount: 16
        )
        let fpData = fpKey.withUnsafeBytes { Data($0) }
        let fingerprint = fpData.map { String(format: "%02x", $0) }.joined()
        return DerivedVaultKey(
            masterKey: masterKey,
            salt: resolvedSalt,
            saltBase64: resolvedSalt.base64EncodedString(),
            iterations: iterations,
            keyFingerprint: fingerprint
        )
    }

    nonisolated static func blobKey(masterKey: SymmetricKey, blobHash: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data(blobHash.utf8),
            info: Data(blobDomain.utf8),
            outputByteCount: 32
        )
    }

    nonisolated static func encryptBlob(_ plaintext: Data, hash: String, masterKey: SymmetricKey) throws -> Data {
        guard WebDAVPayloadSharder.isValidBlobHash(hash) else {
            throw WebDAVSyncError.invalidRemotePath
        }
        let key = blobKey(masterKey: masterKey, blobHash: hash)
        let aad = Data("\(blobDomain):\(hash)".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw EncryptedBackupError.keyDerivationFailed
        }
        return combined
    }

    nonisolated static func decryptBlob(_ ciphertext: Data, hash: String, masterKey: SymmetricKey) throws -> Data {
        guard WebDAVPayloadSharder.isValidBlobHash(hash) else {
            throw WebDAVSyncError.invalidRemotePath
        }
        let key = blobKey(masterKey: masterKey, blobHash: hash)
        let aad = Data("\(blobDomain):\(hash)".utf8)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        guard WebDAVPayloadSharder.sha256Hex(plaintext) == hash else {
            throw EncryptedBackupError.wrongPasswordOrCorrupted
        }
        return plaintext
    }

    nonisolated static func encryptManifest(
        _ manifest: WebDAVPayloadSharder.ManifestPayload,
        presentBlobs: [String],
        vaultKey: DerivedVaultKey
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(manifest)
        let aad = Data(manifestMagic.utf8)
        let sealed = try AES.GCM.seal(plaintext, using: vaultKey.masterKey, authenticating: aad)
        guard let combined = sealed.combined else {
            throw EncryptedBackupError.keyDerivationFailed
        }
        let envelope = ManifestEnvelope(
            magic: manifestMagic,
            iterations: vaultKey.iterations,
            saltBase64: vaultKey.saltBase64,
            keyFingerprint: vaultKey.keyFingerprint,
            presentBlobs: Array(Set(presentBlobs)).sorted(),
            combinedCiphertextBase64: combined.base64EncodedString()
        )
        let outEncoder = JSONEncoder()
        outEncoder.outputFormatting = [.sortedKeys]
        let data = try outEncoder.encode(envelope)
        try BackupService.validateFileSize(data.count)
        return data
    }

    nonisolated static func decryptManifest(
        _ data: Data,
        password: String
    ) throws -> (manifest: WebDAVPayloadSharder.ManifestPayload, envelope: ManifestEnvelope, vaultKey: DerivedVaultKey) {
        try BackupService.validateFileSize(data.count)
        guard !password.isEmpty else { throw EncryptedBackupError.wrongPasswordOrCorrupted }
        guard let envelope = try? JSONDecoder().decode(ManifestEnvelope.self, from: data),
              envelope.magic == manifestMagic,
              envelope.iterations >= 10_000,
              envelope.iterations <= 2_000_000,
              let salt = Data(base64Encoded: envelope.saltBase64),
              salt.count >= 16,
              let combined = Data(base64Encoded: envelope.combinedCiphertextBase64) else {
            throw EncryptedBackupError.invalidEnvelope
        }

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw EncryptedBackupError.invalidEnvelope
        }

        let aad = Data(manifestMagic.utf8)
        let vaultKey = try deriveVaultKey(password: password, salt: salt, iterations: envelope.iterations)
        guard let plaintext = try? AES.GCM.open(box, using: vaultKey.masterKey, authenticating: aad) else {
            throw EncryptedBackupError.wrongPasswordOrCorrupted
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(WebDAVPayloadSharder.ManifestPayload.self, from: plaintext)
        for index in manifest.corePayload.archive.conversations.indices {
            manifest.corePayload.archive.conversations[index].assistanceSettings =
                manifest.corePayload.archive.conversations[index].assistanceSettings?.forPersonaBackup
        }
        return (manifest, envelope, vaultKey)
    }
}

// MARK: - Sharded WebDAV Transport

struct WebDAVShardedSyncStats: Equatable, Sendable {
    var uploadedBlobs: Int = 0
    var skippedUploadBlobs: Int = 0
    var downloadedBlobs: Int = 0
    var skippedLocalBlobs: Int = 0
    var manifestBytes: Int = 0

    var pushSummaryText: String {
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(manifestBytes), countStyle: .file)
        if uploadedBlobs == 0 && skippedUploadBlobs == 0 {
            return String(localized: "已分片同步清单（\(sizeText)）。")
        }
        return String(localized: "已分片同步：清单 \(sizeText)，新增分片 \(uploadedBlobs) 个，复用云端已有分片 \(skippedUploadBlobs) 个。")
    }

    var pullSummaryText: String {
        if downloadedBlobs == 0 && skippedLocalBlobs == 0 {
            return String(localized: "已拉取分片清单。")
        }
        return String(localized: "已分片拉取：下载新分片 \(downloadedBlobs) 个，跳过本机已有分片 \(skippedLocalBlobs) 个。")
    }
}

struct WebDAVShardedPushResult: Sendable {
    let metadata: WebDAVRemoteMetadata
    let stats: WebDAVShardedSyncStats
    let saltBase64: String
    let keyFingerprint: String
    let presentBlobs: [String]
}

struct WebDAVShardedPullResult {
    let payload: EncryptedBackupService.FullPayload
    let metadata: WebDAVRemoteMetadata
    let stats: WebDAVShardedSyncStats
    let saltBase64: String
    let keyFingerprint: String
    let presentBlobs: [String]
}

enum WebDAVShardedSyncService {
    /// Computes the sharded sync directory next to the user's configured WebDAV file path.
    /// Example: `Fugue/fugue-sync.enc.json` -> `Fugue/fugue-sync.shards`
    static func shardRootPath(for remotePath: String) -> String {
        let clean = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = clean.isEmpty ? "Fugue/fugue-sync.enc.json" : clean
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = segments.last else { return "Fugue/fugue-sync.shards" }
        var stem = last
        for suffix in [".enc.json", ".json"] where stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            break
        }
        if stem.isEmpty { stem = "fugue-sync" }
        let shardDir = "\(stem).shards"
        if segments.count <= 1 { return shardDir }
        return (segments.dropLast() + [shardDir]).joined(separator: "/")
    }

    static func manifestPath(for remotePath: String) -> String {
        "\(shardRootPath(for: remotePath))/manifest.enc.json"
    }

    static func blobPath(for remotePath: String, hash: String) throws -> String {
        guard WebDAVPayloadSharder.isValidBlobHash(hash) else {
            throw WebDAVSyncError.invalidRemotePath
        }
        return "\(shardRootPath(for: remotePath))/blobs/\(hash).enc.bin"
    }

    static func fetchManifestMetadata(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        session: URLSession? = nil
    ) async throws -> WebDAVRemoteMetadata {
        try await WebDAVSyncService.fetchRemoteMetadata(
            serverURL: serverURL,
            remotePath: manifestPath(for: remotePath),
            username: username,
            password: password,
            session: session
        )
    }

    static func pushSharded(
        payload: EncryptedBackupService.FullPayload,
        passphrase: String,
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        knownSaltBase64: String? = nil,
        knownKeyFingerprint: String? = nil,
        knownRemoteBlobs: Set<String> = [],
        session: URLSession? = nil
    ) async throws -> WebDAVShardedPushResult {
        guard EncryptedBackupService.isValidExportPassword(passphrase) else {
            throw EncryptedBackupError.emptyPassword
        }

        // Split payload and derive vault key off the main actor.
        let prepared = try await Task.detached(priority: .userInitiated) {
            let bundle = try WebDAVPayloadSharder.split(payload)

            var reuseSalt: Data? = nil
            var usableRemoteBlobs = Set<String>()
            if let knownSaltBase64,
               let decodedSalt = Data(base64Encoded: knownSaltBase64),
               decodedSalt.count >= 16,
               let knownKeyFingerprint, !knownKeyFingerprint.isEmpty {
                let probeKey = try WebDAVShardCrypto.deriveVaultKey(password: passphrase, salt: decodedSalt)
                if probeKey.keyFingerprint == knownKeyFingerprint {
                    reuseSalt = decodedSalt
                    usableRemoteBlobs = knownRemoteBlobs
                }
            }

            let vaultKey = try WebDAVShardCrypto.deriveVaultKey(password: passphrase, salt: reuseSalt)
            return (bundle, vaultKey, usableRemoteBlobs)
        }.value

        let bundle = prepared.0
        let vaultKey = prepared.1
        var confirmedRemoteBlobs = prepared.2

        var stats = WebDAVShardedSyncStats()
        let allHashes = bundle.blobs.keys.sorted()

        for hash in allHashes {
            if confirmedRemoteBlobs.contains(hash) {
                stats.skippedUploadBlobs += 1
                continue
            }
            let path = try blobPath(for: remotePath, hash: hash)
            // If we reused the same vault key salt, check whether the blob already exists on remote
            // before uploading it (avoids re-uploading after reinstalling or switching devices).
            if !knownRemoteBlobs.isEmpty || (knownSaltBase64 == vaultKey.saltBase64 && !vaultKey.saltBase64.isEmpty) {
                if let meta = try? await WebDAVSyncService.fetchRemoteMetadata(
                    serverURL: serverURL,
                    remotePath: path,
                    username: username,
                    password: password,
                    session: session
                ), meta.exists {
                    confirmedRemoteBlobs.insert(hash)
                    stats.skippedUploadBlobs += 1
                    continue
                }
            }
            guard let plaintext = bundle.blobs[hash] else { continue }
            let encryptedBlob = try WebDAVShardCrypto.encryptBlob(plaintext, hash: hash, masterKey: vaultKey.masterKey)
            _ = try await WebDAVSyncService.uploadRawData(
                encryptedBlob,
                contentType: "application/octet-stream",
                serverURL: serverURL,
                remotePath: path,
                username: username,
                password: password,
                session: session
            )
            confirmedRemoteBlobs.insert(hash)
            stats.uploadedBlobs += 1
        }

        let presentList = allHashes.filter { confirmedRemoteBlobs.contains($0) }
        let manifestData = try WebDAVShardCrypto.encryptManifest(
            bundle.manifest,
            presentBlobs: presentList,
            vaultKey: vaultKey
        )
        stats.manifestBytes = manifestData.count

        let mPath = manifestPath(for: remotePath)
        var putMeta = try await WebDAVSyncService.uploadRawData(
            manifestData,
            contentType: "application/json; charset=utf-8",
            serverURL: serverURL,
            remotePath: mPath,
            username: username,
            password: password,
            session: session
        )
        if putMeta.etag == nil && putMeta.lastModified == nil {
            putMeta = (try? await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: serverURL,
                remotePath: mPath,
                username: username,
                password: password,
                session: session
            )) ?? putMeta
        }

        return WebDAVShardedPushResult(
            metadata: putMeta,
            stats: stats,
            saltBase64: vaultKey.saltBase64,
            keyFingerprint: vaultKey.keyFingerprint,
            presentBlobs: presentList
        )
    }

    static func pullSharded(
        passphrase: String,
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        existingBooks: [UUID: BookVolume.Snapshot] = [:],
        existingAttachmentBlobs: [String: Data] = [:],
        session: URLSession? = nil
    ) async throws -> WebDAVShardedPullResult {
        let mPath = manifestPath(for: remotePath)
        let (manifestData, meta) = try await WebDAVSyncService.downloadRawData(
            serverURL: serverURL,
            remotePath: mPath,
            username: username,
            password: password,
            session: session
        )
        guard WebDAVShardCrypto.isShardedManifest(manifestData) else {
            throw WebDAVSyncError.notEncryptedBackup
        }

        let decrypted = try await Task.detached(priority: .userInitiated) {
            try WebDAVShardCrypto.decryptManifest(manifestData, password: passphrase)
        }.value

        let manifest = decrypted.manifest
        let envelope = decrypted.envelope
        let vaultKey = decrypted.vaultKey

        var stats = WebDAVShardedSyncStats()
        stats.manifestBytes = manifestData.count

        var resolvedBlobs: [String: Data] = existingAttachmentBlobs
        var requiredHashes = Set<String>()

        for ref in manifest.bookRefs {
            if existingBooks[ref.id] != nil {
                stats.skippedLocalBlobs += 1
            } else {
                requiredHashes.insert(ref.blobHash)
            }
        }
        for hash in WebDAVPayloadSharder.referencedAttachmentHashes(in: manifest) {
            if resolvedBlobs[hash] != nil {
                stats.skippedLocalBlobs += 1
            } else {
                requiredHashes.insert(hash)
            }
        }

        for hash in requiredHashes.sorted() {
            let path = try blobPath(for: remotePath, hash: hash)
            let (ciphertext, _) = try await WebDAVSyncService.downloadRawData(
                serverURL: serverURL,
                remotePath: path,
                username: username,
                password: password,
                session: session
            )
            let plaintext = try WebDAVShardCrypto.decryptBlob(ciphertext, hash: hash, masterKey: vaultKey.masterKey)
            resolvedBlobs[hash] = plaintext
            stats.downloadedBlobs += 1
        }

        let fullPayload = try WebDAVPayloadSharder.reassemble(
            manifest,
            blobs: resolvedBlobs,
            existingBooks: existingBooks
        )

        return WebDAVShardedPullResult(
            payload: fullPayload,
            metadata: meta,
            stats: stats,
            saltBase64: envelope.saltBase64,
            keyFingerprint: envelope.keyFingerprint,
            presentBlobs: envelope.presentBlobs
        )
    }

    static func blobsDirectoryPath(for remotePath: String) -> String {
        "\(shardRootPath(for: remotePath))/blobs"
    }

    struct OrphanGCReport: Equatable, Sendable {
        var scannedRemoteBlobs: Int
        var referencedBlobs: Int
        var orphanHashes: [String]
        var deletedCount: Int
        var failedCount: Int

        var summaryText: String {
            if orphanHashes.isEmpty {
                return String(localized: "云端共 \(scannedRemoteBlobs) 个分片，全部处于有效引用中，无需清理。")
            }
            if failedCount > 0 {
                return String(localized: "已清理 \(deletedCount) 个孤儿分片，\(failedCount) 个删除失败。")
            }
            return String(localized: "已安全清理 \(deletedCount) 个未引用的云端孤儿分片（保留 \(referencedBlobs) 个有效分片）。")
        }
    }

    /// Lists `shards/blobs/`, compares against the decrypted remote manifest (plus any locally protected hashes),
    /// and deletes unreferenced `<sha256>.enc.bin` shards.
    static func pruneOrphanBlobs(
        passphrase: String,
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        extraProtectedHashes: Set<String> = [],
        dryRun: Bool = false,
        session: URLSession? = nil
    ) async throws -> OrphanGCReport {
        let mPath = manifestPath(for: remotePath)
        let (manifestData, _) = try await WebDAVSyncService.downloadRawData(
            serverURL: serverURL,
            remotePath: mPath,
            username: username,
            password: password,
            session: session
        )
        guard WebDAVShardCrypto.isShardedManifest(manifestData) else {
            throw WebDAVSyncError.notEncryptedBackup
        }

        let decrypted = try await Task.detached(priority: .userInitiated) {
            try WebDAVShardCrypto.decryptManifest(manifestData, password: passphrase)
        }.value

        var referenced = extraProtectedHashes
        for ref in decrypted.manifest.bookRefs {
            referenced.insert(ref.blobHash)
        }
        referenced.formUnion(WebDAVPayloadSharder.referencedAttachmentHashes(in: decrypted.manifest))

        let childNames = try await WebDAVSyncService.listDirectoryFilenames(
            serverURL: serverURL,
            directoryPath: blobsDirectoryPath(for: remotePath),
            username: username,
            password: password,
            session: session
        )

        var validRemoteHashes: [String] = []
        for name in childNames {
            guard name.hasSuffix(".enc.bin") else { continue }
            let hash = String(name.dropLast(".enc.bin".count))
            if WebDAVPayloadSharder.isValidBlobHash(hash) {
                validRemoteHashes.append(hash)
            }
        }

        let orphans = validRemoteHashes.filter { !referenced.contains($0) }.sorted()
        var deleted = 0
        var failed = 0
        if !dryRun {
            for hash in orphans {
                try Task.checkCancellation()
                let path = try blobPath(for: remotePath, hash: hash)
                do {
                    try await WebDAVSyncService.deleteFile(
                        serverURL: serverURL,
                        remotePath: path,
                        username: username,
                        password: password,
                        session: session
                    )
                    deleted += 1
                } catch {
                    failed += 1
                }
            }
        }

        return OrphanGCReport(
            scannedRemoteBlobs: validRemoteHashes.count,
            referencedBlobs: validRemoteHashes.count - orphans.count,
            orphanHashes: orphans,
            deletedCount: deleted,
            failedCount: failed
        )
    }
}
