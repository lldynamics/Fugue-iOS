import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ReadingWorkflowTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: CurrentSchema.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testGlobalBookHitsLocateTheirExactSourceAndQuoteWithoutDisplayEllipses() async throws {
        let container = try makeContainer()
        let query = "测试关键词"
        let chapters = [
            BookChapter(title: "起点", text: query + "。"),
            BookChapter(title: "中部", text: "  🌿这里是书中一段文字。\n" + query + "之后接着是解释。"),
            BookChapter(title: "长章", text: String(repeating: "开篇。", count: 22) + query + String(repeating: "下文。", count: 53))
        ]
        let prepared = try PreparedBook(BookManuscript(title: "测试读物", chapters: chapters))
        container.mainContext.insert(BookVolume(id: prepared.id, title: prepared.title,
                                                chapterTitles: prepared.chapterTitles, manuscript: prepared.data))
        try container.mainContext.save()
        let result = try await ConversationHistorySearch().searchAll(for: HistorySearchQuery(text: query, scope: .books), in: container)
        let hits = result.books.sorted { $0.chapterIndex < $1.chapterIndex }
        XCTAssertEqual(hits.map(\.chapterIndex), [0, 1, 2])
        for hit in hits {
            let citation = try XCTUnwrap(hit.citation)
            let page = try BookReadingPage.make(chapters: chapters, preferred: hit.chapterIndex, citation: citation)
            XCTAssertTrue(page.located)
            XCTAssertTrue(citation.excerpt.contains(query))
            XCTAssertTrue(citation.quotedText.contains(hit.bookTitle))
            XCTAssertTrue(citation.quotedText.contains(hit.sectionTitle))
            let offset = try XCTUnwrap(citation.utf16Offset)
            let source = chapters[hit.chapterIndex].text as NSString
            XCTAssertEqual(source.substring(with: NSRange(location: offset, length: citation.excerpt.utf16.count)), citation.excerpt)
        }
        XCTAssertTrue(try XCTUnwrap(hits.last).excerpt.fullSnippet.contains("…"))

    }

    func testReasoningFilterPreservesFilenameHits() async throws {
        let container = try makeContainer()
        let chat = Conversation(title: "一次对话")
        container.mainContext.insert(chat)
        let doc = MessageAttachment(kind: .document, fileName: "Receiptprobe.txt", mimeType: "text/plain",
                                    dataBase64: nil, extractedText: "独立材料正文", byteSize: 18)
        let message = ChatMessage(role: .user, content: "请阅读文件", attachments: [doc], sortIndex: 0)
        message.conversation = chat
        container.mainContext.insert(message)
        try container.mainContext.save()

        let search = ConversationHistorySearch()
        let withReasoning = try await search.searchAll(for: HistorySearchQuery(text: "Receiptprobe", includeReasoning: true), in: container)
        let withoutReasoning = try await search.searchAll(for: HistorySearchQuery(text: "Receiptprobe", includeReasoning: false), in: container)
        XCTAssertEqual(withReasoning.conversations.first?.hits.first?.matchedField, .attachment)
        XCTAssertEqual(withoutReasoning.conversations.first?.hits.first?.matchedField, .attachment)
    }
}

