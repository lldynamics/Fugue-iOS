import CryptoKit
import Foundation
import SwiftData

// MARK: - Search Excerpt (Single & Multi-Term)

struct SearchExcerpt: Sendable {
    let before: String
    let match: String
    let after: String
    let highlightTerms: [String]
    var sourceRange: NSRange? = nil

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
            sourceRange = NSRange(start..<end, in: text)
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
        sourceRange = NSRange(start..<end, in: text)
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
                    highlightTerms: terms, sourceRange: hit.sourceRange
                )
            }
        }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let preview = String(clean.prefix(96)) + (clean.count > 96 ? "…" : "")
        return SearchExcerpt(before: "", match: "", after: preview, highlightTerms: terms)
    }

    init(before: String, match: String, after: String, highlightTerms: [String], sourceRange: NSRange? = nil) {
        self.before = before
        self.match = match
        self.after = after
        self.highlightTerms = highlightTerms
        self.sourceRange = sourceRange
    }
}

// MARK: - Search Scope & Result Models

enum GlobalSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case conversations
    case books

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "全部")
        case .conversations: return String(localized: "对话")
        case .books: return String(localized: "书架")
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
                let attachmentNames = AttachmentSearchMetadataCache.shared.joinedFileNames(
                    for: message.id,
                    data: message.attachmentsData
                )
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
        hits = matches.sorted {
            if $0.0.createdAt != $1.0.createdAt { return $0.0.createdAt > $1.0.createdAt }
            return $0.0.sortIndex > $1.0.sortIndex
        }.map { message, excerpt, field in
            let speaker = message.role == .user ? String(localized: "提问")
                : ArenaSynthesis.visibleSpeakerName(for: message)
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
    let citation: ReadingCitation?
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

struct GlobalSearchResults: Sendable {
    var conversations: [ConversationSearchResult] = []
    var books: [BookSearchHit] = []

    var isEmpty: Bool {
        conversations.isEmpty && books.isEmpty
    }

    var totalCount: Int {
        conversations.count + books.count
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
    var retainedBookVolumeIDs: Set<String>
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

// MARK: - Lightweight Attachment Metadata Cache

/// Caches attachment filenames keyed by `(messageID, byteCount, edgeDigest)` so repeated searches
/// never re-parse multi-megabyte base64 attachment JSON blobs.
final class AttachmentSearchMetadataCache: @unchecked Sendable {
    static let shared = AttachmentSearchMetadataCache()

    private struct Entry {
        let byteCount: Int
        let edgeDigest: UInt64
        let fileNames: [String]
        let joinedNames: String
    }

    private struct FileNameProbe: Decodable {
        let fileName: String
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private let maxEntries = 4_096

    func fileNames(for messageID: UUID, data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        let count = data.count
        let digest = Self.computeEdgeDigest(data)
        if let hit = lock.withLock({ entries[messageID] }),
           hit.byteCount == count,
           hit.edgeDigest == digest {
            return hit.fileNames
        }

        let names: [String] = autoreleasepool {
            guard let parsed = try? JSONDecoder().decode([FileNameProbe].self, from: data),
                  !parsed.isEmpty else {
                return []
            }
            return parsed.map(\.fileName)
        }
        let joined = names.joined(separator: " ")
        lock.withLock {
            if entries.count >= maxEntries {
                entries.removeAll(keepingCapacity: true)
            }
            entries[messageID] = Entry(
                byteCount: count,
                edgeDigest: digest,
                fileNames: names,
                joinedNames: joined
            )
        }
        return names
    }

    func joinedFileNames(for messageID: UUID, data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let count = data.count
        let digest = Self.computeEdgeDigest(data)
        if let hit = lock.withLock({ entries[messageID] }),
           hit.byteCount == count,
           hit.edgeDigest == digest {
            return hit.joinedNames
        }
        return fileNames(for: messageID, data: data).joined(separator: " ")
    }

    private static func computeEdgeDigest(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        let headCount = min(data.count, 256)
        for byte in data.prefix(headCount) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        if data.count > 256 {
            let tailCount = min(data.count - 256, 256)
            for byte in data.suffix(tailCount) {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
        }
        return hash
    }
}

@ModelActor
private actor ModelContainerFTSExtractor {
    func extractSnapshot(
        includeBooks: Bool,
        indexedBookSummaries: [String: FullTextSearchIndex.IndexedBookVolumeSummary] = [:],
        indexedSyncState: FullTextSearchIndex.IndexedConversationSyncState? = nil
    ) throws -> IndexedModelSnapshot {
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

        for chat in chats {
            try Task.checkCancellation()
            convUpdatedAt[chat.id] = chat.updatedAt
            let cleanTag = chat.folderTag?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanTag, !cleanTag.isEmpty {
                convTags[chat.id] = cleanTag
            }

            let chatDocKey = "chat:\(chat.id.uuidString)"
            let chatUnchangedInIndex = indexedSyncState?.conversationEpochs[chatDocKey]
                .map { abs($0 - chat.updatedAt.timeIntervalSince1970) < 0.000_5 } ?? false

            let memberLabels = chat.groupMembers.map(\.displayLabel).joined(separator: " ")
            let convAux = [cleanTag ?? "", memberLabels].filter { !$0.isEmpty }.joined(separator: " ")
            let convFP = deterministicFingerprint(
                "\(chat.updatedAt.timeIntervalSince1970)",
                chat.title,
                convAux,
                "\(chat.messages.count)"
            )
            convDocs.append(FTSIndexedDocument(
                docKey: chatDocKey,
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

            for msg in chat.messages {
                try Task.checkCancellation()
                let meta = msg.assistanceMetadataData != nil ? msg.assistanceMetadata : nil
                if meta?.isContextDivider == true { continue }
                let isBookmarked = meta?.isBookmarked == true
                if isBookmarked { bookmarkedChatIDs.insert(chat.id) }
                if let group = msg.comparisonGroupID {
                    compGroups[msg.id] = group
                }

                let msgDocKey = "msg:\(msg.id.uuidString)"
                let attachmentNames: String
                if !msg.isStreaming,
                   (chatUnchangedInIndex || msg.role == .user),
                   let alreadyIndexedNames = indexedSyncState?.messageAttachmentNames[msgDocKey] {
                    // Avoid faulting `@Attribute(.externalStorage) var attachmentsData` from disk!
                    attachmentNames = alreadyIndexedNames
                } else {
                    attachmentNames = AttachmentSearchMetadataCache.shared.joinedFileNames(
                        for: msg.id,
                        data: msg.attachmentsData
                    )
                }

                let speaker = msg.role == .user
                    ? String(localized: "提问")
                    : ArenaSynthesis.visibleSpeakerName(for: msg)
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
                    docKey: msgDocKey,
                    entityType: .message,
                    parentID: chat.id.uuidString,
                    itemID: msg.id.uuidString,
                    title: attachmentNames,
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
        var retainedBookVolumeIDs = Set<String>()
        if includeBooks {
            let volumes = try modelContext.fetch(FetchDescriptor<BookVolume>(sortBy: [SortDescriptor(\.importedAt, order: .reverse)]))
            for vol in volumes {
                try Task.checkCancellation()
                let volumeKey = vol.id.uuidString
                // BookVolume.id is content-addressed (SHA-256 of manuscript); when already indexed
                // with matching title and chapter count, skip faulting the external manuscript blob.
                if let existing = indexedBookSummaries[volumeKey],
                   existing.title == vol.title,
                   existing.chunkCount == vol.chapterTitles.count,
                   existing.chunkCount > 0 {
                    retainedBookVolumeIDs.insert(volumeKey)
                    continue
                }
                autoreleasepool {
                    guard let chapters = try? decoder.decode([BookChapter].self, from: vol.manuscript) else { return }
                    for (chapIdx, chapter) in chapters.enumerated() {
                        let cleanText = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanText.isEmpty else { continue }
                        let docKey = "book:\(volumeKey):\(chapIdx)"
                        let fp = deterministicFingerprint(volumeKey, vol.title, "\(chapIdx)", "\(chapter.text.utf8.count)")
                        bookDocs.append(FTSIndexedDocument(
                            docKey: docKey,
                            entityType: .bookChunk,
                            parentID: volumeKey,
                            itemID: "\(volumeKey):\(chapIdx)",
                            title: vol.title,
                            subtitle: chapter.title,
                            rawBody: chapter.text,
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
        }

        return IndexedModelSnapshot(
            conversations: convDocs,
            messages: msgDocs,
            books: bookDocs,
            retainedBookVolumeIDs: retainedBookVolumeIDs,
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
        let all = try await searchAll(for: request, in: container)
        return all.conversations
    }

    func rebuildIndex(in container: ModelContainer) async throws -> FullTextIndexStats {
        let index = resolveIndex(for: container)
        try await index.resetGlobalSearchTables()
        let extractor = ModelContainerFTSExtractor(modelContainer: container)
        let snapshot = try await extractor.extractSnapshot(includeBooks: true)
        try await index.syncDocuments(entityType: .conversation, documents: snapshot.conversations)
        try await index.syncDocuments(entityType: .message, documents: snapshot.messages)
        try await index.syncDocuments(entityType: .bookChunk, documents: snapshot.books)
        return await index.stats()
    }

    func searchAll(
        for request: HistorySearchQuery,
        in container: ModelContainer
    ) async throws -> GlobalSearchResults {
        try Task.checkCancellation()
        let trimmedQuery = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return GlobalSearchResults() }

        let index = resolveIndex(for: container)
        let wantConversations = request.scope == .all || request.scope == .conversations
        let wantBooks = (request.scope == .all || request.scope == .books) && request.tag == nil && !request.bookmarkedChatsOnly

        let convSyncState = wantConversations ? (try? await index.indexedConversationSyncState()) : nil
        let bookSummaries = wantBooks ? ((try? await index.indexedBookVolumeSummaries()) ?? [:]) : [:]
        let extractor = ModelContainerFTSExtractor(modelContainer: container)
        let snapshot = try await extractor.extractSnapshot(
            includeBooks: wantBooks,
            indexedBookSummaries: bookSummaries,
            indexedSyncState: convSyncState
        )
        try Task.checkCancellation()

        if wantConversations {
            try await index.syncDocuments(entityType: .conversation, documents: snapshot.conversations)
            try await index.syncDocuments(entityType: .message, documents: snapshot.messages)
        }
        if wantBooks {
            try await index.syncBookChunks(
                documents: snapshot.books,
                retainingParentIDs: snapshot.retainedBookVolumeIDs
            )
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
                let excerpt = SearchExcerpt.fallbackSnippet(in: hit.rawBody, query: trimmedQuery)
                    ?? SearchExcerpt.fallbackSnippet(in: hit.subtitle, query: trimmedQuery)
                guard let excerpt else { continue }
                let citation = excerpt.sourceRange.flatMap { span -> ReadingCitation? in
                    guard let range = Range(span, in: hit.rawBody) else { return nil }
                    return ReadingCitation(KnowledgePassage(
                        id: 1, volumeID: vid, documentTitle: hit.title, sectionTitle: hit.subtitle,
                        excerpt: String(hit.rawBody[range]), chapterIndex: chapIdx, utf16Offset: span.location
                    ))
                }
                output.books.append(BookSearchHit(
                    id: hit.docKey,
                    volumeID: vid,
                    bookTitle: hit.title,
                    sectionTitle: hit.subtitle,
                    chapterIndex: chapIdx,
                    citation: citation,
                    excerpt: excerpt
                ))
            }
        }

        return output
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


}

// MARK: - Observable Session for UI

@MainActor @Observable
final class HistorySearchSession {
    private let search = ConversationHistorySearch()
    private var generation = 0
    private(set) var completed: HistorySearchQuery?
    private(set) var results: [ConversationSearchResult] = []
    private(set) var bookHits: [BookSearchHit] = []
    private(set) var error: String?

    var hasAnyResults: Bool {
        !results.isEmpty || !bookHits.isEmpty
    }

    func update(
        _ query: HistorySearchQuery,
        in container: ModelContainer,
        delay: Duration = .milliseconds(160)
    ) async {
        generation += 1
        let current = generation
        guard !query.text.isEmpty else {
            completed = nil
            results = []
            bookHits = []
            error = nil
            return
        }
        do {
            try await Task.sleep(for: delay)
            let matched = try await search.searchAll(for: query, in: container)
            try Task.checkCancellation()
            guard generation == current else { return }
            results = matched.conversations
            bookHits = matched.books
            error = nil
        } catch {
            guard !Task.isCancelled, generation == current else { return }
            self.error = error.localizedDescription
            results = []
            bookHits = []
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
    let attachmentNames: [String]
    let metadata: Data?

    init(_ message: ChatMessage) {
        id = message.id
        content = message.content
        reasoning = message.reasoningContent
        attachmentNames = AttachmentSearchMetadataCache.shared.fileNames(
            for: message.id,
            data: message.attachmentsData
        )
        metadata = message.assistanceMetadataData
    }

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
            let attachmentNames = row.attachmentNames
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
