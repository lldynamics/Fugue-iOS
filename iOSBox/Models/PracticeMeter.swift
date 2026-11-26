import Foundation
import SwiftData

/// Provider-reported units for one response or one independently billed transcription.
struct PracticeMeter: Codable, Equatable {
    var input: Int?
    var output: Int?
    var audioInput: Int?
    var audioOutput: Int?
    var cached: Int?
    var cachedAudio: Int?
    var seconds: Double?
    var rates: PracticeAudioRates?

    init(usage: [String: Any]?, kind: RequestKind, rates: PracticeAudioRates?) {
        self.rates = rates
        guard let usage else { return }
        if usage["type"] as? String == "duration" {
            if let n = usage["seconds"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
               n.doubleValue.isFinite, (0...86_400).contains(n.doubleValue) { seconds = n.doubleValue }
            return
        }
        func count(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  Double(n.intValue) == n.doubleValue else { return nil }
            return LLMUsage.valid(n.intValue)
        }
        let incoming = usage["input_token_details"] as? [String: Any]
        let outgoing = usage["output_token_details"] as? [String: Any]
        input = count(usage["input_tokens"])
        output = count(usage["output_tokens"])
        audioInput = count(incoming?["audio_tokens"])
        audioOutput = kind == .practiceTranscription ? 0 : count(outgoing?["audio_tokens"])
        cached = kind == .practiceTranscription ? 0 : count(incoming?["cached_tokens"])
        cachedAudio = count((incoming?["cached_tokens_details"] as? [String: Any])?["audio_tokens"])
    }

    func cost(for record: RequestRecord) -> Double? {
        guard let currency = record.currency, RequestRecord.currencies.contains(currency) else { return nil }
        if let seconds {
            guard seconds.isFinite, (0...86_400).contains(seconds), let rate = RequestRecord.validPrice(rates?.perMinute) else { return nil }
            return seconds * rate / 60
        }
        guard let input = LLMUsage.valid(input), let output = LLMUsage.valid(output),
              let audioIn = LLMUsage.valid(audioInput) ?? (input == 0 ? 0 : nil),
              let audioOut = LLMUsage.valid(audioOutput) ?? (output == 0 ? 0 : nil),
              audioIn <= input, audioOut <= output,
              let cached = LLMUsage.valid(cached) ?? (input == 0 ? 0 : nil), cached <= input else { return nil }
        let inferredCachedAudio = cached == 0 || audioIn == 0 ? 0 : (audioIn == input ? cached : nil)
        guard let audioRead = LLMUsage.valid(cachedAudio) ?? inferredCachedAudio, audioRead <= min(cached, audioIn),
              cached - audioRead <= input - audioIn else { return nil }
        let buckets: [(Int, Double?)] = [(audioIn - audioRead, rates?.input), (audioRead, rates?.cachedInput),
            (input - audioIn - cached + audioRead, record.inputPricePerMillion), (cached - audioRead, record.cacheReadPricePerMillion),
            (audioOut, rates?.output), (output - audioOut, record.outputPricePerMillion)]
        var amount = 0.0
        for (units, price) in buckets where units > 0 {
            guard let rate = RequestRecord.validPrice(price) else { return nil }
            amount += Double(units) * rate
        }
        return amount / 1_000_000
    }
}

/// Written in the same SwiftData transaction as its ledger row. Older schema versions stay frozen.
@Model final class PracticeMeterRecord {
    @Attribute(.unique) var requestID: UUID
    var data: Data

    init(requestID: UUID, meter: PracticeMeter) throws {
        self.requestID = requestID
        data = try JSONEncoder().encode(meter)
    }

    static func find(_ id: UUID, in context: ModelContext) throws -> PracticeMeterRecord? {
        var query = FetchDescriptor<PracticeMeterRecord>(predicate: #Predicate { $0.requestID == id })
        query.fetchLimit = 1
        return try context.fetch(query).first
    }
}
