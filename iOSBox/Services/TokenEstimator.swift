import Foundation
import SwiftData
import Observation
import os

enum TokenEstimator {
    struct Estimate {
        let inputTokens: Int
        let estimatedCostText: String?
    }

    /// Keep only a total. Tracking properties read by the history builder covers branch
    /// changes, Arena selection, attachment edits and context dividers.
    private final class HistoryEstimate: Observable, @unchecked Sendable {
        let hasMedia: Bool
        let hasBody: Bool
        @MainActor var tokens = 0
        private let valid = OSAllocatedUnfairLock(initialState: true)
        private let registrar = ObservationRegistrar()

        init(hasMedia: Bool, hasBody: Bool) {
            self.hasMedia = hasMedia
            self.hasBody = hasBody
        }

        var isValid: Bool {
            registrar.access(self, keyPath: \.isValid)
            return valid.withLock { $0 }
        }

        func invalidate() {
            registrar.withMutation(of: self, keyPath: \.isValid) {
                valid.withLock { $0 = false }
            }
        }
    }

    @MainActor private static let histories = NSMapTable<Conversation, HistoryEstimate>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory
    )

    private static let cachedTavilyPresence: OSAllocatedUnfairLock<Bool?> = {
        let lock = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        NotificationCenter.default.addObserver(
            forName: Notification.Name("IOSBoxCredentialsChanged"),
            object: nil,
            queue: nil
        ) { _ in
            lock.withLock { $0 = nil }
        }
        return lock
    }()

    private static func hasTavilySearchKey() -> Bool {
        if let cached = cachedTavilyPresence.withLock({ $0 }) {
            return cached
        }
        let present = !KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount).isEmpty
        cachedTavilyPresence.withLock { $0 = present }
        return present
    }

    @MainActor
    private static func historyTokens(in conversation: Conversation, hasMedia: Bool, hasBody: Bool) -> Int {
        if let cached = histories.object(forKey: conversation), cached.hasMedia == hasMedia,
           cached.hasBody == hasBody, cached.isValid { return cached.tokens }

        let entry = HistoryEstimate(hasMedia: hasMedia, hasBody: hasBody)
        entry.tokens = withObservationTracking {
            // Reserve the draft's position in both the context limit and the media window.
            // Its actual text and attachments can then change without decoding historical blobs.
            let sampleText = hasBody ? "x" : ""
            let sampleMedia = hasMedia ? [MessageAttachment(kind: .image, fileName: "", mimeType: "image/png",
                                                            dataBase64: "AA==", extractedText: nil, byteSize: 1)] : []
            let draft = ChatMessage(role: .user, content: sampleText, attachments: sampleMedia)
            let messages = ConversationTree.activeMessages(in: conversation) + [draft]
            let history: [LLMPromptMessage]
            if conversation.isGroupMode, let member = conversation.activeGroupMembers.first {
                history = GroupDiscussionCoordinator.buildPromptHistory(messages: messages, for: member,
                                                                         limit: conversation.contextMessageLimit)
            } else {
                history = ChatEngine.shared.buildPromptHistory(messages: messages, limit: conversation.contextMessageLimit)
            }
            return history.reduce(0) { $0 + estimateTokens(for: $1.content, attachments: $1.attachments) + 4 }
                - estimateTokens(for: sampleText, attachments: sampleMedia)
        } onChange: { [weak entry] in
            entry?.invalidate()
        }
        histories.setObject(entry, forKey: conversation)
        _ = entry.isValid // Register the initial SwiftUI render for invalidations too.
        return entry.tokens
    }

    /// Lightweight heuristic: CJK characters count ~1.2 tokens, ASCII/Latin ~0.35 tokens per character,
    /// plus a fixed overhead per image attachment. Intended purely as a pre-send magnitude hint.
    static func estimateTokens(for text: String, attachments: [MessageAttachment] = []) -> Int {
        var total = 0.0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 {
                total += 1.25
            } else if scalar.isASCII {
                total += 0.30
            } else {
                total += 0.75
            }
        }
        for att in attachments {
            switch att.kind {
            case .image:
                total += 850
            case .document:
                if let extracted = att.extractedText {
                    total += Double(estimateTokens(for: extracted))
                } else {
                    total += 400
                }
            }
        }
        return Int(ceil(total))
    }

    @MainActor
    static func estimateUpcomingInput(
        conversation: Conversation,
        providers: [ProviderConfig],
        draftText: String,
        attachments: [MessageAttachment],
        quotedText: String?,
        target: ResolvedModelTarget?,
        omitMemory: Bool = false
    ) -> Estimate {
        let effectiveTarget = target ?? (conversation.isGroupMode ? conversation.activeGroupMembers.first?.target : nil)
        let renderedSystem = PromptTemplateEngine.render(conversation.systemPrompt, target: effectiveTarget)
        var tokens = estimateTokens(for: renderedSystem)
        if let friend = conversation.activeBookFriend {
            tokens += estimateTokens(for: friend.systemInstruction)
            // Actual passages vary by topic. Use the previous reply as a local estimate.
            if let prior = conversation.sortedMessages.last(where: { $0.role == .assistant })?.assistanceMetadata.bookReply,
               let reference = try? prior.referenceText() { tokens += estimateTokens(for: reference) }
        }
        if conversation.isGroupMode, let firstMember = conversation.activeGroupMembers.first {
            tokens += estimateTokens(for: firstMember.rolePrompt) + 180
        }
        if conversation.assistanceSettings.usePersonalMemory && !omitMemory,
           let ctx = conversation.modelContext,
           let mem = try? PersonalMemory.prompt(in: ctx),
           mem.count > 0 {
            tokens += estimateTokens(for: mem.text)
        }
        if !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools {
            let hasTavilyKey = hasTavilySearchKey()
            let hasKB = !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty
            for tool in AgentToolRunner.definitions(hasTavilyKey: hasTavilyKey, hasKnowledgeBase: hasKB) {
                tokens += estimateTokens(for: tool.name + " " + tool.description + " " + tool.parametersSchemaJSON)
            }
        }
        let quote = quotedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ChatEngine.promptContent(draftText.trimmingCharacters(in: .whitespacesAndNewlines),
                                            quotedExcerpt: quote.map { String($0.prefix(1200)) },
                                            separator: conversation.isGroupMode ? "\n" : "\n\n")
        tokens += historyTokens(in: conversation, hasMedia: attachments.contains { $0.dataBase64 != nil },
                                hasBody: !body.isEmpty)
        tokens += estimateTokens(for: body, attachments: attachments)

        var costText: String?
        if let effectiveTarget,
           let provider = providers.first(where: { $0.id == effectiveTarget.providerID }),
           let spec = provider.models.first(where: { $0.id == effectiveTarget.modelID }),
           let price = RequestRecord.validPrice(spec.inputPricePerMillion),
           let currency = spec.priceCurrency,
           RequestRecord.currencies.contains(currency) {
            let cost = Double(tokens) * price / 1_000_000.0
            costText = RequestLedger.costText(cost, currency: currency)
        }
        return Estimate(inputTokens: tokens, estimatedCostText: costText)
    }
}
