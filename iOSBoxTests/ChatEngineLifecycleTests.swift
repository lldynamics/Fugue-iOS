import XCTest
import SwiftData
@testable import iOSBox

@MainActor
final class ChatEngineLifecycleTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    /// A remote provider with no API key in the Keychain: the engine fails fast with a
    /// "missing key" error and never touches the network, which makes it ideal for
    /// exercising the generation lifecycle deterministically.
    private func makeConversationWithKeylessProvider() -> (Conversation, [ProviderConfig]) {
        let provider = ProviderConfig(
            name: "Remote",
            protocolType: .openAICompatible,
            baseURL: "https://api.example.com/v1",
            models: [ModelSpec(id: "test-model")]
        )
        context.insert(provider)
        let conversation = Conversation(primaryTarget: provider.makeTarget(for: provider.models[0]))
        context.insert(conversation)
        try? context.save()
        return (conversation, [provider])
    }

    // MARK: - Fix 4: send outcome (input must not be lost)

    func testSendWithoutAnyModelReportsNoAvailableModelAndInsertsNothing() {
        let conversation = Conversation()
        context.insert(conversation)

        let outcome = ChatEngine.shared.sendUserMessage(
            text: "你好", attachments: [], in: conversation, providers: [], context: context
        )

        XCTAssertEqual(outcome, .noAvailableModel)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertFalse(ChatEngine.shared.isGenerating(in: conversation.id))
    }

    func testSendWithBlankInputReportsEmptyInput() {
        let (conversation, providers) = makeConversationWithKeylessProvider()
        let outcome = ChatEngine.shared.sendUserMessage(
            text: "  \n ", attachments: [], in: conversation, providers: providers, context: context
        )
        XCTAssertEqual(outcome, .emptyInput)
        XCTAssertTrue(conversation.messages.isEmpty)
    }

    // MARK: - Fix 1: stop → resend race

    func testStoppedGenerationBlocksResendUntilUnwoundThenAllowsIt() async {
        let engine = ChatEngine.shared
        let (conversation, providers) = makeConversationWithKeylessProvider()

        XCTAssertEqual(
            engine.sendUserMessage(text: "第一条", attachments: [], in: conversation, providers: providers, context: context),
            .sent
        )
        XCTAssertTrue(engine.isGenerating(in: conversation.id))

        // Stopping must not immediately clear the state: the old task hasn't unwound yet.
        engine.stopGeneration(for: conversation.id)
        XCTAssertTrue(engine.isGenerating(in: conversation.id))
        XCTAssertEqual(
            engine.sendUserMessage(text: "抢跑", attachments: [], in: conversation, providers: providers, context: context),
            .busy
        )

        await engine.stopGenerationAndWait(for: conversation.id)
        XCTAssertFalse(engine.isGenerating(in: conversation.id))

        // A new generation now registers cleanly and stays registered until it finishes itself.
        XCTAssertEqual(
            engine.sendUserMessage(text: "第二条", attachments: [], in: conversation, providers: providers, context: context),
            .sent
        )
        XCTAssertTrue(engine.isGenerating(in: conversation.id))
        await engine.stopGenerationAndWait(for: conversation.id)
        XCTAssertFalse(engine.isGenerating(in: conversation.id))
        XCTAssertEqual(conversation.messages.filter { $0.role == .user }.count, 2)
    }

    // MARK: - Fix 2: deleting while generating

    func testDeletingConversationAfterAwaitedStopLeavesNoActiveGeneration() async throws {
        let engine = ChatEngine.shared
        let (conversation, providers) = makeConversationWithKeylessProvider()
        let conversationID = conversation.id

        engine.sendUserMessage(text: "删除测试", attachments: [], in: conversation, providers: providers, context: context)
        await engine.stopGenerationAndWait(for: conversationID)
        context.delete(conversation)
        try context.save()

        XCTAssertFalse(engine.isGenerating(in: conversationID))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
    }

    // MARK: - Fix 3: messages stuck in "streaming" after the app was killed

    func testRecoveryResetsMessagesLeftStreaming() throws {
        let stuckEmpty = ChatMessage(role: .assistant, isStreaming: true)
        let stuckPartial = ChatMessage(role: .assistant, content: "部分内容", isStreaming: true)
        let finished = ChatMessage(role: .assistant, content: "完整回答", isStreaming: false)
        [stuckEmpty, stuckPartial, finished].forEach(context.insert)
        try context.save()

        let repaired = InterruptedStreamRecovery.run(in: container)
        XCTAssertEqual(repaired, 2)

        let verifyContext = ModelContext(container)
        let all = try verifyContext.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertTrue(all.allSatisfy { !$0.isStreaming })

        let partial = try XCTUnwrap(all.first { $0.content == "部分内容" })
        XCTAssertEqual(partial.errorMessage, InterruptedStreamRecovery.interruptedNotice)
        let complete = try XCTUnwrap(all.first { $0.content == "完整回答" })
        XCTAssertNil(complete.errorMessage)
    }

    // MARK: - Fix 5: duplicate model IDs

    func testProviderModelsAreAlwaysUniqueByID() {
        let provider = ProviderConfig(
            name: "Dup",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            models: [ModelSpec(id: "a", displayName: "A1"), ModelSpec(id: "a", displayName: "A2"), ModelSpec(id: "b")]
        )
        XCTAssertEqual(provider.models.map(\.id), ["a", "b"])
        XCTAssertEqual(provider.models.first?.displayName, "A1")

        provider.models = provider.models + [ModelSpec(id: "b"), ModelSpec(id: "c")]
        XCTAssertEqual(provider.models.map(\.id), ["a", "b", "c"])

        // Previously this crashed with "Duplicate values for key".
        let byID = Dictionary(uniqueKeysWithValues: provider.models.map { ($0.id, $0) })
        XCTAssertEqual(byID.count, 3)
    }
}
