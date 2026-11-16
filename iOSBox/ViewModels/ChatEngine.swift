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
}

@MainActor
@Observable
final class ChatEngine {
    static let shared = ChatEngine()

    private struct ActiveGeneration {
        let token: UUID
        let task: Task<Void, Never>
        let context: ModelContext
    }

    @ObservationIgnored private var activeGenerations: [UUID: ActiveGeneration] = [:]
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Conversations whose generation has not fully unwound yet (including while stopping).
    var activeConversationIDs: Set<UUID> = []

    private init() {}

    func isGenerating(in conversationID: UUID) -> Bool {
        activeConversationIDs.contains(conversationID)
    }

    /// Requests cancellation. The conversation keeps reporting `isGenerating == true`
    /// until the streaming tasks have fully unwound, so a new send can never race with
    /// the cleanup of the cancelled generation.
    func stopGeneration(for conversationID: UUID) {
        activeGenerations[conversationID]?.task.cancel()
    }

    /// Cancels the generation and waits until all of its writes have finished.
    /// Must be awaited before deleting the conversation or any of its messages.
    func stopGenerationAndWait(for conversationID: UUID) async {
        guard let generation = activeGenerations[conversationID] else { return }
        generation.task.cancel()
        await generation.task.value
    }

    func availableTargets(from providers: [ProviderConfig]) -> [ResolvedModelTarget] {
        var list: [ResolvedModelTarget] = []
        for provider in providers where provider.isEnabled {
            for spec in provider.enabledModels {
                list.append(provider.makeTarget(for: spec))
            }
        }
        return list
    }

