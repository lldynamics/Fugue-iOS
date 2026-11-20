import Foundation

enum StudyCoachMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case socratic
    case feynman
    case drill

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return String(localized: "关闭助学导师")
        case .socratic:
            return String(localized: "苏格拉底引导")
        case .feynman:
            return String(localized: "费曼挑刺学生")
        case .drill:
            return String(localized: "闯关实战特训")
        }
    }

    var shortBadge: String {
        switch self {
        case .off:
            return String(localized: "导师")
        case .socratic:
            return String(localized: "苏格拉底")
        case .feynman:
            return String(localized: "费曼学生")
        case .drill:
            return String(localized: "闯关特训")
        }
    }

    var subtitle: String {
        switch self {
        case .off:
            return String(localized: "常规直接解答模式")
        case .socratic:
            return String(localized: "不直接给答案，先追问定位你的理解盲区，循序渐进启发思考")
        case .feynman:
            return String(localized: "由你扮演老师讲解概念，AI 扮演挑刺学生追问漏洞并给掌握度评分")
        case .drill:
            return String(localized: "由浅入深出实战题（Lv.1 → Lv.3），逐题批改反馈后再解锁下一关")
        }
    }

    var symbol: String {
        switch self {
        case .off: return "graduationcap"
        case .socratic: return "lightbulb.max.fill"
        case .feynman: return "person.wave.2.fill"
        case .drill: return "flag.checkered"
        }
    }

    var systemInstruction: String {
        switch self {
        case .off:
            return ""
        case .socratic:
            return """
            [Socratic Learning Coach Mode]
            You are an encouraging, rigorous Socratic tutor helping the user truly master the skill or concept rather than passively copying answers.
            Rules:
            1. Do NOT give away the full solution or final answer immediately unless the user explicitly asks to reveal it.
            2. Start by acknowledging what the user wants to learn, briefly framing the core mental model in 2-3 sentences, and asking ONE focused diagnostic or guiding question.
            3. When the user replies, validate what they got right, gently point out any misconception, give a small progressive hint if they are stuck, and guide them one step further.
            4. Once the user demonstrates solid understanding, briefly summarize the key takeaway and offer to test them or move to the next concept.
            """
        case .feynman:
            return """
            [Feynman Technique Student Mode]
            The user is practicing the Feynman Technique by explaining a topic or skill to you.
            Rules:
            1. Act as an inquisitive, sharp-minded student who refuses to accept vague hand-waving or unexplained jargon.
            2. Identify parts of the user's explanation that are crystal clear, then ask 1-2 pointed follow-up questions about hidden assumptions, edge cases, or terms a beginner wouldn't understand.
            3. Do NOT lecture at length; push the user to refine their own analogy and explanation.
            4. When the user asks for evaluation or gives a complete, clear explanation, provide a structured Mastery Scorecard (Clarity, Accuracy, Blind Spots, and a Polished Analogy).
            """
        case .drill:
            return """
            [Progressive Skill Drill Coach Mode]
            You are a hands-on skill drill coach running interactive micro-challenges (Lv.1 Warm-up -> Lv.2 Applied -> Lv.3 Edge-Case Boss).
            Rules:
            1. Present ONE concrete, bite-sized practice problem or scenario at a time matching the current level, and wait for the user's attempt.
            2. When the user submits an attempt, grade it candidly: highlight strengths, pinpoint bugs or reasoning flaws, show the optimal pattern concisely, and then issue the next-level challenge.
            """
        }
    }

    struct QuickChip: Identifiable {
        let id: String
        let label: String
        let prompt: String
    }

    var quickChips: [QuickChip] {
        switch self {
        case .off:
            return []
        case .socratic:
            return [
                QuickChip(
                    id: "soc-hint",
                    label: String(localized: "💡 给点提示"),
                    prompt: String(localized: "我有点卡住了，请给我一个小提示（先不要直接揭晓最终答案）。")
                ),
                QuickChip(
                    id: "soc-check",
                    label: String(localized: "✅ 考考我"),
                    prompt: String(localized: "请针对刚才的知识点出一道简短的快问快答，检验我是否真正理解了。")
                ),
                QuickChip(
                    id: "soc-reveal",
                    label: String(localized: "📖 揭晓完整解析"),
                    prompt: String(localized: "我已经独立思考过了，请直接给出完整的标准解析与核心要点总结。")
                )
            ]
        case .feynman:
            return [
                QuickChip(
                    id: "feyn-score",
                    label: String(localized: "🎯 给我的讲解打分"),
                    prompt: String(localized: "请评估我刚才的费曼讲解，给出清晰度与准确度评分，指出我没讲透的盲区，并示范一个更通俗精妙的类比。")
                ),
                QuickChip(
                    id: "feyn-probe",
                    label: String(localized: "🔍 追问边界条件"),
                    prompt: String(localized: "请挑一个我刚才忽略的极端情况或底层原理继续追问我。")
                )
            ]
        case .drill:
            return [
                QuickChip(
                    id: "drill-hint",
                    label: String(localized: "🆘 给第一步思路"),
                    prompt: String(localized: "这道题我还没头绪，请只提示第一步切入方向，让我自己完成作答。")
                ),
                QuickChip(
                    id: "drill-next",
                    label: String(localized: "⏭️ 下一关挑战"),
                    prompt: String(localized: "请进入下一关难度更高的实战练习题！")
                )
            ]
        }
    }
}

