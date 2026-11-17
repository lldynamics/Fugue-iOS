import XCTest
import SwiftData
@testable import iOSBox

@MainActor
final class BackupServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ProviderConfig.self, AssistantPreset.self, Conversation.self, ChatMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // Keep the container alive for the test's duration.
        containers.append(container)
        return ModelContext(container)
    }

    private var containers: [ModelContainer] = []

    private func seed(_ context: ModelContext) -> (ProviderConfig, Conversation) {
        let provider = ProviderConfig(
            name: "Gateway",
            protocolType: .anthropic,
            baseURL: "https://gw.example.com/v1",
            models: [ModelSpec(id: "claude-sonnet-4", supportsReasoning: true)],
            customHeaders: [
                CustomHeader(key: "HTTP-Referer", value: "https://x.app"),
                CustomHeader(key: "X-Token", value: "should-not-leak", isSecret: true)
            ]
        )
        context.insert(provider)
        context.insert(AssistantPreset(name: "翻译官", contextMessageLimit: 10, isBuiltIn: true))

        let conversation = Conversation(title: "带附件的对话", primaryTarget: provider.makeTarget(for: provider.models[0]))
        conversation.isPinned = true
        context.insert(conversation)
        let image = MessageAttachment(kind: .image, fileName: "a.jpg", mimeType: "image/jpeg", dataBase64: "QUJD", extractedText: nil, byteSize: 3)
        let user = ChatMessage(role: .user, content: "看图", attachments: [image], sortIndex: 1)
        let reply = ChatMessage(role: .assistant, content: "一只猫", reasoningContent: "观察", sortIndex: 2)
        reply.finishReason = LLMFinishReason.length.rawValue
        reply.completionTokens = 42
        for message in [user, reply] {
            message.conversation = conversation
            context.insert(message)
        }
        try? context.save()
        return (provider, conversation)
    }

    func testFullBackupRoundTripsIntoEmptyStore() throws {
        let source = try makeContext()
        let (provider, conversation) = seed(source)

        let data = try BackupService.encode(BackupService.makeArchive(context: source))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("should-not-leak"), "secret header values must not be exported")

        let target = try makeContext()
        let summary = try BackupService.apply(BackupService.decode(data), to: target)
        XCTAssertEqual(summary, ImportSummary(providers: 1, presets: 1, conversations: 1, messages: 2, skipped: 0))

        let restoredProvider = try XCTUnwrap(target.fetch(FetchDescriptor<ProviderConfig>()).first)
        XCTAssertEqual(restoredProvider.id, provider.id, "same ID lets the provider find its Keychain key again")
        XCTAssertEqual(restoredProvider.protocolType, .anthropic)
        XCTAssertEqual(restoredProvider.models.first?.supportsReasoning, true)
        XCTAssertEqual(restoredProvider.customHeaders.map(\.key), ["HTTP-Referer", "X-Token"])
        XCTAssertEqual(restoredProvider.customHeaders.last?.value, "")

        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(restored.id, conversation.id)
        XCTAssertTrue(restored.isPinned)
        XCTAssertEqual(restored.primaryTarget?.modelID, "claude-sonnet-4")
        let messages = restored.sortedMessages
        XCTAssertEqual(messages.map(\.content), ["看图", "一只猫"])
        XCTAssertEqual(messages.first?.attachments.first?.dataBase64, "QUJD")
        XCTAssertEqual(messages.last?.reasoningContent, "观察")
        XCTAssertEqual(messages.last?.finishReasonValue, .length)
        XCTAssertEqual(messages.last?.completionTokens, 42)

        XCTAssertEqual(try target.fetch(FetchDescriptor<AssistantPreset>()).first?.contextMessageLimit, 10)
    }

    func testImportingSameBackupTwiceSkipsExistingItems() throws {
        let context = try makeContext()
        _ = seed(context)
        let data = try BackupService.encode(BackupService.makeArchive(context: context))

        let summary = try BackupService.apply(BackupService.decode(data), to: context)
        XCTAssertEqual(summary.conversations, 0)
        XCTAssertEqual(summary.skipped, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
    }

    func testLegacyTextOnlyExportCanBeImported() throws {
        let legacy = """
        [{"title":"旧导出","systemPrompt":"你好","updatedAt":"2026-11-01T08:00:00Z",
          "messages":[
            {"role":"user","model":"","provider":"","reasoning":"","content":"问题","createdAt":"2026-11-01T07:59:00Z"},
            {"role":"assistant","model":"deepseek-chat","provider":"DeepSeek","reasoning":"想","content":"回答","createdAt":"2026-11-01T08:00:00Z"}
          ]}]
        """
        let context = try makeContext()
        let summary = try BackupService.apply(BackupService.decode(Data(legacy.utf8)), to: context)
        XCTAssertEqual(summary.conversations, 1)
        XCTAssertEqual(summary.messages, 2)

        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(conversation.title, "旧导出")
        XCTAssertEqual(conversation.sortedMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(conversation.sortedMessages.last?.providerName, "DeepSeek")
    }

    func testRejectsUnknownAndNewerFormats() {
        XCTAssertThrowsError(try BackupService.decode(Data(#"{"hello":1}"#.utf8))) { error in
            guard case BackupError.unrecognizedFormat = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try BackupService.decode(Data(#"{"formatVersion":99}"#.utf8))) { error in
            guard case BackupError.newerFormat(99) = error else { return XCTFail("\(error)") }
        }
    }
}

final class ProtocolSwitchBaseURLTests: XCTestCase {
    func testDefaultURLFollowsProtocolButCustomGatewayIsKept() {
        XCTAssertEqual(
            ProviderTemplate.baseURLAfterProtocolChange(currentBaseURL: "https://api.openai.com/v1/", from: .openAICompatible, to: .anthropic),
            APIProtocolType.anthropic.defaultBaseURL
        )
        XCTAssertEqual(
            ProviderTemplate.baseURLAfterProtocolChange(currentBaseURL: "https://api.deepseek.com/v1", from: .openAICompatible, to: .gemini),
            APIProtocolType.gemini.defaultBaseURL,
            "known template URLs of the old protocol are replaced too"
        )
        XCTAssertEqual(
            ProviderTemplate.baseURLAfterProtocolChange(currentBaseURL: "", from: .gemini, to: .openAICompatible),
            APIProtocolType.openAICompatible.defaultBaseURL
        )
        XCTAssertEqual(
            ProviderTemplate.baseURLAfterProtocolChange(currentBaseURL: "https://my-relay.example.org/v1", from: .openAICompatible, to: .anthropic),
            "https://my-relay.example.org/v1",
            "a custom relay often serves several protocols; keep it"
        )
    }
}
