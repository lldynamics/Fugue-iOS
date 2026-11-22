import Foundation
import XCTest
import ZIPFoundation
@testable import iOSBox

final class OfficeAndPlainTextTests: XCTestCase {
    private func makeZip(_ entries: [(String, String)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, content) in entries {
            let data = Data(content.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, size in
                let start = Int(offset)
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
        return try XCTUnwrap(archive.data)
    }

    func testDOCXExtractionAndBookImport() throws {
        let docxData = try makeZip([
            ("_rels/.rels", """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
                </Relationships>
                """),
            ("word/document.xml", """
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:body>
                    <w:p>
                      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
                      <w:r><w:t>项目周报</w:t></w:r>
                    </w:p>
                    <w:p><w:r><w:t>本周完成了文档解析模块。</w:t></w:r></w:p>
                    <w:tbl>
                      <w:tr>
                        <w:tc><w:p><w:r><w:t>任务</w:t></w:r></w:p></w:tc>
                        <w:tc><w:p><w:r><w:t>状态</w:t></w:r></w:p></w:tc>
                      </w:tr>
                      <w:tr>
                        <w:tc><w:p><w:r><w:t>DOCX 支持</w:t></w:r></w:p></w:tc>
                        <w:tc><w:p><w:r><w:t>已完成</w:t></w:r></w:p></w:tc>
                      </w:tr>
                    </w:tbl>
                  </w:body>
                </w:document>
                """),
            ("word/footnotes.xml", """
                <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:footnote w:id="1"><w:p><w:r><w:t>参考附录一</w:t></w:r></w:p></w:footnote>
                </w:footnotes>
                """)
        ])

        let book = try BookImporter.parse(docxData, filename: "WeeklyReport.docx")
        XCTAssertEqual(book.title, "WeeklyReport")
        XCTAssertEqual(book.chapters.count, 1)
        XCTAssertEqual(book.chapters[0].title, "项目周报")
        XCTAssertTrue(book.chapters[0].text.contains("本周完成了文档解析模块。"))
        XCTAssertTrue(book.chapters[0].text.contains("DOCX 支持 | 已完成"))
        XCTAssertTrue(book.chapters[0].text.contains("参考附录一"))
    }

    func testXLSXSharedStringsAndMultiSheetExtraction() throws {
        let xlsxData = try makeZip([
            ("xl/sharedStrings.xml", """
                <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                  <si><t>项目名称</t></si>
                  <si><t>预算</t></si>
                  <si><t>差旅报销</t><rPh sb="0" eb="2"><t>忽略拼音</t></rPh></si>
                </sst>
                """),
            ("xl/workbook.xml", """
                <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                  <sheets>
                    <sheet name="Q4 预算" sheetId="1" r:id="rId1"/>
                    <sheet name="审批开关" sheetId="2" r:id="rId2"/>
                  </sheets>
                </workbook>
                """),
            ("xl/_rels/workbook.xml.rels", """
                <Relationships>
                  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet2.xml"/>
                </Relationships>
                """),
            ("xl/worksheets/sheet1.xml", """
                <worksheet>
                  <sheetData>
                    <row r="1">
                      <c r="A1" t="s"><v>0</v></c>
                      <c r="B1" t="s"><v>1</v></c>
                    </row>
                    <row r="2">
                      <c r="A2" t="s"><v>2</v></c>
                      <c r="C2"><v>1280</v></c>
                    </row>
                  </sheetData>
                </worksheet>
                """),
            ("xl/worksheets/sheet2.xml", """
                <worksheet>
                  <sheetData>
                    <row r="1">
                      <c r="A1" t="inlineStr"><is><t>加急</t></is></c>
                      <c r="B1" t="b"><v>1</v></c>
                    </row>
                  </sheetData>
                </worksheet>
                """)
        ])

        let book = try BookImporter.parse(xlsxData, filename: "Budget.xlsx")
        XCTAssertEqual(book.chapters.map(\.title), ["Q4 预算", "审批开关"])
        XCTAssertTrue(book.chapters[0].text.contains("项目名称 | 预算"))
        XCTAssertTrue(book.chapters[0].text.contains("差旅报销 |  | 1280"))
        XCTAssertFalse(book.chapters[0].text.contains("忽略拼音"))
        XCTAssertEqual(book.chapters[1].text, "加急 | TRUE")
    }

    func testPPTXSlideOrderAndSpeakerNotes() throws {
        let pptxData = try makeZip([
            ("ppt/slides/slide10.xml", """
                <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                  <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>第十页总结</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                </p:sld>
                """),
            ("ppt/slides/slide2.xml", """
                <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                  <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>第二页路线图</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                </p:sld>
                """),
            ("ppt/slides/_rels/slide2.xml.rels", """
                <Relationships>
                  <Relationship Id="rIdN1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide2.xml"/>
                </Relationships>
                """),
            ("ppt/notesSlides/notesSlide2.xml", """
                <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                  <p:cSld><p:spTree><p:sp><p:txBody>
                    <a:p><a:r><a:t>补充演讲提示</a:t></a:r></a:p>
                    <a:p><a:fld type="slidenum"><a:t>2</a:t></a:fld></a:p>
                  </p:txBody></p:sp></p:spTree></p:cSld>
                </p:notes>
                """)
        ])

        let book = try BookImporter.parse(pptxData, filename: "PitchDeck.pptx")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertTrue(book.chapters[0].text.contains("第二页路线图"))
        XCTAssertTrue(book.chapters[0].text.contains("补充演讲提示"))
        XCTAssertFalse(book.chapters[0].text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "2" })
        XCTAssertTrue(book.chapters[1].text.contains("第十页总结"))
    }

    func testOfficeReaderRejectsEntityExpansionAndTraversal() throws {
        XCTAssertNil(OfficeDocumentReader.resolvePackagePath("../../etc/passwd", relativeTo: "xl/workbook.xml"))
        XCTAssertNil(OfficeDocumentReader.resolvePackagePath("https://evil.example/a.xml", relativeTo: "word/document.xml"))
        XCTAssertEqual(
            OfficeDocumentReader.resolvePackagePath("/xl/worksheets/sheet2.xml", relativeTo: "xl/workbook.xml"),
            "xl/worksheets/sheet2.xml"
        )

        let bombDocx = try makeZip([
            ("word/document.xml", """
                <!DOCTYPE foo [ <!ENTITY lol "lol"> ]>
                <w:document><w:body><w:p><w:r><w:t>&lol;</w:t></w:r></w:p></w:body></w:document>
                """)
        ])
        XCTAssertThrowsError(try OfficeDocumentReader.extractChapters(from: bombDocx, ext: "docx", fallbackTitle: "Bomb")) {
            guard case BookImportError.invalidBook = $0 else { return XCTFail("Expected invalidBook") }
        }

        let lockedDocx = try makeZip([("EncryptedPackage", "secret")])
        XCTAssertThrowsError(try OfficeDocumentReader.extractChapters(from: lockedDocx, ext: "docx", fallbackTitle: "Secret")) {
            guard case BookImportError.locked = $0 else { return XCTFail("Expected locked") }
        }
    }

    func testPlainTextFormatterCleansMarkdownForMessaging() {
        let md = """
        ## 今日会议纪要
        > 请确认 `api_base_url` 与 user_profile_id 配置，预算为 $50 到 $100。
        - **优先级高**：联系[产品文档](https://example.com/spec) 与 *审核人*，忽略 ~~旧方案~~
        - 参见公式 $E = mc^2$

        | 事项 | 负责人 |
        | --- | --- |
        | 发布准备 | 小林 |

        ```python
        def sync_draft_state():
            # keep comments & snake_case inside code
            return _internal_flag
        ```
        """

        let plain = PlainTextFormatter.format(md)
        XCTAssertTrue(plain.contains("今日会议纪要"))
        XCTAssertFalse(plain.contains("## "))
        XCTAssertFalse(plain.contains("**"))
        XCTAssertFalse(plain.contains("~~"))
        XCTAssertTrue(plain.contains("user_profile_id"))
        XCTAssertTrue(plain.contains("api_base_url"))
        XCTAssertTrue(plain.contains("$50 到 $100"))
        XCTAssertTrue(plain.contains("• 优先级高：联系产品文档 (https://example.com/spec) 与 审核人，忽略 旧方案"))
        XCTAssertTrue(plain.contains("• 参见公式 E = mc^2"))
        XCTAssertTrue(plain.contains("事项：负责人"))
        XCTAssertTrue(plain.contains("发布准备：小林"))
        XCTAssertFalse(plain.contains("| ---"))
        XCTAssertFalse(plain.contains("```"))
        XCTAssertTrue(plain.contains("# keep comments & snake_case inside code"))
        XCTAssertTrue(plain.contains("return _internal_flag"))
    }
}
