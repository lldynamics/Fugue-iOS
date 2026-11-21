package com.iosbox.app.core.model

import com.iosbox.app.core.backup.Iso8601EpochMillisSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID
import kotlin.math.roundToInt
import kotlin.math.roundToLong

@Serializable
enum class StudyCoachMode(val rawValue: String) {
    @SerialName("off")
    OFF("off"),

    @SerialName("socratic")
    SOCRATIC("socratic"),

    @SerialName("feynman")
    FEYNMAN("feynman"),

    @SerialName("drill")
    DRILL("drill");

    val displayName: String
        get() = when (this) {
            OFF -> L10n.text("关闭助学导师", "Coach Off")
            SOCRATIC -> L10n.text("苏格拉底引导", "Socratic Tutor")
            FEYNMAN -> L10n.text("费曼挑刺学生", "Feynman Student")
            DRILL -> L10n.text("闯关实战特训", "Skill Drill Coach")
        }

    val shortBadge: String
        get() = when (this) {
            OFF -> L10n.text("导师", "Coach")
            SOCRATIC -> L10n.text("苏格拉底", "Socratic")
            FEYNMAN -> L10n.text("费曼学生", "Feynman")
            DRILL -> L10n.text("闯关特训", "Drill")
        }

    val subtitle: String
        get() = when (this) {
            OFF -> L10n.text("常规直接解答模式", "Standard direct answer mode")
            SOCRATIC -> L10n.text(
                "不直接给答案，先追问定位你的理解盲区，循序渐进启发思考",
                "Guides with targeted questions and progressive hints before revealing the solution"
            )
            FEYNMAN -> L10n.text(
                "由你扮演老师讲解概念，AI 扮演挑刺学生追问漏洞并给掌握度评分",
                "You explain concepts as teacher while AI probes gaps as an inquisitive student"
            )
            DRILL -> L10n.text(
                "由浅入深出实战题（Lv.1 → Lv.3），逐题批改反馈后再解锁下一关",
                "Progressive Lv.1 -> Lv.3 practice problems graded step-by-step"
            )
        }

    val systemInstruction: String
        get() = when (this) {
            OFF -> ""
            SOCRATIC -> """
                [Socratic Learning Coach Mode]
                You are an encouraging, rigorous Socratic tutor helping the user truly master the skill or concept rather than passively copying answers.
                Rules:
                1. Do NOT give away the full solution or final answer immediately unless the user explicitly asks to reveal it.
                2. Start by acknowledging what the user wants to learn, briefly framing the core mental model in 2-3 sentences, and asking ONE focused diagnostic or guiding question.
                3. When the user replies, validate what they got right, gently point out any misconception, give a small progressive hint if they are stuck, and guide them one step further.
                4. Once the user demonstrates solid understanding, briefly summarize the key takeaway and offer to test them or move to the next concept.
            """.trimIndent()
            FEYNMAN -> """
                [Feynman Technique Student Mode]
                The user is practicing the Feynman Technique by explaining a topic or skill to you.
                Rules:
                1. Act as an inquisitive, sharp-minded student who refuses to accept vague hand-waving or unexplained jargon.
                2. Identify parts of the user's explanation that are crystal clear, then ask 1-2 pointed follow-up questions about hidden assumptions, edge cases, or terms a beginner wouldn't understand.
                3. Do NOT lecture at length; push the user to refine their own analogy and explanation.
                4. When the user asks for evaluation or gives a complete, clear explanation, provide a structured Mastery Scorecard (Clarity, Accuracy, Blind Spots, and a Polished Analogy).
            """.trimIndent()
            DRILL -> """
                [Progressive Skill Drill Coach Mode]
                You are a hands-on skill drill coach running interactive micro-challenges (Lv.1 Warm-up -> Lv.2 Applied -> Lv.3 Edge-Case Boss).
                Rules:
                1. Present ONE concrete, bite-sized practice problem or scenario at a time matching the current level, and wait for the user's attempt.
                2. When the user submits an attempt, grade it candidly: highlight strengths, pinpoint bugs or reasoning flaws, show the optimal pattern concisely, and then issue the next-level challenge.
            """.trimIndent()
        }

