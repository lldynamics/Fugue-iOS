import SwiftUI
import SwiftData

/// Live scenario roleplay & silent native-recast coaching studio.
struct EnglishRoleplaySheetView: View {
    let providers: [ProviderConfig]
    let onCompleteSession: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var store = EnglishCoachStore.shared
    @State private var speechCoach = EnglishSpeechCoachService.shared
    @State private var preferences = AppPreferences.shared
    @State private var consent = AIConsentGate()

    @State private var draftInput: String = ""
    @State private var isSending = false
    @State private var isWrappingUp = false
    @State private var slowPlayback = false
    @State private var showHints = false
    @State private var errorMessage: String?

    private var theme: DS.AccentTheme { preferences.accentTheme }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let lesson = store.activeLesson {
                    missionHeader(lesson)
                    Divider().overlay(DS.Surface.hairline)
                    turnsScrollList(lesson)
                    composerBar(lesson)
                } else {
                    ContentUnavailableView("暂无进行中的今日微课", systemImage: "waveform")
                }
            }
            .background(DS.Surface.canvas.ignoresSafeArea())
            .navigationTitle("情景实战与纠偏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("暂存退出") {
                        speechCoach.stopSpeaking()
                        speechCoach.stopRecording()
                        dismiss()
                    }
                    .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        finishAndArchiveSession()
                    } label: {
                        if isWrappingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("结课记日志")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(isSending || isWrappingUp)
                }
            }
            .aiConsentSheet(consent)
            .alert(
                "操作提示",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if let greeting = store.activeLesson?.roleplayTurns.last,
                   greeting.speaker == .tutor,
                   store.activeLesson?.roleplayTurns.count == 1 {
                    speechCoach.speakEnglish(greeting.text, accent: store.profile.accent, slow: slowPlayback)
                }
            }
            .onDisappear {
                speechCoach.stopSpeaking()
                speechCoach.stopRecording()
            }
        }
    }

    private func missionHeader(_ lesson: EnglishDailyLesson) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                Text(lesson.roleplayMission)
                    .font(.caption)
                    .foregroundStyle(DS.Surface.inkSecondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    slowPlayback.toggle()
                } label: {
                    Text(slowPlayback ? "0.75x 慢速" : "1.0x 常速")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(slowPlayback ? theme.readableText : DS.Surface.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(slowPlayback ? theme.softFill : DS.Surface.subtle, in: Capsule())
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !lesson.chunks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(lesson.chunks) { chunk in
                            let used = lesson.activatedPhrases.contains { $0.caseInsensitiveCompare(chunk.phrase) == .orderedSame }
                            Button {
                                speechCoach.speakEnglish(chunk.phrase, accent: store.profile.accent, slow: slowPlayback)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: used ? "checkmark.circle.fill" : "circle.dashed")
                                        .font(.caption2)
                                    Text(chunk.phrase)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(used ? DS.AccentTheme.teal.readableText : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    used ? DS.AccentTheme.teal.softFill : DS.Surface.card,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(DS.Surface.hairline, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(DS.Surface.drawer)
    }

    private func turnsScrollList(_ lesson: EnglishDailyLesson) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(lesson.roleplayTurns) { turn in
                        if turn.speaker == .tutor {
                            tutorTurnView(turn)
                                .id(turn.id)
                        } else {
                            learnerTurnView(turn)
                                .id(turn.id)
                        }
                    }
                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("外教正在构思回应与表达批注…")
                                .font(.caption)
                                .foregroundStyle(DS.Surface.inkSecondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    Color.clear.frame(height: 6).id("ROLEPLAY_BOTTOM")
                }
                .padding(DS.Spacing.lg)
            }
            .onChange(of: lesson.roleplayTurns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("ROLEPLAY_BOTTOM", anchor: .bottom)
                }
            }
        }
    }

    private func tutorTurnView(_ turn: EnglishRoleplayTurn) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: 6) {
                FugueSealMark(character: "師", size: 18, theme: theme)
                Text("AI 外教")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DS.Surface.inkSecondary)
                Spacer()
                Button {
                    speechCoach.speakEnglish(turn.text, accent: store.profile.accent, slow: slowPlayback)
                } label: {
                    Label("朗读", systemImage: "speaker.wave.2")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.readableText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.softFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(turn.text)
                .font(.system(size: 16.5, design: .serif))
                .lineSpacing(4.5)
                .foregroundStyle(.primary)

            if let hint = turn.hintZh, !hint.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { showHints.toggle() }
                } label: {
                    Text(showHints ? hint : String(localized: "显示中文提示"))
                        .font(.caption)
                        .foregroundStyle(DS.Surface.inkSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, borderColor: DS.Surface.hairline, padding: DS.Spacing.md)
    }

    private func learnerTurnView(_ turn: EnglishRoleplayTurn) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(theme.solidFill)
                    .frame(width: 2.5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("你的表达")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.readableText)
                        if !turn.usedTargetPhrases.isEmpty {
                            DSBadge(text: "命中目标短语", icon: "sparkles", style: .accent(.teal))
                        }
                    }
                    Text(turn.text)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(.primary)
                }
            }

            if (turn.grammarCorrection?.isEmpty == false) || (turn.nativeRecast?.isEmpty == false) {
                VStack(alignment: .leading, spacing: 5) {
                    if let corr = turn.grammarCorrection, !corr.isEmpty {
                        Label(corr, systemImage: "pencil.and.outline")
                            .font(.caption)
                            .foregroundStyle(DS.AccentTheme.amber.readableText)
                    }
                    if let recast = turn.nativeRecast, !recast.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Native 地道改写")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(DS.AccentTheme.teal.readableText)
                                Text(recast)
                                    .font(.system(size: 14.5, weight: .medium, design: .serif))
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Button {
                                speechCoach.speakEnglish(recast, accent: store.profile.accent, slow: slowPlayback)
                            } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption)
                                    .foregroundStyle(DS.AccentTheme.teal.readableText)
                                    .frame(width: 36, height: 36)
                                    .background(DS.AccentTheme.teal.softFill, in: Circle())
                                    .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("朗读地道改写")
                        }
                    }
                }
                .padding(10)
                .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            }
        }
    }

    private func composerBar(_ lesson: EnglishDailyLesson) -> some View {
        VStack(spacing: 6) {
            if let err = speechCoach.speechError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(DS.StatusText.warning)
            }
            HStack(alignment: .bottom, spacing: DS.Spacing.sm) {
                Button {
                    toggleVoiceAnswer()
                } label: {
                    Image(systemName: speechCoach.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(speechCoach.isRecording ? Color.red : theme.solidFill)
                        .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityLabel(speechCoach.isRecording ? "停止英文录音" : "开口说英文")

                TextField("开口说或输入英文回答…", text: $draftInput, axis: .vertical)
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))

                Button {
                    sendLearnerTurn()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 31))
                        .foregroundStyle(canSend ? theme.solidFill : Color.secondary.opacity(0.32))
                        .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送英文回答")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .dsFloatingIsland(cornerRadius: DS.Radius.island)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.bottom, DS.Spacing.xs)
        }
    }

    private var canSend: Bool {
        !isSending && !draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggleVoiceAnswer() {
        if speechCoach.isRecording {
            speechCoach.stopRecording()
            return
        }
        speechCoach.startEnglishRecording(accent: store.profile.accent) { transcript, _, _ in
            draftInput = transcript
        }
    }

    private func sendLearnerTurn() {
        if speechCoach.isRecording {
            speechCoach.stopRecording()
        }
        let utterance = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty, let lesson = store.activeLesson else { return }
        guard let resolved = EnglishTutorLLMService.resolveTutorTarget(
            preferredID: store.profile.preferredTargetID,
            providers: providers
        ) else {
            errorMessage = EnglishTutorError.noReadyModel.localizedDescription
            return
        }

        let recipient = AppCompliance.recipient(
            provider: resolved.provider.name,
            model: resolved.target.modelDisplayName,
            baseURL: resolved.provider.baseURL
        )
        consent.perform(recipients: [recipient], search: false, tools: false) {
            draftInput = ""
            isSending = true
            Task { @MainActor in
                defer { isSending = false }
                do {
                    let reply = try await EnglishTutorLLMService.replyInRoleplay(
                        lesson: lesson,
                        profile: store.profile,
                        memory: store.memory,
                        learnerUtterance: utterance,
                        target: resolved.target,
                        provider: resolved.provider,
                        spec: resolved.spec,
                        context: modelContext
                    )
                    store.appendRoleplayExchange(
                        learnerText: utterance,
                        grammarCorrection: reply.grammarCorrection,
                        nativeRecast: reply.nativeRecast,
                        blindspotPattern: reply.blindspotPattern,
                        usedPhrases: reply.usedTargetPhrases,
                        tutorReply: reply.tutorReply,
                        tutorHintZh: reply.tutorHintZh
                    )
                    speechCoach.speakEnglish(reply.tutorReply, accent: store.profile.accent, slow: slowPlayback)
                } catch {
                    draftInput = utterance
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func finishAndArchiveSession() {
        guard let lesson = store.activeLesson else {
            dismiss()
            return
        }
        speechCoach.stopSpeaking()
        speechCoach.stopRecording()

        guard let resolved = EnglishTutorLLMService.resolveTutorTarget(
            preferredID: store.profile.preferredTargetID,
            providers: providers
        ), AppCompliance.hasAcceptedAIDisclosure() else {
            let fallbackSummary = String(
                localized: "已完成《\(lesson.title)》练习：跟读 \(lesson.completedDrillCount) 句，实战开口 \(lesson.learnerTurnCount) 轮，激活 \(lesson.activatedPhrases.count) 个目标表达。"
            )
            store.finalizeLessonToJournal(tutorSummary: fallbackSummary, updatedTutorNotes: nil)
            onCompleteSession()
            dismiss()
            return
        }

        isWrappingUp = true
        Task { @MainActor in
            defer { isWrappingUp = false }
            let result = try? await EnglishTutorLLMService.summarizeLessonForJournal(
                lesson: lesson,
                profile: store.profile,
                memory: store.memory,
                target: resolved.target,
                provider: resolved.provider,
                spec: resolved.spec,
                context: modelContext
            )
            let summary = result?.tutorSummary ?? String(
                localized: "已完成《\(lesson.title)》练习：跟读 \(lesson.completedDrillCount) 句，实战开口 \(lesson.learnerTurnCount) 轮。"
            )
            store.finalizeLessonToJournal(tutorSummary: summary, updatedTutorNotes: result?.updatedTutorNotes)
            onCompleteSession()
            dismiss()
        }
    }
}
