import XCTest
@testable import iOSBox

final class EverydayTemplatesAndQuickKeyTests: XCTestCase {

    func testSetupChoosesOneOpenAIServiceAndKeepsTheExplicitProtocolOnImport() throws {
        var draft = ProviderSetupDraft()
        XCTAssertEqual(ProviderTemplate.setupChoices.filter { $0.baseURL == draft.baseURL }.map(\.id), ["openai_responses"])
        XCTAssertEqual(draft.protocolType, .openAIResponses)
        let key = "sk-proj-offlinefixture12345678"
        let imported = try XCTUnwrap(ClipboardProviderParser.parse(key))
        draft.apply(imported)
        XCTAssertEqual(draft.protocolType, .openAIResponses)
        draft.protocolType = .openAICompatible
        draft.apply(imported)
        XCTAssertEqual(draft.protocolType, .openAICompatible)
        XCTAssertEqual(draft.apiKey, key)

        draft.select(.openRouter)
        XCTAssertEqual(draft.apiKey, "")
        draft.apply(try XCTUnwrap(ClipboardProviderParser.parse("sk-ambiguous1234567890")))
        XCTAssertEqual(draft.baseURL, ProviderTemplate.openRouter.baseURL)
        draft.manualModelID = "openrouter/auto"
        draft.apply(try XCTUnwrap(ClipboardProviderParser.parse("https://api.openai.com/v1")))
        XCTAssertEqual(draft.apiKey, "")
        XCTAssertEqual(draft.manualModelID, "")
        XCTAssertEqual(draft.protocolType, .openAIResponses)
    }

