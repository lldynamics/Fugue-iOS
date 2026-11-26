import Foundation

struct DraftRevision {
    struct Change: Identifiable {
        let id: Int
        let before: [String]
        let after: [String]
        var changed: Bool { before != after }
    }
    let changes: [Change]
    init(original: String, revision: String) {
        let before = original.components(separatedBy: "\n")
        let after = revision.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>(), added = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let i, _, _): removed.insert(i)
            case .insert(let j, _, _): added.insert(j)
            }
        }
        var parts: [Change] = [], i = 0, j = 0
        while i < before.count || j < after.count {
            let start = i, next = j
            if removed.contains(i) || added.contains(j) {
                while removed.contains(i) { i += 1 }
                while added.contains(j) { j += 1 }
            } else {
                while i < before.count && j < after.count && !removed.contains(i) && !added.contains(j) { i += 1; j += 1 }
            }
            parts.append(Change(id: parts.count, before: Array(before[start..<i]), after: Array(after[next..<j])))
        }
        changes = parts
    }
    func text(accepting ids: Set<Int>) -> String {
        changes.flatMap { ids.contains($0.id) ? $0.after : $0.before }.joined(separator: "\n")
    }
}
