import Foundation

enum SyncEntityKind: String, Codable, Hashable, CaseIterable, Sendable {
    case conversation
    case memory
    case book
    case preset
    case personaProfile
    case provider
    case readingAnnotation
}

struct SyncTombstoneKey: Hashable, Sendable {
    let kind: SyncEntityKind
    let id: UUID
}

struct SyncTombstone: Codable, Hashable, Sendable {
    var kind: SyncEntityKind
    var id: UUID
    var deletedAt: Date

    var key: SyncTombstoneKey {
        SyncTombstoneKey(kind: kind, id: id)
    }
}

/// Controls how `BackupService.apply` handles deletion tombstones.
/// - `.ignore`: Manual backup restores must be able to bring back previously deleted items;
///   any restored item clears its stale local tombstone so subsequent syncs keep it.
/// - `.enforce`: Multi-device sync merges tombstones, prevents resurrecting deleted items,
///   and propagates deletions to locally present items older than `deletedAt`.
enum SyncTombstonePolicy {
    case ignore
    case enforce(SyncTombstoneStore)
}

/// Sidecar store tracking entity deletions across devices without modifying frozen SwiftData schemas.
final class SyncTombstoneStore: @unchecked Sendable {
    static let shared = SyncTombstoneStore()

    static let retentionInterval: TimeInterval = 180 * 24 * 3600
    static let maximumEntries = 10_000

    private let lock = NSLock()
    private let fileURL: URL?
    private var inMemory: [SyncTombstoneKey: Date] = [:]
    private var hasLoadedFromDisk = false

    init(fileURL: URL? = SyncTombstoneStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("sync-tombstones.json")
    }

    func recordDeletion(kind: SyncEntityKind, id: UUID, at date: Date = Date()) {
        recordDeletions(kind: kind, ids: [id], at: date)
    }

    func recordDeletions(kind: SyncEntityKind, ids: [UUID], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            var map = loadLocked(now: date)
            var mutated = false
            for id in ids {
                let key = SyncTombstoneKey(kind: kind, id: id)
                if let existing = map[key], existing >= date {
                    continue
                }
                map[key] = date
                mutated = true
            }
            if mutated {
                pruneLocked(&map, now: date)
                persistLocked(map)
            }
        }
    }

    func removeTombstone(kind: SyncEntityKind, id: UUID) {
        removeTombstones([(kind, id)])
    }

    func removeTombstones(_ items: [(SyncEntityKind, UUID)]) {
        guard !items.isEmpty else { return }
        lock.withLock {
            var map = loadLocked(now: Date())
            var mutated = false
            for (kind, id) in items {
                if map.removeValue(forKey: SyncTombstoneKey(kind: kind, id: id)) != nil {
                    mutated = true
                }
            }
            if mutated {
                persistLocked(map)
            }
        }
    }

    func latestDeletion(kind: SyncEntityKind, id: UUID, now: Date = Date()) -> Date? {
        lock.withLock {
            loadLocked(now: now)[SyncTombstoneKey(kind: kind, id: id)]
        }
    }

    func tombstoneMap(now: Date = Date()) -> [SyncTombstoneKey: Date] {
        lock.withLock {
            loadLocked(now: now)
        }
    }

    func allTombstones(now: Date = Date()) -> [SyncTombstone] {
        let map = tombstoneMap(now: now)
        return Self.sortedList(from: map)
    }

    func count(now: Date = Date()) -> Int {
        tombstoneMap(now: now).count
    }

    @discardableResult
    func merge(_ incoming: [SyncTombstone], removing cleared: [SyncTombstoneKey] = [], now: Date = Date()) -> [SyncTombstone] {
        lock.withLock {
            var map = loadLocked(now: now)
            let cutoff = now.addingTimeInterval(-Self.retentionInterval)
            var mutated = false
            for item in incoming where item.deletedAt >= cutoff {
                if let existing = map[item.key], existing >= item.deletedAt {
                    continue
                }
                map[item.key] = item.deletedAt
                mutated = true
            }
            for key in cleared {
                if map.removeValue(forKey: key) != nil {
                    mutated = true
                }
            }
            if pruneLocked(&map, now: now) || mutated {
                persistLocked(map)
            }
            return Self.sortedList(from: map)
        }
    }

    func clearAll() {
        lock.withLock {
            inMemory.removeAll()
            hasLoadedFromDisk = true
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - Persistence

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func sortedList(from map: [SyncTombstoneKey: Date]) -> [SyncTombstone] {
        map.map { SyncTombstone(kind: $0.key.kind, id: $0.key.id, deletedAt: $0.value) }
            .sorted { lhs, rhs in
                if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt > rhs.deletedAt }
                if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private struct RawTombstone: Decodable {
        var kind: String
        var id: UUID
        var deletedAt: Date
    }

    private func loadLocked(now: Date) -> [SyncTombstoneKey: Date] {
        if let fileURL, !hasLoadedFromDisk {
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? Self.makeDecoder().decode([RawTombstone].self, from: data) {
                inMemory = Dictionary(
                    decoded.compactMap { raw in
                        SyncEntityKind(rawValue: raw.kind).map { (SyncTombstoneKey(kind: $0, id: raw.id), raw.deletedAt) }
                    },
                    uniquingKeysWith: { max($0, $1) }
                )
            } else {
                inMemory = [:]
            }
            hasLoadedFromDisk = true
        }
        var map = inMemory
        _ = pruneLocked(&map, now: now)
        return map
    }

    @discardableResult
    private func pruneLocked(_ map: inout [SyncTombstoneKey: Date], now: Date) -> Bool {
        let initialCount = map.count
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        map = map.filter { $0.value >= cutoff }
        if map.count > Self.maximumEntries {
            let kept = Self.sortedList(from: map).prefix(Self.maximumEntries)
            map = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.deletedAt) })
        }
        return map.count != initialCount
    }

    private func persistLocked(_ map: [SyncTombstoneKey: Date]) {
        inMemory = map
        hasLoadedFromDisk = true
        if let fileURL {
            let list = Self.sortedList(from: map)
            if let data = try? Self.makeEncoder().encode(list) {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
}
