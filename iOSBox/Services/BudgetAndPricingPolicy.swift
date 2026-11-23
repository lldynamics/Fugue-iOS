import Foundation

enum PricingMultiplierPolicy {
    static let defaultMultiplier: Double = 1.0
    static let minMultiplier: Double = 0.01
    static let maxMultiplier: Double = 100.0
    static let presets: [Double] = [0.2, 0.5, 1.0, 1.5, 2.0, 7.2]

    static func sanitize(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return defaultMultiplier }
        return min(max(raw, minMultiplier), maxMultiplier)
    }

    static func effectivePrice(_ base: Double?, multiplier: Double) -> Double? {
        guard let base, base.isFinite, base >= 0 else { return nil }
        return base * sanitize(multiplier)
    }

    static func formatted(_ multiplier: Double) -> String {
        let value = sanitize(multiplier)
        if abs(value - value.rounded()) < 0.0001 {
            return "\(Int(value.rounded()))x"
        }
        return String(format: "%.2gx", value)
    }
}

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
}
