import Foundation
import Observation

struct ChatDraft: Codable {
    var text = ""
    var attachments: [MessageAttachment] = []
}

@MainActor
final class ChatDraftStore {
    static let shared = ChatDraftStore(directory: URL.applicationSupportDirectory.appendingPathComponent("Drafts"))
    private let directory: URL
    // Keep failed writes in memory for retry, but do not retain every saved attachment forever.
    private var unsaved: [UUID: ChatDraft] = [:]
    private class WeakState { weak var value: ChatDraftState?; init(_ value: ChatDraftState) { self.value = value } }
    private var states: [UUID: WeakState] = [:]

    init(directory: URL) { self.directory = directory }

    func state(for id: UUID) -> ChatDraftState {
        if let state = states[id]?.value { return state }
        states = states.filter { $0.value.value != nil }
        let state = ChatDraftState(id: id, store: self)
        states[id] = WeakState(state)
        state.load()
        return state
    }

    func load(_ id: UUID) throws -> ChatDraft {
        if let draft = unsaved[id] { return draft }
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return ChatDraft() }
        return try JSONDecoder().decode(ChatDraft.self, from: Data(contentsOf: url))
    }

    func save(_ draft: ChatDraft, for id: UUID) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(id)
            if draft.text.isEmpty && draft.attachments.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try JSONEncoder().encode(draft).write(to: url, options: [.atomic, .completeFileProtection])
            }
            unsaved[id] = nil
        } catch {
            unsaved[id] = draft
            throw error
        }
    }

    func remove(_ id: UUID) throws {
        // Late attachment completions must never recreate a deleted conversation's draft.
        states[id]?.value?.invalidate()
        states[id] = nil
        unsaved[id] = nil
        let url = fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

/// Shared by every presentation and in-flight attachment task for one conversation.
@Observable @MainActor
final class ChatDraftState {
    var text = ""
    var attachments: [MessageAttachment] = []
    var processingAttachments = 0
    var attachmentError: String?
    var persistenceError: String?
    private(set) var isLoaded = false
    private(set) var isDeleted = false
    private let id: UUID
    private let store: ChatDraftStore

    init(id: UUID, store: ChatDraftStore) { self.id = id; self.store = store }

    var canSend: Bool {
        isLoaded && !isDeleted && processingAttachments == 0
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func load() {
        guard !isLoaded, !isDeleted else { return }
        do {
            let draft = try store.load(id)
            text = draft.text
            attachments = draft.attachments
            isLoaded = true
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    func save() {
        guard isLoaded, !isDeleted else { return }
        do {
            try store.save(.init(text: text, attachments: attachments), for: id)
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    func append(_ attachment: MessageAttachment) {
        guard isLoaded, !isDeleted else { return }
        do {
            try AttachmentProcessor.validate(attachments + [attachment])
            attachments.append(attachment)
            // The screen might already have disappeared while the file was being processed.
            save()
        } catch { attachmentError = error.localizedDescription }
    }

    fileprivate func invalidate() {
        isDeleted = true
        text = ""
        attachments = []
    }
}
