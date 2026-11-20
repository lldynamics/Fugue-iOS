import Foundation
import SwiftData
import XCTest
@testable import iOSBox

private final class ResilienceMockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Int, URLProtocol, URLProtocolClient) -> Void

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private static var counts: [String: Int] = [:]
    private static var authHeaders: [String: [String]] = [:]
    private static var stopHooks: [String: @Sendable () -> Void] = [:]

    static func register(
        host: String,
        onStop: (@Sendable () -> Void)? = nil,
        handler: @escaping Handler
    ) {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        handlers[key] = handler
        counts[key] = 0
        authHeaders[key] = []
        if let onStop {
            stopHooks[key] = onStop
        } else {
            stopHooks.removeValue(forKey: key)
        }
    }

    static func count(for host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[host.lowercased(), default: 0]
    }

    static func recordedAuthHeaders(for host: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return authHeaders[host.lowercased(), default: []]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        let host = request.url?.host?.lowercased() ?? ""
        let auth = request.value(forHTTPHeaderField: "Authorization")
            ?? request.value(forHTTPHeaderField: "x-api-key")
            ?? request.value(forHTTPHeaderField: "x-goog-api-key")
            ?? ""

        Self.lock.lock()
        let attempt = Self.counts[host, default: 0] + 1
        Self.counts[host] = attempt
        Self.authHeaders[host, default: []].append(auth)
        let handler = Self.handlers[host]
        Self.lock.unlock()

        guard let handler else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        handler(request, attempt, self, client)
    }

    override func stopLoading() {
        let host = request.url?.host?.lowercased() ?? ""
        Self.lock.lock()
        let hook = Self.stopHooks.removeValue(forKey: host)
        Self.lock.unlock()
        hook?()
    }
}

