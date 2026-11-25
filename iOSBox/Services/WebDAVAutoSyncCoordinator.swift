import Foundation
import SwiftData
import UIKit

enum WebDAVSyncTrigger: Equatable, Sendable {
    case foreground
    case background
    case manualSmart
}

enum WebDAVSyncDecision: Equatable, Sendable {
    case skipCooldown
    case pullThenMerge
    case pushOnly
    case pullMergeThenPush
    case upToDate
}

enum WebDAVAutoSyncPolicy {
    static func isRemoteNewer(
        remote: WebDAVRemoteMetadata,
        knownETag: String,
        knownModifiedAt: Date?
    ) -> Bool {
        guard remote.exists else { return false }
        let cleanKnownETag = knownETag.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRemoteETag = remote.etag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanRemoteETag.isEmpty && !cleanKnownETag.isEmpty {
            return cleanRemoteETag != cleanKnownETag
        }
        if let remoteMod = remote.lastModified, let knownMod = knownModifiedAt {
            return remoteMod.timeIntervalSince(knownMod) > 1.0
        }
        if cleanKnownETag.isEmpty && knownModifiedAt == nil {
            return true
        }
        return false
    }

    static func decide(
        trigger: WebDAVSyncTrigger,
        remote: WebDAVRemoteMetadata,
        knownETag: String,
        knownModifiedAt: Date?,
        localDirty: Bool,
        lastSyncAt: Date?,
        cooldownSeconds: TimeInterval,
        now: Date
    ) -> WebDAVSyncDecision {
        if trigger != .manualSmart,
           let lastSyncAt,
           now.timeIntervalSince(lastSyncAt) < max(0, cooldownSeconds) {
            return .skipCooldown
        }

        let remoteChanged = isRemoteNewer(
            remote: remote,
            knownETag: knownETag,
            knownModifiedAt: knownModifiedAt
        )

        if !remote.exists {
            return (localDirty || trigger == .manualSmart || lastSyncAt == nil) ? .pushOnly : .upToDate
        }
        if remoteChanged && localDirty {
            return .pullMergeThenPush
        }
        if remoteChanged {
            return .pullThenMerge
        }
        if localDirty || trigger == .manualSmart {
            return .pushOnly
        }
        return .upToDate
    }
}

@MainActor
@Observable
final class WebDAVAutoSyncCoordinator {
    static let shared = WebDAVAutoSyncCoordinator()

    private(set) var isSyncing = false
    private(set) var hasLocalChangesPending = false
    private(set) var lastStatusMessage: String?
    private(set) var lastSyncError: String?
    private(set) var remoteMetadata: WebDAVRemoteMetadata?
    private(set) var lastShardedStats: WebDAVShardedSyncStats?
    private(set) var remoteUsesShards = false

    func markLocalDataChanged() {
        guard !isSyncing else { return }
        hasLocalChangesPending = true
    }

