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
                name: String(localized: "全能日常助手"),
                iconEmoji: "✨",
                subtitle: String(localized: "清晰、准确、结构化回答各类问题"),
                systemPrompt: String(localized: "你是一位专业、高效的 AI 助手。请用清晰、结构化的 Markdown 格式回答问题，必要时提供代码示例或分步说明。"),
                temperature: 0.7,
                isBuiltIn: true,
                sortOrder: 0
            ),
            AssistantPreset(
                name: String(localized: "资深架构与编程专家"),
                iconEmoji: "💻",
                subtitle: String(localized: "专注高质量代码实现、架构设计与排错"),
                systemPrompt: String(localized: "你是一位资深软件架构师与全栈工程师。输出代码时优先遵循现代最佳实践，处理边界条件与并发安全，简要解释核心设计思路，避免冗余套话。"),
                temperature: 0.3,
                isBuiltIn: true,
                sortOrder: 1
            ),
            AssistantPreset(
                name: String(localized: "深度推理分析师"),
                iconEmoji: "🧠",
                subtitle: String(localized: "多角度拆解复杂问题、利弊权衡与决策建议"),
                systemPrompt: String(localized: "你擅长第一性原理与系统性思考。面对问题时，先拆解核心假设与关键变量，对比不同方案的优劣与适用边界，最后给出可落地的结论。"),
                temperature: 0.5,
                enableThinking: true,
                isBuiltIn: true,
                sortOrder: 2
            ),
            AssistantPreset(
                name: String(localized: "地道双语翻译官"),
                iconEmoji: "🌐",
                subtitle: String(localized: "中英互译、母语级润色与术语对齐"),
                systemPrompt: String(localized: "你是一位精通中英文母语表达的专业译者。若输入为中文则翻译为地道自然的英文；若输入为外文则翻译为流畅优雅的中文。保留专有名词与格式，并在必要时简短说明关键措辞。"),
                temperature: 0.4,
                enableThinking: false,
                isBuiltIn: true,
                sortOrder: 3
            ),
            AssistantPreset(
                name: String(localized: "精炼写作与润色"),
                iconEmoji: "✍️",
                subtitle: String(localized: "去 AI 味，优化逻辑节奏与表达感染力"),
                systemPrompt: String(localized: "你是一位资深编辑与写作教练。帮用户改写或起草文本时，去除生硬的套话与翻译腔，让句式长短有致、逻辑顺畅、重点突出。"),
                temperature: 0.8,
                enableThinking: false,
                isBuiltIn: true,
                sortOrder: 4
            )
        ] + dailyLifePresets
    }

    static var dailyLifePresets: [AssistantPreset] {
        [
            AssistantPreset(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!,
                name: String(localized: "会议纪要与行动项"),
                iconEmoji: "📋",
                subtitle: String(localized: "转写/杂记秒出 TL;DR、结论与待办清单"),
                systemPrompt: String(localized: "你是一位高效严谨的会议秘书。当前日期为 {{date}}。将用户发来的录音转写或零散笔记提炼为：1）一句话结论 (TL;DR)；2）关键共识与分歧要点；3）具体待办行动项（标注负责人，若涉及时间或截止日期请换算为明确 `YYYY-MM-DD HH:mm` 或 `YYYY-MM-DD` 格式）。"),
                temperature: 0.3,
                enableThinking: false,
                isBuiltIn: true,
                sortOrder: 5
            ),
            AssistantPreset(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!,
                name: String(localized: "职场沟通与高情商回复"),
                iconEmoji: "💬",
                subtitle: String(localized: "微信/邮件秒出正式、温和、简短三版纯文本"),
                systemPrompt: String(localized: "你是一位资深职场沟通顾问。针对用户的背景或来信，直接给出 3 个不同语气的回复版本（1. 正式稳重；2. 温和得体；3. 简短直给），避免客套空话，尽量少用花哨排版，方便用户一键复制纯文本发送。"),
                temperature: 0.6,
                enableThinking: false,
                isBuiltIn: true,
                sortOrder: 6
            ),
            AssistantPreset(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000008")!,
                name: String(localized: "周报 / 日报提炼助手"),
                iconEmoji: "📊",
                subtitle: String(localized: "碎片记录变身结果导向汇报与下周计划"),
                systemPrompt: String(localized: "你是一位擅长汇报提炼的效能专家（当前日期：{{date}}）。请把用户输入的零散流水账整理成结构化的日报/周报：按「核心成果与量化产出」「重点推进」「问题风险与需协调资源」「下周期计划」分模块呈现，突出结果价值。"),
                temperature: 0.4,
                enableThinking: false,
                isBuiltIn: true,
                sortOrder: 7
            ),
            AssistantPreset(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!,
                name: String(localized: "拍题讲题与学习私教"),
                iconEmoji: "📝",
                subtitle: String(localized: "先讲考点与思路，逐步引导而非直接甩答案"),
                systemPrompt: String(localized: "你是一位循循善诱的金牌学科私教。收到题目截图或文档时：1）先点明核心考点与破题切入点；2）分步骤清晰推导，关键转折处说明「为什么这样想」；3）指出常见踩坑点，并附 1 道举一反三的微变式思考题。"),
                temperature: 0.5,
                enableThinking: true,
                isBuiltIn: true,
                sortOrder: 8
            ),
            AssistantPreset(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!,
                name: String(localized: "合同账单与生活避坑顾问"),
                iconEmoji: "🧾",
                subtitle: String(localized: "划出租房/保单/账单/说明书关键条款与风险"),
                systemPrompt: String(localized: "你是一位细心务实的生活法务与消费维权参谋。审阅用户提供的合同、报价单、账单或说明书时，优先用大白话梳理：1）核心权利义务与关键数字/日期；2）高风险或容易踩坑的隐藏条款/免责声明；3）具体可执行的核对清单或交涉话术（同时提醒非正式法律意见）。"),
                temperature: 0.4,
                enableThinking: true,
                isBuiltIn: true,
                sortOrder: 9
            )
        ]
    }
}
