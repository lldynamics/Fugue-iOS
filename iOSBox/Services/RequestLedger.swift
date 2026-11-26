import Foundation

enum LedgerPeriod: String, CaseIterable, Identifiable {
    case today, month, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return String(localized: "按日")
        case .month: return String(localized: "按月")
        case .all: return String(localized: "全部")
        }
    }

    func includes(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard self != .all else { return true }
        guard let interval = calendar.dateInterval(of: self == .today ? .day : .month, for: now) else { return false }
        return date >= interval.start && date < interval.end
    }
}

enum RequestLedger {
    /// Approximate USD multiplier used strictly to order multi-currency summaries by spend magnitude
    /// without merging distinct currencies into a synthetic sum.
    private static func approximateUSDMultiplier(for currency: String) -> Double {
        switch currency.uppercased() {
        case "USD": return 1.0
        case "EUR": return 1.08
        case "GBP": return 1.27
        case "CNY": return 0.14
        case "HKD": return 0.128
        case "JPY": return 0.0067
        default: return 1.0
        }
    }

    static func sortedCurrencies(_ totals: [String: Double]) -> [String] {
        totals.keys.sorted { lhs, rhs in
            let lhsAmount = max(0, totals[lhs] ?? 0)
            let rhsAmount = max(0, totals[rhs] ?? 0)
            let lhsUSD = lhsAmount * approximateUSDMultiplier(for: lhs)
            let rhsUSD = rhsAmount * approximateUSDMultiplier(for: rhs)
            if abs(lhsUSD - rhsUSD) > 1e-12 {
                return lhsUSD > rhsUSD
            }
            if lhsAmount != rhsAmount {
                return lhsAmount > rhsAmount
            }
            if (lhs == "USD") != (rhs == "USD") {
                return lhs == "USD"
            }
            return lhs < rhs
        }
    }

    static func costOverviewText(totals: [String: Double], modelRecords: [RequestRecord], requestCount: Int) -> String {
        let ordered = sortedCurrencies(totals)
        if !ordered.isEmpty {
            if ordered.count == 1, let currency = ordered.first, let amount = totals[currency] {
                return costText(amount, currency: currency)
            }
            let first = ordered[0]
            let second = ordered[1]
            let combined = "\(costText(totals[first] ?? 0, currency: first)) + \(costText(totals[second] ?? 0, currency: second))"
            let extraCount = ordered.count - 2
            return extraCount > 0 ? "\(combined) +\(extraCount)" : combined
        }
        guard requestCount > 0 else { return "0" }
        guard !modelRecords.isEmpty else { return String(localized: "搜索费用另计") }
        let completed = modelRecords.filter { $0.status != .running && $0.status != .blocked }
        if completed.isEmpty {
            return modelRecords.contains { $0.status == .running } ? String(localized: "等待用量") : String(localized: "无计费记录")
        }
        let missingPrice = completed.contains { !$0.hasModelPricing }
        return missingPrice ? String(localized: "未定价") : String(localized: "缺少用量")
    }

    struct Group: Identifiable {
        let id: String
        let providerName: String
        let modelName: String
        let kind: RequestKind
        let records: [RequestRecord]

        var completed: [RequestRecord] { records.filter { $0.status == .succeeded } }
        var medianFirstOutputMs: Double? { median(completed.compactMap { $0.firstOutputMs.map(Double.init) }) }
        var medianFirstContentMs: Double? { median(completed.compactMap { $0.firstContentMs.map(Double.init) }) }
        var medianTPS: Double? { median(completed.compactMap(\.tokensPerSecond)) }
        var speedSampleCount: Int { completed.compactMap(\.tokensPerSecond).count }
        var costs: [String: Double] { RequestLedger.costs(records) }
    }

