import CryptoKit
import Foundation

enum LLMError: LocalizedError {
    case invalidURL(String)
    case missingAPIKey(String)
    case httpError(Int, String)
    case apiError(String)
    case interruptedStream
    case emptyResponse
    case unavailableModel
    case unavailableTool

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return String(localized: "无效的接口地址：\(raw)")
        case .missingAPIKey(let provider):
            return String(localized: "请先在「设置」页面为「\(provider)」配置 API Key（本地服务若免鉴权可忽略）")
        case .httpError(let code, let detail):
            return "HTTP \(code)：\(detail)"
        case .apiError(let msg):
            return msg
        case .interruptedStream:
            return String(localized: "连接提前结束，回复可能不完整，请重试。")
        case .emptyResponse:
            return String(localized: "服务端未返回有效内容")
        case .unavailableModel:
            return String(localized: "此服务商或模型已停用、删除或更改，请重新选择模型。")
        case .unavailableTool:
            return String(localized: "模型请求了本轮未启用的工具，已停止处理。")
        }
    }
}

enum LLMUsage {
    // A billion tokens or milliseconds is far beyond any individual supported request.
    static let maximum = 1_000_000_000

    static func valid(_ value: Int?) -> Int? {
        guard let value, (0...maximum).contains(value) else { return nil }
        return value
    }

    static func combined(_ values: Int?...) -> Int? {
        let validValues = values.compactMap(valid)
        guard !validValues.isEmpty else { return nil }
        return valid(validValues.reduce(0, saturatedSum))
    }

    static func saturatedSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}

struct LLMToolDefinition: Sendable, Codable, Equatable {
    let name: String
    let description: String
    let parametersSchemaJSON: String

    var parametersObject: [String: Any] {
        guard let data = parametersSchemaJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["type": "object", "properties": [:]]
        }
        return obj
    }
}

struct LLMThinkingBlock: Sendable, Codable, Equatable {
    enum Kind: String, Sendable, Codable, Equatable {
        case thinking
        case redactedThinking = "redacted_thinking"
    }

    let kind: Kind
    let thinking: String
    let signature: String?
    let redactedData: String?

    init(thinking: String, signature: String?) {
        self.kind = .thinking
        self.thinking = thinking
        self.signature = signature
        self.redactedData = nil
    }

    init(redactedData: String) {
        self.kind = .redactedThinking
        self.thinking = ""
        self.signature = nil
        self.redactedData = redactedData
    }
}

struct LLMToolCall: Sendable, Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let argumentsJSON: String
    let thoughtSignature: String?

    init(id: String, name: String, argumentsJSON: String, thoughtSignature: String? = nil) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.thoughtSignature = thoughtSignature
    }

    var argumentsDictionary: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

struct LLMPromptMessage: Sendable {
    let role: MessageRole
    let content: String
    let reasoningContent: String
    let thinkingBlocks: [LLMThinkingBlock]
    let attachments: [MessageAttachment]
    let toolCalls: [LLMToolCall]
    let toolCallID: String?
    let toolName: String?

