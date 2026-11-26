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
