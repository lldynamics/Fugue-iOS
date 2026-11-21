package com.iosbox.app.core.model

import com.iosbox.app.core.storage.ChatMessageItem
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * Snapshot of candidates and chosen winner captured at Blind Arena voting time.
 * Matches iOS `ArenaBallot` in `ArenaBallot.swift`.
 */
@Serializable
data class ArenaBallot(
    val winnerID: String,
    val candidates: List<Candidate> = emptyList()
) {
    @Serializable
    data class Candidate(
        val messageID: String,
        val providerID: String? = null,
        val providerName: String = "",
        val modelID: String = "",
        val modelName: String = ""
    )

    data class Standing(
        val providerKey: String,
        val modelID: String,
        val providerName: String,
        val modelName: String,
        val wins: Int,
        val rounds: Int
    ) {
        val winRate: Double
            get() = if (rounds > 0) wins.toDouble() / rounds.toDouble() else 0.0
    }

    companion object {
        fun standings(messages: List<ChatMessageItem>): List<Standing> {
            val rows = LinkedHashMap<Pair<String, String>, Standing>()
            for (message in messages) {
                if (message.comparisonGroupID == null || message.isSynthesis) continue
                val ballot = message.assistanceMetadata.blindArenaBallot ?: continue
                if (!ballot.winnerID.equals(message.id, ignoreCase = true)) continue

                for (candidate in ballot.candidates) {
                    if (candidate.modelID.isEmpty()) continue
                    val providerKey = candidate.providerID?.uppercase() ?: candidate.providerName
                    val key = providerKey to candidate.modelID
                    val existing = rows[key] ?: Standing(
                        providerKey = providerKey,
                        modelID = candidate.modelID,
                        providerName = candidate.providerName,
                        modelName = candidate.modelName,
                        wins = 0,
                        rounds = 0
                    )
                    val won = candidate.messageID.equals(ballot.winnerID, ignoreCase = true)
                    rows[key] = existing.copy(
                        rounds = existing.rounds + 1,
                        wins = existing.wins + if (won) 1 else 0
                    )
                }
            }
            return rows.values.sortedWith(
                compareByDescending<Standing> { it.winRate }
                    .thenByDescending { it.wins }
                    .thenBy { it.providerKey }
                    .thenBy { it.modelID }
            )
        }
    }
}

/**
 * Subset of iOS `AssistanceSettings` directly managed in Android.
 * Unknown iOS keys in the underlying JSON blob are preserved via [mergeInto].
 */
@Serializable
data class ConversationAssistanceSettings(
    val usePersonalMemory: Boolean = false,
    val enablePromptCaching: Boolean = true,
    val blindArenaMode: Boolean = false,
    val enableAgentTools: Boolean = false,
    val enableNativeGrounding: Boolean = false,
    val knowledgeVolumeIDs: List<String> = emptyList(),
    val isGroupMode: Boolean = false,
    val groupMembers: List<GroupMember> = emptyList(),
    val groupSpeakingMode: GroupSpeakingMode = GroupSpeakingMode.SMART_RELAY,
    val groupSpeechStyle: GroupSpeechStyle = GroupSpeechStyle.NATURAL_SHORT,
    val groupMaxRelayTurns: Int = 3,
    val groupSplitShortBubbles: Boolean = true,
    val privatePersona: GroupMember? = null
) {
    val isDefault: Boolean
        get() = this == ConversationAssistanceSettings()

    fun mergeInto(existing: JsonObject?, json: Json): JsonObject {
        val merged = existing?.toMutableMap() ?: LinkedHashMap()
        val encoded = json.encodeToJsonElement(serializer(), this).jsonObject
        for ((k, v) in encoded) {
            merged[k] = v
        }
        if (privatePersona == null) {
            merged.remove("privatePersona")
        }
        return JsonObject(merged)
    }
}

/**
 * Subset of iOS `AssistanceMetadata` directly managed in Android.
 * Unknown iOS keys in the underlying JSON blob are preserved via [mergeInto].
 */
@Serializable
data class MessageAssistanceMetadata(
    val isBookmarked: Boolean = false,
    val omittedMemory: Boolean = false,
    val omittedKnowledge: Boolean = false,
    val blindArenaRevealed: Boolean = false,
    val blindArenaBallot: ArenaBallot? = null,
    val groupMemberID: String? = null,
    val groupMemberName: String? = null,
    val groupMemberTitle: String? = null,
    val groupMemberEmoji: String? = null,
    val isPersonaSimulation: Boolean = false,
    val personaExcerpts: List<PersonaExcerpt>? = null,
    val groupSpeechIntent: GroupSpeechIntent? = null,
    val groupReplyToMessageID: String? = null,
    val groupReplyToSpeaker: String? = null,
    val groupReplyToExcerpt: String? = null,
    val groupReactions: List<GroupReaction> = emptyList(),
    val groupAskedHost: Boolean = false
) {
    val isDefault: Boolean
        get() = this == MessageAssistanceMetadata()

    val groupSpeakerDisplayTitle: String?
        get() {
            val cleanTitle = groupMemberTitle?.trim().orEmpty()
            val cleanName = groupMemberName?.trim().orEmpty()
            return when {
                cleanTitle.isNotEmpty() && cleanName.isNotEmpty() -> "$cleanTitle·$cleanName"
                cleanName.isNotEmpty() -> cleanName
                cleanTitle.isNotEmpty() -> cleanTitle
                else -> null
            }
        }

    fun mergeInto(existing: JsonObject?, json: Json): JsonObject {
        val merged = existing?.toMutableMap() ?: LinkedHashMap()
        val encoded = json.encodeToJsonElement(serializer(), this).jsonObject
        for ((k, v) in encoded) {
            merged[k] = v
        }
        if (blindArenaBallot == null) merged.remove("blindArenaBallot")
        if (groupMemberID == null) merged.remove("groupMemberID")
        if (groupMemberName == null) merged.remove("groupMemberName")
        if (groupMemberTitle == null) merged.remove("groupMemberTitle")
        if (groupMemberEmoji == null) merged.remove("groupMemberEmoji")
        if (personaExcerpts == null) merged.remove("personaExcerpts")
        if (groupSpeechIntent == null) merged.remove("groupSpeechIntent")
        if (groupReplyToMessageID == null) merged.remove("groupReplyToMessageID")
        if (groupReplyToSpeaker == null) merged.remove("groupReplyToSpeaker")
        if (groupReplyToExcerpt == null) merged.remove("groupReplyToExcerpt")
        return JsonObject(merged)
    }
}
