import Foundation
import SwiftData

struct ArenaDecision: Codable, Equatable, Identifiable, Sendable {
    struct Answer: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let provider: String
        let modelID: String
        let model: String
        let content: String
        let attachments: [MessageAttachment]
        let issue: String?
        let elapsedMs: Int?
        let tokensPerSecond: Double?
        let estimatedCost: Double?
        let currency: String?
    }

    let id: UUID
    let groupID: UUID
    let selectedID: UUID
    let question: String
    let answers: [Answer]
    var tags: [String]
    var reason: String
    var updatedTimestamp: Double
    var editID: UUID
    var isDeleted: Bool? = nil

    @MainActor
    static func capture(selected: ChatMessage, peers: [ChatMessage]) -> Self? {
        guard let group = selected.comparisonGroupID, let chat = selected.conversation,
              selected.isSelectedInGroup, ArenaSynthesis.isComplete(selected) else { return nil }
        let candidates = peers.filter { $0.comparisonGroupID == group && (!$0.isSynthesis || $0.id == selected.id) }
            .sorted { ($0.sortIndex, $0.id.uuidString) < ($1.sortIndex, $1.id.uuidString) }
        guard !candidates.contains(where: \.isStreaming), candidates.contains(where: { $0.id == selected.id }) else { return nil }
        let history = ConversationTree.activeMessages(in: chat, endingAt: selected.id)
        let prompt = history.prefix { $0.comparisonGroupID != group }.last { $0.role == .user }
        let question = [prompt?.content ?? "", prompt?.attachments.map(\.fileName).joined(separator: ", ") ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let answers: [Answer] = candidates.map { message in
            // A historical revision lacks its own request reference. Latest metrics can belong to another answer.
            let request = message.assistanceMetadata.activeRevisionIndex == nil ? message.latestRequest : nil
            return Answer(id: message.id, provider: message.providerName, modelID: message.modelID,
                model: ArenaSynthesis.visibleSpeakerName(for: message), content: message.content,
                attachments: message.attachments, issue: message.errorMessage == nil ? message.finishReason : String(localized: "请求失败，详细错误仅保留在原设备。"),
                elapsedMs: request?.durationMs ?? message.latencyMs, tokensPerSecond: request?.tokensPerSecond,
                estimatedCost: request?.estimatedCost, currency: request?.currency)
        }
        if let saved = selected.assistanceMetadata.arenaDecisions?.first(where: {
            $0.isDeleted != true && $0.groupID == group && $0.selectedID == selected.id && $0.answers == answers && $0.question == question
        }) { return saved }
        return Self(id: UUID(), groupID: group, selectedID: selected.id, question: question, answers: answers,
                    tags: [], reason: "", updatedTimestamp: 0, editID: UUID())
    }

    static func tags(from input: String) -> [String] {
        var seen = Set<String>()
        return input.components(separatedBy: CharacterSet(charactersIn: ",，、\n")).compactMap { value in
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !tag.isEmpty && seen.insert(tag.lowercased()).inserted ? tag : nil
        }
    }

    static func merged(_ local: [Self], _ incoming: [Self]) -> [Self] {
        var latest: [UUID: Self] = [:]
        for entry in local + incoming {
            if let previous = latest[entry.id],
               (previous.updatedTimestamp, previous.editID.uuidString) >= (entry.updatedTimestamp, entry.editID.uuidString) { continue }
            latest[entry.id] = entry
        }
        return latest.values.sorted { ($0.updatedTimestamp, $0.id.uuidString) > ($1.updatedTimestamp, $1.id.uuidString) }
    }

    @MainActor
    func save(tags: [String], reason: String, to message: ChatMessage, in context: ModelContext) throws {
        var next = self
        next.tags = tags
        next.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist(next, to: message, in: context)
    }

    @MainActor
    func delete(from message: ChatMessage, in context: ModelContext) throws {
        // A deletion travels through backups without retaining the answers, tags, or reason.
        let tombstone = Self(id: id, groupID: groupID, selectedID: selectedID, question: "", answers: [],
                             tags: [], reason: "", updatedTimestamp: updatedTimestamp, editID: editID, isDeleted: true)
        try persist(tombstone, to: message, in: context)
    }

    @MainActor
    private func persist(_ change: Self, to message: ChatMessage, in context: ModelContext) throws {
        guard !message.isDeleted, message.modelContext === context,
              message.id == selectedID, message.comparisonGroupID == groupID else { throw CocoaError(.fileNoSuchFile) }
        var metadata = message.assistanceMetadata
        let entries = metadata.arenaDecisions ?? []
        if let current = entries.first(where: { $0.id == id }), current.editID != editID {
            throw CocoaError(.fileWriteFileExists)
        }
        var next = change
        next.updatedTimestamp = max(Date().timeIntervalSince1970, updatedTimestamp.nextUp)
        next.editID = UUID()
        let updated = Self.merged(entries, [next])
        if next.isDeleted != true {
            var remaining = AttachmentProcessor.maximumPayloadBytes
            for entry in updated {
                for text in [entry.question, entry.reason] + entry.tags { remaining -= text.utf8.count }
                for answer in entry.answers {
                    remaining -= answer.content.utf8.count
                    for file in answer.attachments {
                        remaining -= (file.dataBase64?.utf8.count ?? 0) + (file.extractedText?.utf8.count ?? 0)
                    }
                }
                guard remaining >= 0 else { throw ArenaDecisionError.tooLarge }
            }
        }
        metadata.arenaDecisions = updated
        let encoded = try JSONEncoder().encode(metadata)
        let previous = message.assistanceMetadataData
        message.assistanceMetadataData = encoded
        do { try context.save() } catch { message.assistanceMetadataData = previous; throw error }
    }
}


private enum ArenaDecisionError: LocalizedError {
    case tooLarge
    var errorDescription: String? { String(localized: "这条回复的采纳记录超过 64 MB，无法保存。") }
}
