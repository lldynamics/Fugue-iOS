import Foundation

struct AssistanceSettings: Codable, Equatable {
    var usePersonalMemory = false
    var automaticRouting = false
    var imageTarget: ResolvedModelTarget?
    var codeTarget: ResolvedModelTarget?
    var fallbackEnabled = false
    var fallbackTargets: [ResolvedModelTarget] = []
    var fallbackOnExtendedErrors = false
    var enablePromptCaching = true
    var enableAgentTools = false
    var enableNativeGrounding = false
    var autoGenerateTitle = false
    var knowledgeVolumeIDs: [UUID] = []
    var isGroupMode = false
    var bookFriend: BookFriend?
    var privatePersona: GroupMember?
    var companionBookID: UUID?
    var groupMembers: [GroupMember] = []
    var groupSpeakingMode: GroupSpeakingMode = .smartRelay
    var groupSpeechStyle: GroupSpeechStyle = .naturalShort
    var groupMaxRelayTurns: Int = 3
    var groupSplitShortBubbles = true

    init(
        usePersonalMemory: Bool = false,
        automaticRouting: Bool = false,
        imageTarget: ResolvedModelTarget? = nil,
        codeTarget: ResolvedModelTarget? = nil,
        fallbackEnabled: Bool = false,
        fallbackTargets: [ResolvedModelTarget] = [],
        enablePromptCaching: Bool = true,
        enableAgentTools: Bool = false,
        autoGenerateTitle: Bool = false,
        isGroupMode: Bool = false,
        groupMembers: [GroupMember] = [],
        groupSpeakingMode: GroupSpeakingMode = .smartRelay,
        groupSpeechStyle: GroupSpeechStyle = .naturalShort,
        groupMaxRelayTurns: Int = 3,
        groupSplitShortBubbles: Bool = true
    ) {
        self.usePersonalMemory = usePersonalMemory
        self.automaticRouting = automaticRouting
        self.imageTarget = imageTarget
        self.codeTarget = codeTarget
        self.fallbackEnabled = fallbackEnabled
        self.fallbackTargets = fallbackTargets
        self.enablePromptCaching = enablePromptCaching
        self.enableAgentTools = enableAgentTools
        self.autoGenerateTitle = autoGenerateTitle
        self.isGroupMode = isGroupMode
        self.groupMembers = groupMembers
        self.groupSpeakingMode = groupSpeakingMode
        self.groupSpeechStyle = groupSpeechStyle
        self.groupMaxRelayTurns = groupMaxRelayTurns
        self.groupSplitShortBubbles = groupSplitShortBubbles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        usePersonalMemory = try c.decodeIfPresent(Bool.self, forKey: .usePersonalMemory) ?? false
        automaticRouting = try c.decodeIfPresent(Bool.self, forKey: .automaticRouting) ?? false
        imageTarget = try c.decodeIfPresent(ResolvedModelTarget.self, forKey: .imageTarget)
        codeTarget = try c.decodeIfPresent(ResolvedModelTarget.self, forKey: .codeTarget)
        fallbackEnabled = try c.decodeIfPresent(Bool.self, forKey: .fallbackEnabled) ?? false
        fallbackTargets = try c.decodeIfPresent([ResolvedModelTarget].self, forKey: .fallbackTargets) ?? []
        fallbackOnExtendedErrors = try c.decodeIfPresent(Bool.self, forKey: .fallbackOnExtendedErrors) ?? false
        enablePromptCaching = try c.decodeIfPresent(Bool.self, forKey: .enablePromptCaching) ?? true
        enableAgentTools = try c.decodeIfPresent(Bool.self, forKey: .enableAgentTools) ?? false
        enableNativeGrounding = try c.decodeIfPresent(Bool.self, forKey: .enableNativeGrounding) ?? false
        autoGenerateTitle = try c.decodeIfPresent(Bool.self, forKey: .autoGenerateTitle) ?? false
        knowledgeVolumeIDs = try c.decodeIfPresent([UUID].self, forKey: .knowledgeVolumeIDs) ?? []
        isGroupMode = try c.decodeIfPresent(Bool.self, forKey: .isGroupMode) ?? false
        bookFriend = try c.decodeIfPresent(BookFriend.self, forKey: .bookFriend)
        privatePersona = try c.decodeIfPresent(GroupMember.self, forKey: .privatePersona)
        companionBookID = try c.decodeIfPresent(UUID.self, forKey: .companionBookID)
        groupMembers = try c.decodeIfPresent([GroupMember].self, forKey: .groupMembers) ?? []
        groupSpeakingMode = try c.decodeIfPresent(GroupSpeakingMode.self, forKey: .groupSpeakingMode) ?? .smartRelay
        groupSpeechStyle = try c.decodeIfPresent(GroupSpeechStyle.self, forKey: .groupSpeechStyle) ?? .naturalShort
        groupMaxRelayTurns = min(max(try c.decodeIfPresent(Int.self, forKey: .groupMaxRelayTurns) ?? 3, 1), 10)
        groupSplitShortBubbles = try c.decodeIfPresent(Bool.self, forKey: .groupSplitShortBubbles) ?? true
    }
}

