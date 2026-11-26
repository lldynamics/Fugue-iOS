import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class RecoveryAndConsentTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var defaults: UserDefaults!
    private let suite = "iosbox.regression." + UUID().uuidString

    override func setUp() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        container = nil
    }

    private func provider(_ name: String = "Local", address: String = "http://localhost:18080") -> ProviderConfig {
        let result = ProviderConfig(name: name, protocolType: .openAICompatible, baseURL: address,
                                    models: [ModelSpec(id: "text"), ModelSpec(id: "vision", supportsVision: true)])
        context.insert(result)
        return result
    }

    @discardableResult
    private func add(_ text: String, to chat: Conversation, parent: UUID? = nil, role: MessageRole = .user) -> ChatMessage {
        let message = ChatMessage(role: role, content: text, sortIndex: chat.messages.count)
        message.parentMessageID = parent
        context.insert(message)
        message.conversation = chat
        return message
    }

    func testBackupClearRestoreIncludesEveryBranchAttachmentAndOriginalLedgerLink() throws {
        let p = provider()
        let chat = Conversation(title: "Before", primaryTarget: p.makeTarget(for: p.models[0]))
        context.insert(chat)
        let root = add("Question", to: chat, parent: ConversationTree.virtualRootID)
        let image = MessageAttachment(kind: .image, fileName: "example.png", mimeType: "image/png", dataBase64: onePixelPNGFixture, byteSize: 70)
        root.attachments = [image]
        let a = add("A", to: chat, parent: root.id, role: .assistant)
        let b = add("B", to: chat, parent: root.id, role: .assistant)
        chat.activeLeafMessageID = b.id
        b.assistanceMetadata.isBookmarked = true
        let record = RequestRecord(target: chat.primaryTarget!, spec: p.models[0], conversationID: chat.id, messageID: b.id, kind: .answer)
        context.insert(record)
        b.latestRequest = record
        try context.save()
        let ids = [root.id, a.id, b.id]
        let kb = PresetKnowledgeStore(fileURL: nil)
        let backup = try BackupService.decode(BackupService.encode(BackupService.makeArchive(context: context, knowledgeStore: kb)))
        _ = try BackupService.clearMessages(in: chat, context: context)
        XCTAssertTrue(chat.messages.isEmpty)
        chat.title = "Renamed after clearing"
        let first = try BackupService.apply(backup, to: context, knowledgeStore: kb)
        XCTAssertEqual(first.restoredConversations, 1)
        XCTAssertEqual(first.messages, 3)
        XCTAssertTrue(first.description.contains(String(localized: "已恢复 \(1) 个原对话")))
        XCTAssertFalse(first.description.contains(String(localized: "新建对话 \(0) 个")))
        XCTAssertEqual(chat.title, "Renamed after clearing")
        XCTAssertEqual(Set(chat.messages.map(\.id)), Set(ids))
        let active = ConversationTree.activeMessages(in: chat)
        XCTAssertEqual(active.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(active.first?.attachments, [image])
        XCTAssertEqual(active.last?.assistanceMetadata.isBookmarked, true)
        XCTAssertEqual(active.last?.latestRequest?.id, record.id)
        XCTAssertEqual(try BackupService.apply(backup, to: context, knowledgeStore: kb).messages, 0)
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<ChatMessage>()), 3)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<RequestRecord>()), 1)
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<Conversation>()).first?.activeLeafMessageID, ids[2])
    }

    func testUndoAfterNewMessagesPreservesBothHistoriesAndLocalSelection() throws {
        let chat = Conversation()
        context.insert(chat)
        let oldQuestionID = add("Old", to: chat).id
        _ = add("Old answer", to: chat, role: .assistant)
        let undo = try BackupService.clearMessages(in: chat, context: context)
        let newQuestion = add("New", to: chat)
        let newAnswer = add("New answer", to: chat, role: .assistant)
        try BackupService.undoClear(undo, in: context)
        XCTAssertEqual(ConversationTree.activeMessages(in: chat).map(\.id), [newQuestion.id, newAnswer.id])
        let oldQuestion = try XCTUnwrap(chat.messages.first { $0.id == oldQuestionID })
        XCTAssertEqual(ConversationTree.branchSiblings(of: newQuestion, in: chat).count, 2)
        ConversationTree.switchBranch(to: oldQuestion, in: chat)
        XCTAssertEqual(ConversationTree.activeMessages(in: chat).map(\.content), ["Old", "Old answer"])
        try BackupService.undoClear(undo, in: context)
        XCTAssertEqual(chat.messages.count, 4)
    }

    func testPartialImportKeepsLocalEditsAndRejectsCrossChatCollisionAtomically() throws {
        let first = Conversation(), second = Conversation()
        context.insert(first); context.insert(second)
        let keep = add("original", to: first)
        let missing = add("restore", to: first, role: .assistant)
        let unrelated = add("other chat", to: second)
        try context.save()
        let kb = PresetKnowledgeStore(fileURL: nil)
        var archive = try BackupService.makeArchive(context: context, knowledgeStore: kb)
        archive.conversations = archive.conversations.filter { $0.id == first.id }
        keep.content = "edited locally"
        context.delete(missing)
        try context.save()
        var collision = archive
        collision.conversations[0].messages[0].id = unrelated.id
        XCTAssertThrowsError(try BackupService.apply(.full(collision), to: context, knowledgeStore: kb))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
        XCTAssertEqual(try BackupService.apply(.full(archive), to: context, knowledgeStore: kb).messages, 1)
        XCTAssertEqual(first.sortedMessages.map(\.content), ["edited locally", "restore"])
    }

    func testImportAfterSharedPrefixKeepsDivergingTurnsOnSeparateBranches() throws {
        let chat = Conversation()
        context.insert(chat)
        _ = add("First question", to: chat)
        _ = add("First answer", to: chat, role: .assistant)
        let oldTurn = add("Archived next turn", to: chat)
        let archivedID = oldTurn.id
        let archive = try BackupService.makeArchive(context: context)
        context.delete(oldTurn)
        try context.save()
        let local = add("Current next turn", to: chat)

        _ = try BackupService.apply(.full(archive), to: context)
        XCTAssertEqual(ConversationTree.activeMessages(in: chat).map(\.content), ["First question", "First answer", "Current next turn"])
        let siblings = ConversationTree.branchSiblings(of: local, in: chat)
        XCTAssertEqual(Set(siblings.map(\.id)), [archivedID, local.id])
        ConversationTree.switchBranch(to: try XCTUnwrap(siblings.first { $0.id == archivedID }), in: chat)
        XCTAssertEqual(ConversationTree.activeMessages(in: chat).last?.content, "Archived next turn")
    }

    func testFirstModelSetupVerifiesExactSelectionAndHandlesFailureOrConfigurationChanges() async throws {
        let remote = provider("No Credential", address: "https://example.invalid")
        let local = provider()
        XCTAssertFalse(remote.isReadyForChat)
        XCTAssertEqual(ProviderConfig.readyTargets(in: [remote, local]).map(\.modelID), ["text", "vision"])
        let verified = try await ModelSetup.verify(provider: local, modelID: "vision", context: context) { connection, target in
            XCTAssertEqual(connection.baseURL, local.baseURL)
            XCTAssertEqual(target.modelID, "vision")
            XCTAssertTrue(connection.apiKey.isEmpty)
        }
        XCTAssertEqual(verified.providerID, local.id)
        do {
            _ = try await ModelSetup.verify(provider: local, modelID: "text", context: context) { _, _ in throw URLError(.timedOut) }
            XCTFail("A failing probe must keep the setup screen open")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        do {
            _ = try await ModelSetup.verify(provider: local, modelID: "text", context: context) { _, _ in local.isEnabled = false }
            XCTFail("A disabled provider cannot be used after a pending probe")
        } catch { XCTAssertFalse(local.isReadyForChat) }
        XCTAssertFalse(AppCompliance.hasAcceptedAIDisclosure(defaults: defaults))
    }

    func testConsentCancellationAcceptanceAndRevocationPreserveDraftAndSendExactlyOnce() throws {
        let gate = AIConsentGate(defaults: defaults)
        let draft = ChatDraftState(id: UUID(), store: ChatDraftStore(directory: FileManager.default.temporaryDirectory))
        draft.load()
        draft.text = "Original draft"
        draft.quotedText = "Quote"
        draft.attachments = [MessageAttachment(kind: .document, fileName: "notes.txt", mimeType: "text/plain", extractedText: "Notes", byteSize: 5)]
        var sends = 0
        let send = { sends += 1 }
        let recipient = AppCompliance.recipient(provider: "Gateway", model: "Model", baseURL: "https://user:secret@local.example/path?key=hidden")
        XCTAssertEqual(recipient, "Gateway · Model (local.example)")
        gate.perform(recipients: [recipient, recipient], search: true, tools: true, send: send)
        let cancelled = try XCTUnwrap(gate.pending)
        XCTAssertEqual(cancelled.recipients, recipient)
        XCTAssertTrue(cancelled.includesWebSearch && cancelled.includesTools)
        gate.pending = nil
        gate.approve(cancelled.id)
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(draft.canSend)
        XCTAssertEqual(draft.text, "Original draft")
        XCTAssertEqual(draft.quotedText, "Quote")
        XCTAssertEqual(draft.attachments.first?.fileName, "notes.txt")
        XCTAssertThrowsError(try AppCompliance.requireConsent(defaults: defaults))
        gate.perform(recipients: [recipient], send: send)
        let approved = try XCTUnwrap(gate.pending)
        gate.approve(approved.id)
        gate.approve(approved.id)
        XCTAssertEqual(sends, 1)
        gate.perform(recipients: [recipient], send: send)
        XCTAssertEqual(sends, 2)
        let otherWindow = try XCTUnwrap(UserDefaults(suiteName: suite))
        AppCompliance.setAcceptedAIDisclosure(false, defaults: otherWindow)
        gate.perform(recipients: [recipient], send: send)
        XCTAssertNotNil(gate.pending)
        XCTAssertEqual(sends, 2)
    }

    func testUnauthorizedShortcutCreatesNoChatAndNoRequest() throws {
        let p = provider()
        let target = p.makeTarget(for: p.models[0])
        let engine = ChatEngine { _ in XCTFail("No request before consent"); return AsyncThrowingStream { $0.finish() } }
        XCTAssertThrowsError(try ShortcutService.start(text: "Keep private", modelID: target.id, context: context,
                                                     engine: engine, consentDefaults: defaults)) {
            XCTAssertTrue($0 is AppCompliance.ConsentRequired)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RequestRecord>()), 0)
    }

    func testChangedRecipientRequiresFreshApproval() throws {
        let gate = AIConsentGate(defaults: defaults)
        let p = provider()
        let shown = p.baseURL
        gate.perform(recipients: [shown], isCurrent: { p.baseURL == shown }) { XCTFail("Stale disclosure sent") }
        let request = try XCTUnwrap(gate.pending)
        p.baseURL = "https://new.example.invalid"
        gate.approve(request.id)
        XCTAssertTrue(gate.requestChanged)
        XCTAssertFalse(AppCompliance.hasAcceptedAIDisclosure(defaults: defaults))
    }

    func testTransportDeniesAllProtocolsBeforeConsentAndAfterRevocation() async throws {
        let p = provider()
        for proto in APIProtocolType.allCases {
            p.protocolType = proto
            let entry = SharedModelEntry(target: p.makeTarget(for: p.models[0]), spec: p.models[0], connectionID: p.id)
            let request = try SystemIntegration.connection(p).request(for: entry, text: "Private draft", systemPrompt: "")
            for previouslyGranted in [false, true] {
                if previouslyGranted { AppCompliance.setAcceptedAIDisclosure(true, defaults: defaults) }
                AppCompliance.setAcceptedAIDisclosure(false, defaults: defaults)
                do {
                    for try await _ in LLMClient.streamChat(request, consentDefaults: defaults) {}
                    XCTFail("Chat transport must require consent")
                } catch { XCTAssertTrue(error is AppCompliance.ConsentRequired) }
            }
        }
    }
}
