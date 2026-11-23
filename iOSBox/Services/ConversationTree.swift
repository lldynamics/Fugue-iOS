import Foundation

enum ConversationTree {
    /// Sentinel parent ID representing the root of a branched conversation.
    static let virtualRootID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static func usesTree(_ conversation: Conversation) -> Bool {
        conversation.activeLeafMessageID != nil || conversation.messages.contains { $0.parentMessageID != nil }
    }

    /// Ensures every message in the conversation has an explicit `parentMessageID` before creating
    /// a branch, so existing linear/Arena messages remain intact on their original branch.
    static func ensureExplicitParentLinks(in conversation: Conversation) {
        let leaf = linkHistory(conversation.sortedMessages)
        if conversation.activeLeafMessageID == nil { conversation.activeLeafMessageID = leaf }
    }

    /// Fill implicit links on a linear history, respecting existing links and local edits.
    static func linkHistory(_ sorted: [ChatMessage], preserving existing: Set<UUID> = []) -> UUID? {
        guard !sorted.isEmpty else { return nil }

        var currentParentID = virtualRootID
        var visitedGroups = Set<UUID>()
        let groups = Dictionary(grouping: sorted.filter { $0.comparisonGroupID != nil }, by: \.comparisonGroupID)
        var index = 0

        while index < sorted.count {
            let msg = sorted[index]
            if let gid = msg.comparisonGroupID {
                guard !visitedGroups.contains(gid) else {
                    index += 1
                    continue
                }
                visitedGroups.insert(gid)
                let group = groups[gid] ?? []
                let groupParent = msg.parentMessageID ?? currentParentID
                for member in group where member.parentMessageID == nil && !existing.contains(member.id) {
                    member.parentMessageID = groupParent
                }
                let winner = group.first(where: { $0.isSelectedInGroup && !$0.content.isEmpty })
                    ?? group.first(where: \.isSelectedInGroup)
                    ?? group.first
                currentParentID = winner?.id ?? currentParentID
                index += 1
            } else {
                if msg.parentMessageID == nil && !existing.contains(msg.id) {
                    msg.parentMessageID = currentParentID
                }
                currentParentID = msg.id
                index += 1
            }
        }

        return currentParentID == virtualRootID ? sorted.last?.id : currentParentID
    }

