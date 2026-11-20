import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import iOSBox

private final class BoundaryMockURLProtocol: URLProtocol {
    struct MockReply {
        let statusCode: Int
        let contentType: String
        let body: String
        let keepOpen: Bool
    }

    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest, Int) -> MockReply] = [:]
    private static var callCounts: [String: Int] = [:]
    private static var capturedBodies: [String: [[String: Any]]] = [:]
    private static var stopHooks: [String: () -> Void] = [:]

    static func register(
        host: String,
        onStop: (() -> Void)? = nil,
        handler: @escaping (URLRequest, Int) -> MockReply
    ) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host.lowercased()] = handler
        callCounts[host.lowercased()] = 0
        capturedBodies[host.lowercased()] = []
        if let onStop {
            stopHooks[host.lowercased()] = onStop
        } else {
            stopHooks.removeValue(forKey: host.lowercased())
        }
    }

    static func count(for host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts[host.lowercased(), default: 0]
    }

    static func bodies(for host: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies[host.lowercased(), default: []]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host?.lowercased() ?? ""
        let bodyData = Self.extractBody(from: request)
        let jsonBody = (bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]

        Self.lock.lock()
        let nextCount = Self.callCounts[host, default: 0] + 1
        Self.callCounts[host] = nextCount
        Self.capturedBodies[host, default: []].append(jsonBody)
        let handler = Self.handlers[host]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        let reply = handler(request, nextCount)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": reply.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        if !reply.keepOpen {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        let host = request.url?.host?.lowercased() ?? ""
        Self.lock.lock()
        let hook = Self.stopHooks.removeValue(forKey: host)
        Self.lock.unlock()
        hook?()
    }

    private static func extractBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@MainActor
final class ConnectionBoundaryFixesTests: XCTestCase {

    private func makeEphemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoundaryMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - 1. Mandatory Reasoning Ping Fix

    func testPingRequestAllocatesHeadroomForMandatoryReasoningModelsAndCapsRunawayStreams() async throws {
        // Even if supportsReasoning was left false, inferReasoningSupport detects o3 / gemini-2.5-pro / deepseek-reasoner.
        let o3Ping = LLMClient.buildPingRequest(
            providerName: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            customHeaders: [],
            modelID: "o3",
            supportsReasoning: false
        )
        XCTAssertTrue(o3Ping.supportsReasoning)
        XCTAssertEqual(o3Ping.maxOutputTokens, 1024)
        XCTAssertFalse(o3Ping.enableThinking)
        let o3Wire = OpenAICompatibleAdapter.buildRequestBody(o3Ping)
        XCTAssertEqual(o3Wire["max_completion_tokens"] as? Int, 1024)
        XCTAssertEqual(o3Wire["reasoning_effort"] as? String, "low")

        let standardPing = LLMClient.buildPingRequest(
            providerName: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            customHeaders: [],
            modelID: "gpt-4.1",
            supportsReasoning: false
        )
        XCTAssertFalse(standardPing.supportsReasoning)
        XCTAssertEqual(standardPing.maxOutputTokens, 64)

        let session = makeEphemeralSession()
        defer { session.invalidateAndCancel() }

        // Anthropic redacted_thinking followed by text succeeds cleanly
        let anthropicHost = "ping-claude-\(UUID().uuidString.lowercased()).invalid"
        BoundaryMockURLProtocol.register(host: anthropicHost) { _, _ in
            let sse = """
            data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"enc"}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"OK"}}

            data: {"type":"message_stop"}


            """
            return .init(statusCode: 200, contentType: "text/event-stream", body: sse, keepOpen: false)
        }
        let claudePing = try await LLMClient.pingModel(
            providerName: "Claude",
            protocolType: .anthropic,
            baseURL: "https://\(anthropicHost)/v1",
            apiKey: "sk-ant",
            customHeaders: [],
            modelID: "claude-sonnet-4-6",
            supportsReasoning: true,
            session: session
        )
        XCTAssertEqual(claudePing.modelID, "claude-sonnet-4-6")
        XCTAssertGreaterThanOrEqual(claudePing.totalMs, claudePing.ttftMs)

        // Runaway verbose stream stops early after >= 32 visible characters and cancels open HTTP connection
        let runawayHost = "ping-runaway-\(UUID().uuidString.lowercased()).invalid"
        let stopped = expectation(description: "Runaway ping connection closed early")
        BoundaryMockURLProtocol.register(host: runawayHost, onStop: { stopped.fulfill() }) { _, _ in
            let longChunk = String(repeating: "A", count: 48)
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"\(longChunk)\"}}]}\n\n"
            return .init(statusCode: 200, contentType: "text/event-stream", body: sse, keepOpen: true)
        }
        let runawayResult = try await LLMClient.pingModel(
            providerName: "Runaway",
            protocolType: .openAICompatible,
            baseURL: "https://\(runawayHost)/v1",
            apiKey: "sk-test",
            customHeaders: [],
            modelID: "deepseek-reasoner",
            supportsReasoning: true,
            session: session
        )
        XCTAssertEqual(runawayResult.modelID, "deepseek-reasoner")
        await fulfillment(of: [stopped], timeout: 2.0)
    }

