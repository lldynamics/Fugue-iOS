package com.iosbox.app.core.storage

/**
 * Non-destructive conversation branching tree, matching iOS `ConversationTree.swift`.
 * Existing linear chats without parent links remain completely untouched until the first
 * branch/edit/retry is created.
 */
object ConversationTree {
    const val VIRTUAL_ROOT_ID = "00000000-0000-0000-0000-000000000000"

    private fun norm(id: String?): String? =
        id?.trim()?.uppercase()?.takeIf { it.isNotEmpty() }

    private fun sortMessages(messages: List<ChatMessageItem>): List<ChatMessageItem> =
        messages.sortedWith(compareBy<ChatMessageItem> { it.sortIndex }.thenBy { it.createdAtEpochMs })

    fun usesTree(activeLeafMessageID: String?, messages: List<ChatMessageItem>): Boolean =
        norm(activeLeafMessageID) != null || messages.any { norm(it.parentMessageID) != null }

    /**
     * Fills implicit parent links along a sorted linear history, returning updated messages
     * alongside the inferred leaf message ID.
     */
    fun linkHistory(
        sorted: List<ChatMessageItem>,
        preserving: Set<String> = emptySet()
    ): Pair<List<ChatMessageItem>, String?> {
        val ordered = sortMessages(sorted)
        if (ordered.isEmpty()) return emptyList<ChatMessageItem>() to null

        val result = ordered.toMutableList()
        val preservedNorm = preserving.mapNotNull(::norm).toSet()
        var currentParentID = VIRTUAL_ROOT_ID
        val visitedGroups = HashSet<String>()
        var index = 0

        while (index < result.size) {
            val msg = result[index]
            val gid = norm(msg.comparisonGroupID)
            if (gid != null) {
                if (!visitedGroups.add(gid)) {
                    index++
                    continue
                }
                val groupIndices = result.indices.filter { norm(result[it].comparisonGroupID) == gid }
                val groupParent = norm(msg.parentMessageID) ?: currentParentID
                for (i in groupIndices) {
                    val member = result[i]
                    val memberId = norm(member.id)
                    if (norm(member.parentMessageID) == null && (memberId == null || !preservedNorm.contains(memberId))) {
                        result[i] = member.copy(parentMessageID = groupParent)
                    }
                }
                val groupMembers = groupIndices.map { result[it] }
                val winner = groupMembers.firstOrNull { it.isSelectedInGroup && it.content.isNotEmpty() }
                    ?: groupMembers.firstOrNull { it.isSelectedInGroup }
                    ?: groupMembers.firstOrNull()
                currentParentID = norm(winner?.id) ?: currentParentID
                index++
            } else {
                val msgId = norm(msg.id)
                if (norm(msg.parentMessageID) == null && (msgId == null || !preservedNorm.contains(msgId))) {
                    result[index] = msg.copy(parentMessageID = currentParentID)
                }
                currentParentID = msgId ?: currentParentID
                index++
            }
        }

        val leafID = if (currentParentID == VIRTUAL_ROOT_ID) norm(result.lastOrNull()?.id) else currentParentID
        return result to leafID
    }

    /**
     * Returns ordered messages along the active branch ending at [endingAt] / [activeLeafMessageID],
     * including all cards of any Arena comparison group encountered on the path.
     */
    fun activeMessages(
        activeLeafMessageID: String?,
        allMessages: List<ChatMessageItem>,
        endingAt: String? = null
    ): List<ChatMessageItem> {
        val sorted = sortMessages(allMessages)
        if (sorted.isEmpty()) return emptyList()
        if (!usesTree(activeLeafMessageID, sorted)) {
            val groups = LinkedHashMap<String, MutableList<ChatMessageItem>>()
            for (m in sorted) {
                val gid = norm(m.comparisonGroupID) ?: continue
                groups.getOrPut(gid) { mutableListOf() }.add(m)
            }
            if (groups.isEmpty()) return sorted
            val pending = LinkedHashMap(groups)
            return sorted.flatMap { message ->
                val gid = norm(message.comparisonGroupID) ?: return@flatMap listOf(message)
                pending.remove(gid) ?: emptyList()
            }
        }

        val byID = LinkedHashMap<String, ChatMessageItem>(sorted.size)
        for (m in sorted) {
            norm(m.id)?.let { byID[it] = m }
        }
        val targetLeafID = norm(endingAt) ?: norm(activeLeafMessageID)
        val leaf = targetLeafID?.let { byID[it] } ?: sorted.lastOrNull() ?: return sorted

        val pathReversed = mutableListOf<ChatMessageItem>()
        val visited = HashSet<String>()
        var cursor: ChatMessageItem? = leaf
        while (cursor != null) {
            val cid = norm(cursor.id) ?: break
            if (!visited.add(cid)) break
            pathReversed.add(cursor)
            val pid = norm(cursor.parentMessageID)
            if (pid == null || pid == VIRTUAL_ROOT_ID) break
            cursor = byID[pid]
        }

        val path = pathReversed.asReversed()
        val result = mutableListOf<ChatMessageItem>()
        val emittedGroups = HashSet<String>()
        val emittedIDs = HashSet<String>()

        for (node in path) {
            val gid = norm(node.comparisonGroupID)
            if (gid != null) {
                if (!emittedGroups.add(gid)) continue
                val nodeParent = norm(node.parentMessageID)
                val groupMembers = sorted.filter {
                    norm(it.comparisonGroupID) == gid && norm(it.parentMessageID) == nodeParent
                }
                for (member in groupMembers) {
                    val mid = norm(member.id) ?: continue
                    if (emittedIDs.add(mid)) {
                        result.add(member)
                    }
                }
            } else {
                val nid = norm(node.id) ?: continue
                if (emittedIDs.add(nid)) {
                    result.add(node)
                }
            }
        }
        return result
    }

