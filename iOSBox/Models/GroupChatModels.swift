import Foundation

enum GroupSpeakingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case smartRelay
    case roundRobin
    case mentionOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smartRelay:
            return String(localized: "智能接力讨论")
        case .roundRobin:
            return String(localized: "轮流依次发言")
        case .mentionOnly:
            return String(localized: "仅 @ 点名发言")
        }
    }

    var shortBadge: String {
        switch self {
        case .smartRelay:
            return String(localized: "智能接力")
        case .roundRobin:
            return String(localized: "轮流")
        case .mentionOnly:
            return String(localized: "点名")
        }
    }

    var subtitle: String {
        switch self {
        case .smartRelay:
            return String(localized: "支持 @ 点名与成员互相点名抢麦，有话接话、没话潜水，自动碰撞 2～6 句后停下等你拍板。")
        case .roundRobin:
            return String(localized: "按群成员座位顺序依次表态，适合多视角方案评审与头脑风暴。")
        case .mentionOnly:
            return String(localized: "成员平时保持潜水，只有被你 @ 点名或点击「发起表决」时才发言。")
        }
    }
}

enum GroupSpeechStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case naturalShort
    case deepDebate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .naturalShort:
            return String(localized: "群聊口语短句")
        case .deepDebate:
            return String(localized: "圆桌深度交锋")
        }
    }

    var subtitle: String {
        switch self {
        case .naturalShort:
            return String(localized: "去 AI 公文味，每次 2～4 句直击要害，像真人在微信群里拿手机回消息。")
        case .deepDebate:
            return String(localized: "保留交锋锋芒的同时允许展开详细论据与代码示例。")
        }
    }
}

enum GroupSpeechIntent: String, Codable, CaseIterable, Sendable {
    case openPerspective
    case rebuttal
    case alternative
    case probeDetail
    case mediate
    case vote
    case summarize

    var badgeTitle: String? {
        switch self {
        case .openPerspective:
            return nil
        case .rebuttal:
            return String(localized: "挑刺反驳")
        case .alternative:
            return String(localized: "另辟蹊径")
        case .probeDetail:
            return String(localized: "追问细节")
        case .mediate:
            return String(localized: "折中收敛")
        case .vote:
            return String(localized: "亮牌表决")
        case .summarize:
            return String(localized: "讨论纪要")
        }
    }

    var badgeIcon: String? {
        switch self {
        case .openPerspective:
            return nil
        case .rebuttal:
            return "bolt.fill"
        case .alternative:
            return "lightbulb.fill"
        case .probeDetail:
            return "magnifyingglass"
        case .mediate:
            return "scale.3d"
        case .vote:
            return "hand.raised.fill"
        case .summarize:
            return "list.clipboard.fill"
        }
    }

    static func parse(_ raw: String) -> GroupSpeechIntent? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open", "openperspective", "perspective":
            return .openPerspective
        case "rebuttal", "disagree", "challenge", "critique":
            return .rebuttal
        case "alternative", "alt", "brainstorm":
            return .alternative
        case "probe", "probedetail", "question", "ask":
            return .probeDetail
        case "mediate", "compromise", "converge":
            return .mediate
        case "vote":
            return .vote
        case "summarize", "summary":
            return .summarize
        default:
            return nil
        }
    }
}

struct PickedGroupMention: Codable, Equatable, Sendable {
    var offset: Int
    let token: String
    let memberID: UUID?

    static func updating(_ mentions: [Self], from oldText: String, to newText: String) -> [Self] {
        guard !mentions.isEmpty else { return mentions }
        let old = Array(oldText.utf16)
        let new = Array(newText.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        func uniqueOffset(of token: String, in text: NSString) -> Int? {
            let first = text.range(of: token, options: .literal)
            guard first.location != NSNotFound else { return nil }
            let remaining = NSRange(location: first.location + 1, length: text.length - first.location - 1)
            return text.range(of: token, options: .literal, range: remaining).location == NSNotFound ? first.location : nil
        }
        return mentions.compactMap { mention in
            guard !mention.token.isEmpty, mention.offset >= 0, mention.offset <= old.count,
                  mention.token.utf16.count <= old.count - mention.offset else { return nil }
            if mention.offset + mention.token.utf16.count <= prefix { return mention }
            var updated = mention
            if mention.offset >= old.count - suffix {
                updated.offset += new.count - old.count
            } else {
                guard uniqueOffset(of: mention.token, in: oldText as NSString) == mention.offset,
                      let offset = uniqueOffset(of: mention.token, in: newText as NSString) else { return nil }
                updated.offset = offset
            }
            return updated
        }
    }
}

struct GroupMember: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var title: String
    var avatarEmoji: String
    var accentHex: String
    var rolePrompt: String
    var target: ResolvedModelTarget
    var temperature: Double
    var isMuted: Bool
    var profileID: UUID?
    var persona: GroupPersona?
    var bookFriend: BookFriend?