    static func groups(_ records: [RequestRecord]) -> [Group] {
        let grouped = Dictionary(grouping: records) { "\($0.providerID)/\($0.modelID)/\($0.kindRaw)" }
        return grouped.compactMap { key, records in
            guard let latest = records.max(by: { $0.startedAt < $1.startedAt }) else { return nil }
            return Group(id: key, providerName: latest.providerName, modelName: latest.modelDisplayName,
                         kind: latest.kind, records: records)
        }.sorted {
            let lhs = $0.medianTPS ?? -1
            let rhs = $1.medianTPS ?? -1
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    static func median(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite).sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }

    static func costs(_ records: [RequestRecord]) -> [String: Double] {
        var result: [String: Double] = [:]
        for record in records where record.status != .running {
            if let currency = record.currency, let cost = record.estimatedCost {
                result[currency, default: 0] += cost
            }
        }
        return result
    }

    static func cacheSavings(_ records: [RequestRecord]) -> [String: Double] {
        var result: [String: Double] = [:]
        for record in records where record.status != .running {
            if let currency = record.currency, let saved = record.estimatedCacheSavings {
                result[currency, default: 0] += saved
            }
        }
        return result
    }

    struct TrendBucket: Identifiable {
        let id: Date
        let date: Date
        let requestCount: Int
        let totalTokens: Int
    }

    static func trendBuckets(_ records: [RequestRecord], period: LedgerPeriod, calendar: Calendar = .current) -> [TrendBucket] {
        guard !records.isEmpty else { return [] }
        let component: Calendar.Component = (period == .today) ? .hour : (period == .month ? .day : .month)
        let grouped = Dictionary(grouping: records) { record -> Date in
            calendar.dateInterval(of: component, for: record.startedAt)?.start ?? record.startedAt
        }
        return grouped.map { bucketDate, items in
            let tokens = items.reduce(0) { total, item in
                LLMUsage.saturatedSum(total, LLMUsage.combined(item.promptTokens, item.completionTokens) ?? 0)
            }
            return TrendBucket(id: bucketDate, date: bucketDate, requestCount: items.count, totalTokens: tokens)
        }
        .sorted { $0.date < $1.date }
    }

    static func costText(_ value: Double, currency: String) -> String {
        if value > 0 && value < 0.000001 {
            let threshold = 0.000001.formatted(.number.precision(.fractionLength(6)))
            return "\(currency) <\(threshold)"
        }
        return "\(currency) \(value.formatted(.number.precision(.fractionLength(0...6))))"
    }

    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.2f s", Double(milliseconds) / 1000)
    }

    /// Backfills missing pricing on historical records for a specific provider + model without overwriting records that already had prices.
    @MainActor
    @discardableResult
    static func backfillUnpricedRecords(
        in records: [RequestRecord],
        providerID: UUID,
        modelID: String,
        spec: ModelSpec
    ) -> Int {
        guard let inPrice = RequestRecord.validPrice(spec.inputPricePerMillion),
              let outPrice = RequestRecord.validPrice(spec.outputPricePerMillion),
              let currency = spec.priceCurrency,
              RequestRecord.currencies.contains(currency) else { return 0 }
        let readPrice = RequestRecord.validPrice(spec.cacheReadPricePerMillion)
        let writePrice = RequestRecord.validPrice(spec.cacheWritePricePerMillion)
        var updatedCount = 0
        var cacheBatch: [UUID: CachePriceSnapshotStore.Pair] = [:]
        for record in records where record.providerID == providerID && record.modelID == modelID && record.kind != .webSearch && !record.kind.usesAudioPricing && !record.hasModelPricing {
            record.inputPricePerMillion = inPrice
            record.outputPricePerMillion = outPrice
            record.currency = currency
            if readPrice != nil || writePrice != nil {
                cacheBatch[record.id] = .init(read: readPrice, write: writePrice)
            }
            updatedCount += 1
        }
        if !cacheBatch.isEmpty {
            CachePriceSnapshotStore.shared.setBatch(cacheBatch)
        }
        return updatedCount
    }
}
