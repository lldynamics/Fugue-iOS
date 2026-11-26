import SwiftUI
import SwiftData
import AVFAudio

struct LiveVoiceView: View {
    @Query private var providers: [ProviderConfig]
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @State private var selected: UUID?
    @AppStorage("model.liveVoiceID") private var model = ""
    @State private var voice = LiveVoiceSession()
    @State private var consent = AIConsentGate()
    @State private var saved = false
    var body: some View {
        Form {
            let ready = providers.filter { $0.hasConfiguredChatAPI && $0.protocolType == .gemini && URLComponents(string: $0.baseURL)?.host == "generativelanguage.googleapis.com" }
            Picker("Gemini 账号", selection: $selected) {
                Text("选择账号").tag(nil as UUID?)
                ForEach(ready) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(voice.running)
            TextField("支持 Live 音频的模型 ID", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(voice.running)
            if voice.running { Button("结束通话") { finish() } }
            else if let provider = ready.first(where: { $0.id == selected }), voice.lines.isEmpty {
                Button("开始向 \(provider.name) 传送麦克风声音") {
                    let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    consent.perform(recipients: [AppCompliance.recipient(provider: provider.name, model: id, baseURL: provider.baseURL)]) {
                        Task { await voice.start(provider: provider, model: id) }
                    }
                }.disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(voice.status)
            ForEach(voice.lines) { line in VStack(alignment: .leading) { Text(line.role == .user ? "你" : "模型").font(.caption); Text(line.text) } }
            if !voice.running && !voice.lines.isEmpty {
                if !saved { Button("保存文字到对话") { save() } }
                else { Button("开始新通话") { voice.lines = []; saved = false } }
            }
        }.navigationTitle("实时语音").aiConsentSheet(consent)
        .onChange(of: voice.running) { if !voice.running { save() } }
        .onDisappear { finish() }
        .onChange(of: phase) { if phase == .background { finish() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in if voice.running { finish() } }
    }
    private func finish() { voice.stop(); save() }
    private func save() {
        guard !saved, !voice.lines.isEmpty else { return }
        let chat = Conversation(title: "实时语音 · " + model)
        context.insert(chat)
        for (index,line) in voice.lines.enumerated() {
            let message = ChatMessage(role: line.role, content: line.text, sortIndex: index)
            message.modelID = model; message.modelDisplayName = model; message.conversation = chat
            context.insert(message)
        }
        do { try context.save(); saved = true } catch { context.delete(chat); voice.status = error.localizedDescription }
    }
}