    // MARK: - 2. API Key Debounce & Redundant Notification Suppression

    func testAPIKeySaveCoordinatorCoalescesKeystrokesAndFlushesImmediately() async throws {
        var writes: [String] = []
        var shouldFail = false
        let coordinator = APIKeySaveCoordinator(
            initialValue: "sk-initial",
            delay: .milliseconds(60),
            saveHandler: { value in
                writes.append(value)
                return !shouldFail
            }
        )

        // Matching initial value (e.g. .onAppear setting apiKeyInput) performs zero writes
        coordinator.scheduleSave("  sk-initial  ")
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertTrue(writes.isEmpty)

        // Rapid character-by-character typing coalesces into a single Keychain write
        let typed = "sk-live-9876543210"
        for length in 1...typed.count {
            coordinator.scheduleSave(String(typed.prefix(length)))
        }
        XCTAssertTrue(writes.isEmpty, "Must not write synchronously per keystroke")
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertEqual(writes, ["sk-live-9876543210"])

        // Immediate flush on focus loss / onDisappear / verification saves right away without double-writing later
        coordinator.scheduleSave("sk-flushed-early")
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        XCTAssertEqual(coordinator.flushNow(), true)
        XCTAssertEqual(writes, ["sk-live-9876543210", "sk-flushed-early"])
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(writes.count, 2)

        // Failed write keeps pendingValue so retry succeeds
        shouldFail = true
        coordinator.scheduleSave("sk-retry-me")
        XCTAssertEqual(coordinator.flushNow(), false)
        XCTAssertTrue(coordinator.hasUnsavedChanges)
        shouldFail = false
        XCTAssertEqual(coordinator.flushNow(), true)
        XCTAssertFalse(coordinator.hasUnsavedChanges)
        XCTAssertEqual(writes.last, "sk-retry-me")

        // KeychainService itself skips redundant IOSBoxCredentialsChanged notifications for unchanged confirmed keys
        let testProviderID = UUID()
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .init("IOSBoxCredentialsChanged"),
            object: nil,
            queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            KeychainService.shared.deleteAPIKey(for: testProviderID)
        }

