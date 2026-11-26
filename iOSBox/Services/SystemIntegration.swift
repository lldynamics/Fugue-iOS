import CryptoKit
import Foundation
import SwiftData
import Observation
import UIKit

@MainActor
@Observable
final class AppRuntime {
    static let shared = AppRuntime(store: PersistenceController.makeContainer())
    private(set) var store: PersistenceController.Result

    init(store: PersistenceController.Result) { self.store = store }

    // Intents may run after unlock, before a scene has received its activation notification.
    static var persistence: PersistenceController.Result {
        shared.retryStorageIfAvailable()
        return shared.store
    }

    func retryStorageIfAvailable() {
        retryStorageIfAvailable(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable) {
            PersistenceController.makeContainer()
        }
    }

    func retryStorageIfAvailable(protectedDataAvailable: Bool, open: () -> PersistenceController.Result) {
        guard protectedDataAvailable, !PersistenceController.canCommitUserData(in: store.container.mainContext) else { return }
        let next = open()
        if PersistenceController.canCommitUserData(in: next.container.mainContext) || next.startupNotice != store.startupNotice {
            store = next
        }
    }
}

struct ChatToolLaunchRequest: Equatable {
    enum Tool: Equatable {
        case voiceNote
        case scanDocument
    }

    let id = UUID()
    let conversationID: UUID
    let tool: Tool
}

@MainActor @Observable
final class SystemEntryRouter {
    static let shared = SystemEntryRouter()
    var conversationID: UUID?
    var messageID: UUID?
    var openOriginalForChatID: UUID?
    var pendingQuickAction: QuickEntryAction?
    var pendingChatToolRequest: ChatToolLaunchRequest?
    private(set) var isLocked = false

    @ObservationIgnored private var deferredURL: URL?
    @ObservationIgnored private var deferredSpotlight: (conversationID: UUID, messageID: UUID?)?
    @ObservationIgnored private var deferredInboxDrain = false

    func setLocked(_ locked: Bool, inbox: QuickEntryInbox = .shared) {
        isLocked = locked
        guard !locked else { return }
        if let url = deferredURL {
            deferredURL = nil
            _ = route(url)
        }
        if let spotlight = deferredSpotlight {
            deferredSpotlight = nil
            routeSpotlight(conversationID: spotlight.conversationID, messageID: spotlight.messageID)
        }
        if deferredInboxDrain {
            deferredInboxDrain = false
            drainPendingInbox(from: inbox)
        }
    }

    func clearDeferredEntries() {
        deferredURL = nil
        deferredSpotlight = nil
        deferredInboxDrain = false
    }

    @discardableResult
    func route(_ url: URL) -> Bool {
        guard let link = SystemDeepLink.parse(url) else { return false }
        if isLocked {
            deferredURL = url
            deferredSpotlight = nil
            return true
        }
        switch link {
        case .conversation(let id):
            messageID = nil
            conversationID = id
        case .action(let action):
            pendingQuickAction = action
        }
        return true
    }

    func routeSpotlight(conversationID: UUID, messageID: UUID?) {
        if isLocked {
            deferredSpotlight = (conversationID, messageID)
            deferredURL = nil
            return
        }
        self.messageID = messageID
        self.conversationID = conversationID
    }

    func drainPendingInbox(from inbox: QuickEntryInbox = .shared) {
        if isLocked {
            deferredInboxDrain = true
            return
        }
        if let action = inbox.consume() {
            pendingQuickAction = action
        }
    }
}

@MainActor @Observable
final class SystemIntegration {
    static let shared = SystemIntegration()
    var error: String?
    private let defaults: UserDefaults
    private static let legacyEnabledKey = "systemShareProviderIDs"
    private static let destinationsKey = "systemShareProviderDestinations"
    @ObservationIgnored private var lastPublishedDigest: String?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var destinationGrants: [String: String] {
        (defaults.dictionary(forKey: Self.destinationsKey) as? [String: String]) ?? [:]
    }

    func isEnabled(_ provider: ProviderConfig) -> Bool {
        destinationGrants[provider.credentialID.uuidString] == Self.destinationDigest(for: provider)
    }

    static func destinationDigest(for provider: ProviderConfig) -> String {
        destinationDigest(protocolType: provider.protocolType, baseURL: provider.baseURL)
    }

    private static func destinationDigest(protocolType: APIProtocolType, baseURL: String) -> String {
        let identity = [protocolType.rawValue, baseURL.trimmingCharacters(in: .whitespacesAndNewlines)]
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func setEnabled(_ enabled: Bool, provider: ProviderConfig, context: ModelContext) throws {
        let providerID = provider.id
        let grantID = provider.credentialID
        if enabled {
            guard PersistenceController.canCommitUserData(in: context) else { throw SystemEntryError.storage }
            try context.save()
        }
        var grants = destinationGrants
        var legacyIDs = Set(defaults.stringArray(forKey: Self.legacyEnabledKey) ?? [])
        legacyIDs.remove(grantID.uuidString)
        legacyIDs.remove(providerID.uuidString)
        defaults.set(Array(legacyIDs), forKey: Self.legacyEnabledKey)
        if enabled {
            grants[grantID.uuidString] = Self.destinationDigest(for: provider)
        } else {
            grants.removeValue(forKey: grantID.uuidString)
            grants.removeValue(forKey: providerID.uuidString)
        }
        defaults.set(grants, forKey: Self.destinationsKey)
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

    static func publishableProviders(_ providers: [ProviderConfig], optedIn: (ProviderConfig) -> Bool) -> [ProviderConfig] {
        providers.filter { optedIn($0) && $0.isReadyForChat }
    }

    func publish(context: ModelContext, force: Bool = false) throws {
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        let store: SystemEntryStore
        do { store = try SystemEntryStore() } catch {
            if !providers.contains(where: isEnabled) { return }
            throw error
        }
        let previous = try store.models()
        let keychain = SharedConnectionKeychain()
        let legacyIDs = Set(defaults.stringArray(forKey: Self.legacyEnabledKey) ?? [])
        var grants = destinationGrants
        // Migrate an old grant only when its published connection proves the approved destination.
        for provider in providers where provider.credentialID == provider.id && legacyIDs.contains(provider.id.uuidString) {
            let key = provider.credentialID.uuidString
            let digest = Self.destinationDigest(for: provider)
            if grants[key] == nil, let entry = previous.first(where: { $0.target.providerID == provider.id }),
               let connection = try? keychain.load(id: entry.connectionID),
               digest == Self.destinationDigest(protocolType: entry.target.protocolType, baseURL: connection.baseURL) {
                grants[key] = digest
            }
        }
        let currentGrants = providers.reduce(into: [String: String]()) { retained, provider in
            let key = provider.credentialID.uuidString
            if grants[key] == Self.destinationDigest(for: provider) { retained[key] = grants[key] }
        }
        if currentGrants != destinationGrants { defaults.set(currentGrants, forKey: Self.destinationsKey) }
        if !legacyIDs.isEmpty { defaults.removeObject(forKey: Self.legacyEnabledKey) }
        let allowed = Self.publishableProviders(providers, optedIn: { currentGrants[$0.credentialID.uuidString] != nil })
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
            apiKey: provider.apiKey,
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
