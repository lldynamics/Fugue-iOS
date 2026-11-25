import Foundation

/// Incrementally splits streaming markdown tokens into clean, speakable sentences so TTS can
/// start speaking on the first completed clause instead of waiting for the full reply.
struct StreamingSentenceBuffer: Sendable {
    let minSentenceCharacters: Int
    let maxTotalCharacters: Int

    private var emittedSourceOffset: Int = 0
    private var totalEmittedCharacters: Int = 0
    private var latestText: String = ""

    init(minSentenceCharacters: Int = 8, maxTotalCharacters: Int = 2400) {
        self.minSentenceCharacters = max(4, minSentenceCharacters)
        self.maxTotalCharacters = max(80, maxTotalCharacters)
    }

    var emittedCharacterCount: Int { totalEmittedCharacters }

    mutating func reset() {
        emittedSourceOffset = 0
        totalEmittedCharacters = 0
        latestText = ""
    }

    /// Feeds the latest cumulative markdown text and returns newly completed sentences ready for TTS.
    mutating func ingest(cumulativeText: String) -> [String] {
        latestText = cumulativeText
        guard totalEmittedCharacters < maxTotalCharacters else { return [] }
        guard cumulativeText.count > emittedSourceOffset else { return [] }

        let startIdx = cumulativeText.index(cumulativeText.startIndex, offsetBy: emittedSourceOffset)
        let pending = String(cumulativeText[startIdx...])

        // If we are inside an unclosed fenced code block, wait until it closes before flushing past it.
        let fenceCount = Self.countCodeFences(in: cumulativeText)
        let hasUnclosedFence = (fenceCount % 2) == 1
        let searchable: String
        if hasUnclosedFence {
            if let fenceRange = pending.range(of: "```", options: .backwards) {
                searchable = String(pending[..<fenceRange.lowerBound])
            } else {
                searchable = ""
            }
        } else {
            searchable = pending
        }

        var results: [String] = []
        var cursor = searchable.startIndex
        var consumedCount = 0

        while cursor < searchable.endIndex, totalEmittedCharacters < maxTotalCharacters {
            guard let boundaryEnd = Self.nextSentenceEnd(in: searchable, from: cursor, minChars: minSentenceCharacters) else {
                break
            }
            let rawChunk = String(searchable[cursor..<boundaryEnd])
            consumedCount += searchable.distance(from: cursor, to: boundaryEnd)
            cursor = boundaryEnd

            if let spoken = sanitizeAndCap(rawChunk) {
                results.append(spoken)
            }
        }

        emittedSourceOffset += consumedCount
        return results
    }

    /// Flushes any remaining unspoken tail when generation finishes.
    mutating func finish() -> [String] {
        guard totalEmittedCharacters < maxTotalCharacters else { return [] }
        guard latestText.count > emittedSourceOffset else { return [] }
        let startIdx = latestText.index(latestText.startIndex, offsetBy: emittedSourceOffset)
        let remainder = String(latestText[startIdx...])
        emittedSourceOffset = latestText.count
        if let spoken = sanitizeAndCap(remainder) {
            return [spoken]
        }
        return []
    }

    private mutating func sanitizeAndCap(_ raw: String) -> String? {
        let cleaned = SpeechService.cleanForSpeech(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let remaining = maxTotalCharacters - totalEmittedCharacters
        guard remaining > 0 else { return nil }
        let clipped = cleaned.count > remaining ? String(cleaned.prefix(remaining)) : cleaned
        totalEmittedCharacters += clipped.count
        return clipped
    }

    private static func countCodeFences(in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: "```", range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    private static func nextSentenceEnd(in text: String, from start: String.Index, minChars: Int) -> String.Index? {
        var idx = start
        var count = 0
        let hardTerminators: Set<Character> = ["。", "！", "？", "!", "?", "；", ";"]

        while idx < text.endIndex {
            // Keep fenced code blocks intact so SpeechService.cleanForSpeech replaces the whole
            // block cleanly instead of splitting on internal newlines and reading code aloud.
            if text[idx...].hasPrefix("```") {
                let afterOpen = text.index(idx, offsetBy: 3)
                guard let closeRange = text.range(of: "```", range: afterOpen..<text.endIndex) else {
                    return nil
                }
                var afterClose = closeRange.upperBound
                if afterClose < text.endIndex && text[afterClose] == "\n" {
                    afterClose = text.index(after: afterClose)
                }
                count += text.distance(from: idx, to: afterClose)
                idx = afterClose
                continue
            }

            let ch = text[idx]
            let next = text.index(after: idx)
            count += 1

            // Line break flushes immediately for headings / lead-in lines before code blocks
            if ch == "\n" {
                if count >= 4 || (next < text.endIndex && text[next] == "\n") {
                    return next
                }
            }

            if count >= minChars {
                if hardTerminators.contains(ch) {
                    return next
                }
                if ch == "." {
                    // Avoid splitting decimals like "3.14" or domain names like "example.com"
                    let prevIsDigit = idx > start && text[text.index(before: idx)].isNumber
                    let nextIsSpaceOrEnd = next == text.endIndex || text[next].isWhitespace
                    if !prevIsDigit && nextIsSpaceOrEnd {
                        return next
                    }
                }
            }
            // Prevent excessively long clauses without terminal punctuation from stalling playback
            if count >= 96 && (ch == "，" || ch == "," || ch == "：" || ch == ":") {
                return next
            }
            idx = next
        }
        return nil
    }
}
