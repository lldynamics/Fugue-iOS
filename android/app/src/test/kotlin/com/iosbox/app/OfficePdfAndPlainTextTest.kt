package com.iosbox.app

import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.storage.BookImporter
import com.iosbox.app.core.storage.OfficeDocumentReader
import com.iosbox.app.core.storage.PdfTextExtractor
import com.iosbox.app.core.system.PlainTextFormatter
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class OfficePdfAndPlainTextTest {

    private fun buildZip(entries: Map<String, String>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zos ->
            for ((path, content) in entries) {
                zos.putNextEntry(ZipEntry(path))
                zos.write(content.toByteArray(Charsets.UTF_8))
                zos.closeEntry()
            }
        }
        return out.toByteArray()
    }

    @Test
    fun docxParsesHeadingsParagraphsAndTablesForAttachmentAndBook() {
        val docxBytes = buildZip(
            mapOf(
                "_rels/.rels" to """
                    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
                    </Relationships>
                """.trimIndent(),
                "word/document.xml" to """
                    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                      <w:body>
                        <w:p>
                          <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
                          <w:r><w:t>项目周报</w:t></w:r>
                        </w:p>
                        <w:p>
                          <w:r><w:t>本周完成了文档解析模块。</w:t></w:r>
                        </w:p>
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
                """.trimIndent(),
                "word/footnotes.xml" to """
                    <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                      <w:footnote w:id="1"><w:p><w:r><w:t>参考附录一</w:t></w:r></w:p></w:footnote>
                    </w:footnotes>
                """.trimIndent()
            )
        )

        val manuscript = BookImporter.parse(docxBytes, "WeeklyReport.docx")
        assertEquals("WeeklyReport", manuscript.title)
        assertEquals(1, manuscript.chapters.size)
        assertEquals("项目周报", manuscript.chapters[0].title)
        assertTrue(manuscript.chapters[0].text.contains("本周完成了文档解析模块。"))
        assertTrue(manuscript.chapters[0].text.contains("DOCX 支持 | 已完成"))
        assertTrue(manuscript.chapters[0].text.contains("参考附录一"))

        val attachmentText = OfficeDocumentReader.extractText(docxBytes, "docx", "WeeklyReport")
        assertTrue(attachmentText.contains("任务 | 状态"))
    }

    @Test
    fun xlsxParsesSharedStringsInlineStringsAndMultipleSheets() {
        val xlsxBytes = buildZip(
            mapOf(
                "xl/sharedStrings.xml" to """
                    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
                      <si><t>项目名称</t></si>
                      <si><t>预算</t></si>
                      <si><t>差旅报销</t><rPh sb="0" eb="2"><t>忽略拼音</t></rPh></si>
                    </sst>
                """.trimIndent(),
                "xl/workbook.xml" to """
                    <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                      <sheets>
                        <sheet name="Q4 预算" sheetId="1" r:id="rId1"/>
                        <sheet name="审批开关" sheetId="2" r:id="rId2"/>
                      </sheets>
                    </workbook>
                """.trimIndent(),
                "xl/_rels/workbook.xml.rels" to """
                    <Relationships>
                      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
                      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet2.xml"/>
                    </Relationships>
                """.trimIndent(),
                "xl/worksheets/sheet1.xml" to """
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
                """.trimIndent(),
                "xl/worksheets/sheet2.xml" to """
                    <worksheet>
                      <sheetData>
                        <row r="1">
                          <c r="A1" t="inlineStr"><is><t>加急</t></is></c>
                          <c r="B1" t="b"><v>1</v></c>
                        </row>
                      </sheetData>
                    </worksheet>
                """.trimIndent()
            )
        )

        val manuscript = BookImporter.parse(xlsxBytes, "Budget.xlsx")
        assertEquals(listOf("Q4 预算", "审批开关"), manuscript.chapters.map { it.title })
        assertTrue(manuscript.chapters[0].text.contains("项目名称 | 预算"))
        assertTrue(manuscript.chapters[0].text.contains("差旅报销 |  | 1280"))
        assertFalse(manuscript.chapters[0].text.contains("忽略拼音"))
        assertEquals("加急 | TRUE", manuscript.chapters[1].text)
    }

    @Test
    fun pptxParsesSlidesInNumericOrderWithSpeakerNotes() {
        val pptxBytes = buildZip(
            mapOf(
                "ppt/slides/slide10.xml" to """
                    <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                      <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>第十页总结</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                    </p:sld>
                """.trimIndent(),
                "ppt/slides/slide2.xml" to """
                    <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                      <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>第二页路线图</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
                    </p:sld>
                """.trimIndent(),
                "ppt/slides/_rels/slide2.xml.rels" to """
                    <Relationships>
                      <Relationship Id="rIdN1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide2.xml"/>
                    </Relationships>
                """.trimIndent(),
                "ppt/notesSlides/notesSlide2.xml" to """
                    <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
                      <p:cSld><p:spTree><p:sp><p:txBody>
                        <a:p><a:r><a:t>补充演讲提示</a:t></a:r></a:p>
                        <a:p><a:fld type="slidenum"><a:t>2</a:t></a:fld></a:p>
                      </p:txBody></p:sp></p:spTree></p:cSld>
                    </p:notes>
                """.trimIndent()
            )
        )

        val manuscript = BookImporter.parse(pptxBytes, "PitchDeck.pptx")
        assertEquals(2, manuscript.chapters.size)
        assertTrue(manuscript.chapters[0].text.contains("第二页路线图"))
        assertTrue(manuscript.chapters[0].text.contains("补充演讲提示"))
        assertFalse(manuscript.chapters[0].text.lines().any { it.trim() == "2" })
        assertTrue(manuscript.chapters[1].text.contains("第十页总结"))
    }

    @Test
    fun officeReaderRejectsPathTraversalAndXmlEntityExpansion() {
        assertNull(OfficeDocumentReader.resolvePackagePath("../../etc/passwd", "xl/workbook.xml"))
        assertNull(OfficeDocumentReader.resolvePackagePath("https://evil.example/a.xml", "word/document.xml"))
        assertEquals("xl/worksheets/sheet2.xml", OfficeDocumentReader.resolvePackagePath("/xl/worksheets/sheet2.xml", "xl/workbook.xml"))
        assertEquals("ppt/notesSlides/notesSlide1.xml", OfficeDocumentReader.resolvePackagePath("../notesSlides/notesSlide1.xml", "ppt/slides/slide1.xml"))

        val entityBombDocx = buildZip(
            mapOf(
                "word/document.xml" to """
                    <!DOCTYPE foo [ <!ENTITY lol "lol"> ]>
                    <w:document><w:body><w:p><w:r><w:t>&lol;</w:t></w:r></w:p></w:body></w:document>
                """.trimIndent()
            )
        )
        assertThrows(BookImportError.InvalidBook::class.java) {
            OfficeDocumentReader.extractChapters(entityBombDocx, "docx", "Bomb")
        }

        val encryptedDocx = buildZip(mapOf("EncryptedPackage" to "locked-binary"))
        assertThrows(BookImportError.Locked::class.java) {
            OfficeDocumentReader.extractChapters(encryptedDocx, "docx", "Secret")
        }
    }

    @Test
    fun pdfTextExtractorExtractsMultiPageTextForAttachmentAndBook() {
        val out = ByteArrayOutputStream()
        PDDocument().use { doc ->
            val p1 = PDPage()
            doc.addPage(p1)
            PDPageContentStream(doc, p1).use { cs ->
                cs.beginText()
                cs.setFont(PDType1Font.HELVETICA, 12f)
                cs.newLineAtOffset(50f, 700f)
                cs.showText("Quarterly Engineering Summary")
                cs.endText()
            }
            val p2 = PDPage()
            doc.addPage(p2)
            PDPageContentStream(doc, p2).use { cs ->
                cs.beginText()
                cs.setFont(PDType1Font.HELVETICA, 12f)
                cs.newLineAtOffset(50f, 700f)
                cs.showText("Action Item: Ship Stage A")
                cs.endText()
            }
            doc.save(out)
        }
        val pdfBytes = out.toByteArray()

        val extracted = PdfTextExtractor.extractForAttachment(pdfBytes)
        assertFalse(extracted.isLocked)
        assertEquals(2, extracted.pageCount)
        assertTrue(extracted.text.contains("Quarterly Engineering Summary"))
        assertTrue(extracted.text.contains("Action Item: Ship Stage A"))

        val book = BookImporter.parse(pdfBytes, "Summary.pdf")
        assertEquals("Summary", book.title)
        assertEquals(2, book.chapters.size)
        assertTrue(book.chapters[0].text.contains("Quarterly Engineering Summary"))
        assertTrue(book.chapters[1].text.contains("Action Item: Ship Stage A"))
    }

    @Test
    fun plainTextFormatterStripsMarkdownPreservesCodeLinksAndSnakeCase() {
        val md = """
            ## 今日会议纪要
            > 请确认 `api_base_url` 与 user_profile_id 配置，预算为 ${'$'}50 到 ${'$'}100。
            - **优先级高**：联系[产品文档](https://example.com/spec) 与 *审核人*，忽略 ~~旧方案~~
            - 参见公式 ${'$'}E = mc^2${'$'}

            | 事项 | 负责人 |
            | --- | --- |
            | 发布准备 | 小林 |

            ```python
            def sync_draft_state():
                # keep comments & snake_case inside code
                return _internal_flag
            ```
        """.trimIndent()

        val plain = PlainTextFormatter.toPlainText(md)
        assertTrue(plain.contains("今日会议纪要"))
        assertFalse(plain.contains("## "))
        assertFalse(plain.contains("**"))
        assertFalse(plain.contains("~~"))
        assertTrue(plain.contains("user_profile_id"))
        assertTrue(plain.contains("api_base_url"))
        assertTrue(plain.contains("${'$'}50 到 ${'$'}100"))
        assertTrue(plain.contains("• 优先级高：联系产品文档 (https://example.com/spec) 与 审核人，忽略 旧方案"))
        assertTrue(plain.contains("• 参见公式 E = mc^2"))
        assertTrue(plain.contains("事项：负责人"))
        assertTrue(plain.contains("发布准备：小林"))
        assertFalse(plain.contains("| ---"))
        assertFalse(plain.contains("```"))
        assertTrue(plain.contains("# keep comments & snake_case inside code"))
        assertTrue(plain.contains("return _internal_flag"))
    }
}
