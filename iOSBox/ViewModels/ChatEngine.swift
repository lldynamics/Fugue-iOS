import Foundation
import SwiftData
import Observation
import UIKit

/// Result of attempting to send a user message. Callers should only clear the
/// composer when the outcome is `.sent`, so user input is never silently lost.
enum SendOutcome: Equatable {
    case sent
    case emptyInput
    case busy
    case noAvailableModel
    case invalidSearch
    case saveFailed
}

@MainActor
@Observable
final class ChatEngine {
    static let shared = ChatEngine()

    struct PendingWebpageApproval: Identifiable, Equatable {
        let id = UUID()
        let conversationID: UUID
        let url: URL
        var host: String { url.host ?? url.absoluteString }
    }

    struct ActiveGeneration {
        let token: UUID
        let task: Task<Void, Never>
        let context: ModelContext
    }

    struct BookTurn {
        let friend: BookFriend
        let question: String
        var memberID: UUID? = nil

        @MainActor func matches(_ chat: Conversation, target: ResolvedModelTarget?) -> Bool {
            guard let memberID else { return chat.activeBookFriend == friend }
            guard chat.isGroupMode, let member = chat.activeGroupMembers.first(where: { $0.id == memberID }) else { return false }
            return member.bookFriend == friend && member.target.id == target?.id
        }
    }

    func bookQuestion(in messages: [ChatMessage]) -> String {
        guard let question = messages.last(where: { $0.role == .user && !$0.assistanceMetadata.isExcludedFromContext }) else { return "" }
        return Self.promptContent(question.content, quotedExcerpt: question.assistanceMetadata.quotedExcerpt)
    }

    struct StreamSlot {
        let message: ChatMessage
        let candidates: [ResolvedModelTarget]
        let kind: RequestKind
        let systemPromptOverride: String?
        var temperatureOverride: Double? = nil
        var appendToExisting: Bool = false
        var tools: [LLMToolDefinition] = []
        var groupSanitizer: GroupStreamSanitizer? = nil
        var bookTurn: BookTurn? = nil
    }