    data class QuickChip(
        val id: String,
        val label: String,
        val prompt: String
    )

    val quickChips: List<QuickChip>
        get() = when (this) {
            OFF -> emptyList()
            SOCRATIC -> listOf(
                QuickChip(
                    id = "soc-hint",
                    label = L10n.text("💡 给点提示", "💡 Hint"),
                    prompt = L10n.text(
                        "我有点卡住了，请给我一个小提示（先不要直接揭晓最终答案）。",
                        "I'm a bit stuck. Give me a small progressive hint without revealing the full answer yet."
                    )
                ),
                QuickChip(
                    id = "soc-check",
                    label = L10n.text("✅ 考考我", "✅ Check Me"),
                    prompt = L10n.text(
                        "请针对刚才的知识点出一道简短的快问快答，检验我是否真正理解了。",
                        "Ask me one quick check question to verify I really understood this concept."
                    )
                ),
                QuickChip(
                    id = "soc-reveal",
                    label = L10n.text("📖 揭晓完整解析", "📖 Full Solution"),
                    prompt = L10n.text(
                        "我已经独立思考过了，请直接给出完整的标准解析与核心要点总结。",
                        "I've thought through it independently. Please show the full explanation and key takeaways."
                    )
                )
            )
            FEYNMAN -> listOf(
                QuickChip(
                    id = "feyn-score",
                    label = L10n.text("🎯 给我的讲解打分", "🎯 Score My Explanation"),
                    prompt = L10n.text(
                        "请评估我刚才的费曼讲解，给出清晰度与准确度评分，指出我没讲透的盲区，并示范一个更通俗精妙的类比。",
                        "Evaluate my explanation with a Clarity & Accuracy scorecard, blind spots, and a sharper analogy."
                    )
                ),
                QuickChip(
                    id = "feyn-probe",
                    label = L10n.text("🔍 追问边界条件", "🔍 Probe Edge Cases"),
                    prompt = L10n.text(
                        "请挑一个我刚才忽略的极端情况或底层原理继续追问我。",
                        "Challenge me on an edge case or underlying mechanism I skipped."
                    )
                )
            )
            DRILL -> listOf(
                QuickChip(
                    id = "drill-hint",
                    label = L10n.text("🆘 给第一步思路", "🆘 First-Step Hint"),
                    prompt = L10n.text(
                        "这道题我还没头绪，请只提示第一步切入方向，让我自己完成作答。",
                        "Give me only the first step direction so I can solve the rest myself."
                    )
                ),
                QuickChip(
                    id = "drill-next",
                    label = L10n.text("⏭️ 下一关挑战", "⏭️ Next Level"),
                    prompt = L10n.text(
                        "请进入下一关难度更高的实战练习题！",
                        "Advance me to the next higher-difficulty drill challenge!"
                    )
                )
            )
        }
}

@Serializable
data class StudyCardDraft(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val front: String,
    val back: String,
    val hint: String? = null
)

@Serializable
data class StudyQuizQuestion(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val question: String,
    val options: List<String>,
    val correctIndex: Int,
    val explanation: String,
    val selectedIndex: Int? = null
) {
    val isAnswered: Boolean
        get() = selectedIndex != null

    val isCorrect: Boolean
        get() = selectedIndex == correctIndex
}

@Serializable
data class StudyQuizBundle(
    val title: String,
    val questions: List<StudyQuizQuestion>,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val createdAt: Long = System.currentTimeMillis()
) {
    val answeredCount: Int
        get() = questions.count { it.isAnswered }

    val correctCount: Int
        get() = questions.count { it.isCorrect }
}

@Serializable
enum class StudyReviewRating(val rawValue: String) {
    @SerialName("again")
    AGAIN("again"),

