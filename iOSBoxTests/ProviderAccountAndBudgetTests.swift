import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ProviderAccountAndBudgetTests: XCTestCase {
    func testBudgetAndLedgerUseModelRatesInBaseCurrency() throws {
        var spec = ModelSpec(id: "review-text")
        spec.inputPricePerMillion = 1
        spec.outputPricePerMillion = 2
        spec.priceCurrency = "USD"
        let target = ResolvedModelTarget(
            providerID: UUID(), providerName: "Review Relay", protocolType: .openAICompatible,
            modelID: spec.id, modelDisplayName: spec.displayName, accentHex: "#123456",
            supportsVision: false, supportsReasoning: false
        )
        let record = RequestRecord(
            target: target, spec: spec, conversationID: UUID(), messageID: UUID(),
            kind: .answer
        )
        // 10,000 input tokens at USD 1/million + 5,000 output tokens at USD 2/million
        // gives USD 0.02 at the configured model prices.
        record.promptTokens = 10_000
        record.completionTokens = 5_000
        record.finish(.succeeded, elapsedMs: 120)
        let totals = RequestLedger.costs([record])
        XCTAssertEqual(record.currency, "USD")
        XCTAssertEqual(try XCTUnwrap(record.estimatedCost), 0.02, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(totals["USD"]), 0.02, accuracy: 0.000_001)
        XCTAssertNil(totals["CNY"])
        let cnyBudget = MonthlyBudgetEvaluator.evaluate(spentByCurrency: totals, limit: 0.10, currency: "CNY")
        XCTAssertEqual(cnyBudget.spent, 0, accuracy: 0.000_001)
        XCTAssertEqual(cnyBudget.remaining, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(cnyBudget.level, .normal)
        let usdBudget = MonthlyBudgetEvaluator.evaluate(spentByCurrency: totals, limit: 0.10, currency: "USD")
        XCTAssertEqual(usdBudget.spent, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(usdBudget.level, .normal)
    }

    func testNewAccountAndExplicitUpdateAtTheSameAddress() throws {
        let container = try ModelContainer(for: ProviderConfig.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var draft = ProviderSetupDraft()
        draft.protocolType = .openAICompatible
        draft.baseURL = "http://localhost:12001/v1"
        draft.name = "Shared Endpoint"
        draft.apiKey = "test-personal-key"
        let originalModel = ModelSpec(id: "old")
        let old = ProviderConfig(name: draft.name, protocolType: draft.protocolType, baseURL: draft.baseURL, models: [originalModel])
        context.insert(old)
        try context.save()
        XCTAssertTrue(KeychainService.shared.saveAPIKey("test-work-key", for: old.credentialID))
        defer { old.deleteAllSecrets() }

        let selected = ModelSpec(id: "new")
        let verified = VerifiedProviderConnection(draft: draft, chosenModel: selected, fetched: [selected], updateAccountID: nil, previousConnection: nil)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProviderConfig>()), 1)
        XCTAssertEqual(old.enabledModels.map(\.id), ["old"])
        XCTAssertEqual(old.apiKey, "test-work-key")
        let (newAccount, target) = try verified.save(in: context)
        defer { newAccount.deleteAllSecrets() }
        XCTAssertEqual(old.apiKey, "test-work-key")
        XCTAssertEqual(newAccount.apiKey, "test-personal-key")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProviderConfig>()), 2)
        XCTAssertNotEqual(target.providerID, old.id)
        XCTAssertNotEqual(newAccount.name, old.name)
        XCTAssertEqual(old.enabledModels.map(\.id), ["old"])

        draft.apiKey = "test-work-replacement"
        let update = VerifiedProviderConnection(draft: draft, chosenModel: selected, fetched: [selected],
                                                updateAccountID: old.id, previousConnection: SystemIntegration.connection(old))
        let (updated, _) = try update.save(in: context)
        XCTAssertEqual(updated.id, old.id)
        XCTAssertEqual(updated.apiKey, "test-work-replacement")
        XCTAssertEqual(newAccount.apiKey, "test-personal-key")
        XCTAssertEqual(updated.name, "Shared Endpoint")
        XCTAssertEqual(updated.enabledModels.map(\.id), ["new"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProviderConfig>()), 2)

        let staleUpdate = VerifiedProviderConnection(draft: draft, chosenModel: selected, fetched: [selected],
                                                     updateAccountID: old.id, previousConnection: SystemIntegration.connection(old))
        old.baseURL = "http://localhost:12345"
        try context.save()
        XCTAssertThrowsError(try staleUpdate.save(in: context))
    }

    func testDiscoveryCanEnableOneListedModelWithoutRevivingRetiredModels() throws {
        let container = try ModelContainer(for: ProviderConfig.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var retired = ModelSpec(id: "retired", isEnabled: false)
        retired.catalogStatus = .unlisted
        var discovered = ModelSpec(id: "new", isEnabled: false)
        discovered.catalogStatus = .listed
        discovered.isStarred = true
        discovered.inputPricePerMillion = 3
        let provider = ProviderConfig(name: "Fixture", protocolType: .openAICompatible, baseURL: "http://localhost:1234",
                                      models: [retired, discovered])
        context.insert(provider)
        try context.save()
        XCTAssertTrue(provider.enabledModels.isEmpty)
        let target = try ProviderModelCatalog.enable(modelID: discovered.id, on: provider, in: context)
        XCTAssertEqual(target.providerID, provider.id)
        XCTAssertEqual(provider.enabledModels.map(\.id), ["new"])
        XCTAssertEqual(provider.enabledModels.first?.isStarred, true)
        XCTAssertEqual(provider.enabledModels.first?.inputPricePerMillion, 3)
        XCTAssertThrowsError(try ProviderModelCatalog.enable(modelID: retired.id, on: provider, in: context))
        XCTAssertEqual(provider.models.map(\.id), ["retired", "new"])
    }

    func testSendReviewTurnBoundMatchesGroupModesAndMentions() {
        func turns(_ mode: GroupSpeakingMode, planned: Int, explicit: Bool, active: Int, configured: Int) -> Int {
            GroupDiscussionCoordinator.maximumTurnsForUserMessage(speakingMode: mode, plannedCount: planned,
                explicitMentions: explicit, activeCount: active, configuredLimit: configured)
        }
        XCTAssertEqual(turns(.roundRobin, planned: 4, explicit: false, active: 4, configured: 2), 4)
        XCTAssertEqual(turns(.mentionOnly, planned: 2, explicit: true, active: 5, configured: 6), 2)
        XCTAssertEqual(turns(.smartRelay, planned: 3, explicit: false, active: 3, configured: 8), 4)
        XCTAssertEqual(turns(.smartRelay, planned: 4, explicit: true, active: 4, configured: 2), 4)
        XCTAssertEqual(turns(.mentionOnly, planned: 0, explicit: false, active: 4, configured: 2), 0)
    }
}
