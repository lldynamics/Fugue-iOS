import Foundation

struct GroupTurnDirective: Equatable, Sendable {
    var isPass = false
    var nextTargetRaw: String?
    var suggestedIntent: GroupSpeechIntent?
    var asksHost = false
    var reactionEmoji: String?
    var replyTargetRaw: String?
}

/// Stateful stream filter that strips accidental `[Name]:` self-prefixes and holds back
/// trailing `[[GROUP_META: ...]]` / `<!-- ... -->` / `[PASS]` directives so raw metadata tags
/// never flash inside a live streaming chat bubble.
struct GroupStreamSanitizer: Sendable {
    struct FinalizedOutput: Equatable, Sendable {
        let visibleText: String
        let directive: GroupTurnDirective
    }

    private let speakerName: String
    private let speakerDisplayLabel: String
    private let isContinuation: Bool
    private var rawBuffer = ""
    private var emittedCount = 0
    private var prefixResolved = false

    init(speakerName: String, speakerDisplayLabel: String, isContinuation: Bool = false) {
        self.speakerName = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speakerDisplayLabel = speakerDisplayLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isContinuation = isContinuation
        self.prefixResolved = isContinuation
    }

    mutating func ingest(_ delta: String) -> String {
        guard !delta.isEmpty else { return "" }
        rawBuffer.append(delta)

        if !prefixResolved {
            let trimmedLead = rawBuffer.drop(while: { $0.isWhitespace })
            if trimmedLead.isEmpty {
                return ""
            }
            if rawBuffer.count < 48 && mayStillBeFormingPrefixOrPass(String(trimmedLead)) {
                return ""
            }
            rawBuffer = stripLeadingSelfPrefix(from: rawBuffer)
            prefixResolved = true
        }

        if !isContinuation {
            let trimmedCheck = rawBuffer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmedCheck == "[PASS]" || trimmedCheck == "[[PASS]]" || "[PASS]".hasPrefix(trimmedCheck) || "[[PASS]]".hasPrefix(trimmedCheck) {
                return ""
            }
        }

        let safeLimit = safeEmitUTF16Count(in: rawBuffer)
        let currentUTF16 = rawBuffer.utf16.count
        guard safeLimit > emittedCount, safeLimit <= currentUTF16 else {
            return ""
        }

        let startIdx = String.Index(utf16Offset: emittedCount, in: rawBuffer)
        let endIdx = String.Index(utf16Offset: safeLimit, in: rawBuffer)
        emittedCount = safeLimit
        return String(rawBuffer[startIdx..<endIdx])
    }