    init(
        role: MessageRole,
        content: String,
        reasoningContent: String = "",
        thinkingBlocks: [LLMThinkingBlock] = [],
        attachments: [MessageAttachment] = [],
        toolCalls: [LLMToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.thinkingBlocks = thinkingBlocks
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

struct LLMChatRequest: Sendable {
    let providerName: String
    let protocolType: APIProtocolType
    let baseURL: String
    let apiKey: String
    let apiKeys: [String]
    let customHeaders: [CustomHeader]
    let modelID: String
    /// Per-model capability flag (user-editable in provider settings). Drives whether
    /// thinking / reasoning parameters are sent at all.
    let supportsReasoning: Bool
    let systemPrompt: String
    let messages: [LLMPromptMessage]
    let temperature: Double?
    let topP: Double
    let maxOutputTokens: Int?
    let enableThinking: Bool
    let thinkingBudgetTokens: Int
    let enablePromptCaching: Bool
    let enableNativeSearch: Bool
    let idleTimeoutSeconds: TimeInterval?
    let tools: [LLMToolDefinition]
    var validateBeforeSending: (@MainActor @Sendable () throws -> Void)?

    /// Deduplicated non-empty API keys in priority order (`apiKey` followed by `apiKeys`).
    var effectiveAPIKeys: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in [apiKey] + apiKeys {
            let trimmed = LLMClient.sanitizedAPIKey(raw)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    init(
        providerName: String,
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        apiKeys: [String] = [],
        customHeaders: [CustomHeader],
        modelID: String,
        supportsReasoning: Bool,
        systemPrompt: String,
        messages: [LLMPromptMessage],
        temperature: Double?,
        topP: Double,
        maxOutputTokens: Int?,
        enableThinking: Bool,
        thinkingBudgetTokens: Int,
        enablePromptCaching: Bool = false,
        enableNativeSearch: Bool = false,
        idleTimeoutSeconds: TimeInterval? = nil,
        tools: [LLMToolDefinition] = []
    ) {
        self.providerName = providerName
        self.protocolType = protocolType
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiKeys = apiKeys
        self.customHeaders = customHeaders
        self.modelID = modelID
        self.supportsReasoning = supportsReasoning
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.enableThinking = enableThinking
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.enablePromptCaching = enablePromptCaching
        self.enableNativeSearch = enableNativeSearch
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.tools = tools
    }
}

struct LLMPingResult: Sendable {
    let modelID: String
    let ttftMs: Int
    let totalMs: Int
}

/// Abnormal reasons a generation stopped. A normal, complete answer emits nothing.
enum LLMFinishReason: String, Codable, Sendable {
    /// Hit the max output token limit; the answer is likely incomplete.
    case length
    /// Blocked or truncated by the provider's safety / content policy.
    case contentFilter = "content_filter"

    static func fromProviderValue(_ raw: String?) -> LLMFinishReason? {
        guard let value = raw?.lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "length", "max_tokens", "model_context_window_exceeded":
            return .length
        case "content_filter", "refusal", "safety", "recitation", "prohibited_content",
             "blocklist", "spii", "image_safety":
            return .contentFilter
        default:
            return nil
        }
    }

    var userNotice: String {
        switch self {
        case .length:
            return String(localized: "回复已达到最大输出长度，内容可能不完整。可在会话参数中调大「最大输出 Tokens」后重答。")
        case .contentFilter:
            return String(localized: "回复被模型服务商的安全策略拦截或截断。")
        }
    }
}

enum LLMStreamEvent: Sendable {
    case retrying(httpStatus: Int)
    case nonStreamingResponse
    case reasoningDelta(String)
    case thinkingBlock(LLMThinkingBlock)
    case contentDelta(String)
    case attachmentDelta(MessageAttachment)
    case toolCall(LLMToolCall)
    case groundingSource(title: String, url: String)
    case usage(promptTokens: Int?, completionTokens: Int?)
    case cacheUsage(cachedTokens: Int?, cacheWriteTokens: Int?)
    case finished(LLMFinishReason)
    case done
}

enum GatewayUnsupportedFeature: String, Codable, CaseIterable, Sendable {
    case streamOptions = "stream_options"
    case promptCaching = "prompt_caching"
    case nativeSearch = "native_search"
    case thinkingConfig = "thinking_config"
    case reasoningContent = "reasoning_content"
    case reasoningParams = "reasoning_params"
    case reasoningSummary = "reasoning_summary"
    case maxCompletionTokens = "max_completion_tokens"
    case requiresMaxCompletionTokens = "requires_max_completion_tokens"
    case samplingParams = "sampling_params"
    case storeFlag = "store_flag"
}

/// Remembers optional wire parameters that a gateway/model rejected with HTTP 400–422
/// (and subsequently accepted without them), avoiding repeated 400 probes on every turn.
/// Keys are SHA-256 digests so raw gateway URLs or path credentials are never written to disk.
final class GatewayCapabilityCache: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        var features: Set<GatewayUnsupportedFeature>
        var updatedAt: Date
    }

    static let shared = GatewayCapabilityCache()
    static let storageKey = "com.iosbox.gatewayCapabilityNegations.v1"

    private let lock = NSLock()
    private var entries: [String: Entry]
    private let defaults: UserDefaults?
    private let ttlSeconds: TimeInterval
    private let maxEntries: Int

    init(
        defaults: UserDefaults? = .standard,
        ttlSeconds: TimeInterval = 7 * 24 * 3600,
        maxEntries: Int = 256
    ) {
        self.defaults = defaults
        self.ttlSeconds = ttlSeconds
        self.maxEntries = maxEntries
        if let data = defaults?.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = [:]
        }
    }

    static func cacheKey(protocolType: APIProtocolType, baseURL: String, modelID: String) -> String {
        let cleanURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let raw = "\(protocolType.rawValue)|\(cleanURL)|\(cleanModel)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func isUnsupported(
        _ feature: GatewayUnsupportedFeature,
        protocolType: APIProtocolType,
        baseURL: String,
        modelID: String,
        now: Date = Date()
    ) -> Bool {
        let key = Self.cacheKey(protocolType: protocolType, baseURL: baseURL, modelID: modelID)
        lock.lock()
        guard let entry = entries[key] else {
            lock.unlock()
            return false
        }
        if now.timeIntervalSince(entry.updatedAt) > ttlSeconds {
            entries.removeValue(forKey: key)
            let snapshot = entries
            lock.unlock()
            persist(snapshot)
            return false
        }
        let result = entry.features.contains(feature)
        lock.unlock()
        return result
    }

    func markUnsupported(
        _ features: Set<GatewayUnsupportedFeature>,
        protocolType: APIProtocolType,
        baseURL: String,
        modelID: String,
        now: Date = Date()
    ) {
        guard !features.isEmpty else { return }
        let key = Self.cacheKey(protocolType: protocolType, baseURL: baseURL, modelID: modelID)
        lock.lock()
        var merged = entries[key]?.features ?? []
        merged.formUnion(features)
        entries[key] = Entry(features: merged, updatedAt: now)
        if entries.count > maxEntries {
            let sortedKeys = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.map(\.key)
            for k in sortedKeys.prefix(entries.count - maxEntries) {
                entries.removeValue(forKey: k)
            }
        }
        let snapshot = entries
        lock.unlock()
        persist(snapshot)
    }

    func clearAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
        defaults?.removeObject(forKey: Self.storageKey)
    }

    private func persist(_ snapshot: [String: Entry]) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Single-task idle timer guarding both initial HTTP header wait and SSE inter-chunk gaps.
