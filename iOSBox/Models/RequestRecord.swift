import Foundation
import SwiftData

enum RequestStatus: String, Codable, CaseIterable {
    case running, succeeded, failed, cancelled, interrupted, incomplete, blocked

    var title: String {
        switch self {
        case .running: return String(localized: "进行中")
        case .succeeded: return String(localized: "已完成")
        case .failed: return String(localized: "失败")
        case .cancelled: return String(localized: "已取消")
        case .interrupted: return String(localized: "已中断")
        case .incomplete: return String(localized: "输出不完整")
        case .blocked: return String(localized: "未发出")
        }
    }
}

enum RequestKind: String, Codable {
    case answer, regeneration, synthesis, sharedReading, modelTask, shortcut, webSearch, continuation, agentTool, titleGeneration, studyGeneration

    var title: String {
        switch self {
        case .answer: return String(localized: "对话")
        case .regeneration: return String(localized: "重答")
        case .synthesis: return String(localized: "裁判汇总")
        case .sharedReading: return String(localized: "分享精读")
        case .modelTask: return String(localized: "模型任务")
        case .shortcut: return String(localized: "快捷指令")
        case .webSearch: return String(localized: "联网搜索")
        case .continuation: return String(localized: "续写")
        case .agentTool: return String(localized: "工具调用")
        case .titleGeneration: return String(localized: "智能标题")
        case .studyGeneration: return String(localized: "学习辅导")
        }
    }
}

/// One entry per attempt. No prompt, answer, credentials or cascading conversation relationship.
/// Deleting a conversation or regenerating its answer must not erase historical spending.
@Model
final class RequestRecord {
    @Attribute(.unique) var id: UUID
    var operationID: UUID
    var attempt: Int
    var conversationID: UUID
    var messageID: UUID
    var providerID: UUID
    var providerName: String
    var modelID: String
    var modelDisplayName: String
    var protocolRaw: String
    var kindRaw: String
    var statusRaw: String
    var startedAt: Date
    var endedAt: Date?
    var firstReasoningMs: Int?
    var firstContentMs: Int?
    var lastOutputMs: Int?
    var durationMs: Int?
    var outputChunkCount: Int
    var isStreamed: Bool
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int?
    var cacheWriteTokens: Int?
    var httpStatus: Int?
    var inputPricePerMillion: Double?
    var outputPricePerMillion: Double?
    var currency: String?

    init(target: ResolvedModelTarget, spec: ModelSpec?, conversationID: UUID, messageID: UUID,
         kind: RequestKind, operationID: UUID = UUID(), attempt: Int = 1, now: Date = Date()) {
        id = UUID()
        self.operationID = operationID
        self.attempt = attempt
        self.conversationID = conversationID
        self.messageID = messageID
        providerID = target.providerID
        providerName = target.providerName
        modelID = target.modelID
        modelDisplayName = target.modelDisplayName
        protocolRaw = target.protocolType.rawValue
        kindRaw = kind.rawValue
        statusRaw = RequestStatus.running.rawValue
        startedAt = now
        outputChunkCount = 0
        isStreamed = true
        inputPricePerMillion = Self.validPrice(spec?.inputPricePerMillion)
        outputPricePerMillion = Self.validPrice(spec?.outputPricePerMillion)
        currency = spec?.priceCurrency
        let readPrice = Self.validPrice(spec?.cacheReadPricePerMillion)
        let writePrice = Self.validPrice(spec?.cacheWritePricePerMillion)
        if readPrice != nil || writePrice != nil {
            CachePriceSnapshotStore.shared.set(read: readPrice, write: writePrice, for: id)
        }
    }

    var status: RequestStatus {
        get { RequestStatus(rawValue: statusRaw) ?? .interrupted }
        set { statusRaw = newValue.rawValue }
    }

    var kind: RequestKind { RequestKind(rawValue: kindRaw) ?? .answer }

    var firstOutputMs: Int? {
        [firstReasoningMs, firstContentMs].compactMap(LLMUsage.valid).min()
    }