@MainActor
final class ConnectionResilienceTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResilienceMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - 1. Stream Idle Watchdog & Heartbeat Keep-Alive

    func testStreamIdleWatchdogFailsHungStreamTriggersFallbackAndHonorsHeartbeats() async throws {
        // Verify smart default idle timeouts
        let stdReq = LLMChatRequest(
            providerName: "Cloud",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-1",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: nil,
            topP: 1,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )
        let reasoningReq = LLMChatRequest(
            providerName: "Cloud",
            protocolType: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            apiKey: "sk-1",
            customHeaders: [],
            modelID: "deepseek-reasoner",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: nil,
            topP: 1,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )
        let customReq = LLMChatRequest(
            providerName: "Custom",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-1",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: nil,
            topP: 1,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            idleTimeoutSeconds: 30
        )
        XCTAssertEqual(LLMClient.resolvedIdleTimeout(for: stdReq), 45)
        XCTAssertEqual(LLMClient.resolvedIdleTimeout(for: reasoningReq), 120)
        XCTAssertEqual(LLMClient.resolvedIdleTimeout(for: customReq), 30)

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        // 1a. Hung stream after HTTP 200 headers times out fast, closes socket, and triggers backup fallback in ChatEngine
        let hungHost = "hung-\(UUID().uuidString.lowercased()).invalid"
        let backupHost = "backup-\(UUID().uuidString.lowercased()).invalid"
        let hungClosed = expectation(description: "Hung upstream socket closed by watchdog")

        ResilienceMockURLProtocol.register(host: hungHost, onStop: { hungClosed.fulfill() }) { req, _, proto, client in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(proto, didReceive: resp, cacheStoragePolicy: .notAllowed)
            // Intentionally never finish or send body bytes
        }
        ResilienceMockURLProtocol.register(host: backupHost) { req, _, proto, client in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(proto, didReceive: resp, cacheStoragePolicy: .notAllowed)
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Backup rescued!\"}}]}\n\ndata: [DONE]\n\n"
            client.urlProtocol(proto, didLoad: Data(body.utf8))
            client.urlProtocolDidFinishLoading(proto)
        }

        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let primaryProvider = ProviderConfig(name: "HungRelay", protocolType: .openAICompatible, baseURL: "https://\(hungHost)/v1", models: [ModelSpec(id: "m1")])
        let backupProvider = ProviderConfig(name: "HealthyBackup", protocolType: .openAICompatible, baseURL: "https://\(backupHost)/v1", models: [ModelSpec(id: "m2")])
        context.insert(primaryProvider)
        context.insert(backupProvider)
        defer {
            KeychainService.shared.deleteAPIKey(for: primaryProvider.id)
            KeychainService.shared.deleteAPIKey(for: backupProvider.id)
        }
        _ = KeychainService.shared.saveAPIKey("sk-p", for: primaryProvider.id)
        _ = KeychainService.shared.saveAPIKey("sk-b", for: backupProvider.id)

        let conv = Conversation(primaryTarget: primaryProvider.makeTarget(for: primaryProvider.models[0]))
        conv.assistanceSettings.fallbackEnabled = true
        conv.assistanceSettings.fallbackTargets = [backupProvider.makeTarget(for: backupProvider.models[0])]
        context.insert(conv)
        try context.save()

        let engine = ChatEngine { req in
            let fastReq = LLMChatRequest(
                providerName: req.providerName,
                protocolType: req.protocolType,
                baseURL: req.baseURL,
                apiKey: req.apiKey,
                apiKeys: req.apiKeys,
                customHeaders: req.customHeaders,
                modelID: req.modelID,
                supportsReasoning: req.supportsReasoning,
                systemPrompt: req.systemPrompt,
                messages: req.messages,
                temperature: req.temperature,
                topP: req.topP,
                maxOutputTokens: req.maxOutputTokens,
                enableThinking: req.enableThinking,
                thinkingBudgetTokens: req.thinkingBudgetTokens,
                idleTimeoutSeconds: 0.10
            )
            return OpenAICompatibleAdapter.streamChat(fastReq, session: session)
        }

        XCTAssertEqual(engine.sendUserMessage(text: "Hello", attachments: [], in: conv, providers: [primaryProvider, backupProvider], context: context), .sent)
        await fulfillment(of: [hungClosed], timeout: 2.0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while engine.isGenerating(in: conv.id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(engine.isGenerating(in: conv.id))
        let reply = try XCTUnwrap(conv.sortedMessages.last)
        XCTAssertEqual(reply.content, "Backup rescued!")
        XCTAssertEqual(reply.providerID, backupProvider.id)
        XCTAssertEqual(reply.assistanceMetadata.fallbackNotices.count, 1)

        // 1b. SSE comment heartbeats (`: keep-alive\n`) keep watchdog alive past single idle window
        let heartbeatHost = "heartbeat-\(UUID().uuidString.lowercased()).invalid"
        ResilienceMockURLProtocol.register(host: heartbeatHost) { req, _, proto, client in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(proto, didReceive: resp, cacheStoragePolicy: .notAllowed)
            Task {
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(55))
                    client.urlProtocol(proto, didLoad: Data(": keep-alive\n\n".utf8))
                }
                let donePayload = "data: {\"choices\":[{\"delta\":{\"content\":\"Alive\"}}]}\n\ndata: [DONE]\n\n"
                client.urlProtocol(proto, didLoad: Data(donePayload.utf8))
                client.urlProtocolDidFinishLoading(proto)
            }
        }
        let heartbeatReq = LLMChatRequest(
            providerName: "HB",
            protocolType: .openAICompatible,
            baseURL: "https://\(heartbeatHost)/v1",
            apiKey: "sk-hb",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "ping")],
            temperature: nil,
            topP: 1,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            idleTimeoutSeconds: 0.14
        )
        var collected = ""
        for try await ev in OpenAICompatibleAdapter.streamChat(heartbeatReq, session: session) {
            if case .contentDelta(let d) = ev { collected += d }
        }
        XCTAssertEqual(collected, "Alive")
    }

    // MARK: - 2. Retry-After, Request-ID Enrichment, and Single-Key Transient Retry

    func testTransientBackoffRetryRetryAfterParsingAndRequestIDEnrichment() async throws {
        let url = URL(string: "https://api.example.com/v1/chat/completions")!
        let secsResp = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "1.25"])!
        XCTAssertEqual(try XCTUnwrap(LLMClient.parseRetryAfter(from: secsResp)), 1.25, accuracy: 0.001)

        let msResp = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["retry-after-ms": "250"])!
        XCTAssertEqual(try XCTUnwrap(LLMClient.parseRetryAfter(from: msResp)), 0.25, accuracy: 0.001)

        let refDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T02:00:00Z"))
        let dateResp = HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "Thu, 19 Nov 2026 02:00:03 GMT"])!
        XCTAssertEqual(try XCTUnwrap(LLMClient.parseRetryAfter(from: dateResp, now: refDate)), 3.0, accuracy: 0.001)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let router = APIKeyPoolRouter()

        // 2a. Transient 503 with short retry-after-ms retries once and succeeds
        let transientHost = "transient503-\(UUID().uuidString.lowercased()).invalid"
        ResilienceMockURLProtocol.register(host: transientHost) { req, attempt, proto, client in
            if attempt == 1 {
                let r = HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "retry-after-ms": "60"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"upstream overloaded"}}"#.utf8))
                client.urlProtocolDidFinishLoading(proto)
            } else {
                let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"Recovered\"}}]}\n\ndata: [DONE]\n\n".utf8))
                client.urlProtocolDidFinishLoading(proto)
            }
        }

        let req503 = LLMChatRequest(
            providerName: "Gateway",
            protocolType: .openAICompatible,
            baseURL: "https://\(transientHost)/v1",
            apiKey: "sk-single",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: nil,
            topP: 1,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )
        var retryStatuses: [Int] = []
        var text503 = ""
        for try await ev in OpenAICompatibleAdapter.streamChat(req503, keyRouter: router, session: session) {
            if case .retrying(let status) = ev { retryStatuses.append(status) }
            if case .contentDelta(let d) = ev { text503 += d }
        }
        XCTAssertEqual(retryStatuses, [503])
        XCTAssertEqual(text503, "Recovered")
        XCTAssertEqual(ResilienceMockURLProtocol.count(for: transientHost), 2)

        // 2b. 429 with long Retry-After (60s) fails immediately without stalling and surfaces x-request-id
        let longRateHost = "rate60-\(UUID().uuidString.lowercased()).invalid"
        ResilienceMockURLProtocol.register(host: longRateHost) { req, _, proto, client in
            let r = HTTPURLResponse(
                url: req.url!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "Retry-After": "60",
                    "x-request-id": "req_998877"
                ]
            )!
            client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"Rate limit exceeded"}}"#.utf8))
            client.urlProtocolDidFinishLoading(proto)
        }
        let req429 = LLMChatRequest(
            providerName: "Gateway",
            protocolType: .openAICompatible,
            baseURL: "https://\(longRateHost)/v1",
            apiKey: "sk-single",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: nil,
            topP: 1,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )
        do {
            for try await _ in OpenAICompatibleAdapter.streamChat(req429, keyRouter: router, session: session) {}
            XCTFail("Expected HTTP 429")
        } catch LLMError.httpError(let status, let detail) {
            XCTAssertEqual(status, 429)
            XCTAssertTrue(detail.contains("Rate limit exceeded"))
            XCTAssertTrue(detail.contains("req_998877"))
        }
        XCTAssertEqual(ResilienceMockURLProtocol.count(for: longRateHost), 1, "Long Retry-After must fail fast")
    }

    // MARK: - 3. Multi-Key Pool Round-Robin, Cooldown Failover, and Encrypted Backup

    func testMultiKeyPoolRoundRobinFailoverAndEncryptedBackupPersistence() async throws {
        let router = APIKeyPoolRouter()
        let baseURL = "https://pool-test.invalid/v1"

        // Round-robin distributes starting key across turns
        let r1 = router.orderedKeys(from: ["sk-a", "sk-b", "sk-c"], protocolType: .openAICompatible, baseURL: baseURL)
        let r2 = router.orderedKeys(from: ["sk-a", "sk-b", "sk-c"], protocolType: .openAICompatible, baseURL: baseURL)
        let r3 = router.orderedKeys(from: ["sk-a", "sk-b", "sk-c"], protocolType: .openAICompatible, baseURL: baseURL)
        XCTAssertEqual(r1.first, "sk-a")
        XCTAssertEqual(r2.first, "sk-b")
        XCTAssertEqual(r3.first, "sk-c")

        // Live HTTP failover: sk-dead returns 429 (even with Retry-After: 120), immediately switches to sk-good in 0ms
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let poolHost = "multipool-\(UUID().uuidString.lowercased()).invalid"
        ResilienceMockURLProtocol.register(host: poolHost) { req, _, proto, client in
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            if auth == "Bearer sk-dead" {
                let r = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "120"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data(#"{"error":{"message":"key quota exhausted"}}"#.utf8))
                client.urlProtocolDidFinishLoading(proto)
            } else {
                let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                client.urlProtocol(proto, didReceive: r, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"From \(auth)\"}}]}\n\ndata: [DONE]\n\n".utf8))
                client.urlProtocolDidFinishLoading(proto)
            }
        }

        let liveRouter = APIKeyPoolRouter()
        let poolReq = LLMChatRequest(
            providerName: "Pool",
            protocolType: .openAICompatible,
            baseURL: "https://\(poolHost)/v1",
            apiKey: "sk-dead",
            apiKeys: ["sk-good"],
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: nil,
            topP: 1,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )

        var firstOut = ""
        for try await ev in OpenAICompatibleAdapter.streamChat(poolReq, keyRouter: liveRouter, session: session) {
            if case .contentDelta(let d) = ev { firstOut += d }
        }
        XCTAssertEqual(firstOut, "From Bearer sk-good")
        XCTAssertEqual(ResilienceMockURLProtocol.recordedAuthHeaders(for: poolHost), ["Bearer sk-dead", "Bearer sk-good"])

        // Next turn skips cooled-down sk-dead immediately on the very first HTTP call!
        var secondOut = ""
        for try await ev in OpenAICompatibleAdapter.streamChat(poolReq, keyRouter: liveRouter, session: session) {
            if case .contentDelta(let d) = ev { secondOut += d }
        }
        XCTAssertEqual(secondOut, "From Bearer sk-good")
        XCTAssertEqual(ResilienceMockURLProtocol.count(for: poolHost), 3, "Cooled-down key is skipped on subsequent turn")

        // Encrypted backup round-trips extraAPIKeys + custom idleTimeoutSeconds without leaking plaintext
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let srcContainer = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let srcCtx = srcContainer.mainContext
        let p = ProviderConfig(name: "MultiKeyProvider", protocolType: .openAICompatible, baseURL: "https://api.example.com/v1", models: [ModelSpec(id: "m1")])
        srcCtx.insert(p)
        p.idleTimeoutSeconds = 120
        try srcCtx.save()

        let pid = p.id
        defer {
            KeychainService.shared.deleteAPIKey(for: pid)
            ProviderConnectionSettingsStore.shared.remove(for: pid)
        }
        XCTAssertTrue(KeychainService.shared.saveAPIKey("sk-primary-1111", for: pid))
        XCTAssertTrue(KeychainService.shared.saveExtraAPIKeys(["sk-backup-2222", "sk-backup-3333"], for: pid))
        XCTAssertEqual(p.allAPIKeys, ["sk-primary-1111", "sk-backup-2222", "sk-backup-3333"])

        let encrypted = try EncryptedBackupService.exportEncryptedData(context: srcCtx, password: "Strong-Password-123!")
        let wire = String(decoding: encrypted, as: UTF8.self)
        XCTAssertFalse(wire.contains("sk-backup-2222"))

        KeychainService.shared.deleteAPIKey(for: pid)
        ProviderConnectionSettingsStore.shared.remove(for: pid)
        XCTAssertTrue(KeychainService.shared.loadAllAPIKeys(for: pid).isEmpty)
        XCTAssertEqual(ProviderConnectionSettingsStore.shared.idleTimeoutSeconds(for: pid), 0)

        let dstContainer = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        _ = try EncryptedBackupService.decryptAndApply(data: encrypted, password: "Strong-Password-123!", to: dstContainer.mainContext)
        XCTAssertEqual(KeychainService.shared.loadAllAPIKeys(for: pid), ["sk-primary-1111", "sk-backup-2222", "sk-backup-3333"])
        XCTAssertEqual(ProviderConnectionSettingsStore.shared.idleTimeoutSeconds(for: pid), 120)
    }
}

