import Foundation
import AVFoundation
import Speech
import Observation

// MARK: - Word-Level Shadowing Alignment & Pronunciation Scoring

struct ShadowingEvaluationSummary: Equatable, Sendable {
    let score: Int
    let spokenTranscript: String
    let tokens: [ShadowingWordResult]

    var missedWords: [String] {
        tokens.filter { $0.state == .missed }.map(\.expectedWord)
    }

    var fuzzyWords: [String] {
        tokens.filter { $0.state == .fuzzy }.map(\.expectedWord)
    }
}

enum EnglishShadowingEvaluator {
    struct SpokenWordToken: Sendable {
        let raw: String
        let normalized: String
        let confidence: Float
    }

    nonisolated static func cleanToken(_ word: String) -> String {
        let apostrophesNormalized = word
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))
        let scalars = apostrophesNormalized.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    nonisolated static func evaluate(
        expectedSentence: String,
        spokenTranscript: String,
        segmentConfidences: [(word: String, confidence: Float)] = []
    ) -> ShadowingEvaluationSummary {
        let expectedDisplayWords = expectedSentence
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !cleanToken($0).isEmpty }

        guard !expectedDisplayWords.isEmpty else {
            return ShadowingEvaluationSummary(score: 0, spokenTranscript: spokenTranscript, tokens: [])
        }

        let spokenTokens: [SpokenWordToken] = {
            if !segmentConfidences.isEmpty {
                let mapped = segmentConfidences.compactMap { pair -> SpokenWordToken? in
                    let norm = cleanToken(pair.word)
                    guard !norm.isEmpty else { return nil }
                    return SpokenWordToken(raw: pair.word, normalized: norm, confidence: pair.confidence)
                }
                if !mapped.isEmpty { return mapped }
            }
            return spokenTranscript
                .components(separatedBy: .whitespacesAndNewlines)
                .compactMap { raw in
                    let norm = cleanToken(raw)
                    guard !norm.isEmpty else { return nil }
                    return SpokenWordToken(raw: raw, normalized: norm, confidence: 0.85)
                }
        }()

        if spokenTokens.isEmpty {
            let missedAll = expectedDisplayWords.map {
                ShadowingWordResult(expectedWord: $0, state: .missed, heardWord: nil)
            }
            return ShadowingEvaluationSummary(score: 0, spokenTranscript: spokenTranscript, tokens: missedAll)
        }

        let expectedNorms = expectedDisplayWords.map { cleanToken($0) }
        let n = expectedNorms.count
        let m = spokenTokens.count

        // Dynamic programming alignment between expectedNorms[0..<n] and spokenTokens[0..<m]
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i * 2 }
        for j in 0...m { dp[0][j] = j * 2 }

        for i in 1...n {
            for j in 1...m {
                let matchCost = wordMatchCost(expectedNorms[i - 1], spokenTokens[j - 1].normalized)
                let sub = dp[i - 1][j - 1] + matchCost
                let del = dp[i - 1][j] + 2
                let ins = dp[i][j - 1] + 2
                var best = min(sub, min(del, ins))
                // 2 spoken words matching 1 expected contraction (e.g., "I" + "will" == "I'll")
                if j >= 2,
                   canonicalContraction(expectedNorms[i - 1]) == spokenTokens[j - 2].normalized + spokenTokens[j - 1].normalized {
                    best = min(best, dp[i - 1][j - 2])
                }
                // 1 spoken contraction matching 2 expected words (e.g., "I'll" == "I" + "will")
                if i >= 2,
                   expectedNorms[i - 2] + expectedNorms[i - 1] == canonicalContraction(spokenTokens[j - 1].normalized) {
                    best = min(best, dp[i - 2][j - 1])
                }
                dp[i][j] = best
            }
        }

        // Backtrack alignment
        var results = Array<ShadowingWordResult?>(repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i >= 1 && j >= 2,
               canonicalContraction(expectedNorms[i - 1]) == spokenTokens[j - 2].normalized + spokenTokens[j - 1].normalized,
               dp[i][j] == dp[i - 1][j - 2] {
                let minConf = min(spokenTokens[j - 2].confidence, spokenTokens[j - 1].confidence)
                let state: ShadowingWordState = (minConf > 0 && minConf < 0.48) ? .fuzzy : .accurate
                results[i - 1] = ShadowingWordResult(
                    expectedWord: expectedDisplayWords[i - 1],
                    state: state,
                    heardWord: nil
                )
                i -= 1
                j -= 2
                continue
            }
            if i >= 2 && j >= 1,
               expectedNorms[i - 2] + expectedNorms[i - 1] == canonicalContraction(spokenTokens[j - 1].normalized),
               dp[i][j] == dp[i - 2][j - 1] {
                let conf = spokenTokens[j - 1].confidence
                let state: ShadowingWordState = (conf > 0 && conf < 0.48) ? .fuzzy : .accurate
                results[i - 1] = ShadowingWordResult(expectedWord: expectedDisplayWords[i - 1], state: state, heardWord: nil)
                results[i - 2] = ShadowingWordResult(expectedWord: expectedDisplayWords[i - 2], state: state, heardWord: nil)
                i -= 2
                j -= 1
                continue
            }
            if i > 0 && j > 0 {
                let cost = wordMatchCost(expectedNorms[i - 1], spokenTokens[j - 1].normalized)
                if dp[i][j] == dp[i - 1][j - 1] + cost {
                    let spoken = spokenTokens[j - 1]
                    let state: ShadowingWordState
                    if cost == 0 {
                        // Confidence 0 means offline recognizer didn't score confidence (treat as accurate)
                        state = (spoken.confidence > 0 && spoken.confidence < 0.48) ? .fuzzy : .accurate
                    } else if cost == 1 {
                        state = .fuzzy
                    } else {
                        state = .missed
                    }
                    results[i - 1] = ShadowingWordResult(
                        expectedWord: expectedDisplayWords[i - 1],
                        state: state,
                        heardWord: state == .accurate ? nil : spoken.raw
                    )
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0 && (j == 0 || dp[i][j] == dp[i - 1][j] + 2) {
                results[i - 1] = ShadowingWordResult(
                    expectedWord: expectedDisplayWords[i - 1],
                    state: .missed,
                    heardWord: nil
                )
                i -= 1
            } else {
                j -= 1
            }
        }

        let finalTokens = results.enumerated().map { idx, item in
            item ?? ShadowingWordResult(expectedWord: expectedDisplayWords[idx], state: .missed, heardWord: nil)
        }

        var weightedSum = 0.0
        for item in finalTokens {
            switch item.state {
            case .accurate: weightedSum += 1.0
            case .fuzzy: weightedSum += 0.65
            case .missed: weightedSum += 0.0
            }
        }
        let rawScore = Int(((weightedSum / Double(finalTokens.count)) * 100.0).rounded())
        return ShadowingEvaluationSummary(
            score: min(max(rawScore, 0), 100),
            spokenTranscript: spokenTranscript,
            tokens: finalTokens
        )
    }

    private nonisolated static func wordMatchCost(_ expected: String, _ spoken: String) -> Int {
        if expected == spoken { return 0 }
        if canonicalContraction(expected) == canonicalContraction(spoken) { return 0 }
        let dist = levenshtein(expected, spoken)
        if expected.count >= 4 && dist == 1 { return 1 }
        if expected.count >= 7 && dist == 2 { return 1 }
        return 3
    }

    private nonisolated static func canonicalContraction(_ word: String) -> String {
        switch word {
        case "i'm": return "iam"
        case "i'll": return "iwill"
        case "we'll": return "wewill"
        case "you'll": return "youwill"
        case "don't": return "donot"
        case "doesn't": return "doesnot"
        case "didn't": return "didnot"
        case "can't": return "cannot"
        case "won't": return "willnot"
        case "it's": return "itis"
        case "that's": return "thatis"
        case "we're": return "weare"
        case "they're": return "theyare"
        case "you're": return "youare"
        case "i've": return "ihave"
        case "we've": return "wehave"
        default: return word.replacingOccurrences(of: "'", with: "")
        }
    }

    private nonisolated static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        for (i, ca) in aChars.enumerated() {
            var curr = [i + 1] + Array(repeating: 0, count: bChars.count)
            for (j, cb) in bChars.enumerated() {
                let cost = ca == cb ? 0 : 1
                curr[j + 1] = min(curr[j] + 1, min(prev[j + 1] + 1, prev[j] + cost))
            }
            prev = curr
        }
        return prev[bChars.count]
    }
}