/// SSE heartbeats (e.g. `: keep-alive`) call `touch()` without spawning per-byte tasks.
final class StreamIdleWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity: ContinuousClock.Instant
    private var expired = false
    private var stopped = false
    private var task: Task<Void, Never>?
    let timeout: Duration

    init(timeoutSeconds: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        let clamped = min(max(timeoutSeconds, 0.05), 3600)
        let ms = max(50, Int((clamped * 1000).rounded()))
        self.timeout = .milliseconds(ms)
        self.lastActivity = ContinuousClock.now
        self.task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let wait = self.remainingDuration() else { return }
                if wait <= .zero {
                    if self.markExpiredIfActive() {
                        onTimeout()
                    }
                    return
                }
                do {
                    try await Task.sleep(for: wait, clock: .continuous)
                } catch {
                    return
                }
            }
        }
    }

    func touch() {
        lock.lock()
        if !stopped {
            lastActivity = ContinuousClock.now
        }
        lock.unlock()
    }

    var didExpire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }

    func stop() {
        lock.lock()
        stopped = true
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }

    private func remainingDuration() -> Duration? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        let deadline = lastActivity.advanced(by: timeout)
        return ContinuousClock.now.duration(to: deadline)
    }

    private func markExpiredIfActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        let deadline = lastActivity.advanced(by: timeout)
        guard ContinuousClock.now >= deadline else { return false }
        expired = true
        stopped = true
        return true
    }
}

/// Distributes traffic across a provider's API key pool via Round-Robin and temporarily
/// cools down keys that hit rate-limit (429) or auth/quota errors (401/402/403).
final class APIKeyPoolRouter: @unchecked Sendable {
    static let shared = APIKeyPoolRouter()

    private let lock = NSLock()
    private var cursors: [String: Int] = [:]
    private var cooldowns: [String: ContinuousClock.Instant] = [:]

    init() {}

