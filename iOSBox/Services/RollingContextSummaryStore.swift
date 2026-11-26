import CryptoKit
import Foundation
import Observation

struct RollingContextSummary: Codable, Equatable, Sendable {
    var conversationID: UUID
    var summaryText: String
    var coveredMessageCount: Int
    var lastCoveredMessageID: UUID
    var updatedAt: Date
    var contextDividerMessageID: UUID?
    var coveredMessageIDs: [UUID]?
    var coveredPrefixDigest: String?

    var summarizedUpToMessageID: UUID {
        get { lastCoveredMessageID }
        set { lastCoveredMessageID = newValue }
    }

    init(
        conversationID: UUID,
        summaryText: String,
        coveredMessageCount: Int,
        lastCoveredMessageID: UUID,
        updatedAt: Date = Date(),
        contextDividerMessageID: UUID? = nil,
        coveredMessageIDs: [UUID]? = nil,
        coveredPrefixDigest: String? = nil
    ) {
        self.conversationID = conversationID
        self.summaryText = summaryText
        self.coveredMessageCount = coveredMessageCount
        self.lastCoveredMessageID = lastCoveredMessageID
        self.updatedAt = updatedAt
        self.contextDividerMessageID = contextDividerMessageID
        self.coveredMessageIDs = coveredMessageIDs
        self.coveredPrefixDigest = coveredPrefixDigest
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case summaryText
        case coveredMessageCount
        case lastCoveredMessageID
        case summarizedUpToMessageID
        case updatedAt
        case contextDividerMessageID
        case coveredMessageIDs
        case coveredPrefixDigest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        summaryText = try c.decode(String.self, forKey: .summaryText)
        coveredMessageCount = try c.decode(Int.self, forKey: .coveredMessageCount)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .lastCoveredMessageID) {
            lastCoveredMessageID = id
        } else {
            lastCoveredMessageID = try c.decode(UUID.self, forKey: .summarizedUpToMessageID)
        }
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        contextDividerMessageID = try c.decodeIfPresent(UUID.self, forKey: .contextDividerMessageID)
        coveredMessageIDs = try c.decodeIfPresent([UUID].self, forKey: .coveredMessageIDs)
        coveredPrefixDigest = try c.decodeIfPresent(String.self, forKey: .coveredPrefixDigest)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(summaryText, forKey: .summaryText)
        try c.encode(coveredMessageCount, forKey: .coveredMessageCount)
        try c.encode(lastCoveredMessageID, forKey: .lastCoveredMessageID)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(contextDividerMessageID, forKey: .contextDividerMessageID)
        try c.encodeIfPresent(coveredMessageIDs, forKey: .coveredMessageIDs)
        try c.encodeIfPresent(coveredPrefixDigest, forKey: .coveredPrefixDigest)
    }
}

enum ContextWindowCatalog {
    /// Approximate context window size (in tokens) for major LLM families.
    static func contextLimit(for modelID: String?) -> Int {
        guard let raw = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return 128_000
        }
        if raw.contains("gemini-1.5") || raw.contains("gemini-2") || raw.contains("gemini-3") || raw.contains("gemini-4") || raw.contains("gemini-pro") {
            return 1_000_000
        }
        if raw.contains("gpt-4.1") || raw.contains("gpt-5") || raw.contains("gpt-6") {
            return 1_000_000
        }
        if raw.contains("claude-3") || raw.contains("claude-4") || raw.contains("claude-5") || raw.contains("claude-sonnet") || raw.contains("claude-opus") || raw.contains("claude-haiku") || raw.contains("claude-fable") || raw.contains("claude-mythos") {
            return 200_000
        }
        if raw.contains("o1") || raw.contains("o3") || raw.contains("o4") {
            return 200_000
        }
        if raw.contains("grok") {
            return 131_072
        }
        if raw.contains("gpt-4o") || raw.contains("gpt-4-turbo") || raw.contains("deepseek") || raw.contains("qwen") || raw.contains("llama-3") || raw.contains("llama-4") || raw.contains("glm-4") || raw.contains("moonshot") || raw.contains("kimi") {
            return 128_000
        }
        if raw.contains("gpt-3.5") {
            return 16_384
        }
        return 128_000
    }

    static func fillRatio(inputTokens: Int, modelID: String?) -> Double {
        let cap = Double(max(1, contextLimit(for: modelID)))
        return min(max(Double(max(0, inputTokens)) / cap, 0.0), 1.0)
    }

    static func formattedWindow(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let m = Double(tokens) / 1_000_000.0
            return m == floor(m) ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        let k = Int((Double(tokens) / 1000.0).rounded())
        return "\(max(1, k))K"
    }
}

