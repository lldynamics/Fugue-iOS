package com.iosbox.app.core.model

import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

object PricingMultiplierPolicy {
    const val DEFAULT_MULTIPLIER = 1.0
    const val MIN_MULTIPLIER = 0.01
    const val MAX_MULTIPLIER = 100.0
    val PRESETS = listOf(0.2, 0.5, 1.0, 1.5, 2.0, 7.2)

    fun sanitize(raw: Double?): Double {
        if (raw == null || !raw.isFinite() || raw <= 0.0) return DEFAULT_MULTIPLIER
        return raw.coerceIn(MIN_MULTIPLIER, MAX_MULTIPLIER)
    }

    fun effectivePrice(base: Double?, multiplier: Double): Double? {
        if (base == null || !base.isFinite() || base < 0.0) return null
        return base * sanitize(multiplier)
    }

    fun format(multiplier: Double): String {
        val clean = sanitize(multiplier)
        val rounded = clean.roundToInt().toDouble()
        if (abs(clean - rounded) < 0.0001) {
            return "${clean.roundToInt()}x"
        }
        val trimmed = String.format(Locale.US, "%.2f", clean).trimEnd('0').trimEnd('.')
        return "${trimmed}x"
    }
}

enum class MonthlyBudgetLevel {
    UNCONFIGURED,
    NORMAL,
    WARNING,
    EXCEEDED
}

data class MonthlyBudgetEvaluation(
    val spent: Double,
    val limit: Double,
    val currency: String,
    val alertRatio: Double,
    val ratio: Double,
    val remaining: Double,
    val level: MonthlyBudgetLevel
)

object MonthlyBudgetEvaluator {
    fun evaluate(
        spentByCurrency: Map<String, Double>,
        limit: Double,
        currency: String,
        alertRatio: Double = 0.8
    ): MonthlyBudgetEvaluation {
        val cleanCurrency = currency.trim().ifEmpty { "USD" }
        val spent = (spentByCurrency[cleanCurrency] ?: 0.0).coerceAtLeast(0.0)
        val cleanAlertRatio = (if (alertRatio.isFinite()) alertRatio else 0.8).coerceIn(0.5, 0.95)

        if (!limit.isFinite() || limit <= 0.0) {
            return MonthlyBudgetEvaluation(
                spent = spent,
                limit = 0.0,
                currency = cleanCurrency,
                alertRatio = cleanAlertRatio,
                ratio = 0.0,
                remaining = 0.0,
                level = MonthlyBudgetLevel.UNCONFIGURED
            )
        }

        val ratio = spent / limit
        val remaining = (limit - spent).coerceAtLeast(0.0)
        val level = when {
            ratio >= 1.0 -> MonthlyBudgetLevel.EXCEEDED
            ratio >= cleanAlertRatio -> MonthlyBudgetLevel.WARNING
            else -> MonthlyBudgetLevel.NORMAL
        }

        return MonthlyBudgetEvaluation(
            spent = spent,
            limit = limit,
            currency = cleanCurrency,
            alertRatio = cleanAlertRatio,
            ratio = ratio,
            remaining = remaining,
            level = level
        )
    }
}