    var isSimulatedPersona: Bool { profileID != nil || persona != nil || bookFriend != nil }

    init(
        id: UUID = UUID(),
        name: String,
        title: String = "",
        avatarEmoji: String = "🤖",
        accentHex: String = "#3F6EF6",
        rolePrompt: String,
        target: ResolvedModelTarget,
        temperature: Double = 0.75,
        isMuted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.avatarEmoji = avatarEmoji
        self.accentHex = accentHex
        self.rolePrompt = rolePrompt
        self.target = target
        self.temperature = temperature
        self.isMuted = isMuted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        avatarEmoji = try c.decodeIfPresent(String.self, forKey: .avatarEmoji) ?? "🤖"
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? "#3F6EF6"
        rolePrompt = try c.decodeIfPresent(String.self, forKey: .rolePrompt) ?? ""
        target = try c.decode(ResolvedModelTarget.self, forKey: .target)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.75
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        persona = try c.decodeIfPresent(GroupPersona.self, forKey: .persona)
        bookFriend = try c.decodeIfPresent(BookFriend.self, forKey: .bookFriend)
    }

    var displayLabel: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty {
            return cleanName.isEmpty ? String(localized: "群成员") : cleanName
        }
        if cleanName.isEmpty {
            return cleanTitle
        }
        return "\(cleanTitle)·\(cleanName)"
    }

    var mentionToken: String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanName.isEmpty ? displayLabel : cleanName
    }

    static let paletteHexes: [String] = [
        "#3F6EF6", "#E65D4F", "#18A058", "#8A4FFF", "#D9822B", "#0E9AA7"
    ]
}

struct GroupReaction: Codable, Equatable, Sendable, Identifiable {
    var memberID: UUID
    var memberName: String
    var memberEmoji: String
    var emoji: String

    var id: String { "\(memberID.uuidString)-\(emoji)" }
}

struct GroupRoomTemplate: Codable, Equatable, Identifiable, Sendable {
    struct Seat: Codable, Equatable, Sendable {
        var name: String
        var title: String
        var emoji: String
        var accentHex: String
        var rolePrompt: String
        var temperature: Double
        var boundMember: GroupMember? = nil
    }

    var id: String
    var roomTitle: String
    var roomEmoji: String
    var subtitle: String
    var sharedTopicPrompt: String
    var speakingMode: GroupSpeakingMode
    var speechStyle: GroupSpeechStyle
    var seats: [Seat]
    var isCustom: Bool = false

    static func custom(
        roomTitle: String,
        roomEmoji: String,
        sharedTopicPrompt: String,
        speakingMode: GroupSpeakingMode,
        speechStyle: GroupSpeechStyle,
        members: [GroupMember]
    ) -> GroupRoomTemplate {
        let trimmedTitle = roomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryNames = members.map(\.displayLabel).joined(separator: " + ")
        return GroupRoomTemplate(
            id: "custom-\(UUID().uuidString)",
            roomTitle: trimmedTitle.isEmpty ? String(localized: "自定义圆桌阵容") : trimmedTitle,
            roomEmoji: roomEmoji.isEmpty ? "👥" : roomEmoji,
            subtitle: summaryNames,
            sharedTopicPrompt: sharedTopicPrompt,
            speakingMode: speakingMode,
            speechStyle: speechStyle,
            seats: members.map {
                Seat(
                    name: $0.name,
                    title: $0.title,
                    emoji: $0.avatarEmoji,
                    accentHex: $0.accentHex,
                    rolePrompt: $0.rolePrompt,
                    temperature: $0.temperature,
                    boundMember: $0.profileID != nil || $0.persona != nil ? $0.copyForNewRoom : nil
                )
            },
            isCustom: true
        )
    }

