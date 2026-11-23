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
            let meta = try await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password
            )
            remoteMetadata = meta
            lastSyncError = nil
            return meta
        } catch {
            lastSyncError = error.localizedDescription
            return nil
        }
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
            let remoteMeta = try await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password
            )
            remoteMetadata = remoteMeta

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
                    context: context,
                    preferences: preferences
                )
                hasLocalChangesPending = false
                let message = String(localized: "已从云端合并：\(summary.title)")
                lastStatusMessage = message
                preferences.webDAVLastAutoSyncSummary = message

            case .pushOnly:
                try await exportAndPush(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    context: context,
                    preferences: preferences
                )
                hasLocalChangesPending = false
                let message = String(localized: "已自动加密上传最新备份。")
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
                    context: context,
                    preferences: preferences
                )
                try await exportAndPush(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    context: context,
                    preferences: preferences
                )
                hasLocalChangesPending = false
                let message = String(localized: "已双向合并并上传更新：\(summary.title)")
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
        hasLocalChangesPending = false
        preferences.webDAVAutoSyncEnabled = false
        preferences.webDAVLastRemoteETag = ""
        preferences.webDAVLastRemoteModifiedAt = nil
        preferences.webDAVLastAutoSyncSummary = ""
        preferences.webDAVLastSyncAt = nil
    }

    private func pullAndMerge(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        remoteMeta: WebDAVRemoteMetadata,
        context: ModelContext,
        preferences: AppPreferences
    ) async throws -> ImportSummary {
        let data = try await WebDAVSyncService.downloadEncryptedData(
            serverURL: serverURL,
            remotePath: remotePath,
            username: username,
            password: password
        )
        let summary = try await EncryptedBackupService.decryptAndApplyAsync(
            data: data,
            password: passphrase,
            to: context
        )
        recordSyncedRemoteMetadata(remoteMeta, preferences: preferences)
        WidgetSnapshotService.shared.sync(context: context, forceReload: true)
        return summary
    }

    private func exportAndPush(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        context: ModelContext,
        preferences: AppPreferences
    ) async throws {
        let payload = try EncryptedBackupService.makeExportPayload(context: context)
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
        recordSyncedRemoteMetadata(finalMeta, preferences: preferences)
    }
}
