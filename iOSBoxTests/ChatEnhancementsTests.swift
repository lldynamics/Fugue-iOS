import XCTest
import SwiftData
@testable import iOSBox

private final class EnhancementCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LLMChatRequest] = []
    func append(_ req: LLMChatRequest) { lock.lock(); defer { lock.unlock() }; values.append(req) }
    var requests: [LLMChatRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private final class EnhancementFixtureURLProtocol: URLProtocol {
    static let lock = NSLock()
    private static var attemptCounts: [String: Int] = [:]
    private static var capturedBodies: [[String: Any]] = []

    static func bodies() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return capturedBodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var bodyData = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                bodyData.append(contentsOf: buf.prefix(n))
            }
        }
        if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            Self.lock.lock(); Self.capturedBodies.append(json); Self.lock.unlock()
        }

        let path = request.url!.path
        Self.lock.lock()
        Self.attemptCounts[path, default: 0] += 1
        let count = Self.attemptCounts[path]!
        Self.lock.unlock()

        var statusCode = 200
        var contentType = "text/event-stream"
        var payload = ""

        if path.contains("anthropic-cache-retry") {
            if count == 1 {
                statusCode = 400
                contentType = "application/json"
                payload = #"{"error":{"message":"Extra inputs are not permitted: cache_control"}}"#
            } else {
                payload = """
                data: {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":40,"cache_creation_input_tokens":8}}}

                data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"CachedOK"}}

                data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

                data: {"type":"message_stop"}


                """
            }
        } else if path.contains("anthropic-tool") {
            payload = """
            data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan search"}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-ant-1"}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_search","input":{}}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"query\\":\\"swift"}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" 6\\"}"}}

            data: {"type":"content_block_stop","index":1}

            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}

            data: {"type":"message_stop"}


            """
        } else if path.contains("openai-tool-cache") {
            payload = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_webpage","arguments":"{\\"url\\":\\"https://example"}}]}}]}

            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":".com\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":15,"prompt_tokens_details":{"cached_tokens":32}}}

            data: [DONE]


            """
        } else if path.contains("gemini-image-tool-cache") {
            payload = """
            data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"propose_memory","args":{"fact":"Uses Swift"}},"thoughtSignature":"sig-123"},{"inlineData":{"mimeType":"image/png","data":"\(onePixelPNGFixture)"}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":30,"candidatesTokenCount":10,"cachedContentTokenCount":20}}


            """
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ChatEnhancementsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    private func makeProvider(name: String = "P1", modelID: String = "m1", protocolType: APIProtocolType = .openAICompatible) -> ProviderConfig {
        var spec = ModelSpec(id: modelID, displayName: modelID.uppercased(), supportsVision: true, supportsReasoning: true)
        spec.inputPricePerMillion = 1.0
        spec.outputPricePerMillion = 2.0
        spec.priceCurrency = "USD"
        let p = ProviderConfig(
            name: name,
            protocolType: protocolType,
            baseURL: "http://localhost:19000/v1",
            models: [spec]
        )
        context.insert(p)
        return p
    }

    private func wait(_ engine: ChatEngine, _ conv: Conversation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while engine.isGenerating(in: conv.id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(engine.isGenerating(in: conv.id))
    }

    // MARK: - Context Divider, Exclusion & Quote

    func testContextDividerExclusionAndQuoteInPromptHistory() {
        let m1 = ChatMessage(role: .user, content: "Old question", sortIndex: 0)
        let m2 = ChatMessage(role: .assistant, content: "Old answer", sortIndex: 1)
        let divider = ChatMessage(role: .system, content: "已清除上文", sortIndex: 2)
        divider.assistanceMetadata.isContextDivider = true
        let m3 = ChatMessage(role: .user, content: "New question", sortIndex: 3)
        m3.assistanceMetadata.quotedExcerpt = "Key sentence"
        let m4 = ChatMessage(role: .assistant, content: "Excluded answer", sortIndex: 4)
        m4.assistanceMetadata.isExcludedFromContext = true
        let m5 = ChatMessage(role: .user, content: "Follow-up", sortIndex: 5)

        let history = ChatEngine.shared.buildPromptHistory(messages: [m1, m2, divider, m3, m4, m5], limit: 20)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history[0].content.hasPrefix("> Key sentence\n\nNew question"))
        XCTAssertEqual(history[1].content, "Follow-up")
    }

    // MARK: - Length Truncation Continuation

    func testContinueGenerationAppendsContentAndAccumulatesTokens() async throws {
        let p = makeProvider()
        let conv = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        context.insert(conv)

        let engine = ChatEngine { req in
            let isContinuation = req.messages.last?.content.contains("Continue writing directly") == true
            return AsyncThrowingStream { c in
                if isContinuation {
                    c.yield(.contentDelta(" part2"))
                    c.yield(.usage(promptTokens: 30, completionTokens: 15))
                } else {
                    c.yield(.contentDelta("part1"))
                    c.yield(.usage(promptTokens: 10, completionTokens: 20))
                    c.yield(.finished(.length))
                }
                c.yield(.done)
                c.finish()
            }
        }

        _ = engine.sendUserMessage(text: "Write a story", attachments: [], in: conv, providers: [p], context: context)
        try await wait(engine, conv)

        let reply = try XCTUnwrap(conv.sortedMessages.last)
        XCTAssertEqual(reply.content, "part1")
        XCTAssertEqual(reply.finishReasonValue, .length)

        engine.continueGeneration(assistantMessage: reply, in: conv, providers: [p], context: context)
        try await wait(engine, conv)

        XCTAssertEqual(reply.content, "part1 part2")
        XCTAssertNil(reply.finishReasonValue)
        XCTAssertEqual(reply.completionTokens, 35)
        XCTAssertEqual(reply.latestRequest?.kind, .continuation)
    }

    // MARK: - Lossless Branching, Revisions & Forking

    func testLosslessBranchingRevisionsAndForking() async throws {
        let p = makeProvider()
        let conv = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        context.insert(conv)

        let counter = LockedCounter()
        let engine = ChatEngine { req in
            let idx = counter.next()
            let lastUser = req.messages.last?.content ?? ""
            return AsyncThrowingStream { c in
                c.yield(.contentDelta("Reply#\(idx) to \(lastUser)"))
                c.yield(.usage(promptTokens: 5, completionTokens: 5))
                c.yield(.done)
                c.finish()
            }
        }

        // Turn 1 + Turn 2
        _ = engine.sendUserMessage(text: "Q1", attachments: [], in: conv, providers: [p], context: context)
        try await wait(engine, conv)
        _ = engine.sendUserMessage(text: "Q2", attachments: [], in: conv, providers: [p], context: context)
        try await wait(engine, conv)
        XCTAssertEqual(conv.messages.count, 4)

        // Edit Q1 with keepBranch = true -> creates Branch 2 without deleting Q1 -> A1 -> Q2 -> A2
        let q1 = try XCTUnwrap(ConversationTree.activeMessages(in: conv).first)
        let outcome = await engine.editUserMessageAndResend(
            userMessage: q1,
            newText: "Q1-edited",
            in: conv,
            providers: [p],
            context: context,
            keepBranch: true
        )
        XCTAssertEqual(outcome, .sent)
        try await wait(engine, conv)

        let activeBranch2 = ConversationTree.activeMessages(in: conv)
        XCTAssertEqual(activeBranch2.map(\.content), ["Q1-edited", "Reply#3 to Q1-edited"])

        let siblings = ConversationTree.branchSiblings(of: activeBranch2[0], in: conv)
        XCTAssertEqual(siblings.map(\.content), ["Q1", "Q1-edited"])

        // Switch back to Q1 branch -> full Q1 -> A1 -> Q2 -> A2 returns
        ConversationTree.switchBranch(to: siblings[0], in: conv)
        let restoredBranch1 = ConversationTree.activeMessages(in: conv)
        XCTAssertEqual(restoredBranch1.map(\.content), ["Q1", "Reply#1 to Q1", "Q2", "Reply#2 to Q2"])

        // Regenerate A2 -> stores revision and allows switching cleanly
        let a2 = restoredBranch1[3]
        engine.regenerate(assistantMessage: a2, in: conv, providers: [p], context: context)
        try await wait(engine, conv)
        XCTAssertEqual(a2.content, "Reply#4 to Q2")
        XCTAssertEqual(a2.assistanceMetadata.revisions.count, 1)

        engine.selectRevision(index: 0, for: a2, context: context)
        XCTAssertEqual(a2.content, "Reply#2 to Q2")
        engine.selectRevision(index: 1, for: a2, context: context)
        XCTAssertEqual(a2.content, "Reply#4 to Q2")
        XCTAssertNil(a2.assistanceMetadata.activeRevisionIndex)

        // Fork up to A1
        let forked = engine.forkConversation(upTo: restoredBranch1[1], in: conv, context: context)
        XCTAssertEqual(forked.sortedMessages.map(\.content), ["Q1", "Reply#1 to Q1"])
    }

    // MARK: - Dynamic Prompt Templates

    func testPromptTemplateVariableRendering() {
        let p = makeProvider(name: "Anthropic", modelID: "claude-sonnet-4", protocolType: .anthropic)
        let target = p.makeTarget(for: p.models[0])
        let fixedDate = Date(timeIntervalSince1970: 1_763_430_000)
        let rendered = PromptTemplateEngine.render(
            "Model={{model}} ID={{model_id}} Provider={{provider}} Date={{date}}",
            target: target,
            now: fixedDate,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertTrue(rendered.contains("Model=CLAUDE-SONNET-4"))
        XCTAssertTrue(rendered.contains("ID=claude-sonnet-4"))
        XCTAssertTrue(rendered.contains("Provider=Anthropic"))
        XCTAssertFalse(rendered.contains("{{"))
    }

    // MARK: - Prompt Caching, Tool Calling & Gemini Native Image

    func testAnthropicPromptCachingRetryAndUsageParsing() async throws {
        let cache = GatewayCapabilityCache(defaults: nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EnhancementFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let req = LLMChatRequest(
            providerName: "Claude",
            protocolType: .anthropic,
            baseURL: "https://fixture.invalid/anthropic-cache-retry/v1",
            apiKey: "sk-test",
            customHeaders: [],
            modelID: "claude-sonnet-4",
            supportsReasoning: false,
            systemPrompt: "System prompt",
            messages: [LLMPromptMessage(role: .user, content: "Hello")],
            temperature: 0.5,
            topP: 1.0,
            maxOutputTokens: 1000,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enablePromptCaching: true
        )

        var events: [LLMStreamEvent] = []
        for try await ev in AnthropicAdapter.streamChat(req, capabilityCache: cache, session: session) {
            events.append(ev)
        }

        XCTAssertTrue(events.contains { if case .retrying(400) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .contentDelta("CachedOK") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .cacheUsage(40, 8) = $0 { return true }; return false })
    }

    func testAllProtocolToolParsingAndGeminiImageOutput() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EnhancementFixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let toolDef = LLMToolDefinition(
            name: "web_search",
            description: "Search",
            parametersSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        )

        // OpenAI tool call + cached_tokens
        let openAIReq = LLMChatRequest(
            providerName: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://fixture.invalid/openai-tool-cache/v1",
            apiKey: "k",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "read")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            tools: [toolDef]
        )
        var openAICall: LLMToolCall?
        var openAICached: Int?
        for try await ev in OpenAICompatibleAdapter.streamChat(openAIReq, session: session) {
            if case .toolCall(let c) = ev { openAICall = c }
            if case .cacheUsage(let cached, _) = ev { openAICached = cached }
        }
        XCTAssertEqual(openAICall?.name, "read_webpage")
        XCTAssertEqual(openAICall?.argumentsDictionary["url"] as? String, "https://example.com")
        XCTAssertEqual(openAICached, 32)

        // Anthropic tool_use delta assembly
        let claudeReq = LLMChatRequest(
            providerName: "Anthropic",
            protocolType: .anthropic,
            baseURL: "https://fixture.invalid/anthropic-tool/v1",
            apiKey: "k",
            customHeaders: [],
            modelID: "claude-sonnet-4",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "search")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            tools: [toolDef]
        )
        var claudeCall: LLMToolCall?
        var claudeThinkingBlock: LLMThinkingBlock?
        for try await ev in AnthropicAdapter.streamChat(claudeReq, session: session) {
            if case .toolCall(let c) = ev { claudeCall = c }
            if case .thinkingBlock(let tb) = ev { claudeThinkingBlock = tb }
        }
        XCTAssertEqual(claudeCall?.id, "toolu_1")
        XCTAssertEqual(claudeCall?.argumentsDictionary["query"] as? String, "swift 6")
        XCTAssertEqual(claudeThinkingBlock?.thinking, "Plan search")
        XCTAssertEqual(claudeThinkingBlock?.signature, "sig-ant-1")

        // Gemini functionCall + inlineData image + cachedContentTokenCount
        let geminiReq = LLMChatRequest(
            providerName: "Gemini",
            protocolType: .gemini,
            baseURL: "https://fixture.invalid/gemini-image-tool-cache/v1beta",
            apiKey: "k",
            customHeaders: [],
            modelID: "gemini-2.5-flash",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "draw")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            tools: [toolDef]
        )
        var geminiCall: LLMToolCall?
        var geminiImage: MessageAttachment?
        var geminiCached: Int?
        for try await ev in GeminiAdapter.streamChat(geminiReq, session: session) {
            if case .toolCall(let c) = ev { geminiCall = c }
            if case .attachmentDelta(let att) = ev { geminiImage = att }
            if case .cacheUsage(let cached, _) = ev { geminiCached = cached }
        }
        XCTAssertEqual(geminiCall?.name, "propose_memory")
        XCTAssertEqual(geminiCall?.thoughtSignature, "sig-123")
        XCTAssertEqual(geminiImage?.mimeType, "image/png")
        XCTAssertEqual(geminiCached, 20)
    }

    func testAgentToolLoopRequiresUserConsentBeforeSavingMemory() async throws {
        let p = makeProvider()
        let conv = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        conv.assistanceSettings.enableAgentTools = true
        context.insert(conv)

        let capture = EnhancementCapture()
        let turnCounter = LockedCounter()
        let engine = ChatEngine(
            search: { query in
                SearchEvidence(query: query, searchedAt: Date(), sources: [
                    SearchSource(id: 1, title: "Docs", url: URL(string: "https://example.com/docs")!, snippet: "Swift")
                ], credits: 1)
            },
            stream: { req in
                capture.append(req)
                let currentTurn = turnCounter.next()
                return AsyncThrowingStream { c in
                    if currentTurn == 1 {
                        c.yield(.toolCall(LLMToolCall(
                            id: "tc1",
                            name: "propose_memory",
                            argumentsJSON: #"{"fact":"Prefers Swift 6 concurrency"}"#
                        )))
                    } else {
                        c.yield(.contentDelta("Done with proposal."))
                    }
                    c.yield(.done)
                    c.finish()
                }
            }
        )

        _ = engine.sendUserMessage(text: "Remember I use Swift 6", attachments: [], in: conv, providers: [p], context: context)
        try await wait(engine, conv)

        XCTAssertEqual(capture.requests.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalMemory>()), 0, "must never auto-save without explicit user confirmation")

        let reply = try XCTUnwrap(conv.sortedMessages.last)
        XCTAssertEqual(reply.content, "Done with proposal.")
        XCTAssertEqual(reply.assistanceMetadata.proposedMemories, ["Prefers Swift 6 concurrency"])
        XCTAssertEqual(reply.assistanceMetadata.toolCalls.count, 1)

        engine.acceptMemoryProposal("Prefers Swift 6 concurrency", on: reply, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalMemory>()), 1)
        XCTAssertTrue(reply.assistanceMetadata.proposedMemories.isEmpty)
    }

    // MARK: - Arena Compare Promotion, Cross Critique & Blind Mode

    func testOptedInLiveActivityStreamsTheAnswerAndKeepsReasoningPrivate() async throws {
        let provider = makeProvider()
        let chat = Conversation(title: "Private chat", primaryTarget: provider.makeTarget(for: provider.models[0]))
        context.insert(chat)
        let live = LiveActivityCoordinator.shared
        let originalPreference = live.showsPreviews
        live.setShowsPreviews(true)
        defer { live.setShowsPreviews(originalPreference) }
        let started = expectation(description: "Stream started")
        let (events, output) = AsyncThrowingStream<LLMStreamEvent, Error>.makeStream()
        let engine = ChatEngine { _ in started.fulfill(); return events }
        defer { output.finish(); engine.stopGeneration(for: chat.id) }
        XCTAssertEqual(engine.sendUserMessage(text: "Question", attachments: [], in: chat,
                                              providers: [provider], context: context), .sent)
        await fulfillment(of: [started], timeout: 5)
        let reply = try XCTUnwrap(chat.sortedMessages.last)
        // Allow the activity's throttled update window to open before each distinct phase.
        try await Task.sleep(for: .milliseconds(1250))
        output.yield(.reasoningDelta("Private reasoning"))
        for _ in 0..<100 where reply.reasoningContent.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reply.reasoningContent, "Private reasoning")
        let thinking = try XCTUnwrap(live.activeStates[chat.id])
        XCTAssertEqual(thinking.phaseText, String(localized: "深度思考中…"))
        XCTAssertNil(thinking.visibleSnippet)
        try await Task.sleep(for: .milliseconds(1250))
        output.yield(.contentDelta("Visible reply"))
        for _ in 0..<100 where reply.content.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(live.activeStates[chat.id]?.visibleSnippet, "Visible reply")
        output.yield(.done)
        output.finish()
        try await wait(engine, chat)
    }

    func testCompareWithAnotherModelCreatesComparisonGroup() async throws {
        let p1 = makeProvider(name: "P1", modelID: "m1")
        let p2 = makeProvider(name: "P2", modelID: "m2")
        let conv = Conversation(primaryTarget: p1.makeTarget(for: p1.models[0]))
        context.insert(conv)

        let engine = ChatEngine { req in
            AsyncThrowingStream { c in
                c.yield(.contentDelta("From \(req.modelID)"))
                c.yield(.usage(promptTokens: 5, completionTokens: 5))
                c.yield(.done)
                c.finish()
            }
        }

        _ = engine.sendUserMessage(text: "Compare test", attachments: [], in: conv, providers: [p1, p2], context: context)
        try await wait(engine, conv)

        let firstReply = try XCTUnwrap(conv.sortedMessages.last)
        engine.compareWithAnotherModel(
            assistantMessage: firstReply,
            secondTarget: p2.makeTarget(for: p2.models[0]),
            in: conv,
            providers: [p1, p2],
            context: context
        )
        try await wait(engine, conv)

        let gid = try XCTUnwrap(firstReply.comparisonGroupID)
        let groupMsgs = conv.sortedMessages.filter { $0.comparisonGroupID == gid }
        XCTAssertEqual(groupMsgs.count, 2)

        try engine.selectContextReply(groupMsgs[1], in: conv, context: context)
        XCTAssertTrue(groupMsgs[1].isSelectedInGroup)
        engine.regenerate(assistantMessage: groupMsgs[1], in: conv, providers: [p1, p2], context: context)
        try await wait(engine, conv)
        XCTAssertEqual(groupMsgs[1].content, "From m2")
    }

    // MARK: - Markdown Export & Offline Artifact Builder

    func testMarkdownExportAndOfflineArtifactGeneration() {
        let p = makeProvider()
        let conv = Conversation(title: "导出测试", primaryTarget: p.makeTarget(for: p.models[0]))
        context.insert(conv)
        let u = ChatMessage(role: .user, content: "Hello", sortIndex: 0)
        u.assistanceMetadata.quotedExcerpt = "Excerpt"
        let a = ChatMessage(role: .assistant, content: "World", reasoningContent: "Thought", target: p.makeTarget(for: p.models[0]), sortIndex: 1)
        u.conversation = conv
        a.conversation = conv
        conv.messages = [u, a]

        let md = ConversationExporter.makeMarkdown(for: conv)
        XCTAssertTrue(md.contains("# 导出测试"))
        XCTAssertTrue(md.contains("> Excerpt"))
        XCTAssertTrue(md.contains("<details><summary>\(String(localized: "思考过程"))</summary>"))

        let mermaidHTML = ArtifactDocumentBuilder.htmlDocument(language: "mermaid", code: "flowchart TD\nA[Start] --> B[End]")
        XCTAssertTrue(mermaidHTML.contains("flowchart TD"))
        XCTAssertTrue(mermaidHTML.contains("Content-Security-Policy"))
        XCTAssertFalse(mermaidHTML.contains("https://"))

        let svgHTML = ArtifactDocumentBuilder.htmlDocument(language: "svg", code: "<svg><script>alert(1)</script><circle r='5'/></svg>")
        XCTAssertFalse(svgHTML.contains("<script>"))
        XCTAssertFalse(ArtifactDocumentBuilder.allowsJavaScript(for: "svg"))
        XCTAssertTrue(ArtifactDocumentBuilder.allowsJavaScript(for: "html"))
    }

    // MARK: - Review Audit Regressions

    func testThinkingWithToolCallsPreservesAnthropicSignaturesAndOpenAIReasoning() throws {
        let signedBlock = LLMThinkingBlock(thinking: "Deep plan", signature: "sig-xyz")
        let toolCall = LLMToolCall(id: "t1", name: "web_search", argumentsJSON: #"{"query":"swift"}"#)

        // 1. Anthropic with signed thinking block keeps thinking enabled and prepends thinking block
        let claudeSigned = AnthropicAdapter.buildRequestBody(LLMChatRequest(
            providerName: "Anthropic",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "k",
            customHeaders: [],
            modelID: "claude-sonnet-4-6",
            supportsReasoning: true,
            systemPrompt: "Sys",
            messages: [
                LLMPromptMessage(role: .user, content: "Q"),
                LLMPromptMessage(role: .assistant, content: "", thinkingBlocks: [signedBlock], toolCalls: [toolCall]),
                LLMPromptMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "t1", toolName: "web_search")
            ],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: true,
            thinkingBudgetTokens: 4096
        ))
        XCTAssertNotNil(claudeSigned["thinking"])
        let wireMsgs = try XCTUnwrap(claudeSigned["messages"] as? [[String: Any]])
        let assistantBlocks = try XCTUnwrap(wireMsgs[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.first?["type"] as? String, "thinking")
        XCTAssertEqual(assistantBlocks.first?["signature"] as? String, "sig-xyz")
        XCTAssertEqual(assistantBlocks.last?["type"] as? String, "tool_use")

        // 2. Anthropic degrades gracefully if an upstream proxy stripped signature on an earlier round
        let claudeUnsigned = AnthropicAdapter.buildRequestBody(LLMChatRequest(
            providerName: "Anthropic",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "k",
            customHeaders: [],
            modelID: "claude-sonnet-4-6",
            supportsReasoning: true,
            systemPrompt: "Sys",
            messages: [
                LLMPromptMessage(role: .user, content: "Q"),
                LLMPromptMessage(role: .assistant, content: "", thinkingBlocks: [], toolCalls: [toolCall]),
                LLMPromptMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "t1", toolName: "web_search")
            ],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: true,
            thinkingBudgetTokens: 4096
        ))
        XCTAssertNil(claudeUnsigned["thinking"], "must disable thinking when tool_use turn lacks signature to avoid HTTP 400")

        // 3. DeepSeek / OpenAI-compatible reasoning_content preserved on assistant tool_calls message
        let deepseekBody = OpenAICompatibleAdapter.buildRequestBody(LLMChatRequest(
            providerName: "DeepSeek",
            protocolType: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "k",
            customHeaders: [],
            modelID: "deepseek-reasoner",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [
                LLMPromptMessage(role: .user, content: "Q"),
                LLMPromptMessage(role: .assistant, content: "", reasoningContent: "Step-by-step", toolCalls: [toolCall]),
                LLMPromptMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "t1", toolName: "web_search")
            ],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: true,
            thinkingBudgetTokens: 4096
        ))
        let dsWire = try XCTUnwrap(deepseekBody["messages"] as? [[String: Any]])
        XCTAssertEqual(dsWire[1]["reasoning_content"] as? String, "Step-by-step")
    }

    func testRepeatedCacheUsageChunksDoNotInflateCachedTokensAndRegenerateKeepsToolsAndClearsAttachments() async throws {
        let p = makeProvider()
        let conv = Conversation(primaryTarget: p.makeTarget(for: p.models[0]))
        conv.assistanceSettings.enableAgentTools = true
        conv.assistanceSettings.enablePromptCaching = true
        context.insert(conv)

        let capture = EnhancementCapture()
        let runCounter = LockedCounter()
        let img1 = MessageAttachment(kind: .image, fileName: "gen1.png", mimeType: "image/png", dataBase64: onePixelPNGFixture, byteSize: 70)

        let engine = ChatEngine { req in
            capture.append(req)
            let run = runCounter.next()
            return AsyncThrowingStream { c in
                if run == 1 {
                    c.yield(.contentDelta("part1"))
                    c.yield(.attachmentDelta(img1))
                    c.yield(.cacheUsage(cachedTokens: 20, cacheWriteTokens: nil))
                    c.yield(.cacheUsage(cachedTokens: 20, cacheWriteTokens: nil))
                    c.yield(.finished(.length))
                    c.yield(.done)
                    c.finish()
                } else if run == 2 {
                    // Continuation with multiple Gemini-style chunks repeating cachedTokens = 50
                    c.yield(.contentDelta(" part2"))
                    c.yield(.cacheUsage(cachedTokens: 50, cacheWriteTokens: nil))
                    c.yield(.cacheUsage(cachedTokens: 50, cacheWriteTokens: nil))
                    c.yield(.cacheUsage(cachedTokens: 50, cacheWriteTokens: nil))
                    c.yield(.done)
                    c.finish()
                } else {
                    // Failed regeneration
                    c.finish(throwing: LLMError.httpError(500, "boom"))
                }
            }
        }

        _ = engine.sendUserMessage(text: "Draw", attachments: [], in: conv, providers: [p], context: context)
        try await wait(engine, conv)
        XCTAssertTrue(capture.requests[0].enablePromptCaching, "prompt caching must stay active when agent tools are enabled")
        XCTAssertFalse(capture.requests[0].tools.isEmpty)

        let reply = try XCTUnwrap(conv.sortedMessages.last)
        XCTAssertEqual(reply.cachedTokens, 20)
        XCTAssertEqual(reply.attachments.count, 1)

        engine.continueGeneration(assistantMessage: reply, in: conv, providers: [p], context: context)
        try await wait(engine, conv)
        XCTAssertEqual(reply.cachedTokens, 70, "20 + 50, never multiplied by chunk count")

        // Regenerate keeps tools, clears old attachment, and failed attempt does not pollute revisions
        engine.regenerate(assistantMessage: reply, in: conv, providers: [p], context: context)
        try await wait(engine, conv)
        XCTAssertFalse(capture.requests.last!.tools.isEmpty, "regenerate must preserve agent tools")
        XCTAssertTrue(reply.attachments.isEmpty, "regenerate must clear previous generated attachments")
        XCTAssertEqual(reply.assistanceMetadata.revisions.count, 1)

        // Switching back to revision 0 restores previous content & image without adding an empty revision
        engine.selectRevision(index: 0, for: reply, context: context)
        XCTAssertEqual(reply.content, "part1 part2")
        XCTAssertEqual(reply.attachments.count, 1)
        XCTAssertTrue(reply.assistanceMetadata.revisions.isEmpty)
        XCTAssertNil(reply.assistanceMetadata.activeRevisionIndex)
    }

    func testArenaSynthesisPromptAndGeminiImageReplay() throws {
        let p1 = makeProvider(name: "VendorA", modelID: "model-alpha")
        let p2 = makeProvider(name: "VendorB", modelID: "model-beta")
        let conv = Conversation(title: "ArenaTest", isArenaMode: true, arenaTargets: [
            p1.makeTarget(for: p1.models[0]),
            p2.makeTarget(for: p2.models[0])
        ])
        context.insert(conv)

        let u = ChatMessage(role: .user, content: "Compare", sortIndex: 0)
        let gid = UUID()
        let m1 = ChatMessage(role: .assistant, content: "Ans1", target: p1.makeTarget(for: p1.models[0]), comparisonGroupID: gid, isSelectedInGroup: true, sortIndex: 1)
        let m2 = ChatMessage(role: .assistant, content: "Ans2", target: p2.makeTarget(for: p2.models[0]), comparisonGroupID: gid, isSelectedInGroup: false, sortIndex: 2)
        for m in [u, m1, m2] { m.conversation = conv; conv.messages.append(m); context.insert(m) }

        let synthPrompt = ArenaSynthesis.candidatePrompt([m1, m2], totalCount: 2)
        let md = ConversationExporter.makeMarkdown(for: conv)

        for label in ["VendorA", "VendorB", "Ans1", "Ans2"] {
            XCTAssertTrue(synthPrompt.contains(label), "synthesis prompt missing \(label)")
            XCTAssertTrue(md.contains(label), "markdown export missing \(label)")
        }

        // Gemini multi-turn replays assistant-generated image inlineData
        let genImg = MessageAttachment(kind: .image, fileName: "generated.png", mimeType: "image/png", dataBase64: onePixelPNGFixture, byteSize: 70)
        let geminiBody = GeminiAdapter.buildRequestBody(LLMChatRequest(
            providerName: "Gemini",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "k",
            customHeaders: [],
            modelID: "gemini-2.5-flash",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [
                LLMPromptMessage(role: .user, content: "Draw a cat"),
                LLMPromptMessage(role: .assistant, content: "", attachments: [genImg]),
                LLMPromptMessage(role: .user, content: "Make the background blue")
            ],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        ))
        let contents = try XCTUnwrap(geminiBody["contents"] as? [[String: Any]])
        let modelParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        XCTAssertNotNil(modelParts.first?["inlineData"], "assistant generated image must be replayed in Gemini multi-turn context")
    }
}