    func orderedKeys(
        from rawKeys: [String],
        protocolType: APIProtocolType,
        baseURL: String,
        now: ContinuousClock.Instant = .now
    ) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for raw in rawKeys {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                unique.append(trimmed)
            }
        }
        guard !unique.isEmpty else { return [""] }
        guard unique.count > 1 else { return unique }

        let poolID = Self.poolHash(protocolType: protocolType, baseURL: baseURL)
        lock.lock()
        let start = cursors[poolID, default: 0] % unique.count
        cursors[poolID] = (start + 1) % unique.count

        var rotated: [String] = []
        rotated.reserveCapacity(unique.count)
        for offset in 0..<unique.count {
            rotated.append(unique[(start + offset) % unique.count])
        }

        var healthy: [String] = []
        var cooling: [(key: String, until: ContinuousClock.Instant)] = []
        for key in rotated {
            let kHash = Self.keyHash(poolID: poolID, key: key)
            if let until = cooldowns[kHash] {
                if now < until {
                    cooling.append((key, until))
                } else {
                    cooldowns.removeValue(forKey: kHash)
                    healthy.append(key)
                }
            } else {
                healthy.append(key)
            }
        }
        lock.unlock()

        cooling.sort { $0.until < $1.until }
        return healthy + cooling.map(\.key)
    }

    func markUnhealthy(
        key: String,
        protocolType: APIProtocolType,
        baseURL: String,
        statusCode: Int,
        retryAfter: TimeInterval? = nil,
        now: ContinuousClock.Instant = .now
    ) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let poolID = Self.poolHash(protocolType: protocolType, baseURL: baseURL)
        let kHash = Self.keyHash(poolID: poolID, key: trimmed)
        let cooldownSec: TimeInterval
        if statusCode == 429 {
            cooldownSec = min(max(retryAfter ?? 30, 5), 600)
        } else {
            cooldownSec = 300
        }
        let ms = Int((cooldownSec * 1000).rounded())
        lock.lock()
        cooldowns[kHash] = now.advanced(by: .milliseconds(ms))
        lock.unlock()
    }

    func markHealthy(key: String, protocolType: APIProtocolType, baseURL: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let poolID = Self.poolHash(protocolType: protocolType, baseURL: baseURL)
        let kHash = Self.keyHash(poolID: poolID, key: trimmed)
        lock.lock()
        cooldowns.removeValue(forKey: kHash)
        lock.unlock()
    }

    func resetAll() {
        lock.lock()
        cursors.removeAll()
        cooldowns.removeAll()
        lock.unlock()
    }

    private static func poolHash(protocolType: APIProtocolType, baseURL: String) -> String {
        let clean = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data("\(protocolType.rawValue)|\(clean)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func keyHash(poolID: String, key: String) -> String {
        let digest = SHA256.hash(data: Data("\(poolID)|\(key)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

struct LLMHTTPStatusError: Error, Sendable {
    let statusCode: Int
    let message: String
    let retryAfterSeconds: TimeInterval?
}

private final class AttemptCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var urlTask: URLSessionTask?
    private var cancelled = false

    func bind(task: Task<Void, Error>) {
        lock.lock()
        let shouldCancel = cancelled
        self.task = task
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func bind(urlTask: URLSessionTask) {
        lock.lock()
        let shouldCancel = cancelled
        self.urlTask = urlTask
        lock.unlock()
        if shouldCancel { urlTask.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        let ut = urlTask
        lock.unlock()
        ut?.cancel()
        t?.cancel()
    }
}

private final class AcceptedHTTPFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markAccepted() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isAccepted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum LLMClient {
    static let standardIdleTimeoutSeconds: TimeInterval = 45
    static let extendedIdleTimeoutSeconds: TimeInterval = 120
    static let maxRetryAfterWaitSeconds: TimeInterval = 5.0

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    static func resolvedIdleTimeout(for request: LLMChatRequest) -> TimeInterval {
        if let custom = request.idleTimeoutSeconds, custom > 0 {
            return min(max(custom, 0.05), 3600)
        }
        let needsExtended = request.supportsReasoning
            || ModelSpec.inferReasoningSupport(modelID: request.modelID)
            || NetworkLocation.isLocalOrPrivate(baseURL: request.baseURL)
        return needsExtended ? extendedIdleTimeoutSeconds : standardIdleTimeoutSeconds
    }

    static func streamChat(_ request: LLMChatRequest, consentDefaults: UserDefaults = AppCompliance.consentDefaults) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        do { try AppCompliance.requireConsent(defaults: consentDefaults) }
        catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
        return startStream(request, session: session)
    }

    private static func startStream(_ request: LLMChatRequest, session: URLSession) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        switch request.protocolType {
        case .openAICompatible:
            return OpenAICompatibleAdapter.streamChat(request, session: session)
        case .openAIResponses:
            return OpenAIResponsesAdapter.streamChat(request, session: session)
        case .anthropic:
            return AnthropicAdapter.streamChat(request, session: session)
        case .gemini:
            return GeminiAdapter.streamChat(request, session: session)
        }
    }

    static func buildPingRequest(
        providerName: String,
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        apiKeys: [String] = [],
        customHeaders: [CustomHeader],
        modelID: String,
        supportsReasoning: Bool = false,
        idleTimeoutSeconds: TimeInterval? = nil
    ) -> LLMChatRequest {
        let effectiveReasoning = supportsReasoning || ModelSpec.inferReasoningSupport(modelID: modelID)
        return LLMChatRequest(
            providerName: providerName,
            protocolType: protocolType,
            baseURL: baseURL,
            apiKey: apiKey,
            apiKeys: apiKeys,
            customHeaders: customHeaders,
            modelID: modelID,
            supportsReasoning: effectiveReasoning,
            systemPrompt: "",
            messages: [
                LLMPromptMessage(role: .user, content: "Reply with: OK", attachments: [])
            ],
            temperature: nil,
            topP: 1.0,
            maxOutputTokens: effectiveReasoning ? 1024 : 64,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            idleTimeoutSeconds: idleTimeoutSeconds
        )
    }

    /// Sends a minimal 1-turn probe request to verify credentials/endpoint and measure TTFT.
    static func pingModel(
        providerName: String,
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        apiKeys: [String] = [],
        customHeaders: [CustomHeader],
        modelID: String,
        supportsReasoning: Bool = false,
        idleTimeoutSeconds: TimeInterval? = nil,
        session customSession: URLSession? = nil
    ) async throws -> LLMPingResult {
        let req = buildPingRequest(
            providerName: providerName,
            protocolType: protocolType,
            baseURL: baseURL,
            apiKey: apiKey,
            apiKeys: apiKeys,
            customHeaders: customHeaders,
            modelID: modelID,
            supportsReasoning: supportsReasoning,
            idleTimeoutSeconds: idleTimeoutSeconds
        )

        let start = ContinuousClock.now
        var firstMs: Int?
        var sawOutput = false
        var visibleCharacters = 0

        // The user explicitly requested this fixed probe; it has no conversation data.
        streamLoop: for try await event in startStream(req, session: customSession ?? session) {
            switch event {
            case .reasoningDelta(let r) where !r.isEmpty:
                if firstMs == nil { firstMs = elapsedMs(since: start) }
                sawOutput = true
            case .thinkingBlock:
                if firstMs == nil { firstMs = elapsedMs(since: start) }
                sawOutput = true
            case .contentDelta(let c) where !c.isEmpty:
                if firstMs == nil { firstMs = elapsedMs(since: start) }
                sawOutput = true
                visibleCharacters += c.count
                if visibleCharacters >= 32 {
                    break streamLoop
                }
            default:
                break
            }
        }

        let total = elapsedMs(since: start)
        guard sawOutput else { throw LLMError.emptyResponse }
        return LLMPingResult(modelID: modelID, ttftMs: firstMs ?? total, totalMs: total)
    }

    static func fetchModels(
        providerName: String,
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        apiKeys: [String] = [],
        customHeaders: [CustomHeader],
        keyRouter: APIKeyPoolRouter = .shared,
        session customSession: URLSession? = nil
    ) async throws -> [ModelSpec] {
        let endpoint = try EndpointResolver.modelsEndpoint(baseURL: baseURL, protocolType: protocolType)
        guard ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: baseURL) else {
            throw LLMError.invalidURL(baseURL)
        }
        let orderedKeys = keyRouter.orderedKeys(
            from: ([apiKey] + apiKeys).map(sanitizedAPIKey),
            protocolType: protocolType,
            baseURL: baseURL
        )
        let activeSession = customSession ?? session
        var lastError: Error?

        for (index, candidateKey) in orderedKeys.prefix(4).enumerated() {
            do {
                let specs: [ModelSpec]
                switch protocolType {
                case .openAICompatible, .openAIResponses:
                    specs = try await OpenAICompatibleAdapter.fetchModels(
                        baseURL: baseURL,
                        apiKey: candidateKey,
                        customHeaders: customHeaders,
                        session: activeSession
                    )
                case .anthropic:
                    specs = try await AnthropicAdapter.fetchModels(
                        baseURL: baseURL,
                        apiKey: candidateKey,
                        customHeaders: customHeaders,
                        session: activeSession
                    )
                case .gemini:
                    specs = try await GeminiAdapter.fetchModels(
                        baseURL: baseURL,
                        apiKey: candidateKey,
                        customHeaders: customHeaders,
                        session: activeSession
                    )
                }
                keyRouter.markHealthy(key: candidateKey, protocolType: protocolType, baseURL: baseURL)
                return specs
            } catch LLMError.httpError(let code, let msg) where [401, 402, 403, 429].contains(code) && index + 1 < min(orderedKeys.count, 4) {
                keyRouter.markUnhealthy(key: candidateKey, protocolType: protocolType, baseURL: baseURL, statusCode: code)
                lastError = LLMError.httpError(code, msg)
                continue
            } catch {
                throw error
            }
        }
        throw lastError ?? LLMError.emptyResponse
    }

    // MARK: - Unified Resilient Streaming Transport

    static func streamWithResilience<State: Sendable>(
        request: LLMChatRequest,
        initialState: State,
        capabilityCache: GatewayCapabilityCache,
        keyRouter: APIKeyPoolRouter = .shared,
        session: URLSession,
        buildURLRequest: @escaping @Sendable (String, State) throws -> URLRequest,
        degradeOn400: @escaping @Sendable (Int, String, inout State, inout Set<GatewayUnsupportedFeature>) -> Bool,
        consumeStream: @escaping @Sendable (
            URLSession.AsyncBytes,
            URLResponse,
            @escaping @Sendable () -> Void,
            AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
        ) async throws -> Void
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let outerTask = Task {
                do {
                    guard !NetworkLocation.isPlainHTTPToPublicHost(baseURL: request.baseURL) else {
                        throw LLMError.invalidURL(request.baseURL)
                    }
                    var state = initialState
                    var newlyDisabled = Set<GatewayUnsupportedFeature>()
                    let orderedKeys = keyRouter.orderedKeys(
                        from: request.effectiveAPIKeys,
                        protocolType: request.protocolType,
                        baseURL: request.baseURL
                    )
                    var keyIndex = 0
                    var keyRotationsUsed = 0
                    var transientRetriesUsed = 0
                    let idleTimeout = resolvedIdleTimeout(for: request)

                    while true {
                        try Task.checkCancellation()
                        let activeKey = orderedKeys[keyIndex]
                        let currentState = state
                        var urlRequest = try buildURLRequest(activeKey, currentState)
                        urlRequest.timeoutInterval = idleTimeout

                        try await request.validateBeforeSending?()

                        let cancelBox = AttemptCancellationBox()
                        let acceptedFlag = AcceptedHTTPFlag()
                        let watchdog = StreamIdleWatchdog(timeoutSeconds: idleTimeout) {
                            cancelBox.cancel()
                        }

                        do {
                            let attemptTask = Task<Void, Error> {
                                let (bytes, response) = try await session.bytes(
                                    for: urlRequest,
                                    delegate: SameOriginRedirectDelegate.shared
                                )
                                cancelBox.bind(urlTask: bytes.task)
                                defer { bytes.task.cancel() }
                                watchdog.touch()
                                try await validateHTTPResponseWithMetadata(response, bytes: bytes)
                                acceptedFlag.markAccepted()
                                watchdog.touch()
                                try await consumeStream(bytes, response, { watchdog.touch() }, continuation)
                            }
                            cancelBox.bind(task: attemptTask)
                            defer { watchdog.stop() }

                            try await withTaskCancellationHandler {
                                try await attemptTask.value
                            } onCancel: {
                                cancelBox.cancel()
                            }

                            keyRouter.markHealthy(
                                key: activeKey,
                                protocolType: request.protocolType,
                                baseURL: request.baseURL
                            )
                            if !newlyDisabled.isEmpty {
                                capabilityCache.markUnsupported(
                                    newlyDisabled,
                                    protocolType: request.protocolType,
                                    baseURL: request.baseURL,
                                    modelID: request.modelID
                                )
                            }
                            break
                        } catch let statusErr as LLMHTTPStatusError {
                            watchdog.stop()
                            guard !acceptedFlag.isAccepted else {
                                throw LLMError.httpError(statusErr.statusCode, statusErr.message)
                            }
                            let code = statusErr.statusCode
                            if (400...422).contains(code),
                               degradeOn400(code, statusErr.message, &state, &newlyDisabled) {
                                continuation.yield(.retrying(httpStatus: code))
                                continue
                            }
                            if [401, 402, 403, 429].contains(code),
                               keyIndex + 1 < orderedKeys.count,
                               keyRotationsUsed < 3 {
                                keyRouter.markUnhealthy(
                                    key: activeKey,
                                    protocolType: request.protocolType,
                                    baseURL: request.baseURL,
                                    statusCode: code,
                                    retryAfter: statusErr.retryAfterSeconds
                                )
                                keyIndex += 1
                                keyRotationsUsed += 1
                                continuation.yield(.retrying(httpStatus: code))
                                continue
                            }
                            if [429, 502, 503, 504, 529].contains(code),
                               transientRetriesUsed == 0,
                               let waitSec = transientRetryDelay(
                                   statusCode: code,
                                   retryAfter: statusErr.retryAfterSeconds,
                                   message: statusErr.message
                               ) {
                                if code == 429 {
                                    keyRouter.markUnhealthy(
                                        key: activeKey,
                                        protocolType: request.protocolType,
                                        baseURL: request.baseURL,
                                        statusCode: code,
                                        retryAfter: statusErr.retryAfterSeconds
                                    )
                                }
                                transientRetriesUsed += 1
                                continuation.yield(.retrying(httpStatus: code))
                                let waitMs = max(1, Int((waitSec * 1000).rounded()))
                                try await Task.sleep(for: .milliseconds(waitMs))
                                continue
                            }
                            throw LLMError.httpError(code, statusErr.message)
                        } catch {
                            let timedOut = watchdog.didExpire && !Task.isCancelled
                            watchdog.stop()
                            if timedOut {
                                throw URLError(.timedOut)
                            }
                            if !acceptedFlag.isAccepted,
                               !Task.isCancelled,
                               transientRetriesUsed == 0,
                               isTransientConnectionDrop(error) {
                                transientRetriesUsed += 1
                                try await Task.sleep(for: .milliseconds(200))
                                continue
                            }
                            throw error
                        }
                    }

                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                outerTask.cancel()
            }
        }
    }

    static func transientRetryDelay(
        statusCode: Int,
        retryAfter: TimeInterval?,
        message: String
    ) -> TimeInterval? {
        if let retryAfter {
            guard retryAfter <= maxRetryAfterWaitSeconds else { return nil }
            return max(0.05, retryAfter)
        }
        switch statusCode {
        case 429:
            let lower = message.lowercased()
            let isHardQuota = lower.contains("insufficient_quota")
                || lower.contains("insufficient balance")
                || lower.contains("余额不足")
                || lower.contains("billing")
            return isHardQuota ? nil : 0.8
        case 502, 503, 504, 529:
            return 0.5
        default:
            return nil
        }
    }

    private static func isTransientConnectionDrop(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorNetworkConnectionLost
    }

    // MARK: - Shared HTTP Utilities

    /// Strips outer whitespace/newlines and an accidentally pasted leading `Bearer ` prefix.
    static func sanitizedAPIKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Returns `true` when an HTTP 400–422 message clearly indicates an error that cannot be fixed
    /// by dropping optional wire parameters (wrong model ID, bad key, quota, context overflow, safety).
    static func isUnrecoverable400(_ lower: String) -> Bool {
        let patterns = [
            "model not exist", "model_not_found", "model not found", "does not exist",
            "no such model", "invalid model", "unknown model", "模型不存在",
            "api key not valid", "invalid_api_key", "incorrect api key", "invalid api key",
            "insufficient_quota", "insufficient balance", "quota exceeded", "余额不足",
            "context_length_exceeded", "maximum context length", "too many tokens",
            "content_policy", "safety"
        ]
        return patterns.contains { lower.contains($0) }
    }

    /// Returns `true` when an HTTP 400–422 response indicates a generic unknown/extra/unsupported
    /// parameter rejection (sometimes without naming the offending field verbatim).
    static func isGenericParameterRejection400(_ lower: String) -> Bool {
        let patterns = [
            "unknown", "unrecognized", "unsupported", "unexpected",
            "extra_forbidden", "extra inputs", "additional properties",
            "not permitted", "not allowed", "invalid parameter", "invalid field",
            "invalid request", "bad request", "invalid_argument", "invalid json",
            "参数错误", "不支持", "请求失败（无详细错误信息）", "请求被服务端拒绝"
        ]
        return patterns.contains { lower.contains($0) }
    }

    static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let dur = start.duration(to: ContinuousClock.now)
        return Int(dur.components.seconds * 1000) + Int(dur.components.attoseconds / 1_000_000_000_000_000)
    }

    static func applyCustomHeaders(_ headers: [CustomHeader], to urlRequest: inout URLRequest) {
        for header in headers where header.isEnabled {
            let k = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty && !(header.isSecret && v.isEmpty) {
                urlRequest.setValue(v, forHTTPHeaderField: k)
            }
        }
    }

    static func validateHTTPResponseWithMetadata(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = parseRetryAfter(from: http)
            let errorData: Data = await withTaskGroup(of: Data?.self) { group in
                group.addTask {
                    var buf = Data()
                    do {
                        for try await byte in bytes {
                            buf.append(byte)
                            if buf.count >= 32_768 { break }
                        }
                    } catch {
                        // Keep any partial error body already received so HTTP status is never masked
                    }
                    return buf
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first ?? Data()
            }
            try Task.checkCancellation()
            let message = enrichErrorMessage(extractReadableErrorMessage(from: errorData), response: http)
            throw LLMHTTPStatusError(statusCode: http.statusCode, message: message, retryAfterSeconds: retryAfter)
        }
    }

    static func validateHTTPResponse(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        do {
            try await validateHTTPResponseWithMetadata(response, bytes: bytes)
        } catch let err as LLMHTTPStatusError {
            throw LLMError.httpError(err.statusCode, err.message)
        }
    }

    static func validateDataResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = enrichErrorMessage(extractReadableErrorMessage(from: data), response: http)
            throw LLMError.httpError(http.statusCode, message)
        }
    }

    static func parseRetryAfter(from http: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        if let rawMs = http.value(forHTTPHeaderField: "retry-after-ms")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let ms = Double(rawMs), ms.isFinite, ms >= 0 {
            return ms / 1000.0
        }
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let secs = Double(raw), secs.isFinite, secs >= 0 {
            return secs
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            return max(0, date.timeIntervalSince(now))
        }
        return nil
    }

    static func extractRequestID(from http: HTTPURLResponse) -> String? {
        let candidates = ["x-request-id", "request-id", "anthropic-request-id", "x-correlation-id"]
        for header in candidates {
            if let raw = http.value(forHTTPHeaderField: header)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                let safe = raw.filter { ($0.asciiValue ?? 0) >= 0x20 && ($0.asciiValue ?? 0) < 0x7F }
                if !safe.isEmpty {
                    return String(safe.prefix(64))
                }
            }
        }
        return nil
    }

    private static func enrichErrorMessage(_ message: String, response: HTTPURLResponse) -> String {
        guard let reqID = extractRequestID(from: response),
              !message.contains(reqID) else {
            return message
        }
        return "\(message) [Request ID: \(reqID)]"
    }

    static func extractReadableErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return String(localized: "请求失败（无详细错误信息）") }
        if let parsed = try? JSONSerialization.jsonObject(with: data) {
            if let dict = parsed as? [String: Any],
               let extracted = extractMessage(fromErrorDict: dict) {
                return extracted
            }
            // Gemini `:streamGenerateContent` frequently wraps HTTP 400 errors in a JSON array: `[{"error": {...}}]`.
            if let arr = parsed as? [[String: Any]],
               let first = arr.first,
               let extracted = extractMessage(fromErrorDict: first) {
                return extracted
            }
        }
        let raw = String(decoding: data.prefix(600), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? String(localized: "请求被服务端拒绝") : raw
    }

    private static func extractMessage(fromErrorDict json: [String: Any]) -> String? {
        if let errDict = json["error"] as? [String: Any] {
            if let msg = errDict["message"] as? String, !msg.isEmpty { return msg }
            if let msg = errDict["msg"] as? String, !msg.isEmpty { return msg }
            if let detail = errDict["detail"] as? String, !detail.isEmpty { return detail }
        }
        if let errStr = json["error"] as? String, !errStr.isEmpty {
            return errStr
        }
        if let msg = json["message"] as? String, !msg.isEmpty {
            return msg
        }
        if let msg = json["msg"] as? String, !msg.isEmpty {
            return msg
        }
        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }
        // FastAPI / Pydantic validation errors: `{"detail": [{"loc": ["body", "stream_options"], "msg": "..."}]}`
        if let detailList = json["detail"] as? [[String: Any]], !detailList.isEmpty {
            let parts = detailList.prefix(3).compactMap { item -> String? in
                let msg = (item["msg"] as? String) ?? (item["message"] as? String) ?? ""
                let loc = (item["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".") ?? ""
                if !loc.isEmpty && !msg.isEmpty { return "\(loc): \(msg)" }
                if !msg.isEmpty { return msg }
                return loc.isEmpty ? nil : loc
            }
            if !parts.isEmpty {
                return parts.joined(separator: "; ")
            }
        }
        return nil
    }

    static func composeTextWithDocuments(text: String, attachments: [MessageAttachment], includePDFText: Bool) -> String {
        var blocks: [String] = []
        for item in attachments where item.kind == .document {
            if item.mimeType == "application/pdf" && !includePDFText && item.dataBase64 != nil {
                continue
            }
            let safeName = xmlEscapedAttribute(item.fileName)
            if let extracted = item.extractedText, !extracted.isEmpty {
                let safeBody = extracted.replacingOccurrences(
                    of: "</attachment>",
                    with: "<\\/attachment>",
                    options: .caseInsensitive
                )
                blocks.append("<attachment name=\"\(safeName)\">\n\(safeBody)\n</attachment>")
            } else {
                blocks.append(String(localized: "[附件: \(item.fileName) (\(item.formattedSize))]"))
            }
        }
        if !text.isEmpty {
            blocks.append(text)
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func xmlEscapedAttribute(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Ensures every assistant `toolCalls` turn has matching contiguous `.tool` responses and drops
    /// orphan `.tool` messages (e.g. after context-window slicing or mid-turn user cancellation),
    /// preventing permanent HTTP 400 errors on subsequent turns across OpenAI, Anthropic, and Gemini.
    static func sanitizeToolHistory(_ messages: [LLMPromptMessage]) -> [LLMPromptMessage] {
        var result: [LLMPromptMessage] = []
        var index = 0
        while index < messages.count {
            let msg = messages[index]
            if msg.role == .tool {
                // Orphan tool output without a preceding assistant tool-call message
                index += 1
                continue
            }
            if msg.role == .assistant && !msg.toolCalls.isEmpty {
                var nextIdx = index + 1
                var toolResponses: [LLMPromptMessage] = []
                while nextIdx < messages.count && messages[nextIdx].role == .tool {
                    toolResponses.append(messages[nextIdx])
                    nextIdx += 1
                }
                if toolResponses.isEmpty {
                    // Interrupted assistant tool call with zero tool outputs: strip dangling toolCalls
                    if !msg.content.isEmpty || !msg.reasoningContent.isEmpty || !msg.attachments.isEmpty {
                        result.append(LLMPromptMessage(
                            role: .assistant,
                            content: msg.content.isEmpty ? "..." : msg.content,
                            reasoningContent: msg.reasoningContent,
                            thinkingBlocks: [],
                            attachments: msg.attachments,
                            toolCalls: []
                        ))
                    }
                    index = nextIdx
                    continue
                }

                // Pair every declared tool call with its corresponding response or a synthetic cancellation stub
                result.append(msg)
                var remainingResponses = toolResponses
                for call in msg.toolCalls {
                    if let matchPos = remainingResponses.firstIndex(where: { $0.toolCallID == call.id }) {
                        result.append(remainingResponses.remove(at: matchPos))
                    } else if let namePos = remainingResponses.firstIndex(where: { ($0.toolCallID ?? "").isEmpty && $0.toolName == call.name }) {
                        let matched = remainingResponses.remove(at: namePos)
                        result.append(LLMPromptMessage(
                            role: .tool,
                            content: matched.content,
                            toolCallID: call.id,
                            toolName: call.name
                        ))
                    } else {
                        result.append(LLMPromptMessage(
                            role: .tool,
                            content: #"{"error":"Tool execution was interrupted"}"#,
                            toolCallID: call.id,
                            toolName: call.name
                        ))
                    }
                }
                index = nextIdx
                continue
            }
            result.append(msg)
            index += 1
        }
        return result
    }
}

/// Prevents cross-origin HTTP redirects (301/302/307/308) or HTTPS→HTTP downgrades from forwarding
/// `x-api-key`, `x-goog-api-key`, `Authorization`, or sensitive custom gateway headers to another host.
final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SameOriginRedirectDelegate()

    static func shouldAllowRedirect(from source: URL?, to next: URL?) -> Bool {
        guard let source, let next,
              let srcScheme = source.scheme?.lowercased(),
              let dstScheme = next.scheme?.lowercased(),
              srcScheme == dstScheme,
              source.host?.lowercased() == next.host?.lowercased(),
              effectivePort(of: source) == effectivePort(of: next) else {
            return false
        }
        return true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if Self.shouldAllowRedirect(from: response.url, to: request.url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

enum ModelListTransport {
    static let maximumEntries = 10_000

    static func json(for request: URLRequest, session: URLSession) async throws -> Any {
        try await readJSON(for: request, session: session, maximumBytes: 4 * 1024 * 1024).value
    }

    private static func readJSON(for request: URLRequest, session: URLSession,
                                 maximumBytes: Int) async throws -> (value: Any, byteCount: Int) {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw URLError(.dataLengthExceedsMaximum) }
        var fresh = request
        fresh.cachePolicy = .reloadIgnoringLocalCacheData
        fresh.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: fresh, delegate: SameOriginRedirectDelegate.shared)
        defer { bytes.task.cancel() }
        try await LLMClient.validateHTTPResponse(response, bytes: bytes)
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try validateStructure(data)
        return (try JSONSerialization.jsonObject(with: data), data.count)
    }

    private static func validateStructure(_ data: Data) throws {
        var depth = 0
        var separators = 0
        var inString = false
        var escaped = false
        for (index, byte) in data.enumerated() {
            if index & 16_383 == 0 { try Task.checkCancellation() }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34: inString = true
            case 91, 123:
                depth += 1
                separators += 1
            case 93, 125:
                depth -= 1
                guard depth >= 0 else { throw URLError(.cannotParseResponse) }
            case 44, 58: separators += 1
            default: break
            }
            guard depth <= 64, separators <= 100_000 else { throw URLError(.dataLengthExceedsMaximum) }
        }
    }

    static func pages(request: URLRequest, session: URLSession, itemsKey: String, cursorName: String,
                      parse: ([String: Any], [[String: Any]]) throws -> (models: [ModelSpec], next: String?)) async throws -> [ModelSpec] {
        guard let url = request.url else { throw URLError(.badURL) }
        var pageRequest = request
        var models: [ModelSpec] = []
        var ids = Set<String>()
        var cursors = Set<String>()
        var remainingBytes = 12 * 1024 * 1024
        var remainingEntries = maximumEntries
        while true {
            let result = try await readJSON(for: pageRequest, session: session,
                                            maximumBytes: min(remainingBytes, 4 * 1024 * 1024))
            remainingBytes -= result.byteCount
            guard let object = result.value as? [String: Any], let rows = object[itemsKey] as? [Any] else {
                throw URLError(.cannotParseResponse)
            }
            guard rows.count <= remainingEntries else { throw URLError(.dataLengthExceedsMaximum) }
            remainingEntries -= rows.count
            guard let modelRows = rows as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            let page = try parse(object, modelRows)
            models.append(contentsOf: page.models.filter { ids.insert($0.id).inserted })
            guard let cursor = page.next, !cursor.isEmpty else { return models }
            guard cursors.count < 100, cursors.insert(cursor).inserted,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else {
                throw URLError(.cannotParseResponse)
            }
            // Keep the gateway's original encoded query and treat the cursor strictly as data.
            var items = (components.percentEncodedQueryItems ?? []).filter { $0.name.removingPercentEncoding != cursorName }
            items.append(URLQueryItem(name: cursorName, value: value))
            components.percentEncodedQueryItems = items
            guard let nextURL = components.url else { throw URLError(.badURL) }
            pageRequest.url = nextURL
        }
    }
}
