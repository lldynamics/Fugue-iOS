import Foundation

enum PromptTemplateEngine {
    struct VariableOption: Identifiable {
        let token: String
        let label: String
        var id: String { token }
    }

    static var availableVariables: [VariableOption] {
        [
            VariableOption(token: "{{date}}", label: String(localized: "当前日期")),
            VariableOption(token: "{{time}}", label: String(localized: "当前时间")),
            VariableOption(token: "{{datetime}}", label: String(localized: "日期与时间")),
            VariableOption(token: "{{weekday}}", label: String(localized: "星期")),
            VariableOption(token: "{{model}}", label: String(localized: "当前模型")),
            VariableOption(token: "{{model_id}}", label: String(localized: "模型 ID")),
            VariableOption(token: "{{provider}}", label: String(localized: "服务商")),
            VariableOption(token: "{{language}}", label: String(localized: "系统语言"))
        ]
    }

    static func render(
        _ template: String,
        target: ResolvedModelTarget?,
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        guard template.contains("{{") else { return template }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.dateFormat = "HH:mm"

        let datetimeFormatter = DateFormatter()
        datetimeFormatter.locale = locale
        datetimeFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = locale
        weekdayFormatter.dateFormat = "EEEE"

        let languageCode = locale.localizedString(forIdentifier: locale.identifier)
            ?? locale.language.languageCode?.identifier
            ?? "en"

        var rendered = template
        let replacements: [(String, String)] = [
            ("{{date}}", dateFormatter.string(from: now)),
            ("{{time}}", timeFormatter.string(from: now)),
            ("{{datetime}}", datetimeFormatter.string(from: now)),
            ("{{weekday}}", weekdayFormatter.string(from: now)),
            ("{{model}}", target?.modelDisplayName ?? ""),
            ("{{model_id}}", target?.modelID ?? ""),
            ("{{provider}}", target?.providerName ?? ""),
            ("{{language}}", languageCode)
        ]

        for (token, value) in replacements {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }
        return rendered
    }
}

struct SlashPromptCommand: Identifiable {
    let id: String
    let command: String
    let title: String
    let subtitle: String
    let symbol: String
    let templatePrefix: String

