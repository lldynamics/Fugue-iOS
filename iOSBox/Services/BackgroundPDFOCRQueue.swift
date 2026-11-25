import Foundation
import Observation
import PDFKit
import SwiftData

struct PDFOCRJobProgress: Identifiable, Equatable, Sendable {
    let id: UUID
    let bookTitle: String
    var completedPages: Int
    var totalPages: Int
    var recognizedNewPages: Int
    var isFinished: Bool = false
    var errorMessage: String? = nil

    var fractionCompleted: Double {
        guard totalPages > 0 else { return 1.0 }
        return min(max(Double(completedPages) / Double(totalPages), 0), 1)
    }
}

/// Runs offline Vision OCR on remaining scanned PDF pages in the background without blocking import,
/// removing the old 120-page ceiling while keeping memory strictly bounded via batched autoreleasepools.
@MainActor
@Observable
final class BackgroundPDFOCRQueue {
    static let shared = BackgroundPDFOCRQueue()

    private(set) var activeJobs: [UUID: PDFOCRJobProgress] = [:]
    @ObservationIgnored private var runningTasks: [UUID: Task<Void, Never>] = [:]

    var orderedJobs: [PDFOCRJobProgress] {
        activeJobs.values.sorted { $0.bookTitle < $1.bookTitle }
    }

    func enqueue(
        bookID: UUID,
        bookTitle: String,
        pdfData: Data,
        remainingPageIndices: [Int],
        totalPDFPages: Int,
        modelContext: ModelContext,
        batchSize: Int = 8
    ) {
        guard !remainingPageIndices.isEmpty else { return }
        cancel(bookID: bookID)

        let alreadyDone = max(0, totalPDFPages - remainingPageIndices.count)
        activeJobs[bookID] = PDFOCRJobProgress(
            id: bookID,
            bookTitle: bookTitle,
            completedPages: alreadyDone,
            totalPages: max(totalPDFPages, remainingPageIndices.count),
            recognizedNewPages: 0
        )

        let safeBatch = max(1, batchSize)
        let container = modelContext.container

        let task = Task { [weak self] in
            var pendingIndex = 0
            while pendingIndex < remainingPageIndices.count {
                if Task.isCancelled { break }
                let end = min(pendingIndex + safeBatch, remainingPageIndices.count)
                let slice = Array(remainingPageIndices[pendingIndex..<end])
                pendingIndex = end

                let recognized: [BookChapter] = await Task.detached(priority: .utility) {
                    guard let pdf = PDFDocument(data: pdfData) else { return [] }
                    var found: [BookChapter] = []
                    for pageIndex in slice {
                        if Task.isCancelled { break }
                        let text: String = autoreleasepool {
                            guard let page = pdf.page(at: pageIndex) else { return "" }
                            return PDFOCRService.recognizeText(on: page)
                        }
                        if !text.isEmpty {
                            found.append(BookChapter(
                                title: String(localized: "第 \(pageIndex + 1) 页"),
                                text: text
                            ))
                        }
                    }
                    return found
                }.value

                if Task.isCancelled { break }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !recognized.isEmpty {
                        self.mergeIntoStoredBook(bookID: bookID, additions: recognized, container: container)
                    }
                    if var progress = self.activeJobs[bookID] {
                        progress.completedPages = min(progress.totalPages, progress.completedPages + slice.count)
                        progress.recognizedNewPages += recognized.count
                        self.activeJobs[bookID] = progress
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.runningTasks.removeValue(forKey: bookID)
                guard !Task.isCancelled else {
                    self.activeJobs.removeValue(forKey: bookID)
                    return
                }
                if var progress = self.activeJobs[bookID] {
                    progress.completedPages = progress.totalPages
                    progress.isFinished = true
                    self.activeJobs[bookID] = progress
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    if self?.activeJobs[bookID]?.isFinished == true {
                        self?.activeJobs.removeValue(forKey: bookID)
                    }
                }
            }
        }
        runningTasks[bookID] = task
    }

    func cancel(bookID: UUID) {
        runningTasks.removeValue(forKey: bookID)?.cancel()
        activeJobs.removeValue(forKey: bookID)
    }

    func dismissFinished(bookID: UUID) {
        if activeJobs[bookID]?.isFinished == true {
            activeJobs.removeValue(forKey: bookID)
        }
    }

    private func mergeIntoStoredBook(bookID: UUID, additions: [BookChapter], container: ModelContainer) {
        let ctx = ModelContext(container)
        guard let book = try? BookLibrary.find(bookID, in: ctx) else { return }
        guard let existing = try? JSONDecoder().decode([BookChapter].self, from: book.manuscript) else { return }
        let merged = Self.mergeChaptersInPageOrder(existing: existing, additions: additions)
        let manuscript = BookManuscript(title: book.title, chapters: merged)
        guard let encoded = try? manuscript.encoded() else { return }
        book.manuscript = encoded
        book.chapterTitles = merged.map(\.title)
        book.manuscriptByteCount = encoded.count
        try? ctx.save()
        Task {
            await ProjectKnowledgeSearch.shared.invalidate(volumeID: bookID)
            await BookReferenceSearch.shared.invalidate(bookID: bookID)
        }
    }

    /// Merges newly recognized PDF page chapters into existing chapters while maintaining ascending page order
    /// and avoiding duplicate page titles.
    nonisolated static func mergeChaptersInPageOrder(
        existing: [BookChapter],
        additions: [BookChapter]
    ) -> [BookChapter] {
        var byTitle: [String: BookChapter] = [:]
        var ordered: [BookChapter] = []
        for ch in existing {
            byTitle[ch.title] = ch
            ordered.append(ch)
        }
        for add in additions where byTitle[add.title] == nil {
            byTitle[add.title] = add
            ordered.append(add)
        }
        return ordered.sorted { lhs, rhs in
            let lNum = extractPageNumber(from: lhs.title) ?? Int.max
            let rNum = extractPageNumber(from: rhs.title) ?? Int.max
            if lNum != rNum { return lNum < rNum }
            return lhs.title < rhs.title
        }
    }

    nonisolated static func extractPageNumber(from title: String) -> Int? {
        var digits = ""
        for ch in title {
            if ch.isNumber && ch.isASCII {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            }
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}