    func instantiate(using targets: [ResolvedModelTarget], profiles: [GroupMember] = []) -> [GroupMember] {
        guard !targets.isEmpty else { return [] }
        return seats.enumerated().map { idx, seat in
            if let saved = seat.boundMember {
                let member = saved.profileID.flatMap { id in profiles.first { $0.profileID == id } } ?? saved
                return member.copyForNewRoom
            }
            let assigned = targets[idx % targets.count]
            return GroupMember(
                name: seat.name,
                title: seat.title,
                avatarEmoji: seat.emoji,
                accentHex: seat.accentHex,
                rolePrompt: seat.rolePrompt,
                target: assigned,
                temperature: seat.temperature
            )
        }
    }

    static var builtInTemplates: [GroupRoomTemplate] {
        [
            GroupRoomTemplate(
                id: "startup-board",
                roomTitle: String(localized: "创业点子审委会"),
                roomEmoji: "🚀",
                subtitle: String(localized: "乐观产品 + 毒舌架构师 + 挑剔投资人，全方位拷问你的想法"),
                sharedTopicPrompt: String(localized: "这是一个产品与创业想法评审群。大家围绕群主抛出的点子真实讨论：有人挖掘用户痛点，有人评估技术可行性与坑点，有人拷问商业变现与护城河。"),
                speakingMode: .smartRelay,
                speechStyle: .naturalShort,
                seats: [
                    Seat(
                        name: String(localized: "林晓"),
                        title: String(localized: "产品经理"),
                        emoji: "👩‍💼",
                        accentHex: "#3F6EF6",
                        rolePrompt: String(localized: "你是一位直觉敏锐的产品经理，擅长站在真实高频场景挖掘痛点、传播钩子与最小可行产品（MVP）切口，说话干练有感染力。"),
                        temperature: 0.8
                    ),
                    Seat(
                        name: String(localized: "老王"),
                        title: String(localized: "毒舌架构师"),
                        emoji: "🧑‍💻",
                        accentHex: "#E65D4F",
                        rolePrompt: String(localized: "你是一位有十五年一线经验的毒舌首席架构师，最讨厌画大饼与过度设计，专门一针见血指出技术瓶颈、边界异常、维护成本和安全隐患。"),
                        temperature: 0.6
                    ),
                    Seat(
                        name: String(localized: "沈总"),
                        title: String(localized: "早期投资人"),
                        emoji: "🧐",
                        accentHex: "#D9822B",
                        rolePrompt: String(localized: "你是一位眼光毒辣的早期风险投资人，只关心获客成本、留存壁垒、付费意愿以及为什么大厂或竞品做不了，喜欢用犀利反问逼出真相。"),
                        temperature: 0.65
                    )
                ]
            ),
            GroupRoomTemplate(
                id: "red-blue-debate",
                roomTitle: String(localized: "红蓝杠精辩论局"),
                roomEmoji: "⚡",
                subtitle: String(localized: "正方力挺 + 反方挑刺 + 冷静裁判，专治买房跳槽选型纠结"),
                sharedTopicPrompt: String(localized: "这是一个红蓝对抗决策群。面对群主纠结的选择，正反双方必须针锋相对摆事实讲利弊，裁判负责拆穿逻辑漏洞并提炼拍板标准。"),
                speakingMode: .smartRelay,
                speechStyle: .naturalShort,
                seats: [
                    Seat(
                        name: String(localized: "陈锋"),
                        title: String(localized: "正方主辩"),
                        emoji: "🔥",
                        accentHex: "#E65D4F",
                        rolePrompt: String(localized: "你是果断行动派，擅长放大核心收益、时间窗口与向上赔率，用强有力的论据推动决策落地。"),
                        temperature: 0.75
                    ),
                    Seat(
                        name: String(localized: "周凛"),
                        title: String(localized: "反方挑刺"),
                        emoji: "🧊",
                        accentHex: "#3F6EF6",
                        rolePrompt: String(localized: "你是深度风险厌恶的冷静挑刺王，专门戳破幸存者偏差、隐性沉没成本与最坏情况，绝不附和盲目乐观。"),
                        temperature: 0.7
                    ),
                    Seat(
                        name: String(localized: "顾言"),
                        title: String(localized: "独立裁判"),
                        emoji: "⚖️",
                        accentHex: "#18A058",
                        rolePrompt: String(localized: "你是客观克制的决策顾问，擅长指出正反双方各自成立的前提条件，并向群主追问最关键的个人约束。"),
                        temperature: 0.45
                    )
                ]
            ),
            GroupRoomTemplate(
                id: "tech-review",
                roomTitle: String(localized: "技术方案三堂会审"),
                roomEmoji: "💻",
                subtitle: String(localized: "性能极客 + 安全专家 + 极简维护派，代码与架构全方位会诊"),
                sharedTopicPrompt: String(localized: "这是一个资深工程技术评审群。针对群主发来的代码、Bug 或架构方案，分别从性能吞吐、安全边界和长期可维护性切入讨论。"),
                speakingMode: .smartRelay,
                speechStyle: .deepDebate,
                seats: [
                    Seat(
                        name: String(localized: "阿杰"),
                        title: String(localized: "性能极客"),
                        emoji: "⚡",
                        accentHex: "#8A4FFF",
                        rolePrompt: String(localized: "你痴迷底层性能、内存布局、并发竞争与主线程卡顿优化，对低效循环和多余拷贝零容忍。"),
                        temperature: 0.4
                    ),
                    Seat(
                        name: String(localized: "陆工"),
                        title: String(localized: "安全审计"),
                        emoji: "🛡️",
                        accentHex: "#0E9AA7",
                        rolePrompt: String(localized: "你专注安全攻防、鉴权越权、数据泄漏、网络超时与异常恢复，专门抓别人忽略的极端边界条件。"),
                        temperature: 0.35
                    ),
                    Seat(
                        name: String(localized: "老赵"),
                        title: String(localized: "极简工程派"),
                        emoji: "🧹",
                        accentHex: "#18A058",
                        rolePrompt: String(localized: "你推崇 KISS 原则和可读性，反对炫技与过度抽象，总能给出代码量最少、半年后最好改的务实方案。"),
                        temperature: 0.5
                    )
                ]
            ),
            GroupRoomTemplate(
                id: "late-night-lounge",
                roomTitle: String(localized: "深夜吹水智囊团"),
                roomEmoji: "☕",
                subtitle: String(localized: "幽默损友 + 温柔共情师 + 理性军师，陪聊解闷也能出主意"),
                sharedTopicPrompt: String(localized: "这是一个轻松真实的老友微信群。大家像认识多年的朋友一样跟群主聊天吐槽、提供情绪价值和实在建议，绝对不要说官话套话。"),
                speakingMode: .smartRelay,
                speechStyle: .naturalShort,
                seats: [
                    Seat(
                        name: String(localized: "阿泽"),
                        title: String(localized: "嘴硬损友"),
                        emoji: "😼",
                        accentHex: "#D9822B",
                        rolePrompt: String(localized: "你是群主认识十年的幽默损友，说话风趣接地气，擅长用玩笑话一针见血点破内耗，护短但嘴上不饶人。"),
                        temperature: 0.9
                    ),
                    Seat(
                        name: String(localized: "知夏"),
                        title: String(localized: "温柔树洞"),
                        emoji: "🌿",
                        accentHex: "#18A058",
                        rolePrompt: String(localized: "你细腻温暖、观察力强，能听懂群主没明说的委屈或疲惫，先接住情绪再温和梳理感受，从不说教。"),
                        temperature: 0.8
                    ),
                    Seat(
                        name: String(localized: "方远"),
                        title: String(localized: "靠谱军师"),
                        emoji: "🧭",
                        accentHex: "#3F6EF6",
                        rolePrompt: String(localized: "你沉稳务实，等大家吐槽完后，总能帮群主把乱麻理顺，给出一两个明天一早就能轻松做到的小动作。"),
                        temperature: 0.6
                    )
                ]
            )
        ]
    }
}
