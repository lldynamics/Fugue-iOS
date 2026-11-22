import SwiftUI
import UniformTypeIdentifiers

struct AudioTranscriptionSheet: View {
    let providers: [ProviderConfig]
    let onSubmit: (_ transcript: String, _ sourceLabel: String?, _ mode: TranscriptActionMode, _ autoExtractSchedule: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preferences = AppPreferences.shared
    @State private var recorder = AudioRecorderService()
    @State private var consent = AIConsentGate()

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
                    if let provider = activeProvider {
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
                            Text("暂未配置可用的 OpenAI 兼容服务商，请先在「服务商」页面启用并填入 Key。")
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
                    HStack(spacing: DS.Spacing.sm) {
                        Button {
                            if recorder.isRecording {
                                if let url = recorder.stopRecording() {
                                    loadRecordedFile(from: url)
                                }
                            } else {
                                cleanupStagedTempFile()
                                stagedFileName = nil
                                stagedAudioData = nil
                                errorMessage = nil
                                recorder.startRecording()
                            }
                        } label: {
                            let mins = recorder.elapsedSeconds / 60
                            let secs = recorder.elapsedSeconds % 60
                            Label(
                                recorder.isRecording
                                    ? String(format: String(localized: "停止录音 %02d:%02d"), mins, secs)
                                    : String(localized: "开始录音"),
                                systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(recorder.isRecording ? .red : preferences.accentTheme.tintColor)
                        .disabled(isTranscribing)

                        Button {
                            showAudioImporter = true
                        } label: {
                            Label("导入音频", systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(recorder.isRecording || isTranscribing)
                    }
                    .padding(.vertical, 4)

                    if let fileName = stagedFileName, stagedAudioData != nil {
                        HStack {
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
                            .disabled(activeProvider == nil || isTranscribing || recorder.isRecording)
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
            .onDisappear {
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
        if isTemporaryRecording, let url = stagedTempURL {
            try? FileManager.default.removeItem(at: url)
        }
        stagedTempURL = nil
        isTemporaryRecording = false
    }

    private func requestTranscribe() {
        guard let provider = activeProvider else {
            errorMessage = String(localized: "请先配置并启用 OpenAI 兼容服务商。")
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

    private func performTranscription(using provider: ProviderConfig) {
        guard let data = stagedAudioData, let fileName = stagedFileName else { return }
        isTranscribing = true
        errorMessage = nil
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
        Task {
            do {
                let text = try await AudioTranscriptionService.transcribe(request)
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
