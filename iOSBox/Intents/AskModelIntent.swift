import AppIntents
import UniformTypeIdentifiers

private extension AppIntent {
    @MainActor func confirmTransmission(to model: ModelEntity, includesImage: Bool) async throws {
        guard !AppCompliance.hasAcceptedAIDisclosure() else { return }
        let recipient = try ShortcutService.recipient(for: model.id)
        let dialog: IntentDialog = includesImage
            ? "将所选图片和问题发给 \(recipient)。同意此次及后续主动发起的 AI 请求？可在「夜奔」中撤回。"
            : "将问题发给 \(recipient)。同意此次及后续主动发起的 AI 请求？可在「夜奔」中撤回。"
        try await requestConfirmation(dialog: dialog)
        try Task.checkCancellation()
        guard try ShortcutService.recipient(for: model.id) == recipient else { throw AppCompliance.RequestChanged() }
        AppCompliance.setAcceptedAIDisclosure(true)
    }
}

struct AskModelIntent: AppIntent {
    static var title: LocalizedStringResource = "询问指定模型"
    static var description = IntentDescription("将问题发送给你配置的模型并返回文字结果；较长请求可转入「夜奔」继续。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    @Parameter(title: "问题", inputConnectionBehavior: .connectToPreviousIntentResult)
    var question: String
    @Parameter(title: "模型") var model: ModelEntity

    static var parameterSummary: some ParameterSummary { Summary("向 \(\.$model) 询问 \(\.$question)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try Task.checkCancellation()
        try ShortcutService.requireUnlocked()
        try await confirmTransmission(to: model, includesImage: false)
        let conversation = try ShortcutService.start(text: question, modelID: model.id)
        do {
            if let answer = try await ShortcutService.answer(for: conversation, within: .seconds(20)) {
                return .result(value: answer, dialog: "\(answer)")
            }
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                try await continueInForeground("模型仍在生成，请在「夜奔」中继续。")
            } else {
                try await requestToContinueInForeground("模型仍在生成，请在「夜奔」中继续。")
            }
            #else
            try await requestToContinueInForeground("模型仍在生成，请在「夜奔」中继续。")
            #endif
            SystemEntryRouter.shared.conversationID = conversation.id
            guard let answer = try await ShortcutService.answer(for: conversation, within: .seconds(300)) else {
                throw LLMError.apiError(String(localized: "请求耗时过长，已保留部分结果，请在对话中重答。"))
            }
            return .result(value: answer, dialog: "\(answer)")
        } catch {
            await ChatEngine.shared.stopGenerationAndWait(for: conversation.id)
            throw error
        }
    }
}

struct AnalyzeImageIntent: AppIntent {
    static var title: LocalizedStringResource = "分析图片"
    static var description = IntentDescription("接收截图或照片，发送给指定的视觉模型并返回分析结果。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    @Parameter(title: "图片", supportedContentTypes: [.image], inputConnectionBehavior: .connectToPreviousIntentResult)
    var image: IntentFile
    @Parameter(title: "问题") var question: String?
    @Parameter(title: "模型") var model: ModelEntity

    static var parameterSummary: some ParameterSummary { Summary("用 \(\.$model) 分析 \(\.$image)") { \.$question } }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try ShortcutService.requireUnlocked()
        let attachment: MessageAttachment
        if let url = image.fileURL {
            attachment = try await Task.detached { try AttachmentProcessor.processFileURL(url, imageOnly: true) }.value
        } else {
            let rawData = image.data
            let filename = image.filename
            guard let processed = await Task.detached(operation: {
                AttachmentProcessor.processImageData(rawData, suggestedName: filename)
            }).value else {
                throw AttachmentError.unreadableImage
            }
            attachment = processed
        }
        try Task.checkCancellation()
        let prompt = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await confirmTransmission(to: model, includesImage: true)
        let conversation = try ShortcutService.start(text: prompt.isEmpty ? String(localized: "请描述并分析这张图片。") : prompt,
                                                       modelID: model.id, image: attachment)
        do {
            if let answer = try await ShortcutService.answer(for: conversation, within: .seconds(20)) {
                return .result(value: answer, dialog: "\(answer)")
            }
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                try await continueInForeground("模型仍在生成，请在「夜奔」中继续。")
            } else {
                try await requestToContinueInForeground("模型仍在生成，请在「夜奔」中继续。")
            }
            #else
            try await requestToContinueInForeground("模型仍在生成，请在「夜奔」中继续。")
            #endif
            SystemEntryRouter.shared.conversationID = conversation.id
            guard let answer = try await ShortcutService.answer(for: conversation, within: .seconds(300)) else {
                throw LLMError.apiError(String(localized: "请求耗时过长，已保留部分结果，请在对话中重答。"))
            }
            return .result(value: answer, dialog: "\(answer)")
        } catch {
            await ChatEngine.shared.stopGenerationAndWait(for: conversation.id)
            throw error
        }
    }
}

// Apple recommends these backward-compatible conformances for iOS 18–25.
@available(iOS, introduced: 16.4, deprecated: 26.0)
extension AskModelIntent: ForegroundContinuableIntent {}
@available(iOS, introduced: 16.4, deprecated: 26.0)
extension AnalyzeImageIntent: ForegroundContinuableIntent {}

struct IOSBoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskModelIntent(), phrases: ["用 \(.applicationName) 提问"],
                    shortTitle: "询问模型", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: AnalyzeImageIntent(), phrases: ["用 \(.applicationName) 分析图片"],
                    shortTitle: "分析图片", systemImageName: "photo.badge.magnifyingglass")
        AppShortcut(intent: RunSkillIntent(), phrases: ["用 \(.applicationName) 运行技能", "用 \(.applicationName) 运行 \(\.$skill)"],
                    shortTitle: "运行 AI 技能", systemImageName: "wand.and.stars")
        AppShortcut(intent: QuickNewChatIntent(), phrases: ["用 \(.applicationName) 新建对话"],
                    shortTitle: "新建对话", systemImageName: "square.and.pencil")
        AppShortcut(intent: QuickVoiceNoteIntent(), phrases: ["用 \(.applicationName) 录音纪要", "用 \(.applicationName) 开始录音"],
                    shortTitle: "录音纪要", systemImageName: "waveform.and.mic")
        AppShortcut(intent: QuickScanDocumentIntent(), phrases: ["用 \(.applicationName) 扫描文档", "用 \(.applicationName) 扫文档转文字"],
                    shortTitle: "扫描文档", systemImageName: "doc.viewfinder")
        AppShortcut(intent: QuickBookmarksIntent(), phrases: ["用 \(.applicationName) 打开收藏夹"],
                    shortTitle: "收藏知识库", systemImageName: "bookmark.fill")
    }
}
