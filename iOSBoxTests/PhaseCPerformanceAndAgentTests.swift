import Foundation
import SwiftData
import XCTest
@testable import iOSBox

final class PhaseCPerformanceAndAgentTests: XCTestCase {

    // MARK: - 1. Incremental Streaming Markdown Parser & Inline Cache

    func testStreamingMarkdownIncrementalMatchesFullParseAcrossAllBlockTypes() {
        MarkdownBlockParser.resetStreamingCache()

        let document = """
        # 深度技术调研报告

        这是一段包含**加粗**、*斜体*、`行内代码` 以及 [链接](https://example.com) 的开篇正文，长度足够触发流式增量前缀缓存机制，确保在多千字长文输出时仅解析活跃尾部。

        ## 核心架构对比

        - 第一条结论：增量前缀缓存可将每次刷新开销降至 O(tail)
        - 第二条结论：支持包含 | 竖线的列表项且不会误判为表格
        - [x] 已完成块级缓存
        - [ ] 持续观测渲染帧率

        1. 第一步：拆解问题
        2. 第二步：并发检索
        3. 第三步：交叉核验

        > 引文第一段内容

        > 引文第二段连续合并

        ```swift
        struct CacheEntry {
            let prefix: String
            let count: Int
        }
        ```

        $$
        E = mc^2 + \\sum_{i=1}^{n} x_i
        $$

        | 指标 | 优化前 | 优化后 |
        | :--- | :---: | ---: |
        | 解析复杂度 | O(N) | O(tail) |
        | 主线程耗时 | 高 | 低 |

        ---

        第二张表格检验单元格预算传递：

        | 模块 | 状态 |
        | --- | --- |
        | Markdown | OK |
        | DeepResearch | OK |

        最后一段收尾总结文字，验证尾部未封闭段落的逐块追加与完整解析完全一致。
        """

        var cursor = document.startIndex
        var stepCount = 0
        while cursor < document.endIndex {
            let next = document.index(cursor, offsetBy: 19, limitedBy: document.endIndex) ?? document.endIndex
            let prefix = String(document[..<next])
            let streamingBlocks = MarkdownBlockParser.parseStreaming(prefix)
            let fullBlocks = MarkdownBlockParser.parse(prefix)
            XCTAssertEqual(streamingBlocks, fullBlocks, "Mismatch at streaming step \(stepCount), length \(prefix.count)")
            cursor = next
            stepCount += 1
        }
        XCTAssertGreaterThan(stepCount, 20)
    }

    func testStreamingMarkdownHandlesInterleavedArenaStreamsAndCRLF() {
        MarkdownBlockParser.resetStreamingCache()

        let streamA = "# Stream A\r\n\r\n" + String(repeating: "Alpha paragraph line with details.\r\n\r\n", count: 14) + "```python\r\nprint('a')\r\n```\r\n\r\nTail A"
        let streamB = "# Stream B\n\n" + String(repeating: "- Beta bullet item with enough text\n", count: 14) + "\n| K | V |\n| - | - |\n| 1 | 2 |\n\nTail B"

        var idxA = streamA.startIndex
        var idxB = streamB.startIndex
        while idxA < streamA.endIndex || idxB < streamB.endIndex {
            if idxA < streamA.endIndex {
                idxA = streamA.index(idxA, offsetBy: 47, limitedBy: streamA.endIndex) ?? streamA.endIndex
                let subA = String(streamA[..<idxA])
                XCTAssertEqual(MarkdownBlockParser.parseStreaming(subA), MarkdownBlockParser.parse(subA))
            }
            if idxB < streamB.endIndex {
                idxB = streamB.index(idxB, offsetBy: 43, limitedBy: streamB.endIndex) ?? streamB.endIndex
                let subB = String(streamB[..<idxB])
                XCTAssertEqual(MarkdownBlockParser.parseStreaming(subB), MarkdownBlockParser.parse(subB))
            }
        }
    }

