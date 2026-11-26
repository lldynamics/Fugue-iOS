import Foundation
import SwiftData

struct ClaimCheckRecord: Codable, Equatable, Identifiable, Sendable {
    struct Statement: Codable, Equatable, Sendable {
        let text: String
        let verdict: String
        let quote: String?
        let citation: ReadingCitation?
    }

    var id = UUID()
    var date = Date()
    let checkedText: String
    let model: String
    let statements: [Statement]

    static func merging(_ local: [Self]?, _ incoming: [Self]?) -> [Self]? {
        var ids = Set<UUID>()
        let combined = ((local ?? []) + (incoming ?? [])).filter { ids.insert($0.id).inserted }
        return combined.isEmpty ? nil : combined.sorted { $0.date > $1.date }
    }

    /// The newest reply has no revision ID until another version is selected or generated.
    struct Version: Equatable {
        let content: String
        let revisionID: UUID?
        let revisionCount: Int
        let requestID: UUID?

        @MainActor init(_ message: ChatMessage) {
            let meta = message.assistanceMetadata
            content = message.content
            revisionID = meta.activeRevisionIndex.flatMap { meta.revisions.indices.contains($0) ? meta.revisions[$0].id : nil }
            revisionCount = meta.revisions.count
            requestID = message.latestRequest?.id
        }
    }

    @MainActor func save(to message: ChatMessage, version: Version) throws {
        guard let context = message.modelContext, !message.isDeleted, !message.isStreaming,
              Version(message) == version else { throw AppCompliance.RequestChanged() }
        let before = message.assistanceMetadata
        var meta = before
        meta.claimChecks = Self.merging(meta.claimChecks, [self])
        if let index = meta.activeRevisionIndex, meta.revisions.indices.contains(index) {
            meta.revisions[index].claimChecks = meta.claimChecks
        }
        let previousDate = message.conversation?.updatedAt
        message.assistanceMetadata = meta
        message.conversation?.updatedAt = .now
        do { try context.save() }
        catch {
            message.assistanceMetadata = before
            if let previousDate { message.conversation?.updatedAt = previousDate }
            throw error
        }
    }
}
