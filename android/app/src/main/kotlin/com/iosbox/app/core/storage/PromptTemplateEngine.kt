package com.iosbox.app.core.storage

import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ResolvedModelTarget
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object PromptTemplateEngine {
    data class VariableOption(
        val token: String,
        val label: String
    )

    val availableVariables: List<VariableOption>
        get() = listOf(
            VariableOption("{{date}}", L10n.text("当前日期", "Date")),
            VariableOption("{{time}}", L10n.text("当前时间", "Time")),
            VariableOption("{{datetime}}", L10n.text("日期与时间", "Date & Time")),
            VariableOption("{{weekday}}", L10n.text("星期", "Weekday")),
            VariableOption("{{model}}", L10n.text("当前模型", "Model")),
            VariableOption("{{model_id}}", L10n.text("模型 ID", "Model ID")),
            VariableOption("{{provider}}", L10n.text("服务商", "Provider")),
            VariableOption("{{language}}", L10n.text("系统语言", "Language"))
        )

    fun render(
        template: String,
        target: ResolvedModelTarget?,
        now: Date = Date(),
        locale: Locale = Locale.getDefault()
    ): String {
        if (!template.contains("{{")) return template

        val dateStr = SimpleDateFormat("yyyy-MM-dd", locale).format(now)
        val timeStr = SimpleDateFormat("HH:mm", locale).format(now)
        val datetimeStr = SimpleDateFormat("yyyy-MM-dd HH:mm", locale).format(now)
        val weekdayStr = SimpleDateFormat("EEEE", locale).format(now)
        val languageStr = locale.getDisplayLanguage(locale).ifBlank { locale.language.ifBlank { "en" } }

        val replacements = listOf(
            "{{date}}" to dateStr,
            "{{time}}" to timeStr,
            "{{datetime}}" to datetimeStr,
            "{{weekday}}" to weekdayStr,
            "{{model}}" to (target?.modelDisplayName ?: ""),
            "{{model_id}}" to (target?.modelID ?: ""),
            "{{provider}}" to (target?.providerName ?: ""),
            "{{language}}" to languageStr
        )

        var rendered = template
        for ((token, value) in replacements) {
            rendered = rendered.replace(token, value)
        }
        return rendered
    }
}