    fun currentAnchorID(
        activeLeafMessageID: String?,
        allMessages: List<ChatMessageItem>
    ): String {
        val active = activeMessages(activeLeafMessageID, allMessages)
        val last = active.lastOrNull() ?: return VIRTUAL_ROOT_ID
        val gid = norm(last.comparisonGroupID)
        if (gid != null) {
            val group = active.filter { norm(it.comparisonGroupID) == gid }
            val winner = group.firstOrNull { it.isSelectedInGroup } ?: group.firstOrNull()
            return norm(winner?.id) ?: VIRTUAL_ROOT_ID
        }
        return norm(last.id) ?: VIRTUAL_ROOT_ID
    }

    fun branchSiblingsMap(
        activeLeafMessageID: String?,
        allMessages: List<ChatMessageItem>
    ): Map<String, List<ChatMessageItem>> {
        if (!usesTree(activeLeafMessageID, allMessages)) return emptyMap()
        val sorted = sortMessages(allMessages)
        val grouped = LinkedHashMap<Pair<String, String>, MutableList<ChatMessageItem>>()
        for (candidate in sorted) {
            if (norm(candidate.comparisonGroupID) != null) continue
            val key = (norm(candidate.parentMessageID) ?: VIRTUAL_ROOT_ID) to candidate.role.rawValue
            grouped.getOrPut(key) { mutableListOf() }.add(candidate)
        }
        val map = LinkedHashMap<String, List<ChatMessageItem>>()
        for (siblings in grouped.values) {
            if (siblings.size > 1) {
                for (msg in siblings) {
                    map[msg.id] = siblings
                }
            }
        }
        return map
    }

    fun resolveBranchLeaf(
        targetMessage: ChatMessageItem,
        allMessages: List<ChatMessageItem>
    ): String {
        val sorted = sortMessages(allMessages)
        val childrenByParent = LinkedHashMap<String, MutableList<ChatMessageItem>>()
        for (msg in sorted) {
            val parent = norm(msg.parentMessageID) ?: VIRTUAL_ROOT_ID
            childrenByParent.getOrPut(parent) { mutableListOf() }.add(msg)
        }

        var current = targetMessage
        val visited = HashSet<String>()
        norm(current.id)?.let { visited.add(it) }

        while (true) {
            val currentID = norm(current.id) ?: break
            val children = childrenByParent[currentID]
            if (children.isNullOrEmpty()) break
            val latestChild = children.last()
            val gid = norm(latestChild.comparisonGroupID)
            val next = if (gid != null) {
                val peers = children.filter { norm(it.comparisonGroupID) == gid }
                peers.firstOrNull { it.isSelectedInGroup } ?: latestChild
            } else {
                latestChild
            }
            val nextID = norm(next.id) ?: break
            if (!visited.add(nextID)) break
            current = next
        }
        return norm(current.id) ?: targetMessage.id.uppercase()
    }

    fun descendantSubtree(
        root: ChatMessageItem,
        activeLeafMessageID: String?,
        allMessages: List<ChatMessageItem>
    ): List<ChatMessageItem> {
        val sorted = sortMessages(allMessages)
        if (!usesTree(activeLeafMessageID, sorted)) {
            val rootID = norm(root.id)
            val idx = sorted.indexOfFirst { norm(it.id) == rootID }
            return if (idx >= 0) sorted.subList(idx, sorted.size) else emptyList()
        }

        val childrenByParent = LinkedHashMap<String, MutableList<ChatMessageItem>>()
        for (msg in sorted) {
            val parent = norm(msg.parentMessageID) ?: VIRTUAL_ROOT_ID
            childrenByParent.getOrPut(parent) { mutableListOf() }.add(msg)
        }

        val seeds = mutableListOf(root)
        val rootGid = norm(root.comparisonGroupID)
        if (rootGid != null) {
            val rootParent = norm(root.parentMessageID)
            val rootID = norm(root.id)
            seeds.addAll(
                sorted.filter {
                    norm(it.comparisonGroupID) == rootGid &&
                        norm(it.parentMessageID) == rootParent &&
                        norm(it.id) != rootID
                }
            )
        }

        val collected = mutableListOf<ChatMessageItem>()
        val visited = HashSet<String>()
        val queue = ArrayDeque(seeds)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            val nid = norm(node.id) ?: continue
            if (!visited.add(nid)) continue
            collected.add(node)
            childrenByParent[nid]?.let { queue.addAll(it) }
        }
        return collected
    }
}
