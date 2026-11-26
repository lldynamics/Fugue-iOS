import CryptoKit
import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ProviderP2FeaturesTests: XCTestCase {
    func testBalanceParsersCoverOpenRouterDeepSeekSiliconFlowMoonshotAndOneAPI() throws {
        // 1. OpenRouter /credits
        let orCredits = Data(#"{"data":{"total_credits":25.0,"total_usage":7.25}}"#.utf8)
        let orSnap = try ProviderBalanceService.parseOpenRouterCredits(orCredits)
        XCTAssertEqual(orSnap.currency, "USD")
        XCTAssertEqual(try XCTUnwrap(orSnap.available), 17.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(orSnap.used), 7.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(orSnap.total), 25.0, accuracy: 0.0001)

        // 2. OpenRouter /key fallback
        let orKey = Data(#"{"data":{"usage":1.5,"limit":10.0,"limit_remaining":8.5,"is_free_tier":false}}"#.utf8)
        let orKeySnap = try ProviderBalanceService.parseOpenRouterKeyInfo(orKey)
        XCTAssertEqual(try XCTUnwrap(orKeySnap.available), 8.5, accuracy: 0.0001)

        // 3. DeepSeek /user/balance
        let dsJSON = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"42.80","granted_balance":"10.00","topped_up_balance":"32.80"}]}"#.utf8)
        let dsSnap = try ProviderBalanceService.parseDeepSeekBalance(dsJSON)
        XCTAssertEqual(dsSnap.currency, "CNY")
        XCTAssertEqual(try XCTUnwrap(dsSnap.available), 42.80, accuracy: 0.0001)
        XCTAssertNotNil(dsSnap.detailNote)

        // 4. SiliconFlow /v1/user/info
        let sfJSON = Data(#"{"data":{"balance":"14.00","chargeBalance":"20.50","totalBalance":"34.50"}}"#.utf8)
        let sfSnap = try ProviderBalanceService.parseSiliconFlowBalance(sfJSON)
        XCTAssertEqual(sfSnap.currency, "CNY")
        XCTAssertEqual(try XCTUnwrap(sfSnap.available), 34.50, accuracy: 0.0001)

        // 5. Moonshot /v1/users/me/balance
        let msJSON = Data(#"{"data":{"available_balance":88.6,"voucher_balance":15.0,"cash_balance":73.6}}"#.utf8)
        let msSnap = try ProviderBalanceService.parseMoonshotBalance(msJSON)
        XCTAssertEqual(msSnap.currency, "CNY")
        XCTAssertEqual(try XCTUnwrap(msSnap.available), 88.6, accuracy: 0.0001)

        // 6. OneAPI / NewAPI /v1/dashboard/billing/*
        let subJSON = Data(#"{"hard_limit_usd":50.0}"#.utf8)
        let usageJSON = Data(#"{"total_usage":1250}"#.utf8) // 1250 cents = $12.50
        let relaySnap = try ProviderBalanceService.parseOpenAICompatibleBilling(subscriptionData: subJSON, usageData: usageJSON)
        XCTAssertEqual(relaySnap.currency, "USD")
        XCTAssertEqual(try XCTUnwrap(relaySnap.available), 37.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(relaySnap.used), 12.5, accuracy: 0.0001)

        // Endpoint eligibility checks
        XCTAssertTrue(ProviderBalanceService.supportsBalanceQuery(protocolType: .openAICompatible, baseURL: "https://openrouter.ai/api/v1"))
        XCTAssertTrue(ProviderBalanceService.supportsBalanceQuery(protocolType: .openAICompatible, baseURL: "https://api.deepseek.com/v1"))
        XCTAssertTrue(ProviderBalanceService.supportsBalanceQuery(protocolType: .openAICompatible, baseURL: "https://my-oneapi.example.org/v1"))
        XCTAssertFalse(ProviderBalanceService.supportsBalanceQuery(protocolType: .anthropic, baseURL: "https://api.anthropic.com/v1"))
        XCTAssertFalse(ProviderBalanceService.supportsBalanceQuery(protocolType: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1"))
    }

    func testOpenRouterPKCEAndKeyExchangeHelpers() throws {
        let pair = OpenRouterOAuthCoordinator.generatePKCEPair()
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertFalse(pair.verifier.contains("="))
        let expectedDigest = SHA256.hash(data: Data(pair.verifier.utf8))
        XCTAssertEqual(pair.challenge, OpenRouterOAuthCoordinator.base64URLEncode(Data(expectedDigest)))

        let authURL = try XCTUnwrap(OpenRouterOAuthCoordinator.buildAuthorizationURL(challenge: pair.challenge))
        XCTAssertEqual(authURL.host, "openrouter.ai")
        XCTAssertTrue(authURL.absoluteString.contains("code_challenge_method=S256"))

        let callback = URL(string: "iosbox://openrouter-oauth?code=auth_code_xyz123")!
        XCTAssertEqual(OpenRouterOAuthCoordinator.extractAuthorizationCode(from: callback), "auth_code_xyz123")

        let keyPayload = Data(#"{"key":"sk-or-v1-0123456789abcdef0123456789abcdef"}"#.utf8)
        XCTAssertEqual(try OpenRouterOAuthCoordinator.parseKeyExchangeResponse(keyPayload), "sk-or-v1-0123456789abcdef0123456789abcdef")
    }

    func testStructuredJSONAndDeepLinkConfigImport() throws {
        let jsonSnippet = """
        {
          "name": "Team OneAPI",
          "baseUrl": "https://gateway.team.org/v1",
          "apiKey": "sk-teamtoken1234567890",
          "model": "claude-sonnet-4-5",
          "protocol": "openai_compatible"
        }
        """
        XCTAssertTrue(ClipboardProviderParser.looksLikeMultiFieldSnippet(jsonSnippet))
        let parsedJSON = try XCTUnwrap(ClipboardProviderParser.parse(jsonSnippet))
        XCTAssertEqual(parsedJSON.providerName, "Team OneAPI")
        XCTAssertEqual(parsedJSON.baseURL, "https://gateway.team.org/v1")
        XCTAssertEqual(parsedJSON.apiKey, "sk-teamtoken1234567890")
        XCTAssertEqual(parsedJSON.extractedModelID, "claude-sonnet-4-5")

        let deepLink = "iosbox://import-provider?name=MyRelay&url=https%3A%2F%2Frelay.company.io%2Fv1&key=sk-relay9876543210abcdef&model=gpt-5&protocol=openai_responses"
        XCTAssertTrue(ClipboardProviderParser.looksLikeMultiFieldSnippet(deepLink))
        let parsedLink = try XCTUnwrap(ClipboardProviderParser.parse(deepLink))
        XCTAssertEqual(parsedLink.providerName, "MyRelay")
        XCTAssertEqual(parsedLink.baseURL, "https://relay.company.io/v1")
        XCTAssertEqual(parsedLink.apiKey, "sk-relay9876543210abcdef")
        XCTAssertEqual(parsedLink.explicitProtocol, .openAIResponses)
        XCTAssertEqual(parsedLink.extractedModelID, "gpt-5")

        let b64 = Data(jsonSnippet.utf8).base64EncodedString()
        let ccSwitchLink = "ccswitch://import?data=\(b64)"
        let parsedB64 = try XCTUnwrap(ClipboardProviderParser.parse(ccSwitchLink))
        XCTAssertEqual(parsedB64.baseURL, "https://gateway.team.org/v1")
        XCTAssertEqual(parsedB64.apiKey, "sk-teamtoken1234567890")
    }

    func testKeyPoolCooldownCountdownAndPrivacyPreservingHashedLabels() {
        let router = APIKeyPoolRouter()
        let start = ContinuousClock.now
        router.markUnhealthy(
            key: "sk-key-alpha",
            protocolType: .openAICompatible,
            baseURL: "https://relay.example.org/v1",
            statusCode: 429,
            retryAfter: 45,
            now: start
        )
        let secs = router.remainingCooldownSeconds(
            key: "sk-key-alpha",
            protocolType: .openAICompatible,
            baseURL: "https://relay.example.org/v1",
            now: start.advanced(by: .seconds(10))
        )
        XCTAssertEqual(secs, 35)
        XCTAssertEqual(
            router.coolingKeyCount(
                keys: ["sk-key-alpha", "sk-key-beta"],
                protocolType: .openAICompatible,
                baseURL: "https://relay.example.org/v1",
                now: start.advanced(by: .seconds(10))
            ),
            1
        )
        router.markHealthy(key: "sk-key-alpha", protocolType: .openAICompatible, baseURL: "https://relay.example.org/v1")
        XCTAssertNil(router.remainingCooldownSeconds(key: "sk-key-alpha", protocolType: .openAICompatible, baseURL: "https://relay.example.org/v1"))

        // Key labels store only SHA-256 digests in UserDefaults, never raw keys.
        let suite = "com.iosbox.tests.keyLabels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConnectionSettingsStore(defaults: defaults)
        let providerID = UUID()
        let rawSecret = "sk-super-secret-production-token-9999"
        store.setKeyLabel("主力生产号", for: rawSecret, providerID: providerID)
        XCTAssertEqual(store.keyLabel(for: rawSecret, providerID: providerID), "主力生产号")

        let persistedBlob = defaults.data(forKey: ProviderConnectionSettingsStore.storageKey) ?? Data()
        let persistedText = String(decoding: persistedBlob, as: UTF8.self)
        XCTAssertFalse(persistedText.contains(rawSecret), "Raw API key must never be written to UserDefaults")
    }

    func testDefaultFallbackModelSeedsNewChatsAndCurrentMonthBudgetQuery() throws {
        let suite = "com.iosbox.tests.p2defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)

        let p1 = ProviderConfig(name: "Primary", protocolType: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1", models: [ModelSpec(id: "m-primary")])
        let p2 = ProviderConfig(name: "Backup", protocolType: .openAICompatible, baseURL: "http://localhost:1234/v1", models: [ModelSpec(id: "m-backup")])
        let t1 = p1.makeTarget(for: p1.models[0])
        let t2 = p2.makeTarget(for: p2.models[0])

        prefs.defaultTargetID = t1.id
        prefs.defaultFallbackTargetID = t2.id

        let chat = prefs.newChat(providers: [p1, p2], presets: [])
        XCTAssertEqual(chat.primaryTarget?.id, t1.id)
        XCTAssertTrue(chat.assistanceSettings.fallbackEnabled)
        XCTAssertEqual(chat.assistanceSettings.fallbackTargets.map(\.id), [t2.id])

        // Current-month budget evaluation via SwiftData predicate
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = container.mainContext

        var pricedSpec = ModelSpec(id: "m-primary")
        pricedSpec.inputPricePerMillion = 10
        pricedSpec.outputPricePerMillion = 20
        pricedSpec.priceCurrency = "USD"

        let now = Date()
        let record = RequestRecord(target: t1, spec: pricedSpec, conversationID: UUID(), messageID: UUID(), kind: .answer, now: now)
        record.promptTokens = 500_000 // $5
        record.completionTokens = 200_000 // $4 -> total $9
        record.finish(.succeeded, elapsedMs: 100, now: now)
        context.insert(record)
        try context.save()

        prefs.monthlyBudgetLimit = 10.0
        prefs.monthlyBudgetCurrency = "USD"
        prefs.monthlyBudgetAlertRatio = 0.8

        let eval = MonthlyBudgetEvaluator.evaluateCurrentMonth(in: context, preferences: prefs, now: now)
        XCTAssertEqual(eval.level, .warning)
        XCTAssertEqual(eval.spent, 9.0, accuracy: 0.0001)
        XCTAssertEqual(eval.remaining, 1.0, accuracy: 0.0001)
    }
}
