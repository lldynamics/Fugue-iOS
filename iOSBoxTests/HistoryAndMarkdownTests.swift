import XCTest
@testable import iOSBox

@MainActor
final class PromptHistoryTests: XCTestCase {

    private func image(_ name: String) -> MessageAttachment {
        MessageAttachment(kind: .image, fileName: name, mimeType: "image/jpeg", dataBase64: "QUJD", extractedText: nil, byteSize: 3)
    }

    private func pdf(_ name: String) -> MessageAttachment {
        MessageAttachment(kind: .document, fileName: name, mimeType: "application/pdf", dataBase64: "JVBERi0=", extractedText: "PDF 正文", byteSize: 5)
    }

    func testEmptyAssistantRepliesAreNotSentAsContext() {
        let messages = [
            ChatMessage(role: .user, content: "第一问", sortIndex: 0),
            ChatMessage(role: .assistant, content: "", sortIndex: 1),          // stopped before any text
            ChatMessage(role: .user, content: "第二问", sortIndex: 2)
        ]
        let history = ChatEngine.shared.buildPromptHistory(messages: messages, limit: 0)
        XCTAssertEqual(history.map(\.content), ["第一问", "第二问"])
    }

    func testOnlyMostRecentMediaTurnsResendBinaryData() {
        let messages = [
            ChatMessage(role: .user, content: "旧图", attachments: [image("old.jpg"), pdf("old.pdf")], sortIndex: 0),
            ChatMessage(role: .assistant, content: "看到了", sortIndex: 1),
            ChatMessage(role: .user, content: "中间图", attachments: [image("mid.jpg")], sortIndex: 2),
            ChatMessage(role: .assistant, content: "好的", sortIndex: 3),
            ChatMessage(role: .user, content: "新图", attachments: [image("new.jpg")], sortIndex: 4)
        ]
        XCTAssertEqual(ChatEngine.mediaTurnsToKeep, 2)

        let history = ChatEngine.shared.buildPromptHistory(messages: messages, limit: 0)
        let newest = history[4].attachments
        let middle = history[2].attachments
        let oldest = history[0].attachments

        XCTAssertEqual(newest.first?.kind, .image)
        XCTAssertNotNil(newest.first?.dataBase64)
        XCTAssertNotNil(middle.first?.dataBase64)

        // Oldest turn: image becomes a text placeholder, PDF falls back to its extracted text.
        XCTAssertTrue(oldest.allSatisfy { $0.dataBase64 == nil })
        XCTAssertEqual(oldest.first?.kind, .document)
        let text = LLMClient.composeTextWithDocuments(text: "旧图", attachments: oldest, includePDFText: false)
        XCTAssertTrue(text.contains("old.jpg"), "image placeholder keeps the file name")
        XCTAssertFalse(text.contains("QUJD"), "no base64 in the placeholder")
        XCTAssertTrue(text.contains("PDF 正文"))
    }
}

final class ContextLimitOptionsTests: XCTestCase {

    func testStandardValuesUnchanged() {
        XCTAssertEqual(ContextLimitOptions.values(including: 20), [4, 10, 20, 50, 0])
    }

    func testLegacyNonStandardValueIsOfferedSoPickerHasMatchingTag() {
        XCTAssertEqual(ContextLimitOptions.values(including: 24), [4, 10, 20, 24, 50, 0])
        XCTAssertEqual(ContextLimitOptions.label(for: 0), String(localized: "全部历史"))
        XCTAssertEqual(ContextLimitOptions.label(for: 24), String(localized: "最近 \(24) 条"))
    }
}

final class MarkdownExtendedSyntaxTests: XCTestCase {

    func testGFMTableWithAlignmentAndEscapedPipe() throws {
        let source = """
        对比如下：
        | 模型 | 价格 | 备注 |
        | :--- | ---: | :---: |
        | A | $1 | 支持 a\\|b |
        | B | $2 |
        结束
        """
        let blocks = MarkdownBlockParser.parse(source)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.first, .paragraph("对比如下："))
        XCTAssertEqual(blocks.last, .paragraph("结束"))

        guard case .table(let table) = blocks[1] else { return XCTFail("expected table, got \(blocks[1])") }
        XCTAssertEqual(table.header, ["模型", "价格", "备注"])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
        XCTAssertEqual(table.rows, [["A", "$1", "支持 a|b"], ["B", "$2"]])
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertTrue(table.estimatedColumnWidths().allSatisfy { $0 >= 44 && $0 <= 240 })
    }

    func testPipeTextWithoutDelimiterRowIsNotATable() {
        let blocks = MarkdownBlockParser.parse("a | b\n普通文字")
        XCTAssertEqual(blocks, [.paragraph("a | b\n普通文字")])
    }

    func testDisplayMathBlocks() {
        XCTAssertEqual(MarkdownBlockParser.parse("$$E = mc^2$$"), [.mathBlock("E = mc^2")])
        XCTAssertEqual(
            MarkdownBlockParser.parse("前文\n$$\n\\int_0^1 x\\,dx\n$$\n后文"),
            [.paragraph("前文"), .mathBlock("\\int_0^1 x\\,dx"), .paragraph("后文")]
        )
        XCTAssertEqual(MarkdownBlockParser.parse("\\[\na^2+b^2=c^2\n\\]"), [.mathBlock("a^2+b^2=c^2")])
    }

    func testNestedListsAndTaskItems() {
        let blocks = MarkdownBlockParser.parse("- 一级\n  - 二级\n    1. 三级\n- [ ] 待办\n- [x] 完成")
        XCTAssertEqual(blocks, [
            .listItem(marker: "•", content: "一级", level: 0),
            .listItem(marker: "◦", content: "二级", level: 1),
            .listItem(marker: "1.", content: "三级", level: 2),
            .listItem(marker: "☐", content: "待办", level: 0),
            .listItem(marker: "☑", content: "完成", level: 0)
        ])
    }

    func testTildeFencesAndUnclosedFenceWhileStreaming() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("~~~python\nprint(1)\n~~~"),
            [.codeBlock(language: "python", code: "print(1)")]
        )
        XCTAssertEqual(
            MarkdownBlockParser.parse("```swift\nlet a = 1"),
            [.codeBlock(language: "swift", code: "let a = 1")]
        )
    }

    func testYearIsNotParsedAsOrderedList() {
        XCTAssertEqual(MarkdownBlockParser.parse("2024. 是个好年份"), [.paragraph("2024. 是个好年份")])
    }
}
