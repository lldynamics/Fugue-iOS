import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioRecorderService: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var elapsedSeconds = 0
    var errorMessage: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var currentFileURL: URL?
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    func startRecording() {
        guard !isRecording else { return }
        errorMessage = nil
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
            guard created.prepareToRecord(), created.record() else {
                throw LLMError.apiError(String(localized: "无法启动音频录制。"))
            }
            self.recorder = created
            self.currentFileURL = fileURL
            self.elapsedSeconds = 0
            self.isRecording = true

            self.timerTask?.cancel()
            self.timerTask = Task { @MainActor [weak self] in
                while let self, self.isRecording, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled && self.isRecording {
                        self.elapsedSeconds += 1
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() -> URL? {
        timerTask?.cancel()
        timerTask = nil
        guard let activeRecorder = recorder else {
            isRecording = false
            return nil
        }
        let url = currentFileURL
        activeRecorder.stop()
        recorder = nil
        currentFileURL = nil
        isRecording = false
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
        elapsedSeconds = 0
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
