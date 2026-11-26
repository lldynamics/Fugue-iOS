import Foundation
import Observation
import os
import UIKit

struct ChatDraft: Codable, Equatable {
    var text = ""
    var attachments: [MessageAttachment] = []
    var quotedText: String?
    var pickedMentions: [PickedGroupMention] = []

    init(text: String = "", attachments: [MessageAttachment] = [], quotedText: String? = nil,
         pickedMentions: [PickedGroupMention] = []) {
        self.text = text
        self.attachments = attachments
        self.quotedText = quotedText
        self.pickedMentions = pickedMentions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        quotedText = try c.decodeIfPresent(String.self, forKey: .quotedText)
        pickedMentions = try c.decodeIfPresent([PickedGroupMention].self, forKey: .pickedMentions) ?? []
    }
}

/// A list row only needs the first line and attachment count, even for older drafts with embedded files.
enum ChatDraftPreview: Equatable, Decodable, Sendable {
    case empty, text(String), attachments(Int), quotation(String)

    private enum CodingKeys: String, CodingKey { case text, attachments, quotedText }

    init(text: String, attachmentCount: Int, quotedText: String?) {
        func firstLine(_ value: String) -> String? {
            let trimmed = value.drop(while: \.isWhitespace)
            let line = trimmed.prefix(while: { !$0.isNewline }).prefix(140)
            return line.isEmpty ? nil : String(line).trimmingCharacters(in: .whitespaces)
        }
        if let line = firstLine(text) { self = .text(line) }
        else if attachmentCount > 0 { self = .attachments(attachmentCount) }
        else if let quotedText, let line = firstLine(quotedText) { self = .quotation(line) }
        else { self = .empty }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let count: Int
        if values.contains(.attachments), try !values.decodeNil(forKey: .attachments) {
            count = try values.nestedUnkeyedContainer(forKey: .attachments).count ?? 0
        } else { count = 0 }
        self.init(text: try values.decodeIfPresent(String.self, forKey: .text) ?? "", attachmentCount: count,
                  quotedText: try values.decodeIfPresent(String.self, forKey: .quotedText))
    }

    var summary: String? {
        switch self {
        case .empty: nil
        case .text(let line): line
        case .attachments(1): String(localized: "1 个附件")
        case .attachments(let count): String(localized: "\(count) 个附件")
        case .quotation(let line): String(localized: "引用：\(line)")
        }
    }
}

@Observable @MainActor
final class ChatDraftStore {
    static let shared: ChatDraftStore = {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-test-workspaces") || arguments.contains("-ui-test-model-picker") {
            return ChatDraftStore(directory: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        }
        #endif
        return ChatDraftStore(directory: URL.applicationSupportDirectory.appendingPathComponent("Drafts"))
    }()
    private let directory: URL
    private nonisolated let ioQueue = DispatchQueue(label: "com.iosbox.chatDraftStore.io", qos: .userInitiated)
    private nonisolated let writeGenerations = OSAllocatedUnfairLock(initialState: [UUID: UInt64]())
    // Keep failed or in-flight async writes in memory so reads immediately see the latest state.
    @ObservationIgnored private var unsaved: [UUID: ChatDraft] = [:]
    private class WeakState { weak var value: ChatDraftState?; init(_ value: ChatDraftState) { self.value = value } }
    @ObservationIgnored private var states: [UUID: WeakState] = [:]
    private(set) var previews: [UUID: ChatDraftPreview] = [:]
    private(set) var draftDates: [UUID: Date] = [:]

    init(directory: URL) { self.directory = directory }

    private nonisolated func nextGeneration(for id: UUID) -> UInt64 {
        writeGenerations.withLock { map in
            let next = (map[id] ?? 0) &+ 1
            map[id] = next
            return next
        }
    }

    private nonisolated func isCurrentGeneration(_ generation: UInt64, for id: UUID) -> Bool {
        writeGenerations.withLock { $0[id] == generation }
    }

    private nonisolated static func writeDraftToDisk(_ draft: ChatDraft, directory: URL, url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if draft.text.isEmpty && draft.attachments.isEmpty && draft.quotedText == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } else {
            try JSONEncoder().encode(draft).write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
    }

    fileprivate func hasPendingWrite(for id: UUID) -> Bool { unsaved[id] != nil }