/// Sidecar JSON store persisting rolling summaries for long conversations without altering frozen SwiftData schemas.
@MainActor
@Observable
final class RollingContextSummaryStore {
    static let shared = RollingContextSummaryStore()

    private(set) var summaries: [UUID: RollingContextSummary] = [:]
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = RollingContextSummaryStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("Fugue", isDirectory: true)
            .appendingPathComponent("rolling-summaries.json")
    }

    func summary(for conversationID: UUID) -> RollingContextSummary? {
        summaries[conversationID]
    }

    func save(_ summary: RollingContextSummary) {
        let clean = summary.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            remove(for: summary.conversationID)
            return
        }
        var bounded = summary
        bounded.summaryText = String(clean.prefix(2400))
        summaries[summary.conversationID] = bounded
        persist()
    }

    func remove(for conversationID: UUID) {
        guard summaries.removeValue(forKey: conversationID) != nil else { return }
        persist()
    }

    func clear(for conversationID: UUID) {
        remove(for: conversationID)
    }

    static func droppedMessages(from collapsed: [ChatMessage], limit: Int) -> [ChatMessage] {
        guard limit > 0, collapsed.count > limit else { return [] }
        return Array(collapsed.dropLast(limit))
    }

    static func prefixDigest(for messages: [ChatMessage]) -> String {
        var hasher = SHA256()
        for msg in messages {
            hasher.update(data: Data(msg.id.uuidString.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(msg.roleRaw.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(msg.content.utf8))
            hasher.update(data: Data([0xFF]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isSummaryValid(
        _ summary: RollingContextSummary,
        dropped: [ChatMessage],
        latestContextDividerID: UUID?
    ) -> Bool {
        if let summaryDividerID = summary.contextDividerMessageID, summaryDividerID != latestContextDividerID {
            return false
        }
        guard !dropped.isEmpty,
              let anchorIdx = dropped.firstIndex(where: { $0.id == summary.lastCoveredMessageID }),
              summary.coveredMessageCount == anchorIdx + 1 else {
            return false
        }
        let coveredSlice = Array(dropped[...anchorIdx])
        if let coveredIDs = summary.coveredMessageIDs, coveredSlice.map(\.id) != coveredIDs {
            return false
        }
        if let expectedDigest = summary.coveredPrefixDigest, prefixDigest(for: coveredSlice) != expectedDigest {
            return false
        }
        return true
    }

    static func promptBlock(for summary: RollingContextSummary) -> String {
        """
        [Earlier Conversation Rolling Summary (\(summary.coveredMessageCount) earlier messages)]
        \(summary.summaryText)
        [End of Earlier Summary — rely on the recent messages below when details conflict.]
        """
    }

    static func buildSummarizationPrompt(
        previousSummary: String?,
        newlyTruncatedMessages: [(role: MessageRole, content: String)]
    ) -> String {
        var parts: [String] = []
        if let prev = previousSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
            parts.append("Previous summary:\n\(prev)")
        }
        let transcript = newlyTruncatedMessages.map { item -> String in
            let speaker = item.role == .user ? "User" : "Assistant"
            let clipped = String(item.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900))
            return "\(speaker): \(clipped)"
        }.joined(separator: "\n")
        parts.append("Older messages to fold into the summary:\n\(transcript)")
        return parts.joined(separator: "\n\n")
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RollingContextSummary].self, from: data) else {
            return
        }
        summaries = Dictionary(uniqueKeysWithValues: decoded.map { ($0.conversationID, $0) })
    }

    private func persist() {
        guard let fileURL else { return }
        let values = Array(summaries.values).sorted { $0.updatedAt > $1.updatedAt }
        guard let data = try? JSONEncoder().encode(values) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