extension ConnectionResilienceTests {
    private func listedModels(_ kind: APIProtocolType, response: @escaping @Sendable (URLRequest, Int) -> String) async throws -> [ModelSpec] {
        let host = "catalog-\(UUID().uuidString).example"
        ResilienceMockURLProtocol.register(host: host) { request, page, proto, client in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Channel"), "test")
            let field: String = switch kind {
            case .openAICompatible: "Authorization"
            case .anthropic: "x-api-key"
            case .gemini: "x-goog-api-key"
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: field), kind == .openAICompatible ? "Bearer fixture" : "fixture")
            let data = Data(response(request, page).utf8)
            client.urlProtocol(proto, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                                  headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(proto, didLoad: data)
            client.urlProtocolDidFinishLoading(proto)
        }
        return try await LLMClient.fetchModels(providerName: "fixture", protocolType: kind, baseURL: "https://\(host)/v1?channel=a%2Fb",
                                               apiKey: "fixture", customHeaders: [CustomHeader(key: "X-Channel", value: "test")], session: makeSession())
    }

    func testModelListShowsNewModelsFirstAndPreservesProviderOrderAndMetadata() async throws {
        let models = try await listedModels(.openAICompatible) { _, _ in
            """
            {"data":[{"id":"legacy","created":1},{"id":"z-new","created":5,"name":"New model","input_modalities":["image","text"],"effort":{"supported_levels":["high"]}},
            {"id":"a-peer","created":5},{"id":"z-new","created":5},{"id":"private-z"},{"id":"private-a"},
            {"id":"image-only","created":99,"architecture":{"output_modalities":["image"]}}]}
            """
        }
        XCTAssertEqual(models.map(\.id), ["z-new", "a-peer", "legacy", "private-z", "private-a"])
        XCTAssertEqual(models.first?.displayName, "New model")
        XCTAssertEqual(models.first?.supportsVision, true)
        XCTAssertEqual(models.first?.supportsReasoning, true)
    }

