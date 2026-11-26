import AVFAudio
import SwiftData
import SwiftUI

struct VoicePracticeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query private var providers: [ProviderConfig]
    @State private var profile: PracticeProfile
    @State private var voice = LiveVoiceSession()
    @State private var consent = AIConsentGate()
    @State private var call: PracticeCall?
    @State private var saved: Conversation?
    @State private var requestReview = false
    @State private var previousIdleTimer: Bool?
    @State private var startTask: Task<Void, Never>?
    @State private var failure: String?

    private static let profileKey = "model.voicePractice.profile"

    init(course: EnglishDailyLesson? = nil, level: EnglishProficiencyLevel? = nil, savedLesson: Conversation? = nil) {
        let data = UserDefaults.standard.data(forKey: Self.profileKey)
        var draft = data.flatMap { try? JSONDecoder().decode(PracticeProfile.self, from: $0) } ?? PracticeProfile()
        if let level {
            draft.language = "en"
            draft.level = level
        }
        if let course {
            draft.scene = String([course.scenarioBrief, course.roleplayMission].filter { !$0.isEmpty }.joined(separator: " ").prefix(240))
        }
        _profile = State(initialValue: draft)
        _saved = State(initialValue: savedLesson)
    }

    var body: some View {
        Form {
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if let saved {
                if saved.assistanceSettings.voicePractice?.isResumable == true {
                    Section {
                        Button("继续上次练习") { resume(saved) }
                            .accessibilityIdentifier("practice.resume")
                        Button("结束本次练习") {
                            do { try PracticeCall.finishPaused(saved) } catch { failure = error.localizedDescription }
                        }
                    } footer: { Text("继续后会把最近已保存的对话发给原陪练账号。") }
                }
                PracticeReviewSection(chat: saved, reviewOnOpen: requestReview)
                Button("开始下一次练习") {
                    requestReview = false
                    self.saved = nil
                    failure = nil
                    voice.lines = []
                }.accessibilityIdentifier("practice.next")
            } else if let active = call?.chat.assistanceSettings.voicePractice {
                Section(active.profile.trimmedScene) {
                    Text(voice.status).accessibilityIdentifier("practice.status")
                    if voice.running {
                        if voice.speakerRequiresTapTurns {
                            Text("当前外放无法消除回声，本次练习使用点按发言。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if voice.usesTapTurns {
                            manualControls
                        } else if voice.readyForSpeech {
                            Button("改用点按发言") { Task { await voice.switchToTapTurns() } }
                                .disabled(voice.changingTurnMode || voice.isFinishing)
                                .accessibilityIdentifier("practice.switchToTap")
                        }
                        Button(active.reviewModelID.isEmpty ? "结束并保存" : "结束并复盘") {
                            requestReview = !active.reviewModelID.isEmpty
                            Task { await voice.finishPractice(); saveIfNeeded() }
                        }.disabled(voice.isFinishing).accessibilityIdentifier("practice.finish")
                    } else if failure != nil {
                        Button("重新保存练习") { saveIfNeeded() }
                    }
                }
                LiveTranscriptSection(voice: voice)
            } else {
                PracticeSetupSection(profile: $profile, consent: consent, resume: resume) { provider, model, lesson in
                    start(provider, model: model, lesson: lesson)
                }
            }
        }
        .navigationTitle("语言陪练")
        .aiConsentSheet(consent)
        .onChange(of: voice.running) { _, running in
            if running {
                previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
            } else { restoreIdleTimer(); saveIfNeeded() }
        }
        .onDisappear { stopOnExit() }
        .onChange(of: phase) { if phase == .background { stopOnExit() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            if let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               type == AVAudioSession.InterruptionType.began.rawValue { stopOnExit() }
        }
    }

    @ViewBuilder private var manualControls: some View {
        Button {
            Task {
                if voice.manualTurn == .recording { await voice.submitManualTurn() }
                else { await voice.beginManualTurn() }
            }
        } label: {
            Label(voice.manualTurn == .recording ? "说完了" : "我来说", systemImage: voice.manualTurn == .recording ? "checkmark.circle.fill" : "mic.fill")
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!voice.readyForSpeech || voice.isFinishing || [.preparing, .waiting].contains(voice.manualTurn))
        .accessibilityIdentifier("practice.takeTurn")
    }

    private func resume(_ chat: Conversation) {
        guard let lesson = chat.assistanceSettings.voicePractice, lesson.isResumable == true,
              let model = lesson.realtimeModelID, let provider = providers.first(where: { $0.id == lesson.providerID && LiveVoiceSession.isOpenAI($0) && LiveVoiceSession.supports($0) })
        else { failure = String(localized: "请先启用这次练习原来的 OpenAI 账号。"); return }
        let address = provider.baseURL
        let recipients = [model, LiveVoiceSession.practiceTranscriptionModel, lesson.reviewModelID].filter { !$0.isEmpty }
            .map { AppCompliance.recipient(provider: provider.name, model: $0, baseURL: address) }
        consent.perform(recipients: recipients, isCurrent: {
            !chat.isDeleted && chat.assistanceSettings.voicePractice?.isResumable == true && address == provider.baseURL && LiveVoiceSession.supports(provider)
        }) { start(provider, model: model, lesson: lesson, resuming: chat) }
    }

    private func start(_ provider: ProviderConfig, model: String, lesson: PracticeLesson, resuming chat: Conversation? = nil) {
        guard call == nil else { return }
        failure = nil
        requestReview = false
        startTask = Task {
            guard !Task.isCancelled, call == nil else { return }
            let connection: PracticeCall
            do { connection = try PracticeCall(provider: provider, model: model, lesson: lesson, resuming: chat, in: context) }
            catch { failure = error.localizedDescription; return }
            call = connection
            saved = nil
            voice.lines = []
            profile = lesson.profile
            rememberProfile(profile)
            await voice.start(provider: provider, model: model, practiceInstructions: connection.instructions,
                              practiceLanguage: lesson.profile.language, tapToTalk: lesson.profile.tapToTalk, practiceCall: connection)
            if !voice.running && !Task.isCancelled { saveIfNeeded() }
        }
    }

    private func saveIfNeeded() {
        guard !voice.running, let call else { return }
        if let error = voice.lastFailure { failure = error }
        do {
            try voice.savePracticeIfNeeded()
            if let lesson = call.chat.assistanceSettings.voicePractice { rememberProfile(lesson.profile) }
            requestReview = requestReview && voice.finishedPracticeNormally
            saved = call.chat
            self.call = nil
        } catch { failure = error.localizedDescription }
    }

    private func rememberProfile(_ profile: PracticeProfile) {
        if let data = try? JSONEncoder().encode(profile) { UserDefaults.standard.set(data, forKey: Self.profileKey) }
    }

    private func restoreIdleTimer() {
        if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        previousIdleTimer = nil
    }

    private func stopOnExit() {
        startTask?.cancel()
        guard call != nil else { return }
        requestReview = false
        if voice.running { voice.stop() }
        restoreIdleTimer()
        saveIfNeeded()
    }
}

private struct PracticeSetupSection: View {
    @Binding var profile: PracticeProfile
    let consent: AIConsentGate
    let resume: (Conversation) -> Void
    let start: (ProviderConfig, String, PracticeLesson) -> Void
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(filter: #Predicate<Conversation> { $0.assistanceSettingsData != nil }, sort: \Conversation.createdAt, order: .reverse)
    private var chats: [Conversation]
    @AppStorage("model.openAIRealtimeID") private var realtimeModel = "gpt-realtime"
    @AppStorage("model.voicePractice.textModel") private var textModel = ""
    @State private var accountID: UUID?
    @State private var due: [PracticeTarget] = []
    @State private var connecting = false
    @State private var pricingModel: ModelSpec?
    @FocusState private var typing: Bool

    private var accounts: [ProviderConfig] { providers.filter { LiveVoiceSession.isOpenAI($0) && LiveVoiceSession.supports($0) } }
    private var account: ProviderConfig? { accounts.first { $0.id == accountID } }

    var body: some View {
        setupRows
            .onAppear { refreshDue() }
            .onChange(of: profile.language) { refreshDue() }
            .onChange(of: accountID) { refreshDue() }
            .onChange(of: accounts.map(\.id), initial: true) { _, ids in
                if !ids.contains(where: { $0 == accountID }) { accountID = ids.count == 1 ? ids.first : nil }
            }
    }

    private func refreshDue() {
        due = LanguagePractice.dueTargets(in: chats, language: profile.language, providerID: accountID)
    }

    @ViewBuilder private var setupRows: some View {
        if let paused = chats.filter({ $0.assistanceSettings.voicePractice?.isResumable == true }).max(by: { $0.updatedAt < $1.updatedAt }) {
            Section {
                Button { resume(paused) } label: {
                    VStack(alignment: .leading) {
                        Label("继续上次练习", systemImage: "play.circle")
                        Text(paused.title).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("practice.resume")
            } footer: { Text("继续后会把最近已保存的对话发给原陪练账号。") }
        }
        Section {
            Picker("练习语言", selection: $profile.language) {
                ForEach(PracticeProfile.languages, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
            }
            Picker("口语水平", selection: $profile.level) {
                ForEach(EnglishProficiencyLevel.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            TextField("想练什么场景？", text: $profile.scene, axis: .vertical)
                .lineLimit(1...3).focused($typing).accessibilityIdentifier("practice.scene")
                .onChange(of: profile.scene) { _, text in if text.count > 240 { profile.scene = String(text.prefix(240)) } }
            Menu("选择常用场景") {
                ForEach(PracticeProfile.scenes, id: \.self) { scene in Button(scene) { profile.scene = scene; typing = false } }
            }
        }
        .toolbar {
            if typing {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { typing = false }
                }
            }
        }
        Section {
            Picker("纠错时机", selection: $profile.correctDuringCall) {
                Text("课后复盘").tag(false)
                Text("当场提示").tag(true)
            }
            Picker("发言方式", selection: $profile.tapToTalk) {
                Text("自动插话").tag(false)
                Text("点按轮流说").tag(true)
            }.accessibilityIdentifier("practice.turnMode")
        } footer: {
            if profile.tapToTalk { Text("点「我来说」打断陪练，再点「说完了」发送这一句。") }
        }
        if !due.isEmpty {
            Section("本次会练到") {
                ForEach(due) { Text($0.expression) }
            }
        }
        Section {
            if let provider = account {
                let model = realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let options = LanguagePractice.reviewModels(for: provider)
                let reviewID = options.first(where: { $0.id == textModel })?.id ?? options.first?.id ?? ""
                Button {
                    typing = false
                    var draft = profile
                    draft.scene = profile.trimmedScene
                    let targets = LanguagePractice.dueTargets(in: chats, language: draft.language, providerID: provider.id)
                    let lesson = PracticeLesson(profile: draft, providerID: provider.id, reviewModelID: reviewID, targets: targets)
                    let address = provider.baseURL
                    let names = [model, LiveVoiceSession.practiceTranscriptionModel, reviewID].filter { !$0.isEmpty }.map {
                        AppCompliance.recipient(provider: provider.name, model: $0, baseURL: address)
                    }
                    consent.perform(recipients: names, isCurrent: {
                        accountID == provider.id && provider.baseURL == address && LiveVoiceSession.supports(provider)
                    }) { start(provider, model, lesson) }
                } label: {
                    Label("开始语音练习", systemImage: "waveform").frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(profile.trimmedScene.isEmpty || model.isEmpty)
                .accessibilityIdentifier("practice.start")
                DisclosureGroup("陪练账号与模型") {
                    accountPicker
                    TextField("实时音频模型 ID", text: $realtimeModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LabeledContent("转写模型", value: LiveVoiceSession.practiceTranscriptionModel)
                    if !model.isEmpty {
                        Button("实时语音单价") { pricingModel = ModelSpec(id: model) }
                    }
                    Button("转写单价") { pricingModel = ModelSpec(id: LiveVoiceSession.practiceTranscriptionModel) }
                    if !options.isEmpty {
                        Picker("复盘文本模型", selection: Binding(get: { reviewID }, set: { textModel = $0 })) {
                            ForEach(options) { Text($0.displayName).tag($0.id) }
                        }
                    }
                }
                .sheet(item: $pricingModel) { ModelPricingSheet(provider: provider, modelID: $0.id, showsAudioRates: true) }
            } else if accounts.isEmpty {
                Text("连接 OpenAI 官方账号后即可开始语音练习。").foregroundStyle(.secondary)
                Button("连接模型") { connecting = true }
                    .sheet(isPresented: $connecting) {
                        QuickKeySetupSheet { provider, model in
                            if LiveVoiceSession.isOpenAI(provider) {
                                accountID = provider.id
                                textModel = model.modelID
                            }
                        }
                    }
            } else { accountPicker }
        } footer: {
            if let account {
                if LanguagePractice.reviewModels(for: account).isEmpty {
                    Text("语音发给 \(account.name)，转写会保存到本机。")
                } else {
                    Text("语音发给 \(account.name)。点「结束并复盘」时，同一账号的文本模型会收到本次练习的发言。")
                }
            }
        }
        let history = chats.filter { $0.assistanceSettings.voicePractice != nil }
        if !history.isEmpty {
            NavigationLink {
                List(history) { chat in
                    NavigationLink {
                        if chat.assistanceSettings.voicePractice?.isResumable == true { VoicePracticeView(savedLesson: chat) }
                        else { Form { PracticeReviewSection(chat: chat) }.navigationTitle("练习复盘") }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(chat.title)
                            Text(chat.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("practice.record")
                }.navigationTitle("练习记录")
            } label: { Label("练习记录", systemImage: "clock.arrow.circlepath") }
            .accessibilityIdentifier("practice.history")
        }
    }

    private var accountPicker: some View {
        Picker("实时语音账号", selection: $accountID) {
            Text("选择账号").tag(nil as UUID?)
            ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}