        XCTAssertTrue(KeychainService.shared.saveAPIKey("sk-dedup-1", for: testProviderID))
        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(KeychainService.shared.saveAPIKey("  sk-dedup-1 \n", for: testProviderID))
        XCTAssertEqual(notificationCount, 1, "Identical trimmed key must not republish credentials")
    }

    // MARK: - 3. Gateway Capability Negation Cache Across All Protocols

    func testGatewayCapabilityCacheSkipsRepeated400FallbacksAndHashesStorageKeys() async throws {
        let suiteName = "iosbox.tests.capcache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cache = GatewayCapabilityCache(defaults: defaults, ttlSeconds: 3600)
        let session = makeEphemeralSession()
        defer { session.invalidateAndCancel() }

        // 3a. OpenAI stream_options 400 fallback is remembered on turn 2
        let openAIHost = "cap-openai-\(UUID().uuidString.lowercased()).invalid"
        BoundaryMockURLProtocol.register(host: openAIHost) { _, _ in
            return .init(statusCode: 200, contentType: "text/event-stream", body: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n", keepOpen: false)
        }
        BoundaryMockURLProtocol.register(host: openAIHost) { req, _ in
            let bodyData = req.httpBody ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
            let rawStreamBody: Data = {
                if !bodyData.isEmpty { return bodyData }
                guard let s = req.httpBodyStream else { return Data() }
                s.open(); defer { s.close() }
                var d = Data(), buf = [UInt8](repeating: 0, count: 1024)
                while s.hasBytesAvailable {
                    let n = s.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    d.append(buf, count: n)
                }
                return d
            }()
            let parsed = json.isEmpty ? ((try? JSONSerialization.jsonObject(with: rawStreamBody) as? [String: Any]) ?? [:]) : json
            if parsed["stream_options"] != nil {
                return .init(statusCode: 400, contentType: "application/json", body: #"{"error":{"message":"unknown field: stream_options"}}"#, keepOpen: false)
            }
            return .init(statusCode: 200, contentType: "text/event-stream", body: "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n", keepOpen: false)
        }

        let secretBaseURL = "https://\(openAIHost)/secret-team-token/v1?gw_key=super-secret-query"
        let openAIReq = LLMChatRequest(
            providerName: "Relay",
            protocolType: .openAICompatible,
            baseURL: secretBaseURL,
            apiKey: "sk-1",
            customHeaders: [],
            modelID: "deepseek-chat",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024
        )

        var firstTurnRetries = 0
        for try await event in OpenAICompatibleAdapter.streamChat(openAIReq, capabilityCache: cache, session: session) {
            if case .retrying = event { firstTurnRetries += 1 }
        }
        XCTAssertEqual(firstTurnRetries, 1)
        XCTAssertEqual(BoundaryMockURLProtocol.count(for: openAIHost), 2, "Turn 1 probes stream_options then retries")

        var secondTurnRetries = 0
        for try await event in OpenAICompatibleAdapter.streamChat(openAIReq, capabilityCache: cache, session: session) {
            if case .retrying = event { secondTurnRetries += 1 }
        }
        XCTAssertEqual(secondTurnRetries, 0)
        XCTAssertEqual(BoundaryMockURLProtocol.count(for: openAIHost), 3, "Turn 2 skips stream_options immediately without a wasted 400 request")

        // Persisted UserDefaults payload must never contain raw host, path token, or query secret
        let rawStored = try XCTUnwrap(defaults.data(forKey: GatewayCapabilityCache.storageKey))
        let storedText = String(decoding: rawStored, as: UTF8.self)
        XCTAssertFalse(storedText.contains(openAIHost))
        XCTAssertFalse(storedText.contains("secret-team-token"))
        XCTAssertFalse(storedText.contains("super-secret-query"))

        // 3b. Anthropic cache_control 400 fallback is remembered on turn 2
        let anthropicHost = "cap-claude-\(UUID().uuidString.lowercased()).invalid"
        BoundaryMockURLProtocol.register(host: anthropicHost) { _, _ in
            return .init(statusCode: 200, contentType: "text/event-stream", body: "", keepOpen: false)
        }
        let claudeReq = LLMChatRequest(
            providerName: "ClaudeRelay",
            protocolType: .anthropic,
            baseURL: "https://\(anthropicHost)/v1",
            apiKey: "sk-ant",
            customHeaders: [],
            modelID: "claude-sonnet-4-6",
            supportsReasoning: false,
            systemPrompt: "sys",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: 1024,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enablePromptCaching: true
        )
        BoundaryMockURLProtocol.register(host: anthropicHost) { _, callIdx in
            let bodies = BoundaryMockURLProtocol.bodies(for: anthropicHost)
            let lastBody = bodies.last ?? [:]
            if lastBody["system"] is [[String: Any]] {
                return .init(statusCode: 400, contentType: "application/json", body: #"{"error":{"message":"cache_control is not supported"}}"#, keepOpen: false)
            }
            let sse = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok-\(callIdx)\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            return .init(statusCode: 200, contentType: "text/event-stream", body: sse, keepOpen: false)
        }
        for try await _ in AnthropicAdapter.streamChat(claudeReq, capabilityCache: cache, session: session) {}
        XCTAssertEqual(BoundaryMockURLProtocol.count(for: anthropicHost), 2)
        for try await _ in AnthropicAdapter.streamChat(claudeReq, capabilityCache: cache, session: session) {}
        XCTAssertEqual(BoundaryMockURLProtocol.count(for: anthropicHost), 3, "Turn 2 omits cache_control on the first request")

        // 3c. Unrelated 400 where retry also fails must NOT poison nativeSearch capability
        let unrelatedHost = "cap-unrelated-\(UUID().uuidString.lowercased()).invalid"
        BoundaryMockURLProtocol.register(host: unrelatedHost) { _, _ in
            .init(statusCode: 400, contentType: "application/json", body: #"{"error":{"message":"unknown model: bad-id"}}"#, keepOpen: false)
        }
        let badModelReq = LLMChatRequest(
            providerName: "Relay",
            protocolType: .openAICompatible,
            baseURL: "https://\(unrelatedHost)/v1",
            apiKey: "sk-1",
            customHeaders: [],
            modelID: "bad-id",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [LLMPromptMessage(role: .user, content: "hi")],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            enableNativeSearch: true
        )
        do {
            for try await _ in OpenAICompatibleAdapter.streamChat(badModelReq, capabilityCache: cache, session: session) {}
            XCTFail("Expected HTTP 400")
        } catch {}
        XCTAssertFalse(
            cache.isUnsupported(.nativeSearch, protocolType: .openAICompatible, baseURL: badModelReq.baseURL, modelID: badModelReq.modelID),
            "Failed retry must not poison capability cache"
        )

        // 3d. TTL expiry re-enables probing
        XCTAssertTrue(cache.isUnsupported(.streamOptions, protocolType: .openAICompatible, baseURL: secretBaseURL, modelID: "deepseek-chat"))
        XCTAssertFalse(
            cache.isUnsupported(
                .streamOptions,
                protocolType: .openAICompatible,
                baseURL: secretBaseURL,
                modelID: "deepseek-chat",
                now: Date().addingTimeInterval(3601)
            )
        )
    }

    // MARK: - 4. EndpointResolver Query Parameter Preservation

    func testEndpointResolverPreservesQueryParametersAcrossAllProtocols() throws {
        // Azure OpenAI style base URL (without /chat/completions, with ?api-version=...)
        let azureBase = "https://contoso.openai.azure.com/openai/deployments/gpt-4o?api-version=2024-10-21"
        XCTAssertEqual(
            try EndpointResolver.chatEndpoint(baseURL: azureBase, protocolType: .openAICompatible).absoluteString,
            "https://contoso.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21"
        )

        // Full Azure chat/completions URL with query parameter must not append a duplicate /chat/completions
        let azureFull = "https://contoso.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21"
        XCTAssertEqual(
            try EndpointResolver.chatEndpoint(baseURL: azureFull, protocolType: .openAICompatible).absoluteString,
            azureFull
        )
        XCTAssertEqual(
            try EndpointResolver.modelsEndpoint(baseURL: azureFull, protocolType: .openAICompatible).absoluteString,
            "https://contoso.openai.azure.com/openai/deployments/gpt-4o/models?api-version=2024-10-21"
        )

        // Custom raw gateway with trailing # and percent-encoded query parameter
        let rawGateway = "https://proxy.example.com/custom?sig=ab%2Bcd#"
        XCTAssertEqual(
            try EndpointResolver.chatEndpoint(baseURL: rawGateway, protocolType: .openAICompatible).absoluteString,
            "https://proxy.example.com/custom/chat/completions?sig=ab%2Bcd"
        )

        // Anthropic gateway with query parameter
        let claudeGateway = "https://claude-proxy.example.com?workspace=dev"
        XCTAssertEqual(
            try EndpointResolver.chatEndpoint(baseURL: claudeGateway, protocolType: .anthropic).absoluteString,
            "https://claude-proxy.example.com/v1/messages?workspace=dev"
        )

        // Gemini gateway with custom query merges alt=sse and pageSize=200 without losing user query
        let geminiGateway = "https://gemini-proxy.example.com?channel=alpha"
        XCTAssertEqual(
            try EndpointResolver.chatEndpoint(baseURL: geminiGateway, protocolType: .gemini, modelID: "gemini-2.5-pro").absoluteString,
            "https://gemini-proxy.example.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?channel=alpha&alt=sse"
        )
        XCTAssertEqual(
            try EndpointResolver.modelsEndpoint(baseURL: geminiGateway, protocolType: .gemini).absoluteString,
            "https://gemini-proxy.example.com/v1beta/models?channel=alpha&pageSize=200"
        )
    }

    // MARK: - 5. ShortcutService Rejects Unready Seeded / Plain-HTTP Public Providers

    func testShortcutServiceRejectsUnauthenticatedAndPlainHTTPPublicProviders() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let suite = "iosbox.tests.shortcut.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        AppCompliance.setAcceptedAIDisclosure(true, defaults: defaults)

        let unauthenticatedSeeded = ProviderConfig(
            name: "Seeded DeepSeek",
            protocolType: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            isEnabled: true,
            models: [ModelSpec(id: "deepseek-chat")]
        )
        let plainHTTPPublic = ProviderConfig(
            name: "Plain HTTP Public",
            protocolType: .openAICompatible,
            baseURL: "http://relay.example.com/v1",
            isEnabled: true,
            models: [ModelSpec(id: "gpt-4.1")]
        )
        context.insert(unauthenticatedSeeded)
        context.insert(plainHTTPPublic)
        try context.save()

        defer {
            defaults.removePersistentDomain(forName: suite)
            KeychainService.shared.deleteAPIKey(for: unauthenticatedSeeded.id)
            KeychainService.shared.deleteAPIKey(for: plainHTTPPublic.id)
        }
        _ = KeychainService.shared.saveAPIKey("sk-plain-http", for: plainHTTPPublic.id)

        let seededTarget = unauthenticatedSeeded.makeTarget(for: unauthenticatedSeeded.models[0])
        let insecureTarget = plainHTTPPublic.makeTarget(for: plainHTTPPublic.models[0])

        let engine = ChatEngine { _ in
            AsyncThrowingStream { c in
                c.yield(.contentDelta("Authorized reply"))
                c.yield(.done)
                c.finish()
            }
        }

        // Neither unauthenticated seeded provider nor plain-HTTP public provider may pass ShortcutService
        XCTAssertThrowsError(try ShortcutService.recipient(for: seededTarget.id, context: context))
        XCTAssertThrowsError(try ShortcutService.recipient(for: insecureTarget.id, context: context))
        XCTAssertThrowsError(try ShortcutService.start(text: "Hi", modelID: seededTarget.id, context: context, engine: engine, consentDefaults: defaults))
        XCTAssertThrowsError(try ShortcutService.start(text: "Hi", modelID: insecureTarget.id, context: context, engine: engine, consentDefaults: defaults))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 0)

        // Once API key is saved for the HTTPS provider, both recipient() and start() succeed
        XCTAssertTrue(KeychainService.shared.saveAPIKey("sk-valid", for: unauthenticatedSeeded.id))
        XCTAssertEqual(
            try ShortcutService.recipient(for: seededTarget.id, context: context),
            "Seeded DeepSeek · deepseek-chat (api.deepseek.com)"
        )
        let conv = try ShortcutService.start(text: "Hi", modelID: seededTarget.id, context: context, engine: engine, consentDefaults: defaults)
        XCTAssertEqual(conv.primaryTarget?.id, seededTarget.id)
        await engine.stopGenerationAndWait(for: conv.id)
    }
}
