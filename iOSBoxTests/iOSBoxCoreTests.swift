import XCTest
import SwiftData
@testable import iOSBox

final class iOSBoxCoreTests: XCTestCase {

    func testEndpointResolverOpenAIVariants() throws {
        // Bare domain auto-appends /v1/chat/completions
        let d1 = try EndpointResolver.chatEndpoint(baseURL: "https://api.deepseek.com", protocolType: .openAICompatible)
        XCTAssertEqual(d1.absoluteString, "https://api.deepseek.com/v1/chat/completions")

        // Existing /v1 is preserved without duplicating
        let d2 = try EndpointResolver.chatEndpoint(baseURL: "https://openrouter.ai/api/v1/", protocolType: .openAICompatible)
        XCTAssertEqual(d2.absoluteString, "https://openrouter.ai/api/v1/chat/completions")

        // Existing /v4 (e.g. Zhipu / custom gateway) is respected
        let d3 = try EndpointResolver.chatEndpoint(baseURL: "https://open.bigmodel.cn/api/paas/v4", protocolType: .openAICompatible)
        XCTAssertEqual(d3.absoluteString, "https://open.bigmodel.cn/api/paas/v4/chat/completions")

        // Trailing # forces raw path without injecting /v1
        let d4 = try EndpointResolver.chatEndpoint(baseURL: "https://my-proxy.example.com/custom#", protocolType: .openAICompatible)
        XCTAssertEqual(d4.absoluteString, "https://my-proxy.example.com/custom/chat/completions")

        // Models endpoint strips /chat/completions if user pasted full path
        let m1 = try EndpointResolver.modelsEndpoint(
            baseURL: "https://api.openai.com/v1/chat/completions",
            protocolType: .openAICompatible
        )
        XCTAssertEqual(m1.absoluteString, "https://api.openai.com/v1/models")
    }

    func testEndpointResolverAnthropicAndGemini() throws {
        let claudeChat = try EndpointResolver.chatEndpoint(
            baseURL: "https://api.anthropic.com",
            protocolType: .anthropic
        )
        XCTAssertEqual(claudeChat.absoluteString, "https://api.anthropic.com/v1/messages")

        let geminiChat = try EndpointResolver.chatEndpoint(
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            protocolType: .gemini,
            modelID: "gemini-2.5-pro"
        )
        XCTAssertEqual(
            geminiChat.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse"
        )
    }

    func testThinkTagStreamParserAcrossSplitChunks() {
        var parser = ThinkTagStreamParser()
        let chunks = ["<thi", "nk>\n第一步", "推理分析</th", "ink>\n\n这是最终", "答案！"]
        var reasoning = ""
        var content = ""

        for c in chunks {
            for seg in parser.feed(c) {
                switch seg {
                case .reasoning(let r): reasoning += r
                case .content(let t): content += t
                }
            }
        }
        for seg in parser.finish() {
            switch seg {
            case .reasoning(let r): reasoning += r
            case .content(let t): content += t
            }
        }

        XCTAssertEqual(reasoning, "第一步推理分析")
        XCTAssertEqual(content, "这是最终答案！")
    }

    func testAnthropicExtendedThinkingOmitsTemperatureAndEnsuresMaxTokens() {
        let req = LLMChatRequest(
            providerName: "Anthropic",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "sk-ant-test",
            customHeaders: [],
            modelID: "claude-sonnet-4-20250514",
            supportsReasoning: true,
            systemPrompt: "你是架构师",
            messages: [
                LLMPromptMessage(role: .user, content: "你好", attachments: [])
            ],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: true,
            thinkingBudgetTokens: 4096
        )

        let body = AnthropicAdapter.buildRequestBody(req)
        XCTAssertNil(body["temperature"], "Anthropic thinking mode must omit temperature")
        let maxTok = body["max_tokens"] as? Int ?? 0
        XCTAssertGreaterThan(maxTok, 4096)
        XCTAssertEqual(body["system"] as? String, "你是架构师")
    }

