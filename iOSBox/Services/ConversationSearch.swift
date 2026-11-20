import Foundation
import SwiftData

struct SearchExcerpt: Sendable {
    let before: String
    let match: String
    let after: String

    init?(in text: String, query: String) {
        guard !query.isEmpty, let range = text.localizedStandardRange(of: query) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 64, limitedBy: text.endIndex) ?? text.endIndex
        before = (start == text.startIndex ? "" : "…") + text[start..<range.lowerBound]
        match = String(text[range])
        after = text[range.upperBound..<end] + (end == text.endIndex ? "" : "…")
    }
}

struct MessageSearchFocus: Equatable {
    let messageID: UUID
    let groupID: UUID?
    // A second tap on the same result must reopen its tab even if the user switched cards.
    let requestID = UUID()
    var anchorID: String { groupID.map { "group-\($0.uuidString)" } ?? messageID.uuidString }
}

struct ConversationSearchResult: Identifiable, Sendable {
    struct Hit: Identifiable, Sendable {
        let id: UUID
        let createdAt: Date
        let groupID: UUID?
        let excerpt: SearchExcerpt
        let speaker: String
        let isOtherBranch: Bool
    }

    let id: UUID
    let matchesDetails: Bool
    let hits: [Hit]

    init?(conversation: Conversation, query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        id = conversation.id
        matchesDetails = conversation.title.localizedStandardContains(query)
            || conversation.folderTag?.localizedStandardContains(query) == true
            || conversation.groupMembers.contains { $0.displayLabel.localizedStandardContains(query) }
        var matches: [(ChatMessage, SearchExcerpt)] = []
        for message in conversation.messages {
            if Task.isCancelled { return nil }
            if let excerpt = SearchExcerpt(in: message.content, query: query), !message.assistanceMetadata.isContextDivider {
                matches.append((message, excerpt))
            }
        }
        guard matchesDetails || !matches.isEmpty else { return nil }
        let activeIDs = !matches.isEmpty && ConversationTree.usesTree(conversation)
            ? Set(ConversationTree.activeMessages(in: conversation).map(\.id)) : nil
        let blind = conversation.assistanceSettings.blindArenaMode
        let candidates = blind && !matches.isEmpty
            ? Dictionary(grouping: conversation.messages.filter { $0.comparisonGroupID != nil }, by: \.comparisonGroupID) : [:]
        hits = matches.sorted {
            if $0.0.createdAt != $1.0.createdAt { return $0.0.createdAt > $1.0.createdAt }
            return $0.0.sortIndex > $1.0.sortIndex
        }.map { message, excerpt in
            let speaker = message.role == .user ? String(localized: "提问")
                : ArenaSynthesis.visibleSpeakerName(for: message, in: candidates[message.comparisonGroupID] ?? [], blindArenaMode: blind)
            return Hit(id: message.id, createdAt: message.createdAt, groupID: message.comparisonGroupID, excerpt: excerpt,
                       speaker: speaker, isOtherBranch: activeIDs?.contains(message.id) == false)
        }
    }
}

struct HistorySearchQuery: Equatable, Sendable {
    var text: String
    var tag: String?
    var bookmarkedChatsOnly = false
}

@ModelActor
private actor ModelContainerSearchWorker {
    func search(_ request: HistorySearchQuery) throws -> [ConversationSearchResult] {
        try Task.checkCancellation()
        let trimmedQuery = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        // Push full-text substring pre-filtering to SQLite so conversations without matching
        // message bodies do not fault all historical messages into memory.
        let messageDescriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { message in
                message.content.localizedStandardContains(trimmedQuery)
            }
        )
        let candidateMessages = try modelContext.fetch(messageDescriptor)
        let matchedChatIDs = Set(candidateMessages.compactMap { $0.conversation?.id })

        let chats = try modelContext.fetch(
            FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )
        var results: [ConversationSearchResult] = []
        for chat in chats {
            try Task.checkCancellation()
            if let tag = request.tag, chat.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines) != tag { continue }
            let detailsMatch = chat.title.localizedStandardContains(trimmedQuery)
                || chat.folderTag?.localizedStandardContains(trimmedQuery) == true
                || chat.groupMembers.contains { $0.displayLabel.localizedStandardContains(trimmedQuery) }
            guard detailsMatch || matchedChatIDs.contains(chat.id) else { continue }
            if request.bookmarkedChatsOnly && !chat.messages.contains(where: { $0.assistanceMetadataData != nil && $0.assistanceMetadata.isBookmarked }) { continue }
            if let result = ConversationSearchResult(conversation: chat, query: trimmedQuery) {
                results.append(result)
            }
        }
        try Task.checkCancellation()
        return results
    }
}

/// Every search reads a fresh committed snapshot via a dedicated `@ModelActor` executor.
/// Only `Sendable` presentation values cross back to SwiftUI.
actor ConversationHistorySearch {
    func results(for request: HistorySearchQuery, in container: ModelContainer) async throws -> [ConversationSearchResult] {
        try Task.checkCancellation()
        let worker = ModelContainerSearchWorker(modelContainer: container)
        return try await worker.search(request)
    }
}

@MainActor @Observable
final class HistorySearchSession {
    private let search = ConversationHistorySearch()
    private var generation = 0
    private(set) var completed: HistorySearchQuery?
    private(set) var results: [ConversationSearchResult] = []
    private(set) var error: String?

    func update(_ query: HistorySearchQuery, in container: ModelContainer, delay: Duration = .milliseconds(180)) async {
        generation += 1
        let current = generation
        guard !query.text.isEmpty else {
            completed = nil
            results = []
            error = nil
            return
        }
        do {
            try await Task.sleep(for: delay)
            let matches = try await search.results(for: query, in: container)
            try Task.checkCancellation()
            guard generation == current else { return }
            results = matches
            error = nil
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            self.error = error.localizedDescription
            results = []
        }
        completed = query
    }
}

struct MessageSearchText: Sendable {
    struct Match: Identifiable, Sendable {
        let id: UUID
        let excerpt: SearchExcerpt?
    }

    let id: UUID
    let content: String
    let reasoning: String
    let attachments: Data
    let metadata: Data?

    init(_ message: ChatMessage) {
        id = message.id
        content = message.content
        reasoning = message.reasoningContent
        attachments = message.attachmentsData
        metadata = message.assistanceMetadataData
    }

    private struct FileName: Decodable { let fileName: String }

    // Run the text scan on the generic executor using values from the visible branch.
    nonisolated static func matches(in messages: [Self], query: String, bookmarksOnly: Bool) async throws -> [Match] {
        let decoder = JSONDecoder()
        var results: [Match] = []
        for row in messages {
            try Task.checkCancellation()
            let meta = row.metadata.flatMap { try? decoder.decode(AssistanceMetadata.self, from: $0) }
            guard meta?.isContextDivider != true, !bookmarksOnly || meta?.isBookmarked == true else { continue }
            if query.isEmpty {
                if bookmarksOnly { results.append(Match(id: row.id, excerpt: nil)) }
                continue
            }
            let excerpt = SearchExcerpt(in: row.content, query: query) ?? SearchExcerpt(in: row.reasoning, query: query)
                ?? (try? decoder.decode([FileName].self, from: row.attachments))?.lazy.compactMap { SearchExcerpt(in: $0.fileName, query: query) }.first
            if let excerpt { results.append(Match(id: row.id, excerpt: excerpt)) }
        }
        return results
    }
}
