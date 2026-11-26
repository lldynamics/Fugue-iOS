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

private final class WebDAVBackgroundSyncGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var expired = false

    func attachTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return expired
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func setBackgroundTaskID(_ id: UIBackgroundTaskIdentifier) {
        lock.withLock {
            backgroundTaskID = id
        }
    }

    func expire() {
        let (taskToCancel, idToEnd) = lock.withLock { () -> (Task<Void, Never>?, UIBackgroundTaskIdentifier) in
            expired = true
            let currentID = backgroundTaskID
            backgroundTaskID = .invalid
            return (task, currentID)
        }
        taskToCancel?.cancel()
        Self.endBackgroundTaskOnMain(idToEnd)
    }

    func finish() {
        let idToEnd = lock.withLock { () -> UIBackgroundTaskIdentifier in
            task = nil
            let currentID = backgroundTaskID
            backgroundTaskID = .invalid
            return currentID
        }
        Self.endBackgroundTaskOnMain(idToEnd)
    }

    private static func endBackgroundTaskOnMain(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(id)
            }
        } else {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(id)
            }
        }
    }
}

@MainActor
@Observable
final class WebDAVAutoSyncCoordinator {
    static let shared = WebDAVAutoSyncCoordinator()

    private enum StorageKeys {
        static let localChangeGeneration = "iosbox.webdav.localChangeGeneration"
        static let syncedChangeGeneration = "iosbox.webdav.syncedChangeGeneration"
    }

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var isSyncing = false
    private(set) var localChangeGeneration: UInt64 {
        didSet { defaults.set(NSNumber(value: localChangeGeneration), forKey: StorageKeys.localChangeGeneration) }
    }
    private(set) var syncedChangeGeneration: UInt64 {
        didSet { defaults.set(NSNumber(value: syncedChangeGeneration), forKey: StorageKeys.syncedChangeGeneration) }
    }
    @ObservationIgnored private var isApplyingRemoteMerge = false
    private(set) var lastStatusMessage: String?
    private(set) var lastSyncError: String?
    private(set) var remoteMetadata: WebDAVRemoteMetadata?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedLocal = (defaults.object(forKey: StorageKeys.localChangeGeneration) as? NSNumber)?.uint64Value ?? 0
        let savedSynced = (defaults.object(forKey: StorageKeys.syncedChangeGeneration) as? NSNumber)?.uint64Value ?? 0
        self.localChangeGeneration = savedLocal
        self.syncedChangeGeneration = savedSynced
    }

    var hasLocalChangesPending: Bool {
        localChangeGeneration != syncedChangeGeneration
    }

    func markLocalDataChanged() {
        guard !isApplyingRemoteMerge else { return }
        localChangeGeneration &+= 1
    }

    func markWorkspaceChanged(in context: ModelContext) {
        guard !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) else { return }
        AppPreferences.shared.webDAVWorkspaceChangeID = UUID().uuidString
    }

    func checkRemoteStatus(
        preferences suppliedPreferences: AppPreferences? = nil,
        session: URLSession? = nil
    ) async -> WebDAVRemoteMetadata? {
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
                password: password,
                session: session
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
        preferences suppliedPreferences: AppPreferences? = nil,
        credentials suppliedCredentials: (password: String, passphrase: String)? = nil,
        session: URLSession? = nil
    ) async {
        let preferences = suppliedPreferences ?? .shared
        guard !isSyncing else { return }
        guard PersistenceController.canCommitUserData(in: context) else { return }
        guard context.container.configurations.allSatisfy({ !$0.isStoredInMemoryOnly }) else { return }
        guard trigger == .manualSmart || preferences.webDAVAutoSyncEnabled else { return }

        let serverURL = preferences.webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = preferences.webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotePath = preferences.webDAVRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = suppliedCredentials?.password ?? KeychainService.shared.loadSecret(account: WebDAVSyncService.webDAVPasswordAccount)
        let passphrase = suppliedCredentials?.passphrase ?? KeychainService.shared.loadSecret(account: WebDAVSyncService.webDAVPassphraseAccount)

        guard !serverURL.isEmpty,
              !username.isEmpty,
              !password.isEmpty,
              EncryptedBackupService.isValidExportPassword(passphrase) else {
            return
        }

        let backgroundGuard = WebDAVBackgroundSyncGuard()
        if trigger == .background {
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "WebDAVAutoSync") {
                backgroundGuard.expire()
            }
            backgroundGuard.setBackgroundTaskID(taskID)
        }
        defer { backgroundGuard.finish() }

        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let syncTask = Task { @MainActor in
            await self.performSync(
                trigger: trigger,
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                passphrase: passphrase,
                context: context,
                preferences: preferences,
                session: session
            )
        }
        backgroundGuard.attachTask(syncTask)
        await syncTask.value
    }

    private func performSync(
        trigger: WebDAVSyncTrigger,
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        context: ModelContext,
        preferences: AppPreferences,
        session: URLSession?
    ) async {
        do {
            try Task.checkCancellation()
            let generationAtStart = localChangeGeneration
            let remoteMeta = try await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                session: session
            )
            remoteMetadata = remoteMeta
            try Task.checkCancellation()

            let cooldown = TimeInterval(preferences.webDAVAutoSyncIntervalMinutes * 60)
            let decision = WebDAVAutoSyncPolicy.decide(
                trigger: trigger,
                remote: remoteMeta,
                knownETag: preferences.webDAVLastRemoteETag,
                knownModifiedAt: preferences.webDAVLastRemoteModifiedAt,
                localDirty: hasLocalChangesPending || !preferences.webDAVWorkspaceChangeID.isEmpty,
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
                    preferences: preferences,
                    session: session
                )
                syncedChangeGeneration = generationAtStart
                let message = String(localized: "已从云端合并：\(summary.title)")
                lastStatusMessage = message
                preferences.webDAVLastAutoSyncSummary = message

            case .pushOnly:
                let conflictSummary = try await pushWithSingleConflictRetry(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    expectedRemoteMeta: remoteMeta,
                    context: context,
                    preferences: preferences,
                    session: session
                )
                let message: String
                if let conflictSummary {
                    message = String(localized: "检测到云端并发更新，已合并并上传：\(conflictSummary.title)")
                } else {
                    message = String(localized: "已自动加密上传最新备份。")
                }
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
                    preferences: preferences,
                    session: session,
                    updateLastSyncAt: false
                )
                _ = try await pushWithSingleConflictRetry(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    expectedRemoteMeta: remoteMeta,
                    context: context,
                    preferences: preferences,
                    session: session
                )
                let message = String(localized: "已双向合并并上传更新：\(summary.title)")
                lastStatusMessage = message
                preferences.webDAVLastAutoSyncSummary = message
            }
        } catch is CancellationError {
            return
        } catch {
            lastSyncError = error.localizedDescription
            preferences.webDAVLastAutoSyncSummary = error.localizedDescription
        }
    }

    func recordSyncedRemoteMetadata(
        _ metadata: WebDAVRemoteMetadata,
        syncDate: Date = Date(),
        uploadedWorkspaceChangeID: String? = nil,
        updateLastSyncAt: Bool = true,
        preferences suppliedPreferences: AppPreferences? = nil
    ) {
        let preferences = suppliedPreferences ?? .shared
        remoteMetadata = metadata
        if let etag = metadata.etag, !etag.isEmpty {
            preferences.webDAVLastRemoteETag = etag
        } else if metadata.exists {
            preferences.webDAVLastRemoteETag = ""
        }
        if let mod = metadata.lastModified {
            preferences.webDAVLastRemoteModifiedAt = mod
        } else if metadata.exists && (metadata.etag?.isEmpty != false) {
            preferences.webDAVLastRemoteModifiedAt = syncDate
        }
        if updateLastSyncAt {
            preferences.webDAVLastSyncAt = syncDate
        }
        if let uploadedWorkspaceChangeID, uploadedWorkspaceChangeID == preferences.webDAVWorkspaceChangeID {
            preferences.webDAVWorkspaceChangeID = ""
        }
    }

    func clearCachedState(preferences suppliedPreferences: AppPreferences? = nil) {
        let preferences = suppliedPreferences ?? .shared
        remoteMetadata = nil
        lastStatusMessage = nil
        lastSyncError = nil
        syncedChangeGeneration = localChangeGeneration
        preferences.webDAVAutoSyncEnabled = false
        preferences.webDAVLastRemoteETag = ""
        preferences.webDAVLastRemoteModifiedAt = nil
        preferences.webDAVLastAutoSyncSummary = ""
        preferences.webDAVLastSyncAt = nil
    }

    private func pushWithSingleConflictRetry(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        expectedRemoteMeta: WebDAVRemoteMetadata,
        context: ModelContext,
        preferences: AppPreferences,
        session: URLSession?
    ) async throws -> ImportSummary? {
        let pushGeneration = localChangeGeneration
        do {
            try await exportAndPush(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                passphrase: passphrase,
                expectedRemoteMeta: expectedRemoteMeta,
                context: context,
                preferences: preferences,
                session: session
            )
            syncedChangeGeneration = pushGeneration
            return nil
        } catch WebDAVSyncError.preconditionFailed {
            try Task.checkCancellation()
            let latestMeta = try await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                session: session
            )
            remoteMetadata = latestMeta
            var mergedSummary: ImportSummary?
            if latestMeta.exists {
                mergedSummary = try await pullAndMerge(
                    serverURL: serverURL,
                    remotePath: remotePath,
                    username: username,
                    password: password,
                    passphrase: passphrase,
                    remoteMeta: latestMeta,
                    context: context,
                    preferences: preferences,
                    session: session,
                    updateLastSyncAt: false
                )
            }
            let retryGeneration = localChangeGeneration
            try await exportAndPush(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                passphrase: passphrase,
                expectedRemoteMeta: latestMeta,
                context: context,
                preferences: preferences,
                session: session
            )
            syncedChangeGeneration = retryGeneration
            return mergedSummary
        }
    }

    private func pullAndMerge(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        remoteMeta: WebDAVRemoteMetadata,
        context: ModelContext,
        preferences: AppPreferences,
        session: URLSession?,
        updateLastSyncAt: Bool = true
    ) async throws -> ImportSummary {
        let data = try await WebDAVSyncService.downloadEncryptedData(
            serverURL: serverURL,
            remotePath: remotePath,
            username: username,
            password: password,
            session: session
        )
        try Task.checkCancellation()
        let payload = try await Task.detached(priority: .userInitiated) {
            try EncryptedBackupService.decryptPayload(data: data, password: passphrase)
        }.value
        try Task.checkCancellation()

        isApplyingRemoteMerge = true
        let summary: ImportSummary
        do {
            summary = try EncryptedBackupService.applyDecryptedPayload(
                payload,
                to: context,
                tombstonePolicy: .enforce(.shared)
            )
            isApplyingRemoteMerge = false
        } catch {
            isApplyingRemoteMerge = false
            throw error
        }

        recordSyncedRemoteMetadata(
            remoteMeta,
            updateLastSyncAt: updateLastSyncAt,
            preferences: preferences
        )
        WidgetSnapshotService.shared.sync(context: context, forceReload: true)
        return summary
    }

    private func exportAndPush(
        serverURL: String,
        remotePath: String,
        username: String,
        password: String,
        passphrase: String,
        expectedRemoteMeta: WebDAVRemoteMetadata,
        context: ModelContext,
        preferences: AppPreferences,
        session: URLSession?
    ) async throws {
        try Task.checkCancellation()
        let workspaceChangeID = preferences.webDAVWorkspaceChangeID
        let payload = try EncryptedBackupService.makeExportPayload(
            context: context,
            tombstoneStore: .shared
        )

        let uploadFileURL = try await Task.detached(priority: .userInitiated) {
            let encryptedData = try EncryptedBackupService.encryptPayload(payload, password: passphrase)
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("webdav-sync-\(UUID().uuidString).enc.json")
            try encryptedData.write(to: tempURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return tempURL
        }.value
        defer { try? FileManager.default.removeItem(at: uploadFileURL) }
        try Task.checkCancellation()

        let putMeta = try await WebDAVSyncService.uploadEncryptedFile(
            uploadFileURL,
            serverURL: serverURL,
            remotePath: remotePath,
            username: username,
            password: password,
            ifMatchETag: expectedRemoteMeta.exists ? expectedRemoteMeta.etag : nil,
            ifNoneMatchStar: !expectedRemoteMeta.exists,
            session: session
        )

        var finalMeta = putMeta
        if finalMeta.etag == nil {
            if let fetched = try? await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: serverURL,
                remotePath: remotePath,
                username: username,
                password: password,
                session: session
            ), fetched.exists {
                finalMeta = WebDAVRemoteMetadata(
                    exists: true,
                    etag: fetched.etag ?? putMeta.etag,
                    lastModified: fetched.lastModified ?? putMeta.lastModified,
                    contentLength: fetched.contentLength ?? putMeta.contentLength
                )
            }
        }
        recordSyncedRemoteMetadata(finalMeta, uploadedWorkspaceChangeID: workspaceChangeID, preferences: preferences)
    }
}
