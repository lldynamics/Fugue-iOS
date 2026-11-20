import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ReleaseReadinessTests: XCTestCase {
    private func container(at url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = url.map { ModelConfiguration(schema: schema, url: $0, cloudKitDatabase: .none) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private var archive: BackupArchive {
        BackupArchive(formatVersion: BackupArchive.currentFormatVersion, exportedAt: .now, appVersion: "test",
                      providers: [], presets: [], conversations: [], requests: [], memories: [])
    }

    func testRecoveryModeRejectsAllImportsBeforeDatabaseSidecarsOrCredentials() throws {
        let source = try container()
        source.mainContext.insert(Conversation(title: "Read me"))
        let card = StudyFlashcard(deckName: "Shelf", front: "Question", back: "Answer")
        var data = try BackupService.makeArchive(context: source.mainContext, flashcardStore: FlashcardStore(fileURL: nil))
        data.flashcards = [card]
        let recovered = try PersistenceController.makeRecoveryContainer(schema: Schema(versionedSchema: CurrentSchema.self))
        let context = recovered.mainContext
        let cards = FlashcardStore(fileURL: nil)
        XCTAssertThrowsError(try BackupService.apply(.full(data), to: context, flashcardStore: cards))
        XCTAssertThrowsError(try BackupService.apply(.legacy([]), to: context, flashcardStore: cards))
        let encrypted = EncryptedBackupService.FullPayload(archive: data, providerSecrets: [], tavilyAPIKey: "fixture")
        XCTAssertThrowsError(try EncryptedBackupService.applyDecryptedPayload(encrypted, to: context, flashcardStore: cards) { _, _ in
            XCTFail("Keychain wrote in recovery mode"); return false
        })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 0)
        XCTAssertTrue(cards.cards.isEmpty)
        XCTAssertNoThrow(try BackupService.makeArchive(context: context, flashcardStore: cards))
        let disk = try directory().appendingPathComponent("library.store")
        do {
            let target = try container(at: disk)
            XCTAssertEqual(try BackupService.apply(.full(data), to: target.mainContext, flashcardStore: cards).conversations, 1)
        }
        let reopened = try container(at: disk)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<Conversation>()).first?.title, "Read me")
        XCTAssertEqual(cards.cards.map(\.id), [card.id])
    }

    private func payload(for provider: ProviderConfig, header: CustomHeader) -> EncryptedBackupService.FullPayload {
        var data = archive
        data.providers = [ProviderBackup(id: provider.id, name: "Archived", protocolRaw: APIProtocolType.openAICompatible.rawValue,
                                         baseURL: "", iconSymbol: "", accentHex: "", isEnabled: true, sortOrder: 0,
                                         models: [], customHeaders: [header], notes: "")]
        let secrets = EncryptedBackupService.ProviderSecretBundle(providerID: provider.id, rawBaseURL: "https://example.test/team/v1",
                                                                 isEnabled: true, apiKey: "primary", extraAPIKeys: ["extra"],
                                                                 secretHeaders: [header.id.uuidString: "header"])
        return .init(archive: data, providerSecrets: [secrets], tavilyAPIKey: "")
    }

    func testRestoreBindsCredentialsToArchivedProviderProtocolEntireRouteAndHeader() throws {
        let db = try container()
        let header = CustomHeader(key: "X-Test", value: "", isSecret: true)
        let local = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "", customHeaders: [header])
        db.mainContext.insert(local)
        var data = payload(for: local, header: header)
        let original = data.providerSecrets[0].rawBaseURL
        for (url, format) in [("", APIProtocolType.openAICompatible), ("https://example.test/other/v1", .openAICompatible),
                              (original + "?tenant=two", .openAICompatible), (original + "#", .openAICompatible),
                              ("https://different.test/team/v1", .openAICompatible), (original, .anthropic)] {
            local.baseURL = url
            local.protocolType = format
            let result = try EncryptedBackupService.applyDecryptedPayload(data, to: db.mainContext) { _, _ in
                XCTFail("Conflicting connection received a credential"); return false
            }
            XCTAssertEqual(result.credentialConflicts, ["Local"])
            XCTAssertEqual(local.baseURL, url)
        }
        local.protocolType = .openAICompatible
        local.customHeaders = [CustomHeader(id: header.id, key: "X-Other", value: "", isSecret: true)]
        var accounts: [String] = []
        let headers = try EncryptedBackupService.applyDecryptedPayload(data, to: db.mainContext) { _, account in
            accounts.append(account); return true
        }
        XCTAssertEqual(headers.credentialConflicts, ["Local"])
        XCTAssertEqual(Set(accounts), [local.id.uuidString, KeychainService.extraKeysAccount(providerID: local.id)])
        data.archive.providers = []
        let orphan = try EncryptedBackupService.applyDecryptedPayload(data, to: db.mainContext) { _, _ in
            XCTFail("Orphan secret restored"); return false
        }
        XCTAssertTrue(orphan.hasWarnings)
    }

    func testCredentialWritesReportAllFailuresAndCanRetryWithoutOverwriting() throws {
        let db = try container()
        let local = ProviderConfig(name: "Account", protocolType: .openAICompatible, baseURL: "")
        let header = CustomHeader(key: "X-Test", value: "", isSecret: true)
        var data = payload(for: local, header: header)
        data.tavilyAPIKey = "search"
        data.personaXBearerToken = "feed"
        let first = try EncryptedBackupService.applyDecryptedPayload(data, to: db.mainContext) { _, _ in false }
        XCTAssertEqual(first.failedCredentialWrites, 5)
        XCTAssertTrue(first.hasWarnings)
        var saved: [String: String] = [local.id.uuidString: "local"]
        let retry = try EncryptedBackupService.applyDecryptedPayload(data, to: db.mainContext) { value, account in
            if saved[account] == nil { saved[account] = value }; return true
        }
        XCTAssertFalse(retry.hasWarnings)
        XCTAssertEqual(saved.count, 5)
        XCTAssertEqual(saved[local.id.uuidString], "local")
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<ProviderConfig>()), 1)
        let account = UUID().uuidString
        defer { KeychainService.shared.deleteSecret(account: account) }
        XCTAssertTrue(KeychainService.shared.restoreSecretIfMissing("first", account: account))
        XCTAssertTrue(KeychainService.shared.restoreSecretIfMissing("second", account: account))
        XCTAssertEqual(KeychainService.shared.loadSecret(account: account), "first")
    }

    func testExpandedReorderedAndRetiredDirectoryRequiresExplicitSelection() throws {
        let low = ModelSpec(id: "basic"), high = ModelSpec(id: "premium")
        let selected = ProviderModelCatalog.merging([low], with: [], choosing: low.id)
        let db = try container()
        let provider = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "http://localhost/v1", models: selected)
        db.mainContext.insert(provider)
        try ProviderModelCatalog.save([high, low], to: provider, in: db.mainContext)
        XCTAssertEqual(ProviderConfig.readyTargets(in: [provider]).map(\.modelID), ["basic"])
        var both = provider.models
        both[1].isEnabled = true
        provider.models = both
        try ProviderModelCatalog.save([high, low], to: provider, in: db.mainContext)
        XCTAssertEqual(provider.enabledModels.map(\.id), ["basic", "premium"])
        let draft = Conversation(primaryTarget: provider.makeTarget(for: low))
        try ProviderModelCatalog.save([high], to: provider, in: db.mainContext)
        let ready = ProviderConfig.readyTargets(in: [provider])
        draft.updateDraftModel(from: ready)
        draft.updateDraftModel(from: ready)
        XCTAssertNil(draft.primaryTarget)
        XCTAssertNil(ChatEngine().sendTargets(text: "Draft", attachments: [], in: draft, providers: [provider]))
        XCTAssertEqual(ready.map(\.modelID), ["premium"])
        try ProviderModelCatalog.save([high, low], to: provider, in: db.mainContext)
        XCTAssertEqual(ProviderConfig.readyTargets(in: [provider]).first?.modelID, "basic")
    }

    func testFlashcardWriteFailurePreservesCardsReviewAndBackupRetry() throws {
        let folder = try directory(), parent = folder.appendingPathComponent("store")
        let file = parent.appendingPathComponent("cards.json")
        let store = FlashcardStore(fileURL: file)
        let card = try XCTUnwrap(store.addCard(deckName: "A", front: "Q", back: "A"))
        let original = folder.appendingPathComponent("original")
        try FileManager.default.moveItem(at: parent, to: original)
        try Data("blocked".utf8).write(to: parent)
        let saved = store.cards
        XCTAssertThrowsError(try store.addCard(deckName: "B", front: "New", back: "A"))
        XCTAssertThrowsError(try store.updateCard(id: card.id, deckName: "Edit", front: "Edit", back: "Edit", hint: nil))
        XCTAssertThrowsError(try store.recordReview(cardID: card.id, rating: .easy))
        XCTAssertThrowsError(try store.deleteDeck("A"))
        XCTAssertEqual(store.cards, saved)
        var data = archive
        data.flashcards = [StudyFlashcard(deckName: "B", front: "New", back: "A")]
        let db = try container()
        let result = try BackupService.apply(.full(data), to: db.mainContext, flashcardStore: store)
        XCTAssertTrue(result.flashcardRestoreFailed)
        XCTAssertEqual(result.flashcards, 0)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.moveItem(at: original, to: parent)
        XCTAssertEqual(try BackupService.apply(.full(data), to: db.mainContext, flashcardStore: store).flashcards, 1)
        XCTAssertEqual(try BackupService.apply(.full(data), to: db.mainContext, flashcardStore: store).flashcards, 0)
        XCTAssertEqual(Set(FlashcardStore(fileURL: file).cards.map(\.id)), Set(store.cards.map(\.id)))
    }

    func testCorruptFlashcardsStayIntactUntilExplicitRecovery() throws {
        let folder = try directory(), file = folder.appendingPathComponent("cards.json")
        let original = Data("incomplete".utf8)
        try original.write(to: file)
        let store = FlashcardStore(fileURL: file)
        XCTAssertEqual(store.loadIssue, .damaged)
        XCTAssertThrowsError(try store.addCard(deckName: "B", front: "New", back: "A"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        try store.preserveDamagedLibrary()
        let copy = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        XCTAssertNotEqual(copy, file)
        XCTAssertEqual(try Data(contentsOf: copy), original)
        try store.addCard(deckName: "B", front: "New", back: "A")
        XCTAssertEqual(FlashcardStore(fileURL: file).cards.count, 1)
    }
}

extension ReleaseReadinessTests {
    func testSearchOfFiveThousandMessagesHonorsFiltersAndRefreshesEditedContent() async throws {
        let db = try container(), ctx = db.mainContext
        var selected: ChatMessage?
        for index in 0..<40 {
            let chat = Conversation(title: "对话 \(index)")
            chat.folderTag = index == 0 ? "阅读" : "其他"
            ctx.insert(chat)
            for offset in 0..<125 {
                let text = offset == 124 ? "最后一页的印记" : "日常阅读和讨论"
                let message = ChatMessage(role: .user, content: text)
                message.conversation = chat
                ctx.insert(message)
                if index == 0 && offset == 124 { selected = message; message.assistanceMetadata.isBookmarked = true }
            }
        }
        try ctx.save()
        let query = HistorySearchQuery(text: "印记", tag: "阅读", bookmarkedChatsOnly: true)
        let search = ConversationHistorySearch()
        let all = try await search.results(for: .init(text: "印记"), in: db)
        XCTAssertEqual(all.count, 40)
        let limited = try await search.results(for: query, in: db)
        XCTAssertEqual(limited.flatMap(\.hits).map(\.id), [try XCTUnwrap(selected).id])
        selected?.content = "新版本"
        try ctx.save()
        let refreshed = try await search.results(for: query, in: db)
        XCTAssertTrue(refreshed.isEmpty)
        let byTitle = try await search.results(for: .init(text: "对话 0"), in: db)
        XCTAssertEqual(byTitle.first?.matchesDetails, true)
    }

    func testSearchCancellationAndSupersededQueryNeverPublishStaleResults() async throws {
        let db = try container()
        db.mainContext.insert(Conversation(title: "Latest phrase"))
        try db.mainContext.save()
        let search = HistorySearchSession()
        let began = expectation(description: "First search scheduled")
        let old = Task {
            began.fulfill()
            await search.update(.init(text: "Old phrase"), in: db, delay: .milliseconds(80))
        }
        await fulfillment(of: [began], timeout: 2)
        await search.update(.init(text: "Latest"), in: db, delay: .zero)
        await old.value
        XCTAssertEqual(search.completed?.text, "Latest")
        XCTAssertEqual(search.results.count, 1)
        let cancel = Task { await search.update(.init(text: "cancelled"), in: db, delay: .seconds(1)) }
        cancel.cancel()
        await cancel.value
        XCTAssertEqual(search.completed?.text, "Latest")
        await search.update(.init(text: ""), in: db)
        XCTAssertNil(search.completed)
        XCTAssertTrue(search.results.isEmpty)
    }

    func testInChatSearchIncludesLiveReasoningAttachmentNamesAndBookmarksButExcludesDividers() async throws {
        let draft = ChatMessage(role: .assistant, content: "")
        draft.reasoningContent = "a private reasoning match"
        draft.assistanceMetadata.isBookmarked = true
        let file = ChatMessage(role: .user, content: "")
        file.attachments = [MessageAttachment(kind: .document, fileName: "研究笔记.txt", mimeType: "text/plain", byteSize: 12)]
        let divider = ChatMessage(role: .system, content: "private")
        divider.assistanceMetadata.isContextDivider = true
        let values = [draft, file, divider].map(MessageSearchText.init)
        let reasoning = try await MessageSearchText.matches(in: values, query: "private", bookmarksOnly: false)
        let filenames = try await MessageSearchText.matches(in: values, query: "笔记", bookmarksOnly: false)
        let marks = try await MessageSearchText.matches(in: values, query: "", bookmarksOnly: true)
        XCTAssertEqual(reasoning.map(\.id), [draft.id])
        XCTAssertEqual(filenames.map(\.id), [file.id])
        XCTAssertEqual(marks.map(\.id), [draft.id])
        XCTAssertNil(marks.first?.excerpt)
    }
}