    @ObservationIgnored var activeGenerations: [UUID: ActiveGeneration] = [:]
    @ObservationIgnored var activeTitleTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored let search: @Sendable (String) async throws -> SearchEvidence
    @ObservationIgnored let stream: @Sendable (LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    @ObservationIgnored let webpageReader: @Sendable (URL) async throws -> ReadablePage
    @ObservationIgnored let persistNewTurn: (ModelContext) throws -> Void
    @ObservationIgnored var customWebpageApprovalHandler: (@MainActor (URL, UUID) async -> WebpageApprovalDecision)?
    @ObservationIgnored var approvedWebpageHostsByConversation: [UUID: Set<String>] = [:]
    @ObservationIgnored var pendingWebpageContinuations: [UUID: CheckedContinuation<WebpageApprovalDecision, Never>] = [:]

    /// Conversations whose generation has not fully unwound yet (including while stopping).
    var activeConversationIDs: Set<UUID> = []
    /// Live speaker indicator (`"🧑‍💻 毒舌架构师·老王"`) while a group member has the floor.
    var activeGroupSpeakers: [UUID: String] = [:]
    /// Assistant messages currently generating inline flashcards or quizzes.
    var generatingStudyMessageIDs: Set<UUID> = []
    /// Active prompt asking the user to approve an unrequested external `read_webpage` call.
    var pendingWebpageApproval: PendingWebpageApproval?

    convenience init(
        stream: @escaping @Sendable (LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> = { LLMClient.streamChat($0) }
    ) {
        self.init(search: { try await Self.defaultSearch($0) }, stream: stream, webpageReader: { url in
            try AppCompliance.requireConsent()
            return try await URLReader.read(url)
        })
    }

    init(
        search: @escaping @Sendable (String) async throws -> SearchEvidence,
        persistNewTurn: @escaping (ModelContext) throws -> Void = { try $0.save() },
        stream: @escaping @Sendable (LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> = { LLMClient.streamChat($0) },
        webpageReader: @escaping @Sendable (URL) async throws -> ReadablePage = { url in try await URLReader.read(url) },
        webpageApprovalHandler: (@MainActor (URL, UUID) async -> WebpageApprovalDecision)? = nil
    ) {
        self.persistNewTurn = persistNewTurn
        self.search = search
        self.stream = stream
        self.webpageReader = webpageReader
        self.customWebpageApprovalHandler = webpageApprovalHandler
    }

    nonisolated private static func defaultSearch(_ query: String) async throws -> SearchEvidence {
        try AppCompliance.requireConsent()
        let key = KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount)
        return try await TavilySearchClient.search(query: query, apiKey: key)
    }

    func isGenerating(in conversationID: UUID) -> Bool {
        activeConversationIDs.contains(conversationID)
    }

    func activeGroupSpeaker(in conversationID: UUID) -> String? {
        activeGroupSpeakers[conversationID]
    }

    func stopGeneration(for conversationID: UUID) {
        if let pending = pendingWebpageApproval, pending.conversationID == conversationID {
            resolvePendingWebpageApproval(id: pending.id, decision: .deny, rememberHost: false)
        }
        activeGenerations[conversationID]?.task.cancel()
        activeTitleTasks[conversationID]?.cancel()
    }

    func stopGenerationAndWait(for conversationID: UUID) async {
        if let pending = pendingWebpageApproval, pending.conversationID == conversationID {
            resolvePendingWebpageApproval(id: pending.id, decision: .deny, rememberHost: false)
        }
        if let generation = activeGenerations[conversationID] {
            generation.task.cancel()
            await generation.task.value
        }
        if let titleTask = activeTitleTasks[conversationID] {
            titleTask.cancel()
            await titleTask.value
        }
    }

    func availableTargets(from providers: [ProviderConfig]) -> [ResolvedModelTarget] {
        ProviderConfig.readyTargets(in: providers)
    }

    struct SendTargets {
        let candidates: [[ResolvedModelTarget]]
        let routeNotice: String?
    }

    /// Used by both the disclosure and the send path, including routing and fallback.
    func sendTargets(text: String, attachments: [MessageAttachment], in conversation: Conversation,
                     providers: [ProviderConfig], kind: RequestKind = .answer, override: ResolvedModelTarget? = nil) -> SendTargets? {
        let requiresVision = attachments.contains { $0.kind == .image }
        var routeNotice: String?
        let slotsTargets: [[ResolvedModelTarget]]

        if conversation.isGroupMode {
            let groupResolved = conversation.activeGroupMembers.compactMap { member in
                AssistancePolicy.resolve(member.target, providers: providers)
            }
            guard !groupResolved.isEmpty else { return nil }
            var unique: [ResolvedModelTarget] = []
            var seen = Set<String>()
            for t in groupResolved where seen.insert(t.id).inserted {
                unique.append(t)
            }
            slotsTargets = unique.map { [$0] }
        } else if conversation.isArenaMode {
            let arenaResolved = conversation.arenaTargets.compactMap { target in
                AssistancePolicy.resolve(target, providers: providers)
            }
            guard arenaResolved.count >= 2 else { return nil }
            slotsTargets = arenaResolved.map { [$0] }
        } else {
            let chosenPrimary: ResolvedModelTarget
            if let override {
                guard let resolved = AssistancePolicy.resolve(override, providers: providers, requiresVision: requiresVision) else {
                    return nil
                }
                chosenPrimary = resolved
                if resolved.id != conversation.primaryTarget?.id {
                    routeNotice = String(localized: "本次指定：\(resolved.providerName) · \(resolved.modelDisplayName)")
                }
            } else {
                guard let basePrimary = conversation.primaryTarget else { return nil }

                if kind != .shortcut && conversation.assistanceSettings.automaticRouting {
                    guard let routed = AssistancePolicy.route(
                        primary: basePrimary,
                        settings: conversation.assistanceSettings,
                        text: text,
                        attachments: attachments,
                        providers: providers
                    ) else {
                        return nil
                    }
                    if routed.id != basePrimary.id {
                        routeNotice = String(localized: "已按输入类型选择：\(routed.providerName) · \(routed.modelDisplayName)")
                    }
                    chosenPrimary = routed
                } else if let live = AssistancePolicy.resolve(basePrimary, providers: providers) {
                    chosenPrimary = live
                } else {
                    let earlyBackups = kind == .shortcut ? [] : AssistancePolicy.fallbacks(
                        after: basePrimary,
                        settings: conversation.assistanceSettings,
                        providers: providers,
                        requiresVision: requiresVision
                    )
                    guard !earlyBackups.isEmpty else { return nil }
                    chosenPrimary = basePrimary
                }
            }

            let backups = kind == .shortcut ? [] : AssistancePolicy.fallbacks(
                after: chosenPrimary,
                settings: conversation.assistanceSettings,
                providers: providers,
                requiresVision: requiresVision
            )
            slotsTargets = [[chosenPrimary] + backups]
        }
        return SendTargets(candidates: slotsTargets, routeNotice: routeNotice)
    }

    @discardableResult
    func sendUserMessage(
        text: String,
        attachments: [MessageAttachment],
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext,
        kind: RequestKind = .answer,
        options: GenerationOptions = GenerationOptions()
    ) -> SendOutcome {
        sendUserMessageInternal(
            text: text,
            attachments: attachments,
            in: conversation,
            providers: providers,
            context: context,
            kind: kind,
            options: options
        )
    }

    func sendUserMessageInternal(
        text: String,
        attachments: [MessageAttachment],
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext,
        kind: RequestKind,
        options: GenerationOptions,
        editing original: ChatMessage? = nil,
        keepBranch: Bool = false
    ) -> SendOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .emptyInput }
        guard !isGenerating(in: conversation.id) else { return .busy }

        var validatedSearchQuery: String?
        if let rawSearch = options.searchQuery {
            let sq = rawSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sq.isEmpty, sq.count <= TavilySearchClient.maximumQueryCharacters else {
                return .invalidSearch
            }
            validatedSearchQuery = sq
        }

        guard let plan = sendTargets(text: trimmed, attachments: attachments, in: conversation,
                                     providers: providers, kind: kind, override: options.overrideTarget) else {
            return .noAvailableModel
        }
        guard PersistenceController.canCommitUserData(in: context) else { return .saveFailed }
        // Commit pre-existing edits first so rollback below affects only this turn.
        do {
            if context.hasChanges { try context.save() }
        } catch { return .saveFailed }

        var explicitParentID: UUID?
        if let original {
            if keepBranch {
                ConversationTree.ensureExplicitParentLinks(in: conversation)
                explicitParentID = original.parentMessageID ?? ConversationTree.virtualRootID
            } else if ConversationTree.usesTree(conversation) {
                let originalParent = original.parentMessageID ?? ConversationTree.virtualRootID
                let subtree = ConversationTree.descendantSubtree(from: original, in: conversation)
                guard !subtree.isEmpty else { return .emptyInput }
                let removedIDs = Set(subtree.map(\.id))
                conversation.messages.removeAll { removedIDs.contains($0.id) }
                for message in subtree {
                    context.delete(message)
                }
                explicitParentID = originalParent
                if let activeLeaf = conversation.activeLeafMessageID, removedIDs.contains(activeLeaf) {
                    conversation.activeLeafMessageID = originalParent == ConversationTree.virtualRootID ? nil : originalParent
                }
            } else {
                let sorted = ConversationTree.activeMessages(in: conversation)
                guard let index = sorted.firstIndex(where: { $0.id == original.id }) else { return .emptyInput }
                for message in sorted[index...] {
                    conversation.messages.removeAll { $0.id == message.id }
                    context.delete(message)
                }
            }
        }
        let slotsTargets = plan.candidates
        let isArena = slotsTargets.count > 1
        let routeNotice = plan.routeNotice
        if !isArena, options.overrideTarget == nil, conversation.primaryTarget == nil {
            conversation.primaryTarget = availableTargets(from: providers).first
        }

        let shouldUseTree = explicitParentID != nil || ConversationTree.usesTree(conversation)
        let resolvedParentID: UUID?
        if let explicitParentID {
            resolvedParentID = explicitParentID
        } else if shouldUseTree {
            resolvedParentID = ConversationTree.currentAnchorID(in: conversation) ?? ConversationTree.virtualRootID
        } else {
            resolvedParentID = nil
        }

        // Snapshot prior branch messages before appending when branching at an earlier parent.
        let priorBranchMessages: [ChatMessage]
        if let explicitParentID {
            if explicitParentID == ConversationTree.virtualRootID {
                priorBranchMessages = []
            } else {
                let savedLeaf = conversation.activeLeafMessageID
                conversation.activeLeafMessageID = explicitParentID
                priorBranchMessages = ConversationTree.activeMessages(in: conversation)
                conversation.activeLeafMessageID = savedLeaf
            }
        } else {
            priorBranchMessages = ConversationTree.activeMessages(in: conversation)
        }

        let nextSort = (conversation.sortedMessages.last?.sortIndex ?? 0) + 1
        let userMsg = ChatMessage(
            role: .user,
            content: trimmed,
            attachments: attachments,
            sortIndex: nextSort
        )
        if let quote = options.quotedExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
            var userMeta = AssistanceMetadata()
            userMeta.quotedExcerpt = String(quote.prefix(1200))
            userMsg.assistanceMetadata = userMeta
        }
        userMsg.parentMessageID = resolvedParentID
        userMsg.conversation = conversation
        conversation.messages.append(userMsg)
        context.insert(userMsg)

