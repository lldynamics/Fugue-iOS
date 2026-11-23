package com.iosbox.app

import com.iosbox.app.core.backup.BackupJson
import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.ConversationAssistanceSettings
import com.iosbox.app.core.model.GroupMember
import com.iosbox.app.core.model.GroupPersona
import com.iosbox.app.core.model.GroupReaction
import com.iosbox.app.core.model.GroupSpeakingMode
import com.iosbox.app.core.model.GroupSpeechIntent
import com.iosbox.app.core.model.GroupSpeechStyle
import com.iosbox.app.core.model.MessageAssistanceMetadata
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.model.PersonaMaterial
import com.iosbox.app.core.model.PickedGroupMention
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.network.GroupDiscussionCoordinator
import com.iosbox.app.core.network.GroupStreamSanitizer
import com.iosbox.app.core.network.GroupTurnDirective
import com.iosbox.app.core.storage.ChatMessageItem
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GroupChatTest {
    private val defaultTarget = ResolvedModelTarget(
        providerID = "P1",
        providerName = "OpenAI",
        protocolType = APIProtocolType.OPEN_AI_COMPATIBLE,
        modelID = "gpt-4.1",
        modelDisplayName = "GPT-4.1",
        accentHex = "#3F6EF6",
        supportsVision = false,
        supportsReasoning = false
    )

    private val memberPM = GroupMember(
        id = "M_PM",
        name = "林晓",
        title = "产品经理",
        avatarEmoji = "👩‍💼",
        accentHex = "#3F6EF6",
        rolePrompt = "关注用户痛点、MVP 与增长策略",
        target = defaultTarget
    )

    private val memberArch = GroupMember(
        id = "M_ARCH",
        name = "老王",
        title = "毒舌架构师",
        avatarEmoji = "🧑‍💻",
        accentHex = "#E65D4F",
        rolePrompt = "关注并发性能、技术瓶颈与安全边界",
        target = defaultTarget
    )

    private val memberVC = GroupMember(
        id = "M_VC",
        name = "沈总",
        title = "早期投资人",
        avatarEmoji = "🧐",
        accentHex = "#D9822B",
        rolePrompt = "关注商业变现、留存与壁垒",
        target = defaultTarget
    )

    private fun sampleMessage(
        id: String,
        role: MessageRole,
        content: String,
        member: GroupMember? = null,
        sortIndex: Int
    ): ChatMessageItem = ChatMessageItem(
        id = id,
        conversationID = "CONV_1",
        role = role,
        content = content,
        reasoningContent = "",
        attachments = emptyList(),
        providerID = member?.target?.providerID,
        providerName = member?.target?.providerName ?: "",
        modelID = member?.target?.modelID ?: "",
        modelDisplayName = member?.target?.modelDisplayName ?: "",
        accentHex = member?.accentHex ?: "#3F6EF6",
        comparisonGroupID = null,
        isSelectedInGroup = true,
        isStreaming = false,
        errorMessage = null,
        finishReason = null,
        promptTokens = null,
        completionTokens = null,
        cachedTokens = null,
        latencyMs = null,
        thinkingDurationMs = null,
        synthesisSourceDigest = null,
        latestRequestID = null,
        assistanceMetadata = if (member != null) {
            MessageAssistanceMetadata(
                groupMemberID = member.id,
                groupMemberName = member.name,
                groupMemberTitle = member.title,
                groupMemberEmoji = member.avatarEmoji
            )
        } else {
            MessageAssistanceMetadata()
        },
        parentMessageID = null,
        sortIndex = sortIndex,
        createdAtEpochMs = 1_795_239_000_000L + sortIndex
    )

    @Test
    fun streamSanitizerStripsSelfPrefixesAndHoldsBackHiddenMetaTagsAcrossChunks() {
        val sanitizer = GroupStreamSanitizer("老王", "毒舌架构师·老王")
        val raw = "[毒舌架构师·老王]: 这个并发方案有锁竞争。\n[[GROUP_META: next=@林晓 | intent=rebuttal | react=🤔]]"
        val emitted = StringBuilder()
        // Feed 2 chars at a time to verify partial prefix & tail tag buffering
        var i = 0
        while (i < raw.length) {
            val end = minOf(raw.length, i + 2)
            val piece = sanitizer.ingest(raw.substring(i, end))
            assertFalse(piece.contains("GROUP_META"))
            assertFalse(piece.contains("[毒舌架构师"))
            emitted.append(piece)
            i = end
        }
        val finalized = sanitizer.finalize()
        assertEquals("这个并发方案有锁竞争。", finalized.visibleText)
        assertEquals("@林晓", finalized.directive.nextTargetRaw)
        assertEquals(GroupSpeechIntent.REBUTTAL, finalized.directive.suggestedIntent)
        assertEquals("🤔", finalized.directive.reactionEmoji)
        assertFalse(finalized.directive.isPass)
    }

    @Test
    fun streamSanitizerDetectsPassAndHostQuestions() {
        val passSanitizer = GroupStreamSanitizer("沈总", "早期投资人·沈总")
        val streamed = passSanitizer.ingest("[PASS]")
        assertEquals("", streamed)
        val passResult = passSanitizer.finalize()
        assertTrue(passResult.directive.isPass)
        assertEquals("", passResult.visibleText)

        val hostSanitizer = GroupStreamSanitizer("林晓", "产品经理·林晓")
        hostSanitizer.ingest("@群主 预算大概多少？")
        val hostResult = hostSanitizer.finalize()
        assertTrue(hostResult.directive.asksHost)

        // "@你们" must NOT falsely trigger asksHost
        val nonHostSanitizer = GroupStreamSanitizer("林晓", "产品经理·林晓")
        nonHostSanitizer.ingest("@你们 怎么看？")
        assertFalse(nonHostSanitizer.finalize().directive.asksHost)
    }

    @Test
    fun mentionExtractionAndInitialPlansCoverAllSpeakingModes() {
        val roster = listOf(memberPM, memberArch, memberVC)

        val allParsed = GroupDiscussionCoordinator.extractMentions("各位@all 聊聊看法", roster)
        assertTrue(allParsed.mentionsAll)
        assertEquals(3, allParsed.members.size)

        val explicitOrder = GroupDiscussionCoordinator.extractMentions("@老王 先说，@沈总 补充", roster)
        assertFalse(explicitOrder.mentionsAll)
        assertEquals(listOf("M_ARCH", "M_VC"), explicitOrder.members.map { it.id })

        // MentionOnly without mentions yields empty plan
        val silentPlan = GroupDiscussionCoordinator.selectInitialPlan(
            userText = "随便聊聊",
            activeMembers = roster,
            speakingMode = GroupSpeakingMode.MENTION_ONLY,
            maxRelayTurns = 3,
            priorMessages = emptyList()
        )
        assertTrue(silentPlan.isEmpty())

        // RoundRobin starts after last assistant speaker
        val prior = listOf(sampleMessage("A1", MessageRole.ASSISTANT, "Earlier", member = memberPM, sortIndex = 1))
        val rrPlan = GroupDiscussionCoordinator.selectInitialPlan(
            userText = "下一轮",
            activeMembers = roster,
            speakingMode = GroupSpeakingMode.ROUND_ROBIN,
            maxRelayTurns = 3,
            priorMessages = prior
        )
        assertEquals(listOf("M_ARCH", "M_VC", "M_PM"), rrPlan.map { it.member.id })
        assertEquals(GroupSpeechIntent.MEDIATE, rrPlan.last().intent)

        // SmartRelay ranks by role keyword relevance
        val smartPlan = GroupDiscussionCoordinator.selectInitialPlan(
            userText = "聊聊这个架构的并发性能瓶颈和安全边界",
            activeMembers = roster,
            speakingMode = GroupSpeakingMode.SMART_RELAY,
            maxRelayTurns = 3,
            priorMessages = emptyList()
        )
        assertEquals("M_ARCH", smartPlan.first().member.id)
    }

    @Test
    fun wholeMentionsAndPickedRecipientsSurviveAnEditWithoutExpandingTheRoster() {
        val first = memberPM.copy(name = "Alex")
        val second = memberArch.copy(name = "Alex")
        val third = memberVC.copy(name = "Alexandra")
        val roster = listOf(first, second, third)
        val plain = GroupDiscussionCoordinator.extractMentions("@Alex What do you think?", roster)
        assertTrue(plain.members.isEmpty())
        assertEquals(listOf(third), GroupDiscussionCoordinator.extractMentions("@Alexandra, thoughts?", roster).members)
        assertTrue(GroupDiscussionCoordinator.extractMentions("@everyoneElse and editor@example.com", roster).members.isEmpty())
        assertTrue(GroupDiscussionCoordinator.extractMentions("@everyone, thoughts?", roster).mentionsAll)

        val original = "@Alex Any recommendations?"
        val edited = "📚 $original Please include a short list."
        val originalPicks = listOf(PickedGroupMention(0, "@Alex", second.id))
        val picks = PickedGroupMention.updating(originalPicks, original, edited)
        val selected = GroupDiscussionCoordinator.extractMentions(edited, roster, picks)
        val planned = GroupDiscussionCoordinator.selectInitialPlan(
            edited, roster, GroupSpeakingMode.MENTION_ONLY, 4, emptyList(), resolvedMentions = selected
        )
        assertEquals(listOf(second.id), planned.map { it.member.id })
        val reservedPick = PickedGroupMention(0, "@all", first.id)
        val mutedPick = GroupDiscussionCoordinator.extractMentions("@all Hello", listOf(second), listOf(reservedPick))
        assertFalse(mutedPick.mentionsAll)
        assertTrue(mutedPick.members.isEmpty())
    }

    @Test
    fun groupHistoryHonorsDividerAndExcludedMessages() {
        val old = sampleMessage("OLD", MessageRole.USER, "Prior topic", sortIndex = 1)
        val divider = sampleMessage("DIV", MessageRole.SYSTEM, "", sortIndex = 2)
            .copy(assistanceMetadata = MessageAssistanceMetadata(isContextDivider = true))
        val hidden = sampleMessage("EXCLUDED", MessageRole.ASSISTANT, "Local note", memberPM, 3)
            .copy(assistanceMetadata = MessageAssistanceMetadata(isExcludedFromContext = true))
        val visible = sampleMessage("VISIBLE", MessageRole.USER, "Current topic", sortIndex = 4)
        val history = GroupDiscussionCoordinator.buildPromptHistory(listOf(old, divider, hidden, visible), memberPM, 1)
        assertEquals(1, history.size)
        assertTrue(history.single().content.contains("Current topic"))
        assertFalse(history.single().content.contains("Prior topic"))
        assertFalse(history.single().content.contains("Local note"))
    }

    @Test
    fun perspectiveFlippedHistoryMergesConsecutiveOtherSpeakersAndPreservesSelfAsAssistant() {
        val personaWithMat = memberPM.copy(
            profileID = "PROF_PM",
            persona = GroupPersona(
                materials = listOf(
                    PersonaMaterial(title = "增长笔记", text = "高频刚需痛点与裂变留存才是冷启动核心。")
                )
            )
        )
        val u1 = sampleMessage("U1", MessageRole.USER, "怎么冷启动？", sortIndex = 1)
        val pmReply = sampleMessage("A1", MessageRole.ASSISTANT, "先抓高频痛点。", member = personaWithMat, sortIndex = 2)
        val archReply = sampleMessage("A2", MessageRole.ASSISTANT, "服务端先别过度设计。", member = memberArch, sortIndex = 3)
        val u2 = sampleMessage("U2", MessageRole.USER, "那留存怎么测？", sortIndex = 4)

        val history = GroupDiscussionCoordinator.buildPromptHistory(
            messages = listOf(u1, pmReply, archReply, u2),
            speaker = personaWithMat,
            limit = 20
        )

        // U1 (user) -> PM (assistant) -> [Arch (user) + U2 (user) merged into single user turn with material reference]
        assertEquals(3, history.size)
        assertEquals(MessageRole.USER, history[0].role)
        assertEquals("[群主]: 怎么冷启动？", history[0].content)
        assertEquals(MessageRole.ASSISTANT, history[1].role)
        assertEquals("先抓高频痛点。", history[1].content)
        assertEquals(MessageRole.USER, history[2].role)
        assertTrue(history[2].content.contains("[毒舌架构师·老王]: 服务端先别过度设计。"))
        assertTrue(history[2].content.contains("[群主]: 那留存怎么测？"))
        assertTrue(history[2].content.contains("参考资料"))
    }

    @Test
    fun selectNextRelaySpeakerRespectsPriorityAndStopsOnHost() {
        val roster = listOf(memberPM, memberArch, memberVC)

        // Inline @mention takes priority over directive `next`
        val inlineNext = GroupDiscussionCoordinator.selectNextRelaySpeaker(
            after = memberPM,
            visibleReply = "@沈总 从投资视角怎么看？",
            directive = GroupTurnDirective(nextTargetRaw = "@老王"),
            activeMembers = roster,
            spokenMemberIDs = setOf(memberPM.id),
            turnsCompleted = 1,
            maxRelayTurns = 3,
            speakingMode = GroupSpeakingMode.SMART_RELAY
        )
        assertEquals("M_VC", inlineNext?.first?.id)

        // Stops immediately when asksHost = true
        val stopOnHost = GroupDiscussionCoordinator.selectNextRelaySpeaker(
            after = memberPM,
            visibleReply = "这里需要拍板",
            directive = GroupTurnDirective(asksHost = true, nextTargetRaw = "HOST"),
            activeMembers = roster,
            spokenMemberIDs = setOf(memberPM.id),
            turnsCompleted = 1,
            maxRelayTurns = 3,
            speakingMode = GroupSpeakingMode.SMART_RELAY
        )
        assertNull(stopOnHost)
    }

    @Test
    fun splitShortBubblesSplitsTwoShortParagraphsAndSkipsCodeOrHeadings() {
        val shortTwo = "先给结论：这个方案可以直接上。\n\n具体落地只需改三行配置即可验证。"
        val split = GroupDiscussionCoordinator.splitShortBubbles(
            text = shortTwo,
            style = GroupSpeechStyle.NATURAL_SHORT,
            enabled = true,
            intent = GroupSpeechIntent.OPEN_PERSPECTIVE
        )
        assertEquals(2, split.size)

        val withCode = "看这段代码：\n\n```kotlin\nprintln(1)\n```"
        assertEquals(
            1,
            GroupDiscussionCoordinator.splitShortBubbles(
                withCode,
                GroupSpeechStyle.NATURAL_SHORT,
                enabled = true,
                intent = GroupSpeechIntent.OPEN_PERSPECTIVE
            ).size
        )

        // Summarize never splits
        assertEquals(
            1,
            GroupDiscussionCoordinator.splitShortBubbles(
                shortTwo,
                GroupSpeechStyle.NATURAL_SHORT,
                enabled = true,
                intent = GroupSpeechIntent.SUMMARIZE
            ).size
        )
    }

    @Test
    fun groupSettingsAndMetadataRoundTripPreserveUnknownFields() {
        val codec = BackupJson.codec
        val existingConv = codec.parseToJsonElement(
            """{"backupState":{"legacyImportID":"XYZ"},"privatePersona":{"id":"OLD","name":"Old","target":{"providerID":"P1","providerName":"OpenAI","protocolRaw":"openAICompatible","modelID":"m","modelDisplayName":"M","accentHex":"#3F6EF6","supportsVision":false,"supportsReasoning":false}}}"""
        ).jsonObject

        val convSettings = ConversationAssistanceSettings(
            isGroupMode = true,
            groupMembers = listOf(memberPM, memberArch),
            groupSpeakingMode = GroupSpeakingMode.ROUND_ROBIN,
            groupSpeechStyle = GroupSpeechStyle.DEEP_DEBATE,
            groupMaxRelayTurns = 5,
            privatePersona = null
        )
        val mergedConv = convSettings.mergeInto(existingConv, codec)
        assertEquals("true", mergedConv["isGroupMode"]?.jsonPrimitive?.content)
        assertEquals("roundRobin", mergedConv["groupSpeakingMode"]?.jsonPrimitive?.content)
        assertEquals(2, mergedConv["groupMembers"]?.jsonArray?.size)
        assertTrue(mergedConv.containsKey("backupState"))
        // Cleared nullable field removed
        assertNull(mergedConv["privatePersona"])

        val existingMeta = codec.parseToJsonElement(
            """{"toolCalls":[{"id":"t1","name":"search"}]}"""
        ).jsonObject
        val msgMeta = MessageAssistanceMetadata(
            groupMemberID = memberPM.id,
            groupMemberName = memberPM.name,
            groupMemberTitle = memberPM.title,
            groupMemberEmoji = memberPM.avatarEmoji,
            groupSpeechIntent = GroupSpeechIntent.REBUTTAL,
            groupReactions = listOf(GroupReaction(memberArch.id, memberArch.name, memberArch.avatarEmoji, "👍")),
            groupAskedHost = true
        )
        val mergedMeta = msgMeta.mergeInto(existingMeta, codec)
        assertEquals("rebuttal", mergedMeta["groupSpeechIntent"]?.jsonPrimitive?.content)
        assertEquals("true", mergedMeta["groupAskedHost"]?.jsonPrimitive?.content)
        assertTrue(mergedMeta.containsKey("toolCalls"))
    }
}