    /// Approximate API-reported output tokens/s, including reasoning where reported.
    /// Never infer token counts from characters, or a stream rate from a single JSON response.
    var tokensPerSecond: Double? {
        guard status == .succeeded, isStreamed, outputChunkCount >= 2,
              let tokens = LLMUsage.valid(completionTokens), tokens > 0,
              let first = firstOutputMs, let last = LLMUsage.valid(lastOutputMs), last > first else { return nil }
        return Double(tokens) * 1000 / Double(last - first)
    }

    var cacheReadPricePerMillion: Double? {
        Self.validPrice(CachePriceSnapshotStore.shared.entry(for: id)?.read)
    }

    var cacheWritePricePerMillion: Double? {
        Self.validPrice(CachePriceSnapshotStore.shared.entry(for: id)?.write)
    }

    var hasModelPricing: Bool {
        Self.validPrice(inputPricePerMillion) != nil && Self.validPrice(outputPricePerMillion) != nil
            && Self.currencies.contains(currency ?? "")
    }

    var estimatedCost: Double? {
        guard let input = LLMUsage.valid(promptTokens), let output = LLMUsage.valid(completionTokens),
              let inPrice = Self.validPrice(inputPricePerMillion),
              let outPrice = Self.validPrice(outputPricePerMillion),
              let currency, Self.currencies.contains(currency) else { return nil }
        let readPrice = cacheReadPricePerMillion
        let writePrice = cacheWritePricePerMillion
        let value: Double
        if readPrice != nil || writePrice != nil {
            let cachedRead = min(max(cachedTokens ?? 0, 0), input)
            let cacheWrite = min(max(cacheWriteTokens ?? 0, 0), max(0, input - cachedRead))
            let uncachedInput = max(0, input - cachedRead - cacheWrite)
            let inCost = Double(uncachedInput) * inPrice
                + Double(cachedRead) * (readPrice ?? inPrice)
                + Double(cacheWrite) * (writePrice ?? inPrice)
            value = (inCost + Double(output) * outPrice) / 1_000_000
        } else {
            value = (Double(input) * inPrice + Double(output) * outPrice) / 1_000_000
        }
        return value.isFinite ? value : nil
    }

    /// Positive net amount saved by prompt caching relative to uncached input pricing,
    /// after deducting any cache-write surcharge.
    var estimatedCacheSavings: Double? {
        guard let input = LLMUsage.valid(promptTokens),
              let inPrice = Self.validPrice(inputPricePerMillion),
              let readPrice = cacheReadPricePerMillion,
              let cachedRead = LLMUsage.valid(cachedTokens), cachedRead > 0,
              inPrice > readPrice else { return nil }
        let effectiveCached = min(cachedRead, input)
        let grossSaved = Double(effectiveCached) * (inPrice - readPrice)
        let cacheWrite = max(LLMUsage.valid(cacheWriteTokens) ?? 0, 0)
        let writeSurchargeRate = max(0, (cacheWritePricePerMillion ?? inPrice) - inPrice)
        let writeSurcharge = Double(cacheWrite) * writeSurchargeRate
        let saved = (grossSaved - writeSurcharge) / 1_000_000
        return saved > 0 && saved.isFinite ? saved : nil
    }

    static let currencies = ["USD", "CNY", "EUR", "GBP", "JPY", "HKD"]

    static func validPrice(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1_000_000_000 else { return nil }
        return value
    }

    func observeOutput(reasoning: Bool, elapsedMs: Int) {
        if reasoning {
            if firstReasoningMs == nil { firstReasoningMs = elapsedMs }
        } else if firstContentMs == nil {
            firstContentMs = elapsedMs
        }
        lastOutputMs = elapsedMs
        outputChunkCount += 1
    }

    func finish(_ status: RequestStatus, elapsedMs: Int, now: Date = Date()) {
        self.status = status
        durationMs = elapsedMs
        endedAt = now
    }