struct StudyCardDraft: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var front: String
    var back: String
    var hint: String?

    init(id: UUID = UUID(), front: String, back: String, hint: String? = nil) {
        self.id = id
        self.front = front
        self.back = back
        self.hint = hint
    }
}

struct StudyQuizQuestion: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var question: String
    var options: [String]
    var correctIndex: Int
    var explanation: String
    var selectedIndex: Int?

    init(
        id: UUID = UUID(),
        question: String,
        options: [String],
        correctIndex: Int,
        explanation: String,
        selectedIndex: Int? = nil
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.correctIndex = correctIndex
        self.explanation = explanation
        self.selectedIndex = selectedIndex
    }

    var isAnswered: Bool { selectedIndex != nil }
    var isCorrect: Bool { selectedIndex == correctIndex }
}

struct StudyQuizBundle: Codable, Equatable, Sendable {
    var title: String
    var questions: [StudyQuizQuestion]
    var createdAt: Date

    init(title: String, questions: [StudyQuizQuestion], createdAt: Date = Date()) {
        self.title = title
        self.questions = questions
        self.createdAt = createdAt
    }

    var answeredCount: Int {
        questions.filter(\.isAnswered).count
    }

    var correctCount: Int {
        questions.filter(\.isCorrect).count
    }
}

enum StudyReviewRating: String, Codable, CaseIterable, Identifiable, Sendable {
    case again
    case hard
    case good
    case easy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .again: return String(localized: "重来")
        case .hard: return String(localized: "吃力")
        case .good: return String(localized: "掌握")
        case .easy: return String(localized: "轻松")
        }
    }
}

struct StudyFlashcard: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var deckName: String
    var front: String
    var back: String
    var hint: String?
    var sourceConversationID: UUID?
    var sourceMessageID: UUID?
    var repetitions: Int
    var intervalDays: Double
    var easeFactor: Double
    var dueAt: Date
    var lastReviewedAt: Date?
    var lapses: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        deckName: String,
        front: String,
        back: String,
        hint: String? = nil,
        sourceConversationID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        repetitions: Int = 0,
        intervalDays: Double = 0,
        easeFactor: Double = 2.5,
        dueAt: Date = Date(),
        lastReviewedAt: Date? = nil,
        lapses: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.deckName = deckName
        self.front = front
        self.back = back
        self.hint = hint
        self.sourceConversationID = sourceConversationID
        self.sourceMessageID = sourceMessageID
        self.repetitions = repetitions
        self.intervalDays = intervalDays
        self.easeFactor = easeFactor
        self.dueAt = dueAt
        self.lastReviewedAt = lastReviewedAt
        self.lapses = lapses
        self.createdAt = createdAt
    }

    var isMastered: Bool {
        repetitions >= 2 && intervalDays >= 6
    }

    func isDue(at date: Date = Date()) -> Bool {
        dueAt <= date
    }

    /// Applies SM-2 / FSRS-inspired spaced-repetition scheduling deterministically.
    func applying(_ rating: StudyReviewRating, now: Date = Date()) -> StudyFlashcard {
        var next = self
        next.lastReviewedAt = now

        switch rating {
        case .again:
            next.repetitions = 0
            next.lapses += 1
            next.intervalDays = 0
            next.easeFactor = max(1.3, easeFactor - 0.2)
            next.dueAt = now.addingTimeInterval(10 * 60) // 10 minutes

        case .hard:
            next.easeFactor = max(1.3, easeFactor - 0.15)
            let days: Double
            if repetitions == 0 {
                days = 1.0
            } else {
                days = max(1.0, (intervalDays * 1.2 * 10).rounded() / 10)
            }
            next.repetitions = max(1, repetitions)
            next.intervalDays = days
            next.dueAt = now.addingTimeInterval(days * 86_400)

        case .good:
            let days: Double
            if repetitions == 0 {
                days = 1.0
            } else if repetitions == 1 {
                days = 3.0
            } else {
                days = max(1.0, (intervalDays * easeFactor).rounded())
            }
            next.repetitions = repetitions + 1
            next.intervalDays = days
            next.dueAt = now.addingTimeInterval(days * 86_400)

        case .easy:
            next.easeFactor = min(3.2, easeFactor + 0.15)
            let days: Double
            if repetitions == 0 {
                days = 4.0
            } else if repetitions == 1 {
                days = 7.0
            } else {
                days = max(4.0, (intervalDays * next.easeFactor * 1.3).rounded())
            }
            next.repetitions = repetitions + 1
            next.intervalDays = days
            next.dueAt = now.addingTimeInterval(days * 86_400)
        }
        return next
    }

    func nextIntervalLabel(for rating: StudyReviewRating) -> String {
        if rating == .again {
            return String(localized: "10 分钟")
        }
        let simulated = applying(rating, now: Date(timeIntervalSince1970: 0))
        let days = max(1, Int(simulated.intervalDays.rounded()))
        return String(localized: "\(days) 天")
    }
}
