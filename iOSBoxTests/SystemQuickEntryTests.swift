import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class SystemQuickEntryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SystemEntryRouter.shared.conversationID = nil
        SystemEntryRouter.shared.messageID = nil
        SystemEntryRouter.shared.pendingQuickAction = nil
        SystemEntryRouter.shared.pendingChatToolRequest = nil
    }

    override func tearDown() {
        SystemEntryRouter.shared.conversationID = nil
        SystemEntryRouter.shared.messageID = nil
        SystemEntryRouter.shared.pendingQuickAction = nil
        SystemEntryRouter.shared.pendingChatToolRequest = nil
        super.tearDown()
    }

    func testSystemDeepLinkParsing() {
        let id = UUID()
        XCTAssertEqual(
            SystemDeepLink.parse(URL(string: "iosbox://conversation/\(id.uuidString)")!),
            .conversation(id)
        )
        XCTAssertEqual(
            SystemDeepLink.parse(URL(string: "IOSBOX://Conversation/\(id.uuidString)")!),
            .conversation(id)
        )

        for action in QuickEntryAction.allCases {
            XCTAssertEqual(SystemDeepLink.parse(action.deepLinkURL), .action(action))
            let upper = URL(string: "IOSBOX://ACTION/\(action.rawValue.uppercased())")!
            XCTAssertEqual(SystemDeepLink.parse(upper), .action(action))
        }

        XCTAssertNil(SystemDeepLink.parse(URL(string: "https://example.com/action/new-chat")!))
        XCTAssertNil(SystemDeepLink.parse(URL(string: "iosbox://unknown/new-chat")!))
        XCTAssertNil(SystemDeepLink.parse(URL(string: "iosbox://conversation/not-a-uuid")!))
        XCTAssertNil(SystemDeepLink.parse(URL(string: "iosbox://action/unknown-action")!))
        XCTAssertNil(SystemDeepLink.parse(URL(string: "iosbox://action")!))
    }

    func testQuickEntryActionShortcutTypeAndInboxRoundTrip() {
        for action in QuickEntryAction.allCases {
            XCTAssertEqual(QuickEntryAction(shortcutType: action.shortcutItemType), action)
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.shortTitle.isEmpty)
            XCTAssertFalse(action.subtitle.isEmpty)
            XCTAssertFalse(action.systemImage.isEmpty)
        }
        XCTAssertNil(QuickEntryAction(shortcutType: "com.other.app.new-chat"))

        let center = NotificationCenter()
        var notificationsCount = 0
        let token = center.addObserver(
            forName: QuickEntryInbox.didReceiveActionNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationsCount += 1
        }
        defer { center.removeObserver(token) }

        let inbox = QuickEntryInbox(notificationCenter: center)
        inbox.enqueue(.voiceNote)
        inbox.enqueue(.scanDocument)
        XCTAssertEqual(notificationsCount, 2)
        XCTAssertEqual(inbox.consume(), .scanDocument)
        XCTAssertNil(inbox.consume())
    }

    func testSystemEntryRouterRoutesURLsAndDrainsInbox() {
        let id = UUID()
        SystemEntryRouter.shared.messageID = UUID()
        XCTAssertTrue(SystemEntryRouter.shared.route(URL(string: "iosbox://conversation/\(id.uuidString)")!))
        XCTAssertEqual(SystemEntryRouter.shared.conversationID, id)
        XCTAssertNil(SystemEntryRouter.shared.messageID)

        XCTAssertTrue(SystemEntryRouter.shared.route(QuickEntryAction.bookmarks.deepLinkURL))
        XCTAssertEqual(SystemEntryRouter.shared.pendingQuickAction, .bookmarks)
        XCTAssertFalse(SystemEntryRouter.shared.route(URL(string: "iosbox://bad/path")!))

        let inbox = QuickEntryInbox(notificationCenter: NotificationCenter())
        inbox.enqueue(.newChat)
        SystemEntryRouter.shared.drainPendingInbox(from: inbox)
        XCTAssertEqual(SystemEntryRouter.shared.pendingQuickAction, .newChat)
        XCTAssertNil(inbox.consume())
    }

    func testWidgetSnapshotStoreAndPrivacyFiltering() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let store = WidgetSnapshotStore(fileURL: tempDir.appendingPathComponent("Widgets/snapshot.json"))
        XCTAssertEqual(store.load(), .empty)

        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let provider = ProviderConfig(
            name: "Local Test",
            protocolType: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            isEnabled: true,
            models: [
                ModelSpec(id: "model-a", displayName: "Model A"),
                ModelSpec(id: "model-b", displayName: "Model B")
            ]
        )
        context.insert(provider)

        let emptyConv = Conversation(title: "空草稿")
        let older = Conversation(title: "较早普通对话")
        older.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let olderMsg = ChatMessage(role: .user, content: "问题 1", sortIndex: 1)
        olderMsg.conversation = older
        older.messages = [olderMsg]

        let pinned = Conversation(title: "置顶重要对话")
        pinned.setPinned(true)
        pinned.updatedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let pinnedMsg = ChatMessage(role: .user, content: "置顶问题", sortIndex: 1)
        pinnedMsg.conversation = pinned
        pinned.messages = [pinnedMsg]

        let newer = Conversation(title: "最新对话")
        newer.updatedAt = Date(timeIntervalSince1970: 1_700_002_000)
        let newerMsg = ChatMessage(role: .user, content: "最新问题", sortIndex: 1)
        newerMsg.conversation = newer
        newer.messages = [newerMsg]

        let fourth = Conversation(title: "第四条对话")
        fourth.updatedAt = Date(timeIntervalSince1970: 1_700_001_000)
        let fourthMsg = ChatMessage(role: .user, content: "第四条问题", sortIndex: 1)
        fourthMsg.conversation = fourth
        fourth.messages = [fourthMsg]

        for conv in [emptyConv, older, pinned, newer, fourth] {
            context.insert(conv)
        }
        try context.save()

        let hiddenSnapshot = WidgetSnapshotService.makeSnapshot(
            conversations: [emptyConv, older, pinned, newer, fourth],
            providers: [provider],
            bookmarkedCount: 5,
            showsRecentTitles: false,
            now: Date(timeIntervalSince1970: 1_700_003_000)
        )
        XCTAssertEqual(hiddenSnapshot.readyModelCount, 2)
        XCTAssertEqual(hiddenSnapshot.bookmarkedCount, 5)
        XCTAssertFalse(hiddenSnapshot.showRecentTitles)
        XCTAssertEqual(hiddenSnapshot.recentConversations, [])

        let visibleSnapshot = WidgetSnapshotService.makeSnapshot(
            conversations: [emptyConv, older, pinned, newer, fourth],
            providers: [provider],
            bookmarkedCount: 5,
            showsRecentTitles: true,
            now: Date(timeIntervalSince1970: 1_700_003_000)
        )
        XCTAssertTrue(visibleSnapshot.showRecentTitles)
        XCTAssertEqual(
            visibleSnapshot.recentConversations.map(\.id),
            [pinned.id, newer.id, fourth.id]
        )

        try store.save(visibleSnapshot)
        let loaded = store.load()
        XCTAssertEqual(loaded, visibleSnapshot)
        XCTAssertTrue(loaded.samePayload(as: visibleSnapshot))
    }

    func testQuickLaunchIntentsEnqueueExpectedActions() {
        let inbox = QuickEntryInbox(notificationCenter: NotificationCenter())

        QuickNewChatIntent().recordLaunch(in: inbox)
        XCTAssertEqual(inbox.consume(), .newChat)
        XCTAssertTrue(QuickNewChatIntent.openAppWhenRun)

        QuickVoiceNoteIntent().recordLaunch(in: inbox)
        XCTAssertEqual(inbox.consume(), .voiceNote)
        XCTAssertTrue(QuickVoiceNoteIntent.openAppWhenRun)

        QuickScanDocumentIntent().recordLaunch(in: inbox)
        XCTAssertEqual(inbox.consume(), .scanDocument)
        XCTAssertTrue(QuickScanDocumentIntent.openAppWhenRun)

        QuickBookmarksIntent().recordLaunch(in: inbox)
        XCTAssertEqual(inbox.consume(), .bookmarks)
        XCTAssertTrue(QuickBookmarksIntent.openAppWhenRun)
    }
}
