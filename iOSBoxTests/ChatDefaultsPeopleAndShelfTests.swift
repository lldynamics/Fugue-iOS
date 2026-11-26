import Foundation
import os
import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ChatDefaultsPeopleAndShelfTests: XCTestCase {
    private func database() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }

    private func provider() -> ProviderConfig {
        ProviderConfig(name: "Fixture", protocolType: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1",
                       models: [ModelSpec(id: "first"), ModelSpec(id: "second")])
    }

    func testHistoryPreviewLoadsLegacyDraftsAndReflectsEditsAttachmentsAndClears() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        let file = folder.appendingPathComponent(id.uuidString + ".json")
        try Data(#"{"text":"  \nFirst line\nSecond line"}"#.utf8).write(to: file)
        let store = ChatDraftStore(directory: folder)
        await store.loadPreview(for: id)
        XCTAssertEqual(store.previews[id], .text("First line"))

        let attachment = MessageAttachment(kind: .document, fileName: "notes.txt", mimeType: "text/plain", byteSize: 1)
        try store.save(ChatDraft(text: " ", attachments: [attachment], quotedText: "Quote"), for: id)
        let reopened = ChatDraftStore(directory: folder)
        await reopened.loadPreview(for: id)
        XCTAssertEqual(reopened.previews[id], .attachments(1))
        try store.save(ChatDraft(quotedText: "Quote\nLater"), for: id)
        XCTAssertEqual(store.previews[id], .quotation("Quote"))
        try store.save(ChatDraft(), for: id)
        await store.loadPreview(for: id)
        XCTAssertEqual(store.previews[id], .empty)
        let cold = ChatDraftStore(directory: folder)
        await cold.loadPreview(for: id)
        XCTAssertEqual(cold.previews[id], .empty)
    }

    func testCostOverviewDistinguishesEmptyUnpricedMissingUsageAndPricedZero() {
        let p = provider()
        let row = RequestRecord(target: p.makeTarget(for: p.models[0]), spec: nil, conversationID: UUID(), messageID: UUID(), kind: .answer)
        func summary() -> String {
            RequestLedger.costOverviewText(totals: RequestLedger.costs([row]), modelRecords: [row], requestCount: 1)
        }
        XCTAssertEqual(RequestLedger.costOverviewText(totals: [:], modelRecords: [], requestCount: 0), "0")
        XCTAssertEqual(RequestLedger.costOverviewText(totals: [:], modelRecords: [], requestCount: 1), String(localized: "搜索费用另计"))
        XCTAssertEqual(summary(), String(localized: "等待用量"))
        row.status = .blocked
        XCTAssertEqual(summary(), String(localized: "无计费记录"))
        row.status = .succeeded
        XCTAssertEqual(summary(), String(localized: "未定价"))
        row.inputPricePerMillion = 0
        row.outputPricePerMillion = 0
        row.currency = "USD"
        XCTAssertEqual(summary(), String(localized: "缺少用量"))
        row.promptTokens = 100
        row.completionTokens = 50
        XCTAssertEqual(summary(), RequestLedger.costText(0, currency: "USD"))
    }

    private func volume(in context: ModelContext) throws -> BookVolume {
        try BookLibrary.store(PreparedBook(BookManuscript(title: "Crossing", chapters: [
            BookChapter(title: "Arrival", text: "Lin waited at the pier."),
            BookChapter(title: "Harbour", text: "Lin found the copper bell beneath the blue flag.\nThe tide turned.")
        ])), in: context)
    }

    private func person(_ target: ResolvedModelTarget) -> GroupMember {
        var member = GroupMember(name: "Lin", rolePrompt: "Ask about birds.", target: target)
        member.persona = GroupPersona(materials: [.init(title: "Field notes", text: "The plum owl sings at sunset.")],
                                      feeds: [.init(kind: .blog, address: "https://example.org/notes.xml")])
        return member
    }

    private func recordingEngine(_ requests: OSAllocatedUnfairLock<[LLMChatRequest]>) -> ChatEngine {
        ChatEngine(stream: { request in
            requests.withLock { $0.append(request) }
            return AsyncThrowingStream { stream in
                stream.yield(.contentDelta("Thank you.")); stream.yield(.done); stream.finish()
            }
        })
    }

    private func finish(_ engine: ChatEngine, _ chat: Conversation) async {
        let limit = ContinuousClock.now + .seconds(8)
        while engine.isGenerating(in: chat.id), ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertFalse(engine.isGenerating(in: chat.id))
    }

    func testNewChatUsesExplicitIndependentDefaultsAndNeverSubstitutesForAMissingDefault() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults), p = provider()
        let first = AssistantPreset(name: "First"), chosen = AssistantPreset(name: "Chosen", systemPrompt: "Chosen only")
        let targets = p.models.map { p.makeTarget(for: $0) }
        let blank = preferences.newChat(providers: [p], presets: [first, chosen])
        XCTAssertNil(blank.primaryTarget)
        XCTAssertNil(blank.assistantID)
        preferences.defaultTargetID = targets[1].id
        preferences.defaultAssistantID = chosen.id
        let reopened = AppPreferences(defaults: defaults)
        let chat = reopened.newChat(providers: [p], presets: [first, chosen])
        XCTAssertEqual(chat.primaryTarget?.id, targets[1].id)
        XCTAssertEqual(chat.assistantID, chosen.id)
        XCTAssertEqual(chat.systemPrompt, "Chosen only")
        var models = p.models
        models[1].isEnabled = false
        p.models = models
        let missing = reopened.newChat(providers: [p], presets: [first])
        XCTAssertNil(missing.primaryTarget)
        XCTAssertNil(missing.assistantID)
        reopened.defaultTargetID = nil
        XCTAssertEqual(reopened.newChat(providers: [p], presets: []).primaryTarget?.id, targets[0].id)
        XCTAssertEqual(chat.primaryTarget?.id, targets[1].id)
    }

    func testSkippingKnowledgeKeepsBindingsAndRemovesBothRetrievalPathsIncludingOnRetry() async throws {
        let db = try database(), ctx = db.mainContext, p = provider(), book = try volume(in: ctx)
        ctx.insert(p)
        let chat = Conversation(title: "Research", primaryTarget: p.makeTarget(for: p.models[0]))
        ctx.insert(chat)
        chat.assistanceSettings.knowledgeVolumeIDs = [book.id]
        chat.assistanceSettings.enableAgentTools = true
        try ctx.save()
        var options = ComposerRequestOptions(omitKnowledge: true)
        let requests = OSAllocatedUnfairLock(initialState: [LLMChatRequest]()), engine = recordingEngine(requests)
        func send() -> SendOutcome {
            engine.sendUserMessage(text: "Where is the copper bell?", attachments: [], in: chat, providers: [p], context: ctx,
                                   options: options.forSend(in: chat, quote: nil))
        }
        options.finishSend(.busy, draftUnchanged: true)
        XCTAssertTrue(options.omitKnowledge)
        let result = send()
        XCTAssertEqual(result, .sent)
        options.finishSend(result, draftUnchanged: true)
        await finish(engine, chat)
        let first = try XCTUnwrap(chat.sortedMessages.last)
        XCTAssertTrue(first.assistanceMetadata.omittedKnowledge)
        XCTAssertNil(first.assistanceMetadata.knowledgeEvidence)
        engine.regenerate(assistantMessage: first, in: chat, providers: [p], context: ctx)
        await finish(engine, chat)
        XCTAssertFalse(options.omitKnowledge)
        XCTAssertEqual(send(), .sent)
        await finish(engine, chat)
        let recorded = requests.withLock { $0 }
        XCTAssertEqual(recorded.count, 3)
        for request in recorded.prefix(2) {
            XCTAssertFalse(request.messages.map(\.content).joined().contains("blue flag"))
            XCTAssertFalse(request.tools.contains { $0.name == "search_documents" })
        }
        let next = try XCTUnwrap(recorded.last)
        XCTAssertTrue(next.messages.map(\.content).joined().contains("blue flag"))
        XCTAssertTrue(next.tools.contains { $0.name == "search_documents" })
        XCTAssertEqual(chat.assistanceSettings.knowledgeVolumeIDs, [book.id])
        XCTAssertEqual(chat.sortedMessages.last?.assistanceMetadata.knowledgeEvidence?.passages.first?.volumeID, book.id)
    }

    func testProfileInvitationsTrackIndependentSubscriptionsAndTemplateKeepsBoundModel() throws {
        let db = try database(), ctx = db.mainContext, p = provider()
        ctx.insert(p)
        let target = p.makeTarget(for: p.models[1]), other = p.makeTarget(for: p.models[0])
        let profile = try PersonaLibrary.save(person(target), in: ctx)
        let member = try profile.member()
        let rooms = ["One", "Two"].map { title in
            let chat = Conversation(title: title)
            chat.assistanceSettings.isGroupMode = true
            ctx.insert(chat)
            return chat
        }
        for room in rooms { try PersonaLibrary.invite(member, to: room, in: ctx) }
        XCTAssertThrowsError(try PersonaLibrary.invite(member, to: rooms[0], in: ctx))
        XCTAssertNotEqual(rooms[0].groupMembers[0].id, rooms[1].groupMembers[0].id)
        var inRoom = rooms[0].groupMembers[0]
        inRoom.persona?.feeds[0].enabled = true
        inRoom.persona?.feeds[0].checkpoint = .init(recentIDs: ["already-seen"])
        rooms[0].groupMembers = [inRoom]
        let template = GroupRoomTemplate.custom(roomTitle: "Study", roomEmoji: "", sharedTopicPrompt: "",
                                               speakingMode: .roundRobin, speechStyle: .naturalShort, members: [inRoom])
        let chat = try PersonaLibrary.privateChat(with: profile, in: ctx)
        XCTAssertFalse(chat.isGroupMode)
        XCTAssertEqual(try PersonaLibrary.privateChat(with: profile, in: ctx).id, chat.id)
        var updated = member
        updated.name = "Lin Mei"
        let saved = try PersonaLibrary.save(updated, in: ctx)
        XCTAssertEqual(chat.title, "Lin Mei")
        XCTAssertEqual(rooms.map { $0.groupMembers[0].name }, ["Lin Mei", "Lin Mei"])
        XCTAssertEqual(rooms[0].groupMembers[0].persona?.feeds[0].checkpoint?.recentIDs, ["already-seen"])
        XCTAssertEqual(rooms[0].groupMembers[0].persona?.feeds[0].enabled, true)
        XCTAssertEqual(rooms[1].groupMembers[0].persona?.feeds[0].enabled, false)
        XCTAssertNil(rooms[1].groupMembers[0].persona?.feeds[0].checkpoint)
        let fresh = try XCTUnwrap(template.instantiate(using: [other, target], profiles: [try saved.member()]).first)
        XCTAssertEqual(fresh.name, "Lin Mei")
        XCTAssertEqual(fresh.target.id, target.id)
        XCTAssertEqual(fresh.persona?.feeds[0].enabled, false)
        XCTAssertNil(fresh.persona?.feeds[0].checkpoint)
        ctx.delete(chat)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<PersonaProfile>()), 1)
    }

    func testPrivatePersonaUsesAndRecordsExactExcerptsOnSendRetryAndContinuationOnlyForItsModel() async throws {
        let db = try database(), ctx = db.mainContext, p = provider()
        ctx.insert(p)
        let profile = try PersonaLibrary.save(person(p.makeTarget(for: p.models[0])), in: ctx)
        let chat = try PersonaLibrary.privateChat(with: profile, in: ctx)
        let requests = OSAllocatedUnfairLock(initialState: [LLMChatRequest]()), engine = recordingEngine(requests)
        // This fixture records foreground generation. Automatic memory extraction has its own transport tests.
        let memory = FriendMemoryStore(fileURL: nil)
        for subject in FriendMemorySubject.subjects(in: chat) {
            memory.setAutoExtractEnabled(false, for: subject)
        }
        engine.friendMemoryStore = memory
        func send(using options: GenerationOptions = GenerationOptions()) -> SendOutcome {
            engine.sendUserMessage(text: "What birds do you hear?", attachments: [], in: chat, providers: [p], context: ctx, options: options)
        }
        XCTAssertEqual(send(), .sent)
        await finish(engine, chat)
        let answer = try XCTUnwrap(chat.sortedMessages.last)
        let excerpts = try XCTUnwrap(answer.assistanceMetadata.personaExcerpts)
        let originalByline = try XCTUnwrap(answer.assistanceMetadata.privateSpeaker)
        XCTAssertEqual(originalByline.label, "Lin")
        let original = try profile.member()
        var groupReply = AssistanceMetadata()
        groupReply.groupMemberName = original.name
        groupReply.groupMemberTitle = original.title
        groupReply.groupMemberEmoji = original.avatarEmoji
        groupReply.isPersonaSimulation = true
        XCTAssertEqual(groupReply.speakerByline(privateProfile: nil, accentHex: original.accentHex), originalByline)
        var legacyPrivateReply = AssistanceMetadata()
        legacyPrivateReply.isPersonaSimulation = true
        XCTAssertEqual(legacyPrivateReply.speakerByline(privateProfile: original, accentHex: "#333333"), originalByline)
        let sample = try XCTUnwrap(excerpts.first)
        XCTAssertEqual(sample.source, "Field notes")
        XCTAssertEqual(sample.excerpt, "The plum owl sings at sunset.")
        engine.regenerate(assistantMessage: answer, in: chat, providers: [p], context: ctx)
        await finish(engine, chat)
        XCTAssertEqual(answer.assistanceMetadata.revisions.first?.personaExcerpts, excerpts)
        XCTAssertEqual(answer.assistanceMetadata.revisions.first?.privateSpeaker, originalByline)
        var revised = try profile.member()
        revised.name = "Renamed"
        revised.persona?.materials = [PersonaMaterial(title: "New notes", text: "The heron waits by the tide.")]
        _ = try PersonaLibrary.save(revised, in: ctx)
        engine.continueGeneration(assistantMessage: answer, in: chat, providers: [p], context: ctx)
        await finish(engine, chat)
        XCTAssertTrue(answer.assistanceMetadata.isPersonaSimulation)
        XCTAssertEqual(answer.assistanceMetadata.speakerByline(privateProfile: revised, accentHex: "#333333"), originalByline)
        let continued = try XCTUnwrap(answer.assistanceMetadata.personaExcerpts)
        XCTAssertEqual(continued.map(\.source), ["Field notes", "New notes"])
        XCTAssertEqual(send(using: GenerationOptions(overrideTarget: p.makeTarget(for: p.models[1]))), .sent)
        await finish(engine, chat)
        let recorded = requests.withLock { $0 }
        XCTAssertEqual(recorded.count, 4)
        for request in recorded.prefix(2) {
            XCTAssertTrue(request.messages.map(\.content).joined().contains(sample.excerpt))
            XCTAssertTrue(request.systemPrompt.contains("Ask about birds"))
        }
        let continuation = try XCTUnwrap(recorded.dropFirst(2).first)
        XCTAssertTrue(continuation.messages.map(\.content).joined().contains("The heron waits"))
        XCTAssertFalse(continuation.messages.map(\.content).joined().contains(sample.excerpt))
        let other = try XCTUnwrap(recorded.last)
        XCTAssertEqual(other.modelID, "second")
        XCTAssertFalse(other.messages.map(\.content).joined().contains("The heron waits"))
        XCTAssertFalse(other.messages.map(\.content).joined().contains(sample.excerpt))
        XCTAssertFalse(other.systemPrompt.contains("Ask about birds"))
        XCTAssertNil(chat.sortedMessages.last?.assistanceMetadata.personaExcerpts)
        XCTAssertNil(chat.sortedMessages.last?.assistanceMetadata.speakerByline(privateProfile: revised, accentHex: "#333333"))
    }

    func testShelfReusesOldCompanionSupportsSeparateDiscussionAndKeepsFriendScopes() throws {
        let db = try database(), ctx = db.mainContext, book = try volume(in: ctx)
        let old = Conversation(title: "Old notes", assistantEmoji: "📚")
        old.assistanceSettings.knowledgeVolumeIDs = [book.id]
        ctx.insert(old)
        let ordinary = Conversation(title: "Research")
        ordinary.assistanceSettings.knowledgeVolumeIDs = [book.id]
        ctx.insert(ordinary)
        let narrow = try BookFriend.make(book: book, name: "Lin", aliases: "", throughChapter: 0)
        let early = try BookLibrary.open(narrow, target: nil, in: ctx)
        let later = Conversation(title: "Later timeline")
        later.assistanceSettings.bookFriend = try BookFriend.make(book: book, name: "lin", aliases: "", throughChapter: 1)
        ctx.insert(later)
        XCTAssertEqual(try BookLibrary.companion(for: book, target: nil, in: ctx).id, old.id)
        let state = try XCTUnwrap(ShelfReadingState.find(book.id, in: ctx))
        state.chapter = 1
        state.paragraph = 1
        let fresh = try BookLibrary.companion(for: book, newDiscussion: true, target: nil, in: ctx)
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertTrue(fresh.messages.isEmpty)
        let second = ModelContext(db)
        let secondBook = try XCTUnwrap(BookLibrary.find(book.id, in: second))
        XCTAssertEqual(try BookLibrary.companion(for: secondBook, target: nil, in: second).id, fresh.id)
        let position = try XCTUnwrap(ShelfReadingState.find(book.id, in: second)?.position)
        XCTAssertEqual(position.chapter, 1)
        XCTAssertEqual(position.paragraph, 1)
        let allowed = try BookReadingPage.chapters(from: book.manuscript, through: early.activeBookFriend?.throughChapter)
        XCTAssertEqual(allowed.map(\.title), ["Arrival"])
        let page = try BookReadingPage.make(chapters: allowed, preferred: position.chapter, citation: nil)
        XCTAssertEqual(page.chapterIndex, 0)
        XCTAssertEqual(page.clampedParagraph(99), 0)
        let histories = BookFriendHistory.grouped([early, fresh, later, ordinary])
        XCTAssertEqual(histories.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(histories.first).chats.map(\.id)), Set([early.id, later.id]))
        XCTAssertNil(try BookLibrary.readingState(for: book, companionID: early.id, in: ctx))
        XCTAssertEqual(try BookLibrary.readingState(for: book, companionID: old.id, in: ctx)?.paragraph, 1)
        XCTAssertEqual(try BookLibrary.companion(for: book, target: nil, in: ctx).id, old.id)
        _ = try BookLibrary.readingState(for: book, companionID: fresh.id, in: ctx)
        ctx.delete(fresh); try ctx.save()
        XCTAssertEqual(try BookLibrary.companion(for: book, target: nil, in: ctx).id, old.id)
    }

    func testProfileAndShelfRestoreTwiceWithoutChangingLocalProgressOrPolling() throws {
        let from = try database(), to = try database(), ctx = from.mainContext
        let p = provider(), book = try volume(in: ctx)
        ctx.insert(p)
        let profile = try PersonaLibrary.save(person(p.makeTarget(for: p.models[1])), in: ctx)
        let privateChat = try PersonaLibrary.privateChat(with: profile, in: ctx)
        let chat = try BookLibrary.companion(for: book, target: nil, in: ctx)
        let state = try XCTUnwrap(ShelfReadingState.find(book.id, in: ctx))
        state.chapter = 1
        state.paragraph = 1
        try ctx.save()
        let bindings = PresetKnowledgeStore(fileURL: nil)
        let archive = try BackupService.makeArchive(context: ctx, knowledgeStore: bindings)
        let decoded = try BackupService.decode(BackupService.encode(archive))
        func restore() throws -> ImportSummary {
            try BackupService.apply(decoded, to: to.mainContext, knowledgeStore: bindings)
        }
        XCTAssertEqual(try restore().restoredProfiles, 1)
        let restored = try XCTUnwrap(to.mainContext.fetch(FetchDescriptor<PersonaProfile>()).first)
        XCTAssertEqual(restored.id, profile.id)
        XCTAssertEqual(try restored.member().persona?.feeds[0].enabled, false)
        let position = try XCTUnwrap(ShelfReadingState.find(book.id, in: to.mainContext))
        XCTAssertEqual(position.position, state.position)
        XCTAssertEqual(position.conversationID, chat.id)
        position.chapter = 0; position.paragraph = 0
        var edited = try restored.member()
        edited.name = "Local edition"
        edited.persona?.materials = []
        _ = try PersonaLibrary.save(edited, in: to.mainContext)
        let restoredChats = try to.mainContext.fetch(FetchDescriptor<Conversation>())
        to.mainContext.delete(try XCTUnwrap(restoredChats.first { $0.id == privateChat.id }))
        try to.mainContext.save()
        XCTAssertEqual(try restore().restoredProfiles, 0)
        let reopened = try PersonaLibrary.privateChat(with: restored, in: to.mainContext)
        XCTAssertEqual(reopened.id, privateChat.id)
        XCTAssertEqual(reopened.title, "Local edition")
        XCTAssertEqual(reopened.assistanceSettings.privatePersona?.persona?.materials.count, 0)
        XCTAssertEqual(position.chapter, 0)
        XCTAssertEqual(try to.mainContext.fetchCount(FetchDescriptor<ShelfReadingState>()), 1)
    }

    func testV7StoreMigratesWithIndependentProfilesAndShelfPositions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.store"), id = UUID()
        do {
            let old = Schema(versionedSchema: SchemaV7.self)
            let db = try ModelContainer(for: old, configurations: [ModelConfiguration(schema: old, url: file)])
            let chat = Conversation(title: "Preserved")
            chat.id = id
            db.mainContext.insert(chat)
            try db.mainContext.save()
        }
        let current = Schema(versionedSchema: CurrentSchema.self)
        let db = try PersistenceController.open(schema: current, configuration: ModelConfiguration(schema: current, url: file))
        XCTAssertEqual(try db.mainContext.fetch(FetchDescriptor<Conversation>()).first?.id, id)
        let book = try volume(in: db.mainContext), p = provider()
        _ = try PersonaLibrary.save(person(p.makeTarget(for: p.models[0])), in: db.mainContext)
        _ = try BookLibrary.companion(for: book, target: nil, in: db.mainContext)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<ShelfReadingState>()), 1)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<PersonaProfile>()), 1)
    }
}
