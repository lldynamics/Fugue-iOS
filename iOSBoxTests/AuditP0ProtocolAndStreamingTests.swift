import Foundation
import Testing
@testable import iOSBox

private struct RepeatedPatternBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    let pattern: [UInt8]
    let repeatCount: Int

    func makeAsyncIterator() -> Iterator {
        Iterator(pattern: pattern, totalBytes: pattern.count * repeatCount)
    }

    struct Iterator: AsyncIteratorProtocol {
        let pattern: [UInt8]
        let totalBytes: Int
        var offset = 0

        mutating func next() async throws -> UInt8? {
            guard offset < totalBytes, !pattern.isEmpty else { return nil }
            let byte = pattern[offset % pattern.count]
            offset += 1
            return byte
        }
    }
}

private final class LockedCounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var countValue = 0

    func increment() {
        lock.lock()
        countValue += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countValue
    }
}

private final class AuditP0MockRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int, [String: Any], URLProtocol, URLProtocolClient) -> Void

    static let shared = AuditP0MockRegistry()

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var counts: [String: Int] = [:]
    private var bodies: [String: [[String: Any]]] = [:]
    private var authHeaders: [String: [String]] = [:]

    func register(host: String, handler: @escaping Handler) {
        let key = host.lowercased()
        lock.lock()
        handlers[key] = handler
        counts[key] = 0
        bodies[key] = []
        authHeaders[key] = []
        lock.unlock()
    }

    func unregister(host: String) {
        let key = host.lowercased()
        lock.lock()
        handlers.removeValue(forKey: key)
        counts.removeValue(forKey: key)
        bodies.removeValue(forKey: key)
        authHeaders.removeValue(forKey: key)
        lock.unlock()
    }

    func count(for host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[host.lowercased(), default: 0]
    }

    func capturedBodies(for host: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return bodies[host.lowercased(), default: []]
    }

    func recordedAuth(for host: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return authHeaders[host.lowercased(), default: []]
    }

    func dispatch(request: URLRequest, proto: URLProtocol, client: URLProtocolClient) {
        let host = request.url?.host?.lowercased() ?? ""
        let auth = request.value(forHTTPHeaderField: "Authorization")
            ?? request.value(forHTTPHeaderField: "x-api-key")
            ?? request.value(forHTTPHeaderField: "x-goog-api-key")
            ?? ""
        let rawBody = Self.extractBody(from: request)
        let parsedBody = (rawBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]

        lock.lock()
        let attempt = counts[host, default: 0] + 1
        counts[host] = attempt
        bodies[host, default: []].append(parsedBody)
        authHeaders[host, default: []].append(auth)
        let handler = handlers[host]
        lock.unlock()

        guard let handler else {
            client.urlProtocol(proto, didFailWithError: URLError(.cannotFindHost))
            return
        }
        handler(request, attempt, parsedBody, proto, client)
    }

    private static func extractBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            if readCount <= 0 { break }
            data.append(buffer, count: readCount)
        }
        return data
    }
}

private final class AuditP0MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        AuditP0MockRegistry.shared.dispatch(request: request, proto: self, client: client)
    }

    override func stopLoading() {}
}

@Suite("Audit P0 Protocol Adapters, SSE Streaming & Key Pool Resilience")
struct AuditP0ProtocolAndStreamingTests {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditP0MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - 1. SSEDecoder Event Cap & Byte Cap

