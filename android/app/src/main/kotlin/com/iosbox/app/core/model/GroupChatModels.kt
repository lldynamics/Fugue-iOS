package com.iosbox.app.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
enum class GroupSpeakingMode(val rawValue: String) {
    @SerialName("smartRelay")
    SMART_RELAY("smartRelay"),

    @SerialName("roundRobin")
    ROUND_ROBIN("roundRobin"),

    @SerialName("mentionOnly")
    MENTION_ONLY("mentionOnly");

    val displayName: String
        get() = when (this) {
            SMART_RELAY -> L10n.text("智能接力讨论", "Smart Relay")
            ROUND_ROBIN -> L10n.text("轮流依次发言", "Round Robin")
            MENTION_ONLY -> L10n.text("仅 @ 点名发言", "@Mention Only")
        }

    val shortBadge: String
        get() = when (this) {
            SMART_RELAY -> L10n.text("智能接力", "Relay")
            ROUND_ROBIN -> L10n.text("轮流", "Round")
            MENTION_ONLY -> L10n.text("点名", "@Only")
        }

    val subtitle: String
        get() = when (this) {
            SMART_RELAY -> L10n.text(
                "支持 @ 点名与成员互相点名抢麦，有话接话、没话潜水，自动碰撞 2～6 句后停下等你拍板。",
                "Supports @mentions and peer-to-peer relays across 2–6 turns before handing back to you."
            )
            ROUND_ROBIN -> L10n.text(
                "按群成员座位顺序依次表态，适合多视角方案评审与头脑风暴。",
                "Members speak in seating order, ideal for multi-perspective critiques and brainstorming."
            )
            MENTION_ONLY -> L10n.text(
                "成员平时保持潜水，只有被你 @ 点名或点击「全员表决」时才发言。",
                "Members stay silent unless explicitly @mentioned or during a group vote."
            )
        }
}

@Serializable
enum class GroupSpeechStyle(val rawValue: String) {
    @SerialName("naturalShort")
    NATURAL_SHORT("naturalShort"),

    @SerialName("deepDebate")
    DEEP_DEBATE("deepDebate");

    val displayName: String
        get() = when (this) {
            NATURAL_SHORT -> L10n.text("群聊口语短句", "Natural Short Chat")
            DEEP_DEBATE -> L10n.text("圆桌深度交锋", "Deep Roundtable")
        }

    val subtitle: String
        get() = when (this) {
            NATURAL_SHORT -> L10n.text(
                "去 AI 公文味，每次 2～4 句直击要害，像真人在微信群里拿手机回消息。",
                "Conversational 2–4 sentence messages with minimal filler, like a real group chat."
            )
            DEEP_DEBATE -> L10n.text(
                "保留交锋锋芒的同时允许展开详细论据与代码示例。",
                "Maintains sharp first-person perspective while allowing technical details and code."
            )
        }
}

@Serializable
enum class GroupSpeechIntent(val rawValue: String) {
    @SerialName("openPerspective")
    OPEN_PERSPECTIVE("openPerspective"),

    @SerialName("rebuttal")
    REBUTTAL("rebuttal"),

    @SerialName("alternative")
    ALTERNATIVE("alternative"),

    @SerialName("probeDetail")
    PROBE_DETAIL("probeDetail"),

    @SerialName("mediate")
    MEDIATE("mediate"),

    @SerialName("vote")
    VOTE("vote"),

    @SerialName("summarize")
    SUMMARIZE("summarize");

    val badgeTitle: String?
        get() = when (this) {
            OPEN_PERSPECTIVE -> null
            REBUTTAL -> L10n.text("挑刺反驳", "Rebuttal")
            ALTERNATIVE -> L10n.text("另辟蹊径", "Alternative")
            PROBE_DETAIL -> L10n.text("追问细节", "Probe")
            MEDIATE -> L10n.text("折中收敛", "Mediate")
            VOTE -> L10n.text("亮牌表决", "Vote")
            SUMMARIZE -> L10n.text("讨论纪要", "Summary")
        }

    companion object {
        fun parse(raw: String): GroupSpeechIntent? =
            when (raw.trim().lowercase()) {
                "open", "openperspective", "perspective" -> OPEN_PERSPECTIVE
                "rebuttal", "disagree", "challenge", "critique" -> REBUTTAL
                "alternative", "alt", "brainstorm" -> ALTERNATIVE
                "probe", "probedetail", "question", "ask" -> PROBE_DETAIL
                "mediate", "compromise", "converge" -> MEDIATE
                "vote" -> VOTE
                "summarize", "summary" -> SUMMARIZE
                else -> null
            }
    }
}