    static var builtIns: [SlashPromptCommand] {
        [
            SlashPromptCommand(
                id: "clear-context",
                command: "/clear",
                title: String(localized: "清除上文分割线"),
                subtitle: String(localized: "保留聊天记录，但后续请求不再携带之前上下文"),
                symbol: "scissors",
                templatePrefix: ""
            ),
            SlashPromptCommand(
                id: "summarize",
                command: "/summarize",
                title: String(localized: "总结提炼"),
                subtitle: String(localized: "提取核心观点、关键论据与行动建议"),
                symbol: "text.alignleft",
                templatePrefix: String(localized: "请帮我提炼以下内容的核心要点、关键结论与行动建议：\n\n")
            ),
            SlashPromptCommand(
                id: "translate",
                command: "/translate",
                title: String(localized: "地道翻译"),
                subtitle: String(localized: "中英互译并保留专业术语与排版"),
                symbol: "globe",
                templatePrefix: String(localized: "请将以下内容翻译为地道自然的表达（中文译英文，外文译简体中文），保留格式与专有名词：\n\n")
            ),
            SlashPromptCommand(
                id: "polish",
                command: "/polish",
                title: String(localized: "写作润色"),
                subtitle: String(localized: "去除 AI 味与翻译腔，优化逻辑与节奏"),
                symbol: "wand.and.stars",
                templatePrefix: String(localized: "请帮我润色以下文字，去除生硬套话，使逻辑更清晰、表达更自然有力：\n\n")
            ),
            SlashPromptCommand(
                id: "explain-code",
                command: "/explain",
                title: String(localized: "代码讲解"),
                subtitle: String(localized: "逐段解析实现原理、并发安全与边界条件"),
                symbol: "chevron.left.forwardslash.chevron.right",
                templatePrefix: String(localized: "请逐层解析这段代码的核心流程、关键设计意图及潜在边界问题：\n\n")
            ),
            SlashPromptCommand(
                id: "code-review",
                command: "/review",
                title: String(localized: "代码审查"),
                subtitle: String(localized: "排查 Bug、性能隐患、内存泄漏与安全漏洞"),
                symbol: "checkmark.shield",
                templatePrefix: String(localized: "请对以下代码进行严格审查，指出潜在 Bug、并发隐患、性能瓶颈与改进建议：\n\n")
            ),
            SlashPromptCommand(
                id: "concise",
                command: "/tldr",
                title: String(localized: "一句话讲清楚"),
                subtitle: String(localized: "先给结论，再用 3 条要点概括"),
                symbol: "bolt",
                templatePrefix: String(localized: "请用最精炼的语言回答：先给出一句话结论，再用不超过 3 条要点说明原因。\n\n")
            ),
            SlashPromptCommand(
                id: "socratic-coach",
                command: "/socratic",
                title: String(localized: "苏格拉底引导"),
                subtitle: String(localized: "开启启发式追问导师，先探测盲区再给提示"),
                symbol: "lightbulb.max",
                templatePrefix: String(localized: "我想真正吃透下面这个概念/技能，请用苏格拉底启发式提问引导我逐步思考，先不要直接揭晓答案：\n\n")
            ),
            SlashPromptCommand(
                id: "feynman-coach",
                command: "/feynman",
                title: String(localized: "费曼输出演练"),
                subtitle: String(localized: "由你讲解概念，AI 扮演挑刺学生追问漏洞"),
                symbol: "person.wave.2",
                templatePrefix: String(localized: "下面我用自己的话给你讲一遍这个概念，请你扮演挑刺学生指出我没讲清或跳步的地方：\n\n")
            ),
            SlashPromptCommand(
                id: "study-quiz",
                command: "/quiz",
                title: String(localized: "随堂理解小测"),
                subtitle: String(localized: "针对当前话题出 3 道递进实战题检验掌握程度"),
                symbol: "checklist",
                templatePrefix: String(localized: "请围绕上文的核心知识点出 3 道由浅入深的理解与实战自测题（先出题等我作答，暂不公布答案）。")
            ),
            SlashPromptCommand(
                id: "meeting-minutes",
                command: "/meeting",
                title: String(localized: "会议纪要与待办"),
                subtitle: String(localized: "提炼讨论结论与带明确日期的行动项"),
                symbol: "list.clipboard",
                templatePrefix: String(localized: "请将以下内容整理为结构化会议纪要（一句话结论、关键讨论、待办行动项与明确 `YYYY-MM-DD HH:mm` 日期）：\n\n")
            ),
            SlashPromptCommand(
                id: "tactful-reply",
                command: "/reply",
                title: String(localized: "高情商沟通回复"),
                subtitle: String(localized: "生成 3 种得体语气可直接复制发送微信/邮件"),
                symbol: "bubble.left.and.bubble.right",
                templatePrefix: String(localized: "请针对以下消息帮我起草高情商回复，给出「正式稳重 / 温和得体 / 简短直给」3 个版本（纯文本可直接复制）：\n\n")
            ),
            SlashPromptCommand(
                id: "weekly-report",
                command: "/weekly",
                title: String(localized: "周报 / 工作汇报"),
                subtitle: String(localized: "从零散笔记提炼核心成果、进展与下周计划"),
                symbol: "chart.bar.doc.horizontal",
                templatePrefix: String(localized: "请把下面零散记录整理成结构清晰、突出成果与量化亮点的周报，并列出下周重点计划：\n\n")
            ),
            SlashPromptCommand(
                id: "photo-tutor",
                command: "/solve",
                title: String(localized: "拍题分步精讲"),
                subtitle: String(localized: "拆解核心考点、逐步推导并附避坑提示"),
                symbol: "graduationcap",
                templatePrefix: String(localized: "请充当我的私教分步讲解这道题/这部分内容：先指出核心考点与思路，再逐步推导，最后点明易错点：\n\n")
            ),
            SlashPromptCommand(
                id: "contract-check",
                command: "/contract",
                title: String(localized: "合同账单避坑"),
                subtitle: String(localized: "大白话拆解关键数字、期限与潜在风险条款"),
                symbol: "doc.text.magnifyingglass",
                templatePrefix: String(localized: "请用大白话审阅以下合同/账单/说明，标出关键费用、违约/免责陷阱、重要截止时间与核对建议：\n\n")
            ),
            SlashPromptCommand(
                id: "life-plan",
                command: "/plan",
                title: String(localized: "出行 / 事务规划"),
                subtitle: String(localized: "按时间线、预算与清单给出可执行方案"),
                symbol: "map",
                templatePrefix: String(localized: "请帮我制定一份清晰可落地的计划（含分天/分阶段时间线、预算估测、物品清单与避坑贴士）：\n\n")
            )
        ]
    }
}
