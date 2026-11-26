import Foundation
import Testing
@testable import iOSBox

@Suite("Audit P1 Pricing, Multi-Currency Ledger & Templates")
@MainActor
struct AuditP1PricingAndLedgerTests {

    @Test("Multi-currency ledger summary surfaces dominant USD spend instead of masking it behind tiny CNY")
    func multiCurrencySummaryPrioritizesDominantSpend() {
        var cnySpec = ModelSpec(id: "deepseek-chat", displayName: "DeepSeek V3")
        cnySpec.inputPricePerMillion = 1.0
        cnySpec.outputPricePerMillion = 1.0
        cnySpec.priceCurrency = "CNY"

        var usdSpec = ModelSpec(id: "claude-opus-4-20250514", displayName: "Claude Opus 4")
        usdSpec.inputPricePerMillion = 50.0
        usdSpec.outputPricePerMillion = 50.0
        usdSpec.priceCurrency = "USD"

        let cnyTarget = ResolvedModelTarget(
            providerID: UUID(),
            providerName: "DeepSeek",
            protocolType: .openAICompatible,
            modelID: cnySpec.id,
            modelDisplayName: cnySpec.displayName,
            accentHex: "#4D6BFE",
            supportsVision: false,
            supportsReasoning: false
        )
        let usdTarget = ResolvedModelTarget(
            providerID: UUID(),
            providerName: "Anthropic",
            protocolType: .anthropic,
            modelID: usdSpec.id,
            modelDisplayName: usdSpec.displayName,
            accentHex: "#D97757",
            supportsVision: true,
            supportsReasoning: true
        )

        let cnyRecord = RequestRecord(
            target: cnyTarget,
            spec: cnySpec,
            conversationID: UUID(),
            messageID: UUID(),
            kind: .answer
        )
        cnyRecord.promptTokens = 5_000
        cnyRecord.completionTokens = 5_000
        cnyRecord.finish(.succeeded, elapsedMs: 200)

        let usdRecord = RequestRecord(
            target: usdTarget,
            spec: usdSpec,
            conversationID: UUID(),
            messageID: UUID(),
            kind: .answer
        )
        usdRecord.promptTokens = 500_000
        usdRecord.completionTokens = 500_000
        usdRecord.finish(.succeeded, elapsedMs: 800)

        let records = [cnyRecord, usdRecord]
        let totals = RequestLedger.costs(records)
        #expect(abs((totals["CNY"] ?? 0) - 0.01) < 1e-6)
        #expect(abs((totals["USD"] ?? 0) - 50.0) < 1e-6)

        let ordered = RequestLedger.sortedCurrencies(totals)
        #expect(ordered == ["USD", "CNY"])

        let overview = RequestLedger.costOverviewText(
            totals: totals,
            modelRecords: records,
            requestCount: records.count
        )
        let expectedUSD = RequestLedger.costText(50.0, currency: "USD")
        let expectedCNY = RequestLedger.costText(0.01, currency: "CNY")
        #expect(overview == "\(expectedUSD) + \(expectedCNY)")
        #expect(overview.hasPrefix(expectedUSD))

        // Three currencies: top two by USD-equivalent shown first, remaining summarized with +1
        let threeTotals = ["CNY": 0.01, "EUR": 10.0, "USD": 50.0]
        let threeOverview = RequestLedger.costOverviewText(
            totals: threeTotals,
            modelRecords: records,
            requestCount: 3
        )
        let expectedEUR = RequestLedger.costText(10.0, currency: "EUR")
        #expect(threeOverview == "\(expectedUSD) + \(expectedEUR) +1")

        // Single currency preserves exact legacy formatting
        let singleOverview = RequestLedger.costOverviewText(
            totals: ["USD": 50.0],
            modelRecords: [usdRecord],
            requestCount: 1
        )
        #expect(singleOverview == expectedUSD)
    }

