import Foundation

/// Incrementally separates a leading `<think>...</think>` (or `<thinking>...</thinking>`) block
/// from regular assistant content across arbitrary SSE token boundaries.
///
/// Reasoning models emit the think block only at the very beginning of a reply, so a tag is
/// recognized only before any non-whitespace content. Once regular content has started, the
/// rest of the stream is passed through verbatim; this keeps answers that merely *mention*
/// `<think>` (docs, code samples) intact.
struct ThinkTagStreamParser: Sendable {
    enum Segment: Equatable, Sendable {
        case reasoning(String)
        case content(String)
    }

    private enum Phase: Sendable {
        /// Only whitespace seen so far; still deciding whether a think block opens the reply.
        case detecting
        /// Inside the leading think block.
        case insideThink
        /// Right after the closing tag: drop newlines separating reasoning from the answer.
        case afterThink
        /// Regular content; no further tag parsing.
        case passthrough
    }

    private static let tagPairs: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>")
    ]

    private var phase: Phase = .detecting
    private var buffer = ""
    private var activeCloseTag = "</think>"

    mutating func feed(_ chunk: String) -> [Segment] {
        guard !chunk.isEmpty else { return [] }
        switch phase {
        case .passthrough:
            return [.content(chunk)]
        case .afterThink:
            return consumeAfterThink(chunk)
        case .insideThink:
            return consumeInsideThink(chunk)
        case .detecting:
            return consumeDetecting(chunk)
        }
    }

    mutating func finish() -> [Segment] {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return [] }
        switch phase {
        case .insideThink:
            return [.reasoning(buffer)]
        case .detecting:
            return [.content(buffer)]
        case .afterThink, .passthrough:
            return []
        }
    }

    // MARK: - Phases

    private mutating func consumeDetecting(_ chunk: String) -> [Segment] {
        buffer.append(chunk)
        let leading = buffer.drop(while: \.isWhitespace)
        if leading.isEmpty {
            return [] // only whitespace so far
        }

        for pair in Self.tagPairs where leading.hasPrefix(pair.open) {
            var rest = String(leading.dropFirst(pair.open.count))
            if rest.hasPrefix("\n") {
                rest.removeFirst()
            }
            buffer = ""
            activeCloseTag = pair.close
            phase = .insideThink
            return rest.isEmpty ? [] : consumeInsideThink(rest)
        }

        if Self.tagPairs.contains(where: { $0.open.hasPrefix(leading) }) {
            return [] // could still become an opening tag, e.g. "<thi"
        }

        phase = .passthrough
        let output = buffer
        buffer = ""
        return [.content(output)]
    }

    private mutating func consumeInsideThink(_ chunk: String) -> [Segment] {
        buffer.append(chunk)

        if let closeRange = buffer.range(of: activeCloseTag) {
            var outputs: [Segment] = []
            let thought = String(buffer[..<closeRange.lowerBound])
            if !thought.isEmpty {
                outputs.append(.reasoning(thought))
            }
            let rest = String(buffer[closeRange.upperBound...])
            buffer = ""
            phase = .afterThink
            outputs.append(contentsOf: rest.isEmpty ? [] : consumeAfterThink(rest))
            return outputs
        }

        if let partialIndex = trailingPartialMatchIndex(in: buffer, target: activeCloseTag) {
            let safePart = String(buffer[..<partialIndex])
            buffer = String(buffer[partialIndex...])
            return safePart.isEmpty ? [] : [.reasoning(safePart)]
        }

        let all = buffer
        buffer = ""
        return [.reasoning(all)]
    }

    private mutating func consumeAfterThink(_ chunk: String) -> [Segment] {
        let trimmed = chunk.drop(while: { $0 == "\n" || $0 == "\r" })
        guard !trimmed.isEmpty else { return [] }
        phase = .passthrough
        return [.content(String(trimmed))]
    }

    // MARK: - Helpers

    private func trailingPartialMatchIndex(in text: String, target: String) -> String.Index? {
        let maxPrefixLen = min(text.count, target.count - 1)
        guard maxPrefixLen >= 1 else { return nil }
        for len in stride(from: maxPrefixLen, through: 1, by: -1) {
            let suffixStart = text.index(text.endIndex, offsetBy: -len)
            if target.hasPrefix(text[suffixStart...]) {
                return suffixStart
            }
        }
        return nil
    }
}
