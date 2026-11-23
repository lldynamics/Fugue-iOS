import Foundation
import os
import SwiftData
import UIKit
import XCTest
import ZIPFoundation
@testable import iOSBox

@MainActor
final class BookFriendTests: XCTestCase {
    private let novel = """
    第一章 初见
    阿禾轻声说：“雨停后再出门。”
    白叔说：“隔壁的蓝伞归我。”
    第二章 渡口
    阿禾把铜钟搬到鹭洲。她又检查了一遍船。
    第三章 重逢
    禾姑娘笑着答道：“晚霞染红的灯塔在西岸。”
    """
    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
    private func stored(in context: ModelContext) throws -> BookVolume {
        try BookLibrary.store(PreparedBook(BookImporter.parse(Data(novel.utf8), filename: "渡河记.txt")), in: context)
    }
    private func character(_ book: BookVolume, cutoff: Int? = nil) throws -> BookFriend {
        try BookFriend.make(book: book, name: " 阿禾 ", aliases: "禾姑娘", throughChapter: cutoff)
    }

    func testWholeTextImportFindsLateRoleAndSplitsMarkdownAndUTF16() async throws {
        let padding = String(repeating: "清晨的河面很平静。\n", count: 9_000)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: file) }
        let raw = "# 河畔\n" + padding + "\n# 雨夜\n砚青说：“山门打开了。”"
        try XCTUnwrap(raw.data(using: .utf16)).write(to: file)
        let prepared = try BookImporter.read(file)
        let db = try container(), book = try BookLibrary.store(prepared, in: db.mainContext)
        XCTAssertEqual(book.chapterTitles, ["河畔", "雨夜"])
        let friend = try BookFriend.make(book: book, name: "砚青", aliases: "", throughChapter: nil)
        let result = try await BookReferenceSearch().reference(for: friend, manuscript: book.manuscript, question: "山门")
        XCTAssertEqual(result.excerpts.map(\.chapter), ["雨夜"])
        XCTAssertTrue(result.excerpts[0].text.contains("山门打开了"))
    }

    func testRetrievalUsesAliasesQuestionAndChapterCutoff() async throws {
        let db = try container(), book = try stored(in: db.mainContext)
        let search = BookReferenceSearch()
        let all = try await search.reference(for: character(book), manuscript: book.manuscript, question: "晚霞染红的灯塔在哪")
        XCTAssertEqual(all.excerpts.first?.chapter, "第三章 重逢")
        XCTAssertTrue(all.excerpts.contains { $0.text.contains("禾姑娘") })
        XCTAssertFalse(all.excerpts.contains { $0.text.contains("蓝伞") })
        let early = try await search.reference(for: character(book, cutoff: 0), manuscript: book.manuscript, question: "西岸的灯塔")
        XCTAssertEqual(early.excerpts.map(\.chapter), ["第一章 初见"])
        XCTAssertFalse(try early.referenceText().contains("西岸"))
        let missing = try BookFriend.make(book: book, name: "不存在的人", aliases: "", throughChapter: nil)
        do { _ = try await search.reference(for: missing, manuscript: book.manuscript, question: ""); XCTFail("Expected unmatched role") }
        catch BookImportError.noMatches { }
    }

    func testLongParagraphAndEnglishNameBoundaries() async throws {
        let manuscript = BookManuscript(title: "Crossing", chapters: [
            BookChapter(title: "I", text: "Joanne saw a private lighthouse.\n" + String(repeating: "x ", count: 600) + "Ann said, “Look for the copper key.”")
        ])
        let prepared = try PreparedBook(manuscript)
        let friend = BookFriend(bookID: prepared.id, bookTitle: prepared.title, name: "Ann", aliases: [], throughChapter: nil)
        let found = try await BookReferenceSearch().reference(for: friend, manuscript: prepared.data, question: "copper key")
        XCTAssertTrue(try XCTUnwrap(found.excerpts.first).text.contains("copper key"))
        XCTAssertFalse(try found.referenceText().contains("Joanne"))
        XCTAssertTrue(found.excerpts.allSatisfy { $0.text.count <= 420 })
    }

    private func epub(encryptText: Bool = false) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        func add(_ path: String, _ text: String) throws {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, size in
                let start = Int(offset)
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", #"<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>"#)
        try add("OPS/book.opf", """
            <package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>灯塔</dc:title></metadata>
            <manifest><item id="b" href="text/last.xhtml" media-type="application/xhtml+xml"/><item id="a" href="text/first%20chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="a"/><itemref idref="b"/></spine></package>
            """)
        try add("OPS/text/last.xhtml", "<html><head><title>重逢</title></head><body><h1>末章</h1><p>阿禾在码头。</p></body></html>")
        try add("OPS/text/first chapter.xhtml", "<html><body><script>unused text</script><h1>首章</h1><p>阿禾<span>说</span>你好。&nbsp;鸣钟。</p></body></html>")
        let protectedPath = encryptText ? "OPS/text/last.xhtml" : "OPS/fonts/book.otf"
        try add("META-INF/encryption.xml", "<encryption><CipherReference URI=\"\(protectedPath)\"/></encryption>")
        return try XCTUnwrap(archive.data)
    }

    func testEPUBReadsCompressedSpineOrderAndLocalTextOnly() throws {
        let book = try BookImporter.parse(epub(), filename: "file.epub")
        XCTAssertEqual(book.title, "灯塔")
        XCTAssertEqual(book.chapters.map(\.title), ["首章", "末章"])
        XCTAssertTrue(book.chapters[0].text.contains("阿禾说你好"))
        XCTAssertTrue(book.chapters[0].text.contains("鸣钟"))
        XCTAssertFalse(book.chapters[0].text.contains("unused text"))
        XCTAssertThrowsError(try BookImporter.parse(epub(encryptText: true), filename: "protected.epub")) {
            guard case BookImportError.locked = $0 else { return XCTFail("Expected protected content") }
        }
    }

    func testPDFTextAndUnreadableDocuments() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 260, height: 240))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Sophie waited by the gate." as NSString).draw(at: CGPoint(x: 10, y: 12), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            context.beginPage()
            ("Sophie found the key." as NSString).draw(at: CGPoint(x: 10, y: 12), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        let book = try BookImporter.parse(data, filename: "Gate.pdf")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertTrue(book.chapters[1].text.contains("key"))
        XCTAssertThrowsError(try BookImporter.parse(renderer.pdfData { $0.beginPage() }, filename: "scan.pdf"))
        XCTAssertThrowsError(try BookImporter.parse(Data(), filename: "empty.txt"))
        XCTAssertThrowsError(try BookImporter.parse(Data([1, 2, 3]), filename: "other.docx"))
    }

    func testLibraryReusesBookAndFriendAndKeepsSeparateHistories() throws {
        let db = try container(), ctx = db.mainContext
        let book = try stored(in: ctx)
        let same = try BookLibrary.store(PreparedBook(BookImporter.parse(Data(novel.utf8), filename: "another.txt")), in: ctx)
        XCTAssertEqual(same.id, book.id)
        let friend = try character(book)
        let chat = try BookLibrary.open(friend, target: nil, in: ctx)
        XCTAssertFalse(chat.isGroupMode)
        XCTAssertEqual(try BookLibrary.open(friend, target: nil, in: ctx).id, chat.id)
        let other = try BookFriend.make(book: book, name: "白叔", aliases: "", throughChapter: nil)
        XCTAssertNotEqual(try BookLibrary.open(other, target: nil, in: ctx).id, chat.id)
        let aliasUpdate = try BookFriend.make(book: book, name: "阿禾", aliases: "禾姑娘,小禾", throughChapter: nil)
        XCTAssertEqual(try BookLibrary.open(aliasUpdate, target: nil, in: ctx).id, chat.id)
        XCTAssertEqual(chat.activeBookFriend?.aliases, ["禾姑娘", "小禾"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BookVolume>()), 1)
        try BookLibrary.remove(book, in: ctx)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<BookVolume>()), 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Conversation>()), 2)
        _ = try stored(in: ctx)
        XCTAssertEqual(try BookLibrary.open(aliasUpdate, target: nil, in: ctx).id, chat.id)
    }

    func testNamedConversationSendsOnlySelectedExcerptsOnSendRetryAndContinuation() async throws {
        let db = try container(), ctx = db.mainContext, book = try stored(in: ctx)
        let p = ProviderConfig(name: "Fixture", protocolType: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1",
                               models: [ModelSpec(id: "local")])
        ctx.insert(p)
        let target = p.makeTarget(for: p.models[0])
        let chat = try BookLibrary.open(character(book, cutoff: 1), target: target, in: ctx)
        let captured = OSAllocatedUnfairLock(initialState: [LLMChatRequest]())
        let engine = ChatEngine(stream: { req in
            captured.withLock { $0.append(req) }
            return AsyncThrowingStream { cont in cont.yield(.contentDelta("我记得那座渡口。")); cont.yield(.done); cont.finish() }
        })
        XCTAssertEqual(engine.sendUserMessage(text: "铜钟在哪里？", attachments: [], in: chat, providers: [p], context: ctx), .sent)
        await idle(engine, chat.id)
        let reply = try XCTUnwrap(chat.sortedMessages.last)
        let evidence = try XCTUnwrap(reply.assistanceMetadata.bookReply)
        XCTAssertEqual(evidence.excerpts.first?.chapter, "第二章 渡口")
        XCTAssertTrue(ConversationExporter.makeMarkdown(for: chat).contains(evidence.byline))
        engine.regenerate(assistantMessage: reply, in: chat, providers: [p], context: ctx)
        await idle(engine, chat.id)
        engine.continueGeneration(assistantMessage: reply, in: chat, providers: [p], context: ctx)
        await idle(engine, chat.id)
        let requests = captured.withLock { $0 }
        XCTAssertEqual(requests.count, 3)
        for req in requests {
            XCTAssertTrue(req.systemPrompt.contains("渡河记"))
            XCTAssertFalse(req.systemPrompt.contains("鹭洲"))
            let texts = req.messages.map(\.content).joined()
            XCTAssertTrue(texts.contains("鹭洲"))
            XCTAssertFalse(texts.contains("灯塔"))
            XCTAssertFalse(texts.contains("蓝伞"))
        }
        let plain = Conversation(title: "普通对话", primaryTarget: target)
        ctx.insert(plain)
        XCTAssertEqual(engine.sendUserMessage(text: "你好", attachments: [], in: plain, providers: [p], context: ctx), .sent)
        await idle(engine, plain.id)
        let ordinary = try XCTUnwrap(captured.withLock { $0.last })
        XCTAssertFalse(ordinary.messages.map(\.content).joined().contains("鹭洲"))
        XCTAssertNil(plain.sortedMessages.last?.assistanceMetadata.bookReply)
    }

    private func idle(_ engine: ChatEngine, _ id: UUID) async {
        let limit = ContinuousClock.now + .seconds(6)
        while engine.isGenerating(in: id), ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(15)) }
        XCTAssertFalse(engine.isGenerating(in: id))
    }

    func testAdvancingKeepsTheChatAndRewindingStartsAnEmptyHistory() throws {
        let db = try container(), ctx = db.mainContext, book = try stored(in: ctx)
        let chat = try BookLibrary.open(character(book, cutoff: 0), target: nil, in: ctx)
        let history = ChatMessage(role: .user, content: "我的私信", sortIndex: 0)
        history.conversation = chat
        ctx.insert(history)
        try ctx.save()
        XCTAssertEqual(try BookLibrary.open(character(book, cutoff: 1), target: nil, in: ctx).id, chat.id)
        XCTAssertEqual(try BookLibrary.changeProgress(in: chat, through: nil, context: ctx).id, chat.id)
        XCTAssertThrowsError(try BookLibrary.changeProgress(in: chat, through: 10, context: ctx))
        let earlier = try BookLibrary.changeProgress(in: chat, through: 0, context: ctx)
        XCTAssertNotEqual(earlier.id, chat.id)
        XCTAssertEqual(earlier.activeBookFriend?.throughChapter, 0)
        XCTAssertNil(chat.activeBookFriend?.throughChapter)
        XCTAssertTrue(earlier.messages.isEmpty)
        XCTAssertEqual(chat.messages.map(\.content), ["我的私信"])
    }

    func testSuggestedNamesHaveLiteralEvidenceWithinReadingRange() throws {
        let book = try PreparedBook(BookManuscript(title: "试读", chapters: [
            BookChapter(title: "见面", text: "阿禾轻声说：“天亮了。”\nMira asked about the rain."),
            BookChapter(title: "后来", text: "顾云说：“密信到了。”")
        ]))
        let first = try BookCharacterSuggestions.find(in: book.data, through: 0)
        XCTAssertTrue(first.contains { $0.name == "阿禾" })
        XCTAssertTrue(first.contains { $0.name == "Mira" })
        XCTAssertTrue(first.allSatisfy { $0.chapter == "见面" && $0.excerpt.contains($0.name) })
        XCTAssertFalse(first.contains { $0.name == "顾云" })
        XCTAssertTrue(try BookCharacterSuggestions.find(in: book.data, through: nil).contains { $0.name == "顾云" })
    }

    func testInvitationsUseReadyTargetsShareGroupProgressAndSurviveBackup() throws {
        let db = try container(), ctx = db.mainContext, book = try stored(in: ctx)
        let ready = ProviderConfig(name: "本地", protocolType: .openAICompatible, baseURL: "http://localhost", models: [ModelSpec(id: "ok")])
        let pending = ProviderConfig(name: "未连接", protocolType: .openAICompatible, baseURL: "https://example.com", models: [ModelSpec(id: "pending")])
        ctx.insert(ready); ctx.insert(pending)
        let providers = [pending, ready], target = ready.makeTarget(for: ready.models[0])
        let template = try XCTUnwrap(GroupRoomTemplate.builtInTemplates.first)
        let defaults = template.instantiate(using: ProviderConfig.readyTargets(in: providers))
        XCTAssertEqual(defaults.count, 3)
        XCTAssertTrue(defaults.allSatisfy { $0.target.id == target.id })
        let group = Conversation(title: "读书群", primaryTarget: pending.makeTarget(for: pending.models[0]))
        group.isGroupMode = true
        ctx.insert(group)
        let first = try character(book, cutoff: 0)
        try BookLibrary.invite(first, to: group, providers: providers, in: ctx)
        let other = try BookFriend.make(book: book, name: "白叔", aliases: "", throughChapter: nil)
        try BookLibrary.invite(other, to: group, providers: providers, in: ctx)
        XCTAssertEqual(group.groupMembers.compactMap(\.bookFriend).map(\.throughChapter), [0, 0])
        XCTAssertTrue(group.groupMembers.allSatisfy { $0.target.id == target.id })
        XCTAssertThrowsError(try BookLibrary.invite(first, to: group, providers: providers, in: ctx))
        let solo = try BookLibrary.open(other, target: target, in: ctx)
        var roster = group.groupMembers
        BookGroupRoster.setProgress(for: book.id, through: 1, in: &roster)
        group.assistanceSettings.groupMembers = roster
        XCTAssertNil(solo.activeBookFriend?.throughChapter)
        XCTAssertEqual(group.groupMembers.compactMap(\.bookFriend).map(\.throughChapter), [1, 1])
        let full = Array(repeating: defaults[0], count: 6)
        XCTAssertThrowsError(try BookGroupRoster.inviting(first, into: full, target: target))
        XCTAssertThrowsError(try BookGroupRoster.inviting(first, into: [], target: nil))
        try ctx.save()
        let archive = try BackupService.makeArchive(context: ctx)
        let dest = try container()
        _ = try BackupService.apply(.full(archive), to: dest.mainContext)
        let restored = try XCTUnwrap(dest.mainContext.fetch(FetchDescriptor<Conversation>()).first(where: \.isGroupMode))
        XCTAssertEqual(restored.groupMembers.compactMap(\.bookFriend), roster.compactMap(\.bookFriend))
        XCTAssertEqual(try dest.mainContext.fetchCount(FetchDescriptor<BookVolume>()), 1)
    }

    func testGroupKnowledgeAndOriginalShareChapterLimitsAcrossColdAndWarmCaches() async throws {
        let db = try container(), ctx = db.mainContext, book = try stored(in: ctx)
        let reference = try BookLibrary.store(PreparedBook(.init(title: "参考", chapters: [.init(title: "索引", text: "灯塔索引")])), in: ctx)
        let provider = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "http://127.0.0.1", models: [.init(id: "ok")])
        var member = GroupMember(name: "读者", rolePrompt: "", target: provider.makeTarget(for: provider.models[0]))
        member.bookFriend = try character(book, cutoff: 0)
        let chat = Conversation()
        chat.assistanceSettings = AssistanceSettings(isGroupMode: true, groupMembers: [member])
        let cache = ProjectKnowledgeSearch(), volumes = [book.id, reference.id]
        for _ in 0..<2 {
            let scoped = try await ProjectKnowledgeSearch.retrieve(volumeIDs: volumes, in: ctx, query: "灯塔", chapterLimits: chat.readingChapterLimits, search: cache)
            XCTAssertFalse(scoped.passages.contains { $0.volumeID == book.id && $0.chapterIndex != 0 })
            XCTAssertTrue(scoped.passages.contains { $0.volumeID == reference.id })
        }
        let full = try await ProjectKnowledgeSearch.retrieve(volumeIDs: volumes, in: ctx, query: "灯塔", search: cache)
        let future = try XCTUnwrap(full.passages.first { $0.volumeID == book.id && $0.chapterIndex == 2 })
        let chapters = try BookReadingPage.chapters(from: book.manuscript, through: chat.readingChapterLimits[book.id])
        XCTAssertEqual(chapters.count, 1)
        let page = try BookReadingPage.make(chapters: chapters, preferred: 2, citation: ReadingCitation(future))
        XCTAssertEqual(page.chapterIndex, 0)
        XCTAssertFalse(page.located)
    }

    func testGroupCharacterReadsOnlyGroupScopeOnSendRetryAndContinuation() async throws {
        let db = try container(), ctx = db.mainContext, book = try stored(in: ctx)
        let provider = ProviderConfig(name: "本地", protocolType: .openAICompatible, baseURL: "http://127.0.0.1", models: [ModelSpec(id: "ok")])
        ctx.insert(provider)
        let target = provider.makeTarget(for: provider.models[0])
        let solo = try BookLibrary.open(character(book), target: target, in: ctx)
        let note = ChatMessage(role: .user, content: "仅出现在私聊的暗号", sortIndex: 0)
        note.conversation = solo; ctx.insert(note)
        let group = Conversation(title: "读书会", primaryTarget: target)
        group.assistanceSettings = AssistanceSettings(isGroupMode: true, groupSpeakingMode: .roundRobin)
        ctx.insert(group)
        try BookLibrary.invite(character(book, cutoff: 0), to: group, providers: [provider], in: ctx)
        // The same full manuscript is also attached as general group knowledge.
        group.assistanceSettings.knowledgeVolumeIDs = [book.id]
        let warm = try await ProjectKnowledgeSearch.retrieve(volumeIDs: [book.id], in: ctx, query: "灯塔")
        XCTAssertTrue(warm.passages.contains { $0.chapterIndex == 2 })
        let requests = OSAllocatedUnfairLock(initialState: [LLMChatRequest]())
        let engine = ChatEngine(stream: { request in
            requests.withLock { $0.append(request) }
            return AsyncThrowingStream { stream in stream.yield(.contentDelta("我们等雨停。")); stream.yield(.done); stream.finish() }
        })
        XCTAssertEqual(engine.sendUserMessage(text: "什么时候出门？渡口与灯塔在哪里？", attachments: [], in: group, providers: [provider], context: ctx), .sent)
        await idle(engine, group.id)
        let reply = try XCTUnwrap(group.sortedMessages.last)
        XCTAssertEqual(reply.assistanceMetadata.bookReply?.excerpts.first?.chapter, "第一章 初见")
        let knowledge = try XCTUnwrap(reply.assistanceMetadata.knowledgeEvidence)
        XCTAssertFalse(knowledge.passages.isEmpty)
        XCTAssertTrue(knowledge.passages.allSatisfy { $0.chapterIndex == 0 })
        engine.regenerate(assistantMessage: reply, in: group, providers: [provider], context: ctx)
        await idle(engine, group.id)
        engine.continueGeneration(assistantMessage: reply, in: group, providers: [provider], context: ctx)
        await idle(engine, group.id)
        let sent = requests.withLock { $0 }
        XCTAssertEqual(sent.count, 3)
        for req in sent {
            XCTAssertTrue(req.systemPrompt.contains("渡河记"))
            let body = req.messages.map(\.content).joined()
            XCTAssertTrue(body.contains("雨停后再出门"))
            XCTAssertFalse(body.contains("晚霞染红的灯塔"))
            XCTAssertFalse(body.contains("铜钟搬到鹭洲"))
            XCTAssertFalse(body.contains("仅出现在私聊的暗号"))
        }
        var members = group.groupMembers
        BookGroupRoster.setProgress(for: book.id, through: 1, in: &members)
        group.assistanceSettings.groupMembers = members
        let request = try XCTUnwrap(sent.first)
        XCTAssertThrowsError(try request.validateBeforeSending?())
    }

    func testBackupRestoresOneBookForSeveralFriendsAndRejectsChangedContentAtomically() async throws {
        let original = try container(), ctx = original.mainContext, book = try stored(in: ctx)
        let first = try character(book)
        let chat = try BookLibrary.open(first, target: nil, in: ctx)
        _ = try BookLibrary.open(try character(book, cutoff: 0), target: nil, in: ctx)
        let evidence = try await BookReferenceSearch().reference(for: first, manuscript: book.manuscript, question: "渡口")
        let message = ChatMessage(role: .assistant, content: "就在这里。")
        ctx.insert(message); message.conversation = chat; message.assistanceMetadata.bookReply = evidence
        try ctx.save()
        var archive = try BackupService.makeArchive(context: ctx)
        XCTAssertEqual(archive.books?.count, 1)
        let restored = try container(), dest = restored.mainContext
        let data = try BackupService.encode(archive)
        let summary = try BackupService.apply(BackupService.decode(data), to: dest)
        XCTAssertEqual(summary.books, 1)
        let recovered = try XCTUnwrap(BookLibrary.find(first.bookID, in: dest))
        XCTAssertEqual(recovered.manuscript, book.manuscript)
        XCTAssertEqual(try dest.fetch(FetchDescriptor<ChatMessage>()).first?.assistanceMetadata.bookReply, evidence)
        XCTAssertEqual(try BackupService.apply(BackupService.decode(data), to: dest).books, 0)
        let empty = try container()
        archive.books?[0].chapters[0].text = "被修改的书稿"
        XCTAssertThrowsError(try BackupService.apply(.full(archive), to: empty.mainContext))
        XCTAssertEqual(try empty.mainContext.fetchCount(FetchDescriptor<Conversation>()), 0)
        XCTAssertEqual(try empty.mainContext.fetchCount(FetchDescriptor<BookVolume>()), 0)
    }

    func testMissingSourceKeepsHistoryAndStopsBeforeModelRequest() async throws {
        let db = try container(), ctx = db.mainContext, book = try stored(in: ctx)
        let provider = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "http://127.0.0.1/v1",
                                      models: [ModelSpec(id: "demo")])
        ctx.insert(provider)
        let chat = try BookLibrary.open(character(book), target: provider.makeTarget(for: provider.models[0]), in: ctx)
        let history = ChatMessage(role: .user, content: "旧记录", sortIndex: 0)
        ctx.insert(history)
        history.conversation = chat
        try ctx.save()
        try BookLibrary.remove(book, in: ctx)
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let engine = ChatEngine(stream: { _ in
            sent.withLock { $0 += 1 }
            return AsyncThrowingStream { $0.finish() }
        })
        XCTAssertEqual(engine.sendUserMessage(text: "还记得渡口吗？", attachments: [], in: chat, providers: [provider], context: ctx), .sent)
        await idle(engine, chat.id)
        XCTAssertEqual(sent.withLock { $0 }, 0)
        XCTAssertEqual(chat.sortedMessages.last?.errorMessage, BookImportError.unavailable.localizedDescription)
        XCTAssertEqual(chat.sortedMessages.first?.content, "旧记录")
        _ = try stored(in: ctx)
        XCTAssertEqual(try BookLibrary.open(try XCTUnwrap(chat.activeBookFriend), target: nil, in: ctx).id, chat.id)
    }

    func testV5StoreOpensWithBookshelfAndRetainsExistingConversation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("book-migration-\(UUID()).store")
        let chatID = UUID()
        do {
            let old = Schema(versionedSchema: SchemaV5.self)
            let db = try ModelContainer(for: old, configurations: [ModelConfiguration(schema: old, url: url)])
            db.mainContext.insert(SchemaV5.Conversation(id: chatID, title: "保留对话"))
            try db.mainContext.save()
        }
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let migrated = try PersistenceController.open(schema: schema, configuration: ModelConfiguration(schema: schema, url: url))
        XCTAssertEqual(try migrated.mainContext.fetch(FetchDescriptor<Conversation>()).first?.id, chatID)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<BookVolume>()), 0)
        _ = try stored(in: migrated.mainContext)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<BookVolume>()), 1)
    }
}