    @discardableResult
    func sendUserMessage(
        text: String,
        attachments: [MessageAttachment],
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) -> SendOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return .emptyInput }
        guard !isGenerating(in: conversation.id) else { return .busy }

        let targets: [ResolvedModelTarget]
        if conversation.isArenaMode && conversation.arenaTargets.count >= 2 {
            targets = conversation.arenaTargets
        } else if let primary = conversation.primaryTarget {
            targets = [primary]
        } else if let fallback = availableTargets(from: providers).first {
            conversation.primaryTarget = fallback
            targets = [fallback]
        } else {
            return .noAvailableModel
        }

        let nextSort = (conversation.sortedMessages.last?.sortIndex ?? 0) + 1
        let userMsg = ChatMessage(
            role: .user,
            content: trimmed,
            attachments: attachments,
            sortIndex: nextSort
        )
        userMsg.conversation = conversation
        conversation.messages.append(userMsg)
        context.insert(userMsg)

        if conversation.messages.filter({ $0.role == .user }).count == 1 && conversation.title == "新对话" {
            conversation.title = Self.makeConversationTitle(from: trimmed, attachments: attachments)
        }
        conversation.updatedAt = Date()

        let historySnapshot = buildPromptHistory(
            messages: conversation.sortedMessages,
            limit: conversation.contextMessageLimit
        )

        let groupID: UUID? = targets.count > 1 ? UUID() : nil
        var assistantPlaceholders: [(ChatMessage, ResolvedModelTarget)] = []

        for (idx, target) in targets.enumerated() {
            let replyMsg = ChatMessage(
                role: .assistant,
                target: target,
                comparisonGroupID: groupID,
                isSelectedInGroup: idx == 0,
                isStreaming: true,
                sortIndex: nextSort + 1 + idx
            )
            replyMsg.conversation = conversation
            conversation.messages.append(replyMsg)
            context.insert(replyMsg)
            assistantPlaceholders.append((replyMsg, target))
        }

        try? context.save()

        launchStreamingTasks(
            placeholders: assistantPlaceholders,
            historySnapshot: historySnapshot,
            conversation: conversation,
            providers: providers,
            context: context
        )
        return .sent
    }

    func regenerate(
        assistantMessage: ChatMessage,
        overrideTarget: ResolvedModelTarget? = nil,
        in conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) {
        guard !isGenerating(in: conversation.id) else { return }
        let sorted = conversation.sortedMessages
        guard let targetIdx = sorted.firstIndex(where: { $0.id == assistantMessage.id }) else { return }

        // Collect history strictly prior to this assistant message (and prior to its comparison group)
        let cutoffMessages = Array(sorted[..<targetIdx]).filter { msg in
            if let gid = assistantMessage.comparisonGroupID, msg.comparisonGroupID == gid {
                return false
            }
            return true
        }

        let historySnapshot = buildPromptHistory(
            messages: cutoffMessages,
            limit: conversation.contextMessageLimit
        )
        guard !historySnapshot.isEmpty else { return }

        let resolvedTarget: ResolvedModelTarget
        if let overrideTarget {
            resolvedTarget = overrideTarget
        } else if let pid = assistantMessage.providerID,
                  let provider = providers.first(where: { $0.id == pid }) {
            let spec = provider.models.first(where: { $0.id == assistantMessage.modelID })
                ?? ModelSpec(id: assistantMessage.modelID, displayName: assistantMessage.modelDisplayName)
            resolvedTarget = provider.makeTarget(for: spec)
        } else if let primary = conversation.primaryTarget {
            resolvedTarget = primary
        } else {
            return
        }

        assistantMessage.providerID = resolvedTarget.providerID
        assistantMessage.providerName = resolvedTarget.providerName
        assistantMessage.modelID = resolvedTarget.modelID
        assistantMessage.modelDisplayName = resolvedTarget.modelDisplayName
        assistantMessage.accentHex = resolvedTarget.accentHex
        assistantMessage.content = ""
        assistantMessage.reasoningContent = ""
        assistantMessage.errorMessage = nil
        assistantMessage.promptTokens = nil
        assistantMessage.completionTokens = nil
        assistantMessage.latencyMs = nil
        assistantMessage.thinkingDurationMs = nil
        assistantMessage.isStreaming = true
        try? context.save()

        launchStreamingTasks(
            placeholders: [(assistantMessage, resolvedTarget)],
            historySnapshot: historySnapshot,
            conversation: conversation,
            providers: providers,
            context: context
        )
    }

    func selectWinnerInGroup(_ winner: ChatMessage, in conversation: Conversation, context: ModelContext) {
        guard let gid = winner.comparisonGroupID else { return }
        for msg in conversation.messages where msg.comparisonGroupID == gid {
            msg.isSelectedInGroup = (msg.id == winner.id)
        }
        try? context.save()
    }

    // MARK: - Private Execution

    private func launchStreamingTasks(
        placeholders: [(ChatMessage, ResolvedModelTarget)],
        historySnapshot: [LLMPromptMessage],
        conversation: Conversation,
        providers: [ProviderConfig],
        context: ModelContext
    ) {
        let convID = conversation.id
        let token = UUID()
        activeConversationIDs.insert(convID)

        // Build Sendable requests upfront on MainActor
        var prepared: [(ChatMessage, LLMChatRequest?)] = []
        for (msg, target) in placeholders {
            guard let provider = providers.first(where: { $0.id == target.providerID }) else {
                msg.errorMessage = "未找到对应的服务商配置（可能已被删除）"
                msg.isStreaming = false
                prepared.append((msg, nil))
                continue
            }
            let apiKey = KeychainService.shared.loadAPIKey(for: provider.id)
            let isLocalHost = provider.baseURL.contains("localhost")
                || provider.baseURL.contains("127.0.0.1")
                || provider.baseURL.contains("192.168.")
                || provider.baseURL.contains("10.")
                || provider.baseURL.contains("172.")
            if apiKey.isEmpty && !isLocalHost {
                msg.errorMessage = LLMError.missingAPIKey(provider.name).localizedDescription
                msg.isStreaming = false
                prepared.append((msg, nil))
                continue
            }

            let req = LLMChatRequest(
                providerName: provider.name,
                protocolType: provider.protocolType,
                baseURL: provider.baseURL,
                apiKey: apiKey,
                customHeaders: provider.customHeaders,
                modelID: target.modelID,
                systemPrompt: conversation.systemPrompt,
                messages: historySnapshot,
                temperature: conversation.useCustomTemperature ? conversation.temperature : nil,
                topP: conversation.topP,
                maxOutputTokens: conversation.maxOutputTokens > 0 ? conversation.maxOutputTokens : nil,
                enableThinking: conversation.enableThinking,
                thinkingBudgetTokens: conversation.thinkingBudgetTokens
            )
            prepared.append((msg, req))
        }

        // The task body only starts after this synchronous MainActor function returns,
        // so the generation is always registered before it can finish.
        let masterTask = Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for (messageModel, maybeReq) in prepared {
                    guard let req = maybeReq else { continue }
                    group.addTask { @MainActor in
                        await self.runSingleStream(request: req, into: messageModel)
                    }
                }
            }
            if Self.isAlive(conversation) {
                conversation.updatedAt = Date()
                try? context.save()
            }
            self.finishGeneration(conversationID: convID, token: token)
        }

        activeGenerations[convID] = ActiveGeneration(token: token, task: masterTask, context: context)
        updateBackgroundExecution()
    }

    /// Only the generation that registered itself may clear the "generating" state.
    private func finishGeneration(conversationID: UUID, token: UUID) {
        guard activeGenerations[conversationID]?.token == token else { return }
        activeGenerations.removeValue(forKey: conversationID)
        activeConversationIDs.remove(conversationID)
        updateBackgroundExecution()
    }

    private func runSingleStream(request: LLMChatRequest, into message: ChatMessage) async {
        let startTime = ContinuousClock.now
        var thinkingStartTime: ContinuousClock.Instant?
        var recordedThinkingDuration = false

        var pendingContent = ""
        var pendingReasoning = ""
        var lastFlush = ContinuousClock.now
        var lastSave = ContinuousClock.now

        func flushBuffers() {
            guard Self.isAlive(message) else {
                pendingReasoning = ""
                pendingContent = ""
                return
            }
            if !pendingReasoning.isEmpty {
                message.reasoningContent.append(pendingReasoning)
                pendingReasoning = ""
            }
            if !pendingContent.isEmpty {
                message.content.append(pendingContent)
                pendingContent = ""
            }
            lastFlush = ContinuousClock.now
            // Persist partial output periodically so a killed app keeps what was received.
            if lastSave.duration(to: lastFlush) >= .seconds(2) {
                try? message.modelContext?.save()
                lastSave = lastFlush
            }
        }

        do {
            for try await event in LLMClient.streamChat(request) {
                try Task.checkCancellation()
                switch event {
                case .reasoningDelta(let delta):
                    if thinkingStartTime == nil {
                        thinkingStartTime = ContinuousClock.now
                    }
                    pendingReasoning.append(delta)
                    if lastFlush.duration(to: ContinuousClock.now) >= .milliseconds(35) {
                        flushBuffers()
                    }

                case .contentDelta(let delta):
                    if let tStart = thinkingStartTime, !recordedThinkingDuration, Self.isAlive(message) {
                        message.thinkingDurationMs = Self.milliseconds(tStart.duration(to: ContinuousClock.now))
                        recordedThinkingDuration = true
                    }
                    pendingContent.append(delta)
                    if lastFlush.duration(to: ContinuousClock.now) >= .milliseconds(35) {
                        flushBuffers()
                    }

                case .usage(let prompt, let completion):
                    guard Self.isAlive(message) else { break }
                    if let prompt { message.promptTokens = prompt }
                    if let completion { message.completionTokens = completion }

                case .done:
                    flushBuffers()
                }
            }

            // A cancelled consumer can end the loop normally; treat that as a stop, not success.
            try Task.checkCancellation()

            flushBuffers()
            guard Self.isAlive(message) else { return }
            message.latencyMs = Self.milliseconds(startTime.duration(to: ContinuousClock.now))
            if let tStart = thinkingStartTime, !recordedThinkingDuration {
                message.thinkingDurationMs = Self.milliseconds(tStart.duration(to: ContinuousClock.now))
            }
            if message.content.isEmpty && message.reasoningContent.isEmpty {
                message.errorMessage = "服务端返回成功，但回复内容为空"
            }
            message.isStreaming = false
        } catch {
            flushBuffers()
            guard Self.isAlive(message) else { return }
            if Self.isCancellation(error) {
                if message.content.isEmpty && message.reasoningContent.isEmpty {
                    message.errorMessage = "已停止生成"
                }
            } else {
                message.errorMessage = error.localizedDescription
            }
            message.isStreaming = false
        }
    }

    // MARK: - Background Execution

    private func updateBackgroundExecution() {
        if activeGenerations.isEmpty {
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
        endBackgroundTaskIfNeeded()
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Helpers

    /// Writing to a SwiftData model after it was deleted can crash, so every write
    /// from an in-flight stream is guarded by this check.
    private static func isAlive(_ model: some PersistentModel) -> Bool {
        model.modelContext != nil && !model.isDeleted
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    func buildPromptHistory(messages: [ChatMessage], limit: Int) -> [LLMPromptMessage] {
        var collapsed: [ChatMessage] = []
        var processedGroups = Set<UUID>()

        for msg in messages {
            if let gid = msg.comparisonGroupID {
                guard !processedGroups.contains(gid) else { continue }
                processedGroups.insert(gid)
                let candidates = messages.filter { $0.comparisonGroupID == gid && !$0.content.isEmpty }
                if let winner = candidates.first(where: \.isSelectedInGroup) ?? candidates.first {
                    collapsed.append(winner)
                }
            } else {
                if msg.role == .assistant && msg.content.isEmpty && msg.errorMessage != nil {
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

        return sliced.map { msg in
            LLMPromptMessage(
                role: msg.role,
                content: msg.content,
                attachments: msg.attachments
            )
        }
    }

    private static func makeConversationTitle(from text: String, attachments: [MessageAttachment]) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !oneLine.isEmpty {
            return oneLine.count > 22 ? String(oneLine.prefix(22)) + "…" : oneLine
        }
        if let first = attachments.first {
            return first.kind == .image ? "识图：\(first.fileName)" : "文档：\(first.fileName)"
        }
        return "新对话"
    }
}
