import SwiftUI
import UIKit

struct VoiceConversationView: View {
    let conversationTitle: String
    let modelDisplayName: String
    let isGenerating: Bool
    let latestAssistantMessage: ChatMessage?
    let needsModelSetup: Bool
    let onOpenModelSetup: () -> Void
    let onSendPrompt: (String) -> Bool
    let onStopGeneration: () -> Void
    let cloudTTSTemplateProvider: () -> CloudTTSRequest?

    @Environment(\.dismiss) private var dismiss
    @State private var controller = VoiceConversationController()
    @State private var speech = SpeechService.shared
    @State private var pulseActive = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.15),
                        Color(red: 0.10, green: 0.13, blue: 0.24),
                        Color(red: 0.07, green: 0.10, blue: 0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    topControlsStrip
                    Spacer(minLength: 8)
                    voiceOrbStage
                    captionPanel
                    if let errorText = controller.statusError ?? speech.speechError {
                        errorBanner(errorText)
                    } else if needsModelSetup {
                        modelSetupBanner
                    }
                    Spacer(minLength: 8)
                    bottomDock
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .navigationTitle(conversationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("退出") {
                        controller.stopSession()
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            controller.onSilenceAutoCommit = {
                sendCurrentTranscript()
            }
            controller.startSession()
            if !needsModelSetup {
                controller.startListening()
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulseActive = true
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stopSession()
        }
        .onChange(of: isGenerating) { wasGenerating, nowGenerating in
            guard wasGenerating && !nowGenerating, controller.phase == .thinking else { return }
            let replyText = latestAssistantMessage?.content ?? ""
            let replyError = latestAssistantMessage?.errorMessage
            let messageID = latestAssistantMessage?.id ?? UUID()
            if let tpl = cloudTTSTemplateProvider() {
                controller.handleGenerationFinished(
                    replyText: replyText,
                    errorMessage: replyError,
                    messageID: messageID,
                    cloudSynthesizer: { [tpl] cleanedText in
                        try await CloudSpeechSynthesizer.synthesize(
                            CloudTTSRequest(
                                baseURL: tpl.baseURL,
                                apiKey: tpl.apiKey,
                                apiKeys: tpl.apiKeys,
                                customHeaders: tpl.customHeaders,
                                model: tpl.model,
                                voice: tpl.voice,
                                input: cleanedText
                            )
                        )
                    }
                )
            } else {
                controller.handleGenerationFinished(
                    replyText: replyText,
                    errorMessage: replyError,
                    messageID: messageID,
                    cloudSynthesizer: nil
                )
            }
        }
        .onChange(of: speech.speechError) { _, newError in
            if let newError, !newError.isEmpty {
                controller.statusError = newError
                if controller.phase == .listening {
                    controller.pauseSession()
                }
            }
        }
    }

    private var topControlsStrip: some View {
        HStack(spacing: 8) {
            Label(modelDisplayName, systemImage: "cpu")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.11), in: Capsule())
                .lineLimit(1)

            Spacer(minLength: 4)

            Menu {
                ForEach(VoiceSilenceTimeout.allCases) { option in
                    Button {
                        controller.silenceTimeout = option
                    } label: {
                        HStack {
                            Text(option.label)
                            if controller.silenceTimeout == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(controller.silenceTimeout.shortLabel, systemImage: "timer")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.11), in: Capsule())
            }

            Button {
                controller.autoResumeListening.toggle()
            } label: {
                Label(
                    controller.autoResumeListening ? String(localized: "自动续听") : String(localized: "单轮暂停"),
                    systemImage: controller.autoResumeListening ? "repeat" : "pause.circle"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(controller.autoResumeListening ? Color.cyan : Color.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    (controller.autoResumeListening ? Color.cyan.opacity(0.18) : Color.white.opacity(0.1)),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var voiceOrbStage: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(orbTint.opacity(controller.phase == .listening ? 0.24 : 0.16))
                    .frame(width: 204, height: 204)
                    .scaleEffect(orbOuterScale)
                    .animation(.easeOut(duration: 0.12), value: controller.voiceLevel)

                Circle()
                    .strokeBorder(orbTint.opacity(0.45), lineWidth: 2)
                    .frame(width: 174, height: 174)
                    .scaleEffect(pulseActive && controller.phase != .idle ? 1.07 : 0.96)

                Button {
                    handleOrbTap()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [orbTint.opacity(0.92), orbTint.opacity(0.65)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 146, height: 146)
                            .shadow(color: orbTint.opacity(0.42), radius: 18, y: 6)

                        if controller.phase == .thinking {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.45)
                        } else {
                            Image(systemName: orbSymbol)
                                .font(.system(size: 46, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(needsModelSetup && controller.phase == .idle)
                .accessibilityLabel(controller.phase.statusTitle)
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(controller.phase.statusTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    if controller.turnCount > 0 {
                        Text("第 \(controller.turnCount) 轮")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.cyan.opacity(0.16), in: Capsule())
                    }
                }

                Text(phaseHintText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var captionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if controller.phase == .listening {
                    Text("实时语音识别")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text(controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? String(localized: "请直接说话，我会实时转为文字…")
                         : controller.liveTranscript)
                        .font(.body)
                        .foregroundStyle(controller.liveTranscript.isEmpty ? .white.opacity(0.58) : .white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if controller.phase == .thinking {
                    Text("你的问题")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text(controller.lastUserUtterance)
                        .font(.body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !controller.latestAssistantReply.isEmpty {
                    Text("助手回复")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text(PlainTextFormatter.format(controller.latestAssistantReply))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("免手操作语音对谈")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Text("点击中央麦克风或直接开口提问，说完短暂停顿即会自动发送并在答复后为你朗读。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 170)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var modelSetupBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(.cyan)
            Text("当前对话尚未就绪可用模型，请先选择一个已配置的模型。")
                .font(.caption)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Button("去选择") {
                controller.stopSession()
                dismiss()
                onOpenModelSetup()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var bottomDock: some View {
        HStack(spacing: 12) {
            Button {
                if let tpl = cloudTTSTemplateProvider() {
                    controller.replayLastReply { [tpl] cleanedText in
                        try await CloudSpeechSynthesizer.synthesize(
                            CloudTTSRequest(
                                baseURL: tpl.baseURL,
                                apiKey: tpl.apiKey,
                                apiKeys: tpl.apiKeys,
                                customHeaders: tpl.customHeaders,
                                model: tpl.model,
                                voice: tpl.voice,
                                input: cleanedText
                            )
                        )
                    }
                } else {
                    controller.replayLastReply(cloudSynthesizer: nil)
                }
            } label: {
                Label("重播", systemImage: "speaker.wave.2")
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 24)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(controller.latestAssistantReply.isEmpty || controller.phase == .thinking)

            Button {
                handlePrimaryDockTap()
            } label: {
                Label(primaryDockTitle, systemImage: primaryDockIcon)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .tint(orbTint)
            .controlSize(.large)
            .disabled(needsModelSetup && controller.phase == .idle)

            if controller.phase == .speaking {
                Button {
                    controller.interruptAndListen()
                } label: {
                    Label("打断说话", systemImage: "mic.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 24)
                }
                .buttonStyle(.bordered)
                .tint(.cyan)
            }
        }
    }

    private var orbTint: Color {
        switch controller.phase {
        case .idle: return .blue
        case .listening: return .teal
        case .thinking: return .indigo
        case .speaking: return .purple
        }
    }

    private var orbSymbol: String {
        switch controller.phase {
        case .idle: return "mic.fill"
        case .listening:
            return controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "waveform"
                : "arrow.up.circle.fill"
        case .thinking: return "sparkles"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    private var orbOuterScale: CGFloat {
        switch controller.phase {
        case .listening:
            return 1.0 + CGFloat(controller.voiceLevel) * 0.42
        case .speaking:
            return pulseActive ? 1.14 : 0.98
        case .thinking:
            return pulseActive ? 1.08 : 0.96
        case .idle:
            return 1.0
        }
    }

    private var phaseHintText: String {
        switch controller.phase {
        case .idle:
            return String(localized: "轻点中央按钮即可继续下一轮对话")
        case .listening:
            return controller.silenceTimeout == .manual
                ? String(localized: "说完后点击中央圆球立即发送")
                : String(localized: "说完停顿（\(controller.silenceTimeout.shortLabel)）自动发送，也可点击立即发送")
        case .thinking:
            return String(localized: "正在请求模型生成回复，完成后将自动朗读")
        case .speaking:
            return String(localized: "点击圆球或「打断说话」可随时插话提问")
        }
    }

    private var primaryDockTitle: String {
        switch controller.phase {
        case .idle:
            return String(localized: "开始聆听")
        case .listening:
            return controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "暂停聆听")
                : String(localized: "立即发送")
        case .thinking:
            return String(localized: "停止思考")
        case .speaking:
            return String(localized: "停止播报")
        }
    }

    private var primaryDockIcon: String {
        switch controller.phase {
        case .idle:
            return "mic.fill"
        case .listening:
            return controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "pause.fill"
                : "paperplane.fill"
        case .thinking, .speaking:
            return "stop.fill"
        }
    }

    private func handleOrbTap() {
        switch controller.phase {
        case .idle:
            controller.startListening()
        case .listening:
            if controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                controller.pauseSession()
            } else {
                sendCurrentTranscript()
            }
        case .thinking:
            onStopGeneration()
            controller.pauseSession()
        case .speaking:
            controller.interruptAndListen()
        }
    }

    private func handlePrimaryDockTap() {
        switch controller.phase {
        case .idle:
            controller.startListening()
        case .listening:
            if controller.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                controller.pauseSession()
            } else {
                sendCurrentTranscript()
            }
        case .thinking:
            onStopGeneration()
            controller.pauseSession()
        case .speaking:
            controller.pauseSession()
        }
    }

    private func sendCurrentTranscript() {
        _ = controller.commitCurrentTranscript { text in
            onSendPrompt(text)
        }
    }
}