    @MainActor
    func testArenaGroupHistoryCollapsesToSelectedWinner() {
        let groupID = UUID()
        let user1 = ChatMessage(role: .user, content: "比较一下 SwiftUI 和 UIKit", sortIndex: 0)
        let modelA = ChatMessage(
            role: .assistant,
            content: "模型 A 的回答",
            comparisonGroupID: groupID,
            isSelectedInGroup: false,
            sortIndex: 1
        )
        let modelB = ChatMessage(
            role: .assistant,
            content: "模型 B 被选中的最佳回答",
            comparisonGroupID: groupID,
            isSelectedInGroup: true,
            sortIndex: 2
        )
        let user2 = ChatMessage(role: .user, content: "继续展开讲讲性能部分", sortIndex: 3)

        let history = ChatEngine.shared.buildPromptHistory(
            messages: [user1, modelA, modelB, user2],
            limit: 20
        )

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history[0].content, "比较一下 SwiftUI 和 UIKit")
        XCTAssertEqual(history[1].content, "模型 B 被选中的最佳回答")
        XCTAssertEqual(history[2].content, "继续展开讲讲性能部分")
    }

    @MainActor
    func testEditUserMessageAndResendTruncatesSubsequentTurnsAndRegenerates() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let provider = ProviderConfig(
            name: "Local",
            protocolType: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            models: [ModelSpec(id: "qwen")]
        )
        context.insert(provider)
        let conv = Conversation(primaryTarget: provider.makeTarget(for: provider.models[0]))
        context.insert(conv)

        let engine = ChatEngine { req in
            let lastQuestion = req.messages.last?.content ?? ""
            return AsyncThrowingStream { c in
                c.yield(.contentDelta("答复：\(lastQuestion)"))
                c.yield(.done)
                c.finish()
            }
        }

        _ = engine.sendUserMessage(text: "旧提问", attachments: [], in: conv, providers: [provider], context: context)
        while engine.isGenerating(in: conv.id) { try await Task.sleep(for: .milliseconds(10)) }
        _ = engine.sendUserMessage(text: "后续追问", attachments: [], in: conv, providers: [provider], context: context)
        while engine.isGenerating(in: conv.id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(conv.sortedMessages.count, 4)

        let firstUserMsg = try XCTUnwrap(conv.sortedMessages.first)
        let outcome = await engine.editUserMessageAndResend(
            userMessage: firstUserMsg,
            newText: "修改后的提问",
            in: conv,
            providers: [provider],
            context: context
        )
        XCTAssertEqual(outcome, .sent)
        while engine.isGenerating(in: conv.id) { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(conv.sortedMessages.map(\.content), ["修改后的提问", "答复：修改后的提问"])
    }

    func testMarkdownTableTSVExportAndHighlighterCache() {
        let blocks = MarkdownBlockParser.parse("| 指标 | 数值 |\n| --- | --- |\n| TTFT | 180ms |")
        guard case .table(let table) = blocks.first else {
            return XCTFail("Expected MarkdownTable")
        }
        XCTAssertEqual(table.toTSV(), "指标\t数值\nTTFT\t180ms")

        let code = "func greet() -> String { return \"ok\" }"
        let first = SyntaxHighlighter.highlight(code: code)
        let second = SyntaxHighlighter.highlight(code: code)
        XCTAssertEqual(first, second)
    }

    func testAppComplianceAndExportEncryptionInfoPlist() throws {
        let suiteName = "com.iosbox.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppCompliance.hasAcceptedAIDisclosure(defaults: defaults))
        AppCompliance.setAcceptedAIDisclosure(true, defaults: defaults)
        XCTAssertTrue(AppCompliance.hasAcceptedAIDisclosure(defaults: defaults))
        AppCompliance.setAcceptedAIDisclosure(false, defaults: defaults)
        XCTAssertFalse(AppCompliance.hasAcceptedAIDisclosure(defaults: defaults))

        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool,
            false
        )
    }

    func testPrivacyPolicyAndSupportEmailRejectPlaceholdersAndInsecureSchemes() {
        XCTAssertNil(AppCompliance.resolvedPrivacyPolicyURL(from: nil))
        XCTAssertNil(AppCompliance.resolvedPrivacyPolicyURL(from: ""))
        XCTAssertNil(AppCompliance.resolvedPrivacyPolicyURL(from: "https://example.com/privacy"))
        XCTAssertNil(AppCompliance.resolvedPrivacyPolicyURL(from: "https://sub.example.com/privacy"))
        XCTAssertNil(AppCompliance.resolvedPrivacyPolicyURL(from: "http://iosbox.org/privacy"))
        XCTAssertEqual(
            AppCompliance.resolvedPrivacyPolicyURL(from: "https://iosbox.org/privacy")?.absoluteString,
            "https://iosbox.org/privacy"
        )

        XCTAssertNil(AppCompliance.resolvedSupportEmail(from: nil))
        XCTAssertNil(AppCompliance.resolvedSupportEmail(from: "support@example.com"))
        XCTAssertNil(AppCompliance.resolvedSupportEmail(from: "not-an-email"))
        XCTAssertEqual(AppCompliance.resolvedSupportEmail(from: "feedback@iosbox.org"), "feedback@iosbox.org")
    }
}
