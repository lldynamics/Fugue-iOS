import os
import SwiftData
import XCTest
@testable import iOSBox

private actor FeedFixture {
    private var replies: [String]
    private var requests: [URLRequest] = []
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ replies: [String]) { self.replies = replies }
    func pause() { paused = true }
    func resume() {
        paused = false
        continuation?.resume()
        continuation = nil
    }
    var count: Int { requests.count }
    var sent: [URLRequest] { requests }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if paused { await withCheckedContinuation { continuation = $0 } }
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        let body = replies.removeFirst()
        if body == "OFFLINE" { throw URLError(.notConnectedToInternet) }
        if body == "EXPIRED" { throw URLReaderError.http(400) }
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(body.utf8), response)
    }
}

@MainActor
final class GroupPersonaTests: XCTestCase {
    private let address = "https://blog.example.org/people/feed.xml"

    private func rss(_ ids: [Int]) -> String {
        let items = ids.map { "<item><guid>entry-\($0)</guid><link>https://blog.example.org/posts/\($0)</link><title>文章 \($0)</title><description>摘录 \($0)</description></item>" }
        return "<rss version=\"2.0\"><channel>" + items.joined() + "</channel></rss>"
    }

    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func makeChat(_ context: ModelContext, feed: PersonaFeed? = nil) throws -> (Conversation, ProviderConfig) {
        let provider = ProviderConfig(name: "Fixture", protocolType: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1",
                                      iconSymbol: "cpu", accentHex: "#333333", isEnabled: true,
                                      models: [ModelSpec(id: "one", displayName: "One"), ModelSpec(id: "two", displayName: "Two")])
        let targets = provider.enabledModels.map { provider.makeTarget(for: $0) }
        var member = GroupMember(name: "阿青", rolePrompt: "园丁", target: targets[0])
        member.persona = GroupPersona(materials: [PersonaMaterial(title: "园艺随笔", text: "雨后的苔藓像一封绿信。")], feeds: feed.map { [$0] } ?? [])
        let other = GroupMember(name: "小林", rolePrompt: "读者", target: targets[1])
        let chat = Conversation(title: "花园", primaryTarget: targets[0])
        chat.assistanceSettings = AssistanceSettings(isGroupMode: true, groupMembers: [member, other], groupSpeakingMode: .roundRobin)
        context.insert(provider)
        context.insert(chat)
        try context.save()
        return (chat, provider)
    }

    func testChatImportSeparatesSimilarNamesAndSupportsStructuredExports() throws {
        let text = """
        [09:30] 阿青：你好
        阿青姐：这是别人的私信
        阿青 2026-04-02 09:31:07
        园子开花了
        昨天种的
        小林 2026-04-02 09:32:00
        不属于阿青
        2026-04-02 09:33 阿青: 再见
        """
        XCTAssertEqual(try PersonaMaterials.chatText(text, speaker: " 阿青 "), "你好\n园子开花了\n昨天种的\n再见")
        let json = #"{"messages":[{"from":"阿青","text":["春天",{"type":"bold","text":"来了"}]},{"from":"小林","text":"他人文字"}]}"#
        XCTAssertEqual(try PersonaMaterials.chatText(json, speaker: "阿青"), "春天来了")
        XCTAssertThrowsError(try PersonaMaterials.chatText(json, speaker: "阿"))
        XCTAssertThrowsError(try PersonaMaterials.chatText(text, speaker: " "))
        let raw = #"[{"sender":"阿青","content":"另一种导出"}]"#
        XCTAssertEqual(try PersonaMaterials.chatText(raw, speaker: "阿青"), "另一种导出")
    }