    func testSetupIdentifiesTheTwoIssuersOnlyAtTheirOfficialEndpoints() {
        let official = ProviderTemplate.openAIResponses.baseURL
        let router = ProviderTemplate.openRouter.baseURL
        let key = "sk-proj-offlinefixture"
        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "Bearer " + key, baseURL: router)?.id, "openai_responses")
        XCTAssertEqual(ProviderTemplate.mismatchedIssuer(apiKey: "sk-or-v1-fixture", baseURL: official)?.id, "openrouter")
        XCTAssertNil(ProviderTemplate.mismatchedIssuer(apiKey: key, baseURL: official))
        XCTAssertNil(ProviderTemplate.mismatchedIssuer(apiKey: key, baseURL: "https://relay.example/v1"))
        XCTAssertNil(ProviderTemplate.mismatchedIssuer(apiKey: "sk-generic", baseURL: router))
        XCTAssertFalse(ModelCatalogRequest(protocolType: .openAICompatible, baseURL: router, apiKey: key).canFetch)
    }

    func testClipboardParserRecognizesMajorProvidersAndCustomRelays() {
        let anthropic = ClipboardProviderParser.parse("Here is my key: sk-ant-api03-abcdefghijklmnop12345")
        XCTAssertNotNil(anthropic)
        XCTAssertEqual(anthropic?.protocolType, .anthropic)
        XCTAssertEqual(anthropic?.baseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(anthropic?.apiKey, "sk-ant-api03-abcdefghijklmnop12345")

        let gemini = ClipboardProviderParser.parse("GEMINI_API_KEY=AIzaSyD1234567890abcdefghijkLMN")
        XCTAssertNotNil(gemini)
        XCTAssertEqual(gemini?.protocolType, .gemini)
        XCTAssertTrue(gemini?.baseURL.contains("generativelanguage.googleapis.com") == true)

        let openRouter = ClipboardProviderParser.parse("sk-or-v1-0123456789abcdef0123456789abcdef")
        XCTAssertNotNil(openRouter)
        XCTAssertEqual(openRouter?.providerName, "OpenRouter")
        XCTAssertEqual(openRouter?.baseURL, "https://openrouter.ai/api/v1")

        let groq = ClipboardProviderParser.parse("gsk_0123456789abcdefghijklmnop")
        XCTAssertNotNil(groq)
        XCTAssertEqual(groq?.providerName, "Groq")
        XCTAssertEqual(groq?.baseURL, "https://api.groq.com/openai/v1")

        let deepseek = ClipboardProviderParser.parse(
            "url: https://api.deepseek.com/v1\nkey: sk-1234567890abcdef123456"
        )
        XCTAssertNotNil(deepseek)
        XCTAssertEqual(deepseek?.templateID, "deepseek")
        XCTAssertTrue(deepseek?.providerName.contains("DeepSeek") == true)
        XCTAssertEqual(deepseek?.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(deepseek?.apiKey, "sk-1234567890abcdef123456")
        XCTAssertEqual(deepseek?.isGenericOpenAIKey, false)

        let relay = ClipboardProviderParser.parse(
            "Base URL: https://relay.example.org/v1\nAuthorization: Bearer tok-abcdef1234567890"
        )
        XCTAssertNotNil(relay)
        XCTAssertEqual(relay?.protocolType, .openAICompatible)
        XCTAssertEqual(relay?.baseURL, "https://relay.example.org/v1")
        XCTAssertEqual(relay?.apiKey, "tok-abcdef1234567890")
    }

    func testClipboardParserAllowsLocalHTTPAndRejectsPublicHTTPOrNoise() {
        let local = ClipboardProviderParser.parse("http://127.0.0.1:11434/v1")
        XCTAssertNotNil(local)
        XCTAssertEqual(local?.baseURL, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(local?.apiKey, "")

        XCTAssertNil(ClipboardProviderParser.parse("http://api.relay.example.org/v1 sk-1234567890abcdef12"))
        XCTAssertNil(ClipboardProviderParser.parse("plain text without url or api key"))
        XCTAssertNil(ClipboardProviderParser.parse("   "))
    }

    func testPickBestStarterModelFiltersNonChatAndFallsBackCleanly() {
        let models = [
            ModelSpec(id: "whisper-1", displayName: "whisper-1"),
            ModelSpec(id: "tts-1-hd", displayName: "tts-1-hd"),
            ModelSpec(id: "dall-e-3", displayName: "dall-e-3"),
            ModelSpec(id: "text-embedding-3-small", displayName: "text-embedding-3-small"),
            ModelSpec(id: "gpt-4o-mini", displayName: "gpt-4o-mini")
        ]
        let picked = ClipboardProviderParser.pickBestStarterModel(from: models, protocolType: .openAICompatible)
        XCTAssertEqual(picked?.id, "gpt-4o-mini")

        let customOnly = [
            ModelSpec(id: "whisper-1", displayName: "whisper-1"),
            ModelSpec(id: "my-custom-chat-v2", displayName: "my-custom-chat-v2")
        ]
        let fallback = ClipboardProviderParser.pickBestStarterModel(from: customOnly, protocolType: .openAICompatible)
        XCTAssertEqual(fallback?.id, "my-custom-chat-v2")
    }

    func testDailyPresetsAndEverydaySlashCommandsAreComplete() {
        let daily = AssistantPreset.dailyLifePresets
        let all = AssistantPreset.defaultPresets
        XCTAssertEqual(daily.count, 5)
        XCTAssertEqual(all.count, 10)
        XCTAssertEqual(Set(all.map(\.id)).count, 10)
        XCTAssertEqual(all.map(\.sortOrder).sorted(), Array(0...9))

        let expectedDailyIDs = [
            UUID(uuidString: "00000000-0000-4000-8000-000000000006")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000007")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000008")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000009")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        ]
        XCTAssertEqual(daily.map(\.id), expectedDailyIDs)

        let builtIns = SlashPromptCommand.builtIns
        XCTAssertEqual(builtIns.count, 16)
        let cmds = Set(builtIns.map(\.command))
        for expected in ["/meeting", "/reply", "/weekly", "/solve", "/contract", "/plan"] {
            XCTAssertTrue(cmds.contains(expected), "Missing slash command: \(expected)")
        }
    }

    @MainActor
    func testSimpleDailyModePreferencePersistsRoundTrip() {
        let suiteName = "com.iosbox.tests.simpleDaily.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs1 = AppPreferences(defaults: defaults)
        XCTAssertFalse(prefs1.simpleDailyMode)

        prefs1.simpleDailyMode = true
        let prefs2 = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs2.simpleDailyMode)

        prefs2.simpleDailyMode = false
        let prefs3 = AppPreferences(defaults: defaults)
        XCTAssertFalse(prefs3.simpleDailyMode)
    }
}
