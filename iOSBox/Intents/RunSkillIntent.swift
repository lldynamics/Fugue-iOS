import AppIntents
import SwiftData
import UniformTypeIdentifiers

struct SkillPresetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "AI 技能"
    static var defaultQuery = SkillPresetEntityQuery()

    var id: String
    var name: String
    var subtitle: String
    var systemPrompt: String
    var userPrefix: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)"
        )
    }

    static var builtInWorkflowSkills: [SkillPresetEntity] {
        [
            SkillPresetEntity(
                id: "workflow:json-extract",
                name: String(localized: "提取账单与结构化 JSON"),
                subtitle: String(localized: "从截图或文本提取金额、商户、日期与明细 JSON"),
                systemPrompt: "You extract structured fields accurately from receipts, bills, or messy text. Output clean JSON with keys: merchant, date, currency, amount, category, items, summary.",
                userPrefix: String(localized: "请提取以下内容或图片中的关键信息并输出标准 JSON：\n\n")
            ),
            SkillPresetEntity(
                id: "workflow:action-items",
                name: String(localized: "提炼行动项与日程清单"),
                subtitle: String(localized: "从会议记录或长文提取待办事项、负责人与截止时间"),
                systemPrompt: "You distill concrete action items, owners, deadlines, and key decisions concisely in Markdown bullet points.",
                userPrefix: String(localized: "请从以下内容中提炼核心结论、待办行动项与关键时间节点：\n\n")
            ),
            SkillPresetEntity(
                id: "workflow:summarize",
                name: String(localized: "核心要点精炼总结"),
                subtitle: String(localized: "先给一句话结论，再列核心论据与建议"),
                systemPrompt: "",
                userPrefix: String(localized: "请帮我提炼以下内容的核心要点、关键结论与行动建议：\n\n")
            ),
            SkillPresetEntity(
                id: "workflow:translate",
                name: String(localized: "地道中英互译"),
                subtitle: String(localized: "自动识别语种并输出母语级译文"),
                systemPrompt: "",
                userPrefix: String(localized: "请将以下内容翻译为地道自然的表达（中文译英文，外文译简体中文），保留格式与专有名词：\n\n")
            )
        ]
    }
}

struct SkillPresetEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SkillPresetEntity] {
        let allItems = try await all()
        return allItems.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SkillPresetEntity] {
        let allItems = try await all()
        return allItems.filter {
            ($0.name + " " + $0.subtitle).localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [SkillPresetEntity] {
        try await all()
    }

    @MainActor
    func all(
        context suppliedContext: ModelContext? = nil,
        preferences: AppPreferences = .shared,
        lockController: AppLockController = .shared
    ) throws -> [SkillPresetEntity] {
        if ShortcutService.isAppLocked(preferences: preferences, lockController: lockController) {
            return SkillPresetEntity.builtInWorkflowSkills
        }
        let context = suppliedContext ?? AppRuntime.persistence.container.mainContext
        DataSeeder.seedIfNeeded(context: context)
        let presets = try context.fetch(FetchDescriptor<AssistantPreset>(sortBy: [SortDescriptor(\.sortOrder)]))
        let presetEntities = presets.map { p in
            SkillPresetEntity(
                id: "preset:\(p.id.uuidString)",
                name: "\(p.iconEmoji) \(p.name)",
                subtitle: p.subtitle,
                systemPrompt: "",
                userPrefix: ""
            )
        }
        return SkillPresetEntity.builtInWorkflowSkills + presetEntities
    }
}

struct RunSkillIntent: AppIntent {
    static var title: LocalizedStringResource = "运行 AI 技能"
    static var description = IntentDescription("调用「夜奔」中的自定义助手或结构化技能（如提取账单 JSON、提炼待办、翻译总结），支持绑定操作按钮与快捷指令流水线。")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    #if compiler(>=6.2)
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    #endif

    @Parameter(title: "AI 技能")
    var skill: SkillPresetEntity

    @Parameter(title: "输入文本（可选）", inputConnectionBehavior: .connectToPreviousIntentResult)
    var input: String?

    @Parameter(title: "图片（可选）", supportedContentTypes: [.image])
    var image: IntentFile?

    @Parameter(title: "指定模型（留空自动选就绪模型）")
    var model: ModelEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("运行技能 \(\.$skill)") {
            \.$input
            \.$image
            \.$model
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try ShortcutService.requireUnlocked()
        var processedImage: MessageAttachment?
        if let image {
            if let url = image.fileURL {
                processedImage = try await Task.detached { try AttachmentProcessor.processFileURL(url, imageOnly: true) }.value
            } else {
                let rawData = image.data
                let filename = image.filename
                guard let att = await Task.detached(operation: {
                    AttachmentProcessor.processImageData(rawData, suggestedName: filename)
                }).value else {
                    throw AttachmentError.unreadableImage
                }
                processedImage = att
            }
        }
        try Task.checkCancellation()

        let context = AppRuntime.persistence.container.mainContext
        let chosenModelID = try ShortcutService.resolveSkillModelID(preferredModelID: model?.id, requiresVision: processedImage != nil, context: context)

        if !AppCompliance.hasAcceptedAIDisclosure() {
            let recipient = try ShortcutService.recipient(for: chosenModelID, context: context)
            let dialog: IntentDialog = processedImage != nil
                ? "将所选图片和问题发给 \(recipient)。同意此次及后续主动发起的 AI 请求？可在「夜奔」中撤回。"
                : "将问题发给 \(recipient)。同意此次及后续主动发起的 AI 请求？可在「夜奔」中撤回。"
            try await requestConfirmation(dialog: dialog)
            try Task.checkCancellation()
            guard try ShortcutService.recipient(for: chosenModelID, context: context) == recipient else {
                throw AppCompliance.RequestChanged()
            }
            AppCompliance.setAcceptedAIDisclosure(true)
        }

        let conversation = try ShortcutService.startSkill(
            skill: skill,
            rawInput: input ?? "",
            modelID: chosenModelID,
            image: processedImage,
            context: context
        )
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

@available(iOS, introduced: 16.4, deprecated: 26.0)
extension RunSkillIntent: ForegroundContinuableIntent {}
