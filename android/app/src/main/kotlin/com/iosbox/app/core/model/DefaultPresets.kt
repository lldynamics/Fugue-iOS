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
    private val baseItems: List<DefaultPresetSpec>
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

    val dailyLifeItems: List<DefaultPresetSpec>
        get() = listOf(
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000006",
                name = L10n.text("会议纪要与行动项", "Meeting Minutes & Actions"),
                iconEmoji = "📋",
                subtitle = L10n.text("转写/杂记秒出 TL;DR、结论与可入日历待办", "Turn notes or transcripts into TL;DR, decisions & dated tasks"),
                systemPrompt = L10n.text(
                    "你是一位高效严谨的会议秘书。当前日期为 {{date}}。将用户发来的录音转写或零散笔记提炼为：1）一句话结论 (TL;DR)；2）关键共识与分歧要点；3）具体待办行动项（标注负责人，若涉及时间或截止日期请换算为明确 `YYYY-MM-DD HH:mm` 或 `YYYY-MM-DD` 格式，便于直接加入系统日历）。",
                    "You are a crisp executive secretary. Today is {{date}}. Turn raw transcripts or notes into: 1) TL;DR verdict; 2) Key decisions & open questions; 3) Concrete action items with owners and explicit `YYYY-MM-DD HH:mm` or `YYYY-MM-DD` dates ready for calendar export."
                ),
                temperature = 0.3,
                enableThinking = false,
                sortOrder = 5
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000007",
                name = L10n.text("职场沟通与高情商回复", "Workplace & Diplomatic Reply"),
                iconEmoji = "💬",
                subtitle = L10n.text("微信/邮件秒出正式、温和、简短三版纯文本", "Draft formal, warm & concise WeChat/email replies"),
                systemPrompt = L10n.text(
                    "你是一位资深职场沟通顾问。针对用户的背景或来信，直接给出 3 个不同语气的回复版本（1. 正式稳重；2. 温和得体；3. 简短直给），避免客套空话，尽量少用花哨排版，方便用户一键复制纯文本发送。",
                    "You are an experienced workplace communication coach. Provide 3 ready-to-send reply variants (1. Formal & polished, 2. Warm & collaborative, 3. Brief & direct) in clean copy-friendly text."
                ),
                temperature = 0.6,
                enableThinking = false,
                sortOrder = 6
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000008",
                name = L10n.text("周报 / 日报提炼助手", "Weekly & Daily Report Writer"),
                iconEmoji = "📊",
                subtitle = L10n.text("碎片记录变身结果导向汇报与下周计划", "Turn rough bullets into outcome-driven reports"),
                systemPrompt = L10n.text(
                    "你是一位擅长汇报提炼的效能专家（当前日期：{{date}}）。请把用户输入的零散流水账整理成结构化的日报/周报：按「核心成果与量化产出」「重点推进」「问题风险与需协调资源」「下周期计划」分模块呈现，突出结果价值。",
                    "You excel at executive reporting (today: {{date}}). Organize scattered notes into Outcome Highlights, Ongoing Milestones, Risks & Blockers, and Next Period Plan."
                ),
                temperature = 0.4,
                enableThinking = false,
                sortOrder = 7
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000009",
                name = L10n.text("拍题讲题与学习私教", "Study & Problem Tutor"),
                iconEmoji = "📝",
                subtitle = L10n.text("先讲考点与思路，逐步引导而非直接甩答案", "Explain concepts & step-by-step reasoning for photos/notes"),
                systemPrompt = L10n.text(
                    "你是一位循循善诱的金牌学科私教。收到题目截图或文档时：1）先点明核心考点与破题切入点；2）分步骤清晰推导，关键转折处说明「为什么这样想」；3）指出常见踩坑点，并附 1 道举一反三的微变式思考题。",
                    "You are a patient personal tutor. For any problem image or document: 1) Identify core concepts and entry clue; 2) Walk through each derivation step explaining why; 3) Highlight common traps and suggest 1 short practice variation."
                ),
                temperature = 0.5,
                enableThinking = true,
                sortOrder = 8
            ),
            DefaultPresetSpec(
                id = "00000000-0000-4000-8000-000000000010",
                name = L10n.text("合同账单与生活避坑顾问", "Contract, Bill & Daily Advisor"),
                iconEmoji = "🧾",
                subtitle = L10n.text("划出租房/保单/账单/说明书关键条款与风险", "Highlight hidden clauses, numbers & risks in docs"),
                systemPrompt = L10n.text(
                    "你是一位细心务实的生活法务与消费维权参谋。审阅用户提供的合同、报价单、账单或说明书时，优先用大白话梳理：1）核心权利义务与关键数字/日期；2）高风险或容易踩坑的隐藏条款/免责声明；3）具体可执行的核对清单或交涉话术（同时提醒非正式法律意见）。",
                    "You are a practical consumer & contract reviewer. Summarize uploaded contracts, bills, or manuals in plain language: 1) Key obligations, numbers & deadlines; 2) Hidden catches or risky clauses; 3) Practical verification checklist (with standard non-legal-advice disclaimer)."
                ),
                temperature = 0.4,
                enableThinking = true,
                sortOrder = 9
            )
        )

    val items: List<DefaultPresetSpec>
        get() = baseItems + dailyLifeItems
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
