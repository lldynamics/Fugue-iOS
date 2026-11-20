import XCTest
@testable import iOSBox

@MainActor
final class ProviderModelCatalogTests: XCTestCase {
    private let request = ModelCatalogRequest(protocolType: .openAICompatible, baseURL: "https://catalog.example/v1", apiKey: "fixture")

    func testNewProviderCanChooseAnyDiscoveredOrManualID() {
        let live = (1...30).map { ModelSpec(id: "model-\($0)") }
        let chosen = ProviderModelCatalog.merging(live, with: [], choosing: "model-29")
        XCTAssertEqual(chosen.first?.id, "model-29")
        XCTAssertTrue(chosen.first!.isEnabled)
        XCTAssertEqual(chosen.filter(\.isSelectable).map(\.id), ["model-29"])
        XCTAssertEqual(chosen.count, 30)
        XCTAssertFalse(chosen.first { $0.id == "model-28" }!.isEnabled)
        XCTAssertEqual(ProviderModelCatalog.merging(live, with: [], choosing: "private-id").first?.id, "private-id")
    }

    func testRefreshRetainsLocalEditsAndRetiredIDsAndListsNewChoicesDisabled() {
        var customized = ModelSpec(id: "keep", displayName: "Custom", isEnabled: false, supportsVision: true)
        customized.isStarred = true
        customized.inputPricePerMillion = 2
        let saved = [ModelSpec(id: "retired"), customized]
        let live = [ModelSpec(id: "keep")] + (1...25).map { ModelSpec(id: "future-\($0)") }
        let result = ProviderModelCatalog.merging(live + [live[0]], with: saved)
        var listed = customized
        listed.catalogStatus = .listed
        var retired = saved[0]
        retired.catalogStatus = .unlisted
        XCTAssertEqual(result.first { $0.id == listed.id }, listed)
        XCTAssertEqual(result.first { $0.id == retired.id }, retired)
        XCTAssertFalse(retired.isSelectable)
        XCTAssertEqual(result.count, 27)
        XCTAssertTrue(result.allSatisfy { !$0.isSelectable })
        XCTAssertFalse(result[result.count - 2].isEnabled)
        XCTAssertEqual(ProviderModelCatalog.merging(live, with: result), result)
    }

    func testFailedRefreshPreservesLastGoodCatalogAndResetClearsOtherAccount() async {
        let catalog = ProviderModelCatalog()
        let working = [ModelSpec(id: "my-account-only")]
        await catalog.refresh(request: request, load: { _ in working })?.value
        await catalog.refresh(request: request, load: { _ in throw URLError(.notConnectedToInternet) })?.value
        XCTAssertNotNil(catalog.error)
        XCTAssertEqual(catalog.models, working)
        let previous = catalog.refresh(request: request, load: { _ in working }, onSuccess: { _ in XCTFail("Stale result committed") })
        catalog.reset()
        let other = [ModelSpec(id: "other-account")]
        await catalog.refresh(request: request, load: { _ in other })?.value
        await previous?.value
        XCTAssertEqual(catalog.models, other)
        XCTAssertNil(catalog.error)
    }

