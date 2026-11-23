import XCTest
@testable import iOSBox

final class Phase1PolishAndExportTests: XCTestCase {

    func testMessageExportRendererGeneratesMultiPagePDFAndFile() throws {
        let longMarkdown = """
        # 周报摘要

        > 请注意周四前完成合同评审并发送会议纪要。

        - 已完成 DOCX / XLSX / PPTX 解析联调
        - 完成 Whisper 录音与系统日历待办写入

        ```swift
        struct Example {
            let status = "ok"
        }
        ```

        """ + Array(repeating: "这是一段用于测试多页自动分页效果的较长正文段落，确保 PDF 导出引擎可以跨页排版而不截断内容。", count: 45).joined(separator: "\n\n")

        let data = MessageExportRenderer.makePDFData(
            title: "项目进度周报",
            speaker: "Claude Sonnet",
            markdown: longMarkdown
        )
        XCTAssertTrue(data.count > 1000)
        XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-")

        let fileURL = try MessageExportRenderer.writePDFFile(
            title: "项目进度周报",
            speaker: "Claude Sonnet",
            markdown: longMarkdown
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(fileURL.pathExtension.lowercased(), "pdf")
    }

    func testConversationTimeBucketGroupsItemsPreservingOrder() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12, minute: 0))!
        let todayMorning = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 8, minute: 30))!
        let twoDaysAgo = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 18, minute: 0))!
        let fiveDaysAgo = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9, minute: 0))!
        let tenDaysAgo = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 0))!

        let items: [(id: String, date: Date)] = [
            ("t1", todayMorning),
            ("r1", twoDaysAgo),
            ("r2", fiveDaysAgo),
            ("e1", tenDaysAgo)
        ]

        let grouped = ConversationTimeBucket.group(items, date: \.date, now: now, calendar: cal)
        XCTAssertEqual(grouped.map(\.bucket), [.today, .last7Days, .earlier])
        XCTAssertEqual(grouped[0].items.map(\.id), ["t1"])
        XCTAssertEqual(grouped[1].items.map(\.id), ["r1", "r2"])
        XCTAssertEqual(grouped[2].items.map(\.id), ["e1"])
    }
}
