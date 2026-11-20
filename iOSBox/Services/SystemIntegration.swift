import CryptoKit
import Foundation
import SwiftData
import Observation

@MainActor
enum AppRuntime {
    // App Intents and the main scene use the same container and recovery pass.
    static let persistence = PersistenceController.makeContainer()
}

@MainActor @Observable
final class SystemEntryRouter {
    static let shared = SystemEntryRouter()
    var conversationID: UUID?
    var messageID: UUID?
}

@MainActor @Observable
final class SystemIntegration {
    static let shared = SystemIntegration()
    var error: String?
    private let defaults: UserDefaults
    private static let enabledKey = "systemShareProviderIDs"
    @ObservationIgnored private var lastPublishedDigest: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isEnabled(_ id: UUID) -> Bool {
        (defaults.stringArray(forKey: Self.enabledKey) ?? []).contains(id.uuidString)
    }

    func setEnabled(_ enabled: Bool, providerID: UUID, context: ModelContext) throws {
        if enabled {
            guard PersistenceController.canCommitUserData(in: context) else { throw SystemEntryError.storage }
            try context.save()
        }
        var ids = Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
        if enabled { ids.insert(providerID.uuidString) } else { ids.remove(providerID.uuidString) }
        defaults.set(Array(ids), forKey: Self.enabledKey)
        if enabled {
            try publish(context: context, force: true)
        } else {
            // Revoking an existing grant does not depend on saving or fetching the chat database.
            lastPublishedDigest = nil
            let store = try SystemEntryStore()
            let previous = try store.models()
            let removed = previous.filter { $0.target.providerID == providerID }
            try Self.revoke(removed, keeping: previous.filter { $0.target.providerID != providerID },
                            save: store.saveModels, delete: SharedConnectionKeychain().delete)
        }
    }

    static func revoke(_ removed: [SharedModelEntry], keeping retained: [SharedModelEntry],
                       save: ([SharedModelEntry]) throws -> Void, delete: (UUID) -> Void) throws {
        guard !removed.isEmpty else { return }
        let revokedIDs = Set(removed.map(\.connectionID)).subtracting(retained.map(\.connectionID))
        defer { revokedIDs.forEach(delete) }
        try save(retained)
    }

    func refresh(context: ModelContext) {
        // Recovery mode cannot supply an authoritative list of enabled providers.
        guard PersistenceController.canCommitUserData(in: context) else { return }
        do { try publish(context: context); error = nil } catch { self.error = error.localizedDescription }
    }

    func publish(context: ModelContext, force: Bool = false) throws {
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        let allowed = providers.filter { $0.isEnabled && isEnabled($0.id) && !$0.enabledModels.isEmpty }
        let store: SystemEntryStore
        do { store = try SystemEntryStore() } catch {
            if allowed.isEmpty { return }
            throw error
        }
        let previous = try store.models()
        guard !allowed.isEmpty || !previous.isEmpty else {
            lastPublishedDigest = ""
            return
        }

        let currentDigest = Self.publishDigest(for: allowed)
        let allowedProviderIDs = Set(allowed.map(\.id))
        let previousProviderIDs = Set(previous.map(\.target.providerID))
        if !force, lastPublishedDigest == currentDigest, previousProviderIDs == allowedProviderIDs {
            return
        }

        let keychain = SharedConnectionKeychain()

        // If any previously authorized provider was disabled or revoked, revoke its credentials first
        // so a failed subsequent write can never leave a revoked provider accessible.
        let removedEntries = previous.filter { !allowedProviderIDs.contains($0.target.providerID) }
        let retainedPrevious = previous.filter { allowedProviderIDs.contains($0.target.providerID) }
        if !removedEntries.isEmpty {
            try Self.revoke(removedEntries, keeping: retainedPrevious, save: store.saveModels, delete: keychain.delete)
        }

        if allowed.isEmpty {
            lastPublishedDigest = ""
            return
        }

        // Publish new connections before atomically swapping models.json so the Share Extension never
        // observes an empty manifest window during a routine foreground refresh.
        var newIDs: [UUID] = []
        do {
            var entries: [SharedModelEntry] = []
            for provider in allowed {
                let id = UUID()
                try keychain.save(Self.connection(provider), id: id)
                newIDs.append(id)
                entries += provider.enabledModels.map {
                    SharedModelEntry(target: provider.makeTarget(for: $0), spec: $0, connectionID: id)
                }
            }
            try store.saveModels(entries)
            let oldRetainedIDs = Set(retainedPrevious.map(\.connectionID)).subtracting(newIDs)
            oldRetainedIDs.forEach(keychain.delete)
            lastPublishedDigest = currentDigest
        } catch {
            newIDs.forEach { keychain.delete(id: $0) }
            throw error
        }
    }