@Serializable
data class PersonaMaterial(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val title: String,
    val text: String,
    val url: String? = null
) {
    companion object {
        const val MAXIMUM_COUNT = 6
        const val MAXIMUM_CHARACTERS = 4_000
    }
}

@Serializable
data class GroupPersona(
    val materials: List<PersonaMaterial> = emptyList()
) {
    val isEmpty: Boolean
        get() = materials.isEmpty()
}

@Serializable
data class PersonaExcerpt(
    val source: String,
    val excerpt: String
)

@Serializable
data class GroupMember(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String,
    val title: String = "",
    val avatarEmoji: String = "🤖",
    val accentHex: String = "#3F6EF6",
    val rolePrompt: String = "",
    val target: ResolvedModelTarget,
    val temperature: Double = 0.75,
    val isMuted: Boolean = false,
    val profileID: String? = null,
    val persona: GroupPersona? = null,
    val bookFriend: BookFriend? = null
) {
    val isSimulatedPersona: Boolean
        get() = profileID != null || persona != null

    val displayLabel: String
        get() {
            val cleanTitle = title.trim()
            val cleanName = name.trim()
            if (cleanTitle.isEmpty()) {
                return cleanName.ifEmpty { L10n.text("群成员", "Member") }
            }
            if (cleanName.isEmpty()) return cleanTitle
            return "$cleanTitle·$cleanName"
        }

    val mentionToken: String
        get() {
            val cleanName = name.trim()
            return cleanName.ifEmpty { displayLabel }
        }

    fun portableProfile(): GroupMember {
        val canonicalId = (profileID ?: id).uppercase()
        return copy(
            id = canonicalId,
            profileID = canonicalId,
            isMuted = false
        )
    }

    fun copyForNewRoom(): GroupMember {
        if (profileID != null) return inRoom()
        return copy(id = UUID.randomUUID().toString().uppercase())
    }

    fun inRoom(replacing: GroupMember? = null): GroupMember {
        val base = portableProfile()
        return base.copy(
            id = replacing?.id?.uppercase() ?: UUID.randomUUID().toString().uppercase(),
            isMuted = replacing?.isMuted ?: false
        )
    }

    companion object {
        val paletteHexes: List<String> = listOf(
            "#3F6EF6", "#E65D4F", "#18A058", "#8A4FFF", "#D9822B", "#0E9AA7"
        )
    }
}

@Serializable
data class GroupReaction(
    val memberID: String,
    val memberName: String,
    val memberEmoji: String,
    val emoji: String
) {
    val key: String
        get() = "$memberID-$emoji"
}

