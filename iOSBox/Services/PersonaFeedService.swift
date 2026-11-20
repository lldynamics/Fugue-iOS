import BackgroundTasks
import CryptoKit
import SwiftData
import UIKit

@MainActor
final class PersonaFeedService {
    static let shared = PersonaFeedService()
    static let interval: TimeInterval = 30 * 60
    private let reader: PersonaFeedReader

    private struct Source: Hashable {
        let chat: UUID
        let member: UUID
        let feed: UUID
    }
    private var inFlight: Set<Source> = []

    struct Report {
        var added = 0
        var baselines = 0
        var checked = 0
        var deferred = 0
        var errors: [String] = []
        var message: String {
            var lines: [String] = []
            if checked > 0 { lines.append(String(localized: "已检查 \(checked) 个订阅，新增 \(added) 条动态。")) }
            if baselines > 0 { lines.append(String(localized: "首次检查已记录现有内容，之后只分享新动态。")) }
            if deferred > 0 { lines.append(String(localized: "部分订阅正在检查或群内正在发言，稍后可再检查。")) }
            lines.append(contentsOf: errors)
            return lines.isEmpty ? String(localized: "没有待检查的订阅。") : lines.joined(separator: "\n")
        }
    }

    init(reader: PersonaFeedReader = PersonaFeedReader()) { self.reader = reader }

    static func hasSubscriptions(_ chat: Conversation) -> Bool {
        guard chat.assistanceSettingsData != nil else { return false }
        return chat.isGroupMode && chat.activeGroupMembers.contains { $0.persona?.feeds.contains(where: \.enabled) == true }
    }

