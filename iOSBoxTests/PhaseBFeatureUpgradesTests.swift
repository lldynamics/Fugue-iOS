import SwiftData
import XCTest
@testable import iOSBox

private final class PhaseBMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
            copy.httpBody = data
        }
        do {
            let (resp, data) = try handler(copy)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class PhaseBFeatureUpgradesTests: XCTestCase {
    private var containers: [ModelContainer] = []

    override func tearDown() {
        PhaseBMockURLProtocol.handler = nil
        containers.removeAll()
        super.tearDown()
    }

    private func makeMockSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [PhaseBMockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        containers.append(container)
        return container
    }

    // MARK: - 1. WebDAV PROPFIND XML Parsing & Orphan Blob GC

    func testWebDAVPropfindParserAndOrphanBlobGC() async throws {
        let activeHash = String(repeating: "a", count: 64)
        let orphanHash = String(repeating: "b", count: 64)
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/Fugue/fugue-sync.shards/blobs/</D:href></D:response>
          <D:response><D:href>/dav/Fugue/fugue-sync.shards/blobs/\(activeHash).enc.bin</D:href></D:response>
          <D:response><D:href>/dav/Fugue/fugue-sync.shards/blobs/\(orphanHash).enc.bin</D:href></D:response>
        </D:multistatus>
        """
        let parsed = WebDAVSyncService.parsePropfindChildNames(
            xmlData: Data(xml.utf8),
            directoryPath: "/dav/Fugue/fugue-sync.shards/blobs"
        )
        XCTAssertEqual(parsed, ["\(activeHash).enc.bin", "\(orphanHash).enc.bin"])

        let container = try makeInMemoryContainer()
        let book = BookVolume(
            id: UUID(),
            title: "GC Test Book",
            chapterTitles: ["Ch1"],
            manuscript: try JSONEncoder().encode([BookChapter(title: "Ch1", text: "Hello GC")])
        )
        container.mainContext.insert(book)
        try container.mainContext.save()

        let payload = try EncryptedBackupService.makeExportPayload(context: container.mainContext)
        let bundle = try WebDAVPayloadSharder.split(payload)
        let vaultKey = try WebDAVShardCrypto.deriveVaultKey(password: "Passphrase!2026", salt: nil, iterations: 10_000)
        let realBookHash = try XCTUnwrap(bundle.manifest.bookRefs.first?.blobHash)
        let manifestData = try WebDAVShardCrypto.encryptManifest(
            bundle.manifest,
            presentBlobs: [realBookHash],
            vaultKey: vaultKey
        )

        var deletedPaths: [String] = []
        let lock = NSLock()
        PhaseBMockURLProtocol.handler = { req in
            let url = req.url!
            let method = req.httpMethod ?? "GET"
            if method == "GET", url.path.hasSuffix("manifest.enc.json") {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, manifestData)
            }
            if method == "PROPFIND" {
                let listing = """
                <D:multistatus xmlns:D="DAV:">
                  <D:response><D:href>\(url.path)/</D:href></D:response>
                  <D:response><D:href>\(url.path)/\(realBookHash).enc.bin</D:href></D:response>
                  <D:response><D:href>\(url.path)/\(orphanHash).enc.bin</D:href></D:response>
                </D:multistatus>
                """
                return (HTTPURLResponse(url: url, statusCode: 207, httpVersion: nil, headerFields: nil)!, Data(listing.utf8))
            }
            if method == "DELETE" {
                lock.withLock { deletedPaths.append(url.path) }
                return (HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let report = try await WebDAVShardedSyncService.pruneOrphanBlobs(
            passphrase: "Passphrase!2026",
            serverURL: "https://dav.example.com/dav",
            remotePath: "Fugue/fugue-sync.enc.json",
            username: "u",
            password: "p",
            session: makeMockSession()
        )
        XCTAssertEqual(report.scannedRemoteBlobs, 2)
        XCTAssertEqual(report.referencedBlobs, 1)
        XCTAssertEqual(report.orphanHashes, [orphanHash])
        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(deletedPaths.count, 1)
        XCTAssertTrue(deletedPaths[0].hasSuffix("\(orphanHash).enc.bin"))
    }

    // MARK: - 2. BookReferenceSearch Hybrid RRF & Spoiler Cutoff

    func testBookReferenceSearchHybridRanksRelevantSceneAndHonorsSpoilerCutoff() async throws {
        let chapters = [
            BookChapter(title: "第一章 启程", text: "林冲站在雪地里低声说道：「今晚风雪太大，我们去草料场避一避。」\n\n陆谦躲在暗处没有吭声。"),
            BookChapter(title: "第二章 风雪山神庙", text: "林冲推开山神庙大门，发现草料场火光冲天，他怒喝道：「贼子竟敢纵火！」"),
            BookChapter(title: "第三章 剧透结局", text: "林冲最终上了梁山泊，成为八十万禁军教头的传奇人物。")
        ]
        let bookID = UUID()
        let manuscriptData = try JSONEncoder().encode(chapters)
        let friend = BookFriend(bookID: bookID, bookTitle: "水浒传", name: "林冲", aliases: ["豹子头"], throughChapter: 1)

        let evidence = try await BookReferenceSearch.shared.reference(
            for: friend,
            manuscript: manuscriptData,
            question: "山神庙里草料场起火时发生了什么？"
        )
        XCTAssertFalse(evidence.excerpts.isEmpty)
        XCTAssertTrue(evidence.excerpts.allSatisfy { ($0.chapterIndex ?? 0) <= 1 }, "Must never leak chapters beyond throughChapter")
        XCTAssertTrue(evidence.excerpts.contains { $0.text.contains("山神庙") })

        // Updating manuscript (e.g. background PDF OCR appending new content) must bust cache even when friend is unchanged
        let expandedChapters = [
            chapters[0],
            BookChapter(title: "第二章 风雪山神庙", text: "林冲在山神庙捡到了一把神秘的青铜古钥匙，并藏进了怀中。"),
            chapters[2]
        ]
        let expandedData = try JSONEncoder().encode(expandedChapters)
        let refreshed = try await BookReferenceSearch.shared.reference(
            for: friend,
            manuscript: expandedData,
            question: "青铜古钥匙在哪里捡到的？"
        )
        XCTAssertTrue(refreshed.excerpts.contains { $0.text.contains("青铜古钥匙") })
    }

    // MARK: - 3. Streaming Sentence TTS Buffer & Controller

    func testStreamingSentenceBufferSplitsCleanlyAndWaitsForCodeFences() {
        var buffer = StreamingSentenceBuffer(minSentenceCharacters: 10)
        let first = buffer.ingest(cumulativeText: "你好，今天天气真不错。")
        XCTAssertEqual(first, ["你好，今天天气真不错。"])

        // Should hold back while inside unclosed code fence
        let midCode = buffer.ingest(cumulativeText: "你好，今天天气真不错。看代码：\n```swift\nlet x = 3.14")
        XCTAssertEqual(midCode.count, 1) // flushes "看代码：\n" before code fence, holds back code

        let closedCode = buffer.ingest(cumulativeText: "你好，今天天气真不错。看代码：\n```swift\nlet x = 3.14\n```\n这就是最终结果！")
        XCTAssertFalse(closedCode.isEmpty)
        XCTAssertTrue(closedCode.joined().contains("这就是最终结果"))
        XCTAssertFalse(closedCode.joined().contains("let x = 3.14"), "Code fence contents must not be spoken verbatim")

        // Tail without terminal punctuation flushes on finish()
        _ = buffer.ingest(cumulativeText: "你好，今天天气真不错。看代码：\n```swift\nlet x = 3.14\n```\n这就是最终结果！补充一句尾注")
        let tail = buffer.finish()
        XCTAssertEqual(tail, ["补充一句尾注"])
    }

    func testVoiceControllerStreamingEmitsSentencesBeforeGenerationCompletes() {
        let controller = VoiceConversationController()
        controller.startSession()
        controller.handleTranscriptUpdate("讲个故事", scheduleTimer: false)
        controller.liveTranscript = "讲个故事"
        XCTAssertTrue(controller.commitCurrentTranscript { _ in true })
        XCTAssertEqual(controller.phase, .thinking)

        let msgID = UUID()
        var spoken: [String] = []
        controller.handleStreamingTextUpdate(
            "从前有座山，山里有座庙。",
            messageID: msgID,
            sentenceHandler: { _, sentence in
                spoken.append(sentence)
            }
        )
        XCTAssertEqual(controller.phase, .speaking)
        XCTAssertEqual(spoken, ["从前有座山，山里有座庙。"])

        controller.handleGenerationFinished(
            replyText: "从前有座山，山里有座庙。故事讲完了",
            errorMessage: nil,
            messageID: msgID,
            sentenceHandler: { _, sentence in spoken.append(sentence) }
        )
        XCTAssertEqual(spoken, ["从前有座山，山里有座庙。", "故事讲完了"])
        XCTAssertEqual(controller.turnCount, 1)
    }

    // MARK: - 4. Rolling Context Summary & Context Window Catalog

    func testRollingSummaryStoreAndContextWindowCatalog() {
        XCTAssertEqual(ContextWindowCatalog.contextLimit(for: "gemini-2.5-pro"), 1_000_000)
        XCTAssertEqual(ContextWindowCatalog.contextLimit(for: "gemini-4-neon"), 1_000_000)
        XCTAssertEqual(ContextWindowCatalog.contextLimit(for: "gpt-6.2-sol"), 1_000_000)
        XCTAssertEqual(ContextWindowCatalog.contextLimit(for: "claude-sonnet-4-5"), 200_000)
        XCTAssertEqual(ContextWindowCatalog.contextLimit(for: "claude-fable-5-2"), 200_000)
        XCTAssertEqual(ContextWindowCatalog.contextLimit(for: "deepseek-reasoner"), 128_000)
        XCTAssertEqual(ContextWindowCatalog.formattedWindow(1_000_000), "1M")
        XCTAssertEqual(ContextWindowCatalog.formattedWindow(200_000), "200K")
        XCTAssertEqual(ContextWindowCatalog.fillRatio(inputTokens: 64_000, modelID: "gpt-4o"), 0.5, accuracy: 0.001)

        let store = RollingContextSummaryStore(fileURL: nil)
        let convID = UUID()
        let lastID = UUID()
        let summary = RollingContextSummary(
            conversationID: convID,
            summaryText: "- User is building an iOS app in Swift",
            coveredMessageCount: 12,
            lastCoveredMessageID: lastID,
            updatedAt: Date()
        )
        store.save(summary)
        XCTAssertEqual(store.summary(for: convID)?.coveredMessageCount, 12)
        XCTAssertTrue(RollingContextSummaryStore.promptBlock(for: summary).contains("12 earlier messages"))

        store.remove(for: convID)
        XCTAssertNil(store.summary(for: convID))
    }

    // MARK: - 5. Background Progressive PDF OCR Page Merge

    func testBackgroundPDFOCRChapterOrderMerge() {
        let existing = [
            BookChapter(title: "第 1 页", text: "Page one"),
            BookChapter(title: "第 10 页", text: "Page ten")
        ]
        let additions = [
            BookChapter(title: "第 2 页", text: "Page two OCR"),
            BookChapter(title: "第 10 页", text: "Duplicate ignored"),
            BookChapter(title: "第 25 页", text: "Page twenty-five OCR")
        ]
        let merged = BackgroundPDFOCRQueue.mergeChaptersInPageOrder(existing: existing, additions: additions)
        XCTAssertEqual(merged.map(\.title), ["第 1 页", "第 2 页", "第 10 页", "第 25 页"])
        XCTAssertEqual(merged[2].text, "Page ten")
    }

    // MARK: - 6. Extended Offline Mermaid Charts & CSP Preservation

    func testArtifactBuilderSupportsExtendedMermaidTypesAndKeepsStrictCSP() {
        XCTAssertEqual(ArtifactDocumentBuilder.supportedMermaidDiagramKind(in: "pie title Pets\n \"Dogs\" : 386"), "pie")
        XCTAssertEqual(ArtifactDocumentBuilder.supportedMermaidDiagramKind(in: "gantt\n title Roadmap\n Task A :a1, 2026-01-01, 5d"), "gantt")
        XCTAssertEqual(ArtifactDocumentBuilder.supportedMermaidDiagramKind(in: "erDiagram\n USER ||--o{ ORDER : places"), "erDiagram")
        XCTAssertEqual(ArtifactDocumentBuilder.supportedMermaidDiagramKind(in: "mindmap\n  root((Fugue))\n    Sync"), "mindmap")
        XCTAssertEqual(ArtifactDocumentBuilder.supportedMermaidDiagramKind(in: "flowchart TD\n subgraph Core\n A{Check} -.-> B([Done])\n end"), "flowchart")

        let html = ArtifactDocumentBuilder.htmlDocument(language: "mermaid", code: "pie\n \"A\" : 60\n \"B\" : 40")
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("RTCPeerConnection"))
        XCTAssertTrue(html.contains("gantt"))
        XCTAssertTrue(html.contains("mindmap"))
        XCTAssertTrue(html.contains("erDiagram"))
        XCTAssertTrue(html.contains("subgraph"))
    }

    // MARK: - 7. Project Workspaces, Scoped Memories & Modular Feature Toggles

    func testProjectWorkspaceAndScopedMemoryFiltering() throws {
        let container = try makeInMemoryContainer()
        let ctx = container.mainContext

        let globalMem = PersonalMemory(content: "Respond in concise Chinese")
        let engMem = PersonalMemory(content: "Uses Swift 6 strict concurrency")
        let writingMem = PersonalMemory(content: "Prefers literary essay tone")
        ctx.insert(globalMem)
        ctx.insert(engMem)
        ctx.insert(writingMem)
        try ctx.save()

        let scopeStore = MemoryScopeStore(fileURL: nil)
        scopeStore.setTags(["工程", "iOS"], for: engMem.id)
        scopeStore.setTags(["写作"], for: writingMem.id)

        // Engineering project gets global + engineering memories, excludes writing-only memory
        let engPrompt = try PersonalMemory.prompt(in: ctx, activeProjectTags: ["工程"], scopeStore: scopeStore)
        XCTAssertEqual(engPrompt.count, 2)
        XCTAssertTrue(engPrompt.text.contains("Swift 6"))
        XCTAssertTrue(engPrompt.text.contains("concise Chinese"))
        XCTAssertFalse(engPrompt.text.contains("literary essay"))

        // Non-project chat still receives all enabled memories
        let allPrompt = try PersonalMemory.prompt(in: ctx, activeProjectTags: nil, scopeStore: scopeStore)
        XCTAssertEqual(allPrompt.count, 3)

        // ProjectWorkspace creates pre-wired conversation
        let wsStore = ProjectWorkspaceStore(fileURL: nil)
        let bookID = UUID()
        let ws = ProjectWorkspace(
            name: "Swift 架构",
            iconEmoji: "🛠️",
            systemPrompt: "Act as senior Swift architect",
            knowledgeVolumeIDs: [bookID],
            memoryTags: ["工程"],
            enableThinking: true,
            enableAgentTools: true
        )
        wsStore.upsert(ws)
        let conv = wsStore.createConversation(in: ws, providers: [], context: ctx)
        XCTAssertEqual(conv.folderTag, "Swift 架构")
        XCTAssertEqual(conv.systemPrompt, "Act as senior Swift architect")
        XCTAssertEqual(conv.assistanceSettings.knowledgeVolumeIDs, [bookID])
        XCTAssertTrue(conv.assistanceSettings.enableAgentTools)
        XCTAssertEqual(wsStore.workspace(forFolderTag: "Swift 架构")?.id, ws.id)

        // Modular toggles on isolated UserDefaults
        let suiteName = "phaseb.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prefs = AppPreferences(defaults: defaults)
        XCTAssertTrue(prefs.showsProjects)
        XCTAssertTrue(prefs.showsUsageTab)
        prefs.moduleUsageTabEnabled = false
        XCTAssertFalse(prefs.showsUsageTab)
    }

    // MARK: - 8. Multi-Search Engines (Brave / Exa / SearXNG)

    func testMultiSearchEngineDecodersAndSearXNGValidation() throws {
        let braveJSON = """
        {"web":{"results":[{"title":"Swift.org","url":"https://www.swift.org/","description":"Official Swift language site"}]}}
        """
        let braveEv = try WebSearchService.decodeBrave(Data(braveJSON.utf8), query: "swift")
        XCTAssertEqual(braveEv.sources.count, 1)
        XCTAssertEqual(braveEv.sources[0].title, "Swift.org")

        let exaJSON = """
        {"results":[{"title":"Exa Doc","url":"https://docs.exa.ai/reference","text":"Semantic web search API"}]}
        """
        let exaEv = try WebSearchService.decodeExa(Data(exaJSON.utf8), query: "exa")
        XCTAssertEqual(exaEv.sources.count, 1)
        XCTAssertEqual(exaEv.sources[0].snippet, "Semantic web search API")

        let searxJSON = """
        {"results":[{"title":"SearXNG","url":"https://docs.searxng.org/","content":"Privacy-respecting metasearch engine"}]}
        """
        let searxEv = try WebSearchService.decodeSearXNG(Data(searxJSON.utf8), query: "searxng")
        XCTAssertEqual(searxEv.sources.count, 1)
        XCTAssertEqual(searxEv.sources[0].title, "SearXNG")

        // SearXNG enforces HTTPS for public hosts, permits local LAN HTTP
        XCTAssertNil(WebSearchService.validateSearXNGBaseURL("http://public-searx.example.com"))
        XCTAssertNotNil(WebSearchService.validateSearXNGBaseURL("https://public-searx.example.com"))
        XCTAssertNotNil(WebSearchService.validateSearXNGBaseURL("http://192.168.1.50:8080"))
    }

    // MARK: - 9. Remote MCP Client (JSON-RPC 2.0 + SSE)

    func testMCPClientDiscoverAndCallOverJSONAndSSE() async throws {
        XCTAssertThrowsError(try MCPClient.validateEndpoint("http://mcp.example.com/rpc")) { err in
            XCTAssertEqual(err as? MCPClientError, .insecurePublicHTTP)
        }
        XCTAssertNoThrow(try MCPClient.validateEndpoint("http://127.0.0.1:8080/mcp"))

        PhaseBMockURLProtocol.handler = { req in
            let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any] ?? [:]
            let method = body["method"] as? String ?? ""
            let url = req.url!
            if method == "initialize" {
                let resp = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Mcp-Session-Id": "sess-42"])!, Data(resp.utf8))
            }
            if method == "notifications/initialized" {
                return (HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!, Data())
            }
            if method == "tools/list" {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Mcp-Session-Id"), "sess-42")
                let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"list_issues\",\"description\":\"List project issues\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"repo\":{\"type\":\"string\"}}}}]}}\n\n"
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
            }
            if method == "tools/call" {
                let resp = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Issue #7: Fix dark mode"}]}}"#
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(resp.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let tools = try await MCPClient.discoverTools(
            endpointURL: "https://mcp.example.com/v1",
            authHeaderName: "Authorization",
            authHeaderValue: "Bearer token",
            session: makeMockSession()
        )
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "list_issues")

        let output = try await MCPClient.callTool(
            endpointURL: "https://mcp.example.com/v1",
            toolName: "list_issues",
            arguments: ["repo": "iosbox"],
            session: makeMockSession()
        )
        XCTAssertTrue(output.contains("Issue #7: Fix dark mode"))
        XCTAssertTrue(output.contains("Untrusted external MCP tool output"))

        let store = MCPServerStore(fileURL: nil)
        let server = MCPServerConfig(name: "GitHub", endpointURL: "https://mcp.example.com/v1", discoveredTools: tools)
        store.upsert(server)
        let defs = store.enabledToolDefinitions()
        XCTAssertEqual(defs.count, 1)
        XCTAssertTrue(defs[0].name.hasPrefix("mcp__"))
        XCTAssertEqual(store.resolveToolCall(namespacedName: defs[0].name)?.tool.name, "list_issues")
    }

    // MARK: - 10. OpenAI Responses API Adapter

    func testOpenAIResponsesEndpointsRequestBodyAndSSEEvents() throws {
        let ep = try EndpointResolver.chatEndpoint(baseURL: "https://api.openai.com/v1", protocolType: .openAIResponses, modelID: "gpt-5")
        XCTAssertEqual(ep.absoluteString, "https://api.openai.com/v1/responses")
        let modelsEp = try EndpointResolver.modelsEndpoint(baseURL: "https://api.openai.com/v1/responses", protocolType: .openAIResponses)
        XCTAssertEqual(modelsEp.absoluteString, "https://api.openai.com/v1/models")

        let req = LLMChatRequest(
            providerName: "OpenAI",
            protocolType: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            customHeaders: [],
            modelID: "gpt-5",
            supportsReasoning: true,
            systemPrompt: "Be concise.",
            messages: [
                LLMPromptMessage(role: .user, content: "Check weather"),
                LLMPromptMessage(role: .assistant, content: "", toolCalls: [LLMToolCall(id: "call_1", name: "get_weather", argumentsJSON: "{\"city\":\"Tokyo\"}")]),
                LLMPromptMessage(role: .tool, content: "{\"temp\":22}", toolCallID: "call_1", toolName: "get_weather")
            ],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: 1024,
            enableThinking: true,
            thinkingBudgetTokens: 8192,
            enableNativeSearch: true,
            tools: [LLMToolDefinition(name: "get_weather", description: "Weather", parametersSchemaJSON: #"{"type":"object","properties":{}}"#)]
        )
        let body = OpenAIResponsesAdapter.buildRequestBody(req, includeReasoning: true, includeNativeSearch: true)
        XCTAssertEqual(body["instructions"] as? String, "Be concise.")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertNil(body["temperature"], "Reasoning requests should omit temperature")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 3)
        XCTAssertEqual(input[1]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["type"] as? String, "function_call_output")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { ($0["type"] as? String) == "web_search_preview" })

        // Parse SSE events
        var state = OpenAIResponsesAdapter.StreamParserState()
        let e1 = try OpenAIResponsesAdapter.parseSSEEventObject(["type": "response.reasoning_summary_text.delta", "delta": "Step 1. "], state: &state)
        let e2 = try OpenAIResponsesAdapter.parseSSEEventObject(["type": "response.output_text.delta", "delta": "Hello!"], state: &state)
        _ = try OpenAIResponsesAdapter.parseSSEEventObject(["type": "response.output_item.added", "item": ["id": "fc_1", "type": "function_call", "call_id": "call_99", "name": "web_search"]], state: &state)
        _ = try OpenAIResponsesAdapter.parseSSEEventObject(["type": "response.function_call_arguments.delta", "item_id": "fc_1", "delta": "{\"q\":\"swift\"}"], state: &state)
        let e3 = try OpenAIResponsesAdapter.parseSSEEventObject(["type": "response.function_call_arguments.done", "item_id": "fc_1", "arguments": "{\"q\":\"swift\"}"], state: &state)
        let e4 = try OpenAIResponsesAdapter.parseSSEEventObject([
            "type": "response.completed",
            "response": [
                "usage": [
                    "input_tokens": 120,
                    "output_tokens": 45,
                    "input_tokens_details": ["cached_tokens": 60]
                ]
            ]
        ], state: &state)

        if case .reasoningDelta(let r) = e1.first { XCTAssertEqual(r, "Step 1. ") } else { XCTFail("Expected reasoning delta") }
        if case .contentDelta(let c) = e2.first { XCTAssertEqual(c, "Hello!") } else { XCTFail("Expected content delta") }
        if case .toolCall(let tc) = e3.first {
            XCTAssertEqual(tc.id, "call_99")
            XCTAssertEqual(tc.name, "web_search")
        } else { XCTFail("Expected toolCall") }
        XCTAssertTrue(state.completed)
        XCTAssertEqual(e4.count, 2) // usage + cacheUsage
    }

    // MARK: - 11. Unified Image Generation & Editing

    func testImageGenerationEndpointsAndResponseDecoders() async throws {
        let genEp = try EndpointResolver.imagesGenerationsEndpoint(baseURL: "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(genEp.absoluteString, "https://api.openai.com/v1/images/generations")
        let editEp = try EndpointResolver.imagesEditsEndpoint(baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(editEp.absoluteString, "https://api.openai.com/v1/images/edits")
        let gemEp = try EndpointResolver.geminiGenerateContentEndpoint(baseURL: "https://generativelanguage.googleapis.com/v1beta", modelID: "gemini-2.5-flash-image-preview")
        XCTAssertEqual(gemEp.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image-preview:generateContent")

        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let b64 = pngHeader.base64EncodedString()

        let openAIResp = #"{"data":[{"b64_json":"\#(b64)","revised_prompt":"A sleek neon skyline"}]}"#
        let openAIImg = try await ImageGenerationService.decodeOpenAIImageResponse(Data(openAIResp.utf8))
        XCTAssertEqual(openAIImg.imageData, pngHeader)
        XCTAssertEqual(openAIImg.mimeType, "image/png")
        XCTAssertEqual(openAIImg.revisedPrompt, "A sleek neon skyline")

        let geminiResp = #"{"candidates":[{"content":{"parts":[{"text":"Here is your edited photo"},{"inlineData":{"mimeType":"image/png","data":"\#(b64)"}}]}}]}"#
        let geminiImg = try ImageGenerationService.decodeGeminiImageResponse(Data(geminiResp.utf8))
        XCTAssertEqual(geminiImg.imageData, pngHeader)
        XCTAssertEqual(geminiImg.revisedPrompt, "Here is your edited photo")
    }

    // MARK: - 12. HTTP 400 Auto-Degradation, Sanitization & Error Extraction

    func testHTTP400AutoDegradationAndErrorExtractionAcrossAdapters() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        // 1. Bearer prefix sanitization
        XCTAssertEqual(LLMClient.sanitizedAPIKey("  Bearer sk-test-123  "), "sk-test-123")
        XCTAssertEqual(LLMClient.sanitizedAPIKey("bearer sk-test-456"), "sk-test-456")
        XCTAssertEqual(LLMClient.sanitizedAPIKey("sk-plain"), "sk-plain")

        // 2. Gemini array error + FastAPI Pydantic detail array extraction
        let geminiArrErr = #"[{"error":{"code":400,"message":"Thinking is not supported by this model","status":"INVALID_ARGUMENT"}}]"#
        XCTAssertEqual(LLMClient.extractReadableErrorMessage(from: Data(geminiArrErr.utf8)), "Thinking is not supported by this model")
        let pydanticErr = #"{"detail":[{"loc":["body","enable_thinking"],"msg":"Extra inputs are not permitted"}]}"#
        let parsedPydantic = LLMClient.extractReadableErrorMessage(from: Data(pydanticErr.utf8))
        XCTAssertTrue(parsedPydantic.contains("enable_thinking"))
        XCTAssertTrue(parsedPydantic.contains("Extra inputs are not permitted"))

        // 3. Starter model picker skips image/audio/embedding variants
        let picked = ClipboardProviderParser.pickBestStarterModel(
            from: [
                ModelSpec(id: "gemini-2.5-flash-image-preview"),
                ModelSpec(id: "gpt-4o-audio-preview"),
                ModelSpec(id: "text-embedding-3-small"),
                ModelSpec(id: "gemini-2.5-flash")
            ],
            protocolType: .gemini
        )
        XCTAssertEqual(picked?.id, "gemini-2.5-flash")

        // 4. OpenAI Responses API omits temperature for o3 even when thinking is off, and marks tools strict: false
        let o3OffReq = LLMChatRequest(
            providerName: "OpenAI",
            protocolType: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            customHeaders: [],
            modelID: "o3",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Reply with: OK")],
            temperature: 0.7,
            topP: 0.9,
            maxOutputTokens: 1024,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            tools: [LLMToolDefinition(name: "demo", description: "Demo", parametersSchemaJSON: #"{"type":"object","properties":{"a":{"type":"string"}}}"#)]
        )
        let respBody = OpenAIResponsesAdapter.buildRequestBody(o3OffReq)
        XCTAssertNil(respBody["temperature"])
        XCTAssertNil(respBody["top_p"])
        let respTools = try XCTUnwrap(respBody["tools"] as? [[String: Any]])
        XCTAssertEqual(respTools.first?["strict"] as? Bool, false)

        // 5. Image generation size normalization avoids gpt-image-1 / dall-e-3 size-mismatch 400
        XCTAssertEqual(ImageGenerationService.resolvedOpenAISize(for: .wide, modelID: "gpt-image-1"), "1536x1024")
        XCTAssertEqual(ImageGenerationService.resolvedOpenAISize(for: .landscape, modelID: "dall-e-3"), "1792x1024")
        XCTAssertEqual(ImageGenerationService.resolvedOpenAISize(for: .portrait, modelID: "dall-e-3"), "1024x1792")

        // 6. OpenAI-compatible Qwen3 ping rejecting `enable_thinking` auto-degrades & succeeds (and strips Bearer prefix)
        let cache = GatewayCapabilityCache(defaults: nil)
        let router = APIKeyPoolRouter()
        let qwenCounter = Counter()
        PhaseBMockURLProtocol.handler = { req in
            _ = qwenCounter.bump()
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-qwen")
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            if obj["enable_thinking"] != nil {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(pydanticErr.utf8))
            }
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
        }
        let qwenPing = LLMClient.buildPingRequest(
            providerName: "Groq",
            protocolType: .openAICompatible,
            baseURL: "https://qwen-test.invalid/v1",
            apiKey: "Bearer sk-qwen",
            customHeaders: [],
            modelID: "qwen/qwen3-32b",
            supportsReasoning: true
        )
        var qwenOut = ""
        for try await ev in OpenAICompatibleAdapter.streamChat(qwenPing, capabilityCache: cache, keyRouter: router, session: makeMockSession()) {
            if case .contentDelta(let d) = ev { qwenOut += d }
        }
        XCTAssertEqual(qwenOut, "OK")
        XCTAssertEqual(qwenCounter.count, 2)
        XCTAssertTrue(cache.isUnsupported(.reasoningParams, protocolType: .openAICompatible, baseURL: "https://qwen-test.invalid/v1", modelID: "qwen/qwen3-32b"))

        // 7. Relay rejecting `reasoning_effort` & `max_completion_tokens` on o3 auto-degrades to `max_tokens`
        let o3Counter = Counter()
        PhaseBMockURLProtocol.handler = { req in
            _ = o3Counter.bump()
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            if obj["reasoning_effort"] != nil {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(#"{"error":{"message":"Unsupported parameter: reasoning_effort"}}"#.utf8))
            }
            if obj["max_completion_tokens"] != nil {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(#"{"error":{"message":"Unknown parameter: max_completion_tokens"}}"#.utf8))
            }
            XCTAssertEqual(obj["max_tokens"] as? Int, 1024)
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
        }
        let o3Ping = LLMClient.buildPingRequest(
            providerName: "Relay",
            protocolType: .openAICompatible,
            baseURL: "https://relay-o3.invalid/v1",
            apiKey: "sk-relay",
            customHeaders: [],
            modelID: "o3",
            supportsReasoning: true
        )
        var o3Out = ""
        for try await ev in OpenAICompatibleAdapter.streamChat(o3Ping, capabilityCache: cache, keyRouter: router, session: makeMockSession()) {
            if case .contentDelta(let d) = ev { o3Out += d }
        }
        XCTAssertEqual(o3Out, "OK")
        XCTAssertEqual(o3Counter.count, 3)

        // 8. Generic 400 ("Extra inputs are not permitted") strips `stream_options` and succeeds
        let genericCounter = Counter()
        PhaseBMockURLProtocol.handler = { req in
            _ = genericCounter.bump()
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            if obj["stream_options"] != nil {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(#"{"error":{"message":"Extra inputs are not permitted"}}"#.utf8))
            }
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
        }
        let stdPing = LLMClient.buildPingRequest(
            providerName: "Gateway",
            protocolType: .openAICompatible,
            baseURL: "https://strict-gw.invalid/v1",
            apiKey: "sk-gw",
            customHeaders: [],
            modelID: "gpt-4o",
            supportsReasoning: false
        )
        var stdOut = ""
        for try await ev in OpenAICompatibleAdapter.streamChat(stdPing, capabilityCache: cache, keyRouter: router, session: makeMockSession()) {
            if case .contentDelta(let d) = ev { stdOut += d }
        }
        XCTAssertEqual(stdOut, "OK")
        XCTAssertEqual(genericCounter.count, 2)

        // 9. Unrecoverable 400 ("Model Not Exist") fails fast on attempt 1
        let badCounter = Counter()
        PhaseBMockURLProtocol.handler = { req in
            _ = badCounter.bump()
            return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(#"{"error":{"message":"Model Not Exist"}}"#.utf8))
        }
        let badPing = LLMClient.buildPingRequest(
            providerName: "DeepSeek",
            protocolType: .openAICompatible,
            baseURL: "https://badmodel.invalid/v1",
            apiKey: "sk-ds",
            customHeaders: [],
            modelID: "nonexistent-model",
            supportsReasoning: false
        )
        do {
            for try await _ in OpenAICompatibleAdapter.streamChat(badPing, capabilityCache: cache, keyRouter: router, session: makeMockSession()) {}
            XCTFail("Expected HTTP 400")
        } catch LLMError.httpError(let code, let detail) {
            XCTAssertEqual(code, 400)
            XCTAssertTrue(detail.contains("Model Not Exist"))
        }
        XCTAssertEqual(badCounter.count, 1)

        // 10. Gemini array-wrapped HTTP 400 for unsupported thinking auto-degrades & succeeds
        let gemCounter = Counter()
        PhaseBMockURLProtocol.handler = { req in
            _ = gemCounter.bump()
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            let genCfg = obj["generationConfig"] as? [String: Any]
            if genCfg?["thinkingConfig"] != nil {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(geminiArrErr.utf8))
            }
            let sse = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"OK\"}]},\"finishReason\":\"STOP\"}]}\n\n"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
        }
        let gemPing = LLMClient.buildPingRequest(
            providerName: "Gemini",
            protocolType: .gemini,
            baseURL: "https://gem-400.invalid/v1beta",
            apiKey: "AIzaTest",
            customHeaders: [],
            modelID: "gemini-2.5-flash",
            supportsReasoning: true
        )
        var gemOut = ""
        for try await ev in GeminiAdapter.streamChat(gemPing, capabilityCache: cache, keyRouter: router, session: makeMockSession()) {
            if case .contentDelta(let d) = ev { gemOut += d }
        }
        XCTAssertEqual(gemOut, "OK")
        XCTAssertEqual(gemCounter.count, 2)

        // 11. Anthropic HTTP 400 for unsupported thinking auto-degrades & succeeds
        let claudeCounter = Counter()
        PhaseBMockURLProtocol.handler = { req in
            _ = claudeCounter.bump()
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            if obj["thinking"] != nil {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(#"{"error":{"message":"thinking is not supported for this model"}}"#.utf8))
            }
            let sse = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"OK\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
        }
        let claudeReq = LLMChatRequest(
            providerName: "Anthropic",
            protocolType: .anthropic,
            baseURL: "https://claude-400.invalid/v1",
            apiKey: "sk-ant-test",
            customHeaders: [],
            modelID: "claude-3-5-haiku-latest",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Hi")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: 2048,
            enableThinking: true,
            thinkingBudgetTokens: 1024
        )
        var claudeOut = ""
        for try await ev in AnthropicAdapter.streamChat(claudeReq, capabilityCache: cache, keyRouter: router, session: makeMockSession()) {
            if case .contentDelta(let d) = ev { claudeOut += d }
        }
        XCTAssertEqual(claudeOut, "OK")
        XCTAssertEqual(claudeCounter.count, 2)

        // 12. OpenAI Responses unverified org summary 400 strips only `summary` and keeps `effort`
        let respCounter = Counter()
        PhaseBMockURLProtocol.handler = { req in
            _ = respCounter.bump()
            let obj = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]) ?? [:]
            let reasoning = obj["reasoning"] as? [String: Any]
            if reasoning?["summary"] != nil {
                return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(#"{"error":{"message":"Your organization must be verified to generate reasoning summaries."}}"#.utf8))
            }
            XCTAssertEqual(reasoning?["effort"] as? String, "medium")
            let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{}}\n\n"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, Data(sse.utf8))
        }
        let respReq = LLMChatRequest(
            providerName: "OpenAI",
            protocolType: .openAIResponses,
            baseURL: "https://resp-400.invalid/v1",
            apiKey: "sk-resp",
            customHeaders: [],
            modelID: "gpt-5",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Hi")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: 1024,
            enableThinking: true,
            thinkingBudgetTokens: 8192
        )
        var respOut = ""
        for try await ev in OpenAIResponsesAdapter.streamChat(respReq, capabilityCache: cache, keyRouter: router, session: makeMockSession()) {
            if case .contentDelta(let d) = ev { respOut += d }
        }
        XCTAssertEqual(respOut, "OK")
        XCTAssertEqual(respCounter.count, 2)
    }
}
