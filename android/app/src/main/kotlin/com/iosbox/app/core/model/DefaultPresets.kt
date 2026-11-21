package com.iosbox.app.core.model

import java.util.UUID

data class DefaultPresetSpec(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String,
    val iconEmoji: String,
    val subtitle: String,
    val systemPrompt: String,
    val temperature: Double = 0.7,
    val useCustomTemperature: Boolean = true,
    val topP: Double = 1.0,
    val maxOutputTokens: Int = 0,
    val contextMessageLimit: Int = 20,
    val enableThinking: Boolean = true,
    val thinkingBudgetTokens: Int = 4096,
    val isBuiltIn: Boolean = true,
    val sortOrder: Int = 0
)

object DefaultPresets {
    val items: List<DefaultPresetSpec>
        get() = listOf(
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000001",
                name = L10n.text("全能日常助手", "General Assistant"),
                iconEmoji = "✨",
                subtitle = L10n.text("清晰、准确、结构化回答各类问题", "Clear, accurate, well-structured answers for everyday questions"),
                systemPrompt = L10n.text(
                    "你是一位专业、高效的 AI 助手。请用清晰、结构化的 Markdown 格式回答问题，必要时提供代码示例或分步说明。",
                    "You are a knowledgeable and efficient AI assistant. Reply in clear, structured Markdown with code examples or step-by-step explanations when helpful."
                ),
                temperature = 0.7,
                enableThinking = true,
                sortOrder = 0
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000002",
                name = L10n.text("资深架构与编程专家", "Staff Software Architect"),
                iconEmoji = "💻",
                subtitle = L10n.text("专注高质量代码实现、架构设计与排错", "Focused on production code quality, architecture, and debugging"),
                systemPrompt = L10n.text(
                    "你是一位资深软件架构师与全栈工程师。输出代码时优先遵循现代最佳实践，处理边界条件与并发安全，简要解释核心设计思路，避免冗余套话。",
                    "You are a staff software architect and full-stack engineer. Prioritize modern best practices, edge cases, and concurrency safety, briefly explain key design choices, and avoid filler."
                ),
                temperature = 0.3,
                enableThinking = true,
                sortOrder = 1
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000003",
                name = L10n.text("深度推理分析师", "Deep Reasoning Analyst"),
                iconEmoji = "🧠",
                subtitle = L10n.text("多角度拆解复杂问题、利弊权衡与决策建议", "Multi-angle breakdown, trade-offs, and actionable conclusions"),
                systemPrompt = L10n.text(
                    "你擅长第一性原理与系统性思考。面对问题时，先拆解核心假设与关键变量，对比不同方案的优劣与适用边界，最后给出可落地的结论。",
                    "You excel at first-principles and systems thinking. Break down core assumptions and variables, compare trade-offs and boundaries across options, and conclude with actionable recommendations."
                ),
                temperature = 0.5,
                enableThinking = true,
                sortOrder = 2
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000004",
                name = L10n.text("地道双语翻译官", "Bilingual Translator"),
                iconEmoji = "🌐",
                subtitle = L10n.text("中英互译、母语级润色与术语对齐", "Natural Chinese-English translation with terminology alignment"),
                systemPrompt = L10n.text(
                    "你是一位精通中英文母语表达的专业译者。若输入为中文则翻译为地道自然的英文；若输入为外文则翻译为流畅优雅的中文。保留专有名词与格式，并在必要时简短说明关键措辞。",
                    "You are a professional bilingual translator fluent in Chinese and English. Translate Chinese into natural, idiomatic English, and other languages into fluent Simplified Chinese. Preserve proper nouns and formatting."
                ),
                temperature = 0.4,
                enableThinking = false,
                sortOrder = 3
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000005",
                name = L10n.text("精炼写作与润色", "Editorial Writing Coach"),
                iconEmoji = "✍️",
                subtitle = L10n.text("去 AI 味，优化逻辑节奏与表达感染力", "Polish clarity, cadence, and tone while removing robotic phrasing"),
                systemPrompt = L10n.text(
                    "你是一位资深编辑与写作教练。帮用户改写或起草文本时，去除生硬的套话与翻译腔，让句式长短有致、逻辑顺畅、重点突出。",
                    "You are a senior editor and writing coach. Draft and revise copy to remove stiff clichés, improve flow and sentence rhythm, and sharpen key takeaways."
                ),
                temperature = 0.8,
                enableThinking = false,
                sortOrder = 4
            )
        )
}

object ContextLimitOptions {
    val standardValues = listOf(4, 10, 20, 50, 0)

    fun valuesIncluding(current: Int): List<Int> {
        if (standardValues.contains(current)) return standardValues
        val limited = (standardValues.filter { it > 0 } + current).sorted()
        return limited + 0
    }

    fun label(value: Int): String =
        if (value == 0) L10n.text("全部历史", "Full History")
        else L10n.text("最近 $value 条", "Last $value messages")
}
