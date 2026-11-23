import SwiftUI
import UniformTypeIdentifiers

private enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case whisper
    case localSpeech

    var id: String { rawValue }
}

struct AudioTranscriptionSheet: View {
    let providers: [ProviderConfig]
    let onSubmit: (_ transcript: String, _ sourceLabel: String?, _ mode: TranscriptActionMode, _ autoExtractSchedule: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preferences = AppPreferences.shared
    @State private var recorder = AudioRecorderService()
    @State private var consent = AIConsentGate()

    @State private var selectedEngine: TranscriptionEngine = .whisper
    @State private var stagedFileName: String?
    @State private var stagedAudioData: Data?
    @State private var isTemporaryRecording = false
    @State private var stagedTempURL: URL?

    @State private var transcriptText = ""
    @State private var isTranscribing = false
    @State private var errorMessage: String?
    @State private var autoExtractSchedule = true
    @State private var showAudioImporter = false

    private var activeProvider: ProviderConfig? {
        AudioTranscriptionService.resolveAudioProvider(
            in: providers,
            preferredID: preferences.audioTranscriptionProviderID
        )
    }

    private var formattedSize: String {
        guard let count = stagedAudioData?.count else { return "" }
        if count >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(count) / (1024.0 * 1024.0))
        }
        if count >= 1024 {
            return String(format: "%.1f KB", Double(count) / 1024.0)
        }
        return "\(count) B"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("识别引擎", selection: $selectedEngine) {
                        Text("Whisper 云端").tag(TranscriptionEngine.whisper)
                        Text("设备免费识别").tag(TranscriptionEngine.localSpeech)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isTranscribing)