    func testPristineTemplateGetsNewSuggestionsOnceAndEditedProviderKeepsItsSettings() throws {
        let tpl = try XCTUnwrap(ProviderTemplate.catalog.first { $0.id == "deepseek" })
        let old = [ModelSpec(id: "deepseek-chat", displayName: "DeepSeek V3", supportsVision: false, supportsReasoning: false),
                   ModelSpec(id: "deepseek-reasoner", displayName: "DeepSeek R1", supportsVision: false, supportsReasoning: true)]
        let provider = ProviderConfig(name: tpl.name, protocolType: tpl.protocolType, baseURL: tpl.baseURL, iconSymbol: tpl.iconSymbol, models: old)
        XCTAssertTrue(KeychainService.shared.saveAPIKey("fixture", for: provider.id))
        defer { provider.deleteAllSecrets() }
        for previous in [old, tpl.suggestedModels + old] {
            provider.models = previous
            DataSeeder.updateStarterModels(in: provider)
            XCTAssertEqual(provider.enabledModels, tpl.suggestedModels)
            XCTAssertEqual(provider.models.suffix(2).map(\.id), old.map(\.id))
            XCTAssertTrue(provider.models.suffix(2).allSatisfy { $0.catalogStatus == .unlisted })
            let liveAlias = ModelSpec(id: old[0].id, displayName: "Current API alias")
            XCTAssertEqual(ProviderModelCatalog.merging([liveAlias], with: provider.models).first { $0.id == liveAlias.id }?.displayName, liveAlias.displayName)
            let migrated = provider.models
            DataSeeder.updateStarterModels(in: provider)
            XCTAssertEqual(provider.models, migrated)
        }
        var edited = old
        edited[0].isEnabled = false
        provider.models = edited
        DataSeeder.updateStarterModels(in: provider)
        XCTAssertEqual(provider.models, edited)
        provider.models = old
        provider.baseURL = "https://my-gateway.example/v1"
        DataSeeder.updateStarterModels(in: provider)
        XCTAssertEqual(provider.models, old)
    }

    func testChatTargetsRequireConfiguredAPIAndEnabledSelectableModel() {
        let models = [ModelSpec(id: "enabled"), ModelSpec(id: "off", isEnabled: false)]
        func provider(_ name: String, _ url: String) -> ProviderConfig {
            ProviderConfig(name: name, protocolType: .openAICompatible, baseURL: url, models: models)
        }
        let template = provider("Unconfigured template", "https://api.deepseek.com/v1")
        let keyed = provider("Key pool", "https://gateway.example/v1")
        let headers = provider("Header only", "https://other.example/v1")
        let local = provider("Local", "http://localhost:11434/v1")
        let placeholder = provider("Placeholder", "https://api.example.com/v1")
        let cleartext = provider("Public HTTP", "http://public.example/v1")
        let disabled = provider("Disabled", "http://127.0.0.1/v1")
        disabled.isEnabled = false
        let credential = CustomHeader(key: "X-API-Key", value: "fixture")
        headers.customHeaders = [credential]
        placeholder.customHeaders = [credential]
        cleartext.customHeaders = [credential]
        var removed = ModelSpec(id: "retired")
        removed.isStarred = true
        removed.catalogStatus = .unlisted
        local.models += [removed]
        XCTAssertTrue(KeychainService.shared.saveExtraAPIKeys(["fixture"], for: keyed.id))
        defer { keyed.deleteAllSecrets() }
        let providers = [template, keyed, headers, local, placeholder, cleartext, disabled]
        let initial = ProviderConfig.readyTargets(in: providers)
        XCTAssertEqual(initial.map(\.providerID), [keyed.id, headers.id, local.id])
        XCTAssertEqual(initial.map(\.modelID), Array(repeating: "enabled", count: 3))
        XCTAssertEqual(ChatEngine().availableTargets(from: providers), initial)
        KeychainService.shared.deleteAPIKey(for: keyed.id)
        headers.customHeaders = [CustomHeader(key: "X-API-Key", value: "fixture", isEnabled: false)]
        XCTAssertEqual(ProviderConfig.readyTargets(in: providers).map(\.providerID), [local.id])
    }

    func testEmptyDirectoryRetiresMissingModelsAndKeepsExplicitDeploymentAndPreferences() async throws {
        let catalog = ProviderModelCatalog()
        let oldJSON = #"{"id":"returning","displayName":"My model","isEnabled":true,"supportsVision":true,"supportsReasoning":false,"isFavorite":true}"#
        var legacy = try JSONDecoder().decode(ModelSpec.self, from: Data(oldJSON.utf8))
        XCTAssertNil(legacy.catalogStatus)
        var manual = ModelSpec(id: "private-deployment")
        manual.catalogStatus = .manual
        var saved = [legacy, manual, ModelSpec(id: "disabled", isEnabled: false)]
        await catalog.refresh(request: request, load: { _ in [] }, onSuccess: { saved = ProviderModelCatalog.merging($0, with: saved) })?.value
        XCTAssertNil(catalog.error)
        XCTAssertEqual(catalog.models, [])
        XCTAssertEqual(saved.filter(\.isSelectable), [manual])
        let returned = ProviderModelCatalog.merging([ModelSpec(id: legacy.id), ModelSpec(id: "disabled")], with: saved)
        legacy.catalogStatus = .listed
        XCTAssertEqual(returned.first, legacy)
        XCTAssertEqual(returned.filter(\.isSelectable).map(\.id), [legacy.id, manual.id])
        XCTAssertFalse(ProviderModelCatalog.merging([ModelSpec(id: "new")], with: [ModelSpec(id: "off", isEnabled: false)])[0].isSelectable)
    }

