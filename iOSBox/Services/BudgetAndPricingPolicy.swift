import Foundation
import SwiftData

enum MonthlyBudgetLevel: Equatable {
    case unconfigured
    case normal
    case warning
    case exceeded
}

struct MonthlyBudgetEvaluation: Equatable {
    let spent: Double
    let limit: Double
    let currency: String
    let alertRatio: Double
    let ratio: Double
    let remaining: Double
    let level: MonthlyBudgetLevel
}

enum MonthlyBudgetEvaluator {
    static func evaluate(
        spentByCurrency: [String: Double],
        limit: Double,
        currency: String,
        alertRatio: Double = 0.8
    ) -> MonthlyBudgetEvaluation {
        let normalizedCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "USD"
            : currency.trimmingCharacters(in: .whitespacesAndNewlines)
        let spent = max(0, spentByCurrency[normalizedCurrency] ?? 0)
        let cleanAlertRatio = min(max(alertRatio.isFinite ? alertRatio : 0.8, 0.5), 0.95)

        guard limit.isFinite, limit > 0 else {
            return MonthlyBudgetEvaluation(
                spent: spent,
                limit: 0,
                currency: normalizedCurrency,
                alertRatio: cleanAlertRatio,
                ratio: 0,
                remaining: 0,
                level: .unconfigured
            )
        }

        let ratio = spent / limit
        let remaining = max(0, limit - spent)
        let level: MonthlyBudgetLevel
        if ratio >= 1.0 {
            level = .exceeded
        } else if ratio >= cleanAlertRatio {
            level = .warning
        } else {
            level = .normal
        }

        return MonthlyBudgetEvaluation(
            spent: spent,
            limit: limit,
            currency: normalizedCurrency,
            alertRatio: cleanAlertRatio,
            ratio: ratio,
            remaining: remaining,
            level: level
        )
    }

    @MainActor
    static func evaluateCurrentMonth(
        in context: ModelContext,
        preferences: AppPreferences,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> MonthlyBudgetEvaluation {
        let limit = preferences.monthlyBudgetLimit
        let currency = preferences.monthlyBudgetCurrency
        let alertRatio = preferences.monthlyBudgetAlertRatio
        guard limit.isFinite, limit > 0,
              let interval = calendar.dateInterval(of: .month, for: now) else {
            return evaluate(spentByCurrency: [:], limit: 0, currency: currency, alertRatio: alertRatio)
        }
        let start = interval.start
        let end = interval.end
        let searchRaw = RequestKind.webSearch.rawValue
        let descriptor = FetchDescriptor<RequestRecord>(
            predicate: #Predicate<RequestRecord> {
                $0.startedAt >= start && $0.startedAt < end && $0.kindRaw != searchRaw
            }
        )
        let monthRecords = (try? context.fetch(descriptor)) ?? []
        let spentByCurrency = RequestLedger.costs(monthRecords)
        return evaluate(spentByCurrency: spentByCurrency, limit: limit, currency: currency, alertRatio: alertRatio)
    }
}
