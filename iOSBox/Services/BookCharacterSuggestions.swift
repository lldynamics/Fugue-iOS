import Foundation
import NaturalLanguage

struct BookCharacterSuggestion: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let chapter: String
    let excerpt: String
}

enum BookCharacterSuggestions {
    /// Candidate names are hints. Every result has a literal occurrence in the selected chapters.
    static func find(in manuscript: Data, through cutoff: Int?) throws -> [BookCharacterSuggestion] {
        let chapters = try JSONDecoder().decode([BookChapter].self, from: manuscript)
        let last = cutoff ?? chapters.count - 1
        guard chapters.indices.contains(last) else { return [] }
        let dialogue = try NSRegularExpression(pattern: #"(?:^|[\n。！？!?.”」』]\s*)([\p{Han}]{2,4}?)(?:(?:轻声|低声|笑着|轻轻|连忙)?(?:说道?|问道?|答道?|喊道?|道)(?=[：:，,。“「『"])|(?=[：:]\s*[“「『"]?))|\b([A-Z][a-z]+(?: [A-Z][a-z]+){0,2})\s+(?:said|asked|replied|whispered)\b"#, options: .anchorsMatchLines)
        let tagger = NLTagger(tagSchemes: [.nameType])
        let ignored: Set<String> = ["自己", "大家", "他们", "她们", "有人", "众人", "少年", "那人", "Chapter", "He", "She", "They"]
        var candidates: [String: (value: BookCharacterSuggestion, score: Int, order: Int)] = [:]

        func record(_ range: Range<String.Index>, in line: String, chapter: String, weight: Int) {
            let name = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...45).contains(name.count), !ignored.contains(name) else { return }
            if var existing = candidates[name] {
                existing.score += weight
                candidates[name] = existing
                return
            }
            guard candidates.count < 400 else { return }
            let start = line.index(range.lowerBound, offsetBy: -22, limitedBy: line.startIndex) ?? line.startIndex
            let excerpt = String(line[start...].prefix(88)).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = BookCharacterSuggestion(name: name, chapter: chapter, excerpt: excerpt)
            candidates[name] = (value, weight, candidates.count)
        }

        // Sample across the permitted range so a long first chapter cannot consume the whole budget.
        let samples = min(last + 1, 48)
        for n in 0..<samples {
            try Task.checkCancellation()
            let chapter = chapters[samples == 1 ? 0 : n * last / (samples - 1)]
            let sample = String(chapter.text.prefix(6_000))
            for match in dialogue.matches(in: sample, range: NSRange(sample.startIndex..., in: sample)) {
                let capture = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
                if let range = Range(capture, in: sample) { record(range, in: sample, chapter: chapter.title, weight: 4) }
            }
            let opening = String(sample.prefix(1_000))
            tagger.string = opening
            tagger.enumerateTags(in: opening.startIndex..<opening.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
                if tag == .personalName { record(range, in: opening, chapter: chapter.title, weight: 1) }
                return !Task.isCancelled
            }
        }
        try Task.checkCancellation()
        return candidates.values.sorted {
            $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score
        }.prefix(5).map(\.value)
    }
}
