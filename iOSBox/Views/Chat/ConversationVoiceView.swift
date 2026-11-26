import AVFAudio
import SwiftData
import SwiftUI

struct ConversationVoiceView<Timeline: View>: View {
    let chat: Conversation
    let omitMemory: Bool
    @ViewBuilder let timeline: (LiveVoiceSession) -> Timeline

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \PersonalMemory.createdAt) private var memories: [PersonalMemory]
    @AppStorage("chat.liveVoice.providerID") private var preferredID = ""
    @AppStorage("model.openAIRealtimeID") private var model = "gpt-realtime"
    @State private var providerID: UUID?
    @State private var excluded = Set<UUID>()
    @State private var consent = AIConsentGate()
    @State private var voice = LiveVoiceSession()
    @State private var writer: ConversationVoiceWriter?
    @State private var saveError: String?
    @State private var connectingAccount = false
    @State private var visible = false
    @State private var oldIdleTimer: Bool?

    private var accounts: [ProviderConfig] {
        providers.filter { LiveVoiceSession.isOpenAI($0) && LiveVoiceSession.supports($0) }
    }

    private var allowedMemories: [PersonalMemory] {
        guard !omitMemory, chat.assistanceSettings.usePersonalMemory else { return [] }
        let scope = chat.assistanceSettings.scopedMemoryIDs
        return memories.filter { $0.isEnabled && (scope?.contains($0.id) ?? true) }
    }

    private var selectedMemoryIDs: Set<UUID> { Set(allowedMemories.map(\.id)).subtracting(excluded) }

    private func snapshot(_ target: ResolvedModelTarget, now: Date) -> ConversationVoiceContext {
        ConversationVoiceContext(chat: chat, target: target, omitMemory: omitMemory,
                                 selectedIDs: selectedMemoryIDs, context: context, now: now)
    }

    var body: some View {
        NavigationStack {
            Group {
                if writer == nil { setup } else { call }
            }
            .navigationTitle("实时通话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if writer == nil || (!voice.running && saveError != nil) {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                }
            }
        }
        .sheet(isPresented: $connectingAccount) {
            FirstModelSetupSheet { target in
                preferredID = target.providerID.uuidString
                providerID = target.providerID
                connectingAccount = false
            }
        }
        .aiConsentSheet(consent)
        .interactiveDismissDisabled(writer != nil)
        .onAppear { visible = true }
        .onChange(of: accounts.map(\.id), initial: true) { _, ids in
            guard writer == nil, !ids.contains(where: { $0 == providerID }) else { return }
            providerID = [UUID(uuidString: preferredID), chat.primaryTarget?.providerID, ids.first]
                .compactMap { $0 }.first(where: ids.contains)
        }
        .onChange(of: voice.running) { _, running in
            if running {
                oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
            } else { saveAndReleaseAudio() }
        }
        .onChange(of: phase) { _, phase in if phase == .background { stopImmediately() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                stopImmediately()
            }
        }
        .onDisappear { visible = false; stopImmediately() }
    }

    private var setup: some View {
        Form {
            Section {
                if accounts.isEmpty {
                    Text("实时通话需要支持 Realtime 的 OpenAI 官方账号。")
                    Button("连接模型") { connectingAccount = true }
                } else {
                    Picker("语音账号", selection: $providerID) {
                        ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField("实时音频模型 ID", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } footer: {
                Text("麦克风声音、当前分支的近期文字、对话指令及选用的记忆将发往所选 OpenAI 账号。附件原件不会随通话发送。")
            }
            if !allowedMemories.isEmpty {
                DisclosureGroup("本次使用的个人记忆") {
                    ForEach(allowedMemories) { memory in
                        Toggle(memory.content, isOn: Binding(get: { !excluded.contains(memory.id) }, set: {
                            if $0 { excluded.remove(memory.id) } else { excluded.insert(memory.id) }
                        }))
                    }
                }
            }
            if let provider = accounts.first(where: { $0.id == providerID }) {
                Button("开始实时通话") { start(provider) }
                    .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("chatLive.start")
            }
        }
    }

    private var call: some View {
        VStack(spacing: 12) {
            Text(chat.title).font(.headline)
            Text(voice.status).font(.subheadline).foregroundStyle(.secondary)
            timeline(voice)
            if voice.incompleteTranscript { Text("部分转写未完成").font(.footnote) }
            if let saveError { Text(saveError).foregroundStyle(.red) }
            HStack {
                if voice.running {
                    Button { voice.muted.toggle() } label: {
                        Label(voice.muted ? "取消静音" : "静音", systemImage: voice.muted ? "mic.slash.fill" : "mic.fill")
                    }.disabled(voice.isFinishing)
                }
                Button(voice.running ? "结束通话" : "返回对话") {
                    Task {
                        guard !voice.isFinishing else { return }
                        if voice.running { await voice.finishWithTranscript() }
                        saveAndReleaseAudio()
                        if saveError == nil { dismiss() }
                    }
                }
                .disabled(voice.isFinishing)
                .accessibilityIdentifier("chatLive.end")
            }
            .buttonStyle(.bordered).padding(.bottom)
        }
    }

    private func start(_ provider: ProviderConfig) {
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = provider.makeTarget(for: ModelSpec(id: id))
        let now = Date()
        let prepared = snapshot(target, now: now)
        let current = {
            visible && phase == .active && chat.modelContext != nil && !chat.isDeleted &&
            !chat.isArenaMode && !chat.isGroupMode && !ChatEngine.shared.isGenerating(in: chat.id) &&
            accounts.contains(where: { $0.id == target.providerID }) && snapshot(target, now: now) == prepared
        }
        consent.perform(recipients: [AppCompliance.recipient(provider: provider.name, model: id, baseURL: provider.baseURL)],
                        isCurrent: current) {
            guard current(), writer == nil else { return }
            preferredID = provider.id.uuidString
            let sink = ConversationVoiceWriter(chat: chat, target: target, context: context,
                                               selectedMemoryIDs: selectedMemoryIDs, omitMemory: omitMemory)
            writer = sink
            voice.checkpoint = { lines in try sink.save(lines) }
            SpeechService.shared.stopSpeaking()
            SpeechService.shared.stopDictationIfActive()
            Task {
                guard visible, phase == .active, writer === sink else { return }
                await voice.start(provider: provider, model: id, chatContext: prepared, isCurrent: current)
            }
        }
    }

    private func saveAndReleaseAudio() {
        if let oldIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
            self.oldIdleTimer = nil
        }
        do {
            try writer?.save(voice.lines, ending: true)
            saveError = nil
        } catch { saveError = error.localizedDescription }
    }

    private func stopImmediately() {
        if voice.running { voice.stop() }
        saveAndReleaseAudio()
    }
}