// MARK: - Dedicated English TTS & STT Coach Service

@MainActor
@Observable
final class EnglishSpeechCoachService: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = EnglishSpeechCoachService()

    private(set) var isSpeaking = false
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0
    var speechError: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var captureToken: UUID?
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speakEnglish(
        _ text: String,
        accent: EnglishAccentPreference = .us,
        slow: Bool = false
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if isRecording {
            stopRecording()
        }
        SpeechService.shared.stopSpeaking()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = bestEnglishVoice(for: accent)
        utterance.rate = slow ? 0.39 : 0.50
        utterance.pitchMultiplier = 1.0
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    private func bestEnglishVoice(for accent: EnglishAccentPreference) -> AVSpeechSynthesisVoice? {
        let targetLang = accent.localeIdentifier.lowercased()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased() == targetLang
        }
        if let premium = candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
            return premium
        }
        return AVSpeechSynthesisVoice(language: accent.localeIdentifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func startEnglishRecording(
        accent: EnglishAccentPreference = .us,
        onLiveUpdate: @escaping (_ transcript: String, _ segments: [(word: String, confidence: Float)], _ isFinal: Bool) -> Void
    ) {
        if isRecording {
            stopRecording()
            return
        }
        stopSpeaking()
        SpeechService.shared.stopDictation()
        speechError = nil

        let token = UUID()
        captureToken = token

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self, self.captureToken == token else { return }
                guard status == .authorized else {
                    self.speechError = String(localized: "请在系统设置中允许语音识别权限后再使用英文跟读。")
                    self.stopRecording()
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard self.captureToken == token else { return }
                        if granted {
                            self.beginEnglishCaptureSession(accent: accent, token: token, onLiveUpdate: onLiveUpdate)
                        } else {
                            self.speechError = String(localized: "请在系统设置中允许麦克风权限后再使用英文跟读。")
                            self.stopRecording()
                        }
                    }
                }
            }
        }
    }

    func stopRecording() {
        captureToken = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        audioLevel = 0
    }

    private func beginEnglishCaptureSession(
        accent: EnglishAccentPreference,
        token: UUID,
        onLiveUpdate: @escaping (_ transcript: String, _ segments: [(word: String, confidence: Float)], _ isFinal: Bool) -> Void
    ) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: accent.localeIdentifier))
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            speechError = String(localized: "当前设备暂不支持英文语音识别，你也可以直接输入英文练习。")
            stopRecording()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                speechError = String(localized: "未检测到可用的麦克风输入通道。")
                stopRecording()
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
                let count = Int(buffer.frameLength)
                var sum: Float = 0
                let samples = channelData[0]
                for idx in 0..<count {
                    sum += samples[idx] * samples[idx]
                }
                let level = min(max(sqrtf(sum / Float(max(1, count))) * 5.2, 0), 1)
                Task { @MainActor [weak self] in
                    guard let self, self.captureToken == token else { return }
                    self.audioLevel = level
                }
            }

            self.audioEngine = engine
            self.recognitionRequest = request
            engine.prepare()
            try engine.start()
            self.isRecording = true

            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.captureToken == token else { return }
                    if let result {
                        let pairs = result.bestTranscription.segments.map {
                            (word: $0.substring, confidence: $0.confidence)
                        }
                        onLiveUpdate(result.bestTranscription.formattedString, pairs, result.isFinal)
                        if result.isFinal {
                            self.stopRecording()
                        }
                    } else if let error {
                        if (error as NSError).code != 216 {
                            self.speechError = error.localizedDescription
                        }
                        self.stopRecording()
                    }
                }
            }
        } catch {
            speechError = error.localizedDescription
            stopRecording()
        }
    }
}