    func testDraftMigratesRetiredStarterWithinSameAccountAndHistoryPreservesItsSnapshot() {
        let provider = ProviderConfig(name: "One", protocolType: .openAICompatible, baseURL: "http://localhost/v1")
        let other = ProviderConfig(name: "Two", protocolType: .openAICompatible, baseURL: "http://localhost/v1")
        let previous = provider.makeTarget(for: ModelSpec(id: "old"))
        let current = provider.makeTarget(for: ModelSpec(id: "current"))
        let unrelated = other.makeTarget(for: ModelSpec(id: "old"))
        let draft = Conversation(primaryTarget: previous)
        draft.updateDraftModel(from: [unrelated, current], replacingLegacy: [previous.id])
        XCTAssertEqual(draft.primaryTarget, current)
        draft.updateDraftModel(from: [unrelated])
        XCTAssertNil(draft.primaryTarget)
        draft.updateDraftModel(from: [unrelated])
        XCTAssertNil(draft.primaryTarget)
        let second = provider.makeTarget(for: ModelSpec(id: "second"))
        let arena = Conversation(isArenaMode: true, arenaTargets: [previous, current])
        arena.updateDraftModel(from: [unrelated, current, second], replacingLegacy: [previous.id])
        XCTAssertEqual(arena.arenaTargets, [second, current])
        let existing = Conversation(primaryTarget: previous)
        existing.messages = [ChatMessage(role: .user, content: "Already sent")]
        existing.updateDraftModel(from: [current])
        XCTAssertEqual(existing.primaryTarget, previous)
    }

    func testLiveRefreshRespectsConfiguredSubsetAndManualOnlyDeployments() {
        let live = ["new", "chosen", "off"].map { ModelSpec(id: $0) }
        let chosen = ProviderModelCatalog.merging(live, with: [], choosing: "chosen")
        let expanded = ProviderModelCatalog.merging([ModelSpec(id: "brand-new")] + live, with: chosen)
        XCTAssertEqual(expanded.filter(\.isSelectable).map(\.id), ["chosen"])
        var deployment = ModelSpec(id: "manual")
        deployment.catalogStatus = .manual
        XCTAssertEqual(ProviderModelCatalog.merging(live, with: [deployment]).filter(\.isSelectable), [deployment])
    }

    func testDiscoveryUsesSelectedEndpointAndCanListWithoutAKeyOnLocalServers() {
        XCTAssertNil(ProviderTemplate.matching(baseURL: "https://gateway.example/v1", protocolType: .openAICompatible))
        XCTAssertNil(ProviderTemplate.matching(baseURL: request.baseURL, protocolType: .anthropic))
        XCTAssertEqual(ProviderTemplate.matching(baseURL: "https://api.deepseek.com/v1/", protocolType: .openAICompatible)?.id, "deepseek")
        XCTAssertTrue(ModelCatalogRequest(protocolType: .openAICompatible, baseURL: "http://localhost:11434/v1", apiKey: "").fetchOnOpen)
        XCTAssertFalse(ModelCatalogRequest(protocolType: .openAICompatible, baseURL: "http://public.example.com", apiKey: "key").canFetch)
        XCTAssertFalse(ModelCatalogRequest(protocolType: .openAICompatible, baseURL: "https://api.example.com/v1", apiKey: "key").canFetch)
        XCTAssertFalse(ModelCatalogRequest(protocolType: .openAICompatible, baseURL: "https://api.deepseek.com/v1", apiKey: "").fetchOnOpen)
    }
}