data class SlashPromptCommand(
    val id: String,
    val command: String,
    val title: String,
    val subtitle: String,
    val templatePrefix: String
) {
    companion object {
        val builtIns: List<SlashPromptCommand>
            get() = listOf(
                SlashPromptCommand(
                    id = "clear-context",
                    command = "/clear",
                    title = L10n.text("清除上文分割线", "Clear Context Divider"),
                    subtitle = L10n.text("保留聊天记录，但后续请求不再携带之前上下文", "Keep history visible while starting fresh model context"),
                    templatePrefix = ""
                ),
                SlashPromptCommand(
                    id = "summarize",
                    command = "/summarize",
                    title = L10n.text("总结提炼", "Summarize"),
                    subtitle = L10n.text("提取核心观点、关键论据与行动建议", "Distill key takeaways, evidence, and action items"),
                    templatePrefix = L10n.text("请帮我提炼以下内容的核心要点、关键结论与行动建议：\n\n", "Please summarize the core points, key conclusions, and action items below:\n\n")
                ),
                SlashPromptCommand(
                    id = "translate",
                    command = "/translate",
                    title = L10n.text("地道翻译", "Translate"),
                    subtitle = L10n.text("中英互译并保留专业术语与排版", "Translate naturally between Chinese and English while preserving formatting"),
                    templatePrefix = L10n.text("请将以下内容翻译为地道自然的表达（中文译英文，外文译简体中文），保留格式与专有名词：\n\n", "Please translate the text below naturally (Chinese <-> English), preserving terminology and formatting:\n\n")
                ),
                SlashPromptCommand(
                    id = "polish",
                    command = "/polish",
                    title = L10n.text("写作润色", "Polish Writing"),
                    subtitle = L10n.text("去除 AI 味与翻译腔，优化逻辑与节奏", "Refine flow, clarity, and natural tone"),
                    templatePrefix = L10n.text("请帮我润色以下文字，去除生硬套话，使逻辑更清晰、表达更自然有力：\n\n", "Please polish the writing below so it reads clearly, naturally, and concisely:\n\n")
                ),
                SlashPromptCommand(
                    id = "explain-code",
                    command = "/explain",
                    title = L10n.text("代码讲解", "Explain Code"),
                    subtitle = L10n.text("逐段解析实现原理、并发安全与边界条件", "Walk through design intent, concurrency, and edge cases"),
                    templatePrefix = L10n.text("请逐层解析这段代码的核心流程、关键设计意图及潜在边界问题：\n\n", "Please explain the core flow, design intent, and edge cases in this code:\n\n")
                ),
                SlashPromptCommand(
                    id = "code-review",
                    command = "/review",
                    title = L10n.text("代码审查", "Code Review"),
                    subtitle = L10n.text("排查 Bug、性能隐患、内存泄漏与安全漏洞", "Inspect for bugs, performance issues, leaks, and security risks"),
                    templatePrefix = L10n.text("请对以下代码进行严格审查，指出潜在 Bug、并发隐患、性能瓶颈与改进建议：\n\n", "Please review the code below strictly for bugs, concurrency hazards, performance, and fixes:\n\n")
                ),
                SlashPromptCommand(
                    id = "concise",
                    command = "/tldr",
                    title = L10n.text("一句话讲清楚", "TL;DR"),
                    subtitle = L10n.text("先给结论，再用 3 条要点概括", "One-sentence conclusion plus up to 3 crisp bullets"),
                    templatePrefix = L10n.text("请用最精炼的语言回答：先给出一句话结论，再用不超过 3 条要点说明原因。\n\n", "Answer concisely: start with a one-sentence verdict followed by at most 3 bullet points.\n\n")
                ),
                SlashPromptCommand(
                    id = "socratic-coach",
                    command = "/socratic",
                    title = L10n.text("苏格拉底引导", "Socratic Tutor"),
                    subtitle = L10n.text("开启启发式追问导师，先探测盲区再给提示", "Enable Socratic coaching with guided questions before answers"),
                    templatePrefix = L10n.text("我想真正吃透下面这个概念/技能，请用苏格拉底启发式提问引导我逐步思考，先不要直接揭晓答案：\n\n", "Help me master this concept using Socratic questions without spoiling the answer yet:\n\n")
                ),
                SlashPromptCommand(
                    id = "feynman-coach",
                    command = "/feynman",
                    title = L10n.text("费曼输出演练", "Feynman Practice"),
                    subtitle = L10n.text("由你讲解概念，AI 扮演挑刺学生追问漏洞", "Explain the concept yourself while AI probes gaps"),
                    templatePrefix = L10n.text("下面我用自己的话给你讲一遍这个概念，请你扮演挑刺学生指出我没讲清或跳步的地方：\n\n", "I will explain this concept in my own words; quiz me on unclear jumps as an inquisitive student:\n\n")
                ),
                SlashPromptCommand(
                    id = "study-quiz",
                    command = "/quiz",
                    title = L10n.text("随堂理解小测", "Quick Quiz"),
                    subtitle = L10n.text("针对当前话题出 3 道递进实战题检验掌握程度", "Generate 3 progressive comprehension questions from context"),
                    templatePrefix = L10n.text("请围绕上文的核心知识点出 3 道由浅入深的理解与实战自测题（先出题等我作答，暂不公布答案）。", "Create 3 progressive practice questions on the key topics above and wait for my answers before grading.")
                ),
                SlashPromptCommand(
                    id = "meeting-minutes",
                    command = "/meeting",
                    title = L10n.text("会议纪要与待办", "Meeting Minutes"),
                    subtitle = L10n.text("提炼讨论结论与带明确日期的行动项", "Summarize decisions and dated calendar action items"),
                    templatePrefix = L10n.text(
                        "请将以下内容整理为结构化会议纪要（一句话结论、关键讨论、待办行动项与明确 `YYYY-MM-DD HH:mm` 日期）：\n\n",
                        "Please summarize this into structured meeting minutes (TL;DR, key points, owners, and explicit `YYYY-MM-DD HH:mm` action dates):\n\n"
                    )
                ),
                SlashPromptCommand(
                    id = "tactful-reply",
                    command = "/reply",
                    title = L10n.text("高情商沟通回复", "Diplomatic Reply"),
                    subtitle = L10n.text("生成 3 种得体语气可直接复制发送微信/邮件", "Provide 3 copy-ready reply variants in different tones"),
                    templatePrefix = L10n.text(
                        "请针对以下消息帮我起草高情商回复，给出「正式稳重 / 温和得体 / 简短直给」3 个版本（纯文本可直接复制）：\n\n",
                        "Draft 3 diplomatic reply options (Formal / Warm / Brief) ready to copy for this message:\n\n"
                    )
                ),
                SlashPromptCommand(
                    id = "weekly-report",
                    command = "/weekly",
                    title = L10n.text("周报 / 工作汇报", "Weekly Report"),
                    subtitle = L10n.text("从零散笔记提炼核心成果、进展与下周计划", "Turn rough notes into an outcome-driven weekly report"),
                    templatePrefix = L10n.text(
                        "请把下面零散记录整理成结构清晰、突出成果与量化亮点的周报，并列出下周重点计划：\n\n",
                        "Organize these rough notes into an outcome-driven weekly report with concrete results and next week's plan:\n\n"
                    )
                ),
                SlashPromptCommand(
                    id = "photo-tutor",
                    command = "/solve",
                    title = L10n.text("拍题分步精讲", "Step-by-Step Tutor"),
                    subtitle = L10n.text("拆解核心考点、逐步推导并附避坑提示", "Break down concept, step-by-step derivation & pitfalls"),
                    templatePrefix = L10n.text(
                        "请充当我的私教分步讲解这道题/这部分内容：先指出核心考点与思路，再逐步推导，最后点明易错点：\n\n",
                        "Act as a tutor and explain this step-by-step: start with core concepts, show each reasoning step, and highlight common mistakes:\n\n"
                    )
                ),
                SlashPromptCommand(
                    id = "contract-check",
                    command = "/contract",
                    title = L10n.text("合同账单避坑", "Contract / Bill Review"),
                    subtitle = L10n.text("大白话拆解关键数字、期限与潜在风险条款", "Flag key numbers, deadlines, and hidden catches in plain language"),
                    templatePrefix = L10n.text(
                        "请用大白话审阅以下合同/账单/说明，标出关键费用、违约/免责陷阱、重要截止时间与核对建议：\n\n",
                        "Review this contract, bill, or notice in plain language and flag key fees, tricky clauses, deadlines, and checks:\n\n"
                    )
                ),
                SlashPromptCommand(
                    id = "life-plan",
                    command = "/plan",
                    title = L10n.text("出行 / 事务规划", "Trip & Life Planner"),
                    subtitle = L10n.text("按时间线、预算与清单给出可执行方案", "Create a practical timeline, budget, and checklist"),
                    templatePrefix = L10n.text(
                        "请帮我制定一份清晰可落地的计划（含分天/分阶段时间线、预算估测、物品清单与避坑贴士）：\n\n",
                        "Build an actionable plan with timeline, budget estimate, checklist, and practical tips for:\n\n"
                    )
                )
            )

        fun matching(draft: String): List<SlashPromptCommand> {
            if (!draft.startsWith("/") || draft.contains('\n')) return emptyList()
            val token = draft.trim().lowercase()
            if (token.contains(' ')) return emptyList()
            val bare = token.removePrefix("/")
            return builtIns.filter { cmd ->
                cmd.command.startsWith(token) ||
                    cmd.title.lowercase().contains(bare) ||
                    cmd.subtitle.lowercase().contains(bare)
            }
        }
    }
}

