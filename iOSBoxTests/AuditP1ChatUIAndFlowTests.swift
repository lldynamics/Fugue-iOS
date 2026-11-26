import Foundation
import Testing
@testable import iOSBox

@Suite("Audit P1 Chat UI, Audio Consent & Sheet Handoff Regression Tests", .serialized)
@MainActor
struct AuditP1ChatUIAndFlowTests {

    private func makeProvider(
        name: String,
        baseURL: String,
        protocolType: APIProtocolType = .openAICompatible,
        isEnabled: Bool = true
    ) -> ProviderConfig {
        ProviderConfig(
            name: name,
            protocolType: protocolType,
            baseURL: baseURL,
            isEnabled: isEnabled,
            models: [ModelSpec(id: "model-1", displayName: "Model 1")],
            customHeaders: [
                CustomHeader(key: "Authorization", value: "Bearer sk-test-token", isSecret: false)
            ]
        )
    }

    @Test("Audio transcript and meeting minutes insertion preserves unsent composer draft")
    func mergingComposerDraftPreservesUnsentText() {
        #expect(
            ChatDetailView.mergingComposerDraft(existing: "", incoming: "  今天下午三点评审发布清单  ")
                == "今天下午三点评审发布清单"
        )
        #expect(
            ChatDetailView.mergingComposerDraft(existing: "   \n\t ", incoming: "整理后的语音笔记")
                == "整理后的语音笔记"
        )

        let existingDraft = "先把上周遗留的接口超时排查结论记在这里："
        let rawMerged = ChatDetailView.mergingComposerDraft(
            existing: existingDraft,
            incoming: "1. 网关连接池上限调到 256\n2. 补充重试退避日志"
        )
        #expect(
            rawMerged == """
            先把上周遗留的接口超时排查结论记在这里：

            1. 网关连接池上限调到 256
            2. 补充重试退避日志
            """
        )

        let prompt = MeetingMinutesPromptBuilder.buildPrompt(
            transcript: "下周二前完成压测回归",
            sourceLabel: "standup.m4a",
            mode: .meetingMinutes
        )
        let promptMerged = ChatDetailView.mergingComposerDraft(
            existing: "\(existingDraft)\n\n",
            incoming: prompt
        )
        #expect(promptMerged.hasPrefix("\(existingDraft)\n\n请根据以下语音转写文本"))
        #expect(!promptMerged.contains("\(existingDraft)\n\n\n"))
        #expect(promptMerged.contains("下周二前完成压测回归"))

        #expect(
            ChatDetailView.mergingComposerDraft(existing: existingDraft, incoming: "   ")
                == existingDraft
        )
    }

    @Test("Cloud TTS resolves speech-compatible provider and gates synthesis behind AI consent")
    func cloudTTSProviderResolutionAndConsentGate() throws {
        let suiteName = "audit-p1-tts-consent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AppCompliance.setAcceptedAIDisclosure(false, defaults: defaults)

        let deepSeek = makeProvider(name: "DeepSeek", baseURL: "https://api.deepseek.com")
        let groq = makeProvider(name: "Groq", baseURL: "https://api.groq.com/openai/v1")
        let openAI = makeProvider(name: "OpenAI Audio", baseURL: "https://api.openai.com/v1")
        let openRouter = makeProvider(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1")

        // Auto-selection must skip chat-only (DeepSeek/OpenRouter) and ASR-only (Groq) hosts.
        let resolvedAuto = ChatCloudTTSCoordinator.resolveCompatibleProvider(
            in: [deepSeek, groq, openAI, openRouter],
            preferredID: nil
        )
        #expect(resolvedAuto?.id == openAI.id)

        // Even an explicit stale preferredID pointing to a non-speech host must not transmit text there.
        #expect(
            ChatCloudTTSCoordinator.resolveCompatibleProvider(
                in: [deepSeek, groq, openAI],
                preferredID: deepSeek.id
            ) == nil
        )
        #expect(
            ChatCloudTTSCoordinator.resolveCompatibleProvider(
                in: [deepSeek, groq, openAI],
                preferredID: groq.id
            ) == nil
        )

        // When Cloud TTS is disabled or no speech-compatible provider exists, fall back locally without prompting consent.
        let idleGate = AIConsentGate(defaults: defaults)
        var fallbackDelivered = false
        ChatCloudTTSCoordinator.authorizeAndBuildTemplate(
            state: {
                .init(
                    useCloudTTS: true,
                    providers: [deepSeek, groq],
                    preferredProviderID: nil,
                    model: "tts-1",
                    voice: "alloy"
                )
            },
            gate: idleGate
        ) { template in
            fallbackDelivered = (template == nil)
        }
        #expect(fallbackDelivered)
        #expect(idleGate.pending == nil)

        // When Cloud TTS is enabled and consent has NOT been granted, gate synthesis behind AIDataConsentSheet.
        let gate = AIConsentGate(defaults: defaults)
        var currentModel = "tts-1-hd"
        var capturedTemplate: CloudTTSRequest?
        var invocationCount = 0

        ChatCloudTTSCoordinator.authorizeAndBuildTemplate(
            state: {
                .init(
                    useCloudTTS: true,
                    providers: [deepSeek, groq, openAI],
                    preferredProviderID: nil,
                    model: currentModel,
                    voice: "nova"
                )
            },
            gate: gate
        ) { template in
            invocationCount += 1
            capturedTemplate = template
        }

        #expect(invocationCount == 0)
        #expect(capturedTemplate == nil)
        let pending = try #require(gate.pending)
        #expect(pending.recipients.contains("OpenAI Audio"))
        #expect(pending.recipients.contains("tts-1-hd"))
        #expect(pending.recipients.contains("api.openai.com"))

        //Approving after user confirmation persists consent and yields the CloudTTSRequest template.
        gate.approve(pending.id)
        #expect(AppCompliance.hasAcceptedAIDisclosure(defaults: defaults))
        #expect(invocationCount == 1)
        let approved = try #require(capturedTemplate)
        #expect(approved.baseURL == "https://api.openai.com/v1")
        #expect(approved.model == "tts-1-hd")
        #expect(approved.voice == "nova")

        // If recipient configuration changes while the consent prompt is pending, block stale approval.
        AppCompliance.setAcceptedAIDisclosure(false, defaults: defaults)
        let changeGate = AIConsentGate(defaults: defaults)
        var staleCallbackFired = false
        ChatCloudTTSCoordinator.authorizeAndBuildTemplate(
            state: {
                .init(
                    useCloudTTS: true,
                    providers: [openAI],
                    preferredProviderID: openAI.id,
                    model: currentModel,
                    voice: "alloy"
                )
            },
            gate: changeGate
        ) { _ in
            staleCallbackFired = true
        }
        let stalePending = try #require(changeGate.pending)
        currentModel = "gpt-4o-mini-tts"
        changeGate.approve(stalePending.id)
        #expect(changeGate.requestChanged)
        #expect(!staleCallbackFired)
        #expect(!AppCompliance.hasAcceptedAIDisclosure(defaults: defaults))
    }

    @Test("Switching conversations stops active voice dictation so transcript never leaks across drafts")
    func switchingConversationStopsDictationAndProtectsNextDraft() {
        let speech = SpeechService.shared
        speech.stopDictation()
        defer { speech.stopDictation() }

        let convAID = UUID()
        let convBID = UUID()
        var activeConversationID = convAID
        var draftAText = "已有前缀"
        var draftBText = "会话 B 的独立草稿"
        var dictationBaseText = draftAText

        speech.beginSimulatedDictationForTesting { [activeConversationIDCapture = { activeConversationID }] transcript in
            guard activeConversationIDCapture() == convAID else {
                draftBText = transcript
                return
            }
            draftAText = ComposerBarView.applyingDictationTranscript(transcript, toBase: dictationBaseText)
        }

        #expect(speech.isRecording)
        #expect(speech.isDictationActive)

        speech.emitSimulatedTranscriptForTesting("第一句口述")
        #expect(draftAText == "已有前缀 第一句口述")
        #expect(draftBText == "会话 B 的独立草稿")

        // Same conversation ID is a no-op and keeps dictation running.
        let sameSwitch = ComposerBarView.handleConversationSwitch(
            from: convAID,
            to: convAID,
            speech: speech,
            dictationBaseText: &dictationBaseText
        )
        #expect(!sameSwitch)
        #expect(speech.isRecording)

        // Switching to Conversation B immediately terminates dictation and clears base text.
        activeConversationID = convBID
        let didSwitch = ComposerBarView.handleConversationSwitch(
            from: convAID,
            to: convBID,
            speech: speech,
            dictationBaseText: &dictationBaseText
        )
        #expect(didSwitch)
        #expect(!speech.isRecording)
        #expect(!speech.isDictationActive)
        #expect(dictationBaseText.isEmpty)

        // Any trailing callback after stopping dictation is ignored and cannot overwrite Conversation B's draft.
        speech.emitSimulatedTranscriptForTesting("串台尾音")
        #expect(draftAText == "已有前缀 第一句口述")
        #expect(draftBText == "会话 B 的独立草稿")
    }

    @Test("SheetHandoffState defers chained sheet presentation until active dismissal completes")
    func sheetHandoffStateDefersChainedPresentations() {
        var handoff = SheetHandoffState<ChatActiveSheet>()
        #expect(handoff.active == nil)
        #expect(handoff.deferred == nil)
        #expect(!handoff.isPresentingOrDismissing)

        // 1. Direct presentation from idle
        handoff.present(.options)
        #expect(handoff.active == .options)
        #expect(handoff.deferred == nil)
        #expect(handoff.isPresentingOrDismissing)

        // 2. ComposerOptionsSheet -> ChatSettingsSheet handoff while .options is still active
        handoff.present(.settings)
        #expect(handoff.active == nil)
        #expect(handoff.deferred == .settings)
        #expect(handoff.isPresentingOrDismissing)

        // UIKit finishes dismissing ComposerOptionsSheet and fires onDismiss:
        let promoted = handoff.handleDismiss()
        #expect(promoted == .settings)
        #expect(handoff.active == .settings)
        #expect(handoff.deferred == nil)
        #expect(handoff.isPresentingOrDismissing)

        // 3. Child sheet calls @Environment(\.dismiss) (clearing active = nil) right before requesting next sheet
        handoff.active = nil
        #expect(handoff.isPresentingOrDismissing)
        handoff.present(.knowledge)
        #expect(handoff.active == nil)
        #expect(handoff.deferred == .knowledge)

        #expect(handoff.handleDismiss() == .knowledge)
        #expect(handoff.active == .knowledge)

        // 4. Explicit dismissal for external cover/modal handoff (e.g. openBookshelf / scanDocument)
        handoff.beginDismissal()
        #expect(handoff.active == nil)
        #expect(handoff.deferred == nil)
        #expect(handoff.isPresentingOrDismissing)

        #expect(handoff.handleDismiss() == nil)
        #expect(!handoff.isPresentingOrDismissing)
    }

    @Test("Live Activity Presentation decodes legacy anonymous payloads safely and group ballot copy matches button")
    func liveActivityPresentationCodableAndBallotCopyAlignment() throws {
        let legacyAnonymousJSON = """
        {"speakerOrModel":"Hidden Model","phaseText":"生成中","completedTurns":0,"totalTurns":1,"previewSnippet":"Secret","presentation":"anonymous"}
        """
        let decodedLegacy = try JSONDecoder().decode(
            IOSBoxGenerationAttributes.ContentState.self,
            from: Data(legacyAnonymousJSON.utf8)
        )
        #expect(decodedLegacy.presentation == .status)
        #expect(decodedLegacy.visibleSpeaker != "Hidden Model")
        #expect(decodedLegacy.visibleSnippet == nil)
        #expect(decodedLegacy.visibleTitle == nil)

        var previewState = IOSBoxGenerationAttributes.ContentState(
            speakerOrModel: "Claude Sonnet",
            phaseText: "正在思考",
            completedTurns: 0,
            totalTurns: 2,
            previewSnippet: "可见摘要"
        )
        previewState.presentation = .preview
        previewState.previewTitle = "架构推演"
        #expect(previewState.visibleSpeaker == "Claude Sonnet")
        #expect(previewState.visibleTitle == "架构推演")
        #expect(previewState.visibleSnippet == "可见摘要")

        previewState.hideDetails()
        #expect(previewState.presentation == .status)
        #expect(previewState.visibleTitle == nil)
        #expect(previewState.visibleSnippet == nil)

        #expect(GroupSpeakingMode.mentionOnly.subtitle.contains("发起表决"))
        #expect(!GroupSpeakingMode.mentionOnly.subtitle.contains("全员表决"))
    }
}