                    if selectedEngine == .localSpeech {
                        let lang = preferences.audioTranscriptionLanguage.isEmpty
                            ? String(localized: "系统默认语言")
                            : preferences.audioTranscriptionLanguage
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple 语音识别（免 Key）")
                                    .font(.subheadline.weight(.medium))
                                Text("识别语言：\(lang) · 适合会议录音与口述免费转写")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "mic.badge.plus")
                                .foregroundStyle(preferences.accentTheme.readableText)
                        }
                    } else if let provider = activeProvider {
                        let lang = preferences.audioTranscriptionLanguage.isEmpty
                            ? String(localized: "自动识别")
                            : preferences.audioTranscriptionLanguage
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(provider.name) · \(preferences.audioTranscriptionModel)")
                                    .font(.subheadline.weight(.medium))
                                Text("识别语言：\(lang)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "waveform")
                                .foregroundStyle(preferences.accentTheme.readableText)
                        }
                    } else {
                        Label {
                            Text("暂未配置可用的 OpenAI 兼容服务商，可切换上方「设备免费识别」或先配置 Whisper Key。")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("转写接口")
                }

                Section {
                    if recorder.isRecording {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            AudioWaveformStrip(
                                levels: recorder.levelHistory,
                                isPaused: recorder.isPaused,
                                tintColor: preferences.accentTheme.tintColor
                            )
                            HStack {
                                Text(recorder.isPaused ? "已暂停" : "正在录音")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(recorder.isPaused ? .orange : .red)
                                Spacer()
                                let mins = recorder.elapsedSeconds / 60
                                let secs = recorder.elapsedSeconds % 60
                                Text(String(format: "%02d:%02d", mins, secs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    HStack(spacing: DS.Spacing.sm) {
                        if recorder.isRecording {
                            Button {
                                if recorder.isPaused {
                                    recorder.resumeRecording()
                                } else {
                                    recorder.pauseRecording()
                                }
                            } label: {
                                Label(
                                    recorder.isPaused ? String(localized: "继续") : String(localized: "暂停"),
                                    systemImage: recorder.isPaused ? "play.circle.fill" : "pause.circle.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(recorder.isPaused ? preferences.accentTheme.tintColor : .orange)
                            .disabled(isTranscribing)

                            Button {
                                if let url = recorder.stopRecording() {
                                    loadRecordedFile(from: url)
                                }
                            } label: {
                                let mins = recorder.elapsedSeconds / 60
                                let secs = recorder.elapsedSeconds % 60
                                Label(
                                    String(format: String(localized: "停止 %02d:%02d"), mins, secs),
                                    systemImage: "stop.circle.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(isTranscribing)
                        } else {
                            Button {
                                recorder.stopPreviewPlayback()
                                cleanupStagedTempFile()
                                stagedFileName = nil
                                stagedAudioData = nil
                                errorMessage = nil
                                recorder.startRecording()
                            } label: {
                                Label(String(localized: "开始录音"), systemImage: "mic.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(preferences.accentTheme.tintColor)
                            .disabled(isTranscribing)

                            Button {
                                recorder.stopPreviewPlayback()
                                showAudioImporter = true
                            } label: {
                                Label("导入音频", systemImage: "doc.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTranscribing)
                        }
                    }
                    .padding(.vertical, 4)

                    if let fileName = stagedFileName, let data = stagedAudioData {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "music.note")
                                .foregroundStyle(preferences.accentTheme.readableText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(formattedSize)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                recorder.togglePreviewPlayback(url: stagedTempURL, data: data)
                            } label: {
                                Image(systemName: recorder.isPlayingPreview ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(recorder.isRecording || isTranscribing)
                            .accessibilityLabel(recorder.isPlayingPreview ? "停止试听" : "试听")

                            Button {
                                requestTranscribe()
                            } label: {
                                if isTranscribing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("转成文字")
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled((selectedEngine == .whisper && activeProvider == nil) || isTranscribing || recorder.isRecording)
                        }
                    }

                    if let err = errorMessage ?? recorder.errorMessage {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("音频采集")
                } footer: {
                    Text("支持现场录音及 m4a / mp3 / wav / ogg / webm / flac（单文件上限 25 MB）。")
                }

                Section {
                    TextEditor(text: $transcriptText)
                        .frame(minHeight: 130)
                        .font(.body)
                } header: {
                    Text("转写文本（可编辑校对）")
                }

                if !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Toggle(isOn: $autoExtractSchedule) {
                            Label("生成纪要后自动提取待办写入日历", systemImage: "calendar.badge.plus")
                        }

                        Button {
                            dismiss()
                            onSubmit(transcriptText, stagedFileName, .meetingMinutes, autoExtractSchedule)
                        } label: {
                            Label("生成会议纪要并发送", systemImage: "list.clipboard")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTranscribing)

                        Button {
                            dismiss()
                            onSubmit(transcriptText, stagedFileName, .voiceNoteCleanup, false)
                        } label: {
                            Label("整理为口述笔记", systemImage: "text.alignleft")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isTranscribing)

                        Button {
                            dismiss()
                            onSubmit(transcriptText, stagedFileName, .insertRaw, false)
                        } label: {
                            Label("仅填入输入框", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isTranscribing)
                    }
                }
            }
            .navigationTitle("录音与音频转会议纪要")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        recorder.stopPreviewPlayback()
                        recorder.cancelAndDelete()
                        cleanupStagedTempFile()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showAudioImporter,
                allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav]
                    + ["m4a", "ogg", "webm", "flac", "aac"].compactMap { UTType(filenameExtension: $0) },
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        do {
                            let data = try await Task.detached(priority: .userInitiated) {
                                try AudioTranscriptionService.readBoundedAudioData(from: url)
                            }.value
                            cleanupStagedTempFile()
                            stagedFileName = AudioTranscriptionService.sanitizeFileName(url.lastPathComponent)
                            stagedAudioData = data
                            isTemporaryRecording = false
                            errorMessage = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                case .failure(let err):
                    errorMessage = err.localizedDescription
                }
            }
            .aiConsentSheet(consent)
            .onAppear {
                if activeProvider == nil {
                    selectedEngine = .localSpeech
                }
            }
            .onDisappear {
                recorder.stopPreviewPlayback()
                if recorder.isRecording {
                    recorder.cancelAndDelete()
                }
                cleanupStagedTempFile()
            }
        }
    }

    private func loadRecordedFile(from url: URL) {
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try AudioTranscriptionService.readBoundedAudioData(from: url)
                }.value
                stagedTempURL = url
                isTemporaryRecording = true
                stagedFileName = url.lastPathComponent
                stagedAudioData = data
                errorMessage = nil
            } catch {
                try? FileManager.default.removeItem(at: url)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cleanupStagedTempFile() {
        recorder.stopPreviewPlayback()
        if isTemporaryRecording, let url = stagedTempURL {
            try? FileManager.default.removeItem(at: url)
        }
        stagedTempURL = nil
        isTemporaryRecording = false
    }

    private func requestTranscribe() {
        recorder.stopPreviewPlayback()
        if selectedEngine == .localSpeech {
            performLocalTranscription()
            return
        }
        guard let provider = activeProvider else {
            errorMessage = String(localized: "请先配置并启用 OpenAI 兼容服务商，或切换为「设备免费识别」。")
            return
        }
        let recipient = AppCompliance.recipient(
            provider: provider.name,
            model: preferences.audioTranscriptionModel,
            baseURL: provider.baseURL
        )
        consent.perform(recipients: [recipient]) {
            performTranscription(using: provider)
        }
    }

    private func performLocalTranscription() {
        guard let data = stagedAudioData, let fileName = stagedFileName else { return }
        let ext = (fileName as NSString).pathExtension
        let language = preferences.audioTranscriptionLanguage.isEmpty ? nil : preferences.audioTranscriptionLanguage
        runTranscriptionTask {
            try await LocalSpeechTranscriber.transcribe(
                audioData: data,
                fileExtension: ext,
                languageCode: language
            )
        }
    }

    private func performTranscription(using provider: ProviderConfig) {
        guard let data = stagedAudioData, let fileName = stagedFileName else { return }
        let request = AudioTranscriptionRequest(
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            apiKeys: provider.extraAPIKeys,
            customHeaders: provider.resolvedCustomHeaders,
            model: preferences.audioTranscriptionModel,
            language: preferences.audioTranscriptionLanguage,
            fileName: fileName,
            mimeType: AudioTranscriptionService.mimeType(forFileName: fileName),
            audioData: data
        )
        runTranscriptionTask {
            try await AudioTranscriptionService.transcribe(request)
        }
    }

    private func runTranscriptionTask(_ operation: @escaping @Sendable () async throws -> String) {
        isTranscribing = true
        errorMessage = nil
        Task {
            do {
                let text = try await operation()
                await MainActor.run {
                    if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        transcriptText = text
                    } else {
                        transcriptText += "\n\n\(text)"
                    }
                    isTranscribing = false
                    cleanupStagedTempFile()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isTranscribing = false
                }
            }
        }
    }
}

private struct AudioWaveformStrip: View {
    let levels: [Float]
    let isPaused: Bool
    let tintColor: Color

    var body: some View {
        let capacity = AudioMeteringNormalizer.maxSamples
        let padCount = max(0, capacity - levels.count)
        let displayLevels = Array(repeating: Float(0.08), count: padCount) + levels.suffix(capacity)

        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, level in
                let isPlaceholder = index < padCount
                Capsule(style: .continuous)
                    .fill(
                        isPlaceholder
                            ? Color.secondary.opacity(0.22)
                            : (isPaused ? Color.orange.opacity(0.75) : tintColor)
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, CGFloat(level) * 28))
            }
        }
        .frame(height: 30)
        .animation(.easeOut(duration: 0.09), value: displayLevels)
    }
}
