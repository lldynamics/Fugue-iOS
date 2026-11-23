import Foundation

struct GroupPersona: Codable, Equatable, Sendable {
    var materials: [PersonaMaterial] = []
    var feeds: [PersonaFeed] = []
    var isEmpty: Bool { materials.isEmpty && feeds.isEmpty }
}

struct PersonaMaterial: Codable, Equatable, Identifiable, Sendable {
    static let maximumCount = 6
    static let maximumCharacters = 4_000
    var id = UUID()
    var title: String
    var text: String
    var url: URL?
}

struct PersonaFeed: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable {
        case blog, x
    }

    var id = UUID()
    let kind: Kind
    let address: String
    var enabled = true
    var checkpoint: Checkpoint?
    var lastChecked: Date?
    var lastError: String?

    struct Checkpoint: Codable, Equatable, Sendable {
        var recentIDs: [String] = []
        var feedURL: URL?
        var userID: String?
        var sinceID: String?
        var nextPage: String?
        var pendingNewestID: String?
        var pendingItems: [PersonaFeedItem]?
        var truncatedBatch: Bool?
        var startedAt: Date?
    }

    var displayName: String { kind == .x ? "@" + address : address }
}

// A source notice is part of the local group timeline. Its URL and publisher travel with the message.
struct GroupSourceNotice: Codable, Equatable, Sendable {
    var memberName: String
    var title: String
    var url: URL
    var published: Date?
    var excerpt: String? = nil
    var byline: String { String(localized: "\(memberName) · 订阅动态") }
    var body: String { [title, excerpt, url.absoluteString].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

enum PersonaError: LocalizedError {
    case empty, noSpeaker, noMatches, tooLarge, invalidAccount, invalidFeed, missingToken, credentialSave, api(Int)
    var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "没有可导入的文字。")
        case .noSpeaker: return String(localized: "请输入记录中这位发言人的名字。")
        case .noMatches: return String(localized: "没有找到此人的发言。请核对名字和聊天记录格式。")
        case .tooLarge: return String(localized: "请选择不超过 2 MB 的文本文件。")
        case .invalidAccount: return String(localized: "请填写有效的 X 用户名或个人主页地址。")
        case .invalidFeed: return String(localized: "未找到可读取的 RSS 或 Atom 订阅，请填写博客公布的订阅地址。")
        case .missingToken: return String(localized: "读取 X 动态需要在人物资料中保存有读取权限的 X API Bearer Token。")
        case .credentialSave: return String(localized: "无法更新钥匙串，请重试。")
        case .api(let status): return String(localized: "X 接口返回 HTTP \(status)，请检查读取权限、账户额度或稍后再试。")
        }
    }
}

extension GroupMember {
    /// Editing a group and polling a feed can overlap. Keep the device's latest cursor for unchanged sources.
    func preservingFeedProgress(from existing: GroupMember?, keepEnabled: Bool = false) -> GroupMember {
        guard var persona else { return self }
        for index in persona.feeds.indices {
            let feed = persona.feeds[index]
            guard let local = existing?.persona?.feeds.first(where: {
                $0.id == feed.id && $0.kind == feed.kind && $0.address == feed.address
            }) else { continue }
            persona.feeds[index].checkpoint = local.checkpoint
            persona.feeds[index].lastChecked = local.lastChecked
            persona.feeds[index].lastError = local.lastError
            if keepEnabled { persona.feeds[index].enabled = local.enabled }
        }
        var copy = self
        copy.persona = persona.isEmpty ? nil : persona
        return copy
    }
}

extension AssistanceSettings {
    /// Imported subscriptions require local opt-in. Credentials and device polling state are never portable.
    var forPersonaBackup: Self {
        var copy = self
        copy.privatePersona = copy.privatePersona?.portableProfile
        for index in copy.groupMembers.indices {
            guard var persona = copy.groupMembers[index].persona else { continue }
            persona.feeds = persona.feeds.map { PersonaFeed(id: $0.id, kind: $0.kind, address: $0.address, enabled: false) }
            copy.groupMembers[index].persona = persona
        }
        return copy
    }
}
