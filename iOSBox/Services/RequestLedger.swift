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
    static func costOverviewText(totals: [String: Double], modelRecords: [RequestRecord], requestCount: Int) -> String {
        if let currency = totals.keys.sorted().first, let amount = totals[currency] {
            return costText(amount, currency: currency)
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
        "\(currency) \(value.formatted(.number.precision(.fractionLength(0...6))))"
    }

    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.2f s", Double(milliseconds) / 1000)
    }
}
