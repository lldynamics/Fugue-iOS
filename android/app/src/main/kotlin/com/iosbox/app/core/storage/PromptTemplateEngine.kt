package com.iosbox.app.core.storage

import com.iosbox.app.core.model.L10n
import com.iosbox.app.core.model.ResolvedModelTarget
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object PromptTemplateEngine {
    data class VariableOption(
        val token: String,
        val label: String
    )

    val availableVariables: List<VariableOption>
        get() = listOf(
            VariableOption("{{date}}", L10n.text("当前日期", "Date")),
            VariableOption("{{time}}", L10n.text("当前时间", "Time")),
            VariableOption("{{datetime}}", L10n.text("日期与时间", "Date & Time")),
            VariableOption("{{weekday}}", L10n.text("星期", "Weekday")),
            VariableOption("{{model}}", L10n.text("当前模型", "Model")),
            VariableOption("{{model_id}}", L10n.text("模型 ID", "Model ID")),
            VariableOption("{{provider}}", L10n.text("服务商", "Provider")),
            VariableOption("{{language}}", L10n.text("系统语言", "Language"))
        )

    fun render(
        template: String,
        target: ResolvedModelTarget?,
        now: Date = Date(),
        locale: Locale = Locale.getDefault()
    ): String {
        if (!template.contains("{{")) return template

        val dateStr = SimpleDateFormat("yyyy-MM-dd", locale).format(now)
        val timeStr = SimpleDateFormat("HH:mm", locale).format(now)
        val datetimeStr = SimpleDateFormat("yyyy-MM-dd HH:mm", locale).format(now)
        val weekdayStr = SimpleDateFormat("EEEE", locale).format(now)
        val languageStr = locale.getDisplayLanguage(locale).ifBlank { locale.language.ifBlank { "en" } }

        val replacements = listOf(
            "{{date}}" to dateStr,
            "{{time}}" to timeStr,
            "{{datetime}}" to datetimeStr,
            "{{weekday}}" to weekdayStr,
            "{{model}}" to (target?.modelDisplayName ?: ""),
            "{{model_id}}" to (target?.modelID ?: ""),
            "{{provider}}" to (target?.providerName ?: ""),
            "{{language}}" to languageStr
        )

        var rendered = template
        for ((token, value) in replacements) {
            rendered = rendered.replace(token, value)
        }
        return rendered
    }
}
