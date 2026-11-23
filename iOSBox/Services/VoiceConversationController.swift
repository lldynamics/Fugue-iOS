import Foundation
import Observation

enum VoiceConversationPhase: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case speaking

    var statusTitle: String {
        switch self {
        case .idle: return String(localized: "待命 · 轻点圆球开始说话")
        case .listening: return String(localized: "正在聆听…")
        case .thinking: return String(localized: "正在思考回复…")
        case .speaking: return String(localized: "正在语音播报…")
        }
    }
}

enum VoiceSilenceTimeout: Double, CaseIterable, Identifiable, Sendable {
    case fast = 1.6
    case normal = 2.4
    case relaxed = 3.5
    case manual = 0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .fast: return String(localized: "快速（1.6 秒）")
        case .normal: return String(localized: "标准（2.4 秒）")
        case .relaxed: return String(localized: "从容（3.5 秒）")
        case .manual: return String(localized: "手动发送")
        }
    }

    var shortLabel: String {
        switch self {
        case .fast: return String(localized: "1.6 秒停顿")
        case .normal: return String(localized: "2.4 秒停顿")
        case .relaxed: return String(localized: "3.5 秒停顿")
        case .manual: return String(localized: "手动发送")
        }
    }
}

enum VoiceConversationPolicy {
    static func shouldAutoCommit(
        transcript: String,
        silenceElapsed: TimeInterval,
        timeoutSeconds: TimeInterval
    ) -> Bool {
        guard timeoutSeconds > 0 else { return false }
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        return silenceElapsed >= timeoutSeconds
    }

    static func cleanedSpeechSummary(from markdown: String, maxCharacters: Int = 2400) -> String {
        let cleaned = SpeechService.cleanForSpeech(markdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let cap = max(80, maxCharacters)
        guard cleaned.count > cap else { return cleaned }
        return String(cleaned.prefix(cap))
    }

    static func nextPhaseAfterSpeechFinished(autoResumeListening: Bool) -> VoiceConversationPhase {
        autoResumeListening ? .listening : .idle
    }
}

@MainActor
@Observable
final class VoiceConversationController {
    private(set) var phase: VoiceConversationPhase = .idle
    var liveTranscript = ""
    private(set) var lastUserUtterance = ""
    private(set) var latestAssistantReply = ""
    private(set) var voiceLevel: Float = 0
    var autoResumeListening = true
    var silenceTimeout: VoiceSilenceTimeout = .normal
    var statusError: String?
    private(set) var turnCount = 0
    private(set) var isSessionActive = false

    @ObservationIgnored private let injectedSpeech: SpeechService?
    @ObservationIgnored private var silenceTimerTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored var onSilenceAutoCommit: (() -> Void)?

    private var speech: SpeechService { injectedSpeech ?? .shared }

    init(speechService: SpeechService? = nil) {
        self.injectedSpeech = speechService
    }

    func startSession() {
        isSessionActive = true
        statusError = nil
        turnCount = 0
    }

    func stopSession() {
        isSessionActive = false
        cancelTimers()
        speech.stopDictation()
        speech.stopSpeaking()
        voiceLevel = 0
        phase = .idle
    }

    func pauseSession() {
        cancelTimers()
        speech.stopDictation()
        speech.stopSpeaking()
        voiceLevel = 0
        phase = .idle
    }

    func startListening() {
        guard isSessionActive else { return }
        cancelTimers()
        speech.stopSpeaking()
        statusError = nil
        liveTranscript = ""
        voiceLevel = 0
        phase = .listening

        speech.startDictation(
            onTranscript: { [weak self] text in
                self?.handleTranscriptUpdate(text, scheduleTimer: true)
            },
            onAudioLevel: { [weak self] level in
                self?.voiceLevel = level
            }
        )
    }