    func observe(_ event: LLMStreamEvent, elapsedMs: Int) {
        switch event {
        case .nonStreamingResponse:
            isStreamed = false
        case .reasoningDelta(let text) where !text.isEmpty:
            observeOutput(reasoning: true, elapsedMs: elapsedMs)
        case .contentDelta(let text) where !text.isEmpty:
            observeOutput(reasoning: false, elapsedMs: elapsedMs)
        case .attachmentDelta:
            observeOutput(reasoning: false, elapsedMs: elapsedMs)
        case .usage(let prompt, let completion):
            if let prompt = LLMUsage.valid(prompt) { promptTokens = prompt }
            if let completion = LLMUsage.valid(completion) { completionTokens = completion }
        case .cacheUsage(let read, let write):
            if let read = LLMUsage.valid(read) { cachedTokens = read }
            if let write = LLMUsage.valid(write) { cacheWriteTokens = write }
        default:
            break
        }
    }

    func startRetry(after status: Int, elapsedMs: Int, target: ResolvedModelTarget, spec: ModelSpec?,
                    in context: ModelContext) -> RequestRecord {
        httpStatus = status
        finish(.failed, elapsedMs: elapsedMs)
        let next = RequestRecord(target: target, spec: spec, conversationID: conversationID,
                                 messageID: messageID, kind: kind, operationID: operationID, attempt: attempt + 1)
        next.inputPricePerMillion = inputPricePerMillion
        next.outputPricePerMillion = outputPricePerMillion
        next.currency = currency
        let existingRead = cacheReadPricePerMillion
        let existingWrite = cacheWritePricePerMillion
        if existingRead != nil || existingWrite != nil {
            CachePriceSnapshotStore.shared.set(read: existingRead, write: existingWrite, for: next.id)
        }
        context.insert(next)
        return next
    }

    /// Archive representation stays independent of SwiftData and includes price snapshots.
    struct Snapshot: Codable {
        var id: UUID
        var operationID: UUID
        var attempt: Int
        var conversationID: UUID
        var messageID: UUID
        var providerID: UUID
        var providerName: String
        var modelID: String
        var modelDisplayName: String
        var protocolRaw: String
        var kindRaw: String
        var statusRaw: String
        var startedAt: Date
        var endedAt: Date?
        var firstReasoningMs: Int?
        var firstContentMs: Int?
        var lastOutputMs: Int?
        var durationMs: Int?
        var outputChunkCount: Int
        var isStreamed: Bool
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        var cacheWriteTokens: Int?
        var httpStatus: Int?
        var inputPricePerMillion: Double?
        var outputPricePerMillion: Double?
        var cacheReadPricePerMillion: Double? = nil
        var cacheWritePricePerMillion: Double? = nil
        var currency: String?
    }

    var snapshot: Snapshot {
        Snapshot(id: id, operationID: operationID, attempt: attempt, conversationID: conversationID,
                 messageID: messageID, providerID: providerID, providerName: providerName,
                 modelID: modelID, modelDisplayName: modelDisplayName, protocolRaw: protocolRaw,
                 kindRaw: kindRaw, statusRaw: statusRaw, startedAt: startedAt, endedAt: endedAt,
                 firstReasoningMs: firstReasoningMs, firstContentMs: firstContentMs,
                 lastOutputMs: lastOutputMs, durationMs: durationMs, outputChunkCount: outputChunkCount,
                 isStreamed: isStreamed, promptTokens: promptTokens, completionTokens: completionTokens,
                 cachedTokens: cachedTokens, cacheWriteTokens: cacheWriteTokens,
                 httpStatus: httpStatus, inputPricePerMillion: inputPricePerMillion,
                 outputPricePerMillion: outputPricePerMillion,
                 cacheReadPricePerMillion: cacheReadPricePerMillion,
                 cacheWritePricePerMillion: cacheWritePricePerMillion,
                 currency: currency)
    }