struct GenerationOptions: Equatable, Sendable {
    var omitMemory = false
    var omitKnowledge = false
    var searchQuery: String?
    var quotedExcerpt: String?
    var overrideTarget: ResolvedModelTarget?
    var pickedMentions: [PickedGroupMention] = []
    var authorizedGroupMentions: GroupDiscussionCoordinator.MentionParseResult?
}

struct ComposerRequestOptions: Equatable {
    var useSearch = false
    var searchQuery = ""
    var omitMemory = false
    var omitKnowledge = false
    var temporaryTarget: ResolvedModelTarget?

    mutating func setSearch(_ enabled: Bool, draft: String) {
        useSearch = enabled
        if enabled && searchQuery.isEmpty {
            searchQuery = String(draft.prefix(400))
        }
    }

    func forSend(in chat: Conversation, quote: String?) -> GenerationOptions {
        GenerationOptions(
            omitMemory: omitMemory && chat.assistanceSettings.usePersonalMemory,
            omitKnowledge: omitKnowledge && !chat.assistanceSettings.knowledgeVolumeIDs.isEmpty,
            searchQuery: useSearch ? searchQuery : nil,
            quotedExcerpt: quote,
            overrideTarget: chat.isArenaMode || chat.isGroupMode ? nil : temporaryTarget
        )
    }

    mutating func finishSend(_ outcome: SendOutcome, draftUnchanged: Bool) {
        if outcome == .sent && draftUnchanged { self = Self() }
    }
}