    static func publishDigest(for providers: [ProviderConfig]) -> String {
        var hasher = SHA256()
        for provider in providers {
            let conn = connection(provider)
            hasher.update(data: Data(provider.id.uuidString.utf8))
            hasher.update(data: Data(provider.name.utf8))
            hasher.update(data: Data(provider.protocolRaw.utf8))
            hasher.update(data: Data(provider.accentHex.utf8))
            hasher.update(data: Data(conn.baseURL.utf8))
            hasher.update(data: Data(conn.apiKey.utf8))
            if let extras = conn.extraAPIKeys {
                for key in extras { hasher.update(data: Data(key.utf8)) }
            }
            if let timeout = conn.idleTimeoutSeconds {
                hasher.update(data: Data(String(timeout).utf8))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let headersData = try? encoder.encode(conn.headers) {
                hasher.update(data: headersData)
            }
            hasher.update(data: provider.modelsData)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func connection(_ provider: ProviderConfig) -> SharedConnection {
        let extras = provider.extraAPIKeys
        let timeout = provider.idleTimeoutSeconds
        return SharedConnection(
            baseURL: provider.baseURL,
            apiKey: KeychainService.shared.loadAPIKey(for: provider.id),
            extraAPIKeys: extras.isEmpty ? nil : extras,
            idleTimeoutSeconds: timeout > 0 ? timeout : nil,
            headers: provider.resolvedCustomHeaders
        )
    }

    static func fingerprint(_ providers: [ProviderConfig]) -> [String] {
        providers.map {
            [$0.id.uuidString, $0.name, $0.baseURL, $0.protocolRaw, String($0.isEnabled),
             String($0.idleTimeoutSeconds),
             $0.modelsData.base64EncodedString(), $0.headersData.base64EncodedString()].joined(separator: "|")
        }
    }
}

enum ExternalReceiptImporter {
    @MainActor @discardableResult
    static func importReceipt(_ receipt: ExternalRunReceipt, context: ModelContext) throws -> UUID? {
        guard !receipt.isRunning else { return nil }
        guard !receipt.records.isEmpty, receipt.userMessageID != receipt.answerMessageID,
              Set(receipt.records.map(\.id)).count == receipt.records.count,
              receipt.records.allSatisfy({ $0.conversationID == receipt.id && $0.messageID == receipt.answerMessageID }) else {
            throw SystemEntryError.importFailed
        }
        let id = receipt.id
        var conversations = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        conversations.fetchLimit = 1
        if try context.fetch(conversations).first != nil { try context.save(); return id }
        // A receipt left behind after successful import must not recreate a deleted chat.
        let requestIDs = Set(receipt.records.map(\.id))
        let existingRecords = try context.fetch(
            FetchDescriptor<RequestRecord>(predicate: #Predicate { $0.conversationID == id })
        )
        guard !existingRecords.contains(where: { requestIDs.contains($0.id) }) else { return nil }
        let conversation = Conversation(id: id, title: receipt.title, systemPrompt: ReadingInput.systemPrompt,
                                        useCustomTemperature: false, primaryTarget: receipt.target)
        conversation.createdAt = receipt.createdAt
        conversation.updatedAt = receipt.updatedAt
        let user = ChatMessage(id: receipt.userMessageID, role: .user, content: receipt.prompt,
                               attachments: receipt.attachments ?? [],
                               sortIndex: 1, createdAt: receipt.createdAt)
        let answer = ChatMessage(id: receipt.answerMessageID, role: .assistant, content: receipt.answer,
                                 reasoningContent: receipt.reasoning, target: receipt.target,
                                 sortIndex: 2, createdAt: receipt.createdAt.addingTimeInterval(0.001))
        answer.errorMessage = receipt.error
        answer.finishReason = receipt.finishReason
        context.insert(conversation)
        for message in [user, answer] {
            message.conversation = conversation
            context.insert(message)
        }
        conversation.messages = [user, answer]
        for snapshot in receipt.records {
            let record = RequestRecord(snapshot: snapshot)
            context.insert(record)
            answer.latestRequest = record
        }
        answer.promptTokens = answer.latestRequest?.promptTokens
        answer.completionTokens = answer.latestRequest?.completionTokens
        answer.latencyMs = answer.latestRequest?.durationMs
        try context.save()
        return id
    }

    @MainActor
    static func drain(_ store: SystemEntryStore, context: ModelContext) throws {
        let configurations = context.container.configurations
        guard PersistenceController.canCommitUserData(in: context) else { return }
        let durable = configurations.allSatisfy { !$0.isStoredInMemoryOnly }
        let batch = try store.receiptBatch()
        var failed = !batch.failed.isEmpty
        for (url, receipt) in batch.entries {
            do {
                _ = try importReceipt(receipt, context: context)
                if durable { try FileManager.default.removeItem(at: url) }
            } catch { failed = true }
        }
        if failed { throw SystemEntryError.importFailed }
    }
}