extension ReadingWorkflowTests {
    func testSavedAnnotationSurvivesBookRemovalAndReturnsToRepeatedPassage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let chapters = [BookChapter(title: "桥", text: "🌱旧桥。\n旧桥。")]
        let prepared = try PreparedBook(BookManuscript(title: "手记", chapters: chapters))
        let book = try BookLibrary.store(prepared, in: context)
        let annotation = ReadingAnnotation.Snapshot(id: UUID(), volumeID: book.id, bookTitle: book.title, chapterTitle: "桥",
            chapterIndex: 0, utf16Offset: "🌱旧桥。\n".utf16.count, excerpt: "旧桥。", note: "第二处桥", updatedAt: Date())
        context.insert(ReadingAnnotation(annotation))
        try context.save()
        try BookLibrary.remove(book, in: context)
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<ReadingAnnotation>()).first).snapshot
        XCTAssertEqual(saved.id, annotation.id)
        let page = try BookReadingPage.make(chapters: chapters, preferred: 0, citation: saved.citation)
        XCTAssertEqual(page.paragraphs.filter { $0.highlight != nil }.map(\.id), [1])
        let word = try XCTUnwrap(saved.citation.selecting(NSRange(location: 1, length: 1)))
        XCTAssertEqual(word.excerpt, "桥")
        XCTAssertEqual(word.utf16Offset, "🌱旧桥。\n旧".utf16.count)
        XCTAssertNil(saved.citation.selecting(NSRange(location: 100, length: 1)))
        let markdown = ReadingAnnotation.markdown([saved])
        XCTAssertTrue(markdown.contains("《手记》 · 桥"))
        XCTAssertTrue(markdown.contains("> 旧桥。"))
        XCTAssertTrue(markdown.contains("第二处桥"))
    }

    func testCorrectedOCRFormatsAndStaleResultsDoNotChangeUnrelatedAttachments() throws {
        let image = MessageAttachment(kind: .image, fileName: "原件.png", mimeType: "image/png", dataBase64: "AAAA", byteSize: 3)
        let other = MessageAttachment(kind: .document, fileName: "其他.md", mimeType: "text/markdown", extractedText: "无关", byteSize: 6)
        let review = DraftAttachmentReview(sources: [image], recognize: true)
        let input = [other, image]
        XCTAssertEqual(try review.applying(.original, text: "校对", coverage: nil, to: input), input)
        let text = try review.applying(.text, text: "校对", coverage: nil, to: input)
        XCTAssertEqual(text.count, 2)
        XCTAssertEqual(text[0], other)
        XCTAssertNil(text[1].dataBase64)
        XCTAssertEqual(text[1].extractedText, "校对")
        let both = try review.applying(.both, text: "校对", coverage: nil, to: input)
        XCTAssertEqual(both.count, 3)
        XCTAssertTrue(both.contains(image))
        XCTAssertEqual(both.last?.extractedText, "校对")
        XCTAssertThrowsError(try review.applying(.text, text: "校对", coverage: nil, to: [other]))
    }

    func testQuestionsKeepAttachmentOnlyPromptsAndDoNotIncludeAssistantAnswers() {
        let attached = MessageAttachment(kind: .document, fileName: "笔记.txt", mimeType: "text/plain", extractedText: "x", byteSize: 1)
        let first = ChatMessage(role: .user, content: "第一问", sortIndex: 0)
        let second = ChatMessage(role: .user, content: "", attachments: [attached], sortIndex: 2)
        let result = ChatTopicScrubberView.PromptMilestone.questions(in: [
            first, ChatMessage(role: .assistant, content: "答", sortIndex: 1), second
        ])
        XCTAssertEqual(result.map(\.id), [first.id, second.id])
        XCTAssertEqual(result.map(\.preview), ["第一问", "笔记.txt"])
        let reply = ChatMessage(role: .assistant, content: "答", sortIndex: 1)
        let timeline = [first, reply, second]
        XCTAssertEqual(ConversationSearchSheet.neighboringQuestions(in: timeline, at: reply.id).previous, first.id)
        XCTAssertEqual(ConversationSearchSheet.neighboringQuestions(in: timeline, at: first.id).next, second.id)
        XCTAssertEqual(ConversationSearchSheet.neighboringQuestions(in: timeline, at: nil).previous, second.id)
    }

    func testV9MemoryAndShelfOffsetsMigrateToVersionTen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("migration.store")
        let id = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV9.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: file)])
            let memory = SchemaV6.PersonalMemory(id: id, content: "保留")
            let shelf = SchemaV8.ShelfReadingState(bookID: id)
            shelf.chapter = 3
            shelf.paragraph = 7
            container.mainContext.insert(memory)
            container.mainContext.insert(shelf)
            try container.mainContext.save()
        }
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try PersistenceController.open(schema: schema, configuration: ModelConfiguration(schema: schema, url: file))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<PersonalMemory>()).first?.content, "保留")
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<ShelfReadingState>()).first?.paragraph, 7)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<ReadingAnnotation>()), 0)
    }
}