struct MessageRevision: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var content: String
    var reasoningContent: String
    var attachments: [MessageAttachment] = []
    var providerID: UUID?
    var providerName: String
    var modelID: String
    var modelDisplayName: String
    var accentHex: String
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int?
    var latencyMs: Int?
    var thinkingDurationMs: Int?
    var personaExcerpts: [PersonaExcerpt]?
    var privateSpeaker: PersonaByline?
    var knowledgeEvidence: KnowledgeEvidence?
    var bookReply: BookReplyEvidence?
    var isPersonaSimulation = false
    var finishReason: String?
    var createdAt: Date

    var hasContent: Bool { !content.isEmpty || !reasoningContent.isEmpty || !attachments.isEmpty }

    func representsSameReply(as other: Self) -> Bool {
        content == other.content && reasoningContent == other.reasoningContent &&
        attachments == other.attachments && (providerID == nil || other.providerID == nil || providerID == other.providerID) &&
        (modelID.isEmpty || other.modelID.isEmpty || modelID == other.modelID) &&
        (privateSpeaker == nil || other.privateSpeaker == nil || privateSpeaker == other.privateSpeaker) &&
        (knowledgeEvidence == nil || other.knowledgeEvidence == nil || knowledgeEvidence == other.knowledgeEvidence) &&
        bookReply == other.bookReply && personaExcerpts == other.personaExcerpts && isPersonaSimulation == other.isPersonaSimulation
    }

    init(
        id: UUID = UUID(),
        content: String,
        reasoningContent: String,
        attachments: [MessageAttachment] = [],
        providerID: UUID? = nil,
        providerName: String,
        modelID: String,
        modelDisplayName: String,
        accentHex: String,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedTokens: Int? = nil,
        latencyMs: Int? = nil,
        thinkingDurationMs: Int? = nil,
        finishReason: String? = nil,
        isPersonaSimulation: Bool = false,
        bookReply: BookReplyEvidence? = nil,
        personaExcerpts: [PersonaExcerpt]? = nil,
        privateSpeaker: PersonaByline? = nil,
        knowledgeEvidence: KnowledgeEvidence? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.content = content
        self.reasoningContent = reasoningContent
        self.attachments = attachments
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.accentHex = accentHex
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens
        self.latencyMs = latencyMs
        self.thinkingDurationMs = thinkingDurationMs
        self.finishReason = finishReason
        self.isPersonaSimulation = isPersonaSimulation
        self.bookReply = bookReply
        self.personaExcerpts = personaExcerpts
        self.privateSpeaker = privateSpeaker
        self.knowledgeEvidence = knowledgeEvidence
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoningContent = try c.decodeIfPresent(String.self, forKey: .reasoningContent) ?? ""
        attachments = try c.decodeIfPresent([MessageAttachment].self, forKey: .attachments) ?? []
        providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName) ?? ""
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        modelDisplayName = try c.decodeIfPresent(String.self, forKey: .modelDisplayName) ?? ""
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? "#3F6EF6"
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        cachedTokens = try c.decodeIfPresent(Int.self, forKey: .cachedTokens)
        latencyMs = try c.decodeIfPresent(Int.self, forKey: .latencyMs)
        thinkingDurationMs = try c.decodeIfPresent(Int.self, forKey: .thinkingDurationMs)
        privateSpeaker = try c.decodeIfPresent(PersonaByline.self, forKey: .privateSpeaker)
        knowledgeEvidence = try c.decodeIfPresent(KnowledgeEvidence.self, forKey: .knowledgeEvidence)
        personaExcerpts = try c.decodeIfPresent([PersonaExcerpt].self, forKey: .personaExcerpts)
        bookReply = try c.decodeIfPresent(BookReplyEvidence.self, forKey: .bookReply)
        isPersonaSimulation = try c.decodeIfPresent(Bool.self, forKey: .isPersonaSimulation) ?? false
        finishReason = try c.decodeIfPresent(String.self, forKey: .finishReason)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct ToolCallRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var argumentsSummary: String
    var resultSummary: String
    var succeeded: Bool
}

