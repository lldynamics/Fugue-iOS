import Foundation
import Observation
import SwiftData

struct ProjectWorkspace: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var iconEmoji: String = "🗂️"
    var accentHex: String = "#4F46E5"
    var summary: String = ""
    var systemPrompt: String = ""
    var defaultTargetID: String? = nil
    var knowledgeVolumeIDs: [UUID] = []
    var memoryTags: [String] = []
    var folderTag: String = ""
    var enableThinking: Bool = true
    var enableAgentTools: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var effectiveFolderTag: String {
        let clean = folderTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanName.isEmpty ? "项目" : cleanName
    }

    static func normalizedTags(from raw: String) -> [String] {
        let parts = raw
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var unique: [String] = []
        for tag in parts {
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                unique.append(String(tag.prefix(24)))
            }
            if unique.count >= 8 { break }
        }
        return unique
    }
}

/// Sidecar JSON store for Project Workspaces unifying instructions, default model, knowledge docs,
/// scoped memories, and grouped conversations without altering frozen SwiftData schemas.
@MainActor
@Observable
final class ProjectWorkspaceStore {
    static let shared = ProjectWorkspaceStore()

    private(set) var workspaces: [ProjectWorkspace] = []
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = ProjectWorkspaceStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("Fugue", isDirectory: true)
            .appendingPathComponent("project-workspaces.json")
    }

    func upsert(_ workspace: ProjectWorkspace) {
        let cleanName = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        var normalized = workspace
        normalized.name = String(cleanName.prefix(60))
        normalized.iconEmoji = workspace.iconEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "🗂️"
            : workspace.iconEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.folderTag = normalized.effectiveFolderTag
        normalized.updatedAt = Date()

        if let idx = workspaces.firstIndex(where: { $0.id == normalized.id }) {
            workspaces[idx] = normalized
        } else {
            workspaces.insert(normalized, at: 0)
        }
        workspaces.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func delete(id: UUID) {
        let before = workspaces.count
        workspaces.removeAll { $0.id == id }
        if workspaces.count != before {
            persist()
        }
    }

    func workspace(forFolderTag folderTag: String?) -> ProjectWorkspace? {
        guard let clean = folderTag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clean.isEmpty else { return nil }
        return workspaces.first { $0.effectiveFolderTag.caseInsensitiveCompare(clean) == .orderedSame }
    }

    @discardableResult
    func createConversation(
        in workspace: ProjectWorkspace,
        providers: [ProviderConfig],
        context: ModelContext
    ) -> Conversation {
        let ready = ProviderConfig.readyTargets(in: providers)
        let preferredTarget = workspace.defaultTargetID.flatMap { targetID in
            ready.first { $0.id == targetID }
        } ?? AppPreferences.shared.initialTarget(from: ready)

        let chat = Conversation(
            title: String(localized: "\(workspace.name) · 新对话"),
            assistantEmoji: workspace.iconEmoji,
            systemPrompt: workspace.systemPrompt,
            enableThinking: workspace.enableThinking,
            primaryTarget: preferredTarget,
            arenaTargets: Array(ready.prefix(2))
        )
        chat.setFolderTag(workspace.effectiveFolderTag)
        var settings = chat.assistanceSettings
        settings.knowledgeVolumeIDs = workspace.knowledgeVolumeIDs
        settings.enableAgentTools = workspace.enableAgentTools
        settings.usePersonalMemory = true
        chat.assistanceSettings = settings

        context.insert(chat)
        try? context.save()
        return chat
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ProjectWorkspace].self, from: data) else {
            return
        }
        workspaces = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(workspaces) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Sidecar JSON mapping `PersonalMemory.id` to optional scope tags (e.g. `工程`, `写作`).
/// Untagged memories remain global across all conversations and projects.
@MainActor
@Observable
final class MemoryScopeStore {
    static let shared = MemoryScopeStore()

    private(set) var tagsByMemoryID: [UUID: [String]] = [:]
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = MemoryScopeStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("Fugue", isDirectory: true)
            .appendingPathComponent("memory-scopes.json")
    }

    func tags(for memoryID: UUID) -> [String] {
        tagsByMemoryID[memoryID] ?? []
    }

    func setTags(_ tags: [String], for memoryID: UUID) {
        let cleaned = ProjectWorkspace.normalizedTags(from: tags.joined(separator: ","))
        if cleaned.isEmpty {
            tagsByMemoryID.removeValue(forKey: memoryID)
        } else {
            tagsByMemoryID[memoryID] = cleaned
        }
        persist()
    }

    func remove(memoryID: UUID) {
        guard tagsByMemoryID.removeValue(forKey: memoryID) != nil else { return }
        persist()
    }

    func allUsedTags() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tags in tagsByMemoryID.values {
            for tag in tags {
                let lower = tag.lowercased()
                if seen.insert(lower).inserted { result.append(tag) }
            }
        }
        return result.sorted()
    }

    /// Evaluates whether a memory should be injected given optional project scope tags.
    /// - When `activeProjectTags` is nil or empty (non-project chat), all enabled memories are eligible.
    /// - When `activeProjectTags` is non-empty, global (untagged) memories and memories matching at least
    ///   one project tag are eligible.
    static func matches(memoryTags: [String], activeProjectTags: [String]?) -> Bool {
        guard let projectTags = activeProjectTags, !projectTags.isEmpty else {
            return true
        }
        if memoryTags.isEmpty { return true }
        let projectSet = Set(projectTags.map { $0.lowercased() })
        return memoryTags.contains { projectSet.contains($0.lowercased()) }
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        var mapped: [UUID: [String]] = [:]
        for (k, v) in decoded {
            if let uuid = UUID(uuidString: k), !v.isEmpty {
                mapped[uuid] = v
            }
        }
        tagsByMemoryID = mapped
    }

    private func persist() {
        guard let fileURL else { return }
        let encodedMap = Dictionary(uniqueKeysWithValues: tagsByMemoryID.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encodedMap) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
