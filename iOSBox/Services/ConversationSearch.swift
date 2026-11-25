import CryptoKit
import Foundation
import SwiftData

// MARK: - Search Excerpt (Single & Multi-Term)

struct SearchExcerpt: Sendable {
    let before: String
    let match: String
    let after: String
    let highlightTerms: [String]

    var fullSnippet: String {
        before + match + after
    }

    init?(in text: String, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.isEmpty else { return nil }

        // Fast path: exact contiguous match preserves original single-term windowing behavior.
        if let range = text.localizedStandardRange(of: trimmed) {
            let start = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 64, limitedBy: text.endIndex) ?? text.endIndex
            before = (start == text.startIndex ? "" : "…") + text[start..<range.lowerBound]
            match = String(text[range])
            after = text[range.upperBound..<end] + (end == text.endIndex ? "" : "…")
            highlightTerms = [trimmed]
            return
        }

        // Multi-term fallback: verify all tokenized terms match and center window around first match.
        let terms = SearchTokenizer.queryHighlightTerms(for: trimmed)
        guard terms.count > 1 else { return nil }
        var matchedRanges: [Range<String.Index>] = []
        for term in terms {
            guard let r = text.localizedStandardRange(of: term) else { return nil }
            matchedRanges.append(r)
        }
        guard let anchor = matchedRanges.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let start = text.index(anchor.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(anchor.upperBound, offsetBy: 96, limitedBy: text.endIndex) ?? text.endIndex
        before = (start == text.startIndex ? "" : "…") + text[start..<anchor.lowerBound]
        match = String(text[anchor])
        after = text[anchor.upperBound..<end] + (end == text.endIndex ? "" : "…")
        highlightTerms = terms
    }

    /// Best-effort snippet when FTS matched across multiple fields (e.g., title + body or partial token prefix).
    static func fallbackSnippet(in text: String, query: String) -> SearchExcerpt? {
        if let exact = SearchExcerpt(in: text, query: query) {
            return exact
        }
        let terms = SearchTokenizer.queryHighlightTerms(for: query)
        for term in terms {
            if let hit = SearchExcerpt(in: text, query: term) {
                return SearchExcerpt(
                    before: hit.before,
                    match: hit.match,
                    after: hit.after,
                    highlightTerms: terms
                )
            }
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let preview = String(clean.prefix(96)) + (clean.count > 96 ? "…" : "")
        return SearchExcerpt(before: "", match: "", after: preview, highlightTerms: terms)
    }

    init(before: String, match: String, after: String, highlightTerms: [String]) {
        self.before = before
        self.match = match
        self.after = after
        self.highlightTerms = highlightTerms
    }
}

// MARK: - Search Scope & Result Models

enum GlobalSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case conversations
    case books
    case flashcards

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "全部")
        case .conversations: return String(localized: "对话")
        case .books: return String(localized: "书架")
        case .flashcards: return String(localized: "闪卡")
        }
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
    enum MatchedField: String, Sendable {
        case content
        case reasoning
        case attachment

        var badgeLabel: String? {
            switch self {
            case .content: return nil
            case .reasoning: return String(localized: "思考过程")
            case .attachment: return String(localized: "附件")
            }
        }
    }

    struct Hit: Identifiable, Sendable {
        let id: UUID
        let createdAt: Date
        let groupID: UUID?
        let excerpt: SearchExcerpt
        let speaker: String
        let isOtherBranch: Bool
        let matchedField: MatchedField

        init(
            id: UUID,
            createdAt: Date,
            groupID: UUID?,
            excerpt: SearchExcerpt,
            speaker: String,
            isOtherBranch: Bool,
            matchedField: MatchedField = .content
        ) {
            self.id = id
            self.createdAt = createdAt
            self.groupID = groupID
            self.excerpt = excerpt
            self.speaker = speaker
            self.isOtherBranch = isOtherBranch
            self.matchedField = matchedField
        }
    }

    let id: UUID
    let matchesDetails: Bool
    let hits: [Hit]

    init(id: UUID, matchesDetails: Bool, hits: [Hit]) {
        self.id = id
        self.matchesDetails = matchesDetails
        self.hits = hits
    }

    init?(conversation: Conversation, query: String, includeReasoning: Bool = true) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        id = conversation.id
        let detailBlob = ([conversation.title, conversation.folderTag ?? ""] + conversation.groupMembers.map(\.displayLabel))
            .joined(separator: " ")
        matchesDetails = SearchTokenizer.matchesAllTerms(in: detailBlob, query: query)

        var matches: [(ChatMessage, SearchExcerpt, MatchedField)] = []
        for message in conversation.messages {
            if Task.isCancelled { return nil }
            guard !message.assistanceMetadata.isContextDivider else { continue }
            if let excerpt = SearchExcerpt(in: message.content, query: query) {
                matches.append((message, excerpt, .content))
            } else if includeReasoning, let excerpt = SearchExcerpt(in: message.reasoningContent, query: query) {
                matches.append((message, excerpt, .reasoning))
            } else {
                let attachmentNames = message.attachments.map(\.fileName).joined(separator: " ")
                if let excerpt = SearchExcerpt(in: attachmentNames, query: query) {
                    matches.append((message, excerpt, .attachment))
                } else if includeReasoning {
                    let combined = [message.content, message.reasoningContent, attachmentNames].joined(separator: "\n")
                    if SearchTokenizer.matchesAllTerms(in: combined, query: query),
                       let excerpt = SearchExcerpt.fallbackSnippet(in: message.content.isEmpty ? message.reasoningContent : message.content, query: query) {
                        matches.append((message, excerpt, message.content.isEmpty ? .reasoning : .content))
                    }
                }
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
        }.map { message, excerpt, field in
            let speaker = message.role == .user ? String(localized: "提问")
                : ArenaSynthesis.visibleSpeakerName(for: message, in: candidates[message.comparisonGroupID] ?? [], blindArenaMode: blind)
            return Hit(
                id: message.id,
                createdAt: message.createdAt,
                groupID: message.comparisonGroupID,
                excerpt: excerpt,
                speaker: speaker,
                isOtherBranch: activeIDs?.contains(message.id) == false,
                matchedField: field
            )
        }
    }
}