struct AssistanceMetadata: Codable {
    var memoryCount = 0
    var omittedMemory = false
    var omittedKnowledge = false
    var requestedSearchQuery: String?
    var search: SearchEvidence?
    var routeNotice: String?
    var fallbackNotices: [String] = []
    var isContextDivider = false
    var isExcludedFromContext = false
    var isBookmarked = false
    var quotedExcerpt: String?
    var revisions: [MessageRevision] = []
    var activeRevisionIndex: Int?
    var proposedMemories: [String] = []
    var handledMemories: [String] = []
    var toolCalls: [ToolCallRecord] = []
    var groupMemberID: UUID?
    var groupMemberName: String?
    var groupMemberTitle: String?
    var groupMemberEmoji: String?
    var privateSpeaker: PersonaByline?
    var isPersonaSimulation = false
    var personaExcerpts: [PersonaExcerpt]?
    var bookReply: BookReplyEvidence?
    var sourceNotice: GroupSourceNotice?
    var groupSpeechIntent: GroupSpeechIntent?
    var groupReplyToMessageID: UUID?
    var groupReplyToSpeaker: String?
    var groupReplyToExcerpt: String?
    var groupReactions: [GroupReaction] = []
    var groupAskedHost = false
    var knowledgeEvidence: KnowledgeEvidence?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memoryCount = try c.decodeIfPresent(Int.self, forKey: .memoryCount) ?? 0
        omittedMemory = try c.decodeIfPresent(Bool.self, forKey: .omittedMemory) ?? false
        omittedKnowledge = try c.decodeIfPresent(Bool.self, forKey: .omittedKnowledge) ?? false
        requestedSearchQuery = try c.decodeIfPresent(String.self, forKey: .requestedSearchQuery)
        search = try c.decodeIfPresent(SearchEvidence.self, forKey: .search)
        routeNotice = try c.decodeIfPresent(String.self, forKey: .routeNotice)
        fallbackNotices = try c.decodeIfPresent([String].self, forKey: .fallbackNotices) ?? []
        isContextDivider = try c.decodeIfPresent(Bool.self, forKey: .isContextDivider) ?? false
        isExcludedFromContext = try c.decodeIfPresent(Bool.self, forKey: .isExcludedFromContext) ?? false
        isBookmarked = try c.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        quotedExcerpt = try c.decodeIfPresent(String.self, forKey: .quotedExcerpt)
        revisions = try c.decodeIfPresent([MessageRevision].self, forKey: .revisions) ?? []
        activeRevisionIndex = try c.decodeIfPresent(Int.self, forKey: .activeRevisionIndex)
        proposedMemories = try c.decodeIfPresent([String].self, forKey: .proposedMemories) ?? []
        handledMemories = try c.decodeIfPresent([String].self, forKey: .handledMemories) ?? []
        toolCalls = try c.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
        groupMemberID = try c.decodeIfPresent(UUID.self, forKey: .groupMemberID)
        groupMemberName = try c.decodeIfPresent(String.self, forKey: .groupMemberName)
        groupMemberTitle = try c.decodeIfPresent(String.self, forKey: .groupMemberTitle)
        groupMemberEmoji = try c.decodeIfPresent(String.self, forKey: .groupMemberEmoji)
        privateSpeaker = try c.decodeIfPresent(PersonaByline.self, forKey: .privateSpeaker)
        isPersonaSimulation = try c.decodeIfPresent(Bool.self, forKey: .isPersonaSimulation) ?? false
        personaExcerpts = try c.decodeIfPresent([PersonaExcerpt].self, forKey: .personaExcerpts)
        bookReply = try c.decodeIfPresent(BookReplyEvidence.self, forKey: .bookReply)
        sourceNotice = try c.decodeIfPresent(GroupSourceNotice.self, forKey: .sourceNotice)
        groupSpeechIntent = try c.decodeIfPresent(GroupSpeechIntent.self, forKey: .groupSpeechIntent)
        groupReplyToMessageID = try c.decodeIfPresent(UUID.self, forKey: .groupReplyToMessageID)
        groupReplyToSpeaker = try c.decodeIfPresent(String.self, forKey: .groupReplyToSpeaker)
        groupReplyToExcerpt = try c.decodeIfPresent(String.self, forKey: .groupReplyToExcerpt)
        groupReactions = try c.decodeIfPresent([GroupReaction].self, forKey: .groupReactions) ?? []
        groupAskedHost = try c.decodeIfPresent(Bool.self, forKey: .groupAskedHost) ?? false
        knowledgeEvidence = try c.decodeIfPresent(KnowledgeEvidence.self, forKey: .knowledgeEvidence)
    }

    var groupSpeakerName: String? {
        guard let name = groupMemberName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        let title = groupMemberTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? name : "\(title)·\(name)"
    }

    var groupSpeakerDisplayTitle: String? {
        guard let label = groupSpeakerName else { return nil }
        return isPersonaSimulation ? String(localized: "\(label) · AI 模拟") : label
    }

    func speakerByline(privateProfile: GroupMember?, accentHex: String) -> PersonaByline? {
        if let label = groupSpeakerName { return PersonaByline(label: label, emoji: groupMemberEmoji, accentHex: accentHex) }
        guard isPersonaSimulation, bookReply == nil else { return nil }
        return privateSpeaker ?? privateProfile.map(PersonaByline.init)
    }

    mutating func appendPersonaExcerpts(_ excerpts: [PersonaExcerpt]) {
        var used = personaExcerpts ?? []
        for excerpt in excerpts where !used.contains(excerpt) { used.append(excerpt) }
        personaExcerpts = used.isEmpty ? nil : used
    }

    var hasPersistedContent: Bool {
        memoryCount > 0 || omittedMemory || omittedKnowledge || requestedSearchQuery != nil || search != nil ||
        routeNotice != nil || !fallbackNotices.isEmpty || isContextDivider || isExcludedFromContext ||
        isBookmarked || quotedExcerpt != nil || !revisions.isEmpty || activeRevisionIndex != nil ||
        !proposedMemories.isEmpty || !handledMemories.isEmpty || !toolCalls.isEmpty ||
        isPersonaSimulation || personaExcerpts?.isEmpty == false || bookReply != nil || sourceNotice != nil || groupMemberID != nil || groupMemberName != nil || groupReplyToExcerpt != nil ||
        !groupReactions.isEmpty || groupAskedHost || groupSpeechIntent != nil || knowledgeEvidence != nil
    }
}

