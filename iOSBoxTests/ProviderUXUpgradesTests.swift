import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ProviderUXUpgradesTests: XCTestCase {
    func testExpandedIssuerDetectionCoversMajorOfficialProvidersAndSkipsCustomRelays() {
        let openAIURL = ProviderTemplate.openAIResponses.baseURL
        let routerURL = ProviderTemplate.openRouter.baseURL
        let deepseekURL = "https://api.deepseek.com/v1"

        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "sk-ant-api03-1234567890abcdef", baseURL: openAIURL)?.id, "anthropic")
        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "AIzaSyD1234567890abcdefghijkLMN", baseURL: openAIURL)?.id, "gemini")
        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "gsk_0123456789abcdefghijklmnop", baseURL: openAIURL)?.id, "groq")
        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "xai-0123456789abcdefghijklmnop", baseURL: deepseekURL)?.id, "xai")
        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "sk-or-v1-0123456789abcdef0123456789abcdef", baseURL: deepseekURL)?.id, "openrouter")
        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "sk-proj-offlinefixture", baseURL: routerURL)?.id, "openai_responses")

        // Matching official endpoints return nil.
        XCTAssertNil(ProviderTemplate.mismatchedIssuer(apiKey: "sk-ant-api03-1234567890abcdef", baseURL: "https://api.anthropic.com/v1"))
        XCTAssertNil(ProviderTemplate.mismatchedIssuer(apiKey: "AIzaSyD1234567890abcdefghijkLMN", baseURL: "https://generativelanguage.googleapis.com/v1beta"))
        XCTAssertNil(ProviderTemplate.mismatchedIssuer(apiKey: "gsk_0123456789abcdefghijklmnop", baseURL: ProviderTemplate.groq.baseURL))

        // Custom relays must never trigger false-positive issuer blocks.
        XCTAssertNil(ProviderTemplate.mismatchedIssuer(apiKey: "sk-ant-api03-1234567890abcdef", baseURL: "https://my-relay.example.org/v1"))
    }

    func testMultiFieldSnippetDetectionAndNewTemplates() {
        XCTAssertFalse(ClipboardProviderParser.looksLikeMultiFieldSnippet("sk-proj-singlelinekey12345678"))
        XCTAssertTrue(ClipboardProviderParser.looksLikeMultiFieldSnippet("https://api.deepseek.com/v1 sk-1234567890abcdef1234"))
        XCTAssertTrue(ClipboardProviderParser.looksLikeMultiFieldSnippet("url: https://open.bigmodel.cn/api/paas/v4\nkey: tok-1234567890abcdef1234"))

        let dashscope = ClipboardProviderParser.parse("https://dashscope.aliyuncs.com/compatible-mode/v1\nAPI_KEY=sk-1234567890abcdef1234")
        XCTAssertEqual(dashscope?.templateID, "dashscope")
        XCTAssertEqual(dashscope?.apiKey, "sk-1234567890abcdef1234")

        let xai = ClipboardProviderParser.parse("xai-1234567890abcdefghijklmnop")
        XCTAssertEqual(xai?.templateID, "xai")
        XCTAssertEqual(xai?.baseURL, "https://api.x.ai/v1")

        // Every official/aggregator built-in template provides a console URL.
        for tpl in ProviderTemplate.setupChoices where tpl.category != .localAndCustom {
            XCTAssertNotNil(tpl.keyConsoleURL, "Missing keyConsoleURL for \(tpl.id)")
        }
    }

    func testRecommendedStarterModelsAndMultiModelVerifiedSave() throws {
        let fetched = [
            ModelSpec(id: "whisper-large-v3"),
            ModelSpec(id: "text-embedding-3-large"),
            ModelSpec(id: "deepseek-chat", supportsVision: false, supportsReasoning: false),
            ModelSpec(id: "deepseek-reasoner", supportsVision: false, supportsReasoning: true),
            ModelSpec(id: "qwen-vl-max", supportsVision: true, supportsReasoning: false),
            ModelSpec(id: "extra-model-4")
        ]
        let picks = ClipboardProviderParser.pickRecommendedStarterModels(
            from: fetched,
            primaryID: "deepseek-chat",
            protocolType: .openAICompatible,
            limit: 3
        )
        XCTAssertEqual(picks.first?.id, "deepseek-chat")
        XCTAssertEqual(picks.count, 3)
        XCTAssertFalse(picks.contains { $0.id.contains("whisper") || $0.id.contains("embedding") })

        let container = try ModelContainer(for: ProviderConfig.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var draft = ProviderSetupDraft(template: .groq, apiKey: "gsk_fixture1234567890abcdef")
        draft.baseURL = "http://localhost:11434/v1"
        let verified = VerifiedProviderConnection(
            draft: draft,
            chosenModel: fetched[2],
            fetched: fetched,
            updateAccountID: nil,
            previousConnection: nil,
            additionalEnabledModelIDs: ["deepseek-reasoner", "qwen-vl-max"]
        )
        let (provider, primaryTarget) = try verified.save(in: context)
        defer { provider.deleteAllSecrets() }
        XCTAssertEqual(primaryTarget.modelID, "deepseek-chat")
        XCTAssertEqual(Set(provider.enabledModels.map(\.id)), ["deepseek-chat", "deepseek-reasoner", "qwen-vl-max"])
    }

    func testGatewayCapabilityCacheSelectiveInspectAndClear() {
        let suite = "com.iosbox.tests.gatewayCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let cache = GatewayCapabilityCache(defaults: defaults)
        cache.markUnsupported([.thinkingConfig], protocolType: .openAICompatible, baseURL: "https://a.example/v1", modelID: "m1")
        cache.markUnsupported([.streamOptions], protocolType: .openAICompatible, baseURL: "https://b.example/v1", modelID: "m2")

        XCTAssertEqual(cache.degradedModelCount(protocolType: .openAICompatible, baseURL: "https://a.example/v1", modelIDs: ["m1", "m2"]), 1)
        let cleared = cache.clear(protocolType: .openAICompatible, baseURL: "https://a.example/v1", modelIDs: ["m1", "m2"])
        XCTAssertEqual(cleared, 1)
        XCTAssertFalse(cache.isUnsupported(.thinkingConfig, protocolType: .openAICompatible, baseURL: "https://a.example/v1", modelID: "m1"))
        XCTAssertTrue(cache.isUnsupported(.streamOptions, protocolType: .openAICompatible, baseURL: "https://b.example/v1", modelID: "m2"))
    }

    func testBackfillUnpricedRecordsUpdatesOnlyMissingPrices() throws {
        let providerID = UUID()
        let target = ResolvedModelTarget(
            providerID: providerID,
            providerName: "Relay",
            protocolType: .openAICompatible,
            modelID: "gpt-4o-mini",
            modelDisplayName: "GPT-4o mini",
            accentHex: "#3F6EF6",
            supportsVision: true,
            supportsReasoning: false
        )
        let unpriced = RequestRecord(target: target, spec: nil, conversationID: UUID(), messageID: UUID(), kind: .answer)
        unpriced.promptTokens = 1_000_000
        unpriced.completionTokens = 500_000
        unpriced.finish(.succeeded, elapsedMs: 200)

        var oldSpec = ModelSpec(id: "gpt-4o-mini")
        oldSpec.inputPricePerMillion = 10
        oldSpec.outputPricePerMillion = 20
        oldSpec.priceCurrency = "USD"
        let alreadyPriced = RequestRecord(target: target, spec: oldSpec, conversationID: UUID(), messageID: UUID(), kind: .answer)
        alreadyPriced.promptTokens = 1_000_000
        alreadyPriced.completionTokens = 500_000
        alreadyPriced.finish(.succeeded, elapsedMs: 200)

        var newSpec = ModelSpec(id: "gpt-4o-mini")
        newSpec.inputPricePerMillion = 0.15
        newSpec.outputPricePerMillion = 0.60
        newSpec.priceCurrency = "USD"

        let count = RequestLedger.backfillUnpricedRecords(
            in: [unpriced, alreadyPriced],
            providerID: providerID,
            modelID: "gpt-4o-mini",
            spec: newSpec
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try XCTUnwrap(unpriced.estimatedCost), 0.45, accuracy: 0.000_001)
        // Historical priced snapshot must remain untouched.
        XCTAssertEqual(try XCTUnwrap(alreadyPriced.estimatedCost), 20.0, accuracy: 0.000_001)
    }
}