    @SerialName("hard")
    HARD("hard"),

    @SerialName("good")
    GOOD("good"),

    @SerialName("easy")
    EASY("easy");

    val title: String
        get() = when (this) {
            AGAIN -> L10n.text("重来", "Again")
            HARD -> L10n.text("吃力", "Hard")
            GOOD -> L10n.text("掌握", "Good")
            EASY -> L10n.text("轻松", "Easy")
        }
}

@Serializable
data class StudyFlashcard(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val deckName: String,
    val front: String,
    val back: String,
    val hint: String? = null,
    val sourceConversationID: String? = null,
    val sourceMessageID: String? = null,
    val repetitions: Int = 0,
    val intervalDays: Double = 0.0,
    val easeFactor: Double = 2.5,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val dueAt: Long = System.currentTimeMillis(),
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val lastReviewedAt: Long? = null,
    val lapses: Int = 0,
    @Serializable(with = Iso8601EpochMillisSerializer::class)
    val createdAt: Long = System.currentTimeMillis()
) {
    val isMastered: Boolean
        get() = repetitions >= 2 && intervalDays >= 6.0

    fun isDue(nowEpochMs: Long = System.currentTimeMillis()): Boolean = dueAt <= nowEpochMs

    /**
     * Applies SM-2 inspired spaced-repetition scheduling deterministically, matching iOS.
     */
    fun applying(rating: StudyReviewRating, nowEpochMs: Long = System.currentTimeMillis()): StudyFlashcard {
        return when (rating) {
            StudyReviewRating.AGAIN -> copy(
                repetitions = 0,
                lapses = lapses + 1,
                intervalDays = 0.0,
                easeFactor = maxOf(1.3, easeFactor - 0.2),
                lastReviewedAt = nowEpochMs,
                dueAt = nowEpochMs + 10L * 60L * 1000L
            )

            StudyReviewRating.HARD -> {
                val newEase = maxOf(1.3, easeFactor - 0.15)
                val days = if (repetitions == 0) {
                    1.0
                } else {
                    maxOf(1.0, (intervalDays * 1.2 * 10.0).roundToInt() / 10.0)
                }
                copy(
                    repetitions = maxOf(1, repetitions),
                    intervalDays = days,
                    easeFactor = newEase,
                    lastReviewedAt = nowEpochMs,
                    dueAt = nowEpochMs + (days * DAY_MILLIS).roundToLong()
                )
            }

            StudyReviewRating.GOOD -> {
                val days = when (repetitions) {
                    0 -> 1.0
                    1 -> 3.0
                    else -> maxOf(1.0, (intervalDays * easeFactor).roundToLong().toDouble())
                }
                copy(
                    repetitions = repetitions + 1,
                    intervalDays = days,
                    lastReviewedAt = nowEpochMs,
                    dueAt = nowEpochMs + (days * DAY_MILLIS).roundToLong()
                )
            }

            StudyReviewRating.EASY -> {
                val newEase = minOf(3.2, easeFactor + 0.15)
                val days = when (repetitions) {
                    0 -> 4.0
                    1 -> 7.0
                    else -> maxOf(4.0, (intervalDays * newEase * 1.3).roundToLong().toDouble())
                }
                copy(
                    repetitions = repetitions + 1,
                    intervalDays = days,
                    easeFactor = newEase,
                    lastReviewedAt = nowEpochMs,
                    dueAt = nowEpochMs + (days * DAY_MILLIS).roundToLong()
                )
            }
        }
    }

    fun nextIntervalLabel(rating: StudyReviewRating): String {
        if (rating == StudyReviewRating.AGAIN) {
            return L10n.text("10 分钟", "10 min")
        }
        val simulated = applying(rating, nowEpochMs = 0L)
        val days = maxOf(1, simulated.intervalDays.roundToInt())
        return L10n.text("$days 天", "${days}d")
    }

    companion object {
        const val DAY_MILLIS = 86_400_000L
    }
}
