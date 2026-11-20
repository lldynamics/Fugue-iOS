import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import Observation

@MainActor
@Observable
final class SpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechService()

    private(set) var speakingMessageID: UUID?
    private(set) var isRecording = false
    var speechError: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var activeUtteranceID: ObjectIdentifier?
    @ObservationIgnored private var dictationToken: UUID?
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var activeRecordingHandler: ((String) -> Void)?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

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
                if self.isRecording { self.stopDictation() }
                if self.speakingMessageID != nil { self.stopSpeaking() }
            }
        }
    }

    // MARK: - Text-to-Speech

    func toggleSpeaking(messageID: UUID, text: String, personaID: UUID? = nil) {
        if speakingMessageID == messageID && synthesizer.isSpeaking {
            stopSpeaking()
            return
        }
        if isRecording {
            stopDictation()
        }
        stopSpeaking()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        configurePlaybackAudioSession()
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = preferredVoice(for: cleaned, personaID: personaID)
        if let personaID {
            let bucket = Self.personaVoiceBucket(for: personaID)
            let pitchOffsets: [Float] = [0.92, 1.0, 1.08, 0.96, 1.12, 1.04]
            let rateMultipliers: [Float] = [0.97, 1.02, 0.95, 1.05, 0.99, 1.03]
            utterance.pitchMultiplier = pitchOffsets[bucket % pitchOffsets.count]
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * rateMultipliers[bucket % rateMultipliers.count]
        } else {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        }
        activeUtteranceID = ObjectIdentifier(utterance)
        speakingMessageID = messageID
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        let hadActiveSpeech = activeUtteranceID != nil || speakingMessageID != nil || synthesizer.isSpeaking
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleUtteranceEnded(finishedID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelledID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleUtteranceEnded(cancelledID)
        }
    }

    func handleUtteranceEnded(_ utteranceID: ObjectIdentifier) {
        if activeUtteranceID == utteranceID {
            activeUtteranceID = nil
            speakingMessageID = nil
            deactivateAudioSessionIfIdle()
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

    private func configurePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    private func deactivateAudioSessionIfIdle() {
        guard !isRecording && !synthesizer.isSpeaking && activeUtteranceID == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Speech-to-Text Dictation

    func startDictation(onTranscript: @escaping (String) -> Void) {
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
                    self.dictationToken = nil
                    self.activeRecordingHandler = nil
                    self.speechError = String(localized: "请在系统设置中允许语音识别权限后再使用语音输入。")
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard self.dictationToken == token else { return }
                        if granted {
                            self.beginAudioCapture()
                        } else {
                            self.dictationToken = nil
                            self.activeRecordingHandler = nil
                            self.speechError = String(localized: "请在系统设置中允许麦克风权限后再使用语音输入。")
                        }
                    }
                }
            }
        }
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

    private func beginAudioCapture() {
        stopSpeaking()
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            speechError = String(localized: "当前设备暂不支持语音识别。")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

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

            engine.prepare()
            try engine.start()

            self.audioEngine = engine
            self.recognitionRequest = request
            self.isRecording = true

            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
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
