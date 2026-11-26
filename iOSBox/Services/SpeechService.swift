import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import Observation

@MainActor
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechService()

    private(set) var speakingMessageID: UUID?
    private(set) var isRecording = false
    private(set) var isSynthesizingCloudSpeech = false
    var speechError: String?

    var isDictationActive: Bool {
        isRecording || dictationToken != nil
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var activeUtteranceID: ObjectIdentifier?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var activePlayerID: ObjectIdentifier?
    @ObservationIgnored private var cloudSpeechTask: Task<Void, Never>?
    @ObservationIgnored private var dictationToken: UUID?
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var activeRecordingHandler: ((String) -> Void)?
    @ObservationIgnored private var onSpeechFinished: (@MainActor () -> Void)?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.iosbox.speech.audio-session", qos: .userInitiated)
    @ObservationIgnored private var audioSessionRequested = false

    private override init() {
        super.init()
        synthesizer.delegate = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw),
                  type == .began else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.dictationToken != nil { self.stopDictation() }
                if self.speakingMessageID != nil { self.stopSpeaking() }
            }
        }
    }

    // MARK: - Text Cleaning for Speech

    nonisolated static func cleanForSpeech(_ markdown: String) -> String {
        var cleaned = markdown
        if let codeRe = try? NSRegularExpression(pattern: #"```[\s\S]*?```"#) {
            cleaned = codeRe.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: " 代码片段。"
            )
        }
        if let linkRe = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) {
            cleaned = linkRe.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: "$1"
            )
        }
        if let headingRe = try? NSRegularExpression(pattern: #"(?m)^#{1,6}\s+"#) {
            cleaned = headingRe.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        if let quoteRe = try? NSRegularExpression(pattern: #"(?m)^>\s*"#) {
            cleaned = quoteRe.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        if let urlRe = try? NSRegularExpression(pattern: #"https?://\S+"#) {
            cleaned = urlRe.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }
        cleaned = cleaned
            .replacingOccurrences(of: "$$", with: " ")
            .replacingOccurrences(of: "\\(", with: " ")
            .replacingOccurrences(of: "\\)", with: " ")
            .replacingOccurrences(of: "\\[", with: " ")
            .replacingOccurrences(of: "\\]", with: " ")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "$", with: "")
        return cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Text-to-Speech

    func toggleSpeaking(
        messageID: UUID,
        text: String,
        personaID: UUID? = nil,
        cloudSynthesizer: (@Sendable (String) async throws -> Data)? = nil,
        onFinished: (@MainActor () -> Void)? = nil
    ) {
        if speakingMessageID == messageID {
            stopSpeaking()
            return
        }
        if dictationToken != nil {
            stopDictation()
        }
        stopSpeaking()
        let cleaned = Self.cleanForSpeech(text)
        guard !cleaned.isEmpty else { return }
        onSpeechFinished = onFinished

        guard let cloudSynthesizer else {
            speakLocally(messageID: messageID, text: cleaned, personaID: personaID)
            return
        }

        speakingMessageID = messageID
        isSynthesizingCloudSpeech = true
        cloudSpeechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let mp3Data = try await cloudSynthesizer(cleaned)
                guard !Task.isCancelled, self.speakingMessageID == messageID else { return }
                let player = try AVAudioPlayer(data: mp3Data)
                player.delegate = self
                let playerID = ObjectIdentifier(player)
                self.audioPlayer = player
                self.activePlayerID = playerID
                self.isSynthesizingCloudSpeech = false
                self.activateAudioSession(forRecording: false) { [weak self] err in
                    guard let self,
                          self.activePlayerID == playerID,
                          self.speakingMessageID == messageID else { return }
                    if err != nil || !player.play() {
                        self.audioPlayer?.stop()
                        self.audioPlayer = nil
                        self.activePlayerID = nil
                        self.speakLocally(messageID: messageID, text: cleaned, personaID: personaID)
                    }
                }
            } catch is CancellationError {
                self.isSynthesizingCloudSpeech = false
            } catch {
                self.isSynthesizingCloudSpeech = false
                guard !Task.isCancelled, self.speakingMessageID == messageID else { return }
                self.audioPlayer = nil
                self.activePlayerID = nil
                self.speakLocally(messageID: messageID, text: cleaned, personaID: personaID)
            }
        }
    }

    private func speakLocally(messageID: UUID, text: String, personaID: UUID?) {
        let utterance = makeUtterance(text: text, personaID: personaID)
        activeUtteranceID = ObjectIdentifier(utterance)
        speakingMessageID = messageID
        activateAudioSession(forRecording: false) { [weak self] _ in
            guard let self, self.activeUtteranceID == ObjectIdentifier(utterance) else { return }
            self.synthesizer.speak(utterance)
        }
    }

    private func makeUtterance(text: String, personaID: UUID?) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice(for: text, personaID: personaID)
        if let personaID {
            let bucket = Self.personaVoiceBucket(for: personaID)
            let pitchOffsets: [Float] = [0.92, 1.0, 1.08, 0.96, 1.12, 1.04]
            let rateMultipliers: [Float] = [0.97, 1.02, 0.95, 1.05, 0.99, 1.03]
            utterance.pitchMultiplier = pitchOffsets[bucket % pitchOffsets.count]
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rateMultipliers[bucket % rateMultipliers.count]
        } else {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        }
        return utterance
    }

    func stopSpeaking() {
        let hadActiveSpeech = activeUtteranceID != nil
            || activePlayerID != nil
            || cloudSpeechTask != nil
            || speakingMessageID != nil
            || synthesizer.isSpeaking
            || (audioPlayer?.isPlaying == true)
        onSpeechFinished = nil
        cloudSpeechTask?.cancel()
        cloudSpeechTask = nil
        isSynthesizingCloudSpeech = false
        activePlayerID = nil
        if let player = audioPlayer {
            player.stop()
            audioPlayer = nil
        }
        activeUtteranceID = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speakingMessageID = nil
        deactivateAudioSessionIfIdle()
        if hadActiveSpeech {
            // `AVSpeechSynthesizer.stopSpeaking(at: .immediate)` unwinds asynchronously; schedule a
            // short follow-up check so background music is guaranteed to un-duck even if `didCancel`
            // races with `synthesizer.isSpeaking`.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                self?.deactivateAudioSessionIfIdle()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.activePlayerID == finishedID else { return }
            self.activePlayerID = nil
            self.audioPlayer = nil
            self.speakingMessageID = nil
            let callback = flag ? self.onSpeechFinished : nil
            self.onSpeechFinished = nil
            self.deactivateAudioSessionIfIdle()
            callback?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let erroredID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.activePlayerID == erroredID else { return }
            self.activePlayerID = nil
            self.audioPlayer = nil
            self.speakingMessageID = nil
            self.onSpeechFinished = nil
            self.deactivateAudioSessionIfIdle()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleUtteranceEnded(finishedID, finishedNaturally: true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelledID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleUtteranceEnded(cancelledID, finishedNaturally: false)
        }
    }

    func handleUtteranceEnded(_ utteranceID: ObjectIdentifier, finishedNaturally: Bool = true) {
        if activeUtteranceID == utteranceID {
            activeUtteranceID = nil
            speakingMessageID = nil
            let callback = finishedNaturally ? onSpeechFinished : nil
            onSpeechFinished = nil
            deactivateAudioSessionIfIdle()
            callback?()
        } else if activeUtteranceID == nil {
            // Manual `stopSpeaking()` already cleared `activeUtteranceID`; now that the synthesizer
            // finished cancelling, release the ducked playback session so other apps' volume restores.
            deactivateAudioSessionIfIdle()
        }
    }

    private func preferredVoice(for text: String, personaID: UUID? = nil) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(240)))
        let langCode: String
        if let lang = recognizer.dominantLanguage {
            langCode = lang == .simplifiedChinese ? "zh-CN" : (lang == .traditionalChinese ? "zh-TW" : lang.rawValue)
        } else {
            langCode = Locale.current.identifier
        }

        if let personaID {
            let prefix = String(langCode.prefix(2)).lowercased()
            let matching = AVSpeechSynthesisVoice.speechVoices().filter {
                $0.language.lowercased().hasPrefix(prefix)
            }
            if matching.count > 1 {
                let sorted = matching.sorted { $0.identifier < $1.identifier }
                let idx = Self.personaVoiceBucket(for: personaID) % sorted.count
                return sorted[idx]
            }
        }

        return AVSpeechSynthesisVoice(language: langCode) ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
    }

    nonisolated static func personaVoiceBucket(for id: UUID) -> Int {
        let bytes = id.uuidString.utf8
        var hash: UInt64 = 5381
        for b in bytes {
            hash = ((hash << 5) &+ hash) &+ UInt64(b)
        }
        return Int(hash % 6)
    }

    // Keep activate/deactivate in request order, including when a user rapidly switches
    // between speech and dictation. Audio hardware negotiation can block for hundreds of ms.
    private func activateAudioSession(forRecording: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        audioSessionRequested = true
        sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                if forRecording {
                    try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
                } else {
                    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                }
                try session.setActive(true)
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    private func deactivateAudioSessionIfIdle() {
        guard audioSessionRequested,
              dictationToken == nil,
              !synthesizer.isSpeaking,
              activeUtteranceID == nil,
              activePlayerID == nil,
              cloudSpeechTask == nil else { return }
        audioSessionRequested = false
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Speech-to-Text Dictation

    func startDictation(
        onTranscript: @escaping (String) -> Void
    ) {
        if isRecording || dictationToken != nil {
            stopDictation()
            return
        }
        speechError = nil
        let token = UUID()
        dictationToken = token
        activeRecordingHandler = onTranscript

        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard let self, self.dictationToken == token else { return }
                guard authStatus == .authorized else {
                    self.speechError = String(localized: "请在系统设置中允许语音识别权限后再使用语音输入。")
                    self.stopDictation()
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard self.dictationToken == token else { return }
                        if granted {
                            self.beginAudioCapture()
                        } else {
                            self.speechError = String(localized: "请在系统设置中允许麦克风权限后再使用语音输入。")
                            self.stopDictation()
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    func stopDictationIfActive() -> Bool {
        guard isDictationActive else { return false }
        stopDictation()
        return true
    }

    func stopDictation() {
        dictationToken = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        activeRecordingHandler = nil
        isRecording = false
        deactivateAudioSessionIfIdle()
    }

    func beginSimulatedDictationForTesting(onTranscript: @escaping (String) -> Void) {
        stopDictation()
        speechError = nil
        dictationToken = UUID()
        activeRecordingHandler = onTranscript
        isRecording = true
    }

    func emitSimulatedTranscriptForTesting(_ transcript: String, isFinal: Bool = false) {
        guard dictationToken != nil else { return }
        activeRecordingHandler?(transcript)
        if isFinal {
            stopDictation()
        }
    }

    private func beginAudioCapture() {
        stopSpeaking()
        guard let token = dictationToken else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            speechError = String(localized: "当前设备暂不支持语音识别。")
            stopDictation()
            return
        }
        activateAudioSession(forRecording: true) { [weak self] error in
            guard let self, self.dictationToken == token else { return }
            if let error {
                self.speechError = error.localizedDescription
                self.stopDictation()
                return
            }
            self.startRecognition(recognizer, token: token)
        }
    }

    private func startRecognition(_ recognizer: SFSpeechRecognizer, token: UUID) {
        do {
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                speechError = String(localized: "当前设备暂不支持语音识别。")
                stopDictation()
                return
            }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            self.audioEngine = engine
            self.recognitionRequest = request
            engine.prepare()
            try engine.start()

            self.isRecording = true

            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.dictationToken == token else { return }
                    if let result {
                        self.activeRecordingHandler?(result.bestTranscription.formattedString)
                        if result.isFinal {
                            self.stopDictation()
                        }
                    } else if let error {
                        if (error as NSError).code != 216 { // ignore user cancellation
                            self.speechError = error.localizedDescription
                        }
                        self.stopDictation()
                    }
                }
            }
        } catch {
            speechError = error.localizedDescription
            stopDictation()
        }
    }
}
