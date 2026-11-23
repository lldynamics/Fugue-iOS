import Foundation
import SwiftData
import UIKit
import os

/// Builds the app's `ModelContainer`. Transient environment errors (locked device before first unlock,
/// file lock contention, or out-of-space) fall back to an in-memory recovery container without touching
/// the user's on-disk database. Only confirmed store corruption or incompatible schema errors archive
/// the damaged files and initialize a clean store.
enum PersistenceController {
    struct Result {
        let container: ModelContainer
        /// Non-nil when the store had to be rebuilt or entered temporary recovery; shown to the user.
        let startupNotice: String?
    }

    private static let logger = Logger(subsystem: "com.iosbox.app", category: "Persistence")
    private static let recoveryStoreName = "TransientRecovery"
    static let pendingRebuildNoticeKey = "com.iosbox.pendingDatabaseRebuildNotice.v1"

    static func makeRecoveryContainer(schema: Schema) throws -> ModelContainer {
        // SwiftData needs a writable backing store to initialize its in-memory SQLite schema.
        let configuration = ModelConfiguration(
            recoveryStoreName,
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func canCommitUserData(in context: ModelContext) -> Bool {
        let configurations = context.container.configurations
        return !configurations.isEmpty && configurations.allSatisfy {
            $0.allowsSave && !($0.isStoredInMemoryOnly && $0.name == recoveryStoreName)
        }
    }

    static func pendingRebuildNotice(in defaults: UserDefaults = .standard) -> String? {
        guard let text = defaults.string(forKey: pendingRebuildNoticeKey), !text.isEmpty else {
            return nil
        }
        return text
    }

    static func acknowledgePendingRebuildNotice(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingRebuildNoticeKey)
    }

    /// Returns `true` only when `error` indicates actual SQLite corruption or an unrecoverable
    /// schema/migration incompatibility, rather than device lock protection, disk full, or lock contention.
    static func shouldRebuildCorruptedStore(after error: Error, isProtectedDataAvailable: Bool) -> Bool {
        guard isProtectedDataAvailable else { return false }

        var queue: [NSError] = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        var sawCorruptionOrMigration = false

        while let current = queue.first {
            queue.removeFirst()
            let objectID = ObjectIdentifier(current)
            guard visited.insert(objectID).inserted else { continue }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let multiples = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                queue.append(contentsOf: multiples)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                queue.append(contentsOf: detailed)
            }

            if isTransientOrEnvironmentalError(current) {
                return false
            }
            if isCorruptionOrMigrationError(current) {
                sawCorruptionOrMigration = true
            }
        }

        return sawCorruptionOrMigration
    }

    private static func isTransientOrEnvironmentalError(_ nsError: NSError) -> Bool {
        switch nsError.domain {
        case NSCocoaErrorDomain:
            let transientCodes: Set<Int> = [
                NSFileLockingError,                  // 255
                NSFileReadNoPermissionError,         // 257
                NSFileWriteNoPermissionError,        // 513
                NSFileWriteOutOfSpaceError,          // 640
                NSFileWriteVolumeReadOnlyError       // 642
            ]
            if transientCodes.contains(nsError.code) { return true }
        case NSPOSIXErrorDomain:
            let transientPOSIX: Set<Int> = [
                Int(EPERM),   // 1
                Int(EACCES),  // 13
                Int(EBUSY),   // 16
                Int(ENOSPC),  // 28
                Int(EROFS),   // 30
                Int(EAGAIN)   // 35
            ]
            if transientPOSIX.contains(nsError.code) { return true }
        case "NSSQLiteErrorDomain":
            // 5 = SQLITE_BUSY, 6 = SQLITE_LOCKED, 13 = SQLITE_FULL, 23 = SQLITE_AUTH
            let transientSQLite: Set<Int> = [5, 6, 13, 23]
            if transientSQLite.contains(nsError.code) { return true }
        default:
            break
        }
        return false
    }

    private static func isCorruptionOrMigrationError(_ nsError: NSError) -> Bool {
        if nsError.domain == "NSSQLiteErrorDomain" {
            // 11 = SQLITE_CORRUPT, 26 = SQLITE_NOTADB
            if nsError.code == 11 || nsError.code == 26 { return true }
        }
        if nsError.domain == NSCocoaErrorDomain {
            // CoreData / SwiftData corrupt store or migration error range (134000...134200, 259 = damaged file)
            if (134000...134200).contains(nsError.code) || nsError.code == NSFileReadCorruptFileError {
                return true
            }
        }
        if nsError.domain.contains("SwiftData") {
            return true
        }
        return false
    }