    /// Existing drafts have no timestamp in their JSON. Read the dates of actual draft files,
    /// so an unfinished reply in an old conversation can still be the first one in the inbox.
    func loadInboxPreviews() async {
        let directory = directory
        let known = previews
        let entries = await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
            )) ?? []
            return files.compactMap { url -> (UUID, Date, ChatDraftPreview)? in
                guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      let preview = known[id] ?? Self.readPreview(at: url), preview != .empty else { return nil }
                return (id, date, preview)
            }
        }.value
        guard !Task.isCancelled else { return }
        for (id, date, preview) in entries where previews[id] != .empty && draftDates[id] == nil {
            previews[id] = preview
            draftDates[id] = date
        }
    }

    private nonisolated static func readPreview(at url: URL) -> ChatDraftPreview? {
        do {
            return try JSONDecoder().decode(ChatDraftPreview.self, from: Data(contentsOf: url, options: .mappedIfSafe))
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch { return nil }
    }

    func loadPreview(for id: UUID) async {
        guard previews[id] == nil else { return }
        let url = fileURL(id)
        let preview = await Task.detached(priority: .utility) { () -> ChatDraftPreview? in
            Self.readPreview(at: url)
        }.value
        // A save or deletion on the main actor takes precedence over an older disk read.
        if !Task.isCancelled, previews[id] == nil, let preview { previews[id] = preview }
    }

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
        let preview = ChatDraftPreview(text: draft.text, attachmentCount: draft.attachments.count, quotedText: draft.quotedText)
        if previews[id] != preview { previews[id] = preview }
        draftDates[id] = preview == .empty ? nil : Date()
        _ = nextGeneration(for: id)
        let dir = directory
        let url = fileURL(id)
        do {
            try ioQueue.sync {
                try Self.writeDraftToDisk(draft, directory: dir, url: url)
            }
            unsaved[id] = nil
        } catch {
            unsaved[id] = draft
            throw error
        }
    }

    /// Encodes and writes the draft on a serial background I/O queue so large image/PDF drafts
    /// never block `@MainActor` during typing autosave, while preserving strict linearizability
    /// against synchronous `save`, `remove`, and `load` calls.
    func saveAsync(_ draft: ChatDraft, for id: UUID) async throws {
        let preview = ChatDraftPreview(text: draft.text, attachmentCount: draft.attachments.count, quotedText: draft.quotedText)
        if previews[id] != preview { previews[id] = preview }
        draftDates[id] = preview == .empty ? nil : Date()
        unsaved[id] = draft
        let generation = nextGeneration(for: id)
        let dir = directory
        let url = fileURL(id)
        let generations = writeGenerations

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ioQueue.async {
                    let isCurrent = generations.withLock { $0[id] == generation }
                    guard isCurrent else {
                        continuation.resume(returning: ())
                        return
                    }
                    do {
                        try Self.writeDraftToDisk(draft, directory: dir, url: url)
                        continuation.resume(returning: ())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            if isCurrentGeneration(generation, for: id) {
                unsaved[id] = nil
            }
        } catch {
            // If a newer save/remove already superseded this write, do not report a stale error.
            guard isCurrentGeneration(generation, for: id) else { return }
            unsaved[id] = draft
            throw error
        }
    }

    /// Quarantines a damaged draft file alongside `Drafts/` without silent data loss, allowing
    /// the user to unblock sending in the conversation.
    func quarantineAndReset(_ id: UUID) throws {
        _ = nextGeneration(for: id)
        let dir = directory
        let url = fileURL(id)
        try ioQueue.sync {
            if FileManager.default.fileExists(atPath: url.path) {
                let stamp = Int(Date().timeIntervalSince1970)
                let archived = dir.appendingPathComponent("\(id.uuidString).corrupt-\(stamp).json")
                try FileManager.default.moveItem(at: url, to: archived)
            }
        }
        unsaved[id] = nil
        previews[id] = .empty
        draftDates[id] = nil
    }

    func remove(_ id: UUID) throws {
        // Late attachment completions must never recreate a deleted conversation's draft.
        states[id]?.value?.invalidate()
        states[id] = nil
        unsaved[id] = nil
        _ = nextGeneration(for: id)
        let url = fileURL(id)
        try ioQueue.sync {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        previews[id] = .empty
        draftDates[id] = nil
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

/// Shared by every presentation and in-flight attachment task for one conversation.
@Observable @MainActor
final class ChatDraftState {
    var text = "" {
        didSet { pickedMentions = PickedGroupMention.updating(pickedMentions, from: oldValue, to: text) }
    }
    private(set) var pickedMentions: [PickedGroupMention] = []
    var attachments: [MessageAttachment] = []
    var quotedText: String?
    var processingAttachments = 0
    var attachmentError: String?
    var persistenceError: String?
    private(set) var savedText = ""
    private(set) var isLoaded = false
    private(set) var isDeleted = false
    private let id: UUID
    private let store: ChatDraftStore
    @ObservationIgnored private var lastSavedDraft: ChatDraft?
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
            lastSavedDraft = draft
            text = draft.text
            pickedMentions = draft.pickedMentions
            savedText = draft.text
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
            lastSavedDraft = ChatDraft()
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
        let snapshot = ChatDraft(text: text, attachments: attachments, quotedText: quotedText, pickedMentions: pickedMentions)
        guard snapshot != lastSavedDraft || persistenceError != nil || store.hasPendingWrite(for: id) else { return }
        do {
            try store.save(snapshot, for: id)
            lastSavedDraft = snapshot
            savedText = text
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    func saveAsync() async {
        guard isLoaded, !isDeleted else { return }
        let snapshot = ChatDraft(text: text, attachments: attachments, quotedText: quotedText, pickedMentions: pickedMentions)
        guard snapshot != lastSavedDraft || persistenceError != nil || store.hasPendingWrite(for: id) else { return }
        do {
            try await store.saveAsync(snapshot, for: id)
            guard !isDeleted else { return }
            lastSavedDraft = snapshot
            savedText = snapshot.text
            persistenceError = nil
        } catch {
            guard !isDeleted else { return }
            persistenceError = error.localizedDescription
        }
    }

    func insertGroupMention(_ token: String, memberID: UUID? = nil) {
        var prefix = text
        if prefix.hasSuffix("@") {
            prefix.removeLast()
        }
        if let last = prefix.last, !last.isWhitespace {
            prefix.append(" ")
        }
        text = prefix + token + " "
        pickedMentions.append(.init(offset: prefix.utf16.count, token: token, memberID: memberID))
        save()
    }

    func scheduleAutosave(delayMilliseconds: Int = 450) {
        autosaveTask?.cancel()
        guard isLoaded, !isDeleted else { return }
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, let self, self.isLoaded, !self.isDeleted else { return }
            await self.saveAsync()
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
        lastSavedDraft = nil
        text = ""
        attachments = []
        quotedText = nil
    }
}
