import Foundation
import SwiftData

@MainActor
enum ShortcutService {
    static func recipient(for modelID: String, context suppliedContext: ModelContext? = nil) throws -> String {
        let context = suppliedContext ?? AppRuntime.persistence.container.mainContext
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        guard let target = ProviderConfig.readyTargets(in: providers).first(where: { $0.id == modelID }),
              let provider = providers.first(where: { $0.id == target.providerID }) else { throw SystemEntryError.noModel }
        return AppCompliance.recipient(provider: provider.name, model: target.modelDisplayName, baseURL: provider.baseURL)
    }

    static func start(text: String, modelID: String, image: MessageAttachment? = nil,
                      context suppliedContext: ModelContext? = nil,
                      engine suppliedEngine: ChatEngine? = nil,
                      consentDefaults: UserDefaults = AppCompliance.consentDefaults) throws -> Conversation {
        let context = suppliedContext ?? AppRuntime.persistence.container.mainContext
        let engine = suppliedEngine ?? .shared
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        guard let target = ProviderConfig.readyTargets(in: providers).first(where: { $0.id == modelID }) else {
            throw SystemEntryError.noModel
        }
        if image != nil && !target.supportsVision {
            throw LLMError.apiError(String(localized: "所选模型未启用识图能力，请选择支持图片的模型。"))
        }
        guard text.count <= URLReader.maximumCharacters,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else {
            throw SystemEntryError.invalidInput
        }
        try AppCompliance.requireConsent(defaults: consentDefaults)
        let conversation = Conversation(primaryTarget: target)
        conversation.useCustomTemperature = false
        context.insert(conversation)
        try context.save()
        let outcome = engine.sendUserMessage(text: text, attachments: image.map { [$0] } ?? [],
                                             in: conversation, providers: providers, context: context, kind: .shortcut)
        guard outcome == .sent else {
            context.delete(conversation)
            try context.save()
            if outcome == .saveFailed { throw SystemEntryError.storage }
            if outcome == .noAvailableModel { throw SystemEntryError.noModel }
            throw SystemEntryError.invalidInput
        }
        do { try context.save() }
        catch { engine.stopGeneration(for: conversation.id); throw error }
        return conversation
    }

    static func resolveSkillModelID(
        preferredModelID: String?,
        requiresVision: Bool,
        context suppliedContext: ModelContext? = nil
    ) throws -> String {
        let context = suppliedContext ?? AppRuntime.persistence.container.mainContext
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        let ready = ProviderConfig.readyTargets(in: providers)
        if let preferredModelID,
           let matched = ready.first(where: { $0.id == preferredModelID }) {
            if requiresVision && !matched.supportsVision {
                throw LLMError.apiError(String(localized: "所选模型未启用识图能力，请选择支持图片的模型。"))
            }
            return matched.id
        }
        if requiresVision, let visionTarget = ready.first(where: \.supportsVision) {
            return visionTarget.id
        }
        guard let firstReady = ready.first else {
            throw SystemEntryError.noModel
        }
        if requiresVision && !firstReady.supportsVision {
            throw LLMError.apiError(String(localized: "所选模型未启用识图能力，请选择支持图片的模型。"))
        }
        return firstReady.id
    }

    static func startSkill(
        skill: SkillPresetEntity,
        rawInput: String,
        modelID: String,
        image: MessageAttachment? = nil,
        context suppliedContext: ModelContext? = nil,
        engine suppliedEngine: ChatEngine? = nil,
        consentDefaults: UserDefaults = AppCompliance.consentDefaults
    ) throws -> Conversation {
        let context = suppliedContext ?? AppRuntime.persistence.container.mainContext
        let engine = suppliedEngine ?? .shared
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        guard let target = ProviderConfig.readyTargets(in: providers).first(where: { $0.id == modelID }) else {
            throw SystemEntryError.noModel
        }
        if image != nil && !target.supportsVision {
            throw LLMError.apiError(String(localized: "所选模型未启用识图能力，请选择支持图片的模型。"))
        }

        let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let composedText: String
        if !skill.userPrefix.isEmpty {
            composedText = trimmedInput.isEmpty ? skill.userPrefix : (skill.userPrefix + trimmedInput)
        } else {
            composedText = trimmedInput.isEmpty && image != nil
                ? String(localized: "请按当前助手设定分析这张图片。")
                : trimmedInput
        }

        guard composedText.count <= URLReader.maximumCharacters,
              !composedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil else {
            throw SystemEntryError.invalidInput
        }

        try AppCompliance.requireConsent(defaults: consentDefaults)
        let conversation = Conversation(title: skill.name, primaryTarget: target)
        conversation.useCustomTemperature = false

        if skill.id.hasPrefix("preset:"),
           let presetUUID = UUID(uuidString: String(skill.id.dropFirst("preset:".count))) {
            let presets = try context.fetch(FetchDescriptor<AssistantPreset>())
            if let preset = presets.first(where: { $0.id == presetUUID }) {
                conversation.applyPreset(preset)
            }
        } else if !skill.systemPrompt.isEmpty {
            conversation.systemPrompt = skill.systemPrompt
        }

        context.insert(conversation)
        try context.save()
        let outcome = engine.sendUserMessage(
            text: composedText,
            attachments: image.map { [$0] } ?? [],
            in: conversation,
            providers: providers,
            context: context,
            kind: .shortcut
        )
        guard outcome == .sent else {
            context.delete(conversation)
            try context.save()
            if outcome == .saveFailed { throw SystemEntryError.storage }
            if outcome == .noAvailableModel { throw SystemEntryError.noModel }
            throw SystemEntryError.invalidInput
        }
        do { try context.save() }
        catch { engine.stopGeneration(for: conversation.id); throw error }
        return conversation
    }

    static func answer(for conversation: Conversation, within timeout: Duration,
                       engine suppliedEngine: ChatEngine? = nil) async throws -> String? {
        let engine = suppliedEngine ?? .shared
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while engine.isGenerating(in: conversation.id) {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard let message = conversation.sortedMessages.last, message.role == .assistant else { throw LLMError.emptyResponse }
        if let error = message.errorMessage { throw LLMError.apiError(error) }
        if let status = message.latestRequest?.status, status != .succeeded && status != .incomplete {
            throw LLMError.apiError(String(localized: "请求已中止，已收到的内容保存在「夜奔」对话中。"))
        }
        guard !message.content.isEmpty else { throw LLMError.emptyResponse }
        return message.content + (message.finishReasonValue.map { "\n\n" + $0.userNotice } ?? "")
    }
}
