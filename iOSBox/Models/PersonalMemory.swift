import Foundation
import SwiftData

/// Only facts and preferences explicitly entered by the user. No automatic extraction.
@Model
final class PersonalMemory {
    @Attribute(.unique) var id: UUID
    var content: String
    var isEnabled: Bool
    var createdAt: Date

    init(id: UUID = UUID(), content: String, isEnabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    static let maximumCount = 60
    static let maximumCharacters = 1_000

    struct Snapshot: Codable {
        var id: UUID
        var content: String
        var isEnabled: Bool
        var createdAt: Date
    }

    var snapshot: Snapshot { Snapshot(id: id, content: content, isEnabled: isEnabled, createdAt: createdAt) }

    @MainActor
    static func prompt(in context: ModelContext) throws -> (text: String, count: Int) {
        let memories = try context.fetch(FetchDescriptor<PersonalMemory>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter(\.isEnabled)
            .prefix(maximumCount)
            .map { String($0.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumCharacters)) }
            .filter { !$0.isEmpty }
        guard !memories.isEmpty else { return ("", 0) }
        let json = String(decoding: try JSONEncoder().encode(memories), as: UTF8.self)
        return ("User-maintained background and preferences (JSON). Use when relevant; the current user request takes precedence.\n" + json, memories.count)
    }
}
