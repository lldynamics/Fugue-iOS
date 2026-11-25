package com.iosbox.app.ui

import com.iosbox.app.core.model.APIProtocolType
import com.iosbox.app.core.model.ModelSpec
import com.iosbox.app.core.model.GroupMember
import com.iosbox.app.core.model.GroupRoomTemplate
import com.iosbox.app.core.model.ResolvedModelTarget
import com.iosbox.app.core.model.RequestKind
import com.iosbox.app.core.model.RequestStatus
import com.iosbox.app.core.storage.RequestRecordItem
import com.iosbox.app.ui.chat.configuredModelRates
import com.iosbox.app.ui.chat.displayRate
import com.iosbox.app.ui.chat.initialGroupMembers
import com.iosbox.app.ui.usage.compactTokens
import com.iosbox.app.ui.usage.summarizeUsageCosts
import com.iosbox.app.ui.usage.summarizeUsageTokens
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class UsageAndModelDisplayTest {
    @Test
    fun modelPricesRequireBothValidRatesAndACurrency() {
        val model = ModelSpec(id = "example", inputPricePerMillion = 0.0, priceCurrency = "USD")
        assertNull(configuredModelRates(model))
        val configured = model.copy(outputPricePerMillion = 0.0000001)
        assertEquals(0.0, configuredModelRates(configured)!!.input, 0.0)
        assertNotEquals("0", displayRate(configuredModelRates(configured)!!.output))
        assertEquals("10", displayRate(10.0))
        assertEquals("1E-12", displayRate(0.000000000001))
        assertNull(configuredModelRates(configured.copy(outputPricePerMillion = Double.NaN)))
        assertNull(configuredModelRates(configured.copy(outputPricePerMillion = -1.0)))
        assertNull(configuredModelRates(configured.copy(priceCurrency = "UNKNOWN")))
    }

    @Test
    fun usageSeparatesCurrenciesAndDoesNotCountUnknownAsFree() {
        val usd = record().copy(currency = "USD", inputPricePerMillion = 1.0, outputPricePerMillion = 2.0)
        val cny = usd.copy(id = "cny", currency = "CNY", inputPricePerMillion = 3.0)
        val free = usd.copy(id = "free", inputPricePerMillion = 0.0, outputPricePerMillion = 0.0)
        val missingPrice = usd.copy(id = "missing-price", outputPricePerMillion = null)
        val missingUsage = usd.copy(id = "missing-usage", promptTokens = null)
        val pending = missingPrice.copy(id = "pending", status = RequestStatus.RUNNING)
        val blocked = missingPrice.copy(id = "blocked", status = RequestStatus.BLOCKED)
        val search = missingPrice.copy(id = "search", kind = RequestKind.WEB_SEARCH)
        val result = summarizeUsageCosts(listOf(usd, cny, free, missingPrice, missingUsage, pending, blocked, search))
        assertEquals(setOf("USD", "CNY"), result.totals.keys)
        assertEquals(0.0003, result.totals.getValue("USD"), 0.00000001)
        assertEquals(0.0005, result.totals.getValue("CNY"), 0.00000001)
        assertEquals(2, result.missingCount)
    }

    @Test
    fun tokenTotalsRemainPositivePastIntLimit() {
        val rows = List(2_300) { record().copy(promptTokens = 1_000_000, completionTokens = 100_000, cachedTokens = 50_000) }
        val result = summarizeUsageTokens(rows + record().copy(promptTokens = -2, completionTokens = -3))
        assertEquals(2_300_000_000L, result.input)
        assertEquals(230_000_000L, result.output)
        assertEquals(115_000_000L, result.cached)
        assertEquals(2_530_000_000L, result.total)
        assertEquals("2.5B", compactTokens(result.total))
        assertEquals("3.0B", compactTokens(3_000_000_000L))
        assertEquals("1.2K", compactTokens(1_200L))
    }

    @Test
    fun existingEmptyAndUnavailableGroupMembersAreNeverReplacedByDefaults() {
        val template = GroupRoomTemplate.builtInTemplates.first()
        val available = ResolvedModelTarget("new", "New", APIProtocolType.OPEN_AI_COMPATIBLE, "new-model", "New model", "#000000", false, false)
        val old = available.copy(providerID = "old", modelID = "old-model")
        val original = GroupMember(name = "Member", target = old)
        assertEquals(emptyList<GroupMember>(), initialGroupMembers(emptyList(), template, listOf(available)))
        assertEquals(listOf(original), initialGroupMembers(listOf(original), template, listOf(available)))
        assertEquals(template.seats.size, initialGroupMembers(null, template, listOf(available)).size)
    }

    private fun record() = RequestRecordItem(
        id = "usd", operationID = "op", attempt = 1, conversationID = "conversation", messageID = "message",
        providerID = "provider", providerName = "Provider", modelID = "model", modelDisplayName = "Model",
        protocolType = APIProtocolType.OPEN_AI_COMPATIBLE, kind = RequestKind.ANSWER, status = RequestStatus.SUCCEEDED,
        startedAtEpochMs = 0, endedAtEpochMs = 1000, firstReasoningMs = null, firstContentMs = null,
        lastOutputMs = null, durationMs = 1000, outputChunkCount = 0, isStreamed = false,
        promptTokens = 100, completionTokens = 100, cachedTokens = null, cacheWriteTokens = null,
        httpStatus = 200, inputPricePerMillion = null, outputPricePerMillion = null,
        cacheReadPricePerMillion = null, cacheWritePricePerMillion = null, currency = null
    )
}
