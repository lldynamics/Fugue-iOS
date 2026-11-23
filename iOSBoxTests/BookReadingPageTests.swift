import XCTest
@testable import iOSBox

final class BookReadingPageTests: XCTestCase {
    private let volume = UUID()

    func testLegacyCitationFindsOnlyMatchingChapterAndHighlightsAcrossLines() throws {
        let old = Data(#"{"id":7,"chapter":"山路","text":"溪水回落。\n老人晒茶。"}"#.utf8)
        let excerpt = try JSONDecoder().decode(BookExcerpt.self, from: old)
        let chapters = [BookChapter(title: "山路", text: "先前的另一章。"),
                        BookChapter(title: "山路", text: "开头🌱\n溪水回落。\n  老人晒茶。\n结尾")]
        let page = try BookReadingPage.make(chapters: chapters, preferred: 0, citation: ReadingCitation(excerpt, in: volume, number: 1))
        XCTAssertTrue(page.located)
        XCTAssertEqual(page.chapterIndex, 1)
        XCTAssertEqual(page.paragraphs.filter { $0.highlight != nil }.map(\.id), [1, 2])
        XCTAssertEqual(page.paragraphs.filter(\.endsCitation).map(\.id), [2])
    }

    func testNewOffsetsDistinguishRepeatedTextAfterEmojiAndLaterChapterStaysOutsideScope() throws {
        let text = "🌱同一句。\n同一句。"
        let offset = "🌱同一句。\n".utf16.count
        let passage = KnowledgePassage(id: 2, volumeID: volume, documentTitle: "手记", sectionTitle: "路上",
                                       excerpt: "同一句。", chapterIndex: 1, utf16Offset: offset)
        let chapters = [BookChapter(title: "路上", text: text), BookChapter(title: "路上", text: text)]
        let page = try BookReadingPage.make(chapters: chapters, preferred: 0, citation: ReadingCitation(passage))
        XCTAssertEqual(page.chapterIndex, 1)
        XCTAssertNil(page.paragraphs[0].highlight)
        XCTAssertEqual(page.paragraphs[1].highlight, NSRange(location: 0, length: 4))
        let limited = try BookReadingPage.make(chapters: Array(chapters.prefix(1)), preferred: 99, citation: ReadingCitation(passage))
        XCTAssertFalse(limited.located)
        XCTAssertEqual(limited.chapterIndex, 0)
    }

    func testSearchResultsCarryUsableOffsetsInTheImportedManuscript() async throws {
        let chapters = [BookChapter(title: "启程", text: "先读这一章。"),
                        BookChapter(title: "山路", text: "  🌿下过雨。\r\n  砚青说：旧桥编号 FZ-17。\n  “我们过桥。”")]
        let data = try JSONEncoder().encode(chapters)
        let friend = BookFriend(bookID: volume, bookTitle: "手记", name: "砚青", aliases: [], throughChapter: 1)
        let evidence = try await BookReferenceSearch().reference(for: friend, manuscript: data, question: "旧桥")
        let excerpt = try XCTUnwrap(evidence.excerpts.first)
        XCTAssertNotNil(excerpt.utf16Offset)
        let friendPage = try BookReadingPage.make(chapters: chapters, preferred: 0, citation: ReadingCitation(excerpt, in: volume, number: 1))
        XCTAssertTrue(friendPage.located)
        let knowledge = try await ProjectKnowledgeSearch().retrieve(from: [.init(id: volume, title: "手记", manuscript: data)], query: "FZ-17")
        let passage = try XCTUnwrap(knowledge.passages.first { $0.excerpt.contains("FZ-17") })
        XCTAssertEqual(passage.chapterIndex, 1)
        XCTAssertNotNil(passage.utf16Offset)
        XCTAssertTrue(try BookReadingPage.make(chapters: chapters, preferred: 0, citation: ReadingCitation(passage)).located)
    }

    func testAmbiguousOrUnknownLegacyQuoteNeverHighlightsAnUnrelatedPassage() throws {
        let chapters = [BookChapter(title: "路上", text: "旧路旁有一条旧路。")]
        for text in ["旧路", "找不到"] {
            let old = BookExcerpt(id: 0, chapter: "路上", text: text)
            let page = try BookReadingPage.make(chapters: chapters, preferred: 0, citation: ReadingCitation(old, in: volume, number: 1))
            XCTAssertFalse(page.located)
            XCTAssertNil(page.paragraphs[0].highlight)
        }
    }

    func testOnlyExplicitUnambiguousMarkersBecomeLinksInTheAnswer() throws {
        let first = KnowledgePassage(id: 1, volumeID: volume, documentTitle: "手记", sectionTitle: "旧桥",
                                     excerpt: "石桥。", chapterIndex: 0, utf16Offset: 0)
        var second = first
        second.id = 2
        second.excerpt = "木桥。"
        second.utf16Offset = 50
        let references = ReadingReferences(knowledge: .init(query: "", passages: [first, second]))
        let end = ReadingCitation(second).marker
        let raw = "旧桥有两座。\(end) 不确定的出处 [Document · 旧桥]。编号 [1]。代码 `\(end)`。"
        let result = references.linkingMarkers(in: try AttributedString(markdown: raw))
        let links = result.runs.compactMap(\.link)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first.flatMap(references.source(for:))?.utf16Offset, 50)
        XCTAssertTrue(String(result.characters).contains("[Document · 旧桥]"))
        XCTAssertTrue(String(result.characters).contains(end))
        XCTAssertEqual(references.linkingMarkers(in: AttributedString("我是语言模型。")), AttributedString("我是语言模型。"))
        let unique = ReadingReferences(knowledge: .init(query: "", passages: [first]))
        let legacy = unique.linkingMarkers(in: AttributedString("据记载。[Document · 旧桥]"))
        XCTAssertEqual(legacy.runs.compactMap(\.link).first.flatMap(unique.source(for:))?.excerpt, "石桥。")
        XCTAssertTrue(KnowledgeEvidence(query: "", passages: [second]).promptText().contains(end))
    }