extension ReadingWorkflowTests {
    func testArenaDecisionPreservesOriginalAnswersAndMergesWithoutReplacingBookmarks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let chat = Conversation(title: "写作比较")
        let group = UUID()
        let question = ChatMessage(role: .user, content: "哪个写法更清楚？", sortIndex: 0)
        let chosen = ChatMessage(role: .assistant, content: "原答案 A", comparisonGroupID: group, sortIndex: 1)
        let other = ChatMessage(role: .assistant, content: "原答案 B", comparisonGroupID: group,
                                isSelectedInGroup: false, sortIndex: 2)
        chosen.parentMessageID = question.id
        other.parentMessageID = question.id
        chosen.latencyMs = 410
        context.insert(chat)
        for message in [question, chosen, other] {
            message.conversation = chat
            context.insert(message)
        }
        try context.save()
        let decision = try XCTUnwrap(ArenaDecision.capture(selected: chosen, peers: [chosen, other]))
        XCTAssertEqual(decision.question, question.content)
        XCTAssertEqual(decision.answers.map(\.content), ["原答案 A", "原答案 B"])
        XCTAssertEqual(decision.answers.first?.elapsedMs, 410)
        XCTAssertNil(decision.answers.first?.estimatedCost)
        let tags = ArenaDecision.tags(from: "写作，Writing、writing, 写作 ")
        XCTAssertEqual(tags, ["写作", "Writing"])
        try decision.save(tags: tags, reason: "结构清楚", to: chosen, in: context)
        let archive = try BackupService.encode(BackupService.makeArchive(context: context))
        let saved = try XCTUnwrap(chosen.assistanceMetadata.arenaDecisions?.first)
        other.content = "重新生成的 B"
        chosen.content = "重新生成的 A"
        var local = chosen.assistanceMetadata
        local.isBookmarked = true
        local.arenaDecisions = nil
        chosen.assistanceMetadata = local
        try context.save()
        try BackupService.apply(BackupService.decode(archive), to: context)
        try BackupService.apply(BackupService.decode(archive), to: context)
        XCTAssertTrue(chosen.assistanceMetadata.isBookmarked)
        XCTAssertEqual(chosen.assistanceMetadata.arenaDecisions, [saved])
        XCTAssertEqual(saved.answers.map(\.content), ["原答案 A", "原答案 B"])
        let history = ChatEngine().buildPromptHistory(messages: [question, chosen], limit: 0)
        XCTAssertFalse(history.contains { $0.content.contains("结构清楚") || $0.content.contains("原答案 B") })
        try saved.delete(from: chosen, in: context)
        try BackupService.apply(BackupService.decode(archive), to: context)
        let tombstone = try XCTUnwrap(chosen.assistanceMetadata.arenaDecisions?.first)
        XCTAssertEqual(tombstone.isDeleted, true)
        XCTAssertTrue(tombstone.answers.isEmpty)
        XCTAssertTrue(tombstone.reason.isEmpty)
        XCTAssertTrue(tombstone.tags.isEmpty)
    }
}

extension ReadingWorkflowTests {
    func testQuotationPreservesAnExistingDraftAndItsPriorSourceOnRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ChatDraftStore(directory: directory)
        let id = UUID()
        let draft = store.state(for: id)
        draft.text = "已有问题"
        draft.quotedText = "已有引用"
        draft.save()
        let citation = ReadingCitation(KnowledgePassage(id: 1, volumeID: UUID(), documentTitle: "书",
            sectionTitle: "第一章", excerpt: "原文", chapterIndex: 0, utf16Offset: 0))
        try draft.addReadingCitation(citation)
        try draft.addReadingCitation(citation)
        let saved = try store.load(id)
        XCTAssertEqual(saved.quotedText, "已有引用")
        XCTAssertEqual(saved.text, "已有问题\n\n《书》 · 第一章\n原文")
    }
}
