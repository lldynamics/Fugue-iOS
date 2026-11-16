import Foundation

/// Incrementally separates inline `<think>...</think>` (or `<thinking>...</thinking>`) blocks
/// from regular assistant content across arbitrary SSE token boundaries.
struct ThinkTagStreamParser: Sendable {
    enum Segment: Equatable, Sendable {
        case reasoning(String)
        case content(String)
    }

    private var insideThink = false
    private var buffer = ""
    private var activeCloseTag = "</think>"
    private var hasSeenOpeningCheck = false

    private let openTags = ["<think>", "<thinking>"]

    mutating func feed(_ chunk: String) -> [Segment] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var outputs: [Segment] = []

        while !buffer.isEmpty {
            if insideThink {
                if let closeRange = buffer.range(of: activeCloseTag) {
                    let thoughtPart = String(buffer[..<closeRange.lowerBound])
                    if !thoughtPart.isEmpty {
                        outputs.append(.reasoning(thoughtPart))
                    }
                    buffer = String(buffer[closeRange.upperBound...])
                    if buffer.hasPrefix("\n\n") {
                        buffer.removeFirst(2)
                    } else if buffer.hasPrefix("\n") {
                        buffer.removeFirst(1)
                    }
                    insideThink = false
                } else if let partialIndex = trailingPartialMatchIndex(in: buffer, target: activeCloseTag) {
                    let safePart = String(buffer[..<partialIndex])
                    if !safePart.isEmpty {
                        outputs.append(.reasoning(safePart))
                    }
                    buffer = String(buffer[partialIndex...])
                    break
                } else {
                    outputs.append(.reasoning(buffer))
                    buffer = ""
                }
            } else {
                // Check if any open tag occurs in buffer
                var earliestMatch: (range: Range<String.Index>, closeTag: String)?
                for tag in openTags {
                    if let range = buffer.range(of: tag) {
                        let close = tag == "<thinking>" ? "</thinking>" : "</think>"
                        if earliestMatch == nil || range.lowerBound < earliestMatch!.range.lowerBound {
                            earliestMatch = (range, close)
                        }
                    }
                }

                if let match = earliestMatch {
                    let before = String(buffer[..<match.range.lowerBound])
                    if !before.isEmpty {
                        outputs.append(.content(before))
                    }
                    buffer = String(buffer[match.range.upperBound...])
                    if buffer.hasPrefix("\n") {
                        buffer.removeFirst(1)
                    }
                    insideThink = true
                    activeCloseTag = match.closeTag
                    hasSeenOpeningCheck = true
                } else if let partialIdx = earliestTrailingPartialOpenTag(in: buffer) {
                    let safeBefore = String(buffer[..<partialIdx])
                    if !safeBefore.isEmpty {
                        outputs.append(.content(safeBefore))
                    }
                    buffer = String(buffer[partialIdx...])
                    break
                } else {
                    hasSeenOpeningCheck = true
                    outputs.append(.content(buffer))
                    buffer = ""
                }
            }
        }

        return mergeAdjacent(outputs)
    }

    mutating func finish() -> [Segment] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer = "" }
        if insideThink {
            return [.reasoning(buffer)]
        } else {
            return [.content(buffer)]
        }
    }

    private func earliestTrailingPartialOpenTag(in text: String) -> String.Index? {
        var best: String.Index?
        for tag in openTags {
            if let idx = trailingPartialMatchIndex(in: text, target: tag) {
                if best == nil || idx < best! {
                    best = idx
                }
            }
        }
        return best
    }

    private func trailingPartialMatchIndex(in text: String, target: String) -> String.Index? {
        let maxPrefixLen = min(text.count, target.count - 1)
        guard maxPrefixLen >= 1 else { return nil }
        for len in stride(from: maxPrefixLen, through: 1, by: -1) {
            let suffixStart = text.index(text.endIndex, offsetBy: -len)
            let suffix = text[suffixStart...]
            if target.hasPrefix(suffix) {
                return suffixStart
            }
        }
        return nil
    }

    private func mergeAdjacent(_ items: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for item in items {
            switch (merged.last, item) {
            case (.some(.reasoning(let a)), .reasoning(let b)):
                merged[merged.count - 1] = .reasoning(a + b)
            case (.some(.content(let a)), .content(let b)):
                merged[merged.count - 1] = .content(a + b)
            default:
                merged.append(item)
            }
        }
        return merged
    }
}
