import Foundation
import PDFKit
import Speech
import SwiftData
import Testing
import UIKit
@testable import iOSBox

@Suite("Audit P0 Security, Export & Privacy Boundary Tests", .serialized)
@MainActor
struct AuditP0SecurityExportAndPrivacyTests {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
    }

    private func relativeLuminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &a) {
            return white
        }
        return 1.0
    }

    @Test("PDF export resolves dynamic colors to dark ink even under Dark Mode traits")
    func pdfRendererUsesDarkInkUnderDarkTraitCollection() throws {
        var resolvedLabelLuminance: CGFloat = 1.0
        var resolvedSecondaryLuminance: CGFloat = 1.0
        var rawDarkLabelLuminance: CGFloat = 0.0
        var pdfData = Data()

        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            rawDarkLabelLuminance = relativeLuminance(of: UIColor.label.resolvedColor(with: .current))
            resolvedLabelLuminance = relativeLuminance(of: MessageExportRenderer.pdfColor(.label))
            resolvedSecondaryLuminance = relativeLuminance(of: MessageExportRenderer.pdfColor(.secondaryLabel))
            pdfData = MessageExportRenderer.makePDFData(
                title: "暗色模式 PDF 导出可读性验证",
                speaker: "Claude Sonnet",
                markdown: """
                # 核心结论

                这是一段在系统深色模式下导出的正文内容，必须使用深色墨水绘制在白纸上。

                > 引用块文字也必须清晰可读。

                ```swift
                let darkInk = true
                ```
                """
            )
        }

        #expect(rawDarkLabelLuminance > 0.85)
        #expect(resolvedLabelLuminance < 0.15)
        #expect(resolvedSecondaryLuminance < 0.55)
        #expect(pdfData.starts(with: Data("%PDF-".utf8)))

        let doc = try #require(PDFDocument(data: pdfData))
        let page = try #require(doc.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: bounds.size.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }

        let cgImage = try #require(rendered.cgImage)
        let dataProvider = try #require(cgImage.dataProvider)
        let pixelData = try #require(dataProvider.data as Data?)
        let bytesPerPixel = max(1, cgImage.bitsPerPixel / 8)
        var darkPixelCount = 0
        for offset in stride(from: 0, to: pixelData.count - bytesPerPixel, by: bytesPerPixel * 4) {
            let c0 = CGFloat(pixelData[offset]) / 255.0
            let c1 = CGFloat(pixelData[offset + 1]) / 255.0
            let c2 = CGFloat(pixelData[offset + 2]) / 255.0
            let lum = (c0 + c1 + c2) / 3.0
            if lum < 0.35 {
                darkPixelCount += 1
            }
        }
        #expect(darkPixelCount > 50, "Rendered PDF page in Dark Mode must contain dark text glyphs, not white-on-white")
    }

    @Test("BatchArchiveExporter strips <details><summary> HTML tags for PDF while keeping them in Markdown")
    func batchArchiveExporterStripsDetailsHTMLTagsOnlyForPDF() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let conv = Conversation(title: "推演归档测试")
        let u1 = ChatMessage(role: .user, content: "请推导时间复杂度", sortIndex: 1)
        let a1 = ChatMessage(
            role: .assistant,
            content: "总时间复杂度为 O(n log n)。",
            reasoningContent: "先拆分递归树高度 log n，每层合并代价 O(n)。",
            sortIndex: 2
        )
        u1.conversation = conv
        a1.conversation = conv
        conv.messages = [u1, a1]
        context.insert(conv)
        try context.save()

        let markdownDefault = BatchArchiveExporter.makeConversationsMarkdown(conversations: [conv])
        #expect(markdownDefault.contains("<details><summary>"))
        #expect(markdownDefault.contains("</details>"))
        #expect(markdownDefault.contains("## 1. 推演归档测试"))

        let markdownForPDF = BatchArchiveExporter.makeConversationsMarkdown(conversations: [conv], forPDF: true)
        #expect(!markdownForPDF.contains("<details"))
        #expect(!markdownForPDF.contains("<summary"))
        #expect(!markdownForPDF.contains("</details>"))
        #expect(markdownForPDF.contains("## 1. 推演归档测试"))
        #expect(markdownForPDF.contains("先拆分递归树高度"))

        let pdfURL = try await BatchArchiveExporter.writeConversationsPDFFileAsync(conversations: [conv])
        defer { try? FileManager.default.removeItem(at: pdfURL.deletingLastPathComponent()) }
        let pdfBytes = try Data(contentsOf: pdfURL)
        #expect(pdfBytes.starts(with: Data("%PDF-".utf8)))
    }

    @Test("SVG sanitizer blocks whitespace-less event handlers, href schemes, SMIL <set>/<animate>, and CSS @import")
    func svgSanitizerBlocksBypassVectorsWhilePreservingLocalFragments() {
        let payload = """
        <svg/onload=alert(1) version="1.1" xmlns="http://www.w3.org/2000/svg">
          <style>@import url("https://evil.example/leak.css"); .shape { fill: url(#safeGrad); background: url(https://evil.example/bg.png); }</style>
          <defs><linearGradient id="safeGrad"><stop offset="0%"/></linearGradient></defs>
          <a id="x"href="javascript:alert(1)"><text>xss1</text></a>
          <a/xlink:href='data:text/html,<script>alert(2)</script>'><text>xss2</text></a>
          <rect width="30" height="30" "x"onload="alert(3)" fill="url(#safeGrad)"/>
          <set attributeName="onload" to="alert(4)"/>
          <animate attributeName="xlink:href" values="javascript:alert(5)"/>
          <use xlink:href="#safeGrad"/>
        </svg>
        """

        let clean = ArtifactDocumentBuilder.sanitizedSVG(payload)
        #expect(!clean.localizedCaseInsensitiveContains("onload"))
        #expect(!clean.localizedCaseInsensitiveContains("javascript:"))
        #expect(!clean.localizedCaseInsensitiveContains("data:text/html"))
        #expect(!clean.localizedCaseInsensitiveContains("<set"))
        #expect(!clean.localizedCaseInsensitiveContains("<animate"))
        #expect(!clean.localizedCaseInsensitiveContains("@import"))
        #expect(!clean.localizedCaseInsensitiveContains("evil.example"))

        #expect(clean.contains(#"version="1.1""#))
        #expect(clean.contains(#"url(#safeGrad)"#))
        #expect(clean.contains(##"xlink:href="#safeGrad""##))
    }

    @Test("SpotlightIndexService persists indexed identifiers across restarts and clears on unbookmark or App Lock")
    func spotlightIndexPersistsKeysAcrossRestartAndClearsOnUnbookmarkOrAppLock() throws {
        let suiteName = "AuditSpotlight-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prefs = AppPreferences(defaults: defaults)

        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let conv = Conversation(title: "跨重启收藏索引")
        let reply = ChatMessage(role: .assistant, content: "敏感但已收藏的精选段落", sortIndex: 1)
        var meta = reply.assistanceMetadata
        meta.isBookmarked = true
        reply.assistanceMetadata = meta
        reply.conversation = conv
        conv.messages = [reply]
        context.insert(conv)
        try context.save()

        let msgKey = SpotlightIndexService.makeIdentifier(conversationID: conv.id, messageID: reply.id)

        // Session 1: bookmark is indexed and persisted to UserDefaults
        let firstService = SpotlightIndexService(defaults: defaults, preferences: prefs)
        firstService.setEnabled(true)
        firstService.indexConversation(conv)
        #expect(firstService.persistedIdentifiers.contains(msgKey))
        #expect(firstService.recentIndexedEntries[msgKey] != nil)

        // Session 2 (simulated cold app restart): RAM cache is empty, persisted set still knows msgKey
        let restartedService = SpotlightIndexService(defaults: defaults, preferences: prefs)
        #expect(restartedService.recentIndexedEntries.isEmpty)
        #expect(restartedService.persistedIdentifiers.contains(msgKey))

        // Unbookmarking after restart must prune and delete msgKey
        var unbookmarked = reply.assistanceMetadata
        unbookmarked.isBookmarked = false
        reply.assistanceMetadata = unbookmarked
        restartedService.indexConversation(conv)
        #expect(!restartedService.persistedIdentifiers.contains(msgKey))
        #expect(restartedService.lastDeletedIdentifiers.contains(msgKey))

        // Turning on App Lock clears all persisted Spotlight identifiers and disables plaintext indexing
        var rebookmarked = reply.assistanceMetadata
        rebookmarked.isBookmarked = true
        reply.assistanceMetadata = rebookmarked
        restartedService.indexConversation(conv)
        #expect(restartedService.persistedIdentifiers.contains(msgKey))

        prefs.appLockEnabled = true
        restartedService.handleAppLockChange(lockEnabled: true)
        #expect(!restartedService.isEnabled)
        #expect(restartedService.persistedIdentifiers.isEmpty)
        #expect(restartedService.recentIndexedEntries.isEmpty)
    }

    @Test("WidgetSnapshotService and LiveActivityCoordinator redact private titles when App Lock is enabled")
    func widgetSnapshotAndLiveActivityRedactTitlesWhenAppLockEnabled() throws {
        let originalAppLock = AppPreferences.shared.appLockEnabled
        defer { AppPreferences.shared.appLockEnabled = originalAppLock }

        let conv = Conversation(title: "绝密并购条款讨论")
        let msg = ChatMessage(role: .user, content: "条款细节", sortIndex: 1)
        msg.conversation = conv
        conv.messages = [msg]

        AppPreferences.shared.appLockEnabled = false
        let unlockedSnapshot = WidgetSnapshotService.makeSnapshot(
            conversations: [conv],
            providers: [],
            bookmarkedCount: 3,
            showsRecentTitles: true
        )
        #expect(unlockedSnapshot.showRecentTitles)
        #expect(unlockedSnapshot.recentConversations.map(\.title) == ["绝密并购条款讨论"])

        AppPreferences.shared.appLockEnabled = true
        let lockedSnapshot = WidgetSnapshotService.makeSnapshot(
            conversations: [conv],
            providers: [],
            bookmarkedCount: 3,
            showsRecentTitles: true
        )
        #expect(!lockedSnapshot.showRecentTitles)
        #expect(lockedSnapshot.recentConversations.isEmpty)
        #expect(!WidgetSnapshotService.shared.showsRecentTitles)

        // Verify fast UTF-8 + 1-field JSON bookmark probe accuracy
        var bookmarkedMeta = AssistanceMetadata()
        bookmarkedMeta.isBookmarked = true
        let bookmarkedRaw = try JSONEncoder().encode(bookmarkedMeta)
        var falsePositiveCandidate = AssistanceMetadata()
        falsePositiveCandidate.isBookmarked = false
        falsePositiveCandidate.quotedExcerpt = #"{"isBookmarked":true}"#
        let unbookmarkedRaw = try JSONEncoder().encode(falsePositiveCandidate)
        #expect(WidgetSnapshotService.isBookmarkedMetadataPayload(bookmarkedRaw))
        #expect(!WidgetSnapshotService.isBookmarkedMetadataPayload(unbookmarkedRaw))

        // Verify LiveActivityCoordinator redacts title, model, and snippet when App Lock is active
        let suiteName = "AuditLive-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let isolatedPrefs = AppPreferences(defaults: defaults)
        isolatedPrefs.appLockEnabled = true

        let live = LiveActivityCoordinator(defaults: defaults, preferences: isolatedPrefs)
        live.setShowsPreviews(true)
        let activityID = UUID()
        defer { _ = live.end(conversationID: activityID, outcome: GenerationOutcome(statuses: [], stopped: true)) }
        live.start(
            conversationID: activityID,
            chatTitle: "私密病历分析",
            modeBadge: "对话",
            speakerOrModel: "Secret-Model",
            phaseText: "生成中"
        )
        live.update(conversationID: activityID, speakerOrModel: "Secret-Model", previewSnippet: "私密回复片段", force: true)
        let state = try #require(live.activeStates[activityID])
        #expect(state.visibleTitle == nil)
        #expect(state.visibleSnippet == nil)
        #expect(state.visibleSpeaker != "Secret-Model")
    }

    @Test("ShortcutService and SkillPresetEntityQuery block execution and custom prompt exposure while locked")
    func shortcutServiceBlocksBackgroundExecutionWhileAppLocked() async throws {
        let suiteName = "AuditShortcut-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AppCompliance.setAcceptedAIDisclosure(true, defaults: defaults)

        let prefs = AppPreferences(defaults: defaults)
        let lockController = AppLockController()
        prefs.appLockEnabled = true
        lockController.lockNow()
        #expect(lockController.isLocked)

        let container = try makeInMemoryContainer()
        let context = container.mainContext

        let provider = ProviderConfig(
            name: "Local Test",
            protocolType: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            isEnabled: true,
            models: [ModelSpec(id: "local-qwen", displayName: "Local Qwen")]
        )
        let customPreset = AssistantPreset(
            name: "私密财务顾问",
            iconEmoji: "💼",
            subtitle: "内部账本规则",
            systemPrompt: "CONFIDENTIAL_LEDGER_PROMPT_DO_NOT_LEAK"
        )
        context.insert(provider)
        context.insert(customPreset)
        try context.save()

        let modelID = try #require(ProviderConfig.readyTargets(in: [provider]).first?.id)
        let mockEngine = ChatEngine(stream: { _ in
            AsyncThrowingStream { cont in
                cont.yield(.contentDelta("ok"))
                cont.yield(.done)
                cont.finish()
            }
        })

        // 1. Custom AssistantPreset must not be exposed in background entity queries while locked
        let lockedSkills = try SkillPresetEntityQuery().all(
            context: context,
            preferences: prefs,
            lockController: lockController
        )
        #expect(!lockedSkills.contains { $0.name.contains("私密财务顾问") })
        #expect(!lockedSkills.contains { $0.systemPrompt.contains("CONFIDENTIAL_LEDGER_PROMPT") })

        // 2. ShortcutService.start and startSkill must throw AppLockedError while locked
        #expect(throws: ShortcutService.AppLockedError.self) {
            _ = try ShortcutService.start(
                text: "测试问题",
                modelID: modelID,
                context: context,
                engine: mockEngine,
                consentDefaults: defaults,
                preferences: prefs,
                lockController: lockController
            )
        }

        let builtInSkill = try #require(SkillPresetEntity.builtInWorkflowSkills.first)
        #expect(throws: ShortcutService.AppLockedError.self) {
            _ = try ShortcutService.startSkill(
                skill: builtInSkill,
                rawInput: "测试文本",
                modelID: modelID,
                context: context,
                engine: mockEngine,
                consentDefaults: defaults,
                preferences: prefs,
                lockController: lockController
            )
        }

        // 3. After authenticating, execution succeeds and preset entity still avoids serializing raw systemPrompt
        let unlocked = await lockController.authenticate { _ in true }
        #expect(unlocked)
        let unlockedSkills = try SkillPresetEntityQuery().all(
            context: context,
            preferences: prefs,
            lockController: lockController
        )
        let matchedPreset = try #require(unlockedSkills.first { $0.name.contains("私密财务顾问") })
        #expect(matchedPreset.systemPrompt.isEmpty)

        let conv = try ShortcutService.start(
            text: "解锁后正常提问",
            modelID: modelID,
            context: context,
            engine: mockEngine,
            consentDefaults: defaults,
            preferences: prefs,
            lockController: lockController
        )
        let answer = try await ShortcutService.answer(for: conv, within: .seconds(2), engine: mockEngine)
        #expect(answer == "ok")
    }

    @Test("AudioTranscriptionService filters incompatible OpenAI-compatible chat hosts and logs ledger records")
    func audioEndpointCompatibilityLedgerAndSpeechPrivacyChecks() throws {
        // 1. Endpoint compatibility checks
        #expect(!AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://api.deepseek.com"))
        #expect(!AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://api.deepseek.com/v1"))
        #expect(!AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://openrouter.ai/api/v1"))
        #expect(!AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"))
        #expect(!AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://api.anthropic.com/v1"))
        #expect(!AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"))
        #expect(!AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://api.groq.com/openai/v1"))

        #expect(!AudioTranscriptionService.supportsOpenAIAudioTranscriptions(baseURL: "https://api.deepseek.com/v1"))
        #expect(!AudioTranscriptionService.supportsOpenAIAudioTranscriptions(baseURL: "https://openrouter.ai/api/v1"))
        #expect(AudioTranscriptionService.supportsOpenAIAudioTranscriptions(baseURL: "https://api.groq.com/openai/v1"))
        #expect(AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "https://api.openai.com/v1"))
        #expect(AudioTranscriptionService.supportsOpenAIAudioSpeech(baseURL: "http://192.168.1.50:8000/v1"))

        // 2. Auto-resolution skips DeepSeek & OpenRouter unless explicitly selected by preferredID
        let deepseek = ProviderConfig(
            name: "DeepSeek",
            protocolType: .openAICompatible,
            baseURL: "https://api.deepseek.com/v1",
            isEnabled: true,
            models: [ModelSpec(id: "deepseek-chat")]
        )
        let openrouter = ProviderConfig(
            name: "OpenRouter",
            protocolType: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            isEnabled: true,
            models: [ModelSpec(id: "openai/gpt-4o-mini")]
        )
        let openai = ProviderConfig(
            name: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            isEnabled: true,
            models: [ModelSpec(id: "gpt-4o-mini")]
        )
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let dsCredID = deepseek.credentialID
        let orCredID = openrouter.credentialID
        let oaCredID = openai.credentialID
        _ = KeychainService.shared.saveAPIKey("sk-ds", for: dsCredID)
        _ = KeychainService.shared.saveAPIKey("sk-or", for: orCredID)
        _ = KeychainService.shared.saveAPIKey("sk-oa", for: oaCredID)
        defer {
            _ = container
            KeychainService.shared.deleteAPIKey(for: dsCredID)
            KeychainService.shared.deleteAPIKey(for: orCredID)
            KeychainService.shared.deleteAPIKey(for: oaCredID)
        }

        #expect(AudioTranscriptionService.resolveAudioProvider(
            in: [deepseek, openrouter],
            preferredID: nil,
            capability: .speech
        ) == nil)
        #expect(AudioTranscriptionService.resolveAudioProvider(
            in: [deepseek, openrouter, openai],
            preferredID: nil,
            capability: .speech
        )?.id == openai.id)
        #expect(AudioTranscriptionService.resolveAudioProvider(
            in: [deepseek, openrouter],
            preferredID: deepseek.id,
            capability: .speech
        )?.id == deepseek.id)

        // 3. RequestLedger entry recording for audio operations
        context.insert(openai)
        try context.save()

        let record = try #require(AudioTranscriptionService.recordAudioLedgerEntry(
            baseURL: "https://api.openai.com/v1",
            modelID: "tts-1-hd",
            isSpeechSynthesis: true,
            status: .succeeded,
            httpStatus: 200,
            elapsedMs: 320,
            context: context
        ))
        #expect(!record.isStreamed)
        #expect(record.status == .succeeded)
        #expect(record.providerID == openai.id)
        #expect(record.modelDisplayName.contains("TTS"))

        // 4. LocalSpeechTranscriber enforces requiresOnDeviceRecognition when supported
        let dummyURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-asr.m4a")
        let reqSupported = SFSpeechURLRecognitionRequest(url: dummyURL)
        LocalSpeechTranscriber.configureRecognitionRequest(reqSupported, supportsOnDeviceRecognition: true)
        #expect(reqSupported.requiresOnDeviceRecognition)

        let reqUnsupported = SFSpeechURLRecognitionRequest(url: dummyURL)
        LocalSpeechTranscriber.configureRecognitionRequest(reqUnsupported, supportsOnDeviceRecognition: false)
        #expect(!reqUnsupported.requiresOnDeviceRecognition)

        // 5. AIDataConsentSheet disclosure covers cloud voice/TTS, English coach, and Web Grounding
        #expect(AIDataConsentSheet.transmittedDataSummary.contains("Whisper"))
        #expect(AIDataConsentSheet.transmittedDataSummary.contains("TTS"))
        #expect(AIDataConsentSheet.transmittedDataSummary.contains("英语陪练"))
        #expect(AIDataConsentSheet.webSearchGroundingSummary.contains("Web Grounding"))
    }
}
