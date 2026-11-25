import CryptoKit
import Foundation
import SQLite3

// MARK: - CJK + Latin Search Tokenizer

enum SearchTokenizer {
    struct ParsedQuery: Equatable, Sendable {
        let ftsMatchExpression: String
        let highlightTerms: [String]

        var isEmpty: Bool {
            ftsMatchExpression.isEmpty
        }
    }

    static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana
             0xAC00...0xD7AF,   // Hangul Syllables
             0x20000...0x2FA1F: // CJK Extensions B-F / Compatibility Supplement
            return true
        default:
            return false
        }
    }

    /// Converts raw text into space-separated tokens compatible with SQLite FTS5 `unicode61`.
    /// Latin/numeric words stay intact; CJK runs emit unigrams and overlapping bigrams so both
    /// single-character and multi-character Chinese/Japanese/Korean searches work accurately.
    static func indexText(_ raw: String, maxCharacters: Int = 120_000) -> String {
        guard !raw.isEmpty else { return "" }
        let bounded = raw.count > maxCharacters ? String(raw.prefix(maxCharacters)) : raw
        let lowered = bounded.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        var tokens: [String] = []
        tokens.reserveCapacity(min(lowered.count, 4096))

        var latinWord = ""
        var cjkRun: [Character] = []

        func flushLatin() {
            if !latinWord.isEmpty {
                tokens.append(latinWord)
                latinWord.removeAll(keepingCapacity: true)
            }
        }

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            for ch in cjkRun {
                tokens.append(String(ch))
            }
            if cjkRun.count >= 2 {
                for i in 0..<(cjkRun.count - 1) {
                    tokens.append(String([cjkRun[i], cjkRun[i + 1]]))
                }
            }
            cjkRun.removeAll(keepingCapacity: true)
        }

        for ch in lowered {
            if let scalar = ch.unicodeScalars.first, isCJK(scalar) {
                flushLatin()
                cjkRun.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                latinWord.append(ch)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return tokens.joined(separator: " ")
    }

    /// Splits a raw user query into clean highlightable terms (whitespace-separated phrases/words).
    static func queryHighlightTerms(for rawQuery: String) -> [String] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var seen = Set<String>()
        var terms: [String] = []
        for rawPart in trimmed.split(whereSeparator: \.isWhitespace) {
            let clean = String(rawPart).trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_.")))
            guard !clean.isEmpty else { continue }
            let key = clean.lowercased()
            if seen.insert(key).inserted {
                terms.append(clean)
            }
            if terms.count >= 12 { break }
        }
        return terms.isEmpty ? [trimmed] : terms
    }

    /// Builds a safe, injection-proof SQLite FTS5 `MATCH` expression from arbitrary user input.
    /// Relaxed matching lets a passage match part of a continuous CJK query or one clause of a question.
    static func parseQuery(_ rawQuery: String, useOR: Bool = false) -> ParsedQuery {
        let highlightTerms = queryHighlightTerms(for: rawQuery)
        guard !highlightTerms.isEmpty else {
            return ParsedQuery(ftsMatchExpression: "", highlightTerms: [])
        }

        let joiner = useOR ? " OR " : " AND "
        var groupClauses: [String] = []
        for term in highlightTerms {
            let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            var subClauses: [String] = []
            var latinWord = ""
            var cjkRun: [Character] = []

            func flushLatin() {
                guard !latinWord.isEmpty else { return }
                let escaped = ftsQuoted(latinWord)
                // Prefix match for Latin/numeric tokens >= 2 chars so typing "swift" matches "SwiftData".
                subClauses.append(latinWord.count >= 2 ? "\(escaped)*" : escaped)
                latinWord.removeAll(keepingCapacity: true)
            }

            func flushCJK() {
                guard !cjkRun.isEmpty else { return }
                if cjkRun.count == 1 {
                    subClauses.append(ftsQuoted(String(cjkRun[0])))
                } else {
                    for i in 0..<(cjkRun.count - 1) {
                        subClauses.append(ftsQuoted(String([cjkRun[i], cjkRun[i + 1]])))
                    }
                }
                cjkRun.removeAll(keepingCapacity: true)
            }

            for ch in folded {
                if let scalar = ch.unicodeScalars.first, isCJK(scalar) {
                    flushLatin()
                    cjkRun.append(ch)
                } else if ch.isLetter || ch.isNumber {
                    flushCJK()
                    latinWord.append(ch)
                } else {
                    flushLatin()
                    flushCJK()
                }
            }
            flushLatin()
            flushCJK()

            if subClauses.count == 1 {
                groupClauses.append(subClauses[0])
            } else if subClauses.count > 1 {
                groupClauses.append("(" + subClauses.joined(separator: joiner) + ")")
            }
        }

        return ParsedQuery(
            ftsMatchExpression: groupClauses.joined(separator: joiner),
            highlightTerms: highlightTerms
        )
    }

    static func matchesAllTerms(in text: String, query: String) -> Bool {
        let terms = queryHighlightTerms(for: query)
        guard !terms.isEmpty, !text.isEmpty else { return false }
        return terms.allSatisfy { text.localizedStandardRange(of: $0) != nil }
    }

    private static func ftsQuoted(_ token: String) -> String {
        let safe = token.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(safe)\""
    }
}

