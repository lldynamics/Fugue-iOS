import Foundation
import Observation

@MainActor
@Observable
final class FlashcardStore {
    static let shared = FlashcardStore()

    private(set) var cards: [StudyFlashcard] = []
    @ObservationIgnored private let fileURL: URL?

    enum StorageIssue: LocalizedError {
        case unreadable, damaged, writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "无法读取闪卡库。请解锁设备并重试。")
            case .damaged: String(localized: "闪卡库文件损坏，原文件已保留。可在学习卡包中保留副本并重建卡库。")
            case .writeFailed: String(localized: "闪卡未能保存。请检查设备存储空间后重试。")
            }
        }
    }
    private(set) var loadIssue: StorageIssue?

    init(fileURL: URL? = FlashcardStore.defaultFileURL()) {
        self.fileURL = fileURL
        reload()
    }

    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("study-flashcards.json")
    }

    func reload() {
        guard let fileURL else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            cards = try Self.makeDecoder().decode([StudyFlashcard].self, from: data)
            loadIssue = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            cards = []
            loadIssue = nil
        } catch is DecodingError {
            loadIssue = .damaged
        } catch {
            loadIssue = .unreadable
        }
    }

    func preserveDamagedLibrary() throws {
        reload()
        guard let fileURL, loadIssue == .damaged else {
            if let loadIssue { throw loadIssue }
            return
        }
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent("study-flashcards-damaged-\(UUID()).json")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        cards = []
        loadIssue = nil
    }

    func readableCards() throws -> [StudyFlashcard] {
        if loadIssue != nil { reload() }
        if let loadIssue { throw loadIssue }
        return cards
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var deckNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for card in cards {
            let trimmed = card.deckName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? String(localized: "默认卡组") : trimmed
            if seen.insert(name).inserted {
                result.append(name)
            }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var masteredCount: Int {
        cards.filter(\.isMastered).count
    }

    func dueCards(inDeck deck: String? = nil, at date: Date = Date()) -> [StudyFlashcard] {
        cards
            .filter { card in
                if let deck, !deck.isEmpty, card.deckName != deck {
                    return false
                }
                return card.isDue(at: date)
            }
            .sorted { $0.dueAt < $1.dueAt }
    }

    func filteredCards(deck: String? = nil, query: String = "") -> [StudyFlashcard] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cards.filter { card in
            if let deck, !deck.isEmpty, card.deckName != deck {
                return false
            }
            guard !q.isEmpty else { return true }
            return card.front.lowercased().contains(q)
                || card.back.lowercased().contains(q)
                || card.deckName.lowercased().contains(q)
        }
    }

    func contains(front: String, deckName: String? = nil) -> Bool {
        let normalizedFront = front.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedFront.isEmpty else { return false }
        return cards.contains { card in
            if let deckName, card.deckName != deckName {
                return false
            }
            return card.front.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedFront
        }
    }

    @discardableResult
    func addCard(
        deckName: String,
        front: String,
        back: String,
        hint: String? = nil,
        sourceConversationID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        now: Date = Date()
    ) throws -> StudyFlashcard? {
        try change { cards in
            Self.upsertCard(in: &cards, deckName: deckName, front: front, back: back, hint: hint,
                            sourceConversationID: sourceConversationID, sourceMessageID: sourceMessageID, now: now)
        }
    }

    private static func upsertCard(
        in cards: inout [StudyFlashcard],
        deckName: String,
        front: String,
        back: String,
        hint: String?,
        sourceConversationID: UUID?,
        sourceMessageID: UUID?,
        now: Date
    ) -> StudyFlashcard? {
        let cleanFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBack = back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFront.isEmpty, !cleanBack.isEmpty else { return nil }
        let cleanDeck = Self.normalizeDeckName(deckName)
        let cleanHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingIdx = cards.firstIndex(where: {
            $0.deckName == cleanDeck && $0.front.caseInsensitiveCompare(cleanFront) == .orderedSame
        }) {
            cards[existingIdx].back = String(cleanBack.prefix(2000))
            if let cleanHint, !cleanHint.isEmpty {
                cards[existingIdx].hint = String(cleanHint.prefix(300))
            }
            return cards[existingIdx]
        }

        let created = StudyFlashcard(
            deckName: cleanDeck,
            front: String(cleanFront.prefix(600)),
            back: String(cleanBack.prefix(2000)),
            hint: (cleanHint?.isEmpty == false) ? String(cleanHint!.prefix(300)) : nil,
            sourceConversationID: sourceConversationID,
            sourceMessageID: sourceMessageID,
            dueAt: now,
            createdAt: now
        )
        cards.insert(created, at: 0)
        return created
    }

    @discardableResult
    func addDrafts(
        _ drafts: [StudyCardDraft],
        deckName: String,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        now: Date = Date()
    ) throws -> Int {
        try change { cards in
            let before = cards.count
            for draft in drafts.reversed() {
                _ = Self.upsertCard(in: &cards, deckName: deckName, front: draft.front, back: draft.back,
                                    hint: draft.hint, sourceConversationID: conversationID,
                                    sourceMessageID: messageID, now: now)
            }
            return cards.count - before
        }
    }

    /// Merges cards restored from a backup archive without overwriting existing local cards or SM-2 history.
    @discardableResult
    func mergeImported(_ incoming: [StudyFlashcard]) throws -> Int {
        try change { cards in
            guard !incoming.isEmpty else { return 0 }
            var existingIDs = Set(cards.map(\.id))
            var added = 0
            for card in incoming {
                let cleanFront = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanBack = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanFront.isEmpty, !cleanBack.isEmpty else { continue }
                guard existingIDs.insert(card.id).inserted else { continue }
                var normalized = card
                normalized.deckName = Self.normalizeDeckName(card.deckName)
                normalized.front = String(cleanFront.prefix(600))
                normalized.back = String(cleanBack.prefix(2000))
                normalized.easeFactor = card.easeFactor.isFinite ? min(max(card.easeFactor, 1.3), 5.0) : 2.5
                normalized.intervalDays = card.intervalDays.isFinite ? min(max(card.intervalDays, 0), 3650) : 0
                normalized.repetitions = max(0, card.repetitions)
                normalized.lapses = max(0, card.lapses)
                if let hint = card.hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                    normalized.hint = String(hint.prefix(300))
                } else {
                    normalized.hint = nil
                }
                cards.append(normalized)
                added += 1
            }
            if added > 0 {
                cards.sort { $0.createdAt > $1.createdAt }
            }
            return added
        }
    }

    func updateCard(id: UUID, deckName: String, front: String, back: String, hint: String?) throws {
        try change { cards in
            guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
            let cleanFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBack = back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanFront.isEmpty, !cleanBack.isEmpty else { return }
            let cleanHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
            cards[idx].deckName = Self.normalizeDeckName(deckName)
            cards[idx].front = String(cleanFront.prefix(600))
            cards[idx].back = String(cleanBack.prefix(2000))
            cards[idx].hint = (cleanHint?.isEmpty == false) ? String(cleanHint!.prefix(300)) : nil
        }
    }

    func recordReview(cardID: UUID, rating: StudyReviewRating, now: Date = Date()) throws {
        try change { cards in
            guard let idx = cards.firstIndex(where: { $0.id == cardID }) else { return }
            cards[idx] = cards[idx].applying(rating, now: now)
        }
    }

    func deleteCard(id: UUID) throws {
        try change { cards in
            cards.removeAll { $0.id == id }
        }
    }

    func deleteDeck(_ deckName: String) throws {
        try change { cards in
            cards.removeAll { $0.deckName == deckName }
        }
    }

    /// Exports cards as Anki-compatible UTF-8 Tab-Separated Values (`.tsv`).
    func exportAnkiTSV(deckFilter: String? = nil) -> String {
        let selected = filteredCards(deck: deckFilter)
        var lines: [String] = [
            "#separator:tab",
            "#html:true",
            "#tags column:3"
        ]
        for card in selected {
            let front = Self.escapeTSVField(card.front)
            var backBody = Self.escapeTSVField(card.back)
            if let hint = card.hint, !hint.isEmpty {
                backBody += "<br><br><small>💡 " + Self.escapeTSVField(hint) + "</small>"
            }
            let tag = card.deckName
                .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
                .replacingOccurrences(of: "\t", with: "_")
            lines.append("\(front)\t\(backBody)\t\(tag)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func writeTemporaryTSVFile(_ content: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fugue-AnkiCards-\(formatter.string(from: Date())).tsv")
        try Data(content.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func normalizeDeckName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != String(localized: "新对话") else {
            return String(localized: "默认卡组")
        }
        return String(trimmed.prefix(60))
    }

    private static func escapeTSVField(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\t", with: "    ")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private func change<Result>(_ edit: (inout [StudyFlashcard]) -> Result) throws -> Result {
        var next = try readableCards()
        let result = edit(&next)
        guard next != cards else { return result }
        if let fileURL {
            do {
                let data = try Self.makeEncoder().encode(next)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw StorageIssue.writeFailed }
        }
        cards = next
        return result
    }
}
