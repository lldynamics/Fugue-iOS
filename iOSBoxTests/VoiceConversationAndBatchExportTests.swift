import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class VoiceConversationAndBatchExportTests: XCTestCase {

    func testVoiceConversationPolicyAndSpeechCleaning() {
        XCTAssertFalse(VoiceConversationPolicy.shouldAutoCommit(transcript: "   ", silenceElapsed: 5.0, timeoutSeconds: 2.0))
        XCTAssertFalse(VoiceConversationPolicy.shouldAutoCommit(transcript: "你好", silenceElapsed: 2.0, timeoutSeconds: 0))
        XCTAssertFalse(VoiceConversationPolicy.shouldAutoCommit(transcript: "你好", silenceElapsed: 1.5, timeoutSeconds: 2.4))
        XCTAssertTrue(VoiceConversationPolicy.shouldAutoCommit(transcript: "今天日程是什么", silenceElapsed: 2.4, timeoutSeconds: 2.4))

        let cleaned = VoiceConversationPolicy.cleanedSpeechSummary(
            from: "## 结论\n参考[文档](https://example.com)与 `Swift`：\n```swift\nprint(1)\n```",
            maxCharacters: 120
        )
        XCTAssertFalse(cleaned.contains("##"))
        XCTAssertFalse(cleaned.contains("https://example.com"))
        XCTAssertTrue(cleaned.contains("文档"))
        XCTAssertTrue(cleaned.contains("代码片段"))

        XCTAssertEqual(VoiceConversationPolicy.nextPhaseAfterSpeechFinished(autoResumeListening: true), .listening)
        XCTAssertEqual(VoiceConversationPolicy.nextPhaseAfterSpeechFinished(autoResumeListening: false), .idle)
    }

    func testVoiceConversationControllerTurnLoopBargeInAndErrors() {
        let controller = VoiceConversationController()
        controller.startSession()
        XCTAssertTrue(controller.isSessionActive)
        XCTAssertEqual(controller.phase, .idle)

        // Transcript update while idle is ignored.
        controller.handleTranscriptUpdate("不应写入", scheduleTimer: false)
        XCTAssertEqual(controller.liveTranscript, "")

        // Simulate listening phase & transcript commit.
        controller.startListening()
        XCTAssertEqual(controller.phase, .listening)
        controller.handleTranscriptUpdate("帮我总结今天的会议记录", scheduleTimer: false)
        XCTAssertEqual(controller.liveTranscript, "帮我总结今天的会议记录")

        var sentPrompt: String?
        let committed = controller.commitCurrentTranscript { prompt in
            sentPrompt = prompt
            return true
        }
        XCTAssertTrue(committed)
        XCTAssertEqual(sentPrompt, "帮我总结今天的会议记录")
        XCTAssertEqual(controller.lastUserUtterance, "帮我总结今天的会议记录")
        XCTAssertEqual(controller.liveTranscript, "")
        XCTAssertEqual(controller.phase, .thinking)

        // Generation completes cleanly -> speaks and auto-resumes listening on finish.
        var spokenText: String?
        var capturedCompletion: (@MainActor () -> Void)?
        controller.handleGenerationFinished(
            replyText: "**核心要点**：下午 3 点产品评审。",
            errorMessage: nil,
            messageID: UUID(),
            resumeDelayMs: 0
        ) { _, text, onFinished in
            spokenText = text
            capturedCompletion = onFinished
        }
        XCTAssertEqual(controller.phase, .speaking)
        XCTAssertEqual(controller.turnCount, 1)
        XCTAssertEqual(spokenText, "核心要点：下午 3 点产品评审。")

        capturedCompletion?()
        XCTAssertEqual(controller.phase, .listening)

        // Disable auto-resume -> ends speaking into idle.
        controller.autoResumeListening = false
        controller.handleTranscriptUpdate("第二个问题", scheduleTimer: false)
        _ = controller.commitCurrentTranscript { _ in true }
        controller.handleGenerationFinished(
            replyText: "第二轮回复",
            errorMessage: nil,
            messageID: UUID(),
            resumeDelayMs: 0
        ) { _, _, onFinished in
            capturedCompletion = onFinished
        }
        XCTAssertEqual(controller.turnCount, 2)
        capturedCompletion?()
        XCTAssertEqual(controller.phase, .idle)

        // Barge-in during speaking jumps cleanly to listening.
        controller.autoResumeListening = true
        controller.startListening()
        controller.handleTranscriptUpdate("第三轮", scheduleTimer: false)
        _ = controller.commitCurrentTranscript { _ in true }
        controller.handleGenerationFinished(
            replyText: "很长的播报内容",
            errorMessage: nil,
            messageID: UUID(),
            resumeDelayMs: 0
        ) { _, _, _ in }
        XCTAssertEqual(controller.phase, .speaking)
        controller.interruptAndListen()
        XCTAssertEqual(controller.phase, .listening)

        // Error in generation surfaces error and stops loop.
        controller.handleTranscriptUpdate("失败测试", scheduleTimer: false)
        _ = controller.commitCurrentTranscript { _ in true }
        controller.handleGenerationFinished(
            replyText: "",
            errorMessage: "网络超时",
            messageID: UUID(),
            resumeDelayMs: 0
        ) { _, _, _ in
            XCTFail("Should not speak on error")
        }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.statusError, "网络超时")

        controller.stopSession()
        XCTAssertFalse(controller.isSessionActive)
    }

    func testBatchArchiveExporterBookmarksMarkdownAndPDF() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let entries = [
            BookmarkedMessageEntry(
                id: UUID(),
                conversationID: UUID(),
                conversationTitle: "架构评审",
                folderTag: "工作",
                speaker: "Claude Sonnet",
                content: "- 将加密流水线移出主线程\n- 增加 `HEAD` 远端探测",
                createdAt: now
            ),
            BookmarkedMessageEntry(
                id: UUID(),
                conversationID: UUID(),
                conversationTitle: "英语学习",
                folderTag: nil,
                speaker: "GPT-4.1",
                content: "推荐使用间隔重复记忆卡片复习高频短语。",
                createdAt: now.addingTimeInterval(-3600)
            )
        ]

        let markdown = BatchArchiveExporter.makeBookmarksMarkdown(
            entries: entries,
            filterDescription: "全部",
            groupByTag: true,
            exportedAt: now
        )
        XCTAssertTrue(markdown.contains("# 夜奔 · 收藏知识库归档"))
        XCTAssertTrue(markdown.contains("## 分组：工作"))
        XCTAssertTrue(markdown.contains("## 未分组"))
        XCTAssertTrue(markdown.contains("### 架构评审"))
        XCTAssertTrue(markdown.contains("### 英语学习"))

        let mdURL = try BatchArchiveExporter.writeBookmarksMarkdownFile(entries: entries, exportedAt: now)
        let pdfURL = try BatchArchiveExporter.writeBookmarksPDFFile(entries: entries, exportedAt: now)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: mdURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent())
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        let pdfData = try Data(contentsOf: pdfURL)
        XCTAssertTrue(pdfData.starts(with: Data("%PDF".utf8)))
    }

    func testBatchArchiveExporterMultiConversationsMarkdownAndPDF() throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let c1 = Conversation(title: "工作周报整理")
        c1.setFolderTag("办公")
        c1.setPinned(true)
        c1.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let u1 = ChatMessage(role: .user, content: "列出本周三个交付里程碑", sortIndex: 1)
        let a1 = ChatMessage(role: .assistant, content: "# 本周完成\n1. iOS 小组件\n2. 隐私锁\n```python\n# code comment must stay intact\nprint('ok')\n```", sortIndex: 2)
        u1.conversation = c1
        a1.conversation = c1
        c1.messages = [u1, a1]

        let c2 = Conversation(title: "读书随想")
        c2.updatedAt = Date(timeIntervalSince1970: 1_700_050_000)
        let u2 = ChatMessage(role: .user, content: "总结第一章核心隐喻", sortIndex: 1)
        let a2 = ChatMessage(role: .assistant, content: "灯塔象征孤独中的守望与航向确认。", sortIndex: 2)
        u2.conversation = c2
        a2.conversation = c2
        c2.messages = [u2, a2]

        context.insert(c1)
        context.insert(c2)
        try context.save()

        let md = BatchArchiveExporter.makeConversationsMarkdown(
            conversations: [c2, c1],
            exportedAt: Date(timeIntervalSince1970: 1_700_060_000)
        )
        XCTAssertTrue(md.contains("## 目录"))
        // Pinned conversation comes first even though older.
        XCTAssertTrue(md.contains("1. 工作周报整理"))
        XCTAssertTrue(md.contains("2. 读书随想"))
        XCTAssertTrue(md.contains("## 1. 工作周报整理"))
        // Hash comment inside fenced code block must NOT be shifted to "## ".
        XCTAssertTrue(md.contains("\n# code comment must stay intact\n"))

        let mdURL = try BatchArchiveExporter.writeConversationsMarkdownFile(conversations: [c1, c2])
        let pdfURL = try BatchArchiveExporter.writeConversationsPDFFile(conversations: [c1, c2])
        addTeardownBlock {
            try? FileManager.default.removeItem(at: mdURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent())
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        let pdfData = try Data(contentsOf: pdfURL)
        XCTAssertTrue(pdfData.starts(with: Data("%PDF".utf8)))
    }
}