        let isFirstUserTurnOnBranch = !priorBranchMessages.contains(where: { $0.role == .user })
        if isFirstUserTurnOnBranch && Conversation.isDefaultTitle(conversation.title) {
            conversation.title = Self.makeConversationTitle(from: trimmed, attachments: attachments)
        }
        let titleSnapshotForAutoGen = conversation.title
        conversation.updatedAt = Date()

        let historySnapshot = buildPromptHistory(
            messages: priorBranchMessages + [userMsg],
            limit: conversation.contextMessageLimit
        )

        let memoryInfo = prepareMemory(
            conversation: conversation,
            omitMemory: options.omitMemory,
            context: context
        )

        if conversation.isGroupMode {
            if shouldUseTree {
                conversation.activeLeafMessageID = userMsg.id
            }
            guard saveNewTurn(in: context) else { return .saveFailed }
            let shouldAutoTitle = kind == .answer
                && conversation.assistanceSettings.autoGenerateTitle
                && isFirstUserTurnOnBranch
            launchGroupRelaySession(
                mode: .afterUserMessage(
                    userMessage: userMsg,
                    priorMessages: priorBranchMessages,
                    searchQuery: validatedSearchQuery,
                    omitMemory: options.omitMemory,
                    memoryInfo: memoryInfo,
                    expectedTitleForAutoGenerate: shouldAutoTitle ? titleSnapshotForAutoGen : nil
                ),
                in: conversation,
                providers: providers,
                context: context
            )
            return .sent
        }

