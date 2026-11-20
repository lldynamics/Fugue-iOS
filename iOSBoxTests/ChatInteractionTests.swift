import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ChatInteractionTests: XCTestCase {
    private func database() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func arena(in context: ModelContext) throws -> (Conversation, ChatMessage, ChatMessage) {
        let group = UUID()
        let chat = Conversation(title: "Comparisons", isArenaMode: true)
        chat.assistanceSettings.blindArenaMode = true
        context.insert(chat)
        let replies = ["A", "B"].enumerated().map { index, name in
            let msg = ChatMessage(role: .assistant, content: "Answer " + name, comparisonGroupID: group,
                                  isSelectedInGroup: index == 0, sortIndex: index)
            msg.modelID = name
            msg.modelDisplayName = "Model " + name
            msg.providerName = "Provider"
            msg.conversation = chat
            context.insert(msg)
            return msg
        }
        try context.save()
        return (chat, replies[0], replies[1])
    }

    func testBlindVoteAndFollowUpAreIndependentBeforeAndAfterReveal() throws {
        let db = try database(), context = db.mainContext
        let (chat, a, b) = try arena(in: context)
        let engine = ChatEngine.shared
        try engine.selectContextReply(b, in: chat, context: context)
        XCTAssertFalse(b.assistanceMetadata.blindArenaRevealed)
        XCTAssertTrue(ArenaBallot.standings(in: [chat]).isEmpty)

        try engine.castBlindVote(for: a, in: chat, context: context)
        XCTAssertTrue(b.isSelectedInGroup)
        XCTAssertFalse(a.isSelectedInGroup)
        XCTAssertTrue(chat.messages.allSatisfy { $0.assistanceMetadata.blindArenaRevealed })
        try engine.selectContextReply(a, in: chat, context: context)
        try engine.selectContextReply(b, in: chat, context: context)
        try engine.castBlindVote(for: b, in: chat, context: context)
        XCTAssertEqual(engine.buildPromptHistory(messages: chat.sortedMessages, limit: 0).map(\.content), ["Answer B"])

        a.modelID = "replacement"
        a.modelDisplayName = "Regenerated Answer"
        try context.save()
        let reopened = try ModelContext(db).fetch(FetchDescriptor<Conversation>())
        let rows = ArenaBallot.standings(in: reopened)
        XCTAssertEqual(rows.map(\.id.model), ["A", "B"])
        XCTAssertEqual(rows.map(\.wins), [1, 0])
        XCTAssertEqual(rows.map(\.rounds), [1, 1])
        XCTAssertEqual(rows.first?.modelName, "Model A")
    }

    func testUnfinishedAndLegacyRevealedRoundsDoNotCreateVotes() throws {
        let db = try database(), context = db.mainContext
        let (chat, a, b) = try arena(in: context)
        b.errorMessage = "Interrupted"
        try ChatEngine.shared.castBlindVote(for: a, in: chat, context: context)
        XCTAssertFalse(a.assistanceMetadata.blindArenaRevealed)
        b.errorMessage = nil
        b.assistanceMetadata = try JSONDecoder().decode(AssistanceMetadata.self, from: Data(#"{"blindArenaRevealed":true}"#.utf8))
        try ChatEngine.shared.selectContextReply(b, in: chat, context: context)
        try ChatEngine.shared.castBlindVote(for: a, in: chat, context: context)
        XCTAssertTrue(b.isSelectedInGroup)
        XCTAssertNil(a.assistanceMetadata.blindArenaBallot)
        XCTAssertTrue(ArenaBallot.standings(in: [chat]).isEmpty)
    }

    func testSameModelNameAtDifferentProvidersKeepsSeparateVoteTotals() throws {
        let db = try database(), context = db.mainContext
        let (chat, a, b) = try arena(in: context)
        a.providerID = UUID()
        b.providerID = UUID()
        b.modelID = a.modelID
        try ChatEngine.shared.castBlindVote(for: b, in: chat, context: context)
        let rows = ArenaBallot.standings(in: [chat])
        XCTAssertEqual(rows.map(\.wins), [1, 0])
        XCTAssertEqual(rows.map(\.rounds), [1, 1])
        XCTAssertEqual(rows.first?.id.provider, b.providerID?.uuidString)
    }

    func testBackupRestoresOneVoteAndKeepsExistingLocalVoteOnConflict() throws {
        let source = try database(), dest = try database(), other = try database()
        let (chat, a, b) = try arena(in: source.mainContext)
        let beforeVote = try BackupService.makeArchive(context: source.mainContext)
        try BackupService.apply(.full(beforeVote), to: dest.mainContext)
        try BackupService.apply(.full(beforeVote), to: other.mainContext)
        let otherChat = try XCTUnwrap(other.mainContext.fetch(FetchDescriptor<Conversation>()).first)
        let otherB = try XCTUnwrap(otherChat.messages.first { $0.id == b.id })
        try ChatEngine.shared.castBlindVote(for: otherB, in: otherChat, context: other.mainContext)
        try ChatEngine.shared.castBlindVote(for: a, in: chat, context: source.mainContext)
        let archive = try BackupService.decode(BackupService.encode(BackupService.makeArchive(context: source.mainContext)))
        for _ in 0..<2 {
            try BackupService.apply(archive, to: dest.mainContext)
            try BackupService.apply(archive, to: other.mainContext)
        }
        let restored = try dest.mainContext.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(ArenaBallot.standings(in: restored).map(\.id.model), ["A", "B"])
        XCTAssertEqual(ArenaBallot.standings(in: restored).map(\.rounds), [1, 1])
        XCTAssertEqual(ArenaBallot.standings(in: [otherChat]).map(\.id.model), ["B", "A"])
        XCTAssertEqual(ArenaBallot.standings(in: [otherChat]).map(\.wins), [1, 0])
    }

    func testSearchHighlightsOriginalSpellingAndFindsEveryMatchingMessage() throws {
        let db = try database(), context = db.mainContext
        let (chat, a, b) = try arena(in: context)
        chat.folderTag = "Café"
        a.modelDisplayName = "Private model name"
        a.assistanceMetadata.groupMemberName = "Private persona"
        a.content = String(repeating: "🍎", count: 60) + "Café" + String(repeating: "文", count: 100)
        b.content = "Older CAFE reply"
        let latest = ChatMessage(role: .user, content: "unrelated latest message")
        latest.conversation = chat
        context.insert(latest)
        let result = try XCTUnwrap(ConversationSearchResult(conversation: chat, query: "  cafe\n"))
        XCTAssertTrue(result.matchesDetails)
        XCTAssertEqual(Set(result.hits.map(\.id)), [a.id, b.id])
        let hit = try XCTUnwrap(result.hits.first { $0.id == a.id })
        XCTAssertEqual(hit.excerpt.match, "Café")
        XCTAssertEqual(hit.excerpt.before, "…" + String(repeating: "🍎", count: 24))
        XCTAssertEqual(hit.excerpt.after, String(repeating: "文", count: 64) + "…")
        XCTAssertFalse(hit.speaker.contains("Private"))
        XCTAssertEqual(hit.speaker, ArenaSynthesis.visibleSpeakerName(for: a, in: [a, b], blindArenaMode: true))
        XCTAssertNil(ConversationSearchResult(conversation: chat, query: "   "))
        XCTAssertNil(ConversationSearchResult(conversation: chat, query: "no match"))
    }

    func testSearchOpensHiddenArenaCandidateWithoutSwitchingTheWorkingBranch() throws {
        let db = try database(), context = db.mainContext
        let (chat, a, b) = try arena(in: context)
        let old = ChatMessage(role: .user, content: "Old question")
        let current = ChatMessage(role: .user, content: "Current question")
        for message in [old, current] {
            message.parentMessageID = ConversationTree.virtualRootID
            message.conversation = chat
            context.insert(message)
        }
        a.parentMessageID = old.id
        b.parentMessageID = old.id
        chat.activeLeafMessageID = current.id
        let hit = try XCTUnwrap(ConversationSearchResult(conversation: chat, query: "Answer B")?.hits.first)
        XCTAssertEqual(hit.id, b.id)
        XCTAssertTrue(hit.isOtherBranch)
        let path = ConversationTree.activeMessages(in: chat, endingAt: hit.id)
        XCTAssertEqual(path.map(\.id), [old.id, a.id, b.id])
        XCTAssertEqual(chat.activeLeafMessageID, current.id)
        let focus = MessageSearchFocus(messageID: hit.id, groupID: hit.groupID)
        XCTAssertEqual(focus.anchorID, "group-\(try XCTUnwrap(a.comparisonGroupID).uuidString)")
        XCTAssertEqual(focus.messageID, b.id)
        ConversationTree.switchBranch(to: b, in: chat)
        XCTAssertFalse(try XCTUnwrap(ConversationSearchResult(conversation: chat, query: "Answer B")?.hits.first).isOtherBranch)
    }

    func testSendOptionsSurviveFailureAndResetOnlyForAnAcceptedUnchangedDraft() throws {
        let chat = Conversation()
        chat.assistanceSettings.enableAgentTools = true
        chat.assistanceSettings.usePersonalMemory = true
        let provider = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "http://localhost",
                                      models: [ModelSpec(id: "one")])
        let target = provider.makeTarget(for: provider.models[0])
        var options = ComposerRequestOptions()
        options.omitMemory = true
        options.temporaryTarget = target
        options.setSearch(true, draft: String(repeating: "x", count: 450))
        XCTAssertEqual(options.searchQuery.count, 400)
        options.searchQuery = "edited query"
        options.setSearch(false, draft: "")
        XCTAssertNil(options.forSend(in: chat, quote: nil).searchQuery)
        options.setSearch(true, draft: "new contents")
        let captured = options.forSend(in: chat, quote: "quote")
        XCTAssertEqual(captured.searchQuery, "edited query")
        XCTAssertEqual(captured.quotedExcerpt, "quote")
        XCTAssertEqual(captured.overrideTarget, target)
        XCTAssertTrue(captured.omitMemory)
        let snapshot = options
        options.finishSend(.invalidSearch, draftUnchanged: true)
        XCTAssertEqual(options, snapshot)
        options.finishSend(.sent, draftUnchanged: false)
        XCTAssertEqual(options, snapshot)
        options.finishSend(.sent, draftUnchanged: true)
        XCTAssertEqual(options, ComposerRequestOptions())
        XCTAssertTrue(chat.assistanceSettings.enableAgentTools)
        XCTAssertTrue(chat.assistanceSettings.usePersonalMemory)
        chat.isArenaMode = true
        XCTAssertNil(snapshot.forSend(in: chat, quote: nil).overrideTarget)
        chat.isGroupMode = true
        XCTAssertNil(snapshot.forSend(in: chat, quote: nil).overrideTarget)
        chat.assistanceSettings.usePersonalMemory = false
        XCTAssertFalse(snapshot.forSend(in: chat, quote: nil).omitMemory)
    }
}
