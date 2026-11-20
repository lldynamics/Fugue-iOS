import Foundation
import Observation
import UIKit

struct ChatDraft: Codable {
    var text = ""
    var attachments: [MessageAttachment] = []
    var quotedText: String?

    init(text: String = "", attachments: [MessageAttachment] = [], quotedText: String? = nil) {
        self.text = text
        self.attachments = attachments
        self.quotedText = quotedText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        quotedText = try c.decodeIfPresent(String.self, forKey: .quotedText)
    }
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
        if let state = states[id]?.value {
            if !state.isLoaded {
                state.load()
            }
            return state
        }
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
            if draft.text.isEmpty && draft.attachments.isEmpty && draft.quotedText == nil {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try JSONEncoder().encode(draft).write(
                    to: url,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }
            unsaved[id] = nil
        } catch {
            unsaved[id] = draft
            throw error
        }
    }

    /// Quarantines a damaged draft file alongside `Drafts/` without silent data loss, allowing
    /// the user to unblock sending in the conversation.
    func quarantineAndReset(_ id: UUID) throws {
        unsaved[id] = nil
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let archived = directory.appendingPathComponent("\(id.uuidString).corrupt-\(stamp).json")
        try FileManager.default.moveItem(at: url, to: archived)
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
    var quotedText: String?
    var processingAttachments = 0
    var attachmentError: String?
    var persistenceError: String?
    private(set) var isLoaded = false
    private(set) var isDeleted = false
    private let id: UUID
    private let store: ChatDraftStore
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?

    init(id: UUID, store: ChatDraftStore) {
        self.id = id
        self.store = store
        self.unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.load()
            }
        }
    }

    deinit {
        if let unlockObserver {
            NotificationCenter.default.removeObserver(unlockObserver)
        }
    }

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
            quotedText = draft.quotedText
            isLoaded = true
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    /// Archives an unreadable draft file when the user explicitly chooses to reset it.
    func discardUnreadableDraft() {
        guard !isDeleted else { return }
        do {
            try store.quarantineAndReset(id)
            text = ""
            attachments = []
            quotedText = nil
            isLoaded = true
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    func save() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isLoaded, !isDeleted else { return }
        do {
            try store.save(.init(text: text, attachments: attachments, quotedText: quotedText), for: id)
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    func scheduleAutosave(delayMilliseconds: Int = 450) {
        autosaveTask?.cancel()
        guard isLoaded, !isDeleted else { return }
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self, self.isLoaded, !self.isDeleted else { return }
            self.save()
        }
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
        autosaveTask?.cancel()
        autosaveTask = nil
        isDeleted = true
        text = ""
        attachments = []
        quotedText = nil
    }
}
