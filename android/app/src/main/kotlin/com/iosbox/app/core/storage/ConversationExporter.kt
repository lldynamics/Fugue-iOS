package com.iosbox.app.core.storage

import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.MessageRole
import com.iosbox.app.core.network.ArenaSynthesis
import java.text.DateFormat
import java.util.Date

object ConversationExporter {
    fun makeMarkdown(
        conversation: ConversationItem,
        messages: List<ChatMessageItem>
    ): String {
        val dateText = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
            .format(Date(conversation.updatedAtEpochMs))
        val blindMode = conversation.assistanceSettings.blindArenaMode
        val lines = mutableListOf<String>()

        lines.add("# ${conversation.title}")
        lines.add("")
        lines.add("- " + L10n.text("更新时间：$dateText", "Updated: $dateText"))
        val primary = conversation.primaryTarget
        if (primary != null && !conversation.isArenaMode) {
            lines.add("- " + L10n.text("模型：${primary.providerName} · ${primary.modelDisplayName}", "Model: ${primary.providerName} · ${primary.modelDisplayName}"))
        }
        val sys = conversation.systemPrompt.trim()
        if (sys.isNotEmpty()) {
            lines.add("")
            lines.add("## " + L10n.text("系统提示词", "System Prompt"))
            lines.add("")
            lines.add("> ${sys.replace("\n", "\n> ")}")
        }
        lines.add("")
        lines.add("---")

        for (msg in messages) {
            val meta = msg.assistanceMetadata
            if (meta.isContextDivider) {
                lines.add("")
                lines.add("--- *${msg.content}* ---")
                continue
            }
            lines.add("")
            when (msg.role) {
                MessageRole.USER -> {
                    lines.add("### " + L10n.text("提问", "Prompt"))
                    val quote = meta.quotedExcerpt
                    if (!quote.isNullOrBlank()) {
                        lines.add("")
                        lines.add("> ${quote.replace("\n", "\n> ")}")
                    }
                    if (msg.attachments.isNotEmpty()) {
                        val names = msg.attachments.joinToString(", ") { it.fileName }
                        lines.add("")
                        lines.add("*" + L10n.text("附件：$names", "Attachments: $names") + "*")
                    }
                    if (msg.content.isNotEmpty()) {
                        lines.add("")
                        lines.add(msg.content)
                    }
                    if (meta.groupReactions.isNotEmpty()) {
                        val summary = meta.groupReactions.joinToString(" · ") { "${it.emoji} ${it.memberName}" }
                        lines.add("")
                        lines.add("*$summary*")
                    }
                }

                MessageRole.ASSISTANT -> {
                    val speaker = ArenaSynthesis.visibleSpeakerName(
                        message = msg,
                        allGroupCandidates = messages,
                        blindArenaMode = blindMode
                    )
                    val title = if (msg.isSynthesis || speaker != msg.modelDisplayName || msg.providerName.isEmpty()) {
                        speaker
                    } else {
                        "$speaker (${msg.providerName})"
                    }
                    val marker = if (msg.comparisonGroupID != null && msg.isSelectedInGroup) {
                        " [" + L10n.text("上下文主回复", "Selected Reply") + "]"
                    } else {
                        ""
                    }
                    lines.add("### $title$marker")

                    val replyExcerpt = meta.groupReplyToExcerpt
                    if (!replyExcerpt.isNullOrBlank()) {
                        val quoteLine = meta.groupReplyToSpeaker?.let {
                            L10n.text("回复 $it：$replyExcerpt", "Replying to $it: $replyExcerpt")
                        } ?: replyExcerpt
                        lines.add("")
                        lines.add("> $quoteLine")
                    }

                    if (msg.reasoningContent.isNotEmpty()) {
                        lines.add("")
                        lines.add("<details><summary>" + L10n.text("思考过程", "Reasoning") + "</summary>")
                        lines.add("")
                        lines.add(msg.reasoningContent)
                        lines.add("")
                        lines.add("</details>")
                    }

                    if (msg.content.isNotEmpty()) {
                        lines.add("")
                        lines.add(msg.content)
                    }

                    if (meta.groupReactions.isNotEmpty()) {
                        val summary = meta.groupReactions.joinToString(" · ") { "${it.emoji} ${it.memberName}" }
                        lines.add("")
                        lines.add("*$summary*")
                    }

                    val search = meta.search
                    if (search != null && search.sources.isNotEmpty()) {
                        lines.add("")
                        lines.add("**" + L10n.text("参考来源（${search.query}）", "Sources (${search.query})") + "**")
                        for (src in search.sources) {
                            lines.add("- [${src.title}](${src.url})")
                        }
                    }

                    val knowledge = meta.knowledgeEvidence
                    if (knowledge != null && knowledge.passages.isNotEmpty()) {
                        lines.add("")
                        lines.add("**" + L10n.text("知识库引用", "Knowledge Citations") + "**")
                        for (p in knowledge.passages) {
                            lines.add("- [${p.id}] ${p.citationLabel}")
                        }
                    }
                }

                MessageRole.SYSTEM, MessageRole.TOOL -> Unit
            }
        }

        return lines.joinToString("\n") + "\n"
    }

    fun sanitizedFileName(raw: String): String {
        val cleaned = raw.replace(Regex("[/\\\\:?%*|\"<>]"), "-")
            .replace(Regex("-+"), "-")
            .trim()
            .trim('.', '-')
            .trim()
            .take(48)
            .trim('.', '-', ' ')
        return if (cleaned.isEmpty()) "Fugue-Chat" else cleaned
    }
}