    func handleTranscriptUpdate(_ text: String, scheduleTimer: Bool = true) {
        guard isSessionActive, phase == .listening else { return }
        liveTranscript = text
        cancelSilenceTimer()
        let timeout = silenceTimeout.rawValue
        guard scheduleTimer,
              VoiceConversationPolicy.shouldAutoCommit(
                  transcript: text,
                  silenceElapsed: timeout,
                  timeoutSeconds: timeout
              ) else {
            return
        }
        silenceTimerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.isSessionActive,
                  self.phase == .listening else {
                return
            }
            self.onSilenceAutoCommit?()
        }
    }

    @discardableResult
    func commitCurrentTranscript(sendHandler: (String) -> Bool) -> Bool {
        cancelTimers()
        let clean = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        speech.stopDictation()
        voiceLevel = 0
        lastUserUtterance = clean
        liveTranscript = ""
        statusError = nil
        if sendHandler(clean) {
            phase = .thinking
            return true
        } else {
            phase = .idle
            return false
        }
    }

    func handleGenerationFinished(
        replyText: String,
        errorMessage: String?,
        messageID: UUID,
        cloudSynthesizer: CloudSpeechSynthesizerHandler? = nil,
        resumeDelayMs: Int = 250,
        speakHandler: ((UUID, String, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        guard isSessionActive else { return }
        cancelTimers()

        if let errorMessage, !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusError = errorMessage
            phase = .idle
            return
        }

        let cleanSpeech = VoiceConversationPolicy.cleanedSpeechSummary(from: replyText)
        guard !cleanSpeech.isEmpty else {
            phase = .idle
            return
        }

        latestAssistantReply = replyText
        turnCount += 1
        phase = .speaking
        statusError = nil

        let completion: @MainActor () -> Void = { [weak self] in
            self?.handleSpeechCompleted(resumeDelayMs: resumeDelayMs)
        }

        if let speakHandler {
            speakHandler(messageID, cleanSpeech, completion)
        } else {
            speech.toggleSpeaking(
                messageID: messageID,
                text: cleanSpeech,
                personaID: nil,
                cloudSynthesizer: cloudSynthesizer,
                onFinished: completion
            )
        }
    }

    func handleSpeechCompleted(
        resumeDelayMs: Int = 250,
        listenHandler: (() -> Void)? = nil
    ) {
        guard isSessionActive, phase == .speaking else { return }
        let next = VoiceConversationPolicy.nextPhaseAfterSpeechFinished(
            autoResumeListening: autoResumeListening
        )
        guard next == .listening else {
            phase = .idle
            return
        }

        if resumeDelayMs <= 0 {
            if let listenHandler {
                phase = .listening
                listenHandler()
            } else {
                startListening()
            }
            return
        }

        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(resumeDelayMs))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.isSessionActive,
                  self.phase == .speaking,
                  self.autoResumeListening else {
                return
            }
            if let listenHandler {
                self.phase = .listening
                listenHandler()
            } else {
                self.startListening()
            }
        }
    }

    func interruptAndListen() {
        cancelTimers()
        speech.stopSpeaking()
        startListening()
    }

    func replayLastReply(cloudSynthesizer: (@Sendable (String) async throws -> Data)? = nil) {
        guard isSessionActive else { return }
        let cleanSpeech = VoiceConversationPolicy.cleanedSpeechSummary(from: latestAssistantReply)
        guard !cleanSpeech.isEmpty else { return }
        cancelTimers()
        speech.stopDictation()
        speech.stopSpeaking()
        phase = .speaking
        statusError = nil
        speech.toggleSpeaking(
            messageID: UUID(),
            text: cleanSpeech,
            personaID: nil,
            cloudSynthesizer: cloudSynthesizer
        ) { [weak self] in
            self?.handleSpeechCompleted()
        }
    }

    private func cancelSilenceTimer() {
        silenceTimerTask?.cancel()
        silenceTimerTask = nil
    }

    private func cancelTimers() {
        silenceTimerTask?.cancel()
        silenceTimerTask = nil
        resumeTask?.cancel()
        resumeTask = nil
    }
}
