package com.iosbox.app

import com.iosbox.app.core.backup.WebDAVEndpointResolver
import com.iosbox.app.core.backup.WebDAVSyncException
import com.iosbox.app.core.model.MonthlyBudgetEvaluator
import com.iosbox.app.core.model.MonthlyBudgetLevel
import com.iosbox.app.core.model.PricingMultiplierPolicy
import com.iosbox.app.ui.chat.BookmarkedEntry
import com.iosbox.app.ui.chat.BookmarksHubFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class Phase3BookmarksBudgetWebDAVTest {

    @Test
    fun bookmarksHubFilterSearchesByQueryTagAndOrdersNewestFirst() {
        val older = BookmarkedEntry(
            messageId = "m1",
            conversationId = "c1",
            conversationTitle = "合同评审",
            folderTag = "工作",
            speaker = "Claude Sonnet",
            content = "周四前提交季度预算总结。",
            createdAtEpochMs = 1_000L
        )
        val newer = BookmarkedEntry(
            messageId = "m2",
            conversationId = "c2",
            conversationTitle = "架构设计",
            folderTag = "技术",
            speaker = "GPT-4.1",
            content = "将预算评估抽取为纯 Kotlin 对象。",
            createdAtEpochMs = 3_000L
        )
        val untagged = BookmarkedEntry(
            messageId = "m3",
            conversationId = "c3",
            conversationTitle = "生活备忘",
            folderTag = null,
            speaker = "Gemini Flash",
            content = "周末采购清单",
            createdAtEpochMs = 2_000L
        )

        val entries = listOf(older, newer, untagged)
        assertEquals(listOf("工作", "技术"), BookmarksHubFilter.availableTags(entries))

        val ordered = BookmarksHubFilter.filter(entries, query = "", tag = null)
        assertEquals(listOf("m2", "m3", "m1"), ordered.map { it.messageId })

        val workOnly = BookmarksHubFilter.filter(entries, query = "", tag = "工作")
        assertEquals(listOf("m1"), workOnly.map { it.messageId })

        val matched = BookmarksHubFilter.filter(entries, query = "预算", tag = null)
        assertEquals(listOf("m2", "m1"), matched.map { it.messageId })
    }

    @Test
    fun pricingMultiplierPolicySanitizesAndScalesPrices() {
        assertEquals(1.0, PricingMultiplierPolicy.sanitize(null), 0.0001)
        assertEquals(1.0, PricingMultiplierPolicy.sanitize(0.0), 0.0001)
        assertEquals(1.0, PricingMultiplierPolicy.sanitize(-2.0), 0.0001)
        assertEquals(1.0, PricingMultiplierPolicy.sanitize(Double.NaN), 0.0001)
        assertEquals(0.01, PricingMultiplierPolicy.sanitize(0.001), 0.0001)
        assertEquals(100.0, PricingMultiplierPolicy.sanitize(300.0), 0.0001)

        assertEquals(1.5, PricingMultiplierPolicy.effectivePrice(3.0, 0.5)!!, 0.0001)
        assertEquals(72.0, PricingMultiplierPolicy.effectivePrice(10.0, 7.2)!!, 0.0001)
        assertEquals(null, PricingMultiplierPolicy.effectivePrice(null, 0.5))
        assertEquals("0.5x", PricingMultiplierPolicy.format(0.5))
        assertEquals("1x", PricingMultiplierPolicy.format(1.0))
        assertEquals("7.2x", PricingMultiplierPolicy.format(7.2))
    }

    @Test
    fun monthlyBudgetEvaluatorTransitionsAcrossThresholds() {
        val spent = mapOf("USD" to 16.5, "CNY" to 12.0)

        val unconfigured = MonthlyBudgetEvaluator.evaluate(spent, limit = 0.0, currency = "USD")
        assertEquals(MonthlyBudgetLevel.UNCONFIGURED, unconfigured.level)

        val normal = MonthlyBudgetEvaluator.evaluate(spent, limit = 30.0, currency = "USD", alertRatio = 0.8)
        assertEquals(MonthlyBudgetLevel.NORMAL, normal.level)
        assertEquals(13.5, normal.remaining, 0.001)

        val warning = MonthlyBudgetEvaluator.evaluate(spent, limit = 20.0, currency = "USD", alertRatio = 0.8)
        assertEquals(MonthlyBudgetLevel.WARNING, warning.level)
        assertEquals(0.825, warning.ratio, 0.001)

        val exceeded = MonthlyBudgetEvaluator.evaluate(spent, limit = 15.0, currency = "USD", alertRatio = 0.8)
        assertEquals(MonthlyBudgetLevel.EXCEEDED, exceeded.level)
        assertEquals(0.0, exceeded.remaining, 0.001)
    }

    @Test
    fun webDAVEndpointResolverValidatesHTTPSPrivateLANTraversalAndBasicAuth() {
        val cloud = WebDAVEndpointResolver.resolve("https://dav.jianguoyun.com/dav", "/Fugue/sync.enc.json")
        assertEquals("https://dav.jianguoyun.com/dav/Fugue/sync.enc.json", cloud.targetUrl)
        assertEquals(listOf("https://dav.jianguoyun.com/dav/Fugue/"), cloud.parentDirectoryUrls)

        val lan = WebDAVEndpointResolver.resolve("http://192.168.1.50:5005/webdav/", "backup.json")
        assertEquals("http://192.168.1.50:5005/webdav/backup.json", lan.targetUrl)
        assertTrue(lan.parentDirectoryUrls.isEmpty())

        try {
            WebDAVEndpointResolver.resolve("http://dav.example.com/dav/", "sync.json")
            fail("Expected InsecurePublicHttp")
        } catch (_: WebDAVSyncException.InsecurePublicHttp) {
            // expected
        }

        try {
            WebDAVEndpointResolver.resolve("https://dav.example.com/dav/", "../escape.json")
            fail("Expected InvalidRemotePath")
        } catch (_: WebDAVSyncException.InvalidRemotePath) {
            // expected
        }

        assertEquals("Basic YWxpY2U6c2VjcmV0", WebDAVEndpointResolver.basicAuthHeader("alice", "secret"))
    }
}
