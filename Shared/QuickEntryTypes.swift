import Foundation

enum QuickEntryWidgetKind {
    static let quickLaunch = "com.iosbox.widget.quick-launch"
}

enum QuickEntryAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case newChat = "new-chat"
    case voiceNote = "voice-note"
    case scanDocument = "scan-document"
    case bookmarks = "bookmarks"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newChat: return String(localized: "新建对话")
        case .voiceNote: return String(localized: "录音纪要")
        case .scanDocument: return String(localized: "扫描文档")
        case .bookmarks: return String(localized: "收藏知识库")
        }
    }

    var shortTitle: String {
        switch self {
        case .newChat: return String(localized: "新对话")
        case .voiceNote: return String(localized: "录音")
        case .scanDocument: return String(localized: "扫文档")
        case .bookmarks: return String(localized: "收藏")
        }
    }

    var subtitle: String {
        switch self {
        case .newChat: return String(localized: "立即开始文字提问")
        case .voiceNote: return String(localized: "语音速记与会议纪要")
        case .scanDocument: return String(localized: "拍照扫描 + 本地 OCR")
        case .bookmarks: return String(localized: "查看已收藏问答片段")
        }
    }

    var systemImage: String {
        switch self {
        case .newChat: return "square.and.pencil"
        case .voiceNote: return "waveform.and.mic"
        case .scanDocument: return "doc.viewfinder"
        case .bookmarks: return "bookmark.fill"
        }
    }

    var deepLinkURL: URL {
        URL(string: "iosbox://action/\(rawValue)")!
    }

    var shortcutItemType: String {
        "com.iosbox.quickaction.\(rawValue)"
    }

    init?(shortcutType: String) {
        let prefix = "com.iosbox.quickaction."
        guard shortcutType.hasPrefix(prefix) else { return nil }
        self.init(rawValue: String(shortcutType.dropFirst(prefix.count)))
    }
}

enum SystemDeepLink: Equatable, Sendable {
    case conversation(UUID)
    case action(QuickEntryAction)

    static func parse(_ url: URL) -> SystemDeepLink? {
        guard url.scheme?.lowercased() == "iosbox",
              let host = url.host?.lowercased(),
              let rawSegment = url.pathComponents.first(where: { $0 != "/" && !$0.isEmpty }) else {
            return nil
        }

        switch host {
        case "conversation":
            guard let id = UUID(uuidString: rawSegment) else { return nil }
            return .conversation(id)
        case "action":
            guard let action = QuickEntryAction(rawValue: rawSegment.lowercased()) else { return nil }
            return .action(action)
        default:
            return nil
        }
    }
}

/// Thread-safe handoff box for foreground quick-entry AppIntents and Home Screen Quick Actions.
final class QuickEntryInbox: @unchecked Sendable {
    static let shared = QuickEntryInbox()
    static let didReceiveActionNotification = Notification.Name("IOSBoxQuickEntryActionRequested")

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var pendingAction: QuickEntryAction?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func enqueue(_ action: QuickEntryAction) {
        lock.withLock {
            pendingAction = action
        }
        if Thread.isMainThread {
            notificationCenter.post(name: Self.didReceiveActionNotification, object: nil)
        } else {
            DispatchQueue.main.async { [notificationCenter] in
                notificationCenter.post(name: Self.didReceiveActionNotification, object: nil)
            }
        }
    }

    func consume() -> QuickEntryAction? {
        lock.withLock {
            let value = pendingAction
            pendingAction = nil
            return value
        }
    }
}

struct WidgetRecentConversation: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var isPinned: Bool
}

struct WidgetSnapshot: Codable, Equatable, Sendable {
    var updatedAt: Date
    var readyModelCount: Int
    var bookmarkedCount: Int
    var showRecentTitles: Bool
    var recentConversations: [WidgetRecentConversation]

    static let empty = WidgetSnapshot(
        updatedAt: Date.distantPast,
        readyModelCount: 0,
        bookmarkedCount: 0,
        showRecentTitles: false,
        recentConversations: []
    )

    func samePayload(as other: WidgetSnapshot) -> Bool {
        readyModelCount == other.readyModelCount
            && bookmarkedCount == other.bookmarkedCount
            && showRecentTitles == other.showRecentTitles
            && recentConversations == other.recentConversations
    }
}

struct WidgetSnapshotStore {
    private static let maxSnapshotBytes = 256 * 1024
    private let explicitFileURL: URL?

    init(fileURL: URL? = nil) {
        self.explicitFileURL = fileURL
    }

    func resolvedFileURL() -> URL? {
        if let explicitFileURL { return explicitFileURL }
        let groupID = Bundle.main.object(forInfoDictionaryKey: "IOSBoxAppGroup") as? String ?? "group.com.iosbox.app"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return nil
        }
        return container
            .appendingPathComponent("Widgets", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    func load() -> WidgetSnapshot {
        guard let url = resolvedFileURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maxSnapshotBytes + 1) ?? Data()
            guard data.count <= Self.maxSnapshotBytes else { return .empty }
            return try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        } catch {
            return .empty
        }
    }

    func save(_ snapshot: WidgetSnapshot) throws {
        guard let url = resolvedFileURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var dirResource = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirResource.setResourceValues(values)
        var fileResource = url
        try? fileResource.setResourceValues(values)
    }
}