    convenience init(snapshot s: Snapshot, persistCachePrices: Bool = true) {
        let target = ResolvedModelTarget(providerID: s.providerID, providerName: s.providerName,
                                        protocolType: APIProtocolType(rawValue: s.protocolRaw) ?? .openAICompatible,
                                        modelID: s.modelID, modelDisplayName: s.modelDisplayName,
                                        accentHex: "#3F6EF6", supportsVision: false, supportsReasoning: false)
        self.init(target: target, spec: nil, conversationID: s.conversationID, messageID: s.messageID,
                  kind: RequestKind(rawValue: s.kindRaw) ?? .answer, operationID: s.operationID,
                  attempt: s.attempt, now: s.startedAt)
        id = s.id
        protocolRaw = s.protocolRaw
        kindRaw = s.kindRaw
        statusRaw = s.statusRaw == RequestStatus.running.rawValue ? RequestStatus.interrupted.rawValue : s.statusRaw
        endedAt = s.endedAt
        firstReasoningMs = LLMUsage.valid(s.firstReasoningMs)
        firstContentMs = LLMUsage.valid(s.firstContentMs)
        lastOutputMs = LLMUsage.valid(s.lastOutputMs)
        if let first = firstOutputMs, let last = lastOutputMs, last < first { lastOutputMs = nil }
        durationMs = LLMUsage.valid(s.durationMs)
        outputChunkCount = LLMUsage.valid(s.outputChunkCount) ?? 0
        isStreamed = s.isStreamed
        promptTokens = LLMUsage.valid(s.promptTokens)
        completionTokens = LLMUsage.valid(s.completionTokens)
        cachedTokens = LLMUsage.valid(s.cachedTokens)
        cacheWriteTokens = LLMUsage.valid(s.cacheWriteTokens)
        httpStatus = s.httpStatus
        inputPricePerMillion = Self.validPrice(s.inputPricePerMillion)
        outputPricePerMillion = Self.validPrice(s.outputPricePerMillion)
        currency = s.currency
        if persistCachePrices {
            let validRead = Self.validPrice(s.cacheReadPricePerMillion)
            let validWrite = Self.validPrice(s.cacheWritePricePerMillion)
            if validRead != nil || validWrite != nil {
                CachePriceSnapshotStore.shared.set(read: validRead, write: validWrite, for: s.id)
            }
        }
    }
}

/// Persists optional cache read/write price snapshots per RequestRecord ID without altering
/// frozen SwiftData SQLite table schemas, while round-tripping through `RequestRecord.Snapshot`.
final class CachePriceSnapshotStore: @unchecked Sendable {
    struct Pair: Codable, Equatable {
        var read: Double?
        var write: Double?
    }

    static let shared = CachePriceSnapshotStore()

    private let lock = NSLock()
    private var cache: [String: Pair]
    private var writeScheduled = false
    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "com.iosbox.cache-price-snapshots", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let url = base?.appendingPathComponent("cache-price-snapshots.json")
        self.fileURL = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Pair].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    func entry(for id: UUID) -> Pair? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id.uuidString]
    }

    func set(read: Double?, write: Double?, for id: UUID) {
        guard read != nil || write != nil else { return }
        lock.lock()
        cache[id.uuidString] = Pair(read: read, write: write)
        schedulePersistLocked()
        lock.unlock()
    }

    func setBatch(_ entries: [UUID: Pair]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        var mutated = false
        for (id, pair) in entries where pair.read != nil || pair.write != nil {
            cache[id.uuidString] = pair
            mutated = true
        }
        if mutated { schedulePersistLocked() }
        lock.unlock()
    }

    private func schedulePersistLocked() {
        guard fileURL != nil, !writeScheduled else { return }
        writeScheduled = true
        writeQueue.async { [weak self] in
            guard let self, let fileURL = self.fileURL else { return }
            self.lock.lock()
            let snapshot = self.cache
            self.writeScheduled = false
            self.lock.unlock()
            if let data = try? JSONEncoder().encode(snapshot) {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
}
