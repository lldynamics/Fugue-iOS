import Foundation
import SwiftData

@Model
final class ShelfReadingState {
    @Attribute(.unique) var bookID: UUID
    var conversationID: UUID?
    var chapter: Int
    var paragraph: Int

    init(bookID: UUID) {
        self.bookID = bookID
        chapter = 0
        paragraph = 0
    }

    struct Position: Codable, Equatable {
        let bookID: UUID
        let conversationID: UUID?
        let chapter: Int
        let paragraph: Int
    }

    var position: Position { Position(bookID: bookID, conversationID: conversationID, chapter: chapter, paragraph: paragraph) }

    static func find(_ id: UUID, in context: ModelContext) throws -> ShelfReadingState? {
        try context.fetch(FetchDescriptor<ShelfReadingState>(predicate: #Predicate<ShelfReadingState> { $0.bookID == id })).first
    }
}

extension Conversation {
    func isCompanion(for bookID: UUID) -> Bool {
        guard !isGroupMode, !isArenaMode, activeBookFriend == nil, assistanceSettings.privatePersona == nil else { return false }
        if let id = assistanceSettings.companionBookID { return id == bookID }
        // Identify the earlier shelf action without collecting ordinary chats that also reference this book.
        return assistantID == nil && assistantEmoji == "📚" && assistanceSettings.knowledgeVolumeIDs == [bookID]
    }
}

struct BookFriendHistory: Identifiable {
    struct ID: Hashable { let book: UUID; let name: String }
    let id: ID
    let friend: BookFriend
    var chats: [Conversation]

    static func grouped(_ conversations: [Conversation]) -> [Self] {
        var positions: [ID: Int] = [:]
        var rows: [Self] = []
        for chat in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard let friend = chat.activeBookFriend else { continue }
            let key = ID(book: friend.bookID, name: friend.name.lowercased())
            if let index = positions[key] { rows[index].chats.append(chat) }
            else {
                positions[key] = rows.count
                rows.append(Self(id: key, friend: friend, chats: [chat]))
            }
        }
        return rows
    }
}

extension BookLibrary {
    static func readingState(for book: BookVolume, companionID: UUID, in context: ModelContext) throws -> ShelfReadingState? {
        guard PersistenceController.canCommitUserData(in: context),
              let chat = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == companionID })).first,
              chat.isCompanion(for: book.id) else { return nil }
        let state = try ShelfReadingState.find(book.id, in: context) ?? ShelfReadingState(bookID: book.id)
        if state.conversationID != companionID {
            let previous = state.conversationID
            let isNew = state.modelContext == nil
            if isNew { context.insert(state) }
            state.conversationID = companionID
            do { try context.save() } catch {
                if isNew { context.delete(state) } else { state.conversationID = previous }
                throw error
            }
        }
        return state
    }

    static func companion(for book: BookVolume, newDiscussion: Bool = false, target: ResolvedModelTarget?, in context: ModelContext) throws -> Conversation {
        guard PersistenceController.canCommitUserData(in: context) else { throw BookImportError.cannotSave }
        let state = try ShelfReadingState.find(book.id, in: context) ?? ShelfReadingState(bookID: book.id)
        let chats = try context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        let candidates = newDiscussion ? [] : chats.filter { $0.isCompanion(for: book.id) }
        let chat = candidates.first { $0.id == state.conversationID } ?? candidates.first ??
            Conversation(title: String(localized: "《\(book.title)》伴读"), assistantEmoji: "📚", primaryTarget: target)
        try context.save()
        do {
            if chat.modelContext == nil {
                context.insert(chat)
                chat.assistanceSettings.knowledgeVolumeIDs = [book.id]
            }
            if state.modelContext == nil { context.insert(state) }
            chat.assistanceSettings.companionBookID = book.id
            state.conversationID = chat.id
            try context.save()
        } catch { context.rollback(); throw error }
        return chat
    }
}
