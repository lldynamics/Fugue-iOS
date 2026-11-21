package com.iosbox.app.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
enum class RequestStatus(val rawValue: String) {
    @SerialName("running")
    RUNNING("running"),

    @SerialName("succeeded")
    SUCCEEDED("succeeded"),

    @SerialName("failed")
    FAILED("failed"),

    @SerialName("cancelled")
    CANCELLED("cancelled"),

    @SerialName("interrupted")
    INTERRUPTED("interrupted"),

    @SerialName("incomplete")
    INCOMPLETE("incomplete"),

    @SerialName("blocked")
    BLOCKED("blocked");

    val title: String
        get() = when (this) {
            RUNNING -> L10n.text("进行中", "Running")
            SUCCEEDED -> L10n.text("已完成", "Succeeded")
            FAILED -> L10n.text("失败", "Failed")
            CANCELLED -> L10n.text("已取消", "Cancelled")
            INTERRUPTED -> L10n.text("已中断", "Interrupted")
            INCOMPLETE -> L10n.text("输出不完整", "Incomplete")
            BLOCKED -> L10n.text("未发出", "Blocked")
        }

    companion object {
        fun fromRaw(raw: String): RequestStatus =
            entries.firstOrNull { it.rawValue == raw } ?: INTERRUPTED
    }
}

@Serializable
enum class RequestKind(val rawValue: String) {
    @SerialName("answer")
    ANSWER("answer"),

    @SerialName("regeneration")
    REGENERATION("regeneration"),

    @SerialName("synthesis")
    SYNTHESIS("synthesis"),

    @SerialName("sharedReading")
    SHARED_READING("sharedReading"),

    @SerialName("shortcut")
    SHORTCUT("shortcut"),

    @SerialName("webSearch")
    WEB_SEARCH("webSearch"),

    @SerialName("continuation")
    CONTINUATION("continuation"),

    @SerialName("agentTool")
    AGENT_TOOL("agentTool"),

    @SerialName("titleGeneration")
    TITLE_GENERATION("titleGeneration"),

    @SerialName("studyGeneration")
    STUDY_GENERATION("studyGeneration");

    val title: String
        get() = when (this) {
            ANSWER -> L10n.text("对话", "Chat")
            REGENERATION -> L10n.text("重答", "Regenerate")
            SYNTHESIS -> L10n.text("裁判汇总", "Synthesis")
            SHARED_READING -> L10n.text("分享精读", "Shared Reading")
            SHORTCUT -> L10n.text("快捷指令", "Shortcut")
            WEB_SEARCH -> L10n.text("联网搜索", "Web Search")
            CONTINUATION -> L10n.text("续写", "Continue")
            AGENT_TOOL -> L10n.text("工具调用", "Tool Call")
            TITLE_GENERATION -> L10n.text("智能标题", "Title Gen")
            STUDY_GENERATION -> L10n.text("助学制卡", "Study Gen")
        }

    companion object {
        fun fromRaw(raw: String): RequestKind =
            entries.firstOrNull { it.rawValue == raw } ?: ANSWER
    }
}

data class RequestMetricsSummary(
    val tokensPerSecond: Double?,
    val firstOutputMs: Int?,
    val estimatedCost: Double?,
    val estimatedCacheSavings: Double?
)

object RequestMetrics {
    val supportedCurrencies = setOf("USD", "CNY", "EUR", "GBP", "JPY", "HKD")

    fun validPrice(value: Double?): Double? {
        if (value == null || !value.isFinite() || value < 0.0 || value > 1_000_000_000.0) return null
        return value
    }

    fun firstOutputMs(firstReasoningMs: Int?, firstContentMs: Int?): Int? =
        listOfNotNull(firstReasoningMs, firstContentMs).minOrNull()

    fun tokensPerSecond(
        status: RequestStatus,
        isStreamed: Boolean,
        outputChunkCount: Int,
        completionTokens: Int?,
        firstReasoningMs: Int?,
        firstContentMs: Int?,
        lastOutputMs: Int?
    ): Double? {
        if (status != RequestStatus.SUCCEEDED || !isStreamed || outputChunkCount < 2) return null
        val tokens = completionTokens ?: return null
        if (tokens <= 0) return null
        val first = firstOutputMs(firstReasoningMs, firstContentMs) ?: return null
        val last = lastOutputMs ?: return null
        if (last <= first) return null
        return tokens.toDouble() * 1000.0 / (last - first).toDouble()
    }

    fun estimatedCost(
        promptTokens: Int?,
        completionTokens: Int?,
        cachedTokens: Int?,
        cacheWriteTokens: Int?,
        inputPricePerMillion: Double?,
        outputPricePerMillion: Double?,
        cacheReadPricePerMillion: Double?,
        cacheWritePricePerMillion: Double?,
        currency: String?
    ): Double? {
        if (promptTokens == null || promptTokens < 0 || completionTokens == null || completionTokens < 0) return null
        val inPrice = validPrice(inputPricePerMillion) ?: return null
        val outPrice = validPrice(outputPricePerMillion) ?: return null
        if (currency == null || !supportedCurrencies.contains(currency)) return null

        val readPrice = validPrice(cacheReadPricePerMillion)
        val writePrice = validPrice(cacheWritePricePerMillion)
        val value = if (readPrice != null || writePrice != null) {
            val cachedRead = minOf(maxOf(cachedTokens ?: 0, 0), promptTokens)
            val cacheWrite = minOf(maxOf(cacheWriteTokens ?: 0, 0), maxOf(0, promptTokens - cachedRead))
            val uncachedInput = maxOf(0, promptTokens - cachedRead - cacheWrite)
            val inCost = uncachedInput * inPrice +
                cachedRead * (readPrice ?: inPrice) +
                cacheWrite * (writePrice ?: inPrice)
            (inCost + completionTokens * outPrice) / 1_000_000.0
        } else {
            (promptTokens * inPrice + completionTokens * outPrice) / 1_000_000.0
        }
        return value.takeIf { it.isFinite() }
    }

    fun estimatedCacheSavings(
        promptTokens: Int?,
        cachedTokens: Int?,
        inputPricePerMillion: Double?,
        cacheReadPricePerMillion: Double?
    ): Double? {
        if (promptTokens == null || promptTokens < 0) return null
        val inPrice = validPrice(inputPricePerMillion) ?: return null
        val readPrice = validPrice(cacheReadPricePerMillion) ?: return null
        val cachedRead = cachedTokens ?: return null
        if (cachedRead <= 0 || inPrice <= readPrice) return null
        val effectiveCached = minOf(cachedRead, promptTokens)
        val saved = effectiveCached * (inPrice - readPrice) / 1_000_000.0
        return saved.takeIf { it > 0.0 && it.isFinite() }
    }
}