// MARK: - Indexed Document & Query Types

enum FTSIndexEntityType: String, Sendable {
    case conversation
    case message
    case bookChunk = "book_chunk"
    case flashcard
}

struct FTSIndexedDocument: Sendable {
    let docKey: String
    let entityType: FTSIndexEntityType
    let parentID: String
    let itemID: String
    let title: String
    let subtitle: String
    let rawBody: String
    let rawAux: String
    let folderTag: String?
    let isBookmarked: Bool
    let isOtherBranch: Bool
    let role: String?
    let speaker: String?
    let chapterIndex: Int?
    let utf16Offset: Int?
    let createdAt: Date
    let updatedAt: Date
    let fingerprint: String
}

struct FTSHitRecord: Sendable {
    let docKey: String
    let entityType: FTSIndexEntityType
    let parentID: String
    let itemID: String
    let title: String
    let subtitle: String
    let rawBody: String
    let rawAux: String
    let folderTag: String?
    let isBookmarked: Bool
    let isOtherBranch: Bool
    let role: String?
    let speaker: String?
    let chapterIndex: Int?
    let utf16Offset: Int?
    let createdAt: Date
    let updatedAt: Date
    let bm25Score: Double
}

struct RAGStoredChunk: Sendable {
    let chunkID: String
    let volumeID: UUID
    let documentTitle: String
    let sectionIndex: Int
    let sectionTitle: String
    let utf16Offset: Int
    let rawText: String
    let embeddingModel: String
    let embedding: [Float]?
}

struct RAGLexicalCandidate: Sendable {
    let chunkID: String
    let volumeID: UUID
    let documentTitle: String
    let sectionIndex: Int
    let sectionTitle: String
    let utf16Offset: Int
    let rawText: String
    let bm25Rank: Double
}

struct FullTextIndexStats: Equatable, Sendable {
    var conversationCount: Int = 0
    var messageCount: Int = 0
    var bookChunkCount: Int = 0
    var flashcardCount: Int = 0
    var ragVolumeCount: Int = 0
    var ragChunkCount: Int = 0
    var ragEmbeddedChunkCount: Int = 0
    var databaseBytes: Int64 = 0
}

// MARK: - SQLite FTS5 & Persistent RAG Storage Engine

