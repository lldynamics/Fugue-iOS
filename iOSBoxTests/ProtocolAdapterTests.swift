import XCTest
@testable import iOSBox

/// Request-body construction and stream-parsing rules for the three protocol adapters.
final class ProtocolAdapterTests: XCTestCase {

    private func makeRequest(
        protocolType: APIProtocolType = .openAICompatible,
        baseURL: String = "https://api.openai.com/v1",
        modelID: String,
        supportsReasoning: Bool = false,
        temperature: Double? = 0.7,
        topP: Double = 0.9,
        maxOutputTokens: Int? = nil,
        enableThinking: Bool = true,
        thinkingBudgetTokens: Int = 4096,
        systemPrompt: String = "",
        messages: [LLMPromptMessage] = [LLMPromptMessage(role: .user, content: "hi", attachments: [])]
    ) -> LLMChatRequest {
        LLMChatRequest(
            providerName: "Test",
            protocolType: protocolType,
            baseURL: baseURL,
            apiKey: "sk-test",
            customHeaders: [],
            modelID: modelID,
            supportsReasoning: supportsReasoning,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            enableThinking: enableThinking,
            thinkingBudgetTokens: thinkingBudgetTokens
        )
    }

    // MARK: - OpenAI compatible

    func testOpenAIRequestsUsageInStream() {
        let body = OpenAICompatibleAdapter.buildRequestBody(makeRequest(modelID: "gpt-4.1"))
        let options = body["stream_options"] as? [String: Any]
        XCTAssertEqual(options?["include_usage"] as? Bool, true)

        let fallback = OpenAICompatibleAdapter.buildRequestBody(makeRequest(modelID: "gpt-4.1"), includeUsageOption: false)
        XCTAssertNil(fallback["stream_options"])
    }

    func testOpenAIRegularModelKeepsSamplingAndMaxTokens() {
        let body = OpenAICompatibleAdapter.buildRequestBody(makeRequest(modelID: "gpt-4.1", maxOutputTokens: 2000))
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertEqual(body["top_p"] as? Double, 0.9)
        XCTAssertEqual(body["max_tokens"] as? Int, 2000)
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertNil(body["reasoning_effort"])
    }