    func testAnthropicListsAllPagesWithGatewayQueryAndOriginalCredentials() async throws {
        let models = try await listedModels(.anthropic) { req, page in
            XCTAssertTrue(req.url!.absoluteString.contains("channel=a%2Fb"))
            XCTAssertNotNil(req.value(forHTTPHeaderField: "anthropic-version"))
            if page == 1 { return #"{"data":[{"id":"new","display_name":"New"}],"last_id":"new","has_more":true}"# }
            XCTAssertEqual(page, 2)
            XCTAssertTrue(req.url!.absoluteString.contains("after_id=new"))
            return #"{"data":[{"id":"new"},{"id":"another"}],"has_more":false}"#
        }
        XCTAssertEqual(models.map(\.id), ["new", "another"])
        XCTAssertEqual(models.first?.displayName, "New")
    }

    func testGeminiFindsTextChatModelsOnLaterPagesAndEncodesOpaqueToken() async throws {
        let models = try await listedModels(.gemini) { req, page in
            if page == 1 {
                return #"{"models":[{"name":"models/embed","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"a+/=&"}"#
            }
            XCTAssertEqual(page, 2)
            XCTAssertTrue(req.url!.absoluteString.contains("channel=a%2Fb"))
            XCTAssertTrue(req.url!.absoluteString.contains("pageToken=a%2B%2F%3D%26"))
            return #"{"models":[{"name":"models/new","displayName":"New","supportedGenerationMethods":["generateContent"]},{"name":"models/voice","supportedOutputModalities":["AUDIO"]}]}"#
        }
        XCTAssertEqual(models.map(\.id), ["new"])
    }

    func testBrokenPaginationFailsInsteadOfReturningAnIncompleteCatalog() async {
        for kind in [APIProtocolType.anthropic, .gemini] {
            do {
                _ = try await listedModels(kind) { _, page in
                    XCTAssertLessThanOrEqual(page, 2)
                    return kind == .gemini ? #"{"models":[{"name":"first"}],"nextPageToken":"same"}"#
                        : #"{"data":[{"id":"first"}],"has_more":true}"#
                }
                XCTFail("Expected malformed pagination to fail")
            } catch { XCTAssertEqual((error as? URLError)?.code, .cannotParseResponse) }
        }
    }

    func testModelDirectoryDistinguishesValidEmptyResponsesFromMalformedRecords() async throws {
        for kind in [APIProtocolType.openAICompatible, .anthropic, .gemini] {
            let field = kind == .gemini ? "models" : "data"
            let empty = try await listedModels(kind) { _, _ in "{\"\(field)\":[]}" }
            XCTAssertTrue(empty.isEmpty)
            for invalid in ["{}", "{\"\(field)\":[{}]}"] {
                do {
                    _ = try await listedModels(kind) { _, _ in invalid }
                    XCTFail("Invalid model directory was accepted by \(kind)")
                } catch { XCTAssertEqual((error as? URLError)?.code, .cannotParseResponse) }
            }
        }
    }
}