actor FullTextSearchIndex {
    static let shared = FullTextSearchIndex()

    private static let schemaVersion: Int32 = 1
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databaseURL: URL?
    private var db: OpaquePointer?

    init(databaseURL: URL? = FullTextSearchIndex.defaultDatabaseURL()) {
        self.databaseURL = databaseURL
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    static func defaultDatabaseURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("fugue-search-fts5.sqlite")
    }

    // MARK: - Database Lifecycle

    private func ensureOpen() throws -> OpaquePointer {
        if let db { return db }
        let handle = try openAndInitialize()
        db = handle
        return handle
    }

    private func openAndInitialize() throws -> OpaquePointer {
        let path: String
        if let databaseURL {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            path = databaseURL.path
        } else {
            path = ":memory:"
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let opened = handle else {
            if let handle { sqlite3_close_v2(handle) }
            if let databaseURL {
                try? FileManager.default.removeItem(at: databaseURL)
                var retryHandle: OpaquePointer?
                guard sqlite3_open_v2(path, &retryHandle, flags, nil) == SQLITE_OK, let retried = retryHandle else {
                    if let retryHandle { sqlite3_close_v2(retryHandle) }
                    throw FTSDatabaseError.openFailed
                }
                try configureAndMigrate(retried)
                applyFileProtectionIfNeeded()
                return retried
            }
            throw FTSDatabaseError.openFailed
        }

        do {
            try configureAndMigrate(opened)
            applyFileProtectionIfNeeded()
            return opened
        } catch {
            sqlite3_close_v2(opened)
            if let databaseURL {
                try? FileManager.default.removeItem(at: databaseURL)
                try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
                try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
                var fresh: OpaquePointer?
                guard sqlite3_open_v2(path, &fresh, flags, nil) == SQLITE_OK, let freshOpened = fresh else {
                    if let fresh { sqlite3_close_v2(fresh) }
                    throw error
                }
                try configureAndMigrate(freshOpened)
                applyFileProtectionIfNeeded()
                return freshOpened
            }
            throw error
        }
    }

    private func applyFileProtectionIfNeeded() {
        guard let databaseURL else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: databaseURL.path
        )
    }

    private func configureAndMigrate(_ handle: OpaquePointer) throws {
        try exec(handle, "PRAGMA busy_timeout = 3000;")
        if databaseURL != nil {
            try exec(handle, "PRAGMA journal_mode = WAL;")
            try exec(handle, "PRAGMA synchronous = NORMAL;")
        }
        try exec(handle, "PRAGMA temp_store = MEMORY;")

        let currentVersion = querySingleInt32(handle, sql: "PRAGMA user_version;") ?? 0
        if currentVersion != Self.schemaVersion {
            try exec(handle, """
            DROP TABLE IF EXISTS search_docs;
            DROP TABLE IF EXISTS search_meta;
            DROP TABLE IF EXISTS rag_volumes;
            DROP TABLE IF EXISTS rag_chunks;
            DROP TABLE IF EXISTS rag_chunks_fts;
            """)
        }

        try exec(handle, """
        CREATE VIRTUAL TABLE IF NOT EXISTS search_docs USING fts5(
            doc_key UNINDEXED,
            entity_type UNINDEXED,
            parent_id UNINDEXED,
            item_id UNINDEXED,
            title_tokens,
            body_tokens,
            aux_tokens,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TABLE IF NOT EXISTS search_meta (
            doc_key TEXT PRIMARY KEY,
            entity_type TEXT NOT NULL,
            parent_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT NOT NULL,
            raw_body TEXT NOT NULL,
            raw_aux TEXT NOT NULL,
            folder_tag TEXT,
            is_bookmarked INTEGER NOT NULL DEFAULT 0,
            is_other_branch INTEGER NOT NULL DEFAULT 0,
            role TEXT,
            speaker TEXT,
            chapter_index INTEGER,
            utf16_offset INTEGER,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            fingerprint TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_search_meta_entity ON search_meta(entity_type, parent_id);

        CREATE TABLE IF NOT EXISTS rag_volumes (
            volume_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            chunk_count INTEGER NOT NULL,
            embedding_model TEXT NOT NULL DEFAULT '',
            embedded_count INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS rag_chunks (
            chunk_id TEXT PRIMARY KEY,
            volume_id TEXT NOT NULL,
            document_title TEXT NOT NULL,
            section_index INTEGER NOT NULL,
            section_title TEXT NOT NULL,
            utf16_offset INTEGER NOT NULL,
            raw_text TEXT NOT NULL,
            embedding_model TEXT NOT NULL DEFAULT '',
            embedding_blob BLOB
        );
        CREATE INDEX IF NOT EXISTS idx_rag_chunks_volume ON rag_chunks(volume_id, section_index);

        CREATE VIRTUAL TABLE IF NOT EXISTS rag_chunks_fts USING fts5(
            chunk_id UNINDEXED,
            volume_id UNINDEXED,
            section_index UNINDEXED,
            title_tokens,
            body_tokens,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)

        if currentVersion != Self.schemaVersion {
            try exec(handle, "PRAGMA user_version = \(Self.schemaVersion);")
        }
    }

    // MARK: - Global Full-Text Search Sync & Query

    func syncDocuments(entityType: FTSIndexEntityType, documents: [FTSIndexedDocument]) throws {
        let handle = try ensureOpen()
        var existingFingerprints: [String: String] = [:]

        let selectSQL = "SELECT doc_key, fingerprint FROM search_meta WHERE entity_type = ?;"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, selectSQL, -1, &selectStmt, nil) == SQLITE_OK, let sStmt = selectStmt else {
            throw FTSDatabaseError.statementFailed(lastErrorMessage(handle))
        }
        defer { sqlite3_finalize(sStmt) }
        bindText(sStmt, 1, entityType.rawValue)
        while sqlite3_step(sStmt) == SQLITE_ROW {
            let key = columnString(sStmt, 0)
            let fp = columnString(sStmt, 1)
            existingFingerprints[key] = fp
        }

        let incomingKeys = Set(documents.map(\.docKey))
        let deletedKeys = existingFingerprints.keys.filter { !incomingKeys.contains($0) }
        let changedDocs = documents.filter { existingFingerprints[$0.docKey] != $0.fingerprint }

        guard !deletedKeys.isEmpty || !changedDocs.isEmpty else { return }

        try withTransaction(handle) {
            if !deletedKeys.isEmpty {
                let delFTS = try prepare(handle, "DELETE FROM search_docs WHERE doc_key = ?;")
                defer { sqlite3_finalize(delFTS) }
                let delMeta = try prepare(handle, "DELETE FROM search_meta WHERE doc_key = ?;")
                defer { sqlite3_finalize(delMeta) }
                for key in deletedKeys {
                    sqlite3_reset(delFTS)
                    bindText(delFTS, 1, key)
                    try stepDone(handle, delFTS)

                    sqlite3_reset(delMeta)
                    bindText(delMeta, 1, key)
                    try stepDone(handle, delMeta)
                }
            }

            if !changedDocs.isEmpty {
                let delFTS = try prepare(handle, "DELETE FROM search_docs WHERE doc_key = ?;")
                defer { sqlite3_finalize(delFTS) }
                let insFTS = try prepare(handle, """
                INSERT INTO search_docs(doc_key, entity_type, parent_id, item_id, title_tokens, body_tokens, aux_tokens)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(insFTS) }
                let insMeta = try prepare(handle, """
                INSERT OR REPLACE INTO search_meta(
                    doc_key, entity_type, parent_id, item_id, title, subtitle,
                    raw_body, raw_aux, folder_tag, is_bookmarked, is_other_branch,
                    role, speaker, chapter_index, utf16_offset, created_at, updated_at, fingerprint
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
                defer { sqlite3_finalize(insMeta) }

                for doc in changedDocs {
                    sqlite3_reset(delFTS)
                    bindText(delFTS, 1, doc.docKey)
                    try stepDone(handle, delFTS)

                    let titleTokens = SearchTokenizer.indexText(doc.title, maxCharacters: 4_000)
                    let bodyTokens = SearchTokenizer.indexText(doc.rawBody, maxCharacters: 80_000)
                    let auxTokens = SearchTokenizer.indexText(doc.rawAux, maxCharacters: 40_000)

                    sqlite3_reset(insFTS)
                    bindText(insFTS, 1, doc.docKey)
                    bindText(insFTS, 2, doc.entityType.rawValue)
                    bindText(insFTS, 3, doc.parentID)
                    bindText(insFTS, 4, doc.itemID)
                    bindText(insFTS, 5, titleTokens)
                    bindText(insFTS, 6, bodyTokens)
                    bindText(insFTS, 7, auxTokens)
                    try stepDone(handle, insFTS)

                    sqlite3_reset(insMeta)
                    bindText(insMeta, 1, doc.docKey)
                    bindText(insMeta, 2, doc.entityType.rawValue)
                    bindText(insMeta, 3, doc.parentID)
                    bindText(insMeta, 4, doc.itemID)
                    bindText(insMeta, 5, doc.title)
                    bindText(insMeta, 6, doc.subtitle)
                    bindText(insMeta, 7, doc.rawBody)
                    bindText(insMeta, 8, doc.rawAux)
                    bindOptionalText(insMeta, 9, doc.folderTag)
                    sqlite3_bind_int(insMeta, 10, doc.isBookmarked ? 1 : 0)
                    sqlite3_bind_int(insMeta, 11, doc.isOtherBranch ? 1 : 0)
                    bindOptionalText(insMeta, 12, doc.role)
                    bindOptionalText(insMeta, 13, doc.speaker)
                    bindOptionalInt(insMeta, 14, doc.chapterIndex)
                    bindOptionalInt(insMeta, 15, doc.utf16Offset)
                    sqlite3_bind_double(insMeta, 16, doc.createdAt.timeIntervalSince1970)
                    sqlite3_bind_double(insMeta, 17, doc.updatedAt.timeIntervalSince1970)
                    bindText(insMeta, 18, doc.fingerprint)
                    try stepDone(handle, insMeta)
                }
            }
        }
    }

    func removeParent(entityType: FTSIndexEntityType, parentID: String) throws {
        let handle = try ensureOpen()
        try withTransaction(handle) {
            let delFTS = try prepare(handle, "DELETE FROM search_docs WHERE entity_type = ? AND parent_id = ?;")
            defer { sqlite3_finalize(delFTS) }
            bindText(delFTS, 1, entityType.rawValue)
            bindText(delFTS, 2, parentID)
            try stepDone(handle, delFTS)

            let delMeta = try prepare(handle, "DELETE FROM search_meta WHERE entity_type = ? AND parent_id = ?;")
            defer { sqlite3_finalize(delMeta) }
            bindText(delMeta, 1, entityType.rawValue)
            bindText(delMeta, 2, parentID)
            try stepDone(handle, delMeta)
        }
    }

    func search(
        query: String,
        entityTypes: [FTSIndexEntityType],
        folderTag: String? = nil,
        includeAux: Bool = true,
        limit: Int = 120
    ) throws -> [FTSHitRecord] {
        let parsed = SearchTokenizer.parseQuery(query)
        guard !parsed.isEmpty, !entityTypes.isEmpty else { return [] }
        let handle = try ensureOpen()

        let typePlaceholders = entityTypes.map { _ in "?" }.joined(separator: ",")
        let matchExpr = includeAux
            ? parsed.ftsMatchExpression
            : "{title_tokens body_tokens} : (\(parsed.ftsMatchExpression))"

        var sql = """
        SELECT
            m.doc_key, m.entity_type, m.parent_id, m.item_id, m.title, m.subtitle,
            m.raw_body, m.raw_aux, m.folder_tag, m.is_bookmarked, m.is_other_branch,
            m.role, m.speaker, m.chapter_index, m.utf16_offset, m.created_at, m.updated_at,
            bm25(search_docs, 0.0, 0.0, 0.0, 0.0, 3.0, 1.0, 0.8) AS rank_score
        FROM search_docs
        JOIN search_meta m ON m.doc_key = search_docs.doc_key
        WHERE search_docs MATCH ?
          AND m.entity_type IN (\(typePlaceholders))
        """
        if folderTag != nil {
            sql += " AND m.folder_tag = ?"
        }
        sql += " ORDER BY rank_score ASC, m.updated_at DESC LIMIT ?;"

        let stmt = try prepare(handle, sql)
        defer { sqlite3_finalize(stmt) }

        var paramIdx: Int32 = 1
        bindText(stmt, paramIdx, matchExpr)
        paramIdx += 1
        for type in entityTypes {
            bindText(stmt, paramIdx, type.rawValue)
            paramIdx += 1
        }
        if let folderTag {
            bindText(stmt, paramIdx, folderTag)
            paramIdx += 1
        }
        sqlite3_bind_int(stmt, paramIdx, Int32(max(1, limit)))

        var hits: [FTSHitRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entityType = FTSIndexEntityType(rawValue: columnString(stmt, 1)) else { continue }
            hits.append(FTSHitRecord(
                docKey: columnString(stmt, 0),
                entityType: entityType,
                parentID: columnString(stmt, 2),
                itemID: columnString(stmt, 3),
                title: columnString(stmt, 4),
                subtitle: columnString(stmt, 5),
                rawBody: columnString(stmt, 6),
                rawAux: columnString(stmt, 7),
                folderTag: columnOptionalString(stmt, 8),
                isBookmarked: sqlite3_column_int(stmt, 9) != 0,
                isOtherBranch: sqlite3_column_int(stmt, 10) != 0,
                role: columnOptionalString(stmt, 11),
                speaker: columnOptionalString(stmt, 12),
                chapterIndex: columnOptionalInt(stmt, 13),
                utf16Offset: columnOptionalInt(stmt, 14),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 16)),
                bm25Score: sqlite3_column_double(stmt, 17)
            ))
        }
        return hits
    }

    // MARK: - Persistent RAG Chunk & Embedding Storage

    func isRAGVolumeUpToDate(volumeID: UUID, contentHash: String) throws -> Bool {
        let handle = try ensureOpen()
        let stmt = try prepare(handle, "SELECT content_hash FROM rag_volumes WHERE volume_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, volumeID.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return columnString(stmt, 0) == contentHash
    }

    func hasRAGVolume(_ volumeID: UUID) throws -> Bool {
        let handle = try ensureOpen()
        let stmt = try prepare(handle, "SELECT 1 FROM rag_volumes WHERE volume_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, volumeID.uuidString)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    func storeRAGVolume(
        volumeID: UUID,
        title: String,
        contentHash: String,
        chunks: [RAGStoredChunk]
    ) throws {
        let handle = try ensureOpen()
        let volStr = volumeID.uuidString

        try withTransaction(handle) {
            let delChunks = try prepare(handle, "DELETE FROM rag_chunks WHERE volume_id = ?;")
            defer { sqlite3_finalize(delChunks) }
            bindText(delChunks, 1, volStr)
            try stepDone(handle, delChunks)

            let delFTS = try prepare(handle, "DELETE FROM rag_chunks_fts WHERE volume_id = ?;")
            defer { sqlite3_finalize(delFTS) }
            bindText(delFTS, 1, volStr)
            try stepDone(handle, delFTS)

            let insChunk = try prepare(handle, """
            INSERT INTO rag_chunks(
                chunk_id, volume_id, document_title, section_index, section_title,
                utf16_offset, raw_text, embedding_model, embedding_blob
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(insChunk) }

            let insFTS = try prepare(handle, """
            INSERT INTO rag_chunks_fts(chunk_id, volume_id, section_index, title_tokens, body_tokens)
            VALUES (?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(insFTS) }

            var embeddedCount = 0
            var activeModel = ""
            for chunk in chunks {
                sqlite3_reset(insChunk)
                bindText(insChunk, 1, chunk.chunkID)
                bindText(insChunk, 2, volStr)
                bindText(insChunk, 3, chunk.documentTitle)
                sqlite3_bind_int(insChunk, 4, Int32(chunk.sectionIndex))
                bindText(insChunk, 5, chunk.sectionTitle)
                sqlite3_bind_int(insChunk, 6, Int32(chunk.utf16Offset))
                bindText(insChunk, 7, chunk.rawText)
                bindText(insChunk, 8, chunk.embeddingModel)
                if let vec = chunk.embedding, !vec.isEmpty {
                    let blob = Self.encodeFloatArray(vec)
                    bindBlob(insChunk, 9, blob)
                    embeddedCount += 1
                    activeModel = chunk.embeddingModel
                } else {
                    sqlite3_bind_null(insChunk, 9)
                }
                try stepDone(handle, insChunk)

                sqlite3_reset(insFTS)
                bindText(insFTS, 1, chunk.chunkID)
                bindText(insFTS, 2, volStr)
                sqlite3_bind_int(insFTS, 3, Int32(chunk.sectionIndex))
                bindText(insFTS, 4, SearchTokenizer.indexText("\(chunk.documentTitle) \(chunk.sectionTitle)", maxCharacters: 2_000))
                bindText(insFTS, 5, SearchTokenizer.indexText(chunk.rawText, maxCharacters: 8_000))
                try stepDone(handle, insFTS)
            }

            let upsertVol = try prepare(handle, """
            INSERT OR REPLACE INTO rag_volumes(
                volume_id, title, content_hash, chunk_count, embedding_model, embedded_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(upsertVol) }
            bindText(upsertVol, 1, volStr)
            bindText(upsertVol, 2, title)
            bindText(upsertVol, 3, contentHash)
            sqlite3_bind_int(upsertVol, 4, Int32(chunks.count))
            bindText(upsertVol, 5, activeModel)
            sqlite3_bind_int(upsertVol, 6, Int32(embeddedCount))
            sqlite3_bind_double(upsertVol, 7, Date().timeIntervalSince1970)
            try stepDone(handle, upsertVol)
        }
    }

    func updateRAGEmbeddings(
        volumeID: UUID,
        embeddingModel: String,
        embeddingsByChunkID: [String: [Float]]
    ) throws {
        guard !embeddingsByChunkID.isEmpty else { return }
        let handle = try ensureOpen()
        let volStr = volumeID.uuidString

        try withTransaction(handle) {
            let updateStmt = try prepare(handle, """
            UPDATE rag_chunks SET embedding_model = ?, embedding_blob = ? WHERE chunk_id = ? AND volume_id = ?;
            """)
            defer { sqlite3_finalize(updateStmt) }

            for (chunkID, vector) in embeddingsByChunkID where !vector.isEmpty {
                sqlite3_reset(updateStmt)
                bindText(updateStmt, 1, embeddingModel)
                bindBlob(updateStmt, 2, Self.encodeFloatArray(vector))
                bindText(updateStmt, 3, chunkID)
                bindText(updateStmt, 4, volStr)
                try stepDone(handle, updateStmt)
            }

            let countStmt = try prepare(handle, """
            SELECT COUNT(*) FROM rag_chunks WHERE volume_id = ? AND embedding_model = ? AND embedding_blob IS NOT NULL;
            """)
            defer { sqlite3_finalize(countStmt) }
            bindText(countStmt, 1, volStr)
            bindText(countStmt, 2, embeddingModel)
            var count: Int32 = 0
            if sqlite3_step(countStmt) == SQLITE_ROW {
                count = sqlite3_column_int(countStmt, 0)
            }

            let volStmt = try prepare(handle, """
            UPDATE rag_volumes SET embedding_model = ?, embedded_count = ?, updated_at = ? WHERE volume_id = ?;
            """)
            defer { sqlite3_finalize(volStmt) }
            bindText(volStmt, 1, embeddingModel)
            sqlite3_bind_int(volStmt, 2, count)
            sqlite3_bind_double(volStmt, 3, Date().timeIntervalSince1970)
            bindText(volStmt, 4, volStr)
            try stepDone(handle, volStmt)
        }
    }

    func removeRAGVolume(_ volumeID: UUID) throws {
        let handle = try ensureOpen()
        let volStr = volumeID.uuidString
        try withTransaction(handle) {
            for sql in [
                "DELETE FROM rag_chunks WHERE volume_id = ?;",
                "DELETE FROM rag_chunks_fts WHERE volume_id = ?;",
                "DELETE FROM rag_volumes WHERE volume_id = ?;"
            ] {
                let stmt = try prepare(handle, sql)
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, volStr)
                try stepDone(handle, stmt)
            }
        }
    }

    func clearAllRAGEmbeddings() throws {
        let handle = try ensureOpen()
        try withTransaction(handle) {
            try exec(handle, "UPDATE rag_chunks SET embedding_model = '', embedding_blob = NULL;")
            try exec(handle, "UPDATE rag_volumes SET embedding_model = '', embedded_count = 0;")
        }
    }

    /// Runs FTS5 BM25 retrieval over persisted RAG chunks across selected volumes.
    func searchRAGLexical(
        volumeIDs: [UUID],
        query: String,
        chapterLimits: [UUID: Int] = [:],
        useOR: Bool = false,
        limit: Int = 60
    ) throws -> [RAGLexicalCandidate] {
        guard !volumeIDs.isEmpty else { return [] }
        let parsed = SearchTokenizer.parseQuery(query, useOR: useOR)
        guard !parsed.isEmpty else { return [] }
        let handle = try ensureOpen()

        let placeholders = volumeIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT
            c.chunk_id, c.volume_id, c.document_title, c.section_index, c.section_title,
            c.utf16_offset, c.raw_text,
            bm25(rag_chunks_fts, 0.0, 0.0, 0.0, 2.5, 1.0) AS rank_score
        FROM rag_chunks_fts
        JOIN rag_chunks c ON c.chunk_id = rag_chunks_fts.chunk_id
        WHERE rag_chunks_fts MATCH ?
          AND c.volume_id IN (\(placeholders))
        ORDER BY rank_score ASC
        LIMIT ?;
        """
        let stmt = try prepare(handle, sql)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        bindText(stmt, idx, parsed.ftsMatchExpression)
        idx += 1
        for vid in volumeIDs {
            bindText(stmt, idx, vid.uuidString)
            idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(max(1, limit * 2)))

        var candidates: [RAGLexicalCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let vid = UUID(uuidString: columnString(stmt, 1)) else { continue }
            let secIdx = Int(sqlite3_column_int(stmt, 3))
            if let cap = chapterLimits[vid], secIdx > cap { continue }
            candidates.append(RAGLexicalCandidate(
                chunkID: columnString(stmt, 0),
                volumeID: vid,
                documentTitle: columnString(stmt, 2),
                sectionIndex: secIdx,
                sectionTitle: columnString(stmt, 4),
                utf16Offset: Int(sqlite3_column_int(stmt, 5)),
                rawText: columnString(stmt, 6),
                bm25Rank: sqlite3_column_double(stmt, 7)
            ))
            if candidates.count >= limit { break }
        }
        return candidates
    }

    func fetchRAGChunks(
        volumeIDs: [UUID],
        chapterLimits: [UUID: Int] = [:],
        embeddingModel: String? = nil
    ) throws -> [RAGStoredChunk] {
        guard !volumeIDs.isEmpty else { return [] }
        let handle = try ensureOpen()
        let placeholders = volumeIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT
            chunk_id, volume_id, document_title, section_index, section_title,
            utf16_offset, raw_text, embedding_model, embedding_blob
        FROM rag_chunks
        WHERE volume_id IN (\(placeholders))
        ORDER BY volume_id, section_index, utf16_offset;
        """
        let stmt = try prepare(handle, sql)
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        for vid in volumeIDs {
            bindText(stmt, idx, vid.uuidString)
            idx += 1
        }

        var result: [RAGStoredChunk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let vid = UUID(uuidString: columnString(stmt, 1)) else { continue }
            let secIdx = Int(sqlite3_column_int(stmt, 3))
            if let cap = chapterLimits[vid], secIdx > cap { continue }
            let storedModel = columnString(stmt, 7)
            let vec: [Float]?
            if embeddingModel == nil || storedModel == embeddingModel {
                vec = columnBlob(stmt, 8).flatMap(Self.decodeFloatArray)
            } else {
                vec = nil
            }
            result.append(RAGStoredChunk(
                chunkID: columnString(stmt, 0),
                volumeID: vid,
                documentTitle: columnString(stmt, 2),
                sectionIndex: secIdx,
                sectionTitle: columnString(stmt, 4),
                utf16Offset: Int(sqlite3_column_int(stmt, 5)),
                rawText: columnString(stmt, 6),
                embeddingModel: storedModel,
                embedding: vec
            ))
        }
        return result
    }

    // MARK: - Diagnostics & Maintenance

    func stats() -> FullTextIndexStats {
        guard let handle = try? ensureOpen() else { return FullTextIndexStats() }
        var out = FullTextIndexStats()
        out.conversationCount = Int(querySingleInt32(handle, sql: "SELECT COUNT(*) FROM search_meta WHERE entity_type = 'conversation';") ?? 0)
        out.messageCount = Int(querySingleInt32(handle, sql: "SELECT COUNT(*) FROM search_meta WHERE entity_type = 'message';") ?? 0)
        out.bookChunkCount = Int(querySingleInt32(handle, sql: "SELECT COUNT(*) FROM search_meta WHERE entity_type = 'book_chunk';") ?? 0)
        out.flashcardCount = Int(querySingleInt32(handle, sql: "SELECT COUNT(*) FROM search_meta WHERE entity_type = 'flashcard';") ?? 0)
        out.ragVolumeCount = Int(querySingleInt32(handle, sql: "SELECT COUNT(*) FROM rag_volumes;") ?? 0)
        out.ragChunkCount = Int(querySingleInt32(handle, sql: "SELECT COUNT(*) FROM rag_chunks;") ?? 0)
        out.ragEmbeddedChunkCount = Int(querySingleInt32(handle, sql: "SELECT COUNT(*) FROM rag_chunks WHERE embedding_blob IS NOT NULL;") ?? 0)
        if let databaseURL,
           let values = try? databaseURL.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            out.databaseBytes = Int64(size)
        }
        return out
    }

    func resetGlobalSearchTables() throws {
        let handle = try ensureOpen()
        try withTransaction(handle) {
            try exec(handle, "DELETE FROM search_docs;")
            try exec(handle, "DELETE FROM search_meta;")
        }
    }

    func resetAll() throws {
        let handle = try ensureOpen()
        try withTransaction(handle) {
            try exec(handle, "DELETE FROM search_docs;")
            try exec(handle, "DELETE FROM search_meta;")
            try exec(handle, "DELETE FROM rag_volumes;")
            try exec(handle, "DELETE FROM rag_chunks;")
            try exec(handle, "DELETE FROM rag_chunks_fts;")
        }
    }

    // MARK: - Float32 Embedding Serialization

    static func encodeFloatArray(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func decodeFloatArray(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count % MemoryLayout<Float>.stride == 0 else { return nil }
        let count = data.count / MemoryLayout<Float>.stride
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest)
        }
        return result
    }

    // MARK: - Low-level SQLite Helpers

    private func withTransaction(_ handle: OpaquePointer, _ body: () throws -> Void) throws {
        try exec(handle, "BEGIN IMMEDIATE;")
        do {
            try body()
            try exec(handle, "COMMIT;")
        } catch {
            try? exec(handle, "ROLLBACK;")
            throw error
        }
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? lastErrorMessage(handle)
            sqlite3_free(errPtr)
            throw FTSDatabaseError.executionFailed(msg)
        }
    }

    private func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw FTSDatabaseError.statementFailed(lastErrorMessage(handle))
        }
        return prepared
    }

    private func stepDone(_ handle: OpaquePointer, _ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw FTSDatabaseError.executionFailed(lastErrorMessage(handle))
        }
    }

    private func querySingleInt32(_ handle: OpaquePointer, sql: String) -> Int32? {
        guard let stmt = try? prepare(handle, sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(stmt, 0)
    }

    private func lastErrorMessage(_ handle: OpaquePointer) -> String {
        sqlite3_errmsg(handle).map { String(cString: $0) } ?? "SQLite error"
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transientDestructor)
    }

    private func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), Self.transientDestructor)
        }
    }

    private func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    private func columnOptionalString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private func columnOptionalInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(stmt, index))
    }

    private func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let byteCount = Int(sqlite3_column_bytes(stmt, index))
        guard byteCount > 0, let ptr = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: ptr, count: byteCount)
    }
}

enum FTSDatabaseError: LocalizedError {
    case openFailed
    case statementFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed:
            return String(localized: "无法打开全文检索索引库。")
        case .statementFailed(let detail):
            return String(localized: "索引查询准备失败：\(detail)")
        case .executionFailed(let detail):
            return String(localized: "索引操作失败：\(detail)")
        }
    }
}
