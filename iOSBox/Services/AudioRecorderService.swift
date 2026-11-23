import AVFoundation
import Foundation
import Observation

enum AudioMeteringNormalizer {
    static let maxSamples = 36

    static func normalize(decibels: Float) -> Float {
        guard decibels.isFinite else { return 0.08 }
        if decibels <= -55 { return 0.08 }
        if decibels >= 0 { return 1.0 }
        let ratio = (decibels + 55) / 55
        return 0.08 + ratio * 0.92
    }

    static func appendSample(_ sample: Float, to history: [Float], capacity: Int = maxSamples) -> [Float] {
        var next = history
        next.append(min(max(sample, 0.08), 1.0))
        if next.count > capacity {
            next.removeFirst(next.count - capacity)
        }
        return next
    }
}

@MainActor
@Observable
final class AudioRecorderService: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsedSeconds = 0
    private(set) var levelHistory: [Float] = []
    private(set) var isPlayingPreview = false
    var errorMessage: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var currentFileURL: URL?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var activeSubticks = 0

    func startRecording() {
        guard !isRecording else { return }
        errorMessage = nil
        stopPreviewPlayback()
        SpeechService.shared.stopDictation()
        SpeechService.shared.stopSpeaking()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                self.errorMessage = String(localized: "请在系统设置中允许麦克风权限后再录音。")
                return
            }
            self.beginRecorder()
        }
    }

    func pauseRecording() {
        guard isRecording, !isPaused, let activeRecorder = recorder else { return }
        activeRecorder.pause()
        isPaused = true
    }

    func resumeRecording() {
        guard isRecording, isPaused, let activeRecorder = recorder else { return }
        if activeRecorder.record() {
            isPaused = false
        }
    }

    func togglePreviewPlayback(url: URL? = nil, data: Data? = nil) {
        if isPlayingPreview {
            stopPreviewPlayback()
            return
        }
        guard !isRecording else { return }
        stopPreviewPlayback()
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let created: AVAudioPlayer
            if let url {
                created = try AVAudioPlayer(contentsOf: url)
            } else if let data {
                created = try AVAudioPlayer(data: data)
            } else {
                return
            }
            created.delegate = self
            guard created.prepareToPlay(), created.play() else {
                throw LLMError.apiError(String(localized: "无法播放当前音频预览。"))
            }
            self.player = created
            self.isPlayingPreview = true
        } catch {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func stopPreviewPlayback() {
        player?.stop()
        player = nil
        isPlayingPreview = false
        if !isRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func beginRecorder() {
        cleanupStaleAudioFiles()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fugue-audio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let fileURL = dir.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000
        ]

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let created = try AVAudioRecorder(url: fileURL, settings: settings)
            created.delegate = self
            created.isMeteringEnabled = true
            guard created.prepareToRecord(), created.record() else {
                throw LLMError.apiError(String(localized: "无法启动音频录制。"))
            }
            self.recorder = created
            self.currentFileURL = fileURL
            self.elapsedSeconds = 0
            self.activeSubticks = 0
            self.levelHistory = []
            self.isPaused = false
            self.isRecording = true

            self.timerTask?.cancel()
            self.timerTask = Task { @MainActor [weak self] in
                while let self, self.isRecording, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !Task.isCancelled && self.isRecording && !self.isPaused {
                        self.sampleMeterAndTick()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    private func sampleMeterAndTick() {
        if let activeRecorder = recorder {
            activeRecorder.updateMeters()
            let sample = AudioMeteringNormalizer.normalize(decibels: activeRecorder.averagePower(forChannel: 0))
            levelHistory = AudioMeteringNormalizer.appendSample(sample, to: levelHistory)
        }
        activeSubticks += 1
        if activeSubticks >= 10 {
            activeSubticks = 0
            elapsedSeconds += 1
        }
    }

    func stopRecording() -> URL? {
        timerTask?.cancel()
        timerTask = nil
        guard let activeRecorder = recorder else {
            isRecording = false
            isPaused = false
            return nil
        }
        let url = currentFileURL
        activeRecorder.stop()
        recorder = nil
        currentFileURL = nil
        isRecording = false
        isPaused = false
        activeSubticks = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            if let url {
                try? FileManager.default.removeItem(at: url)
            }
            errorMessage = String(localized: "录音时间太短，未录到有效声音。")
            return nil
        }
        return url
    }

    func cancelAndDelete() {
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        recorder = nil
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentFileURL = nil
        isRecording = false
        isPaused = false
        elapsedSeconds = 0
        activeSubticks = 0
        levelHistory = []
        stopPreviewPlayback()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? String(localized: "录音编码失败。")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.errorMessage = message
            self.cancelAndDelete()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stopPreviewPlayback()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? String(localized: "音频播放失败。")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.errorMessage = message
            self.stopPreviewPlayback()
        }
    }

    private func cleanupStaleAudioFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fugue-audio", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        for file in entries {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
