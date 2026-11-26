import SwiftUI
import SwiftData
import AVFAudio

struct LiveVoiceView: View {
    @Query private var providers: [ProviderConfig]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @State private var selected: UUID?
    @AppStorage("model.liveVoiceID") private var geminiModel = ""
    @AppStorage("model.openAIRealtimeID") private var openAIModel = "gpt-realtime"
    @State private var activeModel = ""
    @State private var voice = LiveVoiceSession()
    @State private var consent = AIConsentGate()
    @State private var saved = false
    @State private var previousIdleTimer: Bool?
    var body: some View {
        Form {
            if !voice.running && voice.lines.isEmpty {
                NavigationLink { VoicePracticeView() } label: { Label("语言陪练", systemImage: "person.2.wave.2") }
                    .accessibilityIdentifier("liveVoice.practice")
            }
            let ready = providers.filter(LiveVoiceSession.supports)
            Picker("实时语音账号", selection: $selected) {
                Text("选择账号").tag(nil as UUID?)
                ForEach(ready) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(voice.running)
            let openAI = ready.first(where: { $0.id == selected }).map(LiveVoiceSession.isOpenAI) ?? false
            let model = openAI ? openAIModel : geminiModel
            TextField("实时音频模型 ID", text: openAI ? $openAIModel : $geminiModel).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(voice.running)
            if voice.running { Button("结束通话") { finish() } }
            else if let provider = ready.first(where: { $0.id == selected }), voice.lines.isEmpty {
                Button("开始向 \(provider.name) 传送麦克风声音") {
                    let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    consent.perform(recipients: [AppCompliance.recipient(provider: provider.name, model: id, baseURL: provider.baseURL)]) {
                        activeModel = id
                        Task { await voice.start(provider: provider, model: id) }
                    }
                }.accessibilityIdentifier("liveVoice.start").disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(voice.status).accessibilityIdentifier("liveVoice.status")
            if voice.interruptedPlaybackCount > 0 {
                Text("已打断 \(voice.interruptedPlaybackCount) 次").font(.caption).accessibilityIdentifier("liveVoice.interruptions")
            }
            LiveTranscriptSection(voice: voice)
            if !voice.running && !voice.lines.isEmpty {
                if !saved { Button("保存文字到对话") { save() } }
                else { Button("开始新通话") { voice.lines = []; saved = false } }
            }
        }.navigationTitle("实时语音").aiConsentSheet(consent)
        .onChange(of: providers.filter(LiveVoiceSession.supports).map(\.id), initial: true) { _, ids in
            guard !voice.running else { return }
            if selected.map(ids.contains) != true { selected = ids.count == 1 ? ids[0] : nil }
        }
        .onChange(of: voice.running) {
            if voice.running {
                previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
            } else { restoreIdleTimer(); save() }
        }
        .onDisappear { if voice.running { finish() } else { save() } }
        .onChange(of: phase) { if phase == .background { finish() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in if voice.running { finish() } }
    }
    private func restoreIdleTimer() {
        if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        previousIdleTimer = nil
    }
    private func finish() { voice.stop(); restoreIdleTimer(); save() }
    private func save() {
        guard !saved, !voice.lines.isEmpty else { return }
        do {
            _ = try LanguagePractice.saveTranscript(voice.lines, model: activeModel, in: context)
            saved = true
        } catch { voice.status = error.localizedDescription }
    }
}

struct LiveTranscriptSection: View {
    let voice: LiveVoiceSession

    var body: some View {
        ForEach(voice.lines) { line in
            VStack(alignment: .leading, spacing: 4) {
                Text(line.role == .user ? "你" : "模型").font(.caption).foregroundStyle(.secondary)
                if line.interrupted { Text("已打断").font(.caption).foregroundStyle(.secondary) }
                Text(line.text).accessibilityIdentifier(line.role == .user ? "liveVoice.transcript.user" : "liveVoice.transcript.assistant")
            }
        }
    }
}