object ModelMentionParser {
    fun activeMentionQuery(draft: String): String? {
        val atIndex = draft.lastIndexOf('@')
        if (atIndex < 0) return null
        if (atIndex > 0 && !draft[atIndex - 1].isWhitespace()) return null
        val after = draft.substring(atIndex + 1)
        if (after.any { it.isWhitespace() }) return null
        return after
    }

    fun matchingTargets(
        query: String,
        readyTargets: List<ResolvedModelTarget>
    ): List<ResolvedModelTarget> {
        val needle = query.trim().lowercase()
        val matched = if (needle.isEmpty()) {
            readyTargets
        } else {
            readyTargets.filter { target ->
                target.modelDisplayName.lowercase().contains(needle) ||
                    target.modelID.lowercase().contains(needle) ||
                    target.providerName.lowercase().contains(needle)
            }
        }
        return matched.take(6)
    }

    fun stripTrailingMention(draft: String): String {
        val atIndex = draft.lastIndexOf('@')
        if (atIndex < 0) return draft
        if (atIndex > 0 && !draft[atIndex - 1].isWhitespace()) return draft
        val after = draft.substring(atIndex + 1)
        if (after.any { it.isWhitespace() }) return draft
        return draft.substring(0, atIndex).trimEnd()
    }
}