struct BookSearchHit: Identifiable, Hashable, Sendable {
    let id: String
    let volumeID: UUID
    let bookTitle: String
    let sectionTitle: String
    let chapterIndex: Int
    let utf16Offset: Int
    let excerpt: SearchExcerpt

    static func == (lhs: BookSearchHit, rhs: BookSearchHit) -> Bool {
        lhs.id == rhs.id && lhs.volumeID == rhs.volumeID && lhs.chapterIndex == rhs.chapterIndex
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(volumeID)
        hasher.combine(chapterIndex)
    }
}

struct FlashcardSearchHit: Identifiable, Sendable {
    let id: UUID
    let deckName: String
    let front: String
    let back: String
    let excerpt: SearchExcerpt
}

struct GlobalSearchResults: Sendable {
    var conversations: [ConversationSearchResult] = []
    var books: [BookSearchHit] = []
    var flashcards: [FlashcardSearchHit] = []

    var isEmpty: Bool {
        conversations.isEmpty && books.isEmpty && flashcards.isEmpty
    }

    var totalCount: Int {
        conversations.count + books.count + flashcards.count
    }
}

struct HistorySearchQuery: Equatable, Sendable {
    var text: String
    var tag: String?
    var bookmarkedChatsOnly = false
    var scope: GlobalSearchScope = .all
    var includeReasoning: Bool = true
}

// MARK: - SwiftData Snapshot Builder for FTS5 Indexing

private struct IndexedModelSnapshot: Sendable {
    var conversations: [FTSIndexedDocument]
    var messages: [FTSIndexedDocument]
    var books: [FTSIndexedDocument]
    var conversationUpdatedAt: [UUID: Date]
    var bookmarkedConversationIDs: Set<UUID>
    var messageComparisonGroups: [UUID: UUID]
    var conversationTags: [UUID: String]
}

