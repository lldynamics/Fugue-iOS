import Foundation
import SwiftData

@Model
final class ReadingAnnotation {
    @Attribute(.unique) var id: UUID
    var volumeID: UUID
    var bookTitle: String
    var chapterTitle: String
    var chapterIndex: Int
    var utf16Offset: Int
    var excerpt: String
    var note: String
    var updatedAt: Date

    struct Snapshot: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let volumeID: UUID
        let bookTitle: String
        let chapterTitle: String
        let chapterIndex: Int
        let utf16Offset: Int
        let excerpt: String
        let note: String
        let updatedAt: Date
        var preciseUpdatedAt: Double? = nil
        var effectiveUpdatedAt: Date {
            guard let value = preciseUpdatedAt, value.isFinite else { return updatedAt }
            return Date(timeIntervalSince1970: value)
        }

        var isValid: Bool {
            ReadingCitation.validLocation(index: chapterIndex, offset: utf16Offset) != nil &&
            !bookTitle.isEmpty && bookTitle.count <= 300 && !chapterTitle.isEmpty && chapterTitle.count <= 300 &&
            !excerpt.isEmpty && excerpt.count <= 8_000 && note.count <= 16_000
        }

        var citation: ReadingCitation {
            ReadingCitation(KnowledgePassage(id: 1, volumeID: volumeID, documentTitle: bookTitle,
                sectionTitle: chapterTitle, excerpt: excerpt, chapterIndex: chapterIndex, utf16Offset: utf16Offset))
        }
    }

    init(_ snapshot: Snapshot) {
        id = snapshot.id
        volumeID = snapshot.volumeID
        bookTitle = snapshot.bookTitle
        chapterTitle = snapshot.chapterTitle
        chapterIndex = snapshot.chapterIndex
        utf16Offset = snapshot.utf16Offset
        excerpt = snapshot.excerpt
        note = snapshot.note
        updatedAt = snapshot.effectiveUpdatedAt
    }

    var snapshot: Snapshot {
        Snapshot(id: id, volumeID: volumeID, bookTitle: bookTitle, chapterTitle: chapterTitle, chapterIndex: chapterIndex,
                 utf16Offset: utf16Offset, excerpt: excerpt, note: note, updatedAt: updatedAt, preciseUpdatedAt: updatedAt.timeIntervalSince1970)
    }

    func apply(_ snapshot: Snapshot) {
        volumeID = snapshot.volumeID
        bookTitle = snapshot.bookTitle
        chapterTitle = snapshot.chapterTitle
        chapterIndex = snapshot.chapterIndex
        utf16Offset = snapshot.utf16Offset
        excerpt = snapshot.excerpt
        note = snapshot.note
        updatedAt = snapshot.effectiveUpdatedAt
    }

    static func markdown(_ entries: [Snapshot]) -> String {
        entries.map { entry in
            var lines = ["## 《\(entry.bookTitle)》 · \(entry.chapterTitle)", "",
                         entry.excerpt.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")]
            if !entry.note.isEmpty { lines += ["", entry.note] }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n---\n\n")
    }
}