    mutating func finalize() -> FinalizedOutput {
        if !prefixResolved {
            rawBuffer = stripLeadingSelfPrefix(from: rawBuffer)
            prefixResolved = true
        }

        let (cleanedText, parsedDirective) = Self.extractTailDirective(from: rawBuffer)
        let trimmed: String
        if isContinuation {
            trimmed = String(cleanedText.reversed().drop(while: { $0.isWhitespace }).reversed())
        } else {
            trimmed = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var directive = parsedDirective
        if !isContinuation {
            let upper = trimmed.uppercased()
            if upper == "[PASS]" || upper == "[[PASS]]" {
                directive.isPass = true
                return FinalizedOutput(visibleText: "", directive: directive)
            }
        }

        if Self.detectsHostQuestion(in: trimmed) {
            directive.asksHost = true
        }

        return FinalizedOutput(visibleText: trimmed, directive: directive)
    }

    // MARK: - Internal Parsing Helpers

    private func mayStillBeFormingPrefixOrPass(_ trimmedLead: String) -> Bool {
        let upper = trimmedLead.uppercased()
        if "[PASS]".hasPrefix(upper) || "[[PASS]]".hasPrefix(upper) {
            return true
        }
        if trimmedLead.hasPrefix("[") || trimmedLead.hasPrefix("【") {
            let closeIndex = trimmedLead.firstIndex(where: { $0 == "]" || $0 == "】" })
            guard let closeIndex else { return true }
            let afterClose = trimmedLead[trimmedLead.index(after: closeIndex)...]
            if afterClose.isEmpty { return true }
            return false
        }
        for label in [speakerDisplayLabel, speakerName] where !label.isEmpty {
            if label.hasPrefix(trimmedLead) || trimmedLead.hasPrefix(label) {
                if !trimmedLead.contains(":") && !trimmedLead.contains("：") {
                    return true
                }
            }
        }
        return false
    }

    private func stripLeadingSelfPrefix(from text: String) -> String {
        let leadingTrimmed = String(text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
        var candidates: [String] = []
        for label in [speakerDisplayLabel, speakerName] where !label.isEmpty {
            candidates.append("[\(label)]:")
            candidates.append("[\(label)]：")
            candidates.append("【\(label)】:")
            candidates.append("【\(label)】：")
            candidates.append("\(label):")
            candidates.append("\(label)：")
        }
        for prefix in candidates {
            if leadingTrimmed.hasPrefix(prefix) {
                let rest = leadingTrimmed.dropFirst(prefix.count).drop(while: { $0 == " " || $0 == "\t" })
                return String(rest)
            }
        }
        return text
    }

    private func safeEmitUTF16Count(in text: String) -> Int {
        // Hold back if a complete or in-progress [[GROUP_META or <!-- block has started.
        if let metaRange = text.range(of: "[[GROUP_META", options: [.caseInsensitive, .backwards]) {
            return metaRange.lowerBound.utf16Offset(in: text)
        }
        if let commentRange = text.range(of: "<!--", options: [.backwards]) {
            let tail = text[commentRange.lowerBound...]
            if tail.count <= 160 {
                return commentRange.lowerBound.utf16Offset(in: text)
            }
        }

        // Hold back partial marker prefixes right at the end of the stream.
        let markerPrefixes = ["[[GROUP_META", "<!--"]
        let suffixWindow = String(text.suffix(14))
        for marker in markerPrefixes {
            let maxCheck = min(marker.count - 1, suffixWindow.count)
            if maxCheck >= 1 {
                for len in stride(from: maxCheck, through: 1, by: -1) {
                    let candidateSuffix = suffixWindow.suffix(len)
                    if marker.uppercased().hasPrefix(candidateSuffix.uppercased()) {
                        return text.utf16.count - String(candidateSuffix).utf16.count
                    }
                }
            }
        }
        return text.utf16.count
    }

    static func extractTailDirective(from raw: String) -> (String, GroupTurnDirective) {
        var working = raw
        var directive = GroupTurnDirective()

        if let startRange = working.range(of: "[[GROUP_META:", options: [.caseInsensitive, .backwards]) {
            let afterStart = working[startRange.upperBound...]
            if let endRange = afterStart.range(of: "]]") {
                let body = String(afterStart[..<endRange.lowerBound])
                parseKeyValuePairs(body, into: &directive)
                working.removeSubrange(startRange.lowerBound..<endRange.upperBound)
            } else {
                let body = String(afterStart)
                parseKeyValuePairs(body, into: &directive)
                working.removeSubrange(startRange.lowerBound..<working.endIndex)
            }
        } else if let startRange = working.range(of: "<!--", options: [.backwards]),
                  working[startRange.lowerBound...].count <= 180 {
            let afterStart = working[startRange.upperBound...]
            if let endRange = afterStart.range(of: "-->") {
                let body = String(afterStart[..<endRange.lowerBound])
                if body.lowercased().contains("next") || body.lowercased().contains("intent") || body.lowercased().contains("react") {
                    parseKeyValuePairs(body, into: &directive)
                    working.removeSubrange(startRange.lowerBound..<endRange.upperBound)
                }
            }
        }

        return (working, directive)
    }

    private static func parseKeyValuePairs(_ body: String, into directive: inout GroupTurnDirective) {
        let segments = body.split(separator: "|")
        for seg in segments {
            let pair: [Substring]
            if seg.contains("=") {
                pair = seg.split(separator: "=", maxSplits: 1)
            } else if seg.contains(":") {
                pair = seg.split(separator: ":", maxSplits: 1)
            } else {
                continue
            }
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch key {
            case "next":
                let upper = value.uppercased()
                if upper == "HOST" || value == "@群主" || value == "群主" || value == "@你" || upper == "@HOST" || upper == "@YOU" {
                    directive.asksHost = true
                    directive.nextTargetRaw = "HOST"
                } else {
                    directive.nextTargetRaw = value
                }
            case "intent":
                directive.suggestedIntent = GroupSpeechIntent.parse(value)
            case "react", "reaction":
                if let firstScalarCluster = value.first, !firstScalarCluster.isASCII {
                    directive.reactionEmoji = String(firstScalarCluster)
                }
            case "quote", "reply":
                directive.replyTargetRaw = value
            case "pass":
                if value.lowercased() == "true" || value == "1" {
                    directive.isPass = true
                }
            default:
                break
            }
        }
    }

    static func detectsHostQuestion(in text: String) -> Bool {
        guard text.contains("？") || text.contains("?") else { return false }
        let lowered = text.lowercased()
        if text.contains("@群主") || text.contains("@楼主") || lowered.contains("@host") {
            return true
        }
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: "@你", range: searchRange) {
            let after = text[match.upperBound...]
            if !after.hasPrefix("们") {
                return true
            }
            searchRange = match.upperBound..<text.endIndex
        }
        return false
    }
}

@MainActor
enum GroupDiscussionCoordinator {
    struct MentionParseResult: Equatable, Sendable {
        let mentionsAll: Bool
        let members: [GroupMember]
    }

    static func prefersEnglishPrompts(in messages: [ChatMessage]) -> Bool {
        let recentUserTexts = messages
            .filter { $0.role == .user && !$0.assistanceMetadata.isExcludedFromContext }
            .suffix(6)
            .map(\.content)
        guard !recentUserTexts.isEmpty else { return false }
        var cjkCount = 0
        var latinLetterCount = 0
        for text in recentUserTexts {
            for scalar in text.unicodeScalars {
                if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                    cjkCount += 1
                } else if (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value) {
                    latinLetterCount += 1
                }
            }
        }
        return cjkCount == 0 && latinLetterCount >= 4
    }

