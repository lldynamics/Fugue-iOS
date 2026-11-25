import AppIntents
import Foundation

struct QuickNewChatIntent: AppIntent {
    static let launchAction: QuickEntryAction = .newChat
    static var title: LocalizedStringResource = "新建对话"
    static var description = IntentDescription("立即打开「夜奔」并开始一段新对话。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }

    func recordLaunch(in inbox: QuickEntryInbox = .shared) {
        inbox.enqueue(Self.launchAction)
    }

    func perform() async throws -> some IntentResult {
        recordLaunch()
        return .result()
    }
}

struct QuickVoiceNoteIntent: AppIntent {
    static let launchAction: QuickEntryAction = .voiceNote
    static var title: LocalizedStringResource = "开始录音纪要"
    static var description = IntentDescription("立即打开「夜奔」录音与语音转纪要面板。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }

    func recordLaunch(in inbox: QuickEntryInbox = .shared) {
        inbox.enqueue(Self.launchAction)
    }

    func perform() async throws -> some IntentResult {
        recordLaunch()
        return .result()
    }
}

struct QuickScanDocumentIntent: AppIntent {
    static let launchAction: QuickEntryAction = .scanDocument
    static var title: LocalizedStringResource = "扫描文档转文字"
    static var description = IntentDescription("立即打开「夜奔」文档扫描相机，使用本地 OCR 提取文字。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }

    func recordLaunch(in inbox: QuickEntryInbox = .shared) {
        inbox.enqueue(Self.launchAction)
    }

    func perform() async throws -> some IntentResult {
        recordLaunch()
        return .result()
    }
}

struct QuickBookmarksIntent: AppIntent {
    static let launchAction: QuickEntryAction = .bookmarks
    static var title: LocalizedStringResource = "打开收藏知识库"
    static var description = IntentDescription("立即打开「夜奔」收藏夹查看已收藏的问答片段。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }

    func recordLaunch(in inbox: QuickEntryInbox = .shared) {
        inbox.enqueue(Self.launchAction)
    }

    func perform() async throws -> some IntentResult {
        recordLaunch()
        return .result()
    }
}
