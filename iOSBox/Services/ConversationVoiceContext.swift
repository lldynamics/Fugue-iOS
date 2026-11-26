import Foundation
import SwiftData

struct ConversationVoiceContext: Equatable {
    struct Turn: Equatable {
        let role: MessageRole
        let text: String

        var event: [String: Any] {
            ["type": "conversation.item.create", "item": [
                "type": "message", "role": role.rawValue,
                "content": [["type": role == .assistant ? "output_text" : "input_text", "text": text]]
            ]]
        }
    }

    let instructions: String
    let history: [Turn]

    @MainActor
    init(chat: Conversation, target: ResolvedModelTarget, omitMemory: Bool,
         selectedIDs: Set<UUID>?, context: ModelContext, now: Date = .now) {
        let engine = ChatEngine.shared
        let active = ConversationTree.activeMessages(in: chat)
        let eligible = engine.eligiblePromptContext(active)
        let memory = engine.prepareMemory(conversation: chat, omitMemory: omitMemory,
                                          selectedIDs: selectedIDs, context: context)
        var blocks = [memory.systemPrompt]
        if AppPreferences.shared.autoRollingSummaryEnabled, chat.contextMessageLimit > 0,
           let summary = RollingContextSummaryStore.shared.summary(for: chat.id),
           RollingContextSummaryStore.isSummaryValid(summary, dropped: RollingContextSummaryStore.droppedMessages(
            from: eligible, limit: chat.contextMessageLimit),
            latestContextDividerID: active.last(where: { $0.assistanceMetadata.isContextDivider })?.id) {
            blocks.append(RollingContextSummaryStore.promptBlock(for: summary))
        }
        let english = GroupDiscussionCoordinator.prefersEnglishPrompts(in: active)
        let subject: FriendMemorySubject?
        if let friend = chat.activeBookFriend {
            blocks.append(friend.systemInstruction(preferEnglish: english))
            subject = .bookFriend(friend)
        } else if let persona = chat.assistanceSettings.privatePersona, persona.target.id == target.id {
            blocks.append(persona.rolePrompt)
            subject = FriendMemorySubject.subjects(in: chat).first
        } else {
            subject = nil
        }
        if !omitMemory, let subject, let memory = engine.friendMemoryStore.promptBlock(for: subject, preferEnglish: english) {
            blocks.append(memory.text)
        }
        instructions = PromptTemplateEngine.render(blocks.filter { !$0.isEmpty }.joined(separator: "\n\n"), target: target, now: now)

        // Bound the recent text sent when opening the socket. Never forward attachment payloads.
        var remaining = 24_000
        var turns: [Turn] = []
        let limit = chat.contextMessageLimit > 0 ? chat.contextMessageLimit : eligible.count
        for msg in eligible.suffix(limit).reversed() where remaining > 0 {
            let content = ChatEngine.promptContent(msg.content, quotedExcerpt: msg.role == .user ? msg.assistanceMetadata.quotedExcerpt : nil)
            guard !content.isEmpty else { continue }
            let text = String(content.suffix(remaining))
            turns.append(Turn(role: msg.role, text: text))
            remaining -= text.count
        }
        history = turns.reversed()
    }
}

/// Keeps the original branch and item IDs even when input transcription arrives after the reply.
@MainActor
final class ConversationVoiceWriter {
    private let chat: Conversation
    private let context: ModelContext
    private let target: ResolvedModelTarget
    private let anchor: UUID
    private let selectedMemoryIDs: Set<UUID>?
    private let omitMemory: Bool
    private let firstIndex: Int
    private var owned: [UUID: ChatMessage] = [:]

    init(chat: Conversation, target: ResolvedModelTarget, context: ModelContext,
         selectedMemoryIDs: Set<UUID>? = nil, omitMemory: Bool = false) {
        self.selectedMemoryIDs = selectedMemoryIDs
        self.omitMemory = omitMemory
        self.chat = chat
        self.target = target
        self.context = context
        anchor = ConversationTree.currentAnchorID(in: chat) ?? ConversationTree.virtualRootID
        firstIndex = chat.nextMessageSortIndex()
    }

    func save(_ lines: [LiveVoiceSession.Line], ending: Bool = false) throws {
        guard chat.modelContext != nil, !chat.isDeleted else { throw AppCompliance.RequestChanged() }
        let ready = lines.filter { !$0.text.isEmpty && ($0.isFinal || $0.interrupted || ending) }
        guard !ready.isEmpty else { return }
        let current = ConversationTree.currentAnchorID(in: chat)
        guard current == anchor || current.map({ owned[$0] != nil }) == true else { throw AppCompliance.RequestChanged() }
        if owned.isEmpty { ConversationTree.ensureExplicitParentLinks(in: chat) }
        var parent = anchor
        for (index, line) in ready.enumerated() {
            let message: ChatMessage
            if let existing = owned[line.id] {
                message = existing
            } else {
                message = ChatMessage(id: line.id, role: line.role, target: line.role == .assistant ? target : nil,
                                      createdAt: line.startedAt)
                if line.role == .user {
                    message.assistanceMetadata.selectedMemoryIDs = selectedMemoryIDs
                    message.assistanceMetadata.omittedMemory = omitMemory
                }
                message.conversation = chat
                context.insert(message)
                owned[line.id] = message
            }
            if message.sortIndex != firstIndex + index { message.sortIndex = firstIndex + index }
            if message.parentMessageID != parent { message.parentMessageID = parent }
            parent = message.id
            let partial = line.interrupted || !line.isFinal
            var text = line.text
            if partial {
                let marker = line.interrupted ? String(localized: "已打断") : String(localized: "转写未完成")
                text += "\n\n（" + marker + "）"
            }
            if message.content != text { message.content = text }
            if message.assistanceMetadata.isExcludedFromContext != partial {
                message.assistanceMetadata.isExcludedFromContext = partial
            }
            if line.role == .user, Conversation.isDefaultTitle(chat.title) {
                chat.title = ChatEngine.makeConversationTitle(from: line.text, attachments: [])
            }
        }
        chat.activeLeafMessageID = parent
        chat.updatedAt = Date()
        try context.save()
    }
}