    /// Returns the ordered messages along the currently active branch, including all cards of any
    /// Arena comparison group encountered on the path.
    static func activeMessages(in conversation: Conversation, endingAt leafID: UUID? = nil) -> [ChatMessage] {
        let sorted = conversation.sortedMessages
        guard !sorted.isEmpty else { return [] }
        guard usesTree(conversation) else {
            // A judge can summarize an older round after newer turns have been written.
            // Keep its real timestamp while displaying the comparison as one turn.
            let groups = Dictionary(grouping: sorted.filter { $0.comparisonGroupID != nil }, by: \.comparisonGroupID)
            guard !groups.isEmpty else { return sorted }
            var pending = groups
            return sorted.flatMap { message -> [ChatMessage] in
                guard let id = message.comparisonGroupID else { return [message] }
                return pending.removeValue(forKey: id) ?? []
            }
        }

        struct ComparisonBranch: Hashable {
            let groupID: UUID
            let parentID: UUID?
        }
        var comparisons: [ComparisonBranch: [ChatMessage]] = [:]
        for message in sorted {
            if let gid = message.comparisonGroupID {
                comparisons[.init(groupID: gid, parentID: message.parentMessageID), default: []].append(message)
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        let leaf: ChatMessage
        if let leafID = leafID ?? conversation.activeLeafMessageID, let found = byID[leafID] {
            leaf = found
        } else if let fallback = sorted.last {
            leaf = fallback
        } else {
            return sorted
        }

        var pathReversed: [ChatMessage] = []
        var visited = Set<UUID>()
        var cursor: ChatMessage? = leaf
        while let node = cursor, visited.insert(node.id).inserted {
            pathReversed.append(node)
            guard let pid = node.parentMessageID, pid != virtualRootID else { break }
            cursor = byID[pid]
        }

        let path = Array(pathReversed.reversed())
        var result: [ChatMessage] = []
        var emittedGroups = Set<UUID>()
        var emittedIDs = Set<UUID>()

        for node in path {
            if let gid = node.comparisonGroupID {
                guard emittedGroups.insert(gid).inserted else { continue }
                let groupMembers = comparisons[.init(groupID: gid, parentID: node.parentMessageID)] ?? []
                for member in groupMembers where emittedIDs.insert(member.id).inserted {
                    result.append(member)
                }
            } else if emittedIDs.insert(node.id).inserted {
                result.append(node)
            }
        }
        return result
    }

    /// Anchor message ID to attach the next appended message to when tree links are active.
    static func currentAnchorID(in conversation: Conversation) -> UUID? {
        let active = activeMessages(in: conversation)
        guard let last = active.last else { return virtualRootID }
        if let gid = last.comparisonGroupID {
            let group = active.filter { $0.comparisonGroupID == gid }
            return (group.first(where: \.isSelectedInGroup) ?? group.first)?.id
        }
        return last.id
    }

    /// Sibling branches at the same turn level (e.g., multiple edited versions of a user message).
    static func branchSiblings(of message: ChatMessage, in conversation: Conversation) -> [ChatMessage] {
        guard usesTree(conversation) else { return [message] }
        let targetParent = message.parentMessageID ?? virtualRootID
        return conversation.sortedMessages.filter { candidate in
            candidate.role == message.role
                && (candidate.parentMessageID ?? virtualRootID) == targetParent
                && candidate.comparisonGroupID == nil
        }
    }

    /// Precomputes sibling lists for all non-comparison messages in a single O(M log M) pass
    /// so SwiftUI message rows don't re-sort the full history per row on every streaming tick.
    static func branchSiblingsMap(in conversation: Conversation) -> [UUID: [ChatMessage]] {
        guard usesTree(conversation) else { return [:] }
        struct GroupKey: Hashable {
            let parentID: UUID
            let roleRaw: String
        }
        var grouped: [GroupKey: [ChatMessage]] = [:]
        for candidate in conversation.sortedMessages where candidate.comparisonGroupID == nil {
            let key = GroupKey(parentID: candidate.parentMessageID ?? virtualRootID, roleRaw: candidate.roleRaw)
            grouped[key, default: []].append(candidate)
        }
        var map: [UUID: [ChatMessage]] = [:]
        for siblings in grouped.values where siblings.count > 1 {
            for msg in siblings {
                map[msg.id] = siblings
            }
        }
        return map
    }

    /// Switches the active branch to show `targetMessage` and its latest descendant chain.
    static func switchBranch(to targetMessage: ChatMessage, in conversation: Conversation) {
        let sorted = conversation.sortedMessages
        var childrenByParent: [UUID: [ChatMessage]] = [:]
        for msg in sorted {
            let parent = msg.parentMessageID ?? virtualRootID
            childrenByParent[parent, default: []].append(msg)
        }

        var current = targetMessage
        var visited: Set<UUID> = [current.id]
        while let children = childrenByParent[current.id], !children.isEmpty {
            let latestChild = children.last!
            let next: ChatMessage
            if let gid = latestChild.comparisonGroupID {
                let groupPeers = children.filter { $0.comparisonGroupID == gid }
                next = groupPeers.first(where: \.isSelectedInGroup) ?? latestChild
            } else {
                next = latestChild
            }
            guard visited.insert(next.id).inserted else { break }
            current = next
        }
        conversation.activeLeafMessageID = current.id
    }

    /// Collects `root` and all transitive descendants in the conversation tree without touching
    /// sibling branches rooted at the same parent.
    static func descendantSubtree(from root: ChatMessage, in conversation: Conversation) -> [ChatMessage] {
        let sorted = conversation.sortedMessages
        guard usesTree(conversation) else {
            guard let idx = sorted.firstIndex(where: { $0.id == root.id }) else { return [] }
            return Array(sorted[idx...])
        }

        var childrenByParent: [UUID: [ChatMessage]] = [:]
        for msg in sorted {
            let parent = msg.parentMessageID ?? virtualRootID
            childrenByParent[parent, default: []].append(msg)
        }

        var seeds: [ChatMessage] = [root]
        if let gid = root.comparisonGroupID {
            let peers = sorted.filter { $0.comparisonGroupID == gid && $0.parentMessageID == root.parentMessageID && $0.id != root.id }
            seeds.append(contentsOf: peers)
        }

        var collected: [ChatMessage] = []
        var visited = Set<UUID>()
        var queue = seeds
        while let node = queue.first {
            queue.removeFirst()
            guard visited.insert(node.id).inserted else { continue }
            collected.append(node)
            if let children = childrenByParent[node.id] {
                queue.append(contentsOf: children)
            }
        }
        return collected
    }

    /// Cleans up tree parent pointers before deleting a single message.
    static func detachBeforeDeleting(_ message: ChatMessage, in conversation: Conversation) {
        guard usesTree(conversation) else { return }
        let sorted = conversation.sortedMessages
        let replacementParent = message.parentMessageID ?? virtualRootID

        // If deleting a member of an Arena group that still has other members, only re-parent
        // children onto the surviving winner.
        if let gid = message.comparisonGroupID {
            let survivors = sorted.filter { $0.comparisonGroupID == gid && $0.id != message.id }
            if let nextAnchor = survivors.first(where: \.isSelectedInGroup) ?? survivors.first {
                if !nextAnchor.isSelectedInGroup && !nextAnchor.isSynthesis {
                    nextAnchor.isSelectedInGroup = true
                }
                for child in sorted where child.parentMessageID == message.id {
                    child.parentMessageID = nextAnchor.id
                }
                if conversation.activeLeafMessageID == message.id {
                    conversation.activeLeafMessageID = nextAnchor.id
                }
                return
            }
        }

        for child in sorted where child.parentMessageID == message.id {
            child.parentMessageID = replacementParent
        }
        if conversation.activeLeafMessageID == message.id {
            if replacementParent != virtualRootID {
                conversation.activeLeafMessageID = replacementParent
            } else {
                conversation.activeLeafMessageID = sorted.last(where: { $0.id != message.id })?.id
            }
        }
    }
}