    func testFileImportReadsUTF16AndRejectsOversizedInput() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try XCTUnwrap("阿青：春天".data(using: .utf16)).write(to: path)
        XCTAssertEqual(try PersonaMaterials.readFile(path), "阿青：春天")
        try Data(repeating: 65, count: URLReader.maximumBytes + 1).write(to: path)
        XCTAssertThrowsError(try PersonaMaterials.readFile(path))
    }

    func testReferenceBudgetIncludesRelevantChinesePassagesAndMultipleWorks() throws {
        let intro = String(repeating: "天", count: 2_400)
        let first = PersonaMaterial(title: "日记", text: intro + "\n春雨和苔藓")
        let second = PersonaMaterial(title: "随笔", text: "春雨中的新芽")
        let block = try XCTUnwrap(PersonaMaterials.referenceBlock([first, second], topic: "春雨过后苔藓如何"))
        XCTAssertTrue(block.contains("春雨和苔藓"))
        XCTAssertTrue(block.contains("春雨中的新芽"))
        XCTAssertLessThan(block.count, 2_400)
        XCTAssertNil(PersonaMaterials.referenceBlock([], topic: "春雨"))
    }

    func testRoundRobinSendsOnlyBoundMaterialsAndMarksSplitBubblesAndRetry() async throws {
        let store = try container(), context = store.mainContext
        let (chat, provider) = try makeChat(context)
        let capture = OSAllocatedUnfairLock(initialState: [LLMChatRequest]())
        let engine = ChatEngine(stream: { request in
            capture.withLock { $0.append(request) }
            return AsyncThrowingStream { stream in
                stream.yield(.contentDelta("先去看看。\n\n晚点带一把小铲子。"))
                stream.yield(.done)
                stream.finish()
            }
        })
        XCTAssertEqual(engine.sendUserMessage(text: "春天了，聊聊花园。", attachments: [], in: chat, providers: [provider], context: context), .sent)
        await waitForIdle(engine, id: chat.id)
        let requests = capture.withLock { $0 }
        XCTAssertEqual(requests.map(\.modelID), ["one", "two"])
        for request in requests {
            let content = request.messages.map(\.content).joined()
            XCTAssertEqual(content.contains("雨后的苔藓像一封绿信"), request.modelID == "one")
            XCTAssertFalse(request.systemPrompt.contains("雨后的苔藓像一封绿信"))
        }
        let replies = chat.sortedMessages.filter { $0.role == .assistant }
        let marked = replies.filter { $0.modelID == "one" }
        XCTAssertEqual(marked.count, 2)
        XCTAssertTrue(marked.allSatisfy { $0.assistanceMetadata.isPersonaSimulation })
        XCTAssertTrue(replies.filter { $0.modelID == "two" }.allSatisfy { !$0.assistanceMetadata.isPersonaSimulation })
        let first = try XCTUnwrap(marked.first)
        XCTAssertTrue(try XCTUnwrap(first.assistanceMetadata.groupSpeakerDisplayTitle).contains("AI"))
        let samples = try XCTUnwrap(first.assistanceMetadata.personaExcerpts)
        XCTAssertEqual(samples, [PersonaExcerpt(source: "园艺随笔", excerpt: "雨后的苔藓像一封绿信。")])
        XCTAssertTrue(marked.allSatisfy { $0.assistanceMetadata.personaExcerpts == samples })
        XCTAssertTrue(replies.filter { $0.modelID == "two" }.allSatisfy { $0.assistanceMetadata.personaExcerpts == nil })
        let override = try XCTUnwrap(chat.groupMembers.last?.target)
        engine.regenerate(assistantMessage: first, overrideTarget: override, in: chat, providers: [provider], context: context)
        await waitForIdle(engine, id: chat.id)
        let last = try XCTUnwrap(capture.withLock { $0.last })
        XCTAssertNil(first.assistanceMetadata.personaExcerpts)
        XCTAssertEqual(first.assistanceMetadata.revisions.first?.personaExcerpts, samples)
        XCTAssertEqual(last.modelID, "two")
        XCTAssertTrue(last.systemPrompt.contains("AI 模拟"))
        XCTAssertFalse(last.messages.map(\.content).joined().contains("雨后的苔藓像一封绿信"))
        XCTAssertTrue(first.assistanceMetadata.isPersonaSimulation)
        engine.selectRevision(index: 0, for: first, context: context)
        XCTAssertTrue(first.assistanceMetadata.isPersonaSimulation)
        engine.selectRevision(index: 1, for: first, context: context)
        XCTAssertTrue(first.assistanceMetadata.isPersonaSimulation)
    }

    private func waitForIdle(_ engine: ChatEngine, id: UUID) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.isGenerating(in: id), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(15)) }
        XCTAssertFalse(engine.isGenerating(in: id))
    }

    func testRSSDiscoveryAndAtomRelativeLinksKeepOriginalAttribution() async throws {
        let home = "<html><head><link href='../feed.xml' type='application/atom+xml' rel='alternate'></head></html>"
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://blog.example.org/posts/"><entry>
        <id>tag:author,1</id><title>花开</title><link rel="alternate" href="one"/>
        <summary type="html">&lt;p&gt;摘录&lt;/p&gt;</summary><published>2026-04-02T10:30:00Z</published></entry></feed>
        """
        let fixture = FeedFixture([home, atom])
        let reader = PersonaFeedReader(fetch: { try await fixture.fetch($0) }, token: { "" })
        let feed = try PersonaFeedReader.source("https://blog.example.org/author/home", kind: .blog)
        let baseline = try await reader.read(feed)
        XCTAssertTrue(baseline.items.isEmpty)
        XCTAssertEqual(baseline.checkpoint.recentIDs.count, 1)
        XCTAssertEqual(baseline.checkpoint.feedURL?.absoluteString, "https://blog.example.org/feed.xml")
        let entry = try XCTUnwrap(SubscriptionFeedParser.parse(Data(atom.utf8), url: try XCTUnwrap(baseline.checkpoint.feedURL)).first)
        XCTAssertEqual(entry.url.absoluteString, "https://blog.example.org/posts/one")
        XCTAssertEqual(entry.excerpt, "摘录")
        XCTAssertNotNil(entry.published)
        let requests = await fixture.sent
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertThrowsError(try SubscriptionFeedParser.parse(Data("<html/>".utf8), url: entry.url))
    }

    func testGroupRefreshBaselinesRetriesAndRestartsWithoutDuplicatePostsOrBranchChanges() async throws {
        let store = try container(), context = store.mainContext
        let (chat, _) = try makeChat(context, feed: PersonaFeedReader.source(address, kind: .blog))
        let root = ChatMessage(role: .user, content: "讨论", sortIndex: 0)
        context.insert(root)
        root.conversation = chat
        ConversationTree.ensureExplicitParentLinks(in: chat)
        let other = ChatMessage(role: .assistant, content: "其他分支", sortIndex: 1)
        context.insert(other)
        other.conversation = chat
        other.parentMessageID = root.id
        chat.activeLeafMessageID = root.id
        try context.save()
        let fixture = FeedFixture([rss([1]), "OFFLINE", rss([3, 2, 1]), rss([3, 2, 1])])
        let reader = PersonaFeedReader(fetch: { try await fixture.fetch($0) })
        let service = PersonaFeedService(reader: reader)
        let previous = chat.updatedAt
        let baseline = await service.refresh(in: context, chatID: chat.id)
        XCTAssertEqual(baseline.baselines, 1)
        XCTAssertEqual(baseline.added, 0)
        XCTAssertEqual(chat.updatedAt, previous)
        let checkpoint = chat.groupMembers[0].persona?.feeds[0].checkpoint
        let skipped = await service.refresh(in: context, chatID: chat.id)
        XCTAssertEqual(skipped.checked, 0)
        let failure = await service.refresh(in: context, chatID: chat.id, force: true)
        XCTAssertEqual(failure.errors.count, 1)
        XCTAssertEqual(checkpoint, chat.groupMembers[0].persona?.feeds[0].checkpoint)
        let updated = await service.refresh(in: context, chatID: chat.id, force: true)
        XCTAssertEqual(updated.added, 2)
        let active = ConversationTree.activeMessages(in: chat)
        XCTAssertEqual(active.compactMap { $0.assistanceMetadata.sourceNotice?.title }, ["文章 2", "文章 3"])
        XCTAssertFalse(active.contains(where: { $0.id == other.id }))
        XCTAssertEqual(active.dropFirst().first?.parentMessageID, root.id)
        XCTAssertEqual(chat.activeLeafMessageID, active.last?.id)
        let prompt = GroupDiscussionCoordinator.buildPromptHistory(messages: active, for: chat.groupMembers[1], limit: 20)
        XCTAssertTrue(prompt.contains { $0.role == .user && $0.content.contains("摘录 3") && $0.content.contains("https://blog.example.org/posts/3") })
        let markdown = ConversationExporter.makeMarkdown(for: chat)
        XCTAssertTrue(markdown.contains("https://blog.example.org/posts/3"))
        XCTAssertTrue(markdown.contains("阿青"))
        let restarted = PersonaFeedService(reader: reader)
        let reopened = ModelContext(store)
        let again = await restarted.refresh(in: reopened, chatID: chat.id, force: true)
        XCTAssertEqual(again.checked, 1)
        XCTAssertEqual(again.added, 0)
        XCTAssertNil(chat.groupMembers[0].persona?.feeds[0].lastError)
    }

    func testDisableOrMuteWhileFetchingDiscardsResultAndCoalescesConcurrentChecks() async throws {
        let store = try container(), context = store.mainContext
        let (chat, _) = try makeChat(context, feed: PersonaFeedReader.source(address, kind: .blog))
        let fixture = FeedFixture([rss([1]), rss([2, 1])])
        let service = PersonaFeedService(reader: PersonaFeedReader(fetch: { try await fixture.fetch($0) }))
        _ = await service.refresh(in: context)
        let stale = chat.groupMembers[0]
        await fixture.pause()
        let pending = Task { await service.refresh(in: context, force: true) }
        let deadline = ContinuousClock.now + .seconds(4)
        while await fixture.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        let overlap = await service.refresh(in: context, force: true)
        XCTAssertEqual(overlap.deferred, 1)
        chat.groupMembers[0].isMuted = true
        try context.save()
        await fixture.resume()
        let dropped = await pending.value
        XCTAssertEqual(dropped.added, 0)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.groupMembers[0].persona?.feeds[0].checkpoint, stale.persona?.feeds[0].checkpoint)
        chat.groupMembers[0].isMuted = false
        chat.groupMembers[0].persona?.feeds[0].enabled = false
        let disabled = await service.refresh(in: context, force: true)
        XCTAssertEqual(disabled.checked, 0)
        let count = await fixture.count
        XCTAssertEqual(count, 2)
    }

    func testXUsesReadOnlyAPIAndRemembersPagesAcrossRefreshes() async throws {
        let fixture = FeedFixture([
            #"{"data":{"id":"42"}}"#,
            #"{"data":[{"id":"10","text":"旧帖"}],"meta":{"newest_id":"10","result_count":1}}"#,
            #"{"data":[{"id":"13","text":"新帖"}],"meta":{"newest_id":"13","result_count":1,"next_token":"page2"}}"#,
            #"{"data":[{"id":"12","text":"另一篇"}],"meta":{"newest_id":"12","result_count":1}}"#
        ])
        let reader = PersonaFeedReader(fetch: { try await fixture.fetch($0) }, token: { "fixture-token" })
        var feed = try PersonaFeedReader.source("https://twitter.com/Gardener", kind: .x)
        XCTAssertEqual(feed.address, "gardener")
        let first = try await reader.read(feed)
        XCTAssertTrue(first.items.isEmpty)
        feed.checkpoint = first.checkpoint
        let next = try await reader.read(feed)
        XCTAssertTrue(next.items.isEmpty)
        XCTAssertEqual(next.checkpoint.sinceID, "10")
        feed.checkpoint = next.checkpoint
        let last = try await reader.read(feed)
        XCTAssertEqual(last.items.map(\.id), ["12", "13"])
        XCTAssertEqual(last.items.last?.url.absoluteString, "https://x.com/i/web/status/13")
        XCTAssertNil(last.checkpoint.nextPage)
        XCTAssertEqual(last.checkpoint.sinceID, "13")
        let sent = await fixture.sent
        XCTAssertEqual(sent.map { $0.url?.path }, ["/2/users/by/username/gardener", "/2/users/42/tweets", "/2/users/42/tweets", "/2/users/42/tweets"])
        XCTAssertTrue(sent.allSatisfy { $0.url?.host == "api.x.com" && $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" })
        XCTAssertTrue(try XCTUnwrap(sent.last?.url?.query).contains("pagination_token=page2"))
        XCTAssertTrue(try XCTUnwrap(sent.last?.url?.query).contains("since_id=10"))
        let tokenless = PersonaFeedReader(fetch: { try await fixture.fetch($0) }, token: { "" })
        do { _ = try await tokenless.read(feed); XCTFail("A missing credential should stop before network access") }
        catch PersonaError.missingToken { }
        XCTAssertThrowsError(try PersonaFeedReader.source("https://example.org/gardener", kind: .x))
        XCTAssertThrowsError(try PersonaFeedReader.source("http://blog.example.org", kind: .blog))
    }

    func testXPublishesTheWholeBatchInOrderAfterInterruptionAndRelaunch() async throws {
        let db = try container()
        var feed = try PersonaFeedReader.source("@gardener", kind: .x)
        feed.checkpoint = .init(userID: "42", sinceID: "100")
        let (chat, _) = try makeChat(db.mainContext, feed: feed)
        let fixture = FeedFixture([
            #"{"data":[{"id":"104","text":"four"},{"id":"103","text":"three"}],"meta":{"newest_id":"104","result_count":2,"next_token":"older"}}"#,
            "OFFLINE",
            #"{"data":[{"id":"103","text":"three"},{"id":"102","text":"two"},{"id":"101","text":"one"}],"meta":{"newest_id":"103","result_count":3}}"#,
            #"{"meta":{"result_count":0}}"#
        ])
        let reader = PersonaFeedReader(fetch: { try await fixture.fetch($0) }, token: { "fixture" })
        let service = PersonaFeedService(reader: reader)
        let first = await service.refresh(in: db.mainContext, chatID: chat.id, force: true)
        XCTAssertEqual(first.added, 0)
        let offline = await service.refresh(in: db.mainContext, chatID: chat.id, force: true)
        XCTAssertFalse(offline.errors.isEmpty)
        XCTAssertEqual(chat.groupMembers.first?.persona?.feeds.first?.checkpoint?.sinceID, "100")
        let fresh = ModelContext(db), restarted = PersonaFeedService(reader: reader)
        let published = await restarted.refresh(in: fresh, chatID: chat.id, force: true)
        XCTAssertEqual(published.added, 4)
        let reopened = try XCTUnwrap(fresh.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(reopened.sortedMessages.compactMap { $0.assistanceMetadata.sourceNotice?.url.lastPathComponent }, ["101", "102", "103", "104"])
        XCTAssertEqual(reopened.groupMembers.first?.persona?.feeds.first?.checkpoint?.sinceID, "104")
        let again = await restarted.refresh(in: fresh, chatID: chat.id, force: true)
        XCTAssertEqual(again.added, 0)
    }

    func testEmptyXBaselineAndExpiredPageCursorDoNotSkipPosts() async throws {
        let fixture = FeedFixture([
            #"{"data":{"id":"42"}}"#, #"{"meta":{"result_count":0}}"#,
            #"{"data":[{"id":"21","text":"first"}],"meta":{"newest_id":"21","result_count":1,"next_token":"expired"}}"#,
            "EXPIRED", #"{"data":[{"id":"23","text":"new"},{"id":"21","text":"first"}],"meta":{"newest_id":"23","result_count":2}}"#
        ])
        let reader = PersonaFeedReader(fetch: { try await fixture.fetch($0) }, token: { "fixture" })
        var feed = try PersonaFeedReader.source("@gardener", kind: .x)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let baseline = try await reader.read(feed, now: start)
        XCTAssertTrue(baseline.items.isEmpty)
        XCTAssertNil(baseline.checkpoint.sinceID)
        feed.checkpoint = baseline.checkpoint
        let first = try await reader.read(feed, now: start.addingTimeInterval(60))
        XCTAssertTrue(first.items.isEmpty)
        feed.checkpoint = first.checkpoint
        let retried = try await reader.read(feed, now: start.addingTimeInterval(120))
        XCTAssertEqual(retried.checkpoint.sinceID, "23")
        XCTAssertNil(retried.checkpoint.nextPage)
        XCTAssertEqual(retried.items.map(\.id), ["21", "23"])
        let sent = await fixture.sent
        XCTAssertTrue(try XCTUnwrap(sent.last?.url?.query).contains("start_time="))
        XCTAssertFalse(try XCTUnwrap(sent.last?.url?.query).contains("pagination_token"))
    }

    func testTwoMembersSharingAnArticlePublishOnlyOneNoticePerGroup() async throws {
        let store = try container(), context = store.mainContext
        let feed = try PersonaFeedReader.source(address, kind: .blog)
        let (firstChat, _) = try makeChat(context, feed: feed)
        firstChat.groupMembers[1].persona = GroupPersona(feeds: [try PersonaFeedReader.source(address, kind: .blog)])
        let (secondChat, _) = try makeChat(context, feed: feed)
        try context.save()
        let fixture = FeedFixture([rss([1]), rss([1]), rss([1]), rss([2, 1]), rss([2, 1]), rss([2, 1])])
        let service = PersonaFeedService(reader: PersonaFeedReader(fetch: { try await fixture.fetch($0) }))
        let baseline = await service.refresh(in: context)
        XCTAssertEqual(baseline.baselines, 3)
        let updated = await service.refresh(in: context, force: true)
        XCTAssertEqual(updated.added, 2)
        XCTAssertEqual(firstChat.messages.count, 1)
        XCTAssertEqual(secondChat.messages.count, 1)
        XCTAssertNotEqual(firstChat.messages[0].id, secondChat.messages[0].id)
        XCTAssertEqual(firstChat.messages[0].assistanceMetadata.sourceNotice?.url, secondChat.messages[0].assistanceMetadata.sourceNotice?.url)
    }

    func testBackupRetainsMaterialsAndNoticesAndRequiresOptInOnAnotherDevice() async throws {
        let store = try container(), context = store.mainContext
        let (chat, _) = try makeChat(context, feed: PersonaFeedReader.source(address, kind: .blog))
        let fixture = FeedFixture([rss([1]), rss([2, 1])])
        let service = PersonaFeedService(reader: PersonaFeedReader(fetch: { try await fixture.fetch($0) }))
        let draft = chat.groupMembers[0]
        _ = await service.refresh(in: context)
        _ = await service.refresh(in: context, force: true)
        let current = chat.groupMembers[0]
        let combined = draft.preservingFeedProgress(from: current)
        XCTAssertEqual(combined.persona?.feeds[0].checkpoint, current.persona?.feeds[0].checkpoint)
        var archive = try BackupService.makeArchive(context: context)
        let exported = try XCTUnwrap(archive.conversations.first?.assistanceSettings?.groupMembers.first?.persona)
        XCTAssertEqual(exported.materials, current.persona?.materials)
        XCTAssertFalse(exported.feeds[0].enabled)
        XCTAssertNil(exported.feeds[0].checkpoint)
        archive.conversations[0].assistanceSettings = chat.assistanceSettings
        archive.conversations[0].updatedAt = chat.updatedAt.addingTimeInterval(60)
        let data = try BackupService.encode(archive)
        let decoded = try BackupService.decode(data)
        let second = try container()
        _ = try BackupService.apply(decoded, to: second.mainContext)
        let restored = try XCTUnwrap(second.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(restored.groupMembers[0].persona?.materials, current.persona?.materials)
        XCTAssertFalse(try XCTUnwrap(restored.groupMembers[0].persona?.feeds.first).enabled)
        XCTAssertNil(restored.groupMembers[0].persona?.feeds[0].checkpoint)
        XCTAssertEqual(restored.messages.first?.assistanceMetadata.sourceNotice?.title, "文章 2")
        _ = try BackupService.apply(decoded, to: context)
        XCTAssertEqual(chat.groupMembers[0].persona?.feeds.first, current.persona?.feeds.first)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        legacy.removeValue(forKey: "persona")
        let old = try JSONDecoder().decode(GroupMember.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.persona)
    }

    func testBackgroundIdentifierMatchesInstalledAppConfiguration() {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        XCTAssertTrue(permitted?.contains(PersonaRefreshDelegate.identifier) == true)
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("fetch") == true)
    }
}