    static func extractMentions(in text: String, activeMembers: [GroupMember],
                                pickedMentions: [PickedGroupMention] = []) -> MentionParseResult {
        let broadcasts: Set<String> = ["@所有人", "@全体", "@all", "@everyone"]
        var membersByAlias: [String: Set<UUID>] = [:]
        for member in activeMembers {
            for alias in [member.mentionToken, member.name, member.displayLabel, member.title] {
                let name = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !name.isEmpty { membersByAlias["@" + name, default: []].insert(member.id) }
            }
        }
        let aliases = broadcasts.union(membersByAlias.keys).sorted { $0.utf16.count > $1.utf16.count }
        let membersByID = Dictionary(activeMembers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let picks = Dictionary(pickedMentions.map { ($0.offset, $0) }, uniquingKeysWith: { _, last in last })
        let source = text as NSString
        func matches(_ token: String, at offset: Int) -> Bool {
            let count = token.utf16.count
            return count > 1 && count <= source.length - offset
                && source.compare(token, options: .caseInsensitive, range: NSRange(location: offset, length: count)) == .orderedSame
        }
        func isASCIIWord(_ unit: UInt16) -> Bool {
            (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit == 45
        }
        let attachedPunctuation = Set("@/:.\\=+#%&?".utf16)
        func endsAtBoundary(_ end: Int) -> Bool {
            guard end < source.length else { return true }
            let unit = source.character(at: end)
            if unit == 46, end + 1 < source.length, isASCIIWord(source.character(at: end + 1)) { return false }
            if let scalar = UnicodeScalar(unit) {
                return !isASCIIWord(unit) && !CharacterSet.alphanumerics.contains(scalar)
                    && !CharacterSet.nonBaseCharacters.contains(scalar)
            }
            return !(0xD800...0xDBFF).contains(unit)
        }

        var found: [GroupMember] = []
        var seen = Set<UUID>()
        var offset = 0
        while offset < source.length {
            guard source.character(at: offset) == 64 else {
                offset += 1
                continue
            }
            let startsAtBoundary: Bool
            if offset == 0 {
                startsAtBoundary = true
            } else {
                let before = source.character(at: offset - 1)
                startsAtBoundary = !isASCIIWord(before) && !attachedPunctuation.contains(before)
            }
            if let pick = picks[offset], matches(pick.token, at: offset) {
                offset += pick.token.utf16.count
                guard startsAtBoundary, endsAtBoundary(offset) else { continue }
                guard let id = pick.memberID else { return MentionParseResult(mentionsAll: true, members: activeMembers) }
                if let member = membersByID[id], seen.insert(member.id).inserted {
                    found.append(member)
                }
                continue
            }
            guard startsAtBoundary,
                  let alias = aliases.first(where: { matches($0, at: offset) && endsAtBoundary(offset + $0.utf16.count) }) else {
                offset += 1
                continue
            }
            offset += alias.utf16.count
            if broadcasts.contains(alias), membersByAlias[alias] == nil {
                return MentionParseResult(mentionsAll: true, members: activeMembers)
            }
            if let ids = membersByAlias[alias], ids.count == 1, let id = ids.first,
               let member = membersByID[id], seen.insert(id).inserted {
                found.append(member)
            }
        }
        return MentionParseResult(mentionsAll: false, members: found)
    }

    /// Builds a perspective-flipped conversation history for `speaker`:
    /// - `speaker`'s own messages become `.assistant` (plain content, no speaker prefix).
    /// - Host (`.user`) and other group personas' messages become `.user` with explicit speaker labels,
    ///   merging consecutive `.user`-side turns so strict role alternation is preserved across all adapters.
    static func buildPromptHistory(
        messages: [ChatMessage],
        for speaker: GroupMember,
        limit: Int,
        trailingCueIfNeeded: String? = nil,
        preferEnglish: Bool = false,
        recordReferences: (([PersonaExcerpt]) -> Void)? = nil
    ) -> [LLMPromptMessage] {
        let afterDivider: ArraySlice<ChatMessage>
        if let lastDividerIdx = messages.lastIndex(where: { $0.assistanceMetadata.isContextDivider }) {
            afterDivider = messages[messages.index(after: lastDividerIdx)...]
        } else {
            afterDivider = messages[...]
        }

        var filtered: [ChatMessage] = []
        var processedGroups = Set<UUID>()

        for msg in afterDivider {
            if (msg.role == .system && msg.assistanceMetadata.sourceNotice == nil) || msg.assistanceMetadata.isExcludedFromContext {
                continue
            }
            if let gid = msg.comparisonGroupID {
                guard !processedGroups.contains(gid) else { continue }
                processedGroups.insert(gid)
                if let winner = afterDivider.first(where: {
                    $0.comparisonGroupID == gid && $0.isSelectedInGroup && !$0.content.isEmpty
                        && !$0.assistanceMetadata.isExcludedFromContext
                        && (!$0.isSynthesis || ArenaSynthesis.isCurrent($0, in: messages))
                }) {
                    filtered.append(winner)
                }
            } else {
                if msg.role == .assistant && msg.content.isEmpty && msg.attachments.isEmpty {
                    continue
                }
                filtered.append(msg)
            }
        }

        let sliced = limit > 0 ? filtered.suffix(limit) : filtered[...]

        var mediaTurnsKept = 0
        var staged: [(isSelf: Bool, text: String, attachments: [MessageAttachment])] = []

        for msg in sliced.reversed() {
            var attachments = msg.attachments
            if attachments.contains(where: { $0.dataBase64 != nil }) {
                if mediaTurnsKept < ChatEngine.mediaTurnsToKeep {
                    mediaTurnsKept += 1
                } else {
                    attachments = attachments.map(ChatEngine.textOnlyVersion)
                }
            }

            let meta = msg.assistanceMetadata
            let isOwnMessage = msg.role == .assistant && meta.groupMemberID == speaker.id

            if let notice = meta.sourceNotice {
                let source = preferEnglish
                    ? "[Subscribed source for discussion] \(notice.byline)\n\(notice.body)"
                    : "[订阅原文，供讨论参考] \(notice.byline)\n\(notice.body)"
                staged.append((isSelf: false, text: source, attachments: []))
            } else if isOwnMessage {
                staged.append((isSelf: true, text: msg.content, attachments: attachments))
            } else if msg.role == .user {
                let body = ChatEngine.promptContent(msg.content, quotedExcerpt: meta.quotedExcerpt, separator: "\n")
                let formatted: String
                if preferEnglish {
                    formatted = body.isEmpty ? "[Host sent an attachment]" : "[Host]: \(body)"
                } else {
                    formatted = body.isEmpty ? "[群主发送了附件]" : "[群主]: \(body)"
                }
                staged.append((isSelf: false, text: formatted, attachments: attachments))
            } else {
                let defaultPeer = preferEnglish ? "Member" : "群成员"
                let peerTitle = meta.groupSpeakerDisplayTitle
                    ?? (msg.modelDisplayName.isEmpty ? defaultPeer : msg.modelDisplayName)
                let replyHint: String
                if let replyTarget = meta.groupReplyToSpeaker, !replyTarget.isEmpty {
                    replyHint = preferEnglish ? " (replying to @\(replyTarget))" : " (回复 @\(replyTarget))"
                } else {
                    replyHint = ""
                }
                let formatted = "[\(peerTitle)\(replyHint)]: \(msg.content)"
                staged.append((isSelf: false, text: formatted, attachments: []))
            }
        }

        staged.reverse()

        // Merge consecutive same-role entries for clean strict user <-> assistant alternation.
        var merged: [LLMPromptMessage] = []
        for entry in staged {
            let role: MessageRole = entry.isSelf ? .assistant : .user
            if let last = merged.last, last.role == role {
                let joinedText: String
                if last.content.isEmpty {
                    joinedText = entry.text
                } else if entry.text.isEmpty {
                    joinedText = last.content
                } else {
                    joinedText = last.content + "\n\n" + entry.text
                }
                merged[merged.count - 1] = LLMPromptMessage(
                    role: role,
                    content: joinedText,
                    attachments: last.attachments + entry.attachments
                )
            } else {
                merged.append(LLMPromptMessage(
                    role: role,
                    content: entry.text,
                    attachments: entry.attachments
                ))
            }
        }

        if merged.isEmpty || merged.last?.role == .assistant {
            let defaultCue = preferEnglish
                ? "[The group discussion continues—respond directly in character]"
                : "[群内讨论继续，请基于你的身份直接发言回应]"
            let cue = trailingCueIfNeeded ?? defaultCue
            merged.append(LLMPromptMessage(role: .user, content: cue))
        }

        if let materials = speaker.persona?.materials, !materials.isEmpty, let last = merged.last {
            let topic = sliced.last(where: { $0.role == .user })?.content ?? last.content
            let excerpts = PersonaMaterials.excerpts(materials, topic: topic)
            if let reference = PersonaMaterials.referenceBlock(excerpts) {
                recordReferences?(excerpts)
                merged[merged.count - 1] = LLMPromptMessage(role: .user, content: last.content + "\n\n" + reference, attachments: last.attachments)
            }
        }

        return merged
    }

    static func buildSystemPrompt(
        for speaker: GroupMember,
        activeMembers: [GroupMember],
        speechStyle: GroupSpeechStyle,
        intent: GroupSpeechIntent,
        baseSystemPrompt: String,
        allowPass: Bool,
        preferEnglish: Bool = false
    ) -> String {
        if preferEnglish {
            return buildEnglishSystemPrompt(
                for: speaker,
                activeMembers: activeMembers,
                speechStyle: speechStyle,
                intent: intent,
                baseSystemPrompt: baseSystemPrompt,
                allowPass: allowPass
            )
        }
        let peers = activeMembers
            .filter { $0.id != speaker.id }
            .map { "\($0.avatarEmoji) \($0.displayLabel)（@\($0.mentionToken)）" }
            .joined(separator: "、")

        let intentInstruction: String
        switch intent {
        case .openPerspective:
            intentInstruction = "本轮动作【直抒己见】：从你的专业视角出发，直接抛出最鲜明的核心判断，不讲客套开场白。"
        case .rebuttal:
            intentInstruction = "本轮动作【挑刺反驳】：严禁先说“同意楼上”或客套附和！请直接指出前一位发言者最致命的盲点、过度乐观的假设或落地坑点，可以直接 @对方。"
        case .alternative:
            intentInstruction = "本轮动作【另辟蹊径】：跳出前面成员已经聊过的思路，提供一个截然不同、更巧妙或更务实的替代方案。"
        case .probeDetail:
            intentInstruction = "本轮动作【追问细节】：如果前面的讨论缺少关键前提（如预算、规模、时间线），可以直接 `@群主` 抛出一个简短犀利的反问请他拍板；否则追问楼上方案的具体执行细节。"
        case .mediate:
            intentInstruction = "本轮动作【折中收敛】：针对前面群友的交锋分歧，权衡双方底线，给出一个当下最能落地的折中决断。"
        case .vote:
            intentInstruction = "本轮动作【圆桌亮牌表决】：群主发起了表决！你必须在第一行明确亮牌写出【赞成】、【反对】或【中立】（或明确站队某个选项），紧接着用 1～3 句话给出你最硬核的理由。"
        case .summarize:
            intentInstruction = "本轮动作【敲槌总结纪要】：请客观精炼地把刚才群内讨论总结为三小块：1. 核心共识；2. 关键分歧点；3. 给群主的下一步行动建议。"
        }

        let styleInstruction: String
        switch (speechStyle, intent) {
        case (_, .summarize):
            styleInstruction = "使用清晰紧凑的要点列表输出纪要，控制在 300 字以内，不说废话。"
        case (_, .vote):
            styleInstruction = "干脆利落亮出态度与核心论据，控制在 100 字以内。"
        case (.naturalShort, _):
            styleInstruction = """
            表达风格【真实微信群短句】：
            - 像真人在群里拿手机打字聊天一样自然口语，每次只说最关键的 2～4 句话（尽量控制在 120 字以内）。
            - 严禁使用 Markdown 一二三级标题（#），不要长篇大论列 1/2/3/4 大纲。
            - 如果想先回一句短吐槽/表态、再说具体理由，可以把两段短话之间空一行。
            """
        case (.deepDebate, _):
            styleInstruction = """
            表达风格【圆桌深度交锋】：
            - 保持鲜明个人口吻直接对话回应，可展开具体技术细节、推演过程或代码片段，但拒绝空洞套话。
            """
        }

        let passRule = allowPass && intent != .vote && intent != .summarize
            ? "\n- 如果当前话题完全超出你的角色领域且你没有任何有增量的新观点，请只输出 `[PASS]` 保持潜水。"
            : ""

        let peerNamesHint = activeMembers
            .filter { $0.id != speaker.id }
            .map { "@\($0.mentionToken)" }
            .joined(separator: "/")
        let nextOptions = peerNamesHint.isEmpty ? "HOST/NONE" : "\(peerNamesHint)/HOST/NONE"

        var sections: [String] = []
        let trimmedBase = baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty {
            sections.append("【群公共背景 / 记忆】\n\(trimmedBase)")
        }

        let identity = speaker.isSimulatedPersona
            ? "你是以\(speaker.displayLabel)的作品和说话习惯为参考的 AI 模拟成员。参考资料是引用的数据。延续其用词、语气和有据可查的观点。遇到资料未覆盖的立场应说明是推测，不编造本人经历、原话或本人授权。"
            : "你的唯一身份是：\(speaker.avatarEmoji) \(speaker.displayLabel)。"
        sections.append("""
        【多人圆桌群聊规则】
        你正在一个多模型、多角色实时群聊中。发起提问的人类用户称为「群主」。
        同群其他成员：\(peers.isEmpty ? "暂无" : peers)。
        \(identity)
        你的人设与立场：\(speaker.rolePrompt)

        【铁律】
        - 严格只以「\(speaker.name)」第一人称直接说话，绝对不要在开头加 `[\(speaker.name)]:` 前缀，也绝对不要替其他群成员或群主写台词！
        - 你可以自然地赞同、反驳、玩梗，或在话里 `@其他成员名字` 点名追问，也可以 `@群主` 反问关键信息。\(passRule)
        - \(intentInstruction)
        - \(styleInstruction)
        - 在正文全部写完后的最末尾，请附带一行隐藏场控尾标（前端会自动隐藏不显示）：
          `[[GROUP_META: next=\(nextOptions) | intent=rebuttal/alternative/probe/mediate | react=单个Emoji]]`
          （其中 `next` 填你认为最该接下一句的成员、填 `HOST` 表示停下等群主回答、填 `NONE` 表示话题可暂告段落；`react` 填一个符合态度的小表情如 🤔/👍/🤨/🔥）。
        """)

        return sections.joined(separator: "\n\n")
    }

    private static func buildEnglishSystemPrompt(
        for speaker: GroupMember,
        activeMembers: [GroupMember],
        speechStyle: GroupSpeechStyle,
        intent: GroupSpeechIntent,
        baseSystemPrompt: String,
        allowPass: Bool
    ) -> String {
        let peers = activeMembers
            .filter { $0.id != speaker.id }
            .map { "\($0.avatarEmoji) \($0.displayLabel) (@\($0.mentionToken))" }
            .joined(separator: ", ")

        let intentInstruction: String
        switch intent {
        case .openPerspective:
            intentInstruction = "Turn action [Open Perspective]: Lead directly with your sharpest core judgment from your perspective without polite filler."
        case .rebuttal:
            intentInstruction = "Turn action [Rebuttal]: Do NOT start with polite agreement! Directly point out the biggest blind spot, overly optimistic assumption, or practical pitfall in the previous speaker's point; you may @mention them."
        case .alternative:
            intentInstruction = "Turn action [Alternative]: Step outside approaches already discussed and propose a distinct, smarter, or more pragmatic alternative."
        case .probeDetail:
            intentInstruction = "Turn action [Probe Detail]: If key constraints (budget, scale, timeline) are missing, ask `@Host` a concise clarifying question; otherwise press the previous speaker on concrete execution details."
        case .mediate:
            intentInstruction = "Turn action [Mediate]: Weigh the competing viewpoints in the room and propose the most actionable middle-ground decision."
        case .vote:
            intentInstruction = "Turn action [Roundtable Vote]: State your explicit stance on the first line—[Agree], [Disagree], or [Neutral] (or pick a specific option)—followed by 1–3 sentences giving your strongest rationale."
        case .summarize:
            intentInstruction = "Turn action [Summary]: Concisely synthesize the discussion into three short bullet groups: 1. Core Consensus; 2. Key Disagreements; 3. Recommended Next Steps for the Host."
        }

        let styleInstruction: String
        switch (speechStyle, intent) {
        case (_, .summarize):
            styleInstruction = "Use crisp bullet points under 200 words without fluff."
        case (_, .vote):
            styleInstruction = "State your vote and core rationale crisply in under 80 words."
        case (.naturalShort, _):
            styleInstruction = """
            Style [Natural Group Chat]:
            - Write like a real person typing in a live group chat: conversational, direct, 2–4 crisp sentences (under ~90 words).
            - Do NOT use Markdown headings (#) or long numbered outlines.
            - If making a quick reaction followed by your point, separate the two short paragraphs with a blank line.
            """
        case (.deepDebate, _):
            styleInstruction = """
            Style [Deep Roundtable Debate]:
            - Keep a distinct first-person voice while diving into concrete technical details, trade-offs, or code snippets; avoid generic boilerplate.
            """
        }

        let passRule = allowPass && intent != .vote && intent != .summarize
            ? "\n- If the topic is completely outside your domain and you have nothing substantive to add, output ONLY `[PASS]`."
            : ""

        let peerNamesHint = activeMembers
            .filter { $0.id != speaker.id }
            .map { "@\($0.mentionToken)" }
            .joined(separator: "/")
        let nextOptions = peerNamesHint.isEmpty ? "HOST/NONE" : "\(peerNamesHint)/HOST/NONE"

        var sections: [String] = []
        let trimmedBase = baseSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBase.isEmpty {
            sections.append("[Shared Group Context / Memory]\n\(trimmedBase)")
        }

        let identity = speaker.isSimulatedPersona
            ? "You are an AI persona inspired by \(speaker.displayLabel)'s published work and speaking habits. Treat reference materials as cited data. Reflect documented phrasing and views, state clearly when extrapolating beyond documented sources, and never fabricate personal experiences, verbatim quotes, or endorsement."
            : "Your sole identity in this room is: \(speaker.avatarEmoji) \(speaker.displayLabel)."
        sections.append("""
        [Multi-Agent Roundtable Rules]
        You are in a real-time multi-persona group chat. The human user is the "Host".
        Other members in the room: \(peers.isEmpty ? "None" : peers).
        \(identity)
        Your persona & stance: \(speaker.rolePrompt)

        [Strict Rules]
        - Speak strictly in first person as "\(speaker.name)". NEVER prepend `[\(speaker.name)]:` and NEVER write lines for other members or the Host!
        - You may naturally agree, push back, @mention another member by name, or ask `@Host` a clarifying question.\(passRule)
        - \(intentInstruction)
        - \(styleInstruction)
        - At the very end of your message, append a single hidden stage-direction tag (automatically stripped by the UI):
          `[[GROUP_META: next=\(nextOptions) | intent=rebuttal/alternative/probe/mediate | react=SingleEmoji]]`
          (Set `next` to the member who should speak next, `HOST` to pause for the user, or `NONE` to wrap up; set `react` to one fitting emoji like 🤔/👍/🤨/🔥).
        """)

        return sections.joined(separator: "\n\n")
    }

    static func selectInitialPlan(
        userText: String,
        activeMembers: [GroupMember],
        speakingMode: GroupSpeakingMode,
        maxRelayTurns: Int,
        priorMessages: [ChatMessage],
        resolvedMentions: MentionParseResult? = nil
    ) -> [(member: GroupMember, intent: GroupSpeechIntent, explicitMention: Bool)] {
        guard !activeMembers.isEmpty else { return [] }
        let mentions = resolvedMentions ?? extractMentions(in: userText, activeMembers: activeMembers)

        if mentions.mentionsAll {
            return mentions.members.enumerated().map { idx, m in
                let intent: GroupSpeechIntent = idx == 0 ? .openPerspective : (idx % 2 == 1 ? .rebuttal : .alternative)
                return (m, intent, true)
            }
        }

        if !mentions.members.isEmpty {
            return mentions.members.enumerated().map { idx, m in
                let intent: GroupSpeechIntent = idx == 0 ? .openPerspective : .rebuttal
                return (m, intent, true)
            }
        }

        switch speakingMode {
        case .mentionOnly:
            return []

        case .roundRobin:
            let lastSpeakerID = priorMessages.last(where: { $0.role == .assistant })?.assistanceMetadata.groupMemberID
            let startOffset: Int
            if let lastSpeakerID, let lastIdx = activeMembers.firstIndex(where: { $0.id == lastSpeakerID }) {
                startOffset = (lastIdx + 1) % activeMembers.count
            } else {
                startOffset = 0
            }
            return (0..<activeMembers.count).map { step in
                let member = activeMembers[(startOffset + step) % activeMembers.count]
                let intent: GroupSpeechIntent
                switch step {
                case 0: intent = .openPerspective
                case 1: intent = .rebuttal
                case activeMembers.count - 1 where activeMembers.count >= 3: intent = .mediate
                default: intent = .alternative
                }
                return (member, intent, false)
            }

        case .smartRelay:
            let lastSpeakerID = priorMessages.last(where: { $0.role == .assistant })?.assistanceMetadata.groupMemberID
            let ranked = rankMembersByRelevance(
                query: userText,
                members: activeMembers,
                penalizingMemberID: lastSpeakerID
            )
            guard !ranked.isEmpty else { return [] }
            let count = min(max(maxRelayTurns, 1), activeMembers.count)
            return Array(ranked.prefix(count)).enumerated().map { idx, m in
                let intent: GroupSpeechIntent = idx == 0 ? .openPerspective : (idx == 1 ? .rebuttal : .alternative)
                return (m, intent, false)
            }
        }
    }

    static func selectNextRelaySpeaker(
        after speaker: GroupMember,
        visibleReply: String,
        directive: GroupTurnDirective,
        activeMembers: [GroupMember],
        spokenMemberIDs: Set<UUID>,
        turnsCompleted: Int,
        maxRelayTurns: Int,
        speakingMode: GroupSpeakingMode
    ) -> (member: GroupMember, intent: GroupSpeechIntent)? {
        guard turnsCompleted < maxRelayTurns else { return nil }
        if directive.asksHost || directive.nextTargetRaw?.uppercased() == "HOST" {
            return nil
        }

        // 1. Explicit inline @mention from the AI speaker takes highest priority!
        let inlineMentions = extractMentions(in: visibleReply, activeMembers: activeMembers)
        if let calledPeer = inlineMentions.members.first(where: { $0.id != speaker.id }) {
            let intent = directive.suggestedIntent ?? .rebuttal
            return (calledPeer, intent)
        }

        if speakingMode == .mentionOnly {
            return nil
        }

        // 2. Tail-tag `next` directive
        if let rawNext = directive.nextTargetRaw {
            if rawNext.uppercased() == "NONE" && turnsCompleted >= 2 {
                return nil
            }
            let cleaned = rawNext.hasPrefix("@") ? rawNext : "@\(rawNext)"
            let tagMentions = extractMentions(in: cleaned, activeMembers: activeMembers)
            if let nextPeer = tagMentions.members.first(where: { $0.id != speaker.id && !spokenMemberIDs.contains($0.id) }) {
                let fallbackIntent: GroupSpeechIntent = (turnsCompleted + 1 == maxRelayTurns && turnsCompleted >= 2) ? .mediate : .rebuttal
                return (nextPeer, directive.suggestedIntent ?? fallbackIntent)
            }
        }

        // 3. Complementary unvisited speaker in the room
        let remaining = activeMembers.filter { !spokenMemberIDs.contains($0.id) && $0.id != speaker.id }
        guard let nextMember = rankMembersByRelevance(query: visibleReply, members: remaining, penalizingMemberID: speaker.id).first else {
            return nil
        }

        let defaultIntent: GroupSpeechIntent
        if turnsCompleted == 1 {
            defaultIntent = .rebuttal
        } else if turnsCompleted + 1 >= maxRelayTurns {
            defaultIntent = .mediate
        } else {
            defaultIntent = .alternative
        }
        return (nextMember, directive.suggestedIntent ?? defaultIntent)
    }

    static func resolveReplyQuote(
        for speaker: GroupMember,
        visibleReply: String,
        directive: GroupTurnDirective,
        intent: GroupSpeechIntent,
        roundMessages: [ChatMessage],
        activeMembers: [GroupMember]
    ) -> (messageID: UUID, speakerName: String, excerpt: String)? {
        let peerMessages = roundMessages.filter {
            $0.role == .assistant
                && $0.assistanceMetadata.groupMemberID != speaker.id
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !peerMessages.isEmpty else { return nil }

        // If speaker @mentioned a specific peer who already spoke in this round, quote that peer!
        let mentions = extractMentions(in: visibleReply, activeMembers: activeMembers)
        if let mentionedPeer = mentions.members.first(where: { $0.id != speaker.id }),
           let targetMsg = peerMessages.last(where: { $0.assistanceMetadata.groupMemberID == mentionedPeer.id }) {
            return makeQuoteTuple(from: targetMsg)
        }

        if let rawReply = directive.replyTargetRaw, !rawReply.isEmpty, rawReply.uppercased() != "NONE" {
            if rawReply.uppercased() == "LAST", let lastPeer = peerMessages.last {
                return makeQuoteTuple(from: lastPeer)
            }
            let tagMentions = extractMentions(in: rawReply.hasPrefix("@") ? rawReply : "@\(rawReply)", activeMembers: activeMembers)
            if let mentionedPeer = tagMentions.members.first,
               let targetMsg = peerMessages.last(where: { $0.assistanceMetadata.groupMemberID == mentionedPeer.id }) {
                return makeQuoteTuple(from: targetMsg)
            }
        }

        if intent == .rebuttal || intent == .probeDetail, let lastPeer = peerMessages.last {
            return makeQuoteTuple(from: lastPeer)
        }

        return nil
    }

    private static func makeQuoteTuple(from msg: ChatMessage) -> (messageID: UUID, speakerName: String, excerpt: String) {
        let speaker = msg.assistanceMetadata.groupSpeakerDisplayTitle ?? msg.modelDisplayName
        let singleLine = msg.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = singleLine.count > 56 ? String(singleLine.prefix(56)) + "…" : singleLine
        return (msg.id, speaker, excerpt)
    }

    /// Splits a short conversational 2-paragraph response into 2 consecutive chat bubbles
    /// when appropriate (no code blocks, no headings/tables, concise total length).
    static func splitShortBubbles(
        _ text: String,
        style: GroupSpeechStyle,
        enabled: Bool,
        intent: GroupSpeechIntent
    ) -> [String] {
        guard enabled,
              style == .naturalShort,
              intent != .summarize,
              intent != .vote,
              text.count <= 280,
              !text.contains("```"),
              !text.contains("\n#"),
              !text.hasPrefix("#"),
              !text.contains("| ---") else {
            return [text]
        }

        let parts = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count == 2,
              parts[0].count >= 4, parts[0].count <= 160,
              parts[1].count >= 4, parts[1].count <= 180 else {
            return [text]
        }
        return parts
    }

    static func pickBystanderReaction(
        emojiHint: String?,
        excludingMemberIDs: Set<UUID>,
        activeMembers: [GroupMember]
    ) -> GroupReaction? {
        guard let emoji = emojiHint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !emoji.isEmpty,
              let bystander = activeMembers.first(where: { !excludingMemberIDs.contains($0.id) }) else {
            return nil
        }
        return GroupReaction(
            memberID: bystander.id,
            memberName: bystander.name,
            memberEmoji: bystander.avatarEmoji,
            emoji: emoji
        )
    }

    private static func rankMembersByRelevance(
        query: String,
        members: [GroupMember],
        penalizingMemberID: UUID?
    ) -> [GroupMember] {
        let q = query.lowercased()
        let scored = members.enumerated().map { index, member -> (index: Int, score: Int, member: GroupMember) in
            var score = 0
            let profile = "\(member.name) \(member.title) \(member.rolePrompt)".lowercased()

            // Tokenize Chinese 2-char bigrams & ASCII words from profile against query
            let asciiWords = profile
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
            for word in Set(asciiWords) where q.contains(word) {
                score += 6
            }

            let cjkScalars = Array(q.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF })
            if cjkScalars.count >= 2 {
                for i in 0..<(min(cjkScalars.count - 1, 60)) {
                    let bigram = String(String.UnicodeScalarView([cjkScalars[i], cjkScalars[i + 1]]))
                    if profile.contains(bigram) {
                        score += 4
                    }
                }
            }

            if member.id == penalizingMemberID {
                score -= 5
            }
            return (index, score, member)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.index < rhs.index
            }
            .map(\.member)
    }
}