        let toolsToAttach: [LLMToolDefinition]
        if !isArena && kind == .answer && conversation.assistanceSettings.enableAgentTools {
            let hasTavilyKey = !KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount).isEmpty
            let hasKB = !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty
            toolsToAttach = AgentToolRunner.definitions(hasTavilyKey: hasTavilyKey, hasKnowledgeBase: hasKB)
        } else {
            toolsToAttach = []
        }

        let groupID: UUID? = slotsTargets.count > 1 ? UUID() : nil
        var slots: [StreamSlot] = []

        for (idx, candidateChain) in slotsTargets.enumerated() {
            let primaryTarget = candidateChain[0]
            let replyMsg = ChatMessage(
                role: .assistant,
                target: primaryTarget,
                comparisonGroupID: groupID,
                isSelectedInGroup: idx == 0,
                isStreaming: true,
                sortIndex: nextSort + 1 + idx
            )
            if shouldUseTree {
                replyMsg.parentMessageID = userMsg.id
            }
            var meta = AssistanceMetadata()
            meta.omittedMemory = options.omitMemory && conversation.assistanceSettings.usePersonalMemory
            meta.memoryCount = memoryInfo.count
            meta.routeNotice = routeNotice
            meta.requestedSearchQuery = validatedSearchQuery
            if meta.hasPersistedContent {
                replyMsg.assistanceMetadata = meta
            }
            replyMsg.conversation = conversation
            conversation.messages.append(replyMsg)
            context.insert(replyMsg)
            slots.append(StreamSlot(
                message: replyMsg,
                candidates: candidateChain,
                kind: kind,
                systemPromptOverride: memoryInfo.systemPrompt,
                appendToExisting: false,
                tools: toolsToAttach,
                bookTurn: conversation.activeBookFriend.map { BookTurn(friend: $0, question: Self.promptContent(trimmed, quotedExcerpt: options.quotedExcerpt)) }
            ))
        }

        if shouldUseTree, let firstReply = slots.first?.message {
            conversation.activeLeafMessageID = firstReply.id
        }

        guard saveNewTurn(in: context) else { return .saveFailed }

        let shouldAutoTitle = kind == .answer
            && conversation.assistanceSettings.autoGenerateTitle
            && isFirstUserTurnOnBranch

        launchStreamingTasks(
            slots: slots,
            historySnapshot: historySnapshot,
            searchQuery: validatedSearchQuery,
            conversation: conversation,
            providers: providers,
            context: context,
            expectedTitleForAutoGenerate: shouldAutoTitle ? titleSnapshotForAutoGen : nil
        )
        return .sent
    }

    func saveNewTurn(in context: ModelContext) -> Bool {
        do {
            context.processPendingChanges()
            try persistNewTurn(context)
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    func insertContextDivider(in conversation: Conversation, context: ModelContext) {
        guard !isGenerating(in: conversation.id) else { return }
        let useTree = ConversationTree.usesTree(conversation)
        let parentID = useTree
            ? (ConversationTree.currentAnchorID(in: conversation) ?? ConversationTree.virtualRootID)
            : nil
        let nextSort = (conversation.sortedMessages.last?.sortIndex ?? 0) + 1
        let divider = ChatMessage(
            role: .system,
            content: String(localized: "已清除上文，以下开启新话题"),
            sortIndex: nextSort
        )
        var meta = AssistanceMetadata()
        meta.isContextDivider = true
        divider.assistanceMetadata = meta
        divider.parentMessageID = parentID
        divider.conversation = conversation
        conversation.messages.append(divider)
        context.insert(divider)
        if useTree {
            conversation.activeLeafMessageID = divider.id
        }
        conversation.updatedAt = Date()
        try? context.save()
    }

    func toggleContextExclusion(for message: ChatMessage, context: ModelContext) {
        var meta = message.assistanceMetadata
        meta.isExcludedFromContext.toggle()
        if meta.hasPersistedContent {
            message.assistanceMetadata = meta
        } else {
            message.assistanceMetadataData = nil
        }
        try? context.save()
    }

    func toggleBookmark(for message: ChatMessage, context: ModelContext) {
        var meta = message.assistanceMetadata
        meta.isBookmarked.toggle()
        let isBookmarkedNow = meta.isBookmarked
        if meta.hasPersistedContent {
            message.assistanceMetadata = meta
        } else {
            message.assistanceMetadataData = nil
        }
        try? context.save()
        if let conv = message.conversation {
            if !isBookmarkedNow {
                SpotlightIndexService.shared.removeMessage(conversationID: conv.id, messageID: message.id)
            }
            SpotlightIndexService.shared.indexConversation(conv)
        }
    }

    /// Updates an earlier user turn, optionally preserving the old branch as a sibling, and regenerates fresh answers.
    @discardableResult
    func editUserMessageAndResend(
        userMessage: ChatMessage,
        newText: String,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext,
        keepBranch: Bool = false
    ) async -> SendOutcome {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !userMessage.attachments.isEmpty else { return .emptyInput }
        await stopGenerationAndWait(for: conversation.id)

        let active = ConversationTree.activeMessages(in: conversation)
        guard let idx = active.firstIndex(where: { $0.id == userMessage.id }) else { return .emptyInput }

        let attachmentsSnapshot = userMessage.attachments
        let nextAssistantMeta = active[(idx + 1)...].first(where: { $0.role == .assistant })?.assistanceMetadata
        let preservedOptions = GenerationOptions(
            omitMemory: nextAssistantMeta?.omittedMemory ?? false,
            searchQuery: nextAssistantMeta?.requestedSearchQuery,
            quotedExcerpt: userMessage.assistanceMetadata.quotedExcerpt
        )

        return sendUserMessageInternal(
            text: trimmed,
            attachments: attachmentsSnapshot,
            in: conversation,
            providers: providers,
            context: context,
            kind: .answer,
            options: preservedOptions,
            editing: userMessage,
            keepBranch: keepBranch
        )
    }

    func deleteSingleMessage(
        _ message: ChatMessage,
        in conversation: Conversation,
        context: ModelContext
    ) async {
        if isGenerating(in: conversation.id) || activeTitleTasks[conversation.id] != nil {
            await stopGenerationAndWait(for: conversation.id)
        }
        let deletedID = message.id
        let convID = conversation.id
        ConversationTree.detachBeforeDeleting(message, in: conversation)
        conversation.messages.removeAll { $0.id == deletedID }
        context.delete(message)
        conversation.updatedAt = Date()
        try? context.save()
        SpotlightIndexService.shared.removeMessage(conversationID: convID, messageID: deletedID)
    }

    func selectRevision(
        index targetIndex: Int,
        for assistantMessage: ChatMessage,
        context: ModelContext
    ) {
        guard !assistantMessage.isStreaming else { return }
        var meta = assistantMessage.assistanceMetadata
        if meta.activeRevisionIndex == nil,
           (!assistantMessage.content.isEmpty || !assistantMessage.reasoningContent.isEmpty || !assistantMessage.attachments.isEmpty) {
            meta.revisions.append(Self.snapshotRevision(of: assistantMessage))
        }
        guard meta.revisions.indices.contains(targetIndex) else { return }

        let chosen = meta.revisions[targetIndex]
        meta.isPersonaSimulation = chosen.isPersonaSimulation
        meta.bookReply = chosen.bookReply
        assistantMessage.content = chosen.content
        assistantMessage.reasoningContent = chosen.reasoningContent
        assistantMessage.attachments = chosen.attachments
        assistantMessage.providerID = chosen.providerID
        assistantMessage.providerName = chosen.providerName
        assistantMessage.modelID = chosen.modelID
        assistantMessage.modelDisplayName = chosen.modelDisplayName
        assistantMessage.accentHex = chosen.accentHex
        assistantMessage.promptTokens = chosen.promptTokens
        assistantMessage.completionTokens = chosen.completionTokens
        assistantMessage.cachedTokens = chosen.cachedTokens
        assistantMessage.latencyMs = chosen.latencyMs
        assistantMessage.thinkingDurationMs = chosen.thinkingDurationMs
        assistantMessage.finishReason = chosen.finishReason
        assistantMessage.errorMessage = nil

        if targetIndex == meta.revisions.count - 1 {
            meta.revisions.removeLast()
            meta.activeRevisionIndex = nil
        } else {
            meta.activeRevisionIndex = targetIndex
        }
        assistantMessage.assistanceMetadata = meta
        try? context.save()
    }

    func replyTarget(_ message: ChatMessage, in conversation: Conversation, providers: [ProviderConfig]) -> ResolvedModelTarget? {
        guard let id = message.providerID else {
            return conversation.primaryTarget.flatMap { AssistancePolicy.resolve($0, providers: providers) }
        }
        guard let provider = providers.first(where: { $0.id == id && $0.isEnabled && !$0.isDeleted }),
              let model = provider.enabledModels.first(where: { $0.id == message.modelID }) else { return nil }
        return provider.makeTarget(for: model)
    }

    func replyPersona(for message: ChatMessage, in conversation: Conversation, target: ResolvedModelTarget) -> GroupMember? {
        let meta = message.assistanceMetadata
        if let id = meta.groupMemberID, var member = conversation.groupMembers.first(where: { $0.id == id }) {
            // An alternate model may keep the public role and AI attribution, but receives none of the bound samples.
            if member.target.id != target.id {
                member.persona = member.isSimulatedPersona ? GroupPersona() : nil
                member.bookFriend = nil
            }
            if member.persona == nil, meta.isPersonaSimulation { member.persona = GroupPersona() }
            return member
        }
        guard let name = meta.groupMemberName, !name.isEmpty else { return nil }
        var historical = GroupMember(id: meta.groupMemberID ?? UUID(), name: name, title: meta.groupMemberTitle ?? "",
                                     avatarEmoji: meta.groupMemberEmoji ?? "🤖", accentHex: message.accentHex,
                                     rolePrompt: "", target: target)
        if meta.isPersonaSimulation { historical.persona = GroupPersona() }
        return historical
    }

    func titleTarget(in conversation: Conversation, providers: [ProviderConfig]) -> ResolvedModelTarget? {
        let target = conversation.primaryTarget
            ?? conversation.activeGroupMembers.first?.target
            ?? conversation.arenaTargets.first
            ?? availableTargets(from: providers).first
        return target.flatMap { AssistancePolicy.resolve($0, providers: providers) }
    }

    func regenerate(
        assistantMessage: ChatMessage,
        overrideTarget: ResolvedModelTarget? = nil,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) {
        guard !isGenerating(in: conversation.id) else { return }
        let requested = overrideTarget ?? replyTarget(assistantMessage, in: conversation, providers: providers)
        guard let requested, let resolvedTarget = AssistancePolicy.resolve(requested, providers: providers) else { return }
        if assistantMessage.isSynthesis, let gid = assistantMessage.comparisonGroupID {
            _ = synthesize(groupID: gid, target: resolvedTarget, in: conversation, providers: providers, context: context)
            return
        }

        let active = ConversationTree.activeMessages(in: conversation)
        guard let targetIdx = active.firstIndex(where: { $0.id == assistantMessage.id }) else { return }

        let cutoffMessages = Array(active[..<targetIdx]).filter { msg in
            if let gid = assistantMessage.comparisonGroupID, msg.comparisonGroupID == gid {
                return false
            }
            return true
        }

        let prevMeta = assistantMessage.assistanceMetadata
        let groupPersona = replyPersona(for: assistantMessage, in: conversation, target: resolvedTarget)

        let historySnapshot: [LLMPromptMessage]
        if let groupPersona {
            historySnapshot = GroupDiscussionCoordinator.buildPromptHistory(
                messages: cutoffMessages,
                for: groupPersona,
                limit: conversation.contextMessageLimit
            )
        } else {
            historySnapshot = buildPromptHistory(
                messages: cutoffMessages,
                limit: conversation.contextMessageLimit
            )
        }
        guard !historySnapshot.isEmpty else { return }

        var preservedRevisions = prevMeta.revisions
        if prevMeta.activeRevisionIndex == nil,
           (!assistantMessage.content.isEmpty || !assistantMessage.reasoningContent.isEmpty || !assistantMessage.attachments.isEmpty) {
            preservedRevisions.append(Self.snapshotRevision(of: assistantMessage))
        }

        let memoryInfo = prepareMemory(
            conversation: conversation,
            omitMemory: prevMeta.omittedMemory,
            context: context
        )

        let requiresVision = historySnapshot.last?.attachments.contains(where: { $0.kind == .image }) ?? false
        let isInArena = assistantMessage.comparisonGroupID != nil
        let backups = (isInArena || groupPersona != nil) ? [] : AssistancePolicy.fallbacks(
            after: resolvedTarget,
            settings: conversation.assistanceSettings,
            providers: providers,
            requiresVision: requiresVision
        )

        let toolsToAttach: [LLMToolDefinition]
        if !isInArena && groupPersona == nil && conversation.assistanceSettings.enableAgentTools {
            let hasTavilyKey = !KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount).isEmpty
            let hasKB = !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty
            toolsToAttach = AgentToolRunner.definitions(hasTavilyKey: hasTavilyKey, hasKnowledgeBase: hasKB)
        } else {
            toolsToAttach = []
        }

        assistantMessage.providerID = resolvedTarget.providerID
        assistantMessage.providerName = resolvedTarget.providerName
        assistantMessage.modelID = resolvedTarget.modelID
        assistantMessage.modelDisplayName = resolvedTarget.modelDisplayName
        assistantMessage.accentHex = groupPersona?.accentHex ?? resolvedTarget.accentHex
        assistantMessage.content = ""
        assistantMessage.reasoningContent = ""
        assistantMessage.attachments = []
        assistantMessage.errorMessage = nil
        assistantMessage.promptTokens = nil
        assistantMessage.completionTokens = nil
        assistantMessage.cachedTokens = nil
        assistantMessage.latencyMs = nil
        assistantMessage.thinkingDurationMs = nil
        assistantMessage.finishReason = nil
        assistantMessage.isStreaming = true

        var freshMeta = AssistanceMetadata()
        freshMeta.omittedMemory = prevMeta.omittedMemory
        freshMeta.memoryCount = memoryInfo.count
        freshMeta.requestedSearchQuery = prevMeta.requestedSearchQuery
        freshMeta.isBookmarked = prevMeta.isBookmarked
        freshMeta.blindArenaRevealed = prevMeta.blindArenaRevealed
        freshMeta.blindArenaBallot = prevMeta.blindArenaBallot
        freshMeta.isExcludedFromContext = prevMeta.isExcludedFromContext
        freshMeta.revisions = preservedRevisions
        freshMeta.activeRevisionIndex = nil
        freshMeta.groupMemberID = prevMeta.groupMemberID
        freshMeta.groupMemberName = prevMeta.groupMemberName
        freshMeta.groupMemberTitle = prevMeta.groupMemberTitle
        freshMeta.groupMemberEmoji = prevMeta.groupMemberEmoji
        freshMeta.isPersonaSimulation = groupPersona?.isSimulatedPersona == true
        freshMeta.groupSpeechIntent = prevMeta.groupSpeechIntent
        freshMeta.groupReplyToMessageID = prevMeta.groupReplyToMessageID
        freshMeta.groupReplyToSpeaker = prevMeta.groupReplyToSpeaker
        freshMeta.groupReplyToExcerpt = prevMeta.groupReplyToExcerpt
        if freshMeta.hasPersistedContent {
            assistantMessage.assistanceMetadata = freshMeta
        } else {
            assistantMessage.assistanceMetadataData = nil
        }

        try? context.save()

        let effectiveSystemPrompt: String
        let tempOverride: Double?
        let sanitizer: GroupStreamSanitizer?
        if let groupPersona {
            let preferEnglish = GroupDiscussionCoordinator.prefersEnglishPrompts(in: cutoffMessages)
            effectiveSystemPrompt = GroupDiscussionCoordinator.buildSystemPrompt(
                for: groupPersona,
                activeMembers: conversation.activeGroupMembers.isEmpty ? [groupPersona] : conversation.activeGroupMembers,
                speechStyle: conversation.assistanceSettings.groupSpeechStyle,
                intent: prevMeta.groupSpeechIntent ?? .openPerspective,
                baseSystemPrompt: memoryInfo.systemPrompt,
                allowPass: false,
                preferEnglish: preferEnglish
            )
            tempOverride = groupPersona.temperature
            sanitizer = GroupStreamSanitizer(
                speakerName: groupPersona.name,
                speakerDisplayLabel: groupPersona.displayLabel
            )
        } else {
            effectiveSystemPrompt = memoryInfo.systemPrompt
            tempOverride = nil
            sanitizer = nil
        }

        let slot = StreamSlot(
            message: assistantMessage,
            candidates: [resolvedTarget] + backups,
            kind: .regeneration,
            systemPromptOverride: effectiveSystemPrompt,
            temperatureOverride: tempOverride,
            tools: toolsToAttach,
            groupSanitizer: sanitizer,
            bookTurn: (groupPersona?.bookFriend ?? conversation.activeBookFriend).map {
                BookTurn(friend: $0, question: bookQuestion(in: cutoffMessages), memberID: groupPersona?.id)
            }
        )

        launchStreamingTasks(
            slots: [slot],
            historySnapshot: historySnapshot,
            searchQuery: prevMeta.requestedSearchQuery,
            conversation: conversation,
            providers: providers,
            context: context
        )
    }

    /// Continues generating seamlessly from a length-truncated assistant response without re-running from scratch.
    func continueGeneration(
        assistantMessage: ChatMessage,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) {
        guard !isGenerating(in: conversation.id),
              !assistantMessage.isStreaming,
              !assistantMessage.content.isEmpty else {
            return
        }

        let active = ConversationTree.activeMessages(in: conversation)
        guard let targetIdx = active.firstIndex(where: { $0.id == assistantMessage.id }) else { return }

        let upToMessage = Array(active[...targetIdx]).filter { msg in
            if let gid = assistantMessage.comparisonGroupID, msg.comparisonGroupID == gid {
                return msg.id == assistantMessage.id
            }
            return true
        }

        guard let resolvedTarget = replyTarget(assistantMessage, in: conversation, providers: providers) else { return }

        let prevMeta = assistantMessage.assistanceMetadata
        let groupPersona = replyPersona(for: assistantMessage, in: conversation, target: resolvedTarget)

        let continuationCue = "Continue writing directly from the exact point where your previous message stopped. Do not repeat any text already written or add introductory remarks."
        let historySnapshot: [LLMPromptMessage]
        if let groupPersona {
            historySnapshot = GroupDiscussionCoordinator.buildPromptHistory(
                messages: upToMessage,
                for: groupPersona,
                limit: conversation.contextMessageLimit,
                trailingCueIfNeeded: continuationCue
            )
        } else {
            var built = buildPromptHistory(
                messages: upToMessage,
                limit: conversation.contextMessageLimit
            )
            guard !built.isEmpty else { return }
            built.append(LLMPromptMessage(
                role: .user,
                content: continuationCue,
                attachments: []
            ))
            historySnapshot = built
        }
        guard !historySnapshot.isEmpty else { return }

        let memoryInfo = prepareMemory(
            conversation: conversation,
            omitMemory: prevMeta.omittedMemory,
            context: context
        )

        assistantMessage.errorMessage = nil
        if groupPersona?.isSimulatedPersona == true { assistantMessage.assistanceMetadata.isPersonaSimulation = true }
        assistantMessage.finishReason = nil
        assistantMessage.isStreaming = true
        try? context.save()

        let effectiveSystemPrompt: String
        let tempOverride: Double?
        let sanitizer: GroupStreamSanitizer?
        if let groupPersona {
            let preferEnglish = GroupDiscussionCoordinator.prefersEnglishPrompts(in: upToMessage)
            effectiveSystemPrompt = GroupDiscussionCoordinator.buildSystemPrompt(
                for: groupPersona,
                activeMembers: conversation.activeGroupMembers.isEmpty ? [groupPersona] : conversation.activeGroupMembers,
                speechStyle: conversation.assistanceSettings.groupSpeechStyle,
                intent: prevMeta.groupSpeechIntent ?? .openPerspective,
                baseSystemPrompt: memoryInfo.systemPrompt,
                allowPass: false,
                preferEnglish: preferEnglish
            )
            tempOverride = groupPersona.temperature
            sanitizer = GroupStreamSanitizer(
                speakerName: groupPersona.name,
                speakerDisplayLabel: groupPersona.displayLabel,
                isContinuation: true
            )
        } else {
            effectiveSystemPrompt = memoryInfo.systemPrompt
            tempOverride = nil
            sanitizer = nil
        }

        let slot = StreamSlot(
            message: assistantMessage,
            candidates: [resolvedTarget],
            kind: .continuation,
            systemPromptOverride: effectiveSystemPrompt,
            temperatureOverride: tempOverride,
            appendToExisting: true,
            groupSanitizer: sanitizer,
            bookTurn: (groupPersona?.bookFriend ?? conversation.activeBookFriend).map {
                BookTurn(friend: $0, question: bookQuestion(in: upToMessage), memberID: groupPersona?.id)
            }
        )

        launchStreamingTasks(
            slots: [slot],
            historySnapshot: historySnapshot,
            searchQuery: nil,
            conversation: conversation,
            providers: providers,
            context: context
        )
    }

    @discardableResult
    func forkConversation(
        upTo message: ChatMessage,
        in conversation: Conversation,
        context: ModelContext
    ) -> Conversation {
        let active = ConversationTree.activeMessages(in: conversation)
        let prefixSlice: [ChatMessage]
        if let idx = active.firstIndex(where: { $0.id == message.id }) {
            prefixSlice = Array(active[...idx]).filter { candidate in
                if let gid = candidate.comparisonGroupID {
                    if candidate.id == message.id { return true }
                    if message.comparisonGroupID == gid { return false }
                    return candidate.isSelectedInGroup
                }
                return true
            }
        } else {
            prefixSlice = []
        }

        let forked = Conversation(
            title: String(localized: "\(conversation.title) · 分支"),
            isPinned: false,
            assistantID: conversation.assistantID,
            assistantEmoji: conversation.assistantEmoji,
            systemPrompt: conversation.systemPrompt,
            temperature: conversation.temperature,
            useCustomTemperature: conversation.useCustomTemperature,
            topP: conversation.topP,
            maxOutputTokens: conversation.maxOutputTokens,
            contextMessageLimit: conversation.contextMessageLimit,
            enableThinking: conversation.enableThinking,
            thinkingBudgetTokens: conversation.thinkingBudgetTokens,
            isArenaMode: false,
            primaryTarget: conversation.primaryTarget,
            arenaTargets: conversation.arenaTargets
        )
        forked.assistanceSettings = conversation.assistanceSettings
        forked.folderTag = conversation.folderTag
        context.insert(forked)

        for (index, src) in prefixSlice.enumerated() {
            let copy = ChatMessage(
                role: src.role,
                content: src.content,
                reasoningContent: src.reasoningContent,
                attachments: src.attachments,
                comparisonGroupID: nil,
                isSelectedInGroup: true,
                isStreaming: false,
                sortIndex: index,
                createdAt: src.createdAt
            )
            copy.providerID = src.providerID
            copy.providerName = src.providerName
            copy.modelID = src.modelID
            copy.modelDisplayName = src.modelDisplayName
            copy.accentHex = src.accentHex
            copy.promptTokens = src.promptTokens
            copy.completionTokens = src.completionTokens
            copy.cachedTokens = src.cachedTokens
            copy.latencyMs = src.latencyMs
            copy.thinkingDurationMs = src.thinkingDurationMs
            copy.finishReason = src.finishReason
            if src.assistanceMetadataData != nil {
                var meta = src.assistanceMetadata
                meta.revisions = []
                meta.activeRevisionIndex = nil
                meta.blindArenaBallot = nil
                meta.blindArenaRevealed = false
                if meta.hasPersistedContent {
                    copy.assistanceMetadata = meta
                }
            }
            copy.conversation = forked
            forked.messages.append(copy)
            context.insert(copy)
        }
        try? context.save()
        return forked
    }

    // MARK: - Lifecycle & Helpers

    func finishGeneration(conversationID: UUID, token: UUID) {
        guard activeGenerations[conversationID]?.token == token else { return }
        activeGenerations.removeValue(forKey: conversationID)
        activeConversationIDs.remove(conversationID)
        activeGroupSpeakers.removeValue(forKey: conversationID)
        LiveActivityCoordinator.shared.end(conversationID: conversationID, finalPhase: String(localized: "已完成"))
        updateBackgroundExecution()
    }

    func updateBackgroundExecution() {
        if activeGenerations.isEmpty && activeTitleTasks.isEmpty {
            endBackgroundTaskIfNeeded()
        } else if backgroundTaskID == .invalid {
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "iOSBox.LLMStreaming") { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleBackgroundTimeExpired()
                }
            }
        }
    }

    private func handleBackgroundTimeExpired() {
        for generation in activeGenerations.values {
            try? generation.context.save()
            generation.task.cancel()
        }
        for titleTask in activeTitleTasks.values {
            titleTask.cancel()
        }
        endBackgroundTaskIfNeeded()
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    static func snapshotRevision(of message: ChatMessage) -> MessageRevision {
        MessageRevision(
            content: message.content,
            reasoningContent: message.reasoningContent,
            attachments: message.attachments,
            providerID: message.providerID,
            providerName: message.providerName,
            modelID: message.modelID,
            modelDisplayName: message.modelDisplayName,
            accentHex: message.accentHex,
            promptTokens: message.promptTokens,
            completionTokens: message.completionTokens,
            cachedTokens: message.cachedTokens,
            latencyMs: message.latencyMs,
            thinkingDurationMs: message.thinkingDurationMs,
            finishReason: message.finishReason,
            isPersonaSimulation: message.assistanceMetadata.isPersonaSimulation,
            bookReply: message.assistanceMetadata.bookReply,
            createdAt: Date()
        )
    }

    func prepareMemory(
        conversation: Conversation,
        omitMemory: Bool,
        context: ModelContext
    ) -> (systemPrompt: String, count: Int) {
        let base = conversation.systemPrompt
        guard conversation.assistanceSettings.usePersonalMemory, !omitMemory else {
            return (base, 0)
        }
        guard let prompt = try? PersonalMemory.prompt(in: context), prompt.count > 0 else {
            return (base, 0)
        }
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = trimmedBase.isEmpty ? prompt.text : (trimmedBase + "\n\n" + prompt.text)
        return (combined, prompt.count)
    }

    static func isAlive(_ model: some PersistentModel) -> Bool {
        model.modelContext != nil && !model.isDeleted
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static let mediaTurnsToKeep = 2

    nonisolated static func promptContent(_ content: String, quotedExcerpt: String?, separator: String = "\n\n") -> String {
        guard let quote = quotedExcerpt, !quote.isEmpty else { return content }
        let quotedBlock = "> " + quote.replacingOccurrences(of: "\n", with: "\n> ")
        return content.isEmpty ? quotedBlock : quotedBlock + separator + content
    }

    func buildPromptHistory(messages: [ChatMessage], limit: Int) -> [LLMPromptMessage] {
        let afterDivider: ArraySlice<ChatMessage>
        if let lastDividerIdx = messages.lastIndex(where: { $0.assistanceMetadata.isContextDivider }) {
            afterDivider = messages[messages.index(after: lastDividerIdx)...]
        } else {
            afterDivider = messages[...]
        }

        var collapsed: [ChatMessage] = []
        var processedGroups = Set<UUID>()

        for msg in afterDivider {
            if msg.role == .system || msg.assistanceMetadata.isExcludedFromContext {
                continue
            }
            if let gid = msg.comparisonGroupID {
                guard !processedGroups.contains(gid) else { continue }
                processedGroups.insert(gid)
                let candidates = afterDivider.filter { candidate in
                    guard candidate.comparisonGroupID == gid,
                          !candidate.assistanceMetadata.isExcludedFromContext,
                          (!candidate.content.isEmpty || !candidate.attachments.isEmpty) else { return false }
                    if candidate.isSynthesis {
                        return ArenaSynthesis.isCurrent(candidate, in: messages)
                    }
                    return true
                }
                if let winner = candidates.first(where: \.isSelectedInGroup) ?? candidates.first {
                    collapsed.append(winner)
                }
            } else {
                if msg.role == .assistant && msg.content.isEmpty && msg.attachments.isEmpty {
                    continue
                }
                collapsed.append(msg)
            }
        }

        let sliced: ArraySlice<ChatMessage>
        if limit > 0 && collapsed.count > limit {
            sliced = collapsed.suffix(limit)
        } else {
            sliced = collapsed[...]
        }

        var mediaTurnsKept = 0
        var history: [LLMPromptMessage] = []
        for msg in sliced.reversed() {
            var attachments = msg.attachments
            if attachments.contains(where: { $0.dataBase64 != nil }) {
                if mediaTurnsKept < Self.mediaTurnsToKeep {
                    mediaTurnsKept += 1
                } else {
                    attachments = attachments.map(Self.textOnlyVersion)
                }
            }
            let effectiveContent = Self.promptContent(msg.content, quotedExcerpt: msg.role == .user ? msg.assistanceMetadata.quotedExcerpt : nil)
            history.append(LLMPromptMessage(role: msg.role, content: effectiveContent, attachments: attachments))
        }
        return history.reversed()
    }

    static func textOnlyVersion(of attachment: MessageAttachment) -> MessageAttachment {
        var copy = attachment
        copy.dataBase64 = nil
        if attachment.kind == .image {
            copy.kind = .document
            copy.extractedText = nil
        }
        return copy
    }

    static func makeConversationTitle(from text: String, attachments: [MessageAttachment]) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !oneLine.isEmpty {
            return oneLine.count > 22 ? String(oneLine.prefix(22)) + "…" : oneLine
        }
        if let first = attachments.first {
            return first.kind == .image ? String(localized: "识图：\(first.fileName)") : String(localized: "文档：\(first.fileName)")
        }
        return Conversation.defaultTitle
    }
}