    func checkRemoteStatus(preferences suppliedPreferences: AppPreferences? = nil) async -> WebDAVRemoteMetadata? {
        let preferences = suppliedPreferences ?? .shared
        let serverURL = preferences.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = preferences.webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotePath = preferences.webDAVRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = KeychainService.shared.loadSecret(account: WebDAVSyncService.webDAVPasswordAccount)

        guard !serverURL.isEmpty, !username.isEmpty, !password.isEmpty else {
            return nil
        }

        do {
            let (meta, isSharded) = try await resolveRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                preferSharded: preferences.webDAVShardedSyncEnabled
            )
            remoteMetadata = meta
            remoteUsesShards = isSharded
            lastSyncError = nil
            return meta
        } catch {
            lastSyncError = error.localizedDescription
            return nil
        }
    }

    private func resolveRemoteMetadata(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        preferSharded: Bool,
        session: URLSession? = nil
    ) async throws -> (WebDAVRemoteMetadata, Bool) {
        if preferSharded {
            let shardMeta = try await WebDAVShardedSyncService.fetchManifestMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                session: session
            )
            if shardMeta.exists {
                return (shardMeta, true)
            }
        }
        let legacyMeta = try await WebDAVSyncService.fetchRemoteMetadata(
            serverURL: serverURL,
            remotePath: remotePath,
            username: username,
            password: password,
            session: session
        )
        return (legacyMeta, false)
    }

    func syncIfNeeded(
        trigger: WebDAVSyncTrigger,
        context: ModelContext,
        preferences suppliedPreferences: AppPreferences? = nil
    ) async {
        let preferences = suppliedPreferences ?? .shared
        guard !isSyncing else { return }
        guard PersistenceController.canCommitUserData(in: context) else { return }
        guard context.container.configurations.allSatisfy({ !$0.isStoredInMemoryOnly }) else { return }
        guard trigger == .manualSmart || preferences.webDAVAutoSyncEnabled else { return }

        let serverURL = preferences.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = preferences.webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotePath = preferences.webDAVRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = KeychainService.shared.loadSecret(account: WebDAVSyncService.webDAVPasswordAccount)
        let passphrase = KeychainService.shared.loadSecret(account: WebDAVSyncService.webDAVPassphraseAccount)

        guard !serverURL.isEmpty,
              !username.isEmpty,
              !password.isEmpty,
              EncryptedBackupService.isValidExportPassword(passphrase) else {
            return
        }

        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        if trigger == .background {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "WebDAVAutoSync") {
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
        }
        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        do {
            let (remoteMeta, isRemoteSharded) = try await resolveRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                preferSharded: preferences.webDAVShardedSyncEnabled
            )
            remoteMetadata = remoteMeta
            remoteUsesShards = isRemoteSharded

            let cooldown = TimeInterval(preferences.webDAVAutoSyncIntervalMinutes * 60)
            let decision = WebDAVAutoSyncPolicy.decide(
                trigger: trigger,
                remote: remoteMeta,
                knownETag: preferences.webDAVLastRemoteETag,
                knownModifiedAt: preferences.webDAVLastRemoteModifiedAt,
                localDirty: hasLocalChangesPending,
                lastSyncAt: preferences.webDAVLastSyncAt,
                cooldownSeconds: cooldown,
                now: Date()
            )

            switch decision {
            case .skipCooldown:
                return

            case .upToDate:
                let message = String(localized: "云端备份已处于最新一致状态。")
                lastStatusMessage = message
                preferences.webDAVLastAutoSyncSummary = message
                return

            case .pullThenMerge:
                let summary = try await pullAndMerge(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    remoteMeta: remoteMeta,
                    isRemoteSharded: isRemoteSharded,
                    context: context,
                    preferences: preferences
                )
                hasLocalChangesPending = false
                let message = String(localized: "已从云端合并：\(summary.title)")
                lastStatusMessage = message
                preferences.webDAVLastAutoSyncSummary = message

            case .pushOnly:
                let stats = try await exportAndPush(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    context: context,
                    preferences: preferences
                )
                hasLocalChangesPending = false
                let message = stats?.pushSummaryText ?? String(localized: "已自动加密上传最新备份。")
                lastStatusMessage = message
                preferences.webDAVLastAutoSyncSummary = message

            case .pullMergeThenPush:
                let summary = try await pullAndMerge(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    remoteMeta: remoteMeta,
                    isRemoteSharded: isRemoteSharded,
                    context: context,
                    preferences: preferences
                )
                let stats = try await exportAndPush(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    context: context,
                    preferences: preferences
                )
                hasLocalChangesPending = false
                let detail = stats.map { " \($0.pushSummaryText)" } ?? ""
                let message = String(localized: "已双向合并并上传更新：\(summary.title)") + detail
                lastStatusMessage = message
                preferences.webDAVLastAutoSyncSummary = message
            }
        } catch {
            lastSyncError = error.localizedDescription
            preferences.webDAVLastAutoSyncSummary = error.localizedDescription
        }
    }

    func recordSyncedRemoteMetadata(
        _ metadata: WebDAVRemoteMetadata,
        syncDate: Date = Date(),
        preferences suppliedPreferences: AppPreferences? = nil
    ) {
        let preferences = suppliedPreferences ?? .shared
        remoteMetadata = metadata
        if let etag = metadata.etag, !etag.isEmpty {
            preferences.webDAVLastRemoteETag = etag
        }
        if let mod = metadata.lastModified {
            preferences.webDAVLastRemoteModifiedAt = mod
        }
        preferences.webDAVLastSyncAt = syncDate
    }

    func clearCachedState(preferences suppliedPreferences: AppPreferences? = nil) {
        let preferences = suppliedPreferences ?? .shared
        remoteMetadata = nil
        lastStatusMessage = nil
        lastSyncError = nil
        lastShardedStats = nil
        remoteUsesShards = false
        hasLocalChangesPending = false
        preferences.webDAVAutoSyncEnabled = false
        preferences.webDAVLastRemoteETag = ""
        preferences.webDAVLastRemoteModifiedAt = nil
        preferences.webDAVLastAutoSyncSummary = ""
        preferences.webDAVLastSyncAt = nil
        preferences.webDAVKnownShardSalt = ""
        preferences.webDAVKnownShardKeyFingerprint = ""
        preferences.webDAVKnownRemoteBlobs = []
    }

    func recordShardState(
        saltBase64: String,
        keyFingerprint: String,
        presentBlobs: [String],
        stats: WebDAVShardedSyncStats,
        preferences suppliedPreferences: AppPreferences? = nil
    ) {
        let preferences = suppliedPreferences ?? .shared
        preferences.webDAVKnownShardSalt = saltBase64
        preferences.webDAVKnownShardKeyFingerprint = keyFingerprint
        preferences.webDAVKnownRemoteBlobs = presentBlobs
        lastShardedStats = stats
        remoteUsesShards = true
    }

    static func localBookSnapshots(in context: ModelContext) -> [UUID: BookVolume.Snapshot] {
        let volumes = (try? context.fetch(FetchDescriptor<BookVolume>())) ?? []
        var result: [UUID: BookVolume.Snapshot] = [:]
        for vol in volumes {
            if let snap = try? vol.snapshot() {
                result[vol.id] = snap
            }
        }
        return result
    }

    static func localAttachmentBlobs(in context: ModelContext) -> [String: Data] {
        let messages = (try? context.fetch(FetchDescriptor<ChatMessage>())) ?? []
        var blobs: [String: Data] = [:]
        for msg in messages {
            for att in msg.attachments {
                if let b64 = att.dataBase64, b64.utf8.count >= WebDAVPayloadSharder.attachmentShardThresholdBytes {
                    let raw = Data(b64.utf8)
                    blobs[WebDAVPayloadSharder.sha256Hex(raw)] = raw
                }
            }
        }
        return blobs
    }

    private func pullAndMerge(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        remoteMeta: WebDAVRemoteMetadata,
        isRemoteSharded: Bool,
        context: ModelContext,
        preferences: AppPreferences
    ) async throws -> ImportSummary {
        let summary: ImportSummary
        if isRemoteSharded {
            let existingBooks = Self.localBookSnapshots(in: context)
            let existingAttachments = Self.localAttachmentBlobs(in: context)
            let pulled = try await WebDAVShardedSyncService.pullSharded(
                passphrase: passphrase,
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                existingBooks: existingBooks,
                existingAttachmentBlobs: existingAttachments
            )
            summary = try EncryptedBackupService.applyDecryptedPayload(
                pulled.payload,
                to: context,
                tombstonePolicy: .enforce(.shared)
            )
            recordShardState(
                saltBase64: pulled.saltBase64,
                keyFingerprint: pulled.keyFingerprint,
                presentBlobs: pulled.presentBlobs,
                stats: pulled.stats,
                preferences: preferences
            )
            recordSyncedRemoteMetadata(pulled.metadata.exists ? pulled.metadata : remoteMeta, preferences: preferences)
        } else {
            let data = try await WebDAVSyncService.downloadEncryptedData(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password
            )
            summary = try await EncryptedBackupService.decryptAndApplyAsync(
                data: data,
                password: passphrase,
                to: context,
                tombstonePolicy: .enforce(.shared)
            )
            recordSyncedRemoteMetadata(remoteMeta, preferences: preferences)
        }
        WidgetSnapshotService.shared.sync(context: context, forceReload: true)
        return summary
    }

    @discardableResult
    private func exportAndPush(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        context: ModelContext,
        preferences: AppPreferences
    ) async throws -> WebDAVShardedSyncStats? {
        let payload = try EncryptedBackupService.makeExportPayload(
            context: context,
            tombstoneStore: .shared
        )

        if preferences.webDAVShardedSyncEnabled {
            let result = try await WebDAVShardedSyncService.pushSharded(
                payload: payload,
                passphrase: passphrase,
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                knownSaltBase64: preferences.webDAVKnownShardSalt.isEmpty ? nil : preferences.webDAVKnownShardSalt,
                knownKeyFingerprint: preferences.webDAVKnownShardKeyFingerprint.isEmpty ? nil : preferences.webDAVKnownShardKeyFingerprint,
                knownRemoteBlobs: Set(preferences.webDAVKnownRemoteBlobs)
            )
            recordShardState(
                saltBase64: result.saltBase64,
                keyFingerprint: result.keyFingerprint,
                presentBlobs: result.presentBlobs,
                stats: result.stats,
                preferences: preferences
            )
            recordSyncedRemoteMetadata(result.metadata, preferences: preferences)
            return result.stats
        }

        let encryptedData = try await Task.detached(priority: .userInitiated) {
            try EncryptedBackupService.encryptPayload(payload, password: passphrase)
        }.value

        let putMeta = try await WebDAVSyncService.uploadEncryptedData(
            encryptedData,
            serverURL: serverURL,
            remotePath: remotePath,
            username: username,
            password: password
        )

        var finalMeta = putMeta
        if finalMeta.etag == nil && finalMeta.lastModified == nil {
            finalMeta = (try? await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password
            )) ?? putMeta
        }
        lastShardedStats = nil
        remoteUsesShards = false
        recordSyncedRemoteMetadata(finalMeta, preferences: preferences)
        return nil
    }
}
