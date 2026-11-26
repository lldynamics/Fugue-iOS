import Foundation
import SwiftData

/// One connection to a lesson. Reconnecting appends to the existing conversation and starts a new clock.
@MainActor final class PracticeCall {
    let chat: Conversation
    let instructions: String
    private let context: ModelContext
    private let provider: ProviderConfig
    private let model: String
    private let firstIndex: Int
    private let transcriptDate: Date
    private let previousDuration: TimeInterval
    private var connectedAt: Date?
    private var stoppedAt: Date?
    private var written = Set<UUID>()
    private var requests: [String: RequestRecord] = [:]
    private var meterRows: [UUID: PracticeMeterRecord] = [:]
    private static var active = Set<UUID>()

    init(provider: ProviderConfig, model: String, lesson: PracticeLesson, resuming existing: Conversation?,
         in context: ModelContext) throws {
        self.context = context
        self.provider = provider
        self.model = model
        if let existing {
            guard !existing.isDeleted, existing.modelContext === context,
                  let stored = existing.assistanceSettings.voicePractice, stored.isResumable == true,
                  stored.providerID == provider.id, stored.realtimeModelID == model,
                  !Self.active.contains(existing.id) else { throw AppCompliance.RequestChanged() }
            chat = existing
            if stored.pendingTranscription == true {
                try LanguagePractice.update(existing) { $0.incompleteTranscript = true; $0.pendingTranscription = nil }
            }
        } else {
            var draft = lesson
            draft.isResumable = true
            draft.realtimeModelID = model
            draft.voiceMessageIDs = []
            let target = provider.enabledModels.first(where: { $0.id == lesson.reviewModelID }).map(provider.makeTarget)
            chat = try LanguagePractice.saveTranscript([], model: model, lesson: draft, target: target, in: context)
        }
        firstIndex = (chat.sortedMessages.last?.sortIndex ?? -1) + 1
        // Conversation sorts by date, then index. Late ASR results belong to this connection's timeline.
        transcriptDate = max(.now, chat.sortedMessages.last?.createdAt ?? .distantPast)
        previousDuration = chat.assistanceSettings.voicePractice?.callSeconds ?? 0
        let dialogue = existing.flatMap(Self.recentDialogue)
        instructions = lesson.profile.instructions(targets: lesson.targets, helpLanguage: Locale.preferredLanguages.first ?? "zh-Hans", recentDialogue: dialogue)
        Self.active.insert(chat.id)
    }

    static func recentDialogue(in chat: Conversation) -> String? {
        guard let lesson = chat.assistanceSettings.voicePractice else { return nil }
        let saved = Set(lesson.voiceMessageIDs ?? lesson.learnerTurnIDs)
        let turns = chat.sortedMessages.filter { saved.contains($0.id) && lesson.interruptedTutorIDs?.contains($0.id) != true }
            .suffix(8).map { ["role": $0.roleRaw, "text": String($0.content.prefix(500))] }
        guard !turns.isEmpty, let data = try? JSONEncoder().encode(turns) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func connected(at time: Date = .now) { if connectedAt == nil { connectedAt = time } }

    func checkpoint(_ lines: [LiveVoiceSession.Line], incomplete: Bool, tapToTalk: Bool?, interrupted: Set<UUID>, pending: Bool = false, now: Date = .now) throws {
        guard !chat.isDeleted, var lesson = chat.assistanceSettings.voicePractice, lesson.isResumable == true else { throw AppCompliance.RequestChanged() }
        for (index, line) in lines.enumerated() where line.isFinal && !written.contains(line.id) {
            let message = ChatMessage(id: line.id, role: line.role, content: line.text, sortIndex: firstIndex + (line.itemOrder ?? index), createdAt: transcriptDate)
            message.modelID = model
            message.modelDisplayName = model
            message.providerID = provider.id
            message.providerName = provider.name
            context.insert(message)
            message.conversation = chat
            written.insert(line.id)
            lesson.voiceMessageIDs?.append(line.id)
            if line.role == .user { lesson.learnerTurnIDs.append(line.id) }
        }
        if let connectedAt { lesson.callSeconds = previousDuration + max(0, (stoppedAt ?? now).timeIntervalSince(connectedAt)) }
        if let tapToTalk { lesson.profile.tapToTalk = tapToTalk }
        if !interrupted.isEmpty { lesson.interruptedTutorIDs = (lesson.interruptedTutorIDs ?? []).union(interrupted) }
        if incomplete { lesson.incompleteTranscript = true }
        lesson.pendingTranscription = pending ? true : nil
        chat.assistanceSettings.voicePractice = lesson
        chat.updatedAt = now
        try context.save()
    }

    func meter(_ key: String, kind: RequestKind, usage: [String: Any]? = nil, status: RequestStatus = .running) throws {
        guard !chat.isDeleted else { throw AppCompliance.RequestChanged() }
        let id = kind.rawValue + "/" + key
        let record: RequestRecord
        if let existing = requests[id] {
            guard existing.status == .running, status != .running else { return }
            record = existing
        } else {
            let modelID = kind == .practiceTranscription ? LiveVoiceSession.practiceTranscriptionModel : model
            let spec = provider.models.first { $0.id == modelID } ?? ModelSpec(id: modelID)
            record = RequestRecord(target: provider.makeTarget(for: spec), spec: spec, conversationID: chat.id, messageID: UUID(), kind: kind)
            record.isStreamed = false
            context.insert(record)
            requests[id] = record
            let row = try PracticeMeterRecord(requestID: record.id, meter: .init(usage: nil, kind: kind, rates: spec.audioRates))
            context.insert(row)
            meterRows[record.id] = row
        }
        if status != .running {
            if let row = meterRows[record.id] {
                let rates = try JSONDecoder().decode(PracticeMeter.self, from: row.data).rates
                let meter = PracticeMeter(usage: usage, kind: kind, rates: rates)
                record.promptTokens = meter.input
                record.completionTokens = meter.output
                record.cachedTokens = meter.cached
                row.data = try JSONEncoder().encode(meter)
            }
            record.finish(status, elapsedMs: max(0, Int(Date().timeIntervalSince(record.startedAt) * 1000)))
        }
        try context.save()
    }

    func close(_ voice: LiveVoiceSession, completed: Bool, now: Date = .now) throws {
        if stoppedAt == nil { stoppedAt = now }
        for request in requests.values where request.status == .running {
            request.finish(.interrupted, elapsedMs: max(0, Int(now.timeIntervalSince(request.startedAt) * 1000)), now: now)
        }
        try checkpoint(voice.lines, incomplete: voice.incompleteTranscript, tapToTalk: voice.speakerRequiresTapTurns ? nil : voice.usesTapTurns, interrupted: voice.interruptedTutorLines, now: now)
        if completed { try LanguagePractice.update(chat) { $0.isResumable = false } }
        Self.active.remove(chat.id)
    }

    static func finishPaused(_ chat: Conversation) throws {
        guard !active.contains(chat.id) else { throw AppCompliance.RequestChanged() }
        try LanguagePractice.update(chat) {
            if $0.pendingTranscription == true { $0.incompleteTranscript = true; $0.pendingTranscription = nil }
            $0.isResumable = false
        }
    }
}