private func deterministicFingerprint(_ parts: String...) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    let prime: UInt64 = 1_099_511_628_211
    for part in parts {
        for byte in part.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        hash ^= 0xFF
        hash = hash &* prime
    }
    return String(hash, radix: 16)
}

@ModelActor
private actor ModelContainerFTSExtractor {
    func extractSnapshot(includeBooks: Bool) throws -> IndexedModelSnapshot {
        try Task.checkCancellation()
        let chats = try modelContext.fetch(
            FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )

        var convDocs: [FTSIndexedDocument] = []
        var msgDocs: [FTSIndexedDocument] = []
        var convUpdatedAt: [UUID: Date] = [:]
        var bookmarkedChatIDs = Set<UUID>()
        var compGroups: [UUID: UUID] = [:]
        var convTags: [UUID: String] = [:]

        let decoder = JSONDecoder()
        struct FileNameProbe: Decodable { let fileName: String }

        for chat in chats {
            try Task.checkCancellation()
            convUpdatedAt[chat.id] = chat.updatedAt
            let cleanTag = chat.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanTag, !cleanTag.isEmpty {
                convTags[chat.id] = cleanTag
            }

            let memberLabels = chat.groupMembers.map(\.displayLabel).joined(separator: " ")
            let convAux = [cleanTag ?? "", memberLabels].filter { !$0.isEmpty }.joined(separator: " ")
            let convFP = deterministicFingerprint(
                "\(chat.updatedAt.timeIntervalSince1970)",
                chat.title,
                convAux,
                "\(chat.messages.count)"
            )
            convDocs.append(FTSIndexedDocument(
                docKey: "chat:\(chat.id.uuidString)",
                entityType: .conversation,
                parentID: chat.id.uuidString,
                itemID: chat.id.uuidString,
                title: chat.title,
                subtitle: cleanTag ?? "",
                rawBody: chat.title,
                rawAux: convAux,
                folderTag: cleanTag?.isEmpty == false ? cleanTag : nil,
                isBookmarked: false,
                isOtherBranch: false,
                role: nil,
                speaker: nil,
                chapterIndex: nil,
                utf16Offset: nil,
                createdAt: chat.createdAt,
                updatedAt: chat.updatedAt,
                fingerprint: convFP
            ))

            let usesTree = ConversationTree.usesTree(chat)
            let activeIDs = usesTree ? Set(ConversationTree.activeMessages(in: chat).map(\.id)) : nil
            let blind = chat.assistanceSettings.blindArenaMode
            let candidatesByGroup = blind
                ? Dictionary(grouping: chat.messages.filter { $0.comparisonGroupID != nil }, by: \.comparisonGroupID)
                : [:]

            for msg in chat.messages {
                try Task.checkCancellation()
                let meta = msg.assistanceMetadataData != nil ? msg.assistanceMetadata : nil
                if meta?.isContextDivider == true { continue }
                let isBookmarked = meta?.isBookmarked == true
                if isBookmarked { bookmarkedChatIDs.insert(chat.id) }
                if let group = msg.comparisonGroupID {
                    compGroups[msg.id] = group
                }

                let attachmentNames: String
                if !msg.attachmentsData.isEmpty,
                   let parsed = try? decoder.decode([FileNameProbe].self, from: msg.attachmentsData),
                   !parsed.isEmpty {
                    attachmentNames = parsed.map(\.fileName).joined(separator: " ")
                } else {
                    attachmentNames = ""
                }

                let speaker = msg.role == .user
                    ? String(localized: "提问")
                    : ArenaSynthesis.visibleSpeakerName(
                        for: msg,
                        in: candidatesByGroup[msg.comparisonGroupID] ?? [],
                        blindArenaMode: blind
                    )
                // Encode reasoning and attachment names separately with ASCII Unit Separator so we can
                // accurately attribute hits to `.reasoning` vs `.attachment` without indexing chat title on messages.
                let aux = "\(msg.reasoningContent)\u{001F}\(attachmentNames)"
                let isOther = activeIDs?.contains(msg.id) == false
                let msgFP = deterministicFingerprint(
                    msg.content,
                    aux,
                    "\(isBookmarked):\(isOther)",
                    speaker,
                    cleanTag ?? ""
                )

                msgDocs.append(FTSIndexedDocument(
                    docKey: "msg:\(msg.id.uuidString)",
                    entityType: .message,
                    parentID: chat.id.uuidString,
                    itemID: msg.id.uuidString,
                    title: "",
                    subtitle: speaker,
                    rawBody: msg.content,
                    rawAux: aux,
                    folderTag: cleanTag?.isEmpty == false ? cleanTag : nil,
                    isBookmarked: isBookmarked,
                    isOtherBranch: isOther,
                    role: msg.roleRaw,
                    speaker: speaker,
                    chapterIndex: nil,
                    utf16Offset: nil,
                    createdAt: msg.createdAt,
                    updatedAt: msg.createdAt,
                    fingerprint: msgFP
                ))
            }
        }

        var bookDocs: [FTSIndexedDocument] = []
        if includeBooks {
            let volumes = try modelContext.fetch(FetchDescriptor<BookVolume>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
            for vol in volumes {
                try Task.checkCancellation()
                guard let chapters = try? JSONDecoder().decode([BookChapter].self, from: vol.manuscript) else { continue }
                for (chapIdx, chapter) in chapters.enumerated() {
                    let cleanText = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanText.isEmpty else { continue }
                    let docKey = "book:\(vol.id.uuidString):\(chapIdx)"
                    let fp = "\(vol.id.uuidString):\(vol.title.count):\(chapIdx):\(chapter.text.utf8.count)"
                    bookDocs.append(FTSIndexedDocument(
                        docKey: docKey,
                        entityType: .bookChunk,
                        parentID: vol.id.uuidString,
                        itemID: "\(vol.id.uuidString):\(chapIdx)",
                        title: vol.title,
                        subtitle: chapter.title,
                        rawBody: cleanText,
                        rawAux: chapter.title,
                        folderTag: nil,
                        isBookmarked: false,
                        isOtherBranch: false,
                        role: nil,
                        speaker: nil,
                        chapterIndex: chapIdx,
                        utf16Offset: 0,
                        createdAt: vol.importedAt,
                        updatedAt: vol.importedAt,
                        fingerprint: fp
                    ))
                }
            }
        }

        return IndexedModelSnapshot(
            conversations: convDocs,
            messages: msgDocs,
            books: bookDocs,
            conversationUpdatedAt: convUpdatedAt,
            bookmarkedConversationIDs: bookmarkedChatIDs,
            messageComparisonGroups: compGroups,
            conversationTags: convTags
        )
    }
}

// MARK: - FTS5-Backed Global & Conversation History Search

/// Every search incrementally syncs into SQLite FTS5 (`FullTextSearchIndex`) and executes
/// multi-term CJK/Latin BM25 ranking off the main actor.
actor ConversationHistorySearch {
    private let suppliedIndex: FullTextSearchIndex?
    private lazy var ephemeralIndex = FullTextSearchIndex(databaseURL: nil)

    init(index: FullTextSearchIndex? = nil) {
        self.suppliedIndex = index
    }

    private func resolveIndex(for container: ModelContainer) -> FullTextSearchIndex {
        if let suppliedIndex { return suppliedIndex }
        let isInMemory = container.configurations.allSatisfy(\.isStoredInMemoryOnly)
        return isInMemory ? ephemeralIndex : FullTextSearchIndex.shared
    }

    func results(for request: HistorySearchQuery, in container: ModelContainer) async throws -> [ConversationSearchResult] {
        let all = try await searchAll(for: request, in: container, flashcards: [])
        return all.conversations
    }

    func rebuildIndex(in container: ModelContainer, flashcards: [StudyFlashcard]) async throws -> FullTextIndexStats {
        let index = resolveIndex(for: container)
        try await index.resetGlobalSearchTables()
        let extractor = ModelContainerFTSExtractor(modelContainer: container)
        let snapshot = try await extractor.extractSnapshot(includeBooks: true)
        try await index.syncDocuments(entityType: .conversation, documents: snapshot.conversations)
        try await index.syncDocuments(entityType: .message, documents: snapshot.messages)
        try await index.syncDocuments(entityType: .bookChunk, documents: snapshot.books)
        try await index.syncDocuments(entityType: .flashcard, documents: Self.flashcardDocuments(from: flashcards))
        return await index.stats()
    }

    func searchAll(
        for request: HistorySearchQuery,
        in container: ModelContainer,
        flashcards: [StudyFlashcard]
    ) async throws -> GlobalSearchResults {
        try Task.checkCancellation()
        let trimmedQuery = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return GlobalSearchResults() }

        let index = resolveIndex(for: container)
        let wantConversations = request.scope == .all || request.scope == .conversations
        let wantBooks = (request.scope == .all || request.scope == .books) && request.tag == nil && !request.bookmarkedChatsOnly
        let wantFlashcards = (request.scope == .all || request.scope == .flashcards) && request.tag == nil && !request.bookmarkedChatsOnly

        let extractor = ModelContainerFTSExtractor(modelContainer: container)
        let snapshot = try await extractor.extractSnapshot(includeBooks: wantBooks)
        try Task.checkCancellation()

        if wantConversations {
            try await index.syncDocuments(entityType: .conversation, documents: snapshot.conversations)
            try await index.syncDocuments(entityType: .message, documents: snapshot.messages)
        }
        if wantBooks {
            try await index.syncDocuments(entityType: .bookChunk, documents: snapshot.books)
        }
        if wantFlashcards {
            try await index.syncDocuments(entityType: .flashcard, documents: Self.flashcardDocuments(from: flashcards))
        }
        try Task.checkCancellation()

        var output = GlobalSearchResults()

        if wantConversations {
            let cleanTag = request.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            let activeTag = (cleanTag?.isEmpty == false) ? cleanTag : nil

            let convHits = try await index.search(
                query: trimmedQuery,
                entityTypes: [.conversation],
                folderTag: activeTag,
                includeAux: true,
                limit: 80
            )
            let msgHits = try await index.search(
                query: trimmedQuery,
                entityTypes: [.message],
                folderTag: activeTag,
                includeAux: request.includeReasoning,
                limit: 200
            )

            var detailMatchedIDs = Set<UUID>()
            var bestRankByConv: [UUID: Double] = [:]

            for hit in convHits {
                guard let cid = UUID(uuidString: hit.parentID) else { continue }
                if request.bookmarkedChatsOnly && !snapshot.bookmarkedConversationIDs.contains(cid) { continue }
                detailMatchedIDs.insert(cid)
                bestRankByConv[cid] = min(bestRankByConv[cid] ?? .infinity, hit.bm25Score)
            }

            var messageHitsByConv: [UUID: [ConversationSearchResult.Hit]] = [:]
            for hit in msgHits {
                guard let cid = UUID(uuidString: hit.parentID),
                      let mid = UUID(uuidString: hit.itemID) else { continue }
                if request.bookmarkedChatsOnly && !snapshot.bookmarkedConversationIDs.contains(cid) { continue }

                let (excerpt, field) = Self.resolveMessageExcerpt(
                    body: hit.rawBody,
                    aux: hit.rawAux,
                    query: trimmedQuery,
                    includeReasoning: request.includeReasoning
                )
                guard let excerpt else { continue }
                bestRankByConv[cid] = min(bestRankByConv[cid] ?? .infinity, hit.bm25Score)
                messageHitsByConv[cid, default: []].append(ConversationSearchResult.Hit(
                    id: mid,
                    createdAt: hit.createdAt,
                    groupID: snapshot.messageComparisonGroups[mid],
                    excerpt: excerpt,
                    speaker: hit.speaker ?? String(localized: "回答"),
                    isOtherBranch: hit.isOtherBranch,
                    matchedField: field
                ))
            }

            let matchedConvIDs = detailMatchedIDs.union(messageHitsByConv.keys)
            var convResults: [ConversationSearchResult] = []
            for cid in matchedConvIDs {
                let sortedHits = (messageHitsByConv[cid] ?? []).sorted { $0.createdAt > $1.createdAt }
                convResults.append(ConversationSearchResult(
                    id: cid,
                    matchesDetails: detailMatchedIDs.contains(cid),
                    hits: sortedHits
                ))
            }

            convResults.sort { lhs, rhs in
                let lRank = bestRankByConv[lhs.id] ?? 0
                let rRank = bestRankByConv[rhs.id] ?? 0
                if abs(lRank - rRank) > 0.25 {
                    return lRank < rRank
                }
                let lDate = snapshot.conversationUpdatedAt[lhs.id] ?? .distantPast
                let rDate = snapshot.conversationUpdatedAt[rhs.id] ?? .distantPast
                return lDate > rDate
            }
            output.conversations = convResults
        }

        if wantBooks {
            let rawBookHits = try await index.search(
                query: trimmedQuery,
                entityTypes: [.bookChunk],
                folderTag: nil,
                includeAux: true,
                limit: 30
            )
            var seenChapters = Set<String>()
            for hit in rawBookHits {
                guard let vid = UUID(uuidString: hit.parentID),
                      let chapIdx = hit.chapterIndex,
                      seenChapters.insert(hit.docKey).inserted else { continue }
                let offset = Self.findMatchUTF16Offset(in: hit.rawBody, query: trimmedQuery)
                let excerpt = SearchExcerpt.fallbackSnippet(in: hit.rawBody, query: trimmedQuery)
                    ?? SearchExcerpt.fallbackSnippet(in: hit.subtitle, query: trimmedQuery)
                guard let excerpt else { continue }
                output.books.append(BookSearchHit(
                    id: hit.docKey,
                    volumeID: vid,
                    bookTitle: hit.title,
                    sectionTitle: hit.subtitle,
                    chapterIndex: chapIdx,
                    utf16Offset: offset,
                    excerpt: excerpt
                ))
            }
        }

        if wantFlashcards {
            let rawCardHits = try await index.search(
                query: trimmedQuery,
                entityTypes: [.flashcard],
                folderTag: nil,
                includeAux: true,
                limit: 30
            )
            for hit in rawCardHits {
                guard let cardID = UUID(uuidString: hit.itemID) else { continue }
                let excerpt = SearchExcerpt.fallbackSnippet(in: hit.title, query: trimmedQuery)
                    ?? SearchExcerpt.fallbackSnippet(in: hit.rawBody, query: trimmedQuery)
                    ?? SearchExcerpt.fallbackSnippet(in: hit.rawAux, query: trimmedQuery)
                guard let excerpt else { continue }
                output.flashcards.append(FlashcardSearchHit(
                    id: cardID,
                    deckName: hit.subtitle,
                    front: hit.title,
                    back: hit.rawBody,
                    excerpt: excerpt
                ))
            }
        }

        return output
    }

    private static func flashcardDocuments(from cards: [StudyFlashcard]) -> [FTSIndexedDocument] {
        cards.map { card in
            let aux = [card.deckName, card.hint ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            let fp = deterministicFingerprint(card.id.uuidString, card.deckName, card.front, card.back, card.hint ?? "")
            return FTSIndexedDocument(
                docKey: "card:\(card.id.uuidString)",
                entityType: .flashcard,
                parentID: card.deckName,
                itemID: card.id.uuidString,
                title: card.front,
                subtitle: card.deckName,
                rawBody: card.back,
                rawAux: aux,
                folderTag: nil,
                isBookmarked: false,
                isOtherBranch: false,
                role: nil,
                speaker: nil,
                chapterIndex: nil,
                utf16Offset: nil,
                createdAt: card.createdAt,
                updatedAt: card.lastReviewedAt ?? card.createdAt,
                fingerprint: fp
            )
        }
    }

    private static func resolveMessageExcerpt(
        body: String,
        aux: String,
        query: String,
        includeReasoning: Bool
    ) -> (SearchExcerpt?, ConversationSearchResult.MatchedField) {
        let auxParts = aux.split(separator: "\u{001F}", maxSplits: 1, omittingEmptySubsequences: false)
        let reasoning = auxParts.first.map(String.init) ?? ""
        let attachments = auxParts.count > 1 ? String(auxParts[1]) : ""

        if let excerpt = SearchExcerpt(in: body, query: query) {
            return (excerpt, .content)
        }
        if includeReasoning, !reasoning.isEmpty, let excerpt = SearchExcerpt(in: reasoning, query: query) {
            return (excerpt, .reasoning)
        }
        if !attachments.isEmpty, let excerpt = SearchExcerpt(in: attachments, query: query) {
            return (excerpt, .attachment)
        }
        if !body.isEmpty, let excerpt = SearchExcerpt.fallbackSnippet(in: body, query: query) {
            return (excerpt, .content)
        }
        if includeReasoning, !reasoning.isEmpty, let excerpt = SearchExcerpt.fallbackSnippet(in: reasoning, query: query) {
            return (excerpt, .reasoning)
        }
        if !attachments.isEmpty, let excerpt = SearchExcerpt.fallbackSnippet(in: attachments, query: query) {
            return (excerpt, .attachment)
        }
        return (nil, .content)
    }

    private static func findMatchUTF16Offset(in text: String, query: String) -> Int {
        if let range = text.localizedStandardRange(of: query) {
            return text[..<range.lowerBound].utf16.count
        }
        for term in SearchTokenizer.queryHighlightTerms(for: query) {
            if let range = text.localizedStandardRange(of: term) {
                return text[..<range.lowerBound].utf16.count
            }
        }
        return 0
    }
}

// MARK: - Observable Session for UI

@MainActor @Observable
final class HistorySearchSession {
    private let search = ConversationHistorySearch()
    private var generation = 0
    private(set) var completed: HistorySearchQuery?
    private(set) var results: [ConversationSearchResult] = []
    private(set) var bookHits: [BookSearchHit] = []
    private(set) var flashcardHits: [FlashcardSearchHit] = []
    private(set) var error: String?

    var hasAnyResults: Bool {
        !results.isEmpty || !bookHits.isEmpty || !flashcardHits.isEmpty
    }

    func update(
        _ query: HistorySearchQuery,
        in container: ModelContainer,
        flashcards: [StudyFlashcard]? = nil,
        delay: Duration = .milliseconds(160)
    ) async {
        generation += 1
        let current = generation
        guard !query.text.isEmpty else {
            completed = nil
            results = []
            bookHits = []
            flashcardHits = []
            error = nil
            return
        }
        let cards = flashcards ?? FlashcardStore.shared.cards
        do {
            try await Task.sleep(for: delay)
            let matched = try await search.searchAll(for: query, in: container, flashcards: cards)
            try Task.checkCancellation()
            guard generation == current else { return }
            results = matched.conversations
            bookHits = matched.books
            flashcardHits = matched.flashcards
            error = nil
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            self.error = error.localizedDescription
            results = []
            bookHits = []
            flashcardHits = []
        }
        completed = query
    }
}

// MARK: - In-Conversation Message Search (Multi-Term Enhanced)

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
            let attachmentNames = (try? decoder.decode([FileName].self, from: row.attachments))?.map(\.fileName) ?? []
            let excerpt = SearchExcerpt(in: row.content, query: query)
                ?? SearchExcerpt(in: row.reasoning, query: query)
                ?? attachmentNames.lazy.compactMap { SearchExcerpt(in: $0, query: query) }.first
                ?? {
                    let combined = ([row.content, row.reasoning] + attachmentNames).joined(separator: "\n")
                    guard SearchTokenizer.matchesAllTerms(in: combined, query: query) else { return nil }
                    return SearchExcerpt.fallbackSnippet(in: row.content.isEmpty ? row.reasoning : row.content, query: query)
                }()
            if let excerpt { results.append(Match(id: row.id, excerpt: excerpt)) }
        }
        return results
    }
}
