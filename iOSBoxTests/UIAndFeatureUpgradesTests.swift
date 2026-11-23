import Foundation
import PDFKit
import SwiftData
import UIKit
import XCTest
@testable import iOSBox

@MainActor
final class UIAndFeatureUpgradesTests: XCTestCase {
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    func testAppPreferencesRecentsAndCustomGroupTemplates() throws {
        let suiteName = "iosbox.tests.prefs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = AppPreferences(defaults: defaults)
        XCTAssertEqual(prefs.fontScale, 1.0, accuracy: 0.001)
        XCTAssertEqual(prefs.accentTheme, .cobalt)
        XCTAssertFalse(prefs.codeDefaultLineNumbers)
        XCTAssertTrue(prefs.hapticFeedbackEnabled)
        XCTAssertTrue(prefs.autoCollapseReasoning)

        prefs.fontScale = AppPreferences.FontScaleOption.comfortable.rawValue
        prefs.accentTheme = .graphite
        prefs.codeDefaultLineNumbers = true
        prefs.autoCollapseReasoning = false

        let providerID = UUID()
        let targets = (1...10).map { idx in
            ResolvedModelTarget(
                providerID: providerID,
                providerName: "TestProvider",
                protocolType: .openAICompatible,
                modelID: "model-\(idx)",
                modelDisplayName: "Model \(idx)",
                accentHex: "#3F6EF6",
                supportsVision: true,
                supportsReasoning: false
            )
        }
        for target in targets {
            prefs.recordRecentModel(target, maxCount: 8)
        }
        // Re-recording model-5 moves it to index 0 without duplicates
        prefs.recordRecentModel(targets[4], maxCount: 8)
        XCTAssertEqual(prefs.recentModelIDs.count, 8)
        XCTAssertEqual(prefs.recentModelIDs.first, targets[4].id)
        XCTAssertEqual(prefs.recentTargets(from: targets).first?.modelID, "model-5")

        let member = GroupMember(
            name: "架构师",
            title: "技术评审",
            avatarEmoji: "🏗️",
            accentHex: "#3F6EF6",
            rolePrompt: "评估系统边界与扩展性",
            target: targets[0],
            temperature: 0.6
        )
        let customTemplate = GroupRoomTemplate.custom(
            roomTitle: "架构评审室",
            roomEmoji: "🏛️",
            sharedTopicPrompt: "聚焦高可用与数据一致性",
            speakingMode: .smartRelay,
            speechStyle: .deepDebate,
            members: [member]
        )
        XCTAssertTrue(customTemplate.isCustom)
        prefs.addCustomGroupTemplate(customTemplate)

        // Re-load from same UserDefaults suite to verify persistence
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.fontScale, 1.08, accuracy: 0.001)
        XCTAssertEqual(reloaded.accentTheme, .graphite)
        XCTAssertTrue(reloaded.codeDefaultLineNumbers)
        XCTAssertFalse(reloaded.autoCollapseReasoning)
        XCTAssertEqual(reloaded.customGroupTemplates.count, 1)
        XCTAssertEqual(reloaded.customGroupTemplates.first?.roomTitle, "架构评审室")

