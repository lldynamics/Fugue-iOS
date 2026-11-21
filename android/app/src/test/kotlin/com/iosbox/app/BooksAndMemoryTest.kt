package com.iosbox.app

import com.iosbox.app.core.backup.BackupJson
import com.iosbox.app.core.model.BookChapter
import com.iosbox.app.core.model.BookFriend
import com.iosbox.app.core.model.BookImportError
import com.iosbox.app.core.model.BookManuscript
import com.iosbox.app.core.model.BookReplyEvidence
import com.iosbox.app.core.model.BookExcerpt
import com.iosbox.app.core.model.ConversationAssistanceSettings
import com.iosbox.app.core.model.KnowledgeEvidence
import com.iosbox.app.core.model.KnowledgePassage
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.PersonalMemoryPrompt
import com.iosbox.app.core.model.PreparedBook
import com.iosbox.app.core.model.ReadingCitation
import com.iosbox.app.core.network.AgentToolRunner
import com.iosbox.app.core.network.LLMToolCall
import com.iosbox.app.core.storage.BookImporter
import com.iosbox.app.core.storage.BookReadingPage
import com.iosbox.app.core.storage.BookReferenceSearch
import com.iosbox.app.core.storage.EPUBBookReader
import com.iosbox.app.core.storage.KnowledgeDocumentInput
import com.iosbox.app.core.storage.ProjectKnowledgeSearch
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.charset.Charset
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class BooksAndMemoryTest {
    @Test
    fun txtAndMarkdownBookImporterSplitsChaptersDecodesGb18030AndHashesDeterministically() {
        val sample = """
            前言内容略过。

            # 第一回 甄士隐梦幻识通灵
            列位看官，你道此书从何而来？
            甄士隐于书房闲坐。

            第二回 贾夫人仙逝扬州城
            且说黛玉自那日弃舟登岸时，便有荣国府打发了轿子并拉行李的车辆久候了。
        """.trimIndent()

        val gbBytes = sample.toByteArray(Charset.forName("GB18030"))
        val manuscript = BookImporter.parse(gbBytes, "红楼梦.txt")
        assertEquals("红楼梦", manuscript.title)
        assertEquals(3, manuscript.chapters.size)
        assertEquals("第一回 甄士隐梦幻识通灵", manuscript.chapters[1].title)
        assertEquals("第二回 贾夫人仙逝扬州城", manuscript.chapters[2].title)

        val prep1 = PreparedBook.from(manuscript)
        val prep2 = PreparedBook.from(BookImporter.parse(gbBytes, "红楼梦.txt"))
        assertEquals(36, prep1.id.length)
        assertEquals(prep1.id, prep2.id)

        assertThrows(BookImportError.FileType::class.java) {
            BookImporter.parse("dummy".toByteArray(), "manual.pdf")
        }
        assertThrows(BookImportError.NoText::class.java) {
            BookImporter.parse(byteArrayOf(0x41, 0x00, 0x42), "broken.txt")
        }
    }

    @Test
    fun epubBookReaderParsesValidSpineStripsScriptsRejectsEncryptedAndTraversal() {
        assertNull(EPUBBookReader.localPath("../../etc/passwd", "OEBPS/content.opf"))
        assertNull(EPUBBookReader.localPath("/abs/ch1.xhtml", "OEBPS/content.opf"))
        assertNull(EPUBBookReader.localPath("https://evil.com/x.xhtml", "OEBPS/content.opf"))
        assertEquals("OEBPS/text/ch1.xhtml", EPUBBookReader.localPath("text/ch1.xhtml", "OEBPS/content.opf"))

        val validEpub = buildZipBytes(
            mapOf(
                "META-INF/container.xml" to """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                """.trimIndent(),
                "OEBPS/content.opf" to """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
                      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                        <dc:title>夜奔测试集</dc:title>
                      </metadata>
                      <manifest>
                        <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                        <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
                      </manifest>
                      <spine>
                        <itemref idref="c1"/>
                        <itemref idref="c2"/>
                      </spine>
                    </package>
                """.trimIndent(),
                "OEBPS/ch1.xhtml" to """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml">
                      <head><title>HeadOne</title><script>stealSecret()</script></head>
                      <body>
                        <style>.hidden{display:none}</style>
                        <h1>序幕</h1>
                        <p>第一段内容&mdash;测试。</p>
                      </body>
                    </html>
                """.trimIndent(),
                "OEBPS/ch2.xhtml" to """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml">
                      <head><title>终章</title></head>
                      <body><p>第二章正文内容。</p></body>
                    </html>
                """.trimIndent()
            )
        )

        val parsed = EPUBBookReader.read(validEpub, "fallback")
        assertEquals("夜奔测试集", parsed.title)
        assertEquals(2, parsed.chapters.size)
        assertEquals("序幕", parsed.chapters[0].title)
        assertEquals("终章", parsed.chapters[1].title)
        assertTrue(parsed.chapters[0].text.contains("第一段内容—测试。"))
        assertFalse(parsed.chapters[0].text.contains("stealSecret"))
        assertFalse(parsed.chapters[0].text.contains("display:none"))

        val lockedEpub = buildZipBytes(
            mapOf(
                "META-INF/container.xml" to """
                    <container version="1.0"><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>
                """.trimIndent(),
                "META-INF/encryption.xml" to """
                    <encryption><EncryptedData><CipherData><CipherReference URI="ch1.xhtml"/></CipherData></EncryptedData></encryption>
                """.trimIndent(),
                "content.opf" to """
                    <package><manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>
                """.trimIndent(),
                "ch1.xhtml" to "<html><body><p>secret</p></body></html>"
            )
        )
        assertThrows(BookImportError.Locked::class.java) {
            EPUBBookReader.read(lockedEpub, "locked")
        }

        val xxeEpub = buildZipBytes(
            mapOf(
                "META-INF/container.xml" to """
                    <?xml version="1.0"?>
                    <!DOCTYPE foo [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
                    <container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>
                """.trimIndent()
            )
        )
        assertThrows(BookImportError.InvalidBook::class.java) {
            EPUBBookReader.read(xxeEpub, "xxe")
        }
    }

    @Test
    fun projectKnowledgeSearchRanksIdfIdentifiersRespectsChapterLimitsAndBuildsReadingPageHighlight() {
        ProjectKnowledgeSearch.clearForTesting()
        val chaptersV1 = listOf(
            BookChapter("第一章 概述", "这是基础 Compose UI 布局介绍与入门概念说明。"),
            BookChapter("第二章 限流排查", "遇到错误码 ERR-4290-QX 时，请执行指数退避限流策略 rate limit backoff strategy 并检查令牌桶。"),
            BookChapter("第三章 大结局剧透", "这里写了 secret ending spoiler 最终谜底揭晓。")
        )
        val docs = listOf(
            KnowledgeDocumentInput("V1", "架构手册") { chaptersV1 },
            KnowledgeDocumentInput("V2", "甜品菜谱") { listOf(BookChapter("烘焙", "面粉鸡蛋牛奶蛋糕。")) }
        )

        val evidence = ProjectKnowledgeSearch.retrieve(
            documents = docs,
            query = "Explain ERR-4290-QX backoff",
            maxPassages = 3,
            chapterLimits = mapOf("V1" to 1)
        )
        assertEquals(1, evidence.passages.size)
        val passage = evidence.passages[0]
        assertEquals("V1", passage.volumeID)
        assertEquals(1, passage.chapterIndex)

        val limited = ProjectKnowledgeSearch.retrieve(
            documents = docs,
            query = "secret ending spoiler",
            maxPassages = 3,
            chapterLimits = mapOf("V1" to 1)
        )
        assertTrue(limited.passages.isEmpty())

        val citation = ReadingCitation.fromPassage(passage)
        assertTrue(citation.marker.contains("[架构手册 · 第二章 限流排查 #2."))

        val page = BookReadingPage.make(chaptersV1, preferredChapter = 0, citation = citation)
        assertTrue(page.located)
        assertEquals(1, page.chapterIndex)
        val highlightedParagraph = page.paragraphs.firstOrNull { it.highlightRange != null }
        assertNotNull(highlightedParagraph)
        val range = highlightedParagraph?.highlightRange
        assertNotNull(range)
        val highlightedSub = if (highlightedParagraph != null && range != null) {
            highlightedParagraph.text.substring(range.first, range.last + 1)
        } else {
            ""
        }
        assertTrue(highlightedSub.contains("ERR-4290-QX"))

        // Ambiguous legacy citation (no index/offset, appears twice) must not jump arbitrarily
        val dupChapters = listOf(BookChapter("重复章", "重复句子。中间隔开。重复句子。"))
        val ambiguous = ReadingCitation("V3", "测试", "重复章", chapterIndex = null, utf16Offset = null, excerpt = "重复句子", number = 1)
        val dupPage = BookReadingPage.make(dupChapters, preferredChapter = 0, citation = ambiguous)
        assertFalse(dupPage.located)
    }

    @Test
    fun bookReferenceSearchEnforcesSpoilerBoundaryAndFindsCharacterScenes() {
        val chapters = listOf(
            BookChapter("第一回", "宝玉道：“这个妹妹我曾见过的。”\n林黛玉笑道：“好生奇怪，倒像在哪里见过一般。”"),
            BookChapter("第二回", "潇湘妃子在馆中抚琴吟诗，众人皆赞秋窗风雨夕绝妙。"),
            BookChapter("第八十回", "剧透章节：LinDaiyuOutcome 后事揭晓。")
        )
        val cappedFriend = BookFriend.make(
            bookID = "BOOK1",
            bookTitle = "红楼梦",
            chapterTitles = chapters.map { it.title },
            name = "林黛玉",
            aliasesRaw = "潇湘妃子，颦儿",
            throughChapter = 1
        )
        val evidence = BookReferenceSearch.reference(cappedFriend, chapters, "秋窗吟诗见过")
        assertEquals(2, evidence.excerpts.size)
        assertTrue(evidence.excerpts.none { it.text.contains("LinDaiyuOutcome") })
        assertTrue(evidence.referenceText().contains("citation"))

        val laterChar = BookFriend.make(
            bookID = "BOOK1",
            bookTitle = "红楼梦",
            chapterTitles = chapters.map { it.title },
            name = "LinDaiyuOutcome",
            aliasesRaw = "",
            throughChapter = 1
        )
        assertThrows(BookImportError.NoMatches::class.java) {
            BookReferenceSearch.reference(laterChar, chapters, "hello")
        }
    }

    @Test
    fun personalMemoryPromptCapsAtTwentyAndAssistanceMetadataRoundTripsKnowledgeAndBookFields() {
        val overlong = "K".repeat(620)
        val inputs = listOf("   ", overlong) + (1..24).map { "Preference #$it" }
        val (prompt, count) = PersonalMemoryPrompt.buildPrompt(inputs)
        assertEquals(PersonalMemoryPrompt.MAXIMUM_COUNT, count)
        assertTrue(prompt.contains("K".repeat(500)))
        assertFalse(prompt.contains("K".repeat(501)))
        assertFalse(prompt.contains("Preference #20"))

        val codec = BackupJson.codec
        val convExisting = codec.parseToJsonElement("""{"studyCoachMode":"quiz"}""").jsonObject
        val friend = BookFriend("B1", "红楼梦", "林黛玉", listOf("颦儿"), throughChapter = 3)
        val convMerged = ConversationAssistanceSettings(
            usePersonalMemory = true,
            knowledgeVolumeIDs = listOf("B1"),
            bookFriend = friend,
            companionBookID = "B1"
        ).mergeInto(convExisting, codec)
        assertEquals("quiz", convMerged["studyCoachMode"]?.jsonPrimitive?.content)
        assertEquals("B1", convMerged["companionBookID"]?.jsonPrimitive?.content)
        assertEquals("林黛玉", convMerged["bookFriend"]?.jsonObject?.get("name")?.jsonPrimitive?.content)

        val clearedConv = ConversationAssistanceSettings().mergeInto(convMerged, codec)
        assertNull(clearedConv["bookFriend"])
        assertNull(clearedConv["companionBookID"])
        assertEquals("quiz", clearedConv["studyCoachMode"]?.jsonPrimitive?.content)

        val msgExisting = codec.parseToJsonElement("""{"studyQuizScore":95}""").jsonObject
        val kev = KnowledgeEvidence("q", listOf(KnowledgePassage(1, "B1", "红楼梦", "第一回", "片段原文", 0, 12)))
        val bev = BookReplyEvidence("林黛玉", "红楼梦", listOf(BookExcerpt(0, "第一回", "黛玉笑问。", 0, 5)))
        val msgMerged = MessageAssistanceMetadata(
            memoryCount = 4,
            knowledgeEvidence = kev,
            bookReply = bev
        ).mergeInto(msgExisting, codec)
        assertEquals("95", msgMerged["studyQuizScore"]?.jsonPrimitive?.content)
        assertEquals("4", msgMerged["memoryCount"]?.jsonPrimitive?.content)
        assertNotNull(msgMerged["knowledgeEvidence"])
        assertNotNull(msgMerged["bookReply"])

        val clearedMsg = MessageAssistanceMetadata().mergeInto(msgMerged, codec)
        assertNull(clearedMsg["knowledgeEvidence"])
        assertNull(clearedMsg["bookReply"])
        assertEquals("95", clearedMsg["studyQuizScore"]?.jsonPrimitive?.content)
    }

    @Test
    fun agentToolRunnerExecutesSearchDocumentsWithKnowledgeEvidence() = runTest {
        val output = AgentToolRunner.execute(
            call = LLMToolCall(id = "t_doc", name = "search_documents", argumentsJSON = """{"query":"Compose state"}"""),
            searchHandler = { error("unused") },
            knowledgeHandler = { q ->
                KnowledgeEvidence(
                    query = q,
                    passages = listOf(
                        KnowledgePassage(
                            id = 1,
                            volumeID = "VOL-1",
                            documentTitle = "Compose Handbook",
                            sectionTitle = "State Hoisting",
                            excerpt = "State hoisting moves state to a caller to make a composable stateless.",
                            chapterIndex = 2,
                            utf16Offset = 40
                        )
                    )
                )
            }
        )
        assertTrue(output.record.succeeded)
        assertEquals(1, output.knowledgeEvidence?.passages?.size)
        assertTrue(output.toolOutputJSON.contains("Reference passages"))
        assertTrue(output.toolOutputJSON.contains("Compose Handbook"))
    }

    private fun buildZipBytes(entries: Map<String, String>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zos ->
            for ((name, content) in entries) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(content.toByteArray(Charsets.UTF_8))
                zos.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
