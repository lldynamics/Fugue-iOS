import XCTest
import SwiftData
@testable import iOSBox

@MainActor
final class BackupServiceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(
            for: schema,
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
        let image = MessageAttachment(kind: .image, fileName: "a.png", mimeType: "image/png", dataBase64: onePixelPNGFixture, byteSize: 70)
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
        conversation.assistanceSettings = AssistanceSettings(usePersonalMemory: true, automaticRouting: true,
                                                             codeTarget: conversation.primaryTarget, fallbackEnabled: true,
                                                             autoGenerateTitle: true)
        let srcCards = FlashcardStore(fileURL: nil)
        let dstCards = FlashcardStore(fileURL: nil)
        let srcKB = PresetKnowledgeStore(fileURL: nil)
        let dstKB = PresetKnowledgeStore(fileURL: nil)

        let data = try BackupService.encode(BackupService.makeArchive(context: source, flashcardStore: srcCards, knowledgeStore: srcKB))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("should-not-leak"), "secret header values must not be exported")

        let target = try makeContext()
        let summary = try BackupService.apply(BackupService.decode(data), to: target, flashcardStore: dstCards, knowledgeStore: dstKB)
        XCTAssertEqual(summary, ImportSummary(providers: 1, presets: 1, conversations: 1, messages: 2, skipped: 0))

        let restoredProvider = try XCTUnwrap(target.fetch(FetchDescriptor<ProviderConfig>()).first)
        XCTAssertEqual(restoredProvider.id, provider.id)
        XCTAssertFalse(restoredProvider.isEnabled)
        XCTAssertEqual(restoredProvider.protocolType, .anthropic)
        XCTAssertEqual(restoredProvider.models.first?.supportsReasoning, true)
        XCTAssertEqual(restoredProvider.customHeaders.map(\.key), ["HTTP-Referer", "X-Token"])
        XCTAssertEqual(restoredProvider.customHeaders.last?.value, "")

        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(restored.id, conversation.id)
        XCTAssertTrue(restored.isPinned)
        XCTAssertEqual(restored.primaryTarget?.modelID, "claude-sonnet-4")
        XCTAssertFalse(restored.assistanceSettings.usePersonalMemory)
        XCTAssertFalse(restored.assistanceSettings.automaticRouting)
        XCTAssertFalse(restored.assistanceSettings.fallbackEnabled)
        XCTAssertFalse(restored.assistanceSettings.autoGenerateTitle)
        XCTAssertEqual(restored.assistanceSettings.codeTarget, restored.primaryTarget)
        let messages = restored.sortedMessages
        XCTAssertEqual(messages.map(\.content), ["看图", "一只猫"])
        XCTAssertEqual(messages.first?.attachments.first?.dataBase64, onePixelPNGFixture)
        XCTAssertEqual(messages.last?.reasoningContent, "观察")
        XCTAssertEqual(messages.last?.finishReasonValue, .length)
        XCTAssertEqual(messages.last?.completionTokens, 42)

        XCTAssertEqual(try target.fetch(FetchDescriptor<AssistantPreset>()).first?.contextMessageLimit, 10)
    }

    func testRecreatedProviderKeepsReferencesWithoutInheritingKeychainCredentials() throws {
        let original = try makeContext()
        let (provider, _) = seed(original)
        let header = try XCTUnwrap(provider.customHeaders.first { $0.isSecret })
        let oldHeaderAccount = KeychainService.headerAccount(providerID: provider.id, headerID: header.id)
        let keys = KeychainService.shared
        defer { provider.deleteAllSecrets() }
        XCTAssertTrue(keys.saveAPIKey("original-fixture", for: provider.id))
        XCTAssertTrue(keys.saveExtraAPIKeys(["secondary-fixture"], for: provider.id))
        XCTAssertTrue(keys.saveSecret("header-fixture", account: oldHeaderAccount))

        let target = try makeContext()
        let cards = FlashcardStore(fileURL: nil)
        let knowledge = PresetKnowledgeStore(fileURL: nil)
        let archive = try BackupService.makeArchive(context: original, flashcardStore: cards, knowledgeStore: knowledge)
        try BackupService.apply(.full(archive), to: target, flashcardStore: cards, knowledgeStore: knowledge)
        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<ProviderConfig>()).first)
        defer { restored.deleteAllSecrets() }
        XCTAssertEqual(restored.id, provider.id)
        XCTAssertNotEqual(restored.credentialID, provider.credentialID)
        let request = ModelCatalogRequest.saved(for: restored)
        XCTAssertTrue(request.apiKey.isEmpty)
        XCTAssertTrue(request.extraKeys.isEmpty)
        XCTAssertEqual(request.headers.first { $0.id == header.id }?.value, "")
        XCTAssertFalse(restored.hasConfiguredChatAPI)

        let directory = ChatModelDirectory()
        directory.update(configured: [restored], in: target)
        XCTAssertTrue(directory.catalogs.isEmpty)

        let saved = restored.makeTarget(for: try XCTUnwrap(restored.models.first))
        let single = Conversation(title: "Restored draft", primaryTarget: saved)
        let arena = Conversation(title: "Restored Arena", isArenaMode: true, arenaTargets: [saved])
        single.updateDraftModel(from: [], preservingUnavailableProviders: [restored.id])
        arena.updateDraftModel(from: [], preservingUnavailableProviders: [restored.id])
        XCTAssertEqual(single.primaryTarget, saved)
        XCTAssertEqual(arena.arenaTargets, [saved])

        // Approving the provider and supplying its own credential is still supported.
        XCTAssertTrue(keys.saveAPIKey("restored-fixture", for: restored.credentialID))
        restored.isEnabled = true
        XCTAssertEqual(ProviderConfig.readyTargets(in: [restored]).map(\.providerID), [provider.id])
        XCTAssertEqual(ModelCatalogRequest.saved(for: restored).apiKey, "restored-fixture")
        XCTAssertEqual(provider.apiKey, "original-fixture")
        XCTAssertEqual(keys.loadSecret(account: oldHeaderAccount), "header-fixture")
    }

    func testProviderMigrationPreservesExistingCredentialAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.store")
        let id = UUID()
        do {
            let schema = Schema(versionedSchema: SchemaV8.self)
            let store = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
            let provider = SchemaV6.ProviderConfig(id: id, name: "Existing", protocolType: .openAICompatible,
                                                   baseURL: "https://gateway.example/v1", models: [ModelSpec(id: "saved")])
            store.mainContext.insert(provider)
            try store.mainContext.save()
        }
        let keys = KeychainService.shared
        defer { keys.deleteAPIKey(for: id) }
        XCTAssertTrue(keys.saveAPIKey("migration-fixture", for: id))

        let schema = Schema(versionedSchema: CurrentSchema.self)
        let migrated = try PersistenceController.open(schema: schema, configuration: ModelConfiguration(schema: schema, url: url))
        let provider = try XCTUnwrap(migrated.mainContext.fetch(FetchDescriptor<ProviderConfig>()).first)
        XCTAssertEqual(provider.id, id)
        XCTAssertEqual(provider.credentialID, id)
        XCTAssertEqual(provider.apiKey, "migration-fixture")
        XCTAssertEqual(provider.enabledModels.map(\.id), ["saved"])
    }

    func testImportingSameBackupTwiceSkipsExistingItems() throws {
        let context = try makeContext()
        _ = seed(context)
        let cards = FlashcardStore(fileURL: nil)
        let kb = PresetKnowledgeStore(fileURL: nil)
        let data = try BackupService.encode(BackupService.makeArchive(context: context, flashcardStore: cards, knowledgeStore: kb))

        let summary = try BackupService.apply(BackupService.decode(data), to: context, flashcardStore: cards, knowledgeStore: kb)
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
