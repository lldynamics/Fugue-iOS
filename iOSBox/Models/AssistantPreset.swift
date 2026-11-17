import Foundation
import SwiftData

@Model
final class AssistantPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var iconEmoji: String
    var subtitle: String
    var systemPrompt: String
    var temperature: Double
    var useCustomTemperature: Bool
    var topP: Double
    var maxOutputTokens: Int
    var contextMessageLimit: Int
    var enableThinking: Bool
    var thinkingBudgetTokens: Int
    var isBuiltIn: Bool
    var sortOrder: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        iconEmoji: String = "🤖",
        subtitle: String = "",
        systemPrompt: String = "",
        temperature: Double = 0.7,
        useCustomTemperature: Bool = true,
        topP: Double = 1.0,
        maxOutputTokens: Int = 0,
        contextMessageLimit: Int = 20,
        enableThinking: Bool = true,
        thinkingBudgetTokens: Int = 4096,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.iconEmoji = iconEmoji
        self.subtitle = subtitle
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.useCustomTemperature = useCustomTemperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.contextMessageLimit = contextMessageLimit
        self.enableThinking = enableThinking
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    static var defaultPresets: [AssistantPreset] {
        [
            AssistantPreset(
                name: "全能日常助手",
                iconEmoji: "✨",
                subtitle: "清晰、准确、结构化回答各类问题",
                systemPrompt: "你是一位专业、高效的 AI 助手。请用清晰、结构化的 Markdown 格式回答问题，必要时提供代码示例或分步说明。",
                temperature: 0.7,
                isBuiltIn: true,
                sortOrder: 0
            ),
            AssistantPreset(
                name: "资深架构与编程专家",
                iconEmoji: "💻",
                subtitle: "专注高质量代码实现、架构设计与排错",
                systemPrompt: "你是一位资深软件架构师与全栈工程师。输出代码时优先遵循现代最佳实践，处理边界条件与并发安全，简要解释核心设计思路，避免冗余套话。",
                temperature: 0.3,
                isBuiltIn: true,
                sortOrder: 1
            ),
            AssistantPreset(
                name: "深度推理分析师",
                iconEmoji: "🧠",
                subtitle: "多角度拆解复杂问题、利弊权衡与决策建议",
                systemPrompt: "你擅长第一性原理与系统性思考。面对问题时，先拆解核心假设与关键变量，对比不同方案的优劣与适用边界，最后给出可落地的结论。",
                temperature: 0.5,
                enableThinking: true,
                isBuiltIn: true,
                sortOrder: 2
            ),
            AssistantPreset(
                name: "地道双语翻译官",
                iconEmoji: "🌐",
                subtitle: "中英互译、母语级润色与术语对齐",
                systemPrompt: "你是一位精通中英文母语表达的专业译者。若输入为中文则翻译为地道自然的英文；若输入为外文则翻译为流畅优雅的中文。保留专有名词与格式，并在必要时简短说明关键措辞。",
                temperature: 0.4,
                enableThinking: false,
                isBuiltIn: true,
                sortOrder: 3
            ),
            AssistantPreset(
                name: "精炼写作与润色",
                iconEmoji: "✍️",
                subtitle: "去 AI 味，优化逻辑节奏与表达感染力",
                systemPrompt: "你是一位资深编辑与写作教练。帮用户改写或起草文本时，去除生硬的套话与翻译腔，让句式长短有致、逻辑顺畅、重点突出。",
                temperature: 0.8,
                enableThinking: false,
                isBuiltIn: true,
                sortOrder: 4
            )
        ]
    }
}