        reloaded.removeCustomGroupTemplate(id: customTemplate.id)
        XCTAssertTrue(reloaded.customGroupTemplates.isEmpty)
    }

    func testModelSpecBackwardCompatAndCachePricingCalculations() throws {
        let legacyJSON = Data(#"{"id":"gpt-4o","displayName":"GPT-4o","isEnabled":true,"supportsVision":true,"supportsReasoning":false}"#.utf8)
        var decoded = try JSONDecoder().decode(ModelSpec.self, from: legacyJSON)
        XCTAssertNil(decoded.cacheReadPricePerMillion)
        XCTAssertNil(decoded.cacheWritePricePerMillion)
        XCTAssertNil(decoded.isFavorite)
        XCTAssertFalse(decoded.isStarred)

        decoded.isFavorite = true
        XCTAssertTrue(decoded.isStarred)

        // Longest-prefix matching
        XCTAssertEqual(ModelPricingCatalog.match(modelID: "gpt-4.1-mini-2025-04-14")?.id, "gpt-4.1-mini")
        XCTAssertEqual(ModelPricingCatalog.match(modelID: "gpt-4.1-2025-04-14")?.id, "gpt-4.1")
        XCTAssertEqual(ModelPricingCatalog.match(modelID: "claude-sonnet-4-20250514")?.id, "claude-sonnet-4")
        XCTAssertEqual(ModelPricingCatalog.match(modelID: "deepseek-reasoner")?.currency, "CNY")

        var claudeSpec = ModelSpec(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4")
        let preset = try XCTUnwrap(ModelPricingCatalog.match(modelID: claudeSpec.id))
        ModelPricingCatalog.apply(preset, to: &claudeSpec)

        let target = ResolvedModelTarget(
            providerID: UUID(),
            providerName: "Anthropic",
            protocolType: .anthropic,
            modelID: claudeSpec.id,
            modelDisplayName: claudeSpec.displayName,
            accentHex: "#D97757",
            supportsVision: true,
            supportsReasoning: true
        )
        let record = RequestRecord(
            target: target,
            spec: claudeSpec,
            conversationID: UUID(),
            messageID: UUID(),
            kind: .answer
        )
        record.promptTokens = 100_000
        record.cachedTokens = 80_000
        record.cacheWriteTokens = 10_000
        record.completionTokens = 2_000
        record.finish(.succeeded, elapsedMs: 1200)

        // Uncached: 10k * $3 = $0.03; Cache read: 80k * $0.30 = $0.024; Cache write: 10k * $3.75 = $0.0375; Output: 2k * $15 = $0.03 -> $0.1215
        let cost = try XCTUnwrap(record.estimatedCost)
        XCTAssertEqual(cost, 0.1215, accuracy: 0.000_001)

        // Savings: 80k * ($3.0 - $0.30) / 1M = $0.216
        let savings = try XCTUnwrap(record.estimatedCacheSavings)
        XCTAssertEqual(savings, 0.216, accuracy: 0.000_001)

        // Snapshot round-trip preserves cache pricing
        let snap = record.snapshot
        let restored = RequestRecord(snapshot: snap)
        XCTAssertEqual(try XCTUnwrap(restored.estimatedCost), 0.1215, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(restored.estimatedCacheSavings), 0.216, accuracy: 0.000_001)
    }

    func testEncryptedBackupRoundTripAndWrongPasswordRejection() throws {
        let sourceContainer = try makeInMemoryContainer()
        let sourceCtx = sourceContainer.mainContext

        let secretHeader = CustomHeader(key: "X-Gateway-Secret", value: "", isSecret: true)
        let provider = ProviderConfig(
            name: "Private Gateway",
            protocolType: .openAICompatible,
            baseURL: "https://gateway.example.com/team-a/v1",
            isEnabled: true,
            models: [ModelSpec(id: "gpt-4.1", displayName: "GPT-4.1")],
            customHeaders: [secretHeader]
        )
        sourceCtx.insert(provider)
        try sourceCtx.save()

        let providerID = provider.id
        let headerAccount = KeychainService.headerAccount(providerID: providerID, headerID: secretHeader.id)
        let previousTavily = KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount)

        defer {
            KeychainService.shared.deleteAPIKey(for: providerID)
            KeychainService.shared.deleteSecret(account: headerAccount)
            if previousTavily.isEmpty {
                KeychainService.shared.deleteSecret(account: TavilySearchClient.keychainAccount)
            } else {
                _ = KeychainService.shared.saveSecret(previousTavily, account: TavilySearchClient.keychainAccount)
            }
        }

        XCTAssertTrue(KeychainService.shared.saveAPIKey("sk-enc-test-987654", for: providerID))
        XCTAssertTrue(KeychainService.shared.saveSecret("hdr-enc-secret-42", account: headerAccount))
        XCTAssertTrue(KeychainService.shared.saveSecret("tvly-enc-key-777", account: TavilySearchClient.keychainAccount))

        // Short password rejected
        XCTAssertThrowsError(try EncryptedBackupService.exportEncryptedData(context: sourceCtx, password: "123")) { error in
            guard case EncryptedBackupError.emptyPassword = error else {
                return XCTFail("Expected emptyPassword error, got \(error)")
            }
        }

        let encrypted = try EncryptedBackupService.exportEncryptedData(context: sourceCtx, password: "Correct-Horse-Battery!")
        XCTAssertTrue(EncryptedBackupService.isEncryptedBackup(encrypted))

        let wireText = String(decoding: encrypted, as: UTF8.self)
        XCTAssertFalse(wireText.contains("sk-enc-test-987654"))
        XCTAssertFalse(wireText.contains("hdr-enc-secret-42"))
        XCTAssertFalse(wireText.contains("tvly-enc-key-777"))
        XCTAssertFalse(wireText.contains("gateway.example.com"))

        // Clear Keychain secrets to simulate restoring onto a fresh device
        KeychainService.shared.deleteAPIKey(for: providerID)
        KeychainService.shared.deleteSecret(account: headerAccount)
        KeychainService.shared.deleteSecret(account: TavilySearchClient.keychainAccount)
        XCTAssertFalse(KeychainService.shared.hasAPIKey(for: providerID))

        let destContainer = try makeInMemoryContainer()
        let destCtx = destContainer.mainContext

        // Wrong password rejected cleanly
        XCTAssertThrowsError(try EncryptedBackupService.decryptAndApply(data: encrypted, password: "Wrong-Password!", to: destCtx)) { error in
            guard case EncryptedBackupError.wrongPasswordOrCorrupted = error else {
                return XCTFail("Expected wrongPasswordOrCorrupted, got \(error)")
            }
        }

        let summary = try EncryptedBackupService.decryptAndApply(data: encrypted, password: "Correct-Horse-Battery!", to: destCtx)
        XCTAssertEqual(summary.providers, 1)

        let restoredProviders = try destCtx.fetch(FetchDescriptor<ProviderConfig>())
        let restored = try XCTUnwrap(restoredProviders.first { $0.id == providerID })
        defer { restored.deleteAllSecrets() }
        XCTAssertEqual(restored.baseURL, "https://gateway.example.com/team-a/v1")
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.apiKey, "sk-enc-test-987654")
        XCTAssertEqual(restored.resolvedCustomHeaders.first { $0.id == secretHeader.id }?.value, "hdr-enc-secret-42")
        XCTAssertTrue(KeychainService.shared.loadAPIKey(for: providerID).isEmpty)
        XCTAssertTrue(KeychainService.shared.loadSecret(account: headerAccount).isEmpty)
        XCTAssertEqual(KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount), "tvly-enc-key-777")
    }

    func testScannedPDFOCRImportAndShareAskAndImageInput() throws {
        // Render text into a bitmap image first, then draw only the image into a PDF page so there is zero PDF text layer.
        let pageRect = CGRect(x: 0, y: 0, width: 480, height: 220)
        let imgFormat = UIGraphicsImageRendererFormat.default()
        imgFormat.scale = 2.0
        imgFormat.opaque = true
        let scannedBitmap = UIGraphicsImageRenderer(size: pageRect.size, format: imgFormat).image { ctx in
            UIColor.white.setFill()
            ctx.fill(pageRect)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 24),
                .foregroundColor: UIColor.black
            ]
            ("Helena found the silver compass" as NSString).draw(at: CGPoint(x: 28, y: 80), withAttributes: attrs)
        }

        let pdfData = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { ctx in
            ctx.beginPage()
            scannedBitmap.draw(in: pageRect)
        }

        let pdfDoc = try XCTUnwrap(PDFDocument(data: pdfData))
        let rawPageText = pdfDoc.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(rawPageText.isEmpty, "Bitmap PDF must not contain a selectable text layer")

        let parsedBook = try BookImporter.parse(pdfData, filename: "Scanned.pdf")
        XCTAssertEqual(parsedBook.chapters.count, 1)
        let recognizedLower = parsedBook.chapters[0].text.lowercased()
        XCTAssertTrue(recognizedLower.contains("compass") || recognizedLower.contains("helena"),
                      "Vision OCR should recognize text from scanned PDF page, got: \(parsedBook.chapters[0].text)")

        // Share Extension ReadingInput: custom ask & image-only modes
        let articleInput = ReadingInput(text: "Quarterly revenue grew 18% while cloud margins expanded.", title: "Q3 Report")
        let askPrompt = try articleInput.prompt(action: .ask, language: "English", question: "What drove margin expansion?")
        XCTAssertTrue(askPrompt.contains("What drove margin expansion?"))
        XCTAssertTrue(askPrompt.contains("Quarterly revenue grew 18%"))

        let sampleAttachment = MessageAttachment(
            kind: .image,
            fileName: "chart.jpg",
            mimeType: "image/jpeg",
            dataBase64: "AAEC",
            extractedText: nil,
            byteSize: 3
        )
        let imageOnly = ReadingInput(attachments: [sampleAttachment])
        let imageAskPrompt = try imageOnly.prompt(action: .ask, language: "中文", question: "图里的趋势是什么？")
        XCTAssertEqual(imageAskPrompt, "图里的趋势是什么？")
        let imageDefaultPrompt = try imageOnly.prompt(action: .summarize, language: "中文")
        XCTAssertFalse(imageDefaultPrompt.isEmpty)
    }

    func testNativeWebGroundingPayloadsAcrossAllProtocols() throws {
        let userMsg = LLMPromptMessage(role: .user, content: "What happened in Swift 6.2?")

        let geminiReq = LLMChatRequest(
            providerName: "Gemini",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "test",
            customHeaders: [],
            modelID: "gemini-2.5-flash",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [userMsg],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 2048,
            enableNativeSearch: true
        )
        let geminiBody = GeminiAdapter.buildRequestBody(geminiReq)
        let geminiTools = try XCTUnwrap(geminiBody["tools"] as? [[String: Any]])
        XCTAssertNotNil(geminiTools.first?["google_search"])

        let anthropicReq = LLMChatRequest(
            providerName: "Claude",
            protocolType: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "test",
            customHeaders: [],
            modelID: "claude-sonnet-4-20250514",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [userMsg],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: 4096,
            enableThinking: false,
            thinkingBudgetTokens: 2048,
            enableNativeSearch: true
        )
        let anthropicBody = AnthropicAdapter.buildRequestBody(anthropicReq)
        let anthropicTools = try XCTUnwrap(anthropicBody["tools"] as? [[String: Any]])
        XCTAssertEqual(anthropicTools.first?["type"] as? String, "web_search_20250305")
        XCTAssertEqual(anthropicTools.first?["name"] as? String, "web_search")

        let openAIReq = LLMChatRequest(
            providerName: "OpenAI",
            protocolType: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "test",
            customHeaders: [],
            modelID: "gpt-4o-search-preview",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [userMsg],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 2048,
            enableNativeSearch: true
        )
        let openAIBody = OpenAICompatibleAdapter.buildRequestBody(openAIReq)
        XCTAssertNotNil(openAIBody["web_search_options"] as? [String: Any])

        let openRouterReq = LLMChatRequest(
            providerName: "OpenRouter",
            protocolType: .openAICompatible,
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "test",
            customHeaders: [],
            modelID: "openai/gpt-4.1",
            supportsReasoning: false,
            systemPrompt: "",
            messages: [userMsg],
            temperature: 0.7,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: false,
            thinkingBudgetTokens: 2048,
            enableNativeSearch: true
        )
        let openRouterBody = OpenAICompatibleAdapter.buildRequestBody(openRouterReq)
        let plugins = try XCTUnwrap(openRouterBody["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.first?["id"] as? String, "web")
    }

    func testMermaidArtifactSupportsStateAndClassDiagrams() {
        let stateDoc = ArtifactDocumentBuilder.htmlDocument(
            language: "mermaid",
            code: "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Streaming : send"
        )
        XCTAssertTrue(stateDoc.contains("stateDiagram"))
        XCTAssertTrue(stateDoc.contains("classDiagram"))
        XCTAssertTrue(stateDoc.contains("Content-Security-Policy"))
        XCTAssertTrue(stateDoc.contains("Idle --&gt; Streaming"))
    }

    func testSpacedRepetitionFlashcardStoreAndAnkiExport() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcards-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let baseNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = FlashcardStore(fileURL: tempURL)

        let drafts = [
            StudyCardDraft(front: "什么是 Swift Actor 可重入性？", back: "await 挂起期间 Actor 可处理其他消息，恢复后状态可能已改变。", hint: "思考 await 前后的不变式"),
            StudyCardDraft(front: "Sendable 协议的作用？", back: "保证值或引用跨并发域传递时不存在数据竞争。")
        ]
        let added = try store.addDrafts(drafts, deckName: "Swift 并发精讲", now: baseNow)
        XCTAssertEqual(added, 2)
        // Re-adding identical fronts updates without duplicating
        XCTAssertEqual(try store.addDrafts(drafts, deckName: "Swift 并发精讲", now: baseNow), 0)
        XCTAssertEqual(store.cards.count, 2)
        XCTAssertEqual(store.dueCards(at: baseNow).count, 2)

        // Review progression: Good (1d) -> Good (3d) -> Easy (>= 7d, mastered!)
        let cardID = try XCTUnwrap(store.cards.first?.id)
        try store.recordReview(cardID: cardID, rating: .good, now: baseNow)
        var updated = try XCTUnwrap(store.cards.first { $0.id == cardID })
        XCTAssertEqual(updated.intervalDays, 1.0, accuracy: 0.01)
        XCTAssertFalse(updated.isDue(at: baseNow.addingTimeInterval(3600)))
        XCTAssertTrue(updated.isDue(at: baseNow.addingTimeInterval(86_400 + 1)))

        let dayOne = baseNow.addingTimeInterval(86_400)
        try store.recordReview(cardID: cardID, rating: .good, now: dayOne)
        updated = try XCTUnwrap(store.cards.first { $0.id == cardID })
        XCTAssertEqual(updated.intervalDays, 3.0, accuracy: 0.01)

        let dayFour = dayOne.addingTimeInterval(3 * 86_400)
        try store.recordReview(cardID: cardID, rating: .easy, now: dayFour)
        updated = try XCTUnwrap(store.cards.first { $0.id == cardID })
        XCTAssertTrue(updated.isMastered)
        XCTAssertEqual(store.masteredCount, 1)

        // Again resets repetitions and schedules 10 minutes out
        try store.recordReview(cardID: cardID, rating: .again, now: dayFour)
        updated = try XCTUnwrap(store.cards.first { $0.id == cardID })
        XCTAssertEqual(updated.repetitions, 0)
        XCTAssertEqual(updated.lapses, 1)

        // Reload from disk and verify Anki TSV export
        let reloaded = FlashcardStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.cards.count, 2)
        let tsv = reloaded.exportAnkiTSV(deckFilter: "Swift 并发精讲")
        XCTAssertTrue(tsv.contains("#separator:tab"))
        XCTAssertTrue(tsv.contains("什么是 Swift Actor 可重入性？"))
        XCTAssertTrue(tsv.contains("Swift_并发精讲"))
    }

    func testSocraticCoachPromptInjectionAndInlineStudyGeneration() async throws {
        // 1. Resilient JSON parser handles <think> blocks and markdown code fences
        let fencedCards = """
        <think>Let me pick the two best recall prompts.</think>
        ```json
        {"cards":[{"front":"TCP 三次握手为什么不能是两次？","back":"防止历史失效的连接请求报文突然又传送到服务端产生错误锁定。","hint":"失效连接请求"}]}
        ```
        """
        let parsedCards = try StudyGeneratorService.parseFlashcardsJSON(fencedCards)
        XCTAssertEqual(parsedCards.count, 1)
        XCTAssertEqual(parsedCards[0].hint, "失效连接请求")

        let fencedQuiz = """
        ```json
        {"title":"TCP 握手小测","questions":[{"question":"第三次握手携带的主要标志位是？","options":["SYN","ACK","FIN","RST"],"correctIndex":1,"explanation":"客户端确认服务端 SYN+ACK 时发送 ACK。"}]}
        ```
        """
        let parsedQuiz = try StudyGeneratorService.parseQuizJSON(fencedQuiz)
        XCTAssertEqual(parsedQuiz.title, "TCP 握手小测")
        XCTAssertEqual(parsedQuiz.questions.count, 1)
        XCTAssertEqual(parsedQuiz.questions[0].correctIndex, 1)

        // 2. End-to-end ChatEngine Socratic system prompt injection + inline quiz generation
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext
        let provider = ProviderConfig(
            name: "Local Tutor",
            protocolType: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            isEnabled: true,
            models: [ModelSpec(id: "tutor-model", displayName: "Tutor")]
        )
        let target = provider.makeTarget(for: provider.models[0])
        let chat = Conversation(title: "网络协议助学", primaryTarget: target)
        chat.assistanceSettings.studyCoachMode = .socratic
        ctx.insert(provider)
        ctx.insert(chat)
        try ctx.save()

        let box = LockedStringBox()
        let mockEngine = ChatEngine(stream: { req in
            box.set(req.systemPrompt)
            return AsyncThrowingStream { cont in
                if req.systemPrompt.contains("comprehension quiz") {
                    cont.yield(.contentDelta(#"{"title":"随堂测验","questions":[{"question":"2+2=?","options":["3","4"],"correctIndex":1,"explanation":"基础算术"}]}"#))
                } else {
                    cont.yield(.contentDelta("你觉得如果只有两次握手，延迟到达的旧 SYN 包会发生什么？"))
                }
                cont.yield(.usage(promptTokens: 30, completionTokens: 20))
                cont.yield(.done)
                cont.finish()
            }
        })

        XCTAssertEqual(mockEngine.sendUserMessage(text: "帮我理解 TCP 握手", attachments: [], in: chat, providers: [provider], context: ctx), .sent)
        let deadline = ContinuousClock.now + .seconds(3)
        while mockEngine.isGenerating(in: chat.id) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(box.get().contains("[Socratic Learning Coach Mode]"))

        let assistantMsg = try XCTUnwrap(chat.sortedMessages.last { $0.role == .assistant })
        try await mockEngine.generateStudyQuiz(for: assistantMsg, in: chat, providers: [provider], context: ctx)
        XCTAssertEqual(assistantMsg.assistanceMetadata.generatedQuiz?.questions.count, 1)

        let qID = try XCTUnwrap(assistantMsg.assistanceMetadata.generatedQuiz?.questions.first?.id)
        mockEngine.selectQuizOption(questionID: qID, optionIndex: 1, on: assistantMsg, context: ctx)
        XCTAssertEqual(assistantMsg.assistanceMetadata.generatedQuiz?.correctCount, 1)

        let studyRecords = try ctx.fetch(FetchDescriptor<RequestRecord>()).filter { $0.kind == .studyGeneration }
        XCTAssertEqual(studyRecords.count, 1)
    }

    func testProjectKnowledgeMultiDocRetrievalAndSearchDocumentsTool() async throws {
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext

        let doc1Text = """
        # 缓存一致性架构
        分布式租约超期设为 45 秒，写操作通过 Raft 日志复制保证线性一致。
        # 容灾演练规范
        跨可用区故障切换目标 RTO 小于 12 秒。
        """
        let doc2Text = """
        第一章 营收概览
        第四季度订阅经常性收入（ARR）同比增长 64%，净留存率达到 128%。
        """
        let vol1 = try BookLibrary.store(PreparedBook(BookImporter.parse(Data(doc1Text.utf8), filename: "架构白皮书.md")), in: ctx)
        let vol2 = try BookLibrary.store(PreparedBook(BookImporter.parse(Data(doc2Text.utf8), filename: "Q4财报.txt")), in: ctx)

        let tempPresetStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preset-kb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempPresetStoreURL) }
        let isolatedPresetKB = PresetKnowledgeStore(fileURL: tempPresetStoreURL)
        let presetID = UUID()
        try isolatedPresetKB.setVolumeIDs([vol1.id, vol2.id], for: presetID)
        XCTAssertEqual(isolatedPresetKB.volumeIDs(for: presetID), [vol1.id, vol2.id])

        let snapshots = ProjectKnowledgeSearch.snapshots(for: [vol1.id, vol2.id], in: ctx)
        XCTAssertEqual(snapshots.count, 2)

        let searchActor = ProjectKnowledgeSearch()
        let rtoEvidence = try await searchActor.retrieve(from: snapshots, query: "跨可用区 RTO 目标是多少秒", maxPassages: 3)
        XCTAssertFalse(rtoEvidence.passages.isEmpty)
        XCTAssertEqual(rtoEvidence.passages.first?.sectionTitle, "容灾演练规范")
        XCTAssertTrue(rtoEvidence.passages.first?.excerpt.contains("12 秒") == true)

        // Verify AgentToolRunner exposes search_documents & propose_schedule_item
        let toolDefs = AgentToolRunner.definitions(hasTavilyKey: false, hasKnowledgeBase: true)
        XCTAssertTrue(toolDefs.contains { $0.name == "search_documents" })
        XCTAssertTrue(toolDefs.contains { $0.name == "propose_schedule_item" })

        let searchCall = LLMToolCall(
            id: "call_kb_1",
            name: "search_documents",
            argumentsJSON: #"{"query":"净留存率 ARR"}"#
        )
        let exec = await AgentToolRunner.execute(
            searchCall,
            searchHandler: { _ in SearchEvidence(query: "", searchedAt: Date(), sources: [], credits: nil) },
            knowledgeHandler: { q in try await searchActor.retrieve(from: snapshots, query: q, maxPassages: 3) }
        )
        XCTAssertTrue(exec.record.succeeded)
        XCTAssertTrue(exec.toolOutputJSON.contains("128%"))
        XCTAssertNotNil(exec.knowledgeEvidence)
    }

    func testEventKitScheduleConfirmationCardAndExtractor() async throws {
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext

        // 1. Parse schedule items from LLM JSON
        let sampleJSON = """
        ```json
        {"items":[
          {"kind":"reminder","title":"复盘 Q4 留存漏斗数据","notes":"重点核对企业版续费率","scheduledAt":"2026-11-20 10:30","durationMinutes":30},
          {"kind":"calendar","title":"架构评审会","notes":"评审多活容灾方案","scheduledAt":"2026-11-21 15:00","durationMinutes":45}
        ]}
        ```
        """
        let parsed = ScheduleExtractorService.parseScheduleItemsJSON(sampleJSON)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].kind, .reminder)
        XCTAssertNotNil(parsed[0].scheduledAt)
        XCTAssertEqual(parsed[1].kind, .calendarEvent)
        XCTAssertEqual(parsed[1].durationMinutes, 45)

        // 2. Agent tool propose_schedule_item + human-in-the-loop EventKit confirmation
        let call = LLMToolCall(
            id: "call_sched_1",
            name: "propose_schedule_item",
            argumentsJSON: #"{"kind":"reminder","title":"提交季度预算表","notes":"周五下班前","scheduledAt":"2026-11-22 17:00"}"#
        )
        let out = await AgentToolRunner.execute(
            call,
            searchHandler: { _ in SearchEvidence(query: "", searchedAt: Date(), sources: [], credits: nil) }
        )
        let proposed = try XCTUnwrap(out.proposedSchedule)
        XCTAssertEqual(proposed.title, "提交季度预算表")

        let msg = ChatMessage(role: .assistant, content: "已为你整理待办确认卡。")
        var meta = AssistanceMetadata()
        meta.proposedSchedules = [proposed]
        msg.assistanceMetadata = meta
        ctx.insert(msg)
        try ctx.save()

        var savedItems: [ProposedScheduleItem] = []
        EventKitService.shared.customSaveHandler = { item in
            savedItems.append(item)
        }
        defer { EventKitService.shared.customSaveHandler = nil }

        try await ChatEngine.shared.confirmScheduleProposal(proposed, on: msg, context: ctx)
        XCTAssertEqual(savedItems.count, 1)
        XCTAssertEqual(savedItems.first?.title, "提交季度预算表")
        XCTAssertTrue(msg.assistanceMetadata.proposedSchedules.isEmpty)
        XCTAssertTrue(msg.assistanceMetadata.handledScheduleIDs.contains(proposed.id))
    }

    func testRunSkillIntentSpotlightIndexingAndLiveActivityCoordinator() async throws {
        let db = try makeInMemoryContainer()
        let ctx = db.mainContext
        let suiteName = "iosbox.tests.consent.\(UUID().uuidString)"
        let consentDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { consentDefaults.removePersistentDomain(forName: suiteName) }
        AppCompliance.setAcceptedAIDisclosure(true, defaults: consentDefaults)

        let provider = ProviderConfig(
            name: "Local Gateway",
            protocolType: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            isEnabled: true,
            models: [ModelSpec(id: "skill-model", displayName: "Skill Model", supportsVision: true)]
        )
        ctx.insert(provider)
        try ctx.save()

        let promptCapture = LockedStringBox()
        let mockEngine = ChatEngine(stream: { req in
            promptCapture.set(req.messages.last?.content ?? "")
            return AsyncThrowingStream { cont in
                cont.yield(.contentDelta(#"{"merchant":"Coffee Lab","amount":38.0,"currency":"CNY"}"#))
                cont.yield(.usage(promptTokens: 25, completionTokens: 15))
                cont.yield(.done)
                cont.finish()
            }
        })

        let jsonSkill = try XCTUnwrap(SkillPresetEntity.builtInWorkflowSkills.first { $0.id == "workflow:json-extract" })
        let resolvedModelID = try ShortcutService.resolveSkillModelID(preferredModelID: nil, requiresVision: false, context: ctx)
        let conv = try ShortcutService.startSkill(
            skill: jsonSkill,
            rawInput: "Coffee Lab 拿铁 38 元",
            modelID: resolvedModelID,
            context: ctx,
            engine: mockEngine,
            consentDefaults: consentDefaults
        )
        let answer = try await ShortcutService.answer(for: conv, within: .seconds(3), engine: mockEngine)
        XCTAssertEqual(answer, #"{"merchant":"Coffee Lab","amount":38.0,"currency":"CNY"}"#)
        XCTAssertTrue(promptCapture.get().contains("Coffee Lab"))

        // Spotlight indexing & deep-link identifier round-trip (opt-in enabled)
        SpotlightIndexService.shared.setEnabled(true)
        defer { SpotlightIndexService.shared.setEnabled(false) }
        let assistantReply = try XCTUnwrap(conv.sortedMessages.last { $0.role == .assistant })
        mockEngine.toggleBookmark(for: assistantReply, context: ctx)
        SpotlightIndexService.shared.indexConversation(conv)

        let convKey = SpotlightIndexService.makeIdentifier(conversationID: conv.id, messageID: nil)
        let msgKey = SpotlightIndexService.makeIdentifier(conversationID: conv.id, messageID: assistantReply.id)
        XCTAssertNotNil(SpotlightIndexService.shared.recentIndexedEntries[convKey])
        XCTAssertEqual(SpotlightIndexService.shared.recentIndexedEntries[convKey]?.contentDescription, "")
        XCTAssertNotNil(SpotlightIndexService.shared.recentIndexedEntries[msgKey])

        let parsedMsgRoute = try XCTUnwrap(SpotlightIndexService.parseIdentifier(msgKey))
        XCTAssertEqual(parsedMsgRoute.conversationID, conv.id)
        XCTAssertEqual(parsedMsgRoute.messageID, assistantReply.id)

        SpotlightIndexService.shared.removeConversation(id: conv.id)
        XCTAssertNil(SpotlightIndexService.shared.recentIndexedEntries[convKey])
        XCTAssertNil(SpotlightIndexService.shared.recentIndexedEntries[msgKey])

        // LiveActivityCoordinator state machine lifecycle
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let live = LiveActivityCoordinator(defaults: defaults)
        live.setShowsPreviews(true)
        let liveID = UUID()
        live.start(
            conversationID: liveID,
            chatTitle: "多角色架构圆桌",
            modeBadge: "圆桌群聊",
            speakerOrModel: "🧑‍💻 老王",
            phaseText: "正在发言…",
            totalTurns: 3
        )
        XCTAssertEqual(live.activeStates[liveID]?.speakerOrModel, "🧑‍💻 老王")
        live.update(
            conversationID: liveID,
            speakerOrModel: "🕵️ 沈总",
            completedTurns: 1,
            previewSnippet: "先看商业闭环",
            force: true
        )
        XCTAssertEqual(live.activeStates[liveID]?.speakerOrModel, "🕵️ 沈总")
        XCTAssertEqual(live.activeStates[liveID]?.completedTurns, 1)
        let ended = live.end(conversationID: liveID, outcome: GenerationOutcome(statuses: [.succeeded, .failed], stopped: false))
        XCTAssertEqual(ended?.completedTurns, 1)
        XCTAssertEqual(ended?.phaseText, String(localized: "部分完成"))
        XCTAssertNil(live.activeStates[liveID])
    }
}

private final class LockedStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