    @MainActor
    static func makeContainer(defaults: UserDefaults = .standard) -> Result {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let protectedAvailable = UIApplication.shared.isProtectedDataAvailable

        if !protectedAvailable {
            logger.warning("Protected data unavailable during container init; entering non-destructive recovery container.")
            return fallbackRecoveryResult(
                schema: schema,
                notice: String(localized: "请解锁设备。受保护的数据可用后，将自动重新打开本地数据库。")
            )
        }

        do {
            try restoreInterruptedArchive(at: configuration.url)
        } catch {
            return fallbackRecoveryResult(schema: schema, notice: error.localizedDescription)
        }

        let initialError: Error
        do {
            let container = try open(schema: schema, configuration: configuration)
            return Result(container: container, startupNotice: pendingRebuildNotice(in: defaults))
        } catch {
            initialError = error
            logger.error("Failed to open store: \(String(describing: error), privacy: .public)")
        }

        guard shouldRebuildCorruptedStore(after: initialError, isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) else {
            logger.warning("Transient/environmental store open failure; preserving on-disk store without rebuild.")
            return fallbackRecoveryResult(
                schema: schema,
                notice: String(localized: "数据库可能正被占用、权限受限或存储空间不足。请检查设备存储空间后重试。")
            )
        }

        // Confirmed corruption / incompatible migration: atomically archive all store files first.
        // If backup fails, never overwrite the unarchived user database.
        let backupFolder: URL
        do {
            backupFolder = try backupStoreFiles(at: configuration.url)
        } catch let partial as IncompleteArchive {
            return fallbackRecoveryResult(schema: schema, notice: partial.localizedDescription)
        } catch {
            return fallbackRecoveryResult(
                schema: schema,
                notice: String(localized: "本地数据库异常且自动归档备份未成功（可能存储空间不足），为保护原有文件未覆盖数据库。请清理设备空间后重试。")
            )
        }

        do {
            let container = try open(schema: schema, configuration: configuration)
            DataSeeder.resetSeedFlagsForRebuiltStore(in: defaults)
            let location = String(localized: "已将旧数据库完整备份到 App 的 Application Support/\(backupFolder.lastPathComponent) 目录。")
            let notice = String(localized: "本地数据库结构损坏无法读取，已为你创建新的数据库。\(location)")
            defaults.set(notice, forKey: pendingRebuildNoticeKey)
            return Result(container: container, startupNotice: notice)
        } catch {
            logger.fault("Failed to recreate store: \(String(describing: error), privacy: .public)")
        }

        return fallbackRecoveryResult(
            schema: schema,
            notice: String(localized: "无法打开本地数据库。请检查设备存储空间后重试。")
        )
    }

    private static func fallbackRecoveryResult(schema: Schema, notice: String) -> Result {
        do {
            let container = try makeRecoveryContainer(schema: schema)
            return Result(container: container, startupNotice: notice)
        } catch {
            fatalError("无法初始化任何 ModelContainer: \(error)")
        }
    }

    static func open(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        let container = try ModelContainer(
            for: schema,
            migrationPlan: IOSBoxMigrationPlan.self,
            configurations: [configuration]
        )
        // Runs exactly once per process, before any UI or generation exists.
        InterruptedStreamRecovery.run(in: container)
        return container
    }

    struct IncompleteArchive: LocalizedError {
        let folder: URL
        var errorDescription: String? {
            String(localized: "数据库归档尚未复原。可恢复的文件保存在 Application Support/\(folder.lastPathComponent)，请检查可用空间和文件权限后重试。")
        }
    }

    private static func archiveMarker(for store: URL) -> URL {
        store.deletingLastPathComponent().appendingPathComponent(".\(store.lastPathComponent).archive-in-progress")
    }

    /// A marker is written before moving anything so a restart cannot create a blank database
    /// alongside a WAL or external storage left behind by an interrupted rollback.
    static func restoreInterruptedArchive(at store: URL, move: (URL, URL) throws -> Void = FileManager.default.moveItem(at:to:)) throws {
        let fm = FileManager.default
        let marker = archiveMarker(for: store)
        let name: String
        do {
            name = try String(contentsOf: marker, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
        guard name.hasPrefix("StoreBackup-"), !name.contains("/") else { throw CocoaError(.fileReadCorruptFile) }
        let folder = store.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        do {
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in files {
                try move(file, store.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent))
            }
            try fm.removeItem(at: marker)
            try? fm.removeItem(at: folder) // All archived files have been restored.
        } catch {
            throw IncompleteArchive(folder: folder)
        }
    }

    static func backupStoreFiles(at storeURL: URL, move: (URL, URL) throws -> Void = FileManager.default.moveItem(at:to:)) throws -> URL {
        let fm = FileManager.default
        try restoreInterruptedArchive(at: storeURL, move: move)
        let directory = storeURL.deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = directory.appendingPathComponent("StoreBackup-\(stamp)-\(UUID().uuidString)", isDirectory: true)
        let name = storeURL.lastPathComponent
        let candidates = [name, name + "-wal", name + "-shm", ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT"]
        let present = Set(try fm.contentsOfDirectory(atPath: directory.path))
        guard present.contains(name) else { throw CocoaError(.fileReadNoSuchFile) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let marker = archiveMarker(for: storeURL)
        do {
            try Data(folder.lastPathComponent.utf8).write(to: marker, options: .withoutOverwriting)
        } catch {
            try? fm.removeItem(at: folder) // No files have been moved yet.
            throw error
        }
        do {
            for candidate in candidates where present.contains(candidate) {
                try move(directory.appendingPathComponent(candidate), folder.appendingPathComponent(candidate))
            }
            try fm.removeItem(at: marker)
            return folder
        } catch {
            try restoreInterruptedArchive(at: storeURL, move: move)
            throw error
        }
    }
}