enum AssistancePolicy {
    @MainActor
    static func resolve(_ target: ResolvedModelTarget, providers: [ProviderConfig], requiresVision: Bool = false) -> ResolvedModelTarget? {
        guard let provider = providers.first(where: { $0.id == target.providerID && $0.isEnabled && !$0.isDeleted }),
              let spec = provider.enabledModels.first(where: { $0.id == target.modelID }),
              !requiresVision || spec.supportsVision else { return nil }
        return provider.makeTarget(for: spec)
    }

    static func isCode(text: String, attachments: [MessageAttachment]) -> Bool {
        if text.contains("```") { return true }
        let extensions = Set(["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "kt", "c", "cpp", "h", "cs", "sql", "sh"])
        return attachments.contains { extensions.contains(($0.fileName as NSString).pathExtension.lowercased()) }
    }

    @MainActor
    static func route(primary: ResolvedModelTarget, settings: AssistanceSettings, text: String,
                      attachments: [MessageAttachment], providers: [ProviderConfig]) -> ResolvedModelTarget? {
        guard settings.automaticRouting else { return resolve(primary, providers: providers) }
        if attachments.contains(where: { $0.kind == .image }) {
            return resolve(settings.imageTarget ?? primary, providers: providers, requiresVision: true)
        }
        if isCode(text: text, attachments: attachments), let code = settings.codeTarget {
            return resolve(code, providers: providers)
        }
        return resolve(primary, providers: providers)
    }

    static let maxFallbackTargets = 5

    @MainActor
    static func fallbacks(after primary: ResolvedModelTarget, settings: AssistanceSettings,
                          providers: [ProviderConfig], requiresVision: Bool) -> [ResolvedModelTarget] {
        guard settings.fallbackEnabled else { return [] }
        var seen: Set<String> = [primary.id]
        return settings.fallbackTargets.prefix(maxFallbackTargets).compactMap { candidate in
            guard let resolved = resolve(candidate, providers: providers, requiresVision: requiresVision),
                  seen.insert(resolved.id).inserted else { return nil }
            return resolved
        }
    }

    static func mayFallback(
        _ error: Error,
        receivedOutput: Bool,
        abnormalFinish: Bool,
        includeExtendedErrors: Bool = false
    ) -> Bool {
        guard !receivedOutput, !abnormalFinish, !(error is CancellationError) else { return false }
        if case LLMError.httpError(let status, _) = error {
            if [429, 502, 503, 504, 529].contains(status) { return true }
            if includeExtendedErrors && [402, 404, 500].contains(status) { return true }
            return false
        }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut
    }
}