    func refresh(in context: ModelContext, chatID: UUID? = nil, force: Bool = false, now: Date = Date()) async -> Report {
        var report = Report()
        guard PersistenceController.canCommitUserData(in: context) else { return report }
        do {
            let descriptor: FetchDescriptor<Conversation>
            if let chatID { descriptor = FetchDescriptor(predicate: #Predicate { $0.id == chatID }) }
            else { descriptor = FetchDescriptor() }
            for chat in try context.fetch(descriptor) where Self.hasSubscriptions(chat) {
                for member in chat.activeGroupMembers {
                    for feed in member.persona?.feeds ?? [] where feed.enabled {
                        guard !Task.isCancelled else { return report }
                        let source = Source(chat: chat.id, member: member.id, feed: feed.id)
                        guard let current = liveSettings(chat, member.id, feed)?.feed,
                              force || current.lastChecked.map({ now.timeIntervalSince($0) >= Self.interval }) ?? true else { continue }
                        guard !ChatEngine.shared.isGenerating(in: chat.id), !chat.messages.contains(where: \.isStreaming), inFlight.insert(source).inserted else {
                            report.deferred += 1
                            continue
                        }
                        defer { inFlight.remove(source) }
                        let result: Result<PersonaFeedBatch, Error>
                        do { result = .success(try await reader.read(current, now: now)) }
                        catch { result = .failure(error) }
                        guard !Task.isCancelled else { return report }
                        guard let live = liveSettings(chat, member.id, current), live.feed.checkpoint == current.checkpoint else { continue }
                        guard !ChatEngine.shared.isGenerating(in: chat.id), !chat.messages.contains(where: \.isStreaming) else { report.deferred += 1; continue }
                        var updated = live.feed
                        updated.lastChecked = now
                        let items: [PersonaFeedItem]
                        switch result {
                        case .success(let batch):
                            updated.checkpoint = batch.checkpoint
                            updated.lastError = nil
                            items = batch.items
                        case .failure(let error):
                            updated.lastError = error.localizedDescription
                            report.errors.append("\(live.name) · \(error.localizedDescription)")
                            items = []
                        }
                        var settings = chat.assistanceSettings
                        settings.groupMembers[live.memberIndex].persona?.feeds[live.feedIndex] = updated
                        let count = try commit(items: items, member: live.name, settings: settings, chat: chat, context: context, now: now)
                        if case .success = result {
                            report.checked += 1
                            report.added += count
                            if current.checkpoint == nil { report.baselines += 1 }
                        }
                    }
                }
            }
        } catch { report.errors.append(error.localizedDescription) }
        return report
    }

    private func liveSettings(_ chat: Conversation, _ memberID: UUID, _ source: PersonaFeed)
        -> (memberIndex: Int, feedIndex: Int, name: String, feed: PersonaFeed)? {
        guard chat.modelContext != nil, !chat.isDeleted, chat.isGroupMode else { return nil }
        let members = chat.groupMembers
        guard let m = members.firstIndex(where: { $0.id == memberID && !$0.isMuted }),
              let feeds = members[m].persona?.feeds,
              let f = feeds.firstIndex(where: { $0.id == source.id && $0.kind == source.kind && $0.address == source.address && $0.enabled })
        else { return nil }
        return (m, f, members[m].displayLabel, feeds[f])
    }

    private func commit(items: [PersonaFeedItem], member: String, settings: AssistanceSettings,
                        chat: Conversation, context: ModelContext, now: Date) throws -> Int {
        let previous = (chat.assistanceSettingsData, chat.activeLeafMessageID, chat.updatedAt)
        var added: [ChatMessage] = []
        if !items.isEmpty {
            let tree = ConversationTree.usesTree(chat)
            var parent = tree ? ConversationTree.currentAnchorID(in: chat) : nil
            var index = (chat.messages.map(\.sortIndex).max() ?? -1) + 1
            var known = Set(chat.messages.map(\.id))
            for item in items {
                let id = Self.noticeID(chat.id, item.url)
                guard known.insert(id).inserted else { continue }
                let notice = GroupSourceNotice(memberName: member, title: item.title, url: item.url,
                                               published: item.published, excerpt: item.excerpt)
                let message = ChatMessage(id: id, role: .system, content: notice.body, sortIndex: index, createdAt: now)
                message.assistanceMetadata.sourceNotice = notice
                message.parentMessageID = parent
                context.insert(message)
                message.conversation = chat
                added.append(message)
                if tree { parent = id; chat.activeLeafMessageID = id }
                index += 1
            }
        }
        chat.assistanceSettings = settings
        if !added.isEmpty { chat.updatedAt = now }
        do { try context.save() } catch {
            for message in added { context.delete(message) }
            (chat.assistanceSettingsData, chat.activeLeafMessageID, chat.updatedAt) = previous
            throw error
        }
        return added.count
    }

    private static func noticeID(_ chatID: UUID, _ url: URL) -> UUID {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        let digest = SHA256.hash(data: Data((chatID.uuidString + "|" + (parts?.string ?? url.absoluteString)).utf8))
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], (b[6] & 15) | 80, b[7],
                           (b[8] & 63) | 128, b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

@MainActor
final class PersonaRefreshDelegate: NSObject, UIApplicationDelegate {
    static let identifier = (Bundle.main.bundleIdentifier ?? "com.iosbox.app") + ".persona-refresh"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            let worker = Task { @MainActor in
                let context = AppRuntime.persistence.container.mainContext
                Self.schedule(in: context)
                let report = await PersonaFeedService.shared.refresh(in: context)
                task.setTaskCompleted(success: !Task.isCancelled && report.errors.isEmpty)
            }
            task.expirationHandler = { worker.cancel() }
        }
        return true
    }

    static func schedule(in context: ModelContext) {
        guard PersistenceController.canCommitUserData(in: context),
              let chats = try? context.fetch(FetchDescriptor<Conversation>()) else { return }
        guard chats.contains(where: { PersonaFeedService.hasSubscriptions($0) }) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: PersonaFeedService.interval)
        // Foreground refresh remains available when background refresh is disabled by the system.
        try? BGTaskScheduler.shared.submit(request)
    }
}