    func testReferenceLookupHonorsReadingBoundaryAndIgnoresAuthoredLinks() throws {
        let later = KnowledgePassage(id: 1, volumeID: volume, documentTitle: "手记", sectionTitle: "结局",
                                     excerpt: "后来。", chapterIndex: 2, utf16Offset: 0)
        let evidence = KnowledgeEvidence(query: "", passages: [later])
        let restricted = ReadingReferences(knowledge: evidence, limits: [volume: 1])
        XCTAssertTrue(restricted.sources.isEmpty)
        XCTAssertTrue(restricted.linkingMarkers(in: AttributedString(ReadingCitation(later).marker)).runs.compactMap(\.link).isEmpty)
        let references = ReadingReferences(knowledge: evidence)
        let supplied = try AttributedString(markdown: "[打开](iosbox-reading://passage/0) [网站](https://example.org)")
        XCTAssertEqual(references.linkingMarkers(in: supplied).runs.compactMap(\.link).map(\.scheme), ["https"])
    }

    func testSharedPassageIsListedOnceAndTitlesWithMarkdownStillLink() throws {
        let title = "手记 [上]", chapter = "*旧桥*"
        let passage = KnowledgePassage(id: 7, volumeID: volume, documentTitle: title, sectionTitle: chapter,
                                       excerpt: "石桥。", chapterIndex: 0, utf16Offset: 0)
        let part = BookExcerpt(id: 0, chapter: chapter, text: passage.excerpt, chapterIndex: 0, utf16Offset: 0)
        let friend = BookFriend(bookID: volume, bookTitle: title, name: "阿澜", aliases: [], throughChapter: 0)
        let references = ReadingReferences(knowledge: .init(query: "", passages: [passage]),
                                           book: .init(name: friend.name, title: title, excerpts: [part]), friend: friend)
        XCTAssertEqual(references.sources.count, 1)
        let marker = ReadingCitation(passage).marker
        let formatted = references.linkingMarkers(in: try AttributedString(markdown: "翻到旧桥。\(marker)"))
        let url = try XCTUnwrap(formatted.runs.compactMap(\.link).first)
        XCTAssertEqual(references.source(for: url)?.excerpt, part.text)
        XCTAssertEqual(references.source(for: url)?.number, 1)
    }
}
