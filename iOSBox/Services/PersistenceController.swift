import Foundation
import SwiftData
import os

/// Builds the app's `ModelContainer`. Instead of crashing on launch when the store can't be
/// opened (e.g. an incompatible schema change), it moves the old store files to a timestamped
/// backup folder, creates a fresh store, and reports a notice for the UI to show.
enum PersistenceController {
    struct Result {
        let container: ModelContainer
        /// Non-nil when the store had to be rebuilt; shown to the user once.
        let startupNotice: String?
    }

    private static let logger = Logger(subsystem: "com.iosbox.app", category: "Persistence")

    static func makeContainer() -> Result {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try open(schema: schema, configuration: configuration)
            return Result(container: container, startupNotice: nil)
        } catch {
            logger.error("Failed to open store: \(String(describing: error), privacy: .public)")
        }

        // Recovery path: keep the user's data on disk, then start fresh.
        let backupFolder = backupStoreFiles(at: configuration.url)
        do {
            let container = try open(schema: schema, configuration: configuration)
            let location = backupFolder.map { String(localized: "已将旧数据库备份到 App 的 Application Support/\($0.lastPathComponent) 目录。") }
                ?? String(localized: "旧数据库备份失败。")
            return Result(
                container: container,
                startupNotice: String(localized: "本地数据库无法打开，已为你创建新的数据库。\(location)")
            )
        } catch {
            logger.fault("Failed to recreate store: \(String(describing: error), privacy: .public)")
        }

        // Last resort: keep the app usable for this session.
        do {
            let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: schema, configurations: [memoryConfig])
            return Result(
                container: container,
                startupNotice: String(localized: "本地数据库无法创建，本次运行的数据不会被保存。请检查设备存储空间后重启 App。")
            )
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

    /// Moves `default.store` and its `-wal` / `-shm` siblings (plus the external-storage
    /// support folder) into `Application Support/StoreBackup-<timestamp>/`.
    private static func backupStoreFiles(at storeURL: URL) -> URL? {
        let fm = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupFolder = directory.appendingPathComponent("StoreBackup-\(stamp)", isDirectory: true)
        let storeName = storeURL.lastPathComponent
        let externalSupport = ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT"
        let candidates = [storeName, storeName + "-wal", storeName + "-shm", externalSupport]

        do {
            try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
            for name in candidates {
                let source = directory.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.moveItem(at: source, to: backupFolder.appendingPathComponent(name))
            }
            return backupFolder
        } catch {
            logger.error("Store backup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