    func testInlineMarkdownCacheReturnsConsistentAttributedString() {
        InlineMarkdownCache.clear()
        let sample = "支持 **粗体** 与 `code` 以及 [来源](https://example.com)"
        let first = InlineMarkdownCache.attributedString(for: sample, cacheable: true)
        let second = InlineMarkdownCache.attributedString(for: sample, cacheable: true)
        let uncached = InlineMarkdownCache.attributedString(for: sample, cacheable: false)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, uncached)
    }

    // MARK: - 2. Adaptive Streaming Flush Cadence & Interrupted Continuation

    func testAdaptiveStreamingFlushIntervalScalesWithLength() {
        XCTAssertEqual(ChatEngine.streamingFlushInterval(forContentLength: 0), .milliseconds(35))
        XCTAssertEqual(ChatEngine.streamingFlushInterval(forContentLength: 1_499), .milliseconds(35))
        XCTAssertEqual(ChatEngine.streamingFlushInterval(forContentLength: 1_500), .milliseconds(60))
        XCTAssertEqual(ChatEngine.streamingFlushInterval(forContentLength: 5_999), .milliseconds(60))
        XCTAssertEqual(ChatEngine.streamingFlushInterval(forContentLength: 6_000), .milliseconds(95))
        XCTAssertEqual(ChatEngine.streamingFlushInterval(forContentLength: 18_000), .milliseconds(95))
    }

    @MainActor
    func testInterruptedStreamPreservesPartialTextAndContinuesSeamlessly() async throws {
        let (container, context, provider, conversation) = try makeInMemoryChatFixtures()
        _ = container

        final class CallCounter: @unchecked Sendable {
            var count = 0
        }
        let counter = CallCounter()

        let engine = ChatEngine(
            search: { _ in SearchEvidence(query: "", searchedAt: Date(), sources: []) },
            stream: { _ in
                counter.count += 1
                let attempt = counter.count
                return AsyncThrowingStream { continuation in
                    if attempt == 1 {
                        continuation.yield(.contentDelta("第一段已成功输出，接着在半句处"))
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                    } else {
                        continuation.yield(.contentDelta("顺利续写完成全文。"))
                        continuation.yield(.done)
                        continuation.finish()
                    }
                }
            }
        )

        let outcome = engine.sendUserMessage(
            text: "写一篇分析",
            attachments: [],
            in: conversation,
            providers: [provider],
            context: context
        )
        XCTAssertEqual(outcome, .sent)
        await waitUntilIdle(engine: engine, conversationID: conversation.id)

        let assistant = try XCTUnwrap(conversation.messages.last(where: { $0.role == .assistant }))
        XCTAssertEqual(assistant.content, "第一段已成功输出，接着在半句处")
        XCTAssertNotNil(assistant.errorMessage)
        XCTAssertFalse(assistant.isStreaming)

        engine.continueGeneration(
            assistantMessage: assistant,
            in: conversation,
            providers: [provider],
            context: context
        )
        await waitUntilIdle(engine: engine, conversationID: conversation.id)

        XCTAssertNil(assistant.errorMessage)
        XCTAssertEqual(assistant.content, "第一段已成功输出，接着在半句处顺利续写完成全文。")
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: - 3. Agent Image Generation Tool & Provider Ranking

    @MainActor
    func testPreferredAgentImageProviderSkipsTextOnlyHostsAndRanksImageCapable() {
        let deepseek = ProviderConfig(
            name: "DeepSeek",
            protocolType: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            models: [ModelSpec(id: "deepseek-chat", displayName: "DeepSeek V3")]
        )
        let openrouter = ProviderConfig(
            name: "OpenRouter",
            protocolType: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            models: [ModelSpec(id: "anthropic/claude-sonnet-4", displayName: "Claude")]
        )
        let gemini = ProviderConfig(
            name: "Gemini",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            models: [ModelSpec(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")]
        )
        let openai = ProviderConfig(
            name: "OpenAI",
            protocolType: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            models: [ModelSpec(id: "gpt-4o", displayName: "GPT-4o")]
        )
        let siliconFlowWithExplicit = ProviderConfig(
            name: "SiliconFlow",
            protocolType: .openAICompatible,
            baseURL: "https://api.siliconflow.cn/v1",
            models: [ModelSpec(id: "black-forest-labs/FLUX.1-dev", displayName: "FLUX Dev")]
        )

        let allProviders = [deepseek, openrouter, gemini, openai, siliconFlowWithExplicit]
        for p in allProviders {
            _ = KeychainService.shared.saveAPIKey("sk-test-\(p.name)", for: p.credentialID)
        }
        defer {
            for p in allProviders {
                KeychainService.shared.deleteAPIKey(for: p.credentialID)
            }
        }

        XCTAssertNil(ImageGenerationService.preferredAgentProvider(from: [deepseek, openrouter]))

        let pickedGemini = ImageGenerationService.preferredAgentProvider(from: [deepseek, gemini])
        XCTAssertEqual(pickedGemini?.provider.name, "Gemini")
        XCTAssertEqual(pickedGemini?.modelID, "gemini-2.5-flash-image-preview")

        let pickedOpenAI = ImageGenerationService.preferredAgentProvider(from: [deepseek, gemini, openai])
        XCTAssertEqual(pickedOpenAI?.provider.name, "OpenAI")
        XCTAssertEqual(pickedOpenAI?.modelID, "gpt-image-1")

        let pickedExplicit = ImageGenerationService.preferredAgentProvider(from: [openai, siliconFlowWithExplicit])
        XCTAssertEqual(pickedExplicit?.provider.name, "SiliconFlow")
        XCTAssertEqual(pickedExplicit?.modelID, "black-forest-labs/FLUX.1-dev")
    }

    func testAgentToolRunnerImageGenerationSchemaAndExecution() async {
        let withoutImg = AgentToolRunner.definitions(hasTavilyKey: false, hasKnowledgeBase: false, hasImageGeneration: false)
        XCTAssertFalse(withoutImg.contains(where: { $0.name == "generate_image" }))

        let withImg = AgentToolRunner.definitions(hasTavilyKey: false, hasKnowledgeBase: false, hasImageGeneration: true)
        XCTAssertTrue(withImg.contains(where: { $0.name == "generate_image" }))

        let sampleBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let call = LLMToolCall(
            id: "call_img_1",
            name: "generate_image",
            argumentsJSON: #"{"prompt":"A quiet Japanese tea room at dusk","size":"1536x1024","edit_latest_image":true}"#
        )
        let output = await AgentToolRunner.execute(
            call,
            searchHandler: { _ in SearchEvidence(query: "", searchedAt: Date(), sources: []) },
            imageGeneratorHandler: { prompt, size, editLatest in
                XCTAssertEqual(prompt, "A quiet Japanese tea room at dusk")
                XCTAssertEqual(size, .landscape)
                XCTAssertTrue(editLatest)
                let attachment = ImageGenerationService.makeAttachment(
                    from: GeneratedImageResult(imageData: sampleBytes, mimeType: "image/png", revisedPrompt: "Warm dusk lighting")
                )
                return AgentToolRunner.GeneratedImageToolOutput(
                    attachment: attachment,
                    providerName: "OpenAI",
                    modelID: "gpt-image-1",
                    revisedPrompt: "Warm dusk lighting"
                )
            }
        )

        XCTAssertTrue(output.record.succeeded)
        XCTAssertEqual(output.record.name, "generate_image")
        XCTAssertNotNil(output.generatedAttachment)
        XCTAssertEqual(output.generatedAttachment?.kind, .image)
        XCTAssertTrue(output.toolOutputJSON.contains("generated"))
        XCTAssertTrue(output.toolOutputJSON.contains("Warm dusk lighting"))
    }

    @MainActor
    func testChatEngineExecutesGenerateImageAndEditLatestImageTools() async throws {
        let (container, context, provider, conversation) = try makeInMemoryChatFixtures()
        _ = container
        conversation.assistanceSettings.enableAgentTools = true

        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        final class ToolLoopRecorder: @unchecked Sendable {
            var round = 0
            var receivedReferenceCount = 0
            var sawGenerateImageTool = false
        }
        let recorder = ToolLoopRecorder()

        let engine = ChatEngine(
            search: { _ in SearchEvidence(query: "", searchedAt: Date(), sources: []) },
            stream: { req in
                recorder.round += 1
                if req.tools.contains(where: { $0.name == "generate_image" }) {
                    recorder.sawGenerateImageTool = true
                }
                let round = recorder.round
                return AsyncThrowingStream { continuation in
                    if round == 1 {
                        continuation.yield(.toolCall(LLMToolCall(
                            id: "img_1",
                            name: "generate_image",
                            argumentsJSON: #"{"prompt":"Minimalist ink landscape","size":"1024x1024"}"#
                        )))
                    } else if round == 2 {
                        continuation.yield(.toolCall(LLMToolCall(
                            id: "img_2",
                            name: "generate_image",
                            argumentsJSON: #"{"prompt":"Add a small red boat","edit_latest_image":true}"#
                        )))
                    } else {
                        continuation.yield(.contentDelta("已为你绘制并修改了水墨小舟画作。"))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                }
            },
            imageGenerator: { prompt, _, ref in
                if ref != nil {
                    recorder.receivedReferenceCount += 1
                }
                let att = ImageGenerationService.makeAttachment(
                    from: GeneratedImageResult(imageData: pngHeader, mimeType: "image/png", revisedPrompt: prompt)
                )
                return AgentToolRunner.GeneratedImageToolOutput(
                    attachment: att,
                    providerName: "MockImage",
                    modelID: "gpt-image-1",
                    revisedPrompt: prompt
                )
            }
        )

        let outcome = engine.sendUserMessage(
            text: "帮我画一幅水墨画并加上红船",
            attachments: [],
            in: conversation,
            providers: [provider],
            context: context
        )
        XCTAssertEqual(outcome, .sent)
        await waitUntilIdle(engine: engine, conversationID: conversation.id)

        let assistant = try XCTUnwrap(conversation.messages.last(where: { $0.role == .assistant }))
        XCTAssertTrue(recorder.sawGenerateImageTool)
        XCTAssertEqual(recorder.receivedReferenceCount, 1)
        XCTAssertEqual(assistant.attachments.count, 2)
        XCTAssertEqual(assistant.assistanceMetadata.toolCalls.count, 2)
        XCTAssertTrue(assistant.assistanceMetadata.toolCalls.allSatisfy(\.succeeded))
        XCTAssertEqual(assistant.content, "已为你绘制并修改了水墨小舟画作。")
    }

    // MARK: - 4. Deep Research Multi-Step Autonomous Mode

    func testDeepResearchSubQueryParsingAndDeduplication() {
        let jsonWithThink = """
        <think>Need to decompose into 3 angles.</think>
        ```json
        ["Swift 6 concurrency migration guide", "Swift 6 strict concurrency performance", "swift 6 concurrency migration guide", "Actor isolation pitfalls Swift 6"]
        ```
        """
        let parsed = DeepResearchService.parseSubQueries(from: jsonWithThink, fallbackTopic: "Swift 6")
        XCTAssertEqual(parsed, [
            "Swift 6 concurrency migration guide",
            "Swift 6 strict concurrency performance",
            "Actor isolation pitfalls Swift 6"
        ])

        let bulletFallback = """
        1. 本地大模型量化方案对比
        2. GGUF 与 MLX 推理吞吐评测
        - Apple Silicon 内存带宽瓶颈
        """
        let bullets = DeepResearchService.parseSubQueries(from: bulletFallback, fallbackTopic: "本地推理")
        XCTAssertEqual(bullets.count, 3)
        XCTAssertEqual(bullets[0], "本地大模型量化方案对比")

        let emptyFallback = DeepResearchService.parseSubQueries(from: "   ", fallbackTopic: "量子纠错进展")
        XCTAssertEqual(emptyFallback, ["量子纠错进展"])
    }

    func testDeepResearchMergeEvidenceAndPageSelection() {
        let ev1 = SearchEvidence(
            query: "q1",
            searchedAt: Date(),
            sources: [
                SearchSource(id: 1, title: "Doc A", url: URL(string: "https://apple.com/swift")!, snippet: "Swift overview"),
                SearchSource(id: 2, title: "Paper PDF", url: URL(string: "https://arxiv.org/paper.pdf")!, snippet: "PDF paper"),
                SearchSource(id: 3, title: "Doc A2", url: URL(string: "https://apple.com/swift-2")!, snippet: "Second Apple page")
            ],
            credits: 1.0
        )
        let ev2 = SearchEvidence(
            query: "q2",
            searchedAt: Date(),
            sources: [
                SearchSource(id: 1, title: "Doc A Dup", url: URL(string: "https://apple.com/swift")!, snippet: "Duplicate"),
                SearchSource(id: 2, title: "Wiki", url: URL(string: "https://en.wikipedia.org/wiki/Swift")!, snippet: "Wiki article"),
                SearchSource(id: 3, title: "Blog", url: URL(string: "https://swift.org/blog")!, snippet: "Official blog")
            ],
            credits: 1.5
        )

        let merged = DeepResearchService.mergeEvidence(topic: "Swift", results: [ev1, ev2])
        XCTAssertEqual(merged.sources.count, 5)
        XCTAssertEqual(merged.sources.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(merged.credits, 2.5)

        let toRead = DeepResearchService.selectPagesToRead(from: merged.sources, limit: 3)
        XCTAssertEqual(toRead.count, 3)
        // Must skip paper.pdf and pick 3 distinct hosts: apple.com, en.wikipedia.org, swift.org
        XCTAssertEqual(Set(toRead.compactMap { $0.url.host }), Set(["apple.com", "en.wikipedia.org", "swift.org"]))
    }

    func testAssistanceMetadataDeepResearchTraceCodableBackwardCompatibility() throws {
        var meta = AssistanceMetadata()
        meta.deepResearchTrace = DeepResearchTrace(
            topic: "iOS 渲染优化",
            subQueries: ["SwiftUI LazyVStack", "TextKit 2 layout"],
            steps: [
                DeepResearchStep(phase: .planning, title: "已规划 2 个研究维度", detail: "SwiftUI · TextKit 2", succeeded: true, durationMs: 420)
            ],
            totalSources: 6,
            pagesRead: 2,
            isRunning: false,
            completedAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
        XCTAssertTrue(meta.hasPersistedContent)

        let encoded = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(AssistanceMetadata.self, from: encoded)
        XCTAssertEqual(decoded.deepResearchTrace, meta.deepResearchTrace)

        // Legacy payload without deepResearchTrace must decode cleanly with nil
        let legacyJSON = Data(#"{"memoryCount":2}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(AssistanceMetadata.self, from: legacyJSON)
        XCTAssertEqual(legacyDecoded.memoryCount, 2)
        XCTAssertNil(legacyDecoded.deepResearchTrace)
    }

    @MainActor
    func testChatEngineDeepResearchEndToEndWorkflow() async throws {
        let (container, context, provider, conversation) = try makeInMemoryChatFixtures()
        _ = container

        final class ResearchRecorder: @unchecked Sendable {
            let lock = NSLock()
            var searchedQueries: [String] = []
            var readURLs: [String] = []
            var synthesisSawDossier = false
            var llmCalls = 0
        }
        let recorder = ResearchRecorder()

        let engine = ChatEngine(
            search: { query in
                let idx = recorder.lock.withLock {
                    recorder.searchedQueries.append(query)
                    return recorder.searchedQueries.count
                }
                let host = "source\(idx).example.com"
                return SearchEvidence(
                    query: query,
                    searchedAt: Date(),
                    sources: [
                        SearchSource(
                            id: 1,
                            title: "Article \(idx) for \(query)",
                            url: URL(string: "https://\(host)/article-\(idx)")!,
                            snippet: "Detailed finding \(idx) about \(query)."
                        )
                    ],
                    credits: 1.0
                )
            },
            stream: { req in
                let callIdx = recorder.lock.withLock {
                    recorder.llmCalls += 1
                    let idx = recorder.llmCalls
                    let lastUserText = req.messages.last?.content ?? ""
                    if idx == 2 && lastUserText.contains("DEEP RESEARCH DOSSIER") && lastUserText.contains("Deeply Read Full-Page Excerpts") {
                        recorder.synthesisSawDossier = true
                    }
                    return idx
                }

                return AsyncThrowingStream { continuation in
                    if callIdx == 1 {
                        continuation.yield(.contentDelta(#"["端侧推理架构演进", "MLX 与 llama.cpp 性能对比", "移动端内存量化实践"]"#))
                    } else {
                        continuation.yield(.contentDelta("## 研究结论\n\n端侧推理在 Apple Silicon 上表现出色 [[1]](https://source1.example.com/article-1)。"))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                }
            },
            webpageReader: { url in
                recorder.lock.withLock {
                    recorder.readURLs.append(url.absoluteString)
                }
                return ReadablePage(
                    url: url,
                    title: "Full Article on \(url.host ?? "")",
                    text: String(repeating: "Verified technical benchmark data and architecture explanation. ", count: 6),
                    isTruncated: false
                )
            }
        )

        var options = GenerationOptions()
        options.useDeepResearch = true

        let outcome = engine.sendUserMessage(
            text: "深度调研端侧大模型推理方案",
            attachments: [],
            in: conversation,
            providers: [provider],
            context: context,
            options: options
        )
        XCTAssertEqual(outcome, .sent)
        await waitUntilIdle(engine: engine, conversationID: conversation.id)

        let assistant = try XCTUnwrap(conversation.messages.last(where: { $0.role == .assistant }))
        XCTAssertNil(assistant.errorMessage)
        XCTAssertTrue(assistant.content.contains("研究结论"))
        XCTAssertTrue(recorder.synthesisSawDossier)
        XCTAssertEqual(recorder.searchedQueries.count, 3)
        XCTAssertEqual(recorder.readURLs.count, 3)

        let trace = try XCTUnwrap(assistant.assistanceMetadata.deepResearchTrace)
        XCTAssertFalse(trace.isRunning)
        XCTAssertNotNil(trace.completedAt)
        XCTAssertEqual(trace.subQueries.count, 3)
        XCTAssertEqual(trace.totalSources, 3)
        XCTAssertEqual(trace.pagesRead, 3)
        XCTAssertEqual(assistant.assistanceMetadata.search?.sources.count, 3)
    }

    // MARK: - Helpers

    @MainActor
    private func makeInMemoryChatFixtures() throws -> (ModelContainer, ModelContext, ProviderConfig, Conversation) {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let model = ModelSpec(id: "gpt-4o", displayName: "GPT-4o", supportsVision: true, supportsReasoning: false)
        let provider = ProviderConfig(
            name: "TestOpenAI",
            protocolType: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            models: [model]
        )
        context.insert(provider)

        let conversation = Conversation(title: "Phase C Test", primaryTarget: provider.makeTarget(for: model))
        context.insert(conversation)
        try context.save()
        return (container, context, provider, conversation)
    }

    @MainActor
    private func waitUntilIdle(engine: ChatEngine, conversationID: UUID, timeoutSeconds: Double = 5.0) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while engine.isGenerating(in: conversationID) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