    func testOpenAIReasoningModelsUseMaxCompletionTokensAndDropSampling() {
        for model in ["o3-mini", "o4-mini", "gpt-5", "gpt-5-mini", "gpt-6.2-sol", "gpt-6.2-astra"] {
            let body = OpenAICompatibleAdapter.buildRequestBody(
                makeRequest(modelID: model, supportsReasoning: true, maxOutputTokens: 3000)
            )
            XCTAssertNil(body["temperature"], model)
            XCTAssertNil(body["top_p"], model)
            XCTAssertNil(body["max_tokens"], model)
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 3000, model)
            XCTAssertEqual(body["reasoning_effort"] as? String, "medium", model)
        }
    }

    func testGPT5ChatVariantIsNotTreatedAsReasoningModel() {
        let body = OpenAICompatibleAdapter.buildRequestBody(
            makeRequest(modelID: "gpt-5-chat-latest", supportsReasoning: true, maxOutputTokens: 1000)
        )
        XCTAssertEqual(body["temperature"] as? Double, 0.7)
        XCTAssertEqual(body["max_tokens"] as? Int, 1000)
        XCTAssertNil(body["reasoning_effort"])
    }

    func testReasoningEffortFollowsThinkingSwitchAndBudget() {
        func effort(_ enable: Bool, _ budget: Int) -> String? {
            OpenAICompatibleAdapter.reasoningParameters(
                for: makeRequest(modelID: "o3", supportsReasoning: true, enableThinking: enable, thinkingBudgetTokens: budget)
            )["reasoning_effort"] as? String
        }
        XCTAssertEqual(effort(false, 32_768), "low")
        XCTAssertEqual(effort(true, 2048), "low")
        XCTAssertEqual(effort(true, 8192), "medium")
        XCTAssertEqual(effort(true, 16_384), "high")
    }

    func testOpenRouterUsesUnifiedReasoningParameterAndMaxTokens() {
        let req = makeRequest(
            baseURL: "https://openrouter.ai/api/v1",
            modelID: "openai/o3",
            supportsReasoning: true,
            maxOutputTokens: 5000,
            thinkingBudgetTokens: 6000
        )
        let body = OpenAICompatibleAdapter.buildRequestBody(req)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["max_tokens"] as? Int, 6000)
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(body["max_tokens"] as? Int, 5000)
        XCTAssertNil(body["temperature"], "o-series via OpenRouter still must not get temperature")
    }

    func testQwen3HybridGetsEnableThinkingButFixedModeVariantsDoNot() {
        let hybrid = OpenAICompatibleAdapter.reasoningParameters(
            for: makeRequest(baseURL: "https://api.siliconflow.cn/v1", modelID: "Qwen/Qwen3-32B", supportsReasoning: true, enableThinking: false)
        )
        XCTAssertEqual(hybrid["enable_thinking"] as? Bool, false)
        XCTAssertNil(hybrid["thinking_budget"])

        let instruct = OpenAICompatibleAdapter.reasoningParameters(
            for: makeRequest(modelID: "Qwen/Qwen3-235B-A22B-Instruct-2507", supportsReasoning: true)
        )
        XCTAssertTrue(instruct.isEmpty)
    }

    func testNoReasoningParametersWhenModelNotFlagged() {
        let params = OpenAICompatibleAdapter.reasoningParameters(for: makeRequest(modelID: "o3", supportsReasoning: false))
        XCTAssertTrue(params.isEmpty)
    }

    // MARK: - Anthropic

    func testAnthropicThinkingIsDrivenByModelFlag() {
        let unflagged = AnthropicAdapter.buildRequestBody(
            makeRequest(protocolType: .anthropic, modelID: "claude-sonnet-4-5", supportsReasoning: false)
        )
        XCTAssertNil(unflagged["thinking"])

        let flagged = AnthropicAdapter.buildRequestBody(
            makeRequest(protocolType: .anthropic, modelID: "claude-haiku-4-5", supportsReasoning: true)
        )
        let thinking = flagged["thinking"] as? [String: Any]
        XCTAssertEqual(thinking?["type"] as? String, "enabled")
        XCTAssertNil(flagged["temperature"])
    }

    func testAnthropicThinkingTokensStayWithinCapAndBelowMaxTokens() {
        let body = AnthropicAdapter.buildRequestBody(
            makeRequest(protocolType: .anthropic, modelID: "claude-opus-4", supportsReasoning: true, thinkingBudgetTokens: 32_768)
        )
        let maxTokens = body["max_tokens"] as? Int ?? 0
        let budget = (body["thinking"] as? [String: Any])?["budget_tokens"] as? Int ?? 0
        XCTAssertLessThanOrEqual(maxTokens, AnthropicAdapter.thinkingOutputCap)
        XCTAssertLessThan(budget, maxTokens)
        XCTAssertGreaterThanOrEqual(budget, 1024)
    }

    func testAnthropicRespectsExplicitLargeMaxTokensWithThinking() {
        let body = AnthropicAdapter.buildRequestBody(
            makeRequest(protocolType: .anthropic, modelID: "claude-sonnet-4", supportsReasoning: true, maxOutputTokens: 64_000)
        )
        XCTAssertEqual(body["max_tokens"] as? Int, 64_000)
    }

    func testAnthropicDefaultMaxTokens() {
        XCTAssertEqual(AnthropicAdapter.defaultMaxTokens(for: "claude-sonnet-4-20250514"), 8192)
        XCTAssertEqual(AnthropicAdapter.defaultMaxTokens(for: "claude-3-5-haiku-latest"), 8192)
        XCTAssertEqual(AnthropicAdapter.defaultMaxTokens(for: "claude-3-haiku-20240307"), 4096)

        let body = AnthropicAdapter.buildRequestBody(
            makeRequest(protocolType: .anthropic, modelID: "claude-sonnet-4", supportsReasoning: true, enableThinking: false)
        )
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertNil(body["thinking"])
    }

    // MARK: - Gemini

    func testGemini25ThinkingBudgetAndDisable() {
        let on = GeminiAdapter.thinkingConfig(for: makeRequest(protocolType: .gemini, modelID: "gemini-2.5-flash", thinkingBudgetTokens: 40_000))
        XCTAssertEqual(on?["includeThoughts"] as? Bool, true)
        XCTAssertEqual(on?["thinkingBudget"] as? Int, 24_576, "Flash budget is clamped to its maximum")

        let flashOff = GeminiAdapter.thinkingConfig(for: makeRequest(protocolType: .gemini, modelID: "gemini-2.5-flash", enableThinking: false))
        XCTAssertEqual(flashOff?["thinkingBudget"] as? Int, 0)

        let proOff = GeminiAdapter.thinkingConfig(for: makeRequest(protocolType: .gemini, modelID: "gemini-2.5-pro", enableThinking: false))
        XCTAssertNil(proOff, "2.5 Pro can't disable thinking; keep its default")
    }

    func testGemini3UsesThinkingLevelNotBudget() {
        let config = GeminiAdapter.thinkingConfig(for: makeRequest(protocolType: .gemini, modelID: "gemini-3-pro-preview", thinkingBudgetTokens: 16_384))
        XCTAssertEqual(config?["thinkingLevel"] as? String, "high")
        XCTAssertNil(config?["thinkingBudget"])
    }

    func testCurrentSuggestedModelsSendCompatibleThinkingParameters() {
        for enabled in [true, false] {
            let gemini = GeminiAdapter.thinkingConfig(for: makeRequest(protocolType: .gemini, modelID: "gemini-4-neon", enableThinking: enabled))
            XCTAssertNotNil(gemini?["thinkingLevel"])
            XCTAssertNil(gemini?["thinkingBudget"])
            let claude = AnthropicAdapter.buildRequestBody(makeRequest(protocolType: .anthropic, modelID: "claude-sonnet-5-5", supportsReasoning: true, enableThinking: enabled))
            XCTAssertEqual(claude["temperature"] as? Double, enabled ? nil : 0.7)
            let thinking = claude["thinking"] as? [String: Any]
            XCTAssertEqual(thinking?["type"] as? String, enabled ? "adaptive" : nil)
            XCTAssertNil(thinking?["budget_tokens"])
            let deepseek = OpenAICompatibleAdapter.buildRequestBody(makeRequest(baseURL: "https://api.deepseek.com/v1",
                                                                                modelID: "deepseek-flash", supportsReasoning: true, enableThinking: enabled))
            XCTAssertEqual((deepseek["thinking"] as? [String: String])?["type"], enabled ? "enabled" : "disabled")
        }
    }

    func testGeminiNonThinkingModelGetsNoThinkingConfig() {
        XCTAssertNil(GeminiAdapter.thinkingConfig(for: makeRequest(protocolType: .gemini, modelID: "gemini-2.0-flash")))
    }

    // MARK: - Finish reasons

    func testFinishReasonMapping() {
        XCTAssertEqual(LLMFinishReason.fromProviderValue("length"), .length)          // OpenAI
        XCTAssertEqual(LLMFinishReason.fromProviderValue("max_tokens"), .length)      // Anthropic
        XCTAssertEqual(LLMFinishReason.fromProviderValue("MAX_TOKENS"), .length)      // Gemini
        XCTAssertEqual(LLMFinishReason.fromProviderValue("content_filter"), .contentFilter)
        XCTAssertEqual(LLMFinishReason.fromProviderValue("refusal"), .contentFilter)
        XCTAssertEqual(LLMFinishReason.fromProviderValue("SAFETY"), .contentFilter)
        XCTAssertNil(LLMFinishReason.fromProviderValue("stop"))
        XCTAssertNil(LLMFinishReason.fromProviderValue("end_turn"))
        XCTAssertNil(LLMFinishReason.fromProviderValue("STOP"))
        XCTAssertNil(LLMFinishReason.fromProviderValue(nil))
    }

    // MARK: - <think> parsing

    private func run(_ chunks: [String]) -> (reasoning: String, content: String) {
        var parser = ThinkTagStreamParser()
        var reasoning = ""
        var content = ""
        for seg in chunks.flatMap({ parser.feed($0) }) + parser.finish() {
            switch seg {
            case .reasoning(let r): reasoning += r
            case .content(let c): content += c
            }
        }
        return (reasoning, content)
    }

    func testThinkTagMentionedMidAnswerStaysContent() {
        let answer = "要解析推理模型输出，可以查找 <think> 标签，直到 </think> 结束。"
        let result = run(["要解析推理模型输出，可以查找 <th", "ink> 标签，直到 </think> 结束。"])
        XCTAssertEqual(result.reasoning, "")
        XCTAssertEqual(result.content, answer)
    }

    func testThinkTagAfterLeadingWhitespaceIsRecognized() {
        let result = run(["\n\n  <thinking>", "想一想</thinking>\n答案"])
        XCTAssertEqual(result.reasoning, "想一想")
        XCTAssertEqual(result.content, "答案")
    }

    func testOnlyFirstThinkBlockIsExtracted() {
        let result = run(["<think>推理</think>正文里再写 <think>不是推理</think>"])
        XCTAssertEqual(result.reasoning, "推理")
        XCTAssertEqual(result.content, "正文里再写 <think>不是推理</think>")
    }

    func testUnclosedThinkBlockIsReasoningAndPlainTextIsContent() {
        XCTAssertEqual(run(["<think>还没想完"]).reasoning, "还没想完")
        XCTAssertEqual(run(["<", "b>粗体</b>"]).content, "<b>粗体</b>")
    }

    func testOpenAIAndGeminiNormalizeLeadingAssistantAndConsecutiveRoles() throws {
        let messages = [
            LLMPromptMessage(role: .assistant, content: "First answer", attachments: []),
            LLMPromptMessage(role: .assistant, content: "Second answer", attachments: []),
            LLMPromptMessage(role: .user, content: "Follow-up", attachments: []),
            LLMPromptMessage(role: .user, content: "More detail", attachments: [])
        ]

        let openAIBody = OpenAICompatibleAdapter.buildRequestBody(
            makeRequest(protocolType: .openAICompatible, modelID: "deepseek-reasoner", systemPrompt: "Sys", messages: messages)
        )
        let wire = try XCTUnwrap(openAIBody["messages"] as? [[String: Any]])
        XCTAssertEqual(wire.compactMap { $0["role"] as? String }, ["system", "user", "assistant", "user"])
        XCTAssertEqual(wire[1]["content"] as? String, String(localized: "继续"))
        XCTAssertEqual(wire[2]["content"] as? String, "First answer\n\nSecond answer")
        XCTAssertEqual(wire[3]["content"] as? String, "Follow-up\n\nMore detail")

        let imgAttachment = MessageAttachment(kind: .image, fileName: "pic.jpg", mimeType: "image/jpeg", dataBase64: "QUJD", byteSize: 3)
        let multimodalOpenAI = OpenAICompatibleAdapter.buildRequestBody(
            makeRequest(
                protocolType: .openAICompatible,
                modelID: "gpt-4.1",
                messages: [
                    LLMPromptMessage(role: .user, content: "Part 1", attachments: []),
                    LLMPromptMessage(role: .user, content: "Part 2", attachments: [imgAttachment])
                ]
            )
        )
        let multiWire = try XCTUnwrap(multimodalOpenAI["messages"] as? [[String: Any]])
        XCTAssertEqual(multiWire.count, 1)
        let mergedParts = try XCTUnwrap(multiWire[0]["content"] as? [[String: Any]])
        XCTAssertEqual(mergedParts.count, 3)

        let geminiBody = GeminiAdapter.buildRequestBody(
            makeRequest(protocolType: .gemini, modelID: "gemini-2.5-flash", messages: messages)
        )
        let contents = try XCTUnwrap(geminiBody["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.compactMap { $0["role"] as? String }, ["user", "model", "user"])
        let leadingParts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(leadingParts.first?["text"] as? String, String(localized: "继续"))
        XCTAssertEqual((contents[1]["parts"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((contents[2]["parts"] as? [[String: Any]])?.count, 2)
    }
}

extension ProtocolAdapterTests {
    @MainActor
    func testReviewedPDFUsesTheSelectedFormatAcrossAllFourAdapters() throws {
        let pdf = MessageAttachment(kind: .document, fileName: "original.pdf", mimeType: "application/pdf",
                                    dataBase64: "UEZERklMRQ==", extractedText: "UNCORRECTED_SOURCE", byteSize: 7)
        let review = DraftAttachmentReview(sources: [pdf], recognize: false)
        for format in AttachmentSendFormat.allCases {
            let reviewed = try review.applying(format, text: "CORRECTED_WORDS", coverage: nil, to: [pdf])
            let request = makeRequest(modelID: "test", messages: [.init(role: .user, content: "Read", attachments: reviewed)])
            let bodies = [OpenAICompatibleAdapter.buildRequestBody(request), OpenAIResponsesAdapter.buildRequestBody(request),
                          AnthropicAdapter.buildRequestBody(request), GeminiAdapter.buildRequestBody(request)]
            for body in bodies {
                let wire = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
                XCTAssertEqual(wire.contains("UEZERklMRQ=="), format != .text)
                XCTAssertEqual(wire.contains("CORRECTED_WORDS"), format != .original)
                XCTAssertFalse(wire.contains("UNCORRECTED_SOURCE"))
            }
        }
    }
}