extension BookFriendTests {
    func testNewFriendStartsAtFirstChapterAndSwitchingBooksResetsFullBookConsent() throws {
        let db = try container(), book = try stored(in: db.mainContext)
        var scope = BookFriendReadingScope()
        scope.select(book.id)
        XCTAssertEqual(scope.throughChapter, 0)
        let initial = try BookCharacterSuggestions.find(in: book.manuscript, through: scope.throughChapter)
        XCTAssertFalse(initial.isEmpty)
        XCTAssertTrue(initial.allSatisfy { $0.chapter == book.chapterTitles[0] })
        scope.throughChapter = nil
        scope.select(book.id)
        XCTAssertNil(scope.throughChapter)
        scope.select(UUID())
        XCTAssertEqual(scope.throughChapter, 0)
    }

    func testGroupExpansionRequiresConsentForTheExactReadingRange() throws {
        let db = try container(), ctx = db.mainContext, book = try stored(in: ctx)
        let early = try character(book, cutoff: 0)
        let host = try BookFriend.make(book: book, name: "白叔", aliases: "", throughChapter: 1)
        let provider = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "http://localhost/v1",
                                      models: [ModelSpec(id: "book")])
        ctx.insert(provider)
        let solo = try BookLibrary.open(early, target: nil, in: ctx)
        let group = Conversation(title: "Club")
        group.isGroupMode = true
        ctx.insert(group)
        try BookLibrary.invite(host, to: group, providers: [provider], in: ctx)
        XCTAssertThrowsError(try BookLibrary.invite(early, to: group, providers: [provider], in: ctx))
        XCTAssertEqual(group.groupMembers.count, 1)
        let accepted = BookGroupRoster.groupVersion(of: early, in: group.groupMembers)
        XCTAssertEqual(accepted.throughChapter, 1)
        var members = group.groupMembers
        BookGroupRoster.setProgress(for: book.id, through: nil, in: &members)
        group.assistanceSettings.groupMembers = members
        XCTAssertThrowsError(try BookLibrary.invite(early, to: group, providers: [provider], in: ctx, confirmedProgress: accepted))
        let whole = BookGroupRoster.groupVersion(of: early, in: members)
        try BookLibrary.invite(early, to: group, providers: [provider], in: ctx, confirmedProgress: whole)
        XCTAssertEqual(group.groupMembers.count, 2)
        XCTAssertNil(try XCTUnwrap(group.groupMembers.last?.bookFriend).throughChapter)
        XCTAssertEqual(solo.activeBookFriend?.throughChapter, 0)
    }
}