    @Test("RequestRecord cache savings deducts cache-write surcharge and clamps net loss to nil")
    func cacheSavingsDeductsCacheWriteSurcharge() throws {
        var claudeSpec = ModelSpec(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4")
        let preset = try #require(ModelPricingCatalog.match(modelID: claudeSpec.id))
        ModelPricingCatalog.apply(preset, to: &claudeSpec)

        let target = ResolvedModelTarget(
            providerID: UUID(),
            providerName: "Anthropic",
            protocolType: .anthropic,
            modelID: claudeSpec.id,
            modelDisplayName: claudeSpec.displayName,
            accentHex: "#D97757",
            supportsVision: true,
            supportsReasoning: true
        )

        // 100k input: 80k cache read ($0.30/M vs $3.00/M -> +$0.216) + 10k cache write ($3.75/M vs $3.00/M -> -$0.0075)
        // Net savings = $0.216 - $0.0075 = $0.2085 (uncached $0.33 - actual $0.1215 = $0.2085)
        let record = RequestRecord(
            target: target,
            spec: claudeSpec,
            conversationID: UUID(),
            messageID: UUID(),
            kind: .answer
        )
        record.promptTokens = 100_000
        record.cachedTokens = 80_000
        record.cacheWriteTokens = 10_000
        record.completionTokens = 2_000
        record.finish(.succeeded, elapsedMs: 600)

        let cost = try #require(record.estimatedCost)
        let savings = try #require(record.estimatedCacheSavings)
        #expect(abs(cost - 0.1215) < 1e-6)
        #expect(abs(savings - 0.2085) < 1e-6)

        // Ledger aggregation uses net cache savings
        let ledgerSavings = RequestLedger.cacheSavings([record])
        #expect(abs((ledgerSavings["USD"] ?? 0) - 0.2085) < 1e-6)

        // When cache-write surcharge exceeds cache-read discount, net savings is non-positive (nil)
        let writeHeavy = RequestRecord(
            target: target,
            spec: claudeSpec,
            conversationID: UUID(),
            messageID: UUID(),
            kind: .answer
        )
        writeHeavy.promptTokens = 100_000
        writeHeavy.cachedTokens = 5_000       // gross read savings: 5k * $2.70/M = $0.0135
        writeHeavy.cacheWriteTokens = 80_000  // write surcharge: 80k * $0.75/M = $0.0600
        writeHeavy.completionTokens = 1_000
        writeHeavy.finish(.succeeded, elapsedMs: 500)
        #expect(writeHeavy.estimatedCacheSavings == nil)
        #expect(RequestLedger.cacheSavings([writeHeavy]).isEmpty)
    }

    @Test("ModelPricingCatalog matches Flash-Lite, Gemini 2.0 Flash, modern Opus 4.5-4.7, and USD router DeepSeek rates")
    func catalogPrefixOrderingAndAggregatorCurrency() throws {
        // Gemini 2.5 Flash-Lite and Gemini 2.0 Flash must not be billed 6x higher at Gemini 2.5 Flash rates
        let flashLite = try #require(ModelPricingCatalog.match(modelID: "gemini-2.5-flash-lite"))
        #expect(flashLite.currency == "USD")
        #expect(abs(flashLite.inputPerMillion - 0.10) < 1e-6)
        #expect(abs(flashLite.outputPerMillion - 0.40) < 1e-6)

        let gemini20Flash = try #require(ModelPricingCatalog.match(modelID: "gemini-2.0-flash"))
        #expect(gemini20Flash.currency == "USD")
        #expect(abs(gemini20Flash.inputPerMillion - 0.10) < 1e-6)
        #expect(abs(gemini20Flash.outputPerMillion - 0.40) < 1e-6)

        let gemini25Flash = try #require(ModelPricingCatalog.match(modelID: "gemini-2.5-flash"))
        #expect(abs(gemini25Flash.inputPerMillion - 0.30) < 1e-6)
        #expect(abs(gemini25Flash.outputPerMillion - 2.50) < 1e-6)

        // Modern Claude Opus 4.5 / 4.6 / 4.7 ($5 / $25) must match before legacy Opus 4 ($15 / $75)
        for modernOpus in ["claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5-20251101", "anthropic/claude-opus-4.6"] {
            let matched = try #require(ModelPricingCatalog.match(modelID: modernOpus))
            #expect(matched.currency == "USD")
            #expect(abs(matched.inputPerMillion - 5.0) < 1e-6)
            #expect(abs(matched.outputPerMillion - 25.0) < 1e-6)
        }

        let legacyOpus = try #require(ModelPricingCatalog.match(modelID: "claude-opus-4-20250514"))
        #expect(abs(legacyOpus.inputPerMillion - 15.0) < 1e-6)
        #expect(abs(legacyOpus.outputPerMillion - 75.0) < 1e-6)

        // USD aggregators (OpenRouter, Together, Fireworks, Groq, DeepInfra) bill DeepSeek in USD
        let routerV3 = try #require(ModelPricingCatalog.match(
            modelID: "deepseek/deepseek-chat",
            baseURL: "https://openrouter.ai/api/v1"
        ))
        #expect(routerV3.currency == "USD")
        #expect(abs(routerV3.inputPerMillion - 0.27) < 1e-6)
        #expect(abs(routerV3.outputPerMillion - 1.10) < 1e-6)

        let routerR1 = try #require(ModelPricingCatalog.match(
            modelID: "deepseek/deepseek-r1",
            baseURL: "https://openrouter.ai/api/v1"
        ))
        #expect(routerR1.currency == "USD")
        #expect(abs(routerR1.inputPerMillion - 0.55) < 1e-6)
        #expect(abs(routerR1.outputPerMillion - 2.19) < 1e-6)

        // Official DeepSeek endpoint and nil baseURL preserve CNY rates
        let officialR1 = try #require(ModelPricingCatalog.match(
            modelID: "deepseek-reasoner",
            baseURL: "https://api.deepseek.com/v1"
        ))
        #expect(officialR1.currency == "CNY")
        #expect(abs(officialR1.inputPerMillion - 4.0) < 1e-6)
        #expect(abs(officialR1.outputPerMillion - 16.0) < 1e-6)

        let defaultV3 = try #require(ModelPricingCatalog.match(modelID: "deepseek-chat"))
        #expect(defaultV3.currency == "CNY")
        #expect(abs(defaultV3.inputPerMillion - 2.0) < 1e-6)
        #expect(abs(defaultV3.outputPerMillion - 8.0) < 1e-6)
    }

    @Test("OpenAI Responses template matches current OpenAI flagship models")
    func openAIResponsesTemplateAlignedWithFlagships() throws {
        let openAITemplate = try #require(ProviderTemplate.catalog.first { $0.id == "openai" })
        let responsesTemplate = ProviderTemplate.openAIResponses

        #expect(responsesTemplate.suggestedModels.map(\.id) == openAITemplate.suggestedModels.map(\.id))
        #expect(responsesTemplate.suggestedModels.map(\.id) == ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6-luna"])
    }
}