data class GroupRoomTemplate(
    val id: String,
    val roomTitle: String,
    val roomEmoji: String,
    val subtitle: String,
    val sharedTopicPrompt: String,
    val speakingMode: GroupSpeakingMode,
    val speechStyle: GroupSpeechStyle,
    val seats: List<Seat>
) {
    data class Seat(
        val name: String,
        val title: String,
        val emoji: String,
        val accentHex: String,
        val rolePrompt: String,
        val temperature: Double
    )

    fun instantiate(targets: List<ResolvedModelTarget>): List<GroupMember> {
        if (targets.isEmpty()) return emptyList()
        return seats.mapIndexed { idx, seat ->
            GroupMember(
                name = seat.name,
                title = seat.title,
                avatarEmoji = seat.emoji,
                accentHex = seat.accentHex,
                rolePrompt = seat.rolePrompt,
                target = targets[idx % targets.size],
                temperature = seat.temperature
            )
        }
    }

    companion object {
        val builtInTemplates: List<GroupRoomTemplate>
            get() = listOf(
                GroupRoomTemplate(
                    id = "startup-board",
                    roomTitle = L10n.text("创业点子审委会", "Startup Review Board"),
                    roomEmoji = "🚀",
                    subtitle = L10n.text(
                        "乐观产品 + 毒舌架构师 + 挑剔投资人，全方位拷问你的想法",
                        "PM + Blunt Architect + Skeptical VC stress-testing your idea"
                    ),
                    sharedTopicPrompt = L10n.text(
                        "这是一个产品与创业想法评审群。大家围绕群主抛出的点子真实讨论：有人挖掘用户痛点，有人评估技术可行性与坑点，有人拷问商业变现与护城河。",
                        "This is a product & startup review board. Debate the Host's idea candidly across user pain points, technical feasibility, and monetization."
                    ),
                    speakingMode = GroupSpeakingMode.SMART_RELAY,
                    speechStyle = GroupSpeechStyle.NATURAL_SHORT,
                    seats = listOf(
                        Seat(
                            name = L10n.text("林晓", "Lin"),
                            title = L10n.text("产品经理", "PM"),
                            emoji = "👩‍💼",
                            accentHex = "#3F6EF6",
                            rolePrompt = L10n.text(
                                "你是一位直觉敏锐的产品经理，擅长站在真实高频场景挖掘痛点、传播钩子与最小可行产品（MVP）切口，说话干练有感染力。",
                                "You are an instinctive PM focused on real user pain points, viral hooks, and pragmatic MVP scoping."
                            ),
                            temperature = 0.8
                        ),
                        Seat(
                            name = L10n.text("老王", "Wang"),
                            title = L10n.text("毒舌架构师", "Architect"),
                            emoji = "🧑‍💻",
                            accentHex = "#E65D4F",
                            rolePrompt = L10n.text(
                                "你是一位有十五年一线经验的毒舌首席架构师，最讨厌画大饼与过度设计，专门一针见血指出技术瓶颈、边界异常、维护成本和安全隐患。",
                                "You are a 15-year principal architect who hates hand-waving and exposes technical bottlenecks, edge cases, and maintenance costs."
                            ),
                            temperature = 0.6
                        ),
                        Seat(
                            name = L10n.text("沈总", "Shen"),
                            title = L10n.text("早期投资人", "Seed VC"),
                            emoji = "🧐",
                            accentHex = "#D9822B",
                            rolePrompt = L10n.text(
                                "你是一位眼光毒辣的早期风险投资人，只关心获客成本、留存壁垒、付费意愿以及为什么大厂或竞品做不了，喜欢用犀利反问逼出真相。",
                                "You are a sharp early-stage VC focused strictly on CAC, retention, willingness to pay, and defensibility."
                            ),
                            temperature = 0.65
                        )
                    )
                ),
                GroupRoomTemplate(
                    id = "red-blue-debate",
                    roomTitle = L10n.text("红蓝杠精辩论局", "Red vs Blue Debate"),
                    roomEmoji = "⚡",
                    subtitle = L10n.text(
                        "正方力挺 + 反方挑刺 + 冷静裁判，专治买房跳槽选型纠结",
                        "Advocate + Skeptic + Objective Referee for tough tradeoffs"
                    ),
                    sharedTopicPrompt = L10n.text(
                        "这是一个红蓝对抗决策群。面对群主纠结的选择，正反双方必须针锋相对摆事实讲利弊，裁判负责拆穿逻辑漏洞并提炼拍板标准。",
                        "This is a red-blue decision debate room. Pro and Con argue sharply with facts while the Referee extracts concrete decision criteria."
                    ),
                    speakingMode = GroupSpeakingMode.SMART_RELAY,
                    speechStyle = GroupSpeechStyle.NATURAL_SHORT,
                    seats = listOf(
                        Seat(
                            name = L10n.text("陈锋", "Chen"),
                            title = L10n.text("正方主辩", "Pro"),
                            emoji = "🔥",
                            accentHex = "#E65D4F",
                            rolePrompt = L10n.text(
                                "你是果断行动派，擅长放大核心收益、时间窗口与向上赔率，用强有力的论据推动决策落地。",
                                "You champion bold action, upside potential, and decisive momentum backed by strong arguments."
                            ),
                            temperature = 0.75
                        ),
                        Seat(
                            name = L10n.text("周凛", "Zhou"),
                            title = L10n.text("反方挑刺", "Con"),
                            emoji = "🧊",
                            accentHex = "#3F6EF6",
                            rolePrompt = L10n.text(
                                "你是深度风险厌恶的冷静挑刺王，专门戳破幸存者偏差、隐性沉没成本与最坏情况，绝不附和盲目乐观。",
                                "You stress-test every assumption, exposing survivorship bias, hidden sunk costs, and worst-case scenarios."
                            ),
                            temperature = 0.7
                        ),
                        Seat(
                            name = L10n.text("顾言", "Gu"),
                            title = L10n.text("独立裁判", "Referee"),
                            emoji = "⚖️",
                            accentHex = "#18A058",
                            rolePrompt = L10n.text(
                                "你是客观克制的决策顾问，擅长指出正反双方各自成立的前提条件，并向群主追问最关键的个人约束。",
                                "You identify the exact conditions under which each side holds and ask the Host the deciding constraint."
                            ),
                            temperature = 0.45
                        )
                    )
                ),
                GroupRoomTemplate(
                    id = "tech-review",
                    roomTitle = L10n.text("技术方案三堂会审", "Engineering Review"),
                    roomEmoji = "💻",
                    subtitle = L10n.text(
                        "性能极客 + 安全专家 + 极简维护派，代码与架构全方位会诊",
                        "Performance + Security + Simplicity review panel"
                    ),
                    sharedTopicPrompt = L10n.text(
                        "这是一个资深工程技术评审群。针对群主发来的代码、Bug 或架构方案，分别从性能吞吐、安全边界和长期可维护性切入讨论。",
                        "Senior engineering panel reviewing code, bugs, and system designs across throughput, security boundaries, and maintainability."
                    ),
                    speakingMode = GroupSpeakingMode.SMART_RELAY,
                    speechStyle = GroupSpeechStyle.DEEP_DEBATE,
                    seats = listOf(
                        Seat(
                            name = L10n.text("阿杰", "Jie"),
                            title = L10n.text("性能极客", "Perf"),
                            emoji = "⚡",
                            accentHex = "#8A4FFF",
                            rolePrompt = L10n.text(
                                "你痴迷底层性能、内存布局、并发竞争与主线程卡顿优化，对低效循环和多余拷贝零容忍。",
                                "You focus relentlessly on latency, memory layout, concurrency hazards, and eliminating unnecessary allocations."
                            ),
                            temperature = 0.4
                        ),
                        Seat(
                            name = L10n.text("陆工", "Lu"),
                            title = L10n.text("安全审计", "Security"),
                            emoji = "🛡️",
                            accentHex = "#0E9AA7",
                            rolePrompt = L10n.text(
                                "你专注安全攻防、鉴权越权、数据泄漏、网络超时与异常恢复，专门抓别人忽略的极端边界条件。",
                                "You hunt auth bypasses, data leaks, timeout handling flaws, and extreme boundary edge cases."
                            ),
                            temperature = 0.35
                        ),
                        Seat(
                            name = L10n.text("老赵", "Zhao"),
                            title = L10n.text("极简工程派", "KISS"),
                            emoji = "🧹",
                            accentHex = "#18A058",
                            rolePrompt = L10n.text(
                                "你推崇 KISS 原则和可读性，反对炫技与过度抽象，总能给出代码量最少、半年后最好改的务实方案。",
                                "You advocate KISS and readability over over-engineering, favoring simple maintainable designs."
                            ),
                            temperature = 0.5
                        )
                    )
                ),
                GroupRoomTemplate(
                    id = "late-night-lounge",
                    roomTitle = L10n.text("深夜吹水智囊团", "Late Night Lounge"),
                    roomEmoji = "☕",
                    subtitle = L10n.text(
                        "幽默损友 + 温柔共情师 + 理性军师，陪聊解闷也能出主意",
                        "Witty Friend + Warm Listener + Pragmatic Advisor"
                    ),
                    sharedTopicPrompt = L10n.text(
                        "这是一个轻松真实的老友微信群。大家像认识多年的朋友一样跟群主聊天吐槽、提供情绪价值和实在建议，绝对不要说官话套话。",
                        "Relaxed group chat with longtime friends. Chat warmly and candidly without stiff corporate phrasing."
                    ),
                    speakingMode = GroupSpeakingMode.SMART_RELAY,
                    speechStyle = GroupSpeechStyle.NATURAL_SHORT,
                    seats = listOf(
                        Seat(
                            name = L10n.text("阿泽", "Ze"),
                            title = L10n.text("嘴硬损友", "Banter"),
                            emoji = "😼",
                            accentHex = "#D9822B",
                            rolePrompt = L10n.text(
                                "你是群主认识十年的幽默损友，说话风趣接地气，擅长用玩笑话一针见血点破内耗，护短但嘴上不饶人。",
                                "You are a humorous longtime friend who cuts through overthinking with witty banter and genuine care."
                            ),
                            temperature = 0.9
                        ),
                        Seat(
                            name = L10n.text("知夏", "Xia"),
                            title = L10n.text("温柔树洞", "Empathy"),
                            emoji = "🌿",
                            accentHex = "#18A058",
                            rolePrompt = L10n.text(
                                "你细腻温暖、观察力强，能听懂群主没明说的委屈或疲惫，先接住情绪再温和梳理感受，从不说教。",
                                "You notice unspoken stress, validate feelings gently, and never lecture."
                            ),
                            temperature = 0.8
                        ),
                        Seat(
                            name = L10n.text("方远", "Fang"),
                            title = L10n.text("靠谱军师", "Advisor"),
                            emoji = "🧭",
                            accentHex = "#3F6EF6",
                            rolePrompt = L10n.text(
                                "你沉稳务实，等大家吐槽完后，总能帮群主把乱麻理顺，给出一两个明天一早就能轻松做到的小动作。",
                                "Calm and grounded, you distill tangled worries into one or two concrete small steps for tomorrow."
                            ),
                            temperature = 0.6
                        )
                    )
                )
            )
    }
}