    @Test("SSEDecoder allows >12,000 events up to 200,000 and throws above 200,000")
    func sseDecoderAllowsLongReasoningStreamsAndEnforcesRaisedCap() async throws {
        #expect(SSEDecoder.maximumEvents == 200_000)
        #expect(SSEDecoder.maximumStreamBytes == 32 * 1024 * 1024)

        let unitEvent = Array("data:1\n\n".utf8)

        // 15,000 events (> old 12,000 cap) complete cleanly without throwing interruptedStream
        var count15k = 0
        for try await event in SSEDecoder.events(RepeatedPatternBytes(pattern: unitEvent, repeatCount: 15_000)) {
            if count15k == 0 { #expect(event == "1") }
            count15k += 1
        }
        #expect(count15k == 15_000)

        // 200,001 events (~1.6 MB, well below 32 MB stream cap) emit 200,000 then throw interruptedStream
        var emittedBeforeCap = 0
        var didThrowEventCap = false
        do {
            for try await _ in SSEDecoder.events(RepeatedPatternBytes(pattern: unitEvent, repeatCount: 200_001)) {
                emittedBeforeCap += 1
            }
        } catch LLMError.interruptedStream {
            didThrowEventCap = true
        }
        #expect(didThrowEventCap)
        #expect(emittedBeforeCap == 200_000)

        // > 32 MB of comment heartbeats still enforces the 32 MB byte cap
        let commentChunk = Array((": " + String(repeating: "k", count: 4096) + "\n").utf8)
        var didThrowByteCap = false
        do {
            for try await _ in SSEDecoder.events(RepeatedPatternBytes(pattern: commentChunk, repeatCount: 8_500)) {}
        } catch LLMError.interruptedStream {
            didThrowByteCap = true
        }
        #expect(didThrowByteCap)
    }

    // MARK: - 2. AnthropicAdapter Budget Clamping, Adaptive Temperature & message_delta Usage

    @Test("Anthropic clampMaxTokensTo4096 keeps budget_tokens < max_tokens and adaptive off passes temperature")
    func anthropicBudgetClampingAndAdaptiveTemperature() async throws {
        // 2a. Direct buildRequestBody with maxTokensCap: 4096 clamps budget_tokens strictly below 4096
        let clampedReq = LLMChatRequest(
            providerName: "Anthropic",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "sk-ant",
            customHeaders: [],
            modelID: "claude-sonnet-4-5",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Solve step by step")],
            temperature: 0.6,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: true,
            thinkingBudgetTokens: 16_384
        )
        let clampedBody = AnthropicAdapter.buildRequestBody(clampedReq, maxTokensCap: 4096)
        let maxTokens = try #require(clampedBody["max_tokens"] as? Int)
        let thinking = try #require(clampedBody["thinking"] as? [String: Any])
        let budget = try #require(thinking["budget_tokens"] as? Int)
        #expect(maxTokens == 4096)
        #expect(budget >= 1024)
        #expect(budget < maxTokens)

        // When finalMaxTokens <= 1024, thinking is omitted rather than sending an invalid budget
        let tinyCapBody = AnthropicAdapter.buildRequestBody(clampedReq, maxTokensCap: 1024)
        #expect(tinyCapBody["max_tokens"] as? Int == 1024)
        #expect(tinyCapBody["thinking"] == nil)
        #expect(tinyCapBody["temperature"] as? Double == 0.6)

        // 2b. End-to-end 400 degradation on max_tokens clamps budget_tokens without secondary 400
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let cache = GatewayCapabilityCache(defaults: nil)
        let host = "ant-clamp-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: host) }

        AuditP0MockRegistry.shared.register(host: host) { req, _, body, proto, client in
            let sentMax = (body["max_tokens"] as? Int) ?? 0
            if sentMax > 4096 {
                let r = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"max_tokens: 24576 > 4096 maximum allowed"}}"#.utf8))
                client.urlProtocolDidFinishLoading(proto)
                return
            }
            if let thinkObj = body["thinking"] as? [String: Any],
               let sentBudget = thinkObj["budget_tokens"] as? Int,
               sentBudget >= sentMax || sentBudget < 1024 {
                let r = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"max_tokens must be greater than thinking.budget_tokens"}}"#.utf8))
                client.urlProtocolDidFinishLoading(proto)
                return
            }
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
            let sse = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ClampedOK\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            client.urlProtocol(proto, didLoad: Data(sse.utf8))
            client.urlProtocolDidFinishLoading(proto)
        }

        let liveClampReq = LLMChatRequest(
            providerName: "Relay",
            protocolType: .anthropic,
            baseURL: "https://\(host)/v1",
            apiKey: "sk-ant",
            customHeaders: [],
            modelID: "claude-sonnet-4-5",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Hi")],
            temperature: 0.5,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: true,
            thinkingBudgetTokens: 16_384
        )
        var textOut = ""
        for try await ev in AnthropicAdapter.streamChat(liveClampReq, capabilityCache: cache, session: session) {
            if case .contentDelta(let chunk) = ev { textOut += chunk }
        }
        #expect(textOut == "ClampedOK")
        #expect(AuditP0MockRegistry.shared.count(for: host) == 2)
        #expect(!cache.isUnsupported(.thinkingConfig, protocolType: .anthropic, baseURL: "https://\(host)/v1", modelID: "claude-sonnet-4-5"))

        // 2c. Adaptive-thinking models pass temperature when thinking is off, omit when thinking is on
        for modelID in ["claude-sonnet-5-5", "claude-opus-4-7"] {
            let offBody = AnthropicAdapter.buildRequestBody(LLMChatRequest(
                providerName: "Anthropic",
                protocolType: .anthropic,
                baseURL: "https://api.anthropic.com/v1",
                apiKey: "sk-ant",
                customHeaders: [],
                modelID: modelID,
                supportsReasoning: true,
                systemPrompt: "",
                messages: [LLMPromptMessage(role: .user, content: "Hi")],
                temperature: 0.65,
                topP: 1.0,
                maxOutputTokens: 4096,
                enableThinking: false,
                thinkingBudgetTokens: 4096
            ))
            #expect(offBody["thinking"] == nil)
            #expect(offBody["temperature"] as? Double == 0.65)

            let onBody = AnthropicAdapter.buildRequestBody(LLMChatRequest(
                providerName: "Anthropic",
                protocolType: .anthropic,
                baseURL: "https://api.anthropic.com/v1",
                apiKey: "sk-ant",
                customHeaders: [],
                modelID: modelID,
                supportsReasoning: true,
                systemPrompt: "",
                messages: [LLMPromptMessage(role: .user, content: "Hi")],
                temperature: 0.65,
                topP: 1.0,
                maxOutputTokens: 4096,
                enableThinking: true,
                thinkingBudgetTokens: 4096
            ))
            #expect((onBody["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
            #expect(onBody["temperature"] == nil)
        }
    }

    @Test("Anthropic message_delta merges updated cumulative input and cache tokens from server-side tools")
    func anthropicMessageDeltaMergesCumulativeServerToolTokens() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let host = "ant-usage-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: host) }

        AuditP0MockRegistry.shared.register(host: host) { req, _, _, proto, client in
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
            let sse = """
            data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":40,"cache_creation_input_tokens":10,"output_tokens":1}}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Search answer"}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":380,"cache_read_input_tokens":160,"cache_creation_input_tokens":25,"output_tokens":95}}

            data: {"type":"message_stop"}


            """
            client.urlProtocol(proto, didLoad: Data(sse.utf8))
            client.urlProtocolDidFinishLoading(proto)
        }

        let req = LLMChatRequest(
            providerName: "Anthropic",
            protocolType: .anthropic,
            baseURL: "https://\(host)/v1",
            apiKey: "sk-ant",
            customHeaders: [],
            modelID: "claude-sonnet-4-5",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Latest news")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: 2048,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enableNativeSearch: true
        )

        var lastPromptTokens: Int?
        var lastCompletionTokens: Int?
        var lastCachedRead: Int?
        var lastCacheWrite: Int?
        for try await ev in AnthropicAdapter.streamChat(req, session: session) {
            if case .usage(let p, let c) = ev {
                lastPromptTokens = p
                lastCompletionTokens = c
            }
            if case .cacheUsage(let r, let w) = ev {
                lastCachedRead = r
                lastCacheWrite = w
            }
        }
        #expect(lastPromptTokens == 380 + 160 + 25)
        #expect(lastCompletionTokens == 95)
        #expect(lastCachedRead == 160)
        #expect(lastCacheWrite == 25)
    }

    @Test("Generic 'tools' HTTP 400 with custom agent tools does not poison .nativeSearch capability cache")
    func genericTools400DoesNotPoisonNativeSearchWhenCustomToolsActive() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let cache = GatewayCapabilityCache(defaults: nil)
        let customTool = LLMToolDefinition(
            name: "read_webpage",
            description: "Fetch webpage",
            parametersSchemaJSON: #"{"type":"object","properties":{"url":{"type":"string"}}}"#
        )

        // Generic "tools" schema error across Anthropic, OpenAIResponses, and Gemini must NOT disable or cache .nativeSearch
        for proto in [APIProtocolType.anthropic, .openAIResponses, .gemini] {
            let host = "tools400-\(proto.rawValue)-\(UUID().uuidString.lowercased()).invalid"
            defer { AuditP0MockRegistry.shared.unregister(host: host) }

            AuditP0MockRegistry.shared.register(host: host) { req, _, _, urlProto, client in
                let r = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client.urlProtocol(urlProto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(urlProto, didLoad: Data(#"{"error":{"message":"Invalid parameter in tools[0]: schema rejection"}}"#.utf8))
                client.urlProtocolDidFinishLoading(urlProto)
            }

            let baseURL = proto == .gemini ? "https://\(host)/v1beta" : "https://\(host)/v1"
            let req = LLMChatRequest(
                providerName: "Gateway",
                protocolType: proto,
                baseURL: baseURL,
                apiKey: "sk-key",
                customHeaders: [],
                modelID: "test-model",
                supportsReasoning: false,
                systemPrompt: "",
                messages: [LLMPromptMessage(role: .user, content: "Read")],
                temperature: nil,
                topP: 1.0,
                maxOutputTokens: 1024,
                enableThinking: false,
                thinkingBudgetTokens: 1024,
                enableNativeSearch: true,
                tools: [customTool]
            )

            let stream: AsyncThrowingStream<LLMStreamEvent, Error> = switch proto {
            case .anthropic: AnthropicAdapter.streamChat(req, capabilityCache: cache, session: session)
            case .openAIResponses: OpenAIResponsesAdapter.streamChat(req, capabilityCache: cache, session: session)
            case .gemini: GeminiAdapter.streamChat(req, capabilityCache: cache, session: session)
            case .openAICompatible: OpenAICompatibleAdapter.streamChat(req, capabilityCache: cache, session: session)
            }

            var caught400 = false
            do {
                for try await _ in stream {}
            } catch LLMError.httpError(let status, _) {
                caught400 = (status == 400)
            }
            #expect(caught400)
            #expect(AuditP0MockRegistry.shared.count(for: host) == 1, "Must not waste a retry stripping native search when custom tools caused generic tools 400")
            #expect(!cache.isUnsupported(.nativeSearch, protocolType: proto, baseURL: baseURL, modelID: "test-model"))
        }

        // Even when a recoverable 400 (e.g. max_tokens > 4096) also mentions "tools" and the retry succeeds (200 OK),
        // .nativeSearch must stay active and never be written into the 7-day GatewayCapabilityCache.
        let mixedHost = "mixed-tools-max-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: mixedHost) }
        AuditP0MockRegistry.shared.register(host: mixedHost) { req, _, body, urlProto, client in
            let sentMax = (body["max_tokens"] as? Int) ?? 0
            if sentMax > 4096 {
                let r = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client.urlProtocol(urlProto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(urlProto, didLoad: Data(#"{"error":{"message":"max_tokens exceeds 4096 when tools are provided"}}"#.utf8))
                client.urlProtocolDidFinishLoading(urlProto)
                return
            }
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(urlProto, didReceive: r, cacheStoragePolicy: .notAllowed)
            let sse = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"KeptSearch\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            client.urlProtocol(urlProto, didLoad: Data(sse.utf8))
            client.urlProtocolDidFinishLoading(urlProto)
        }
        let mixedBase = "https://\(mixedHost)/v1"
        let mixedReq = LLMChatRequest(
            providerName: "AnthropicRelay",
            protocolType: .anthropic,
            baseURL: mixedBase,
            apiKey: "sk-ant",
            customHeaders: [],
            modelID: "claude-sonnet-4-5",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Search & read")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: 8192,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enableNativeSearch: true,
            tools: [customTool]
        )
        var mixedOut = ""
        for try await ev in AnthropicAdapter.streamChat(mixedReq, capabilityCache: cache, session: session) {
            if case .contentDelta(let d) = ev { mixedOut += d }
        }
        #expect(mixedOut == "KeptSearch")
        #expect(!cache.isUnsupported(.nativeSearch, protocolType: .anthropic, baseURL: mixedBase, modelID: "claude-sonnet-4-5"))
        let acceptedTools = (AuditP0MockRegistry.shared.capturedBodies(for: mixedHost).last?["tools"] as? [[String: Any]]) ?? []
        #expect(acceptedTools.contains(where: { ($0["type"] as? String) == "web_search_20250305" }))

        // Conversely, when error explicitly names `web_search` even with custom tools active, native search degrades and caches cleanly
        let explicitHost = "explicit-ws-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: explicitHost) }
        AuditP0MockRegistry.shared.register(host: explicitHost) { req, _, body, urlProto, client in
            let tools = (body["tools"] as? [[String: Any]]) ?? []
            if tools.contains(where: { ($0["type"] as? String) == "web_search_20250305" }) {
                let r = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client.urlProtocol(urlProto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(urlProto, didLoad: Data(#"{"error":{"message":"Tool type web_search_20250305 is not enabled"}}"#.utf8))
                client.urlProtocolDidFinishLoading(urlProto)
                return
            }
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(urlProto, didReceive: r, cacheStoragePolicy: .notAllowed)
            let sse = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"FallbackOK\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            client.urlProtocol(urlProto, didLoad: Data(sse.utf8))
            client.urlProtocolDidFinishLoading(urlProto)
        }

        let explicitBase = "https://\(explicitHost)/v1"
        let explicitReq = LLMChatRequest(
            providerName: "AnthropicRelay",
            protocolType: .anthropic,
            baseURL: explicitBase,
            apiKey: "sk-ant",
            customHeaders: [],
            modelID: "claude-sonnet-4-5",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Check")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: 1024,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enableNativeSearch: true,
            tools: [customTool]
        )
        var out = ""
        for try await ev in AnthropicAdapter.streamChat(explicitReq, capabilityCache: cache, session: session) {
            if case .contentDelta(let d) = ev { out += d }
        }
        #expect(out == "FallbackOK")
        #expect(cache.isUnsupported(.nativeSearch, protocolType: .anthropic, baseURL: explicitBase, modelID: "claude-sonnet-4-5"))
    }

    // MARK: - 3. OpenAIResponsesAdapter Turn Preservation, Safety Refusals & Non-Streaming Watchdog

    @Test("OpenAIResponsesAdapter preserves stripped-attachment turns, surfaces refusals, and feeds watchdog in non-streaming mode")
    func openAIResponsesTurnPreservationRefusalsAndNonStreamingWatchdog() async throws {
        // 3a. Historical turns whose image/document payloads were stripped emit compact placeholders instead of dropping turns
        let strippedImage = MessageAttachment(
            kind: .image,
            fileName: "chart.png",
            mimeType: "image/png",
            dataBase64: nil,
            extractedText: nil,
            byteSize: 2048
        )
        let strippedDoc = MessageAttachment(
            kind: .document,
            fileName: "report.pdf",
            mimeType: "application/pdf",
            dataBase64: nil,
            extractedText: nil,
            byteSize: 4096
        )
        let historyReq = LLMChatRequest(
            providerName: "OpenAI",
            protocolType: .openAIResponses,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [
                LLMPromptMessage(role: .user, content: "", attachments: [strippedImage]),
                LLMPromptMessage(role: .assistant, content: "I see the chart."),
                LLMPromptMessage(role: .user, content: "", attachments: [strippedDoc]),
                LLMPromptMessage(role: .assistant, content: "", attachments: [strippedImage]),
                LLMPromptMessage(role: .user, content: "Summarize everything.")
            ],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: 512,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )

        let body = OpenAIResponsesAdapter.buildRequestBody(historyReq)
        let inputItems = try #require(body["input"] as? [[String: Any]])
        #expect(inputItems.count == 5)
        #expect(inputItems.compactMap { $0["role"] as? String } == ["user", "assistant", "user", "assistant", "user"])

        let firstUserContent = try #require(inputItems[0]["content"] as? [[String: Any]])
        #expect(firstUserContent.first?["type"] as? String == "input_text")
        #expect(firstUserContent.first?["text"] as? String == "[图片]")

        let secondUserContent = try #require(inputItems[2]["content"] as? [[String: Any]])
        #expect(secondUserContent.first?["text"] as? String == "[附件]")

        let secondAssistantContent = try #require(inputItems[3]["content"] as? [[String: Any]])
        #expect(secondAssistantContent.first?["type"] as? String == "output_text")
        #expect(secondAssistantContent.first?["text"] as? String == "[图片]")

        // 3b. SSE streaming refusal delta & non-streaming refusal JSON
        var sseState = OpenAIResponsesAdapter.StreamParserState()
        let r1 = try OpenAIResponsesAdapter.parseSSEEventObject(
            ["type": "response.refusal.delta", "delta": "Sorry, I cannot "],
            state: &sseState
        )
        let r2 = try OpenAIResponsesAdapter.parseSSEEventObject(
            ["type": "response.refusal.delta", "delta": "assist with that."],
            state: &sseState
        )
        var sseRefusal = ""
        for ev in r1 + r2 {
            if case .contentDelta(let text) = ev { sseRefusal += text }
        }
        #expect(sseRefusal == "Sorry, I cannot assist with that.")

        let nonStreamJSON = Data(#"""
        {
          "output": [
            {
              "type": "message",
              "role": "assistant",
              "content": [
                {"type": "refusal", "refusal": "Request declined by safety policy."}
              ]
            }
          ],
          "usage": {"input_tokens": 12, "output_tokens": 7}
        }
        """#.utf8)
        let parsedEvents = try OpenAIResponsesAdapter.parseNonStreamingResponse(nonStreamJSON)
        var nonStreamText = ""
        for ev in parsedEvents {
            if case .contentDelta(let text) = ev { nonStreamText += text }
        }
        #expect(nonStreamText == "Request declined by safety policy.")

        // 3c. Non-streaming byte reader feeds inactivity watchdog as chunks arrive
        let activityTicks = LockedCounterBox()
        let rawBytes = Array(nonStreamJSON)
        let readBack = try await OpenAIResponsesAdapter.readNonStreamingData(
            RepeatedPatternBytes(pattern: rawBytes, repeatCount: 1),
            onActivity: { activityTicks.increment() }
        )
        #expect(readBack == nonStreamJSON)
        #expect(activityTicks.count > 2)

        // End-to-end slow trickled application/json response stays alive past a single idle timeout window
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let slowHost = "resp-slow-json-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: slowHost) }

        AuditP0MockRegistry.shared.register(host: slowHost) { req, _, _, proto, client in
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
            let chunks = [
                #"{"output":[{"type":"message","content":["#,
                #"{"type":"refusal","refusal":"Slow non-streaming "#,
                #"refusal survived watchdog."}]}]}"#
            ]
            Task {
                for chunk in chunks {
                    try? await Task.sleep(for: .milliseconds(55))
                    client.urlProtocol(proto, didLoad: Data(chunk.utf8))
                }
                client.urlProtocolDidFinishLoading(proto)
            }
        }

        let slowReq = LLMChatRequest(
            providerName: "SlowJSONRelay",
            protocolType: .openAIResponses,
            baseURL: "https://\(slowHost)/v1",
            apiKey: "sk-resp",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Test")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: 256,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            idleTimeoutSeconds: 0.13
        )
        var sawNonStreamingFlag = false
        var trickledText = ""
        for try await ev in OpenAIResponsesAdapter.streamChat(slowReq, session: session) {
            if case .nonStreamingResponse = ev { sawNonStreamingFlag = true }
            if case .contentDelta(let d) = ev { trickledText += d }
        }
        #expect(sawNonStreamingFlag)
        #expect(trickledText == "Slow non-streaming refusal survived watchdog.")
    }

    // MARK: - 4. GeminiAdapter Non-Empty Text Part thoughtSignature

    @Test("GeminiAdapter captures thoughtSignature attached to a non-empty visible text part")
    func geminiCapturesThoughtSignatureOnNonEmptyTextPart() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let host = "gemini-sig-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: host) }

        AuditP0MockRegistry.shared.register(host: host) { req, _, _, proto, client in
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
            let sse = """
            data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Reasoning part. ","thought":true}]}}]}

            data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Visible answer with signature.","thoughtSignature":"sig-nonempty-text-42"}]},"finishReason":"STOP"}]}


            """
            client.urlProtocol(proto, didLoad: Data(sse.utf8))
            client.urlProtocolDidFinishLoading(proto)
        }

        let req = LLMChatRequest(
            providerName: "Gemini",
            protocolType: .gemini,
            baseURL: "https://\(host)/v1beta",
            apiKey: "AIzaTest",
            customHeaders: [],
            modelID: "gemini-3-pro-preview",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Explain")],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: 1024,
            enableThinking: true,
            thinkingBudgetTokens: 4096
        )

        var reasoning = ""
        var visible = ""
        var thinkingBlocks: [LLMThinkingBlock] = []
        for try await ev in GeminiAdapter.streamChat(req, session: session) {
            switch ev {
            case .reasoningDelta(let r): reasoning += r
            case .contentDelta(let c): visible += c
            case .thinkingBlock(let b): thinkingBlocks.append(b)
            default: break
            }
        }
        #expect(reasoning == "Reasoning part. ")
        #expect(visible == "Visible answer with signature.")
        #expect(thinkingBlocks.count == 1)
        #expect(thinkingBlocks.first?.thinking == "Reasoning part. ")
        #expect(thinkingBlocks.first?.signature == "sig-nonempty-text-42")
    }

    // MARK: - 5. Multi-Key Rotation Pool Marks Final Key Unhealthy

    @Test("LLMClient marks the final key unhealthy when all keys in a multi-key pool fail with 401/429")
    func multiKeyPoolMarksFinalKeyUnhealthyOnStreamingAndFetchModels() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        // 5a. Streaming loop: sk-1 fails with 429 (Retry-After: 5s), final key sk-2 fails with 401 (300s cooldown)
        let streamHost = "pool-last-stream-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: streamHost) }

        AuditP0MockRegistry.shared.register(host: streamHost) { req, _, _, proto, client in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            if auth == "Bearer sk-1" {
                let r = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "5"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"rate limit"}}"#.utf8))
                client.urlProtocolDidFinishLoading(proto)
            } else {
                let r = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"revoked key"}}"#.utf8))
                client.urlProtocolDidFinishLoading(proto)
            }
        }

        let streamRouter = APIKeyPoolRouter()
        let streamBaseURL = "https://\(streamHost)/v1"
        let streamReq = LLMChatRequest(
            providerName: "Pool",
            protocolType: .openAIResponses,
            baseURL: streamBaseURL,
            apiKey: "sk-1",
            apiKeys: ["sk-2"],
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "Hi")],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: 256,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )

        var streamFailed401 = false
        do {
            for try await _ in OpenAIResponsesAdapter.streamChat(streamReq, keyRouter: streamRouter, session: session) {}
        } catch LLMError.httpError(let code, _) {
            streamFailed401 = (code == 401)
        }
        #expect(streamFailed401)
        #expect(AuditP0MockRegistry.shared.recordedAuth(for: streamHost) == ["Bearer sk-1", "Bearer sk-2"])
        #expect(streamRouter.isCooling(key: "sk-1", protocolType: .openAIResponses, baseURL: streamBaseURL))
        #expect(streamRouter.isCooling(key: "sk-2", protocolType: .openAIResponses, baseURL: streamBaseURL))

        // At +6s, sk-1's 5s rate-limit cooldown has expired while sk-2's 300s auth cooldown remains active,
        // so consecutive round-robin selections must BOTH put sk-1 first instead of treating sk-2 as healthy.
        let afterSixSeconds = ContinuousClock.now.advanced(by: .seconds(6))
        let nextOrder1 = try streamRouter.orderedKeys(from: ["sk-1", "sk-2"], protocolType: .openAIResponses, baseURL: streamBaseURL, now: afterSixSeconds)
        let nextOrder2 = try streamRouter.orderedKeys(from: ["sk-1", "sk-2"], protocolType: .openAIResponses, baseURL: streamBaseURL, now: afterSixSeconds)
        #expect(nextOrder1 == ["sk-1", "sk-2"])
        #expect(nextOrder2 == ["sk-1", "sk-2"])

        // 5b. Non-streaming fetchModels loop: final key failing with 429 is also marked unhealthy
        let catalogHost = "pool-last-cat-\(UUID().uuidString.lowercased()).invalid"
        defer { AuditP0MockRegistry.shared.unregister(host: catalogHost) }

        AuditP0MockRegistry.shared.register(host: catalogHost) { req, _, _, proto, client in
            let key = req.value(forHTTPHeaderField: "x-api-key") ?? ""
            let status = (key == "sk-cat-1") ? 401 : 429
            let r = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"pool exhausted"}}"#.utf8))
            client.urlProtocolDidFinishLoading(proto)
        }

        let catalogRouter = APIKeyPoolRouter()
        let catalogBaseURL = "https://\(catalogHost)/v1"
        var catalogFailed429 = false
        do {
            _ = try await LLMClient.fetchModels(
                providerName: "AnthropicPool",
                protocolType: .anthropic,
                baseURL: catalogBaseURL,
                apiKey: "sk-cat-1",
                apiKeys: ["sk-cat-2"],
                customHeaders: [],
                keyRouter: catalogRouter,
                session: session
            )
        } catch LLMError.httpError(let code, _) {
            catalogFailed429 = (code == 429)
        }
        #expect(catalogFailed429)
        #expect(AuditP0MockRegistry.shared.recordedAuth(for: catalogHost) == ["sk-cat-1", "sk-cat-2"])
        #expect(catalogRouter.isCooling(key: "sk-cat-1", protocolType: .anthropic, baseURL: catalogBaseURL))
        #expect(catalogRouter.isCooling(key: "sk-cat-2", protocolType: .anthropic, baseURL: catalogBaseURL))
    }
}
