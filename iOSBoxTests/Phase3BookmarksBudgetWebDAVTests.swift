import XCTest
@testable import iOSBox

final class Phase3BookmarksBudgetWebDAVTests: XCTestCase {

    func testBookmarksHubFilterMatchesQueryTagAndSortsNewestFirst() {
        let older = BookmarkedMessageEntry(
            id: UUID(),
            conversationID: UUID(),
            conversationTitle: "合同评审纪要",
            folderTag: "工作",
            speaker: "Claude Sonnet",
            content: "本周四前提交 Q4 预算清单与风险点。",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newer = BookmarkedMessageEntry(
            id: UUID(),
            conversationID: UUID(),
            conversationTitle: "Swift 架构讨论",
            folderTag: "研发",
            speaker: "GPT-4.1",
            content: "建议将预算检查逻辑拆分为纯函数以便单测。",
            createdAt: Date(timeIntervalSince1970: 1_700_005_000)
        )
        let untagged = BookmarkedMessageEntry(
            id: UUID(),
            conversationID: UUID(),
            conversationTitle: "日常灵感",
            folderTag: nil,
            speaker: "Gemini 2.5 Pro",
            content: "周末采购清单：咖啡豆与滤纸。",
            createdAt: Date(timeIntervalSince1970: 1_700_002_000)
        )

        let entries = [older, newer, untagged]
        XCTAssertEqual(BookmarksHubFilter.availableTags(from: entries), ["工作", "研发"])

        let all = BookmarksHubFilter.filter(entries, query: "", tag: nil)
        XCTAssertEqual(all.map(\.id), [newer.id, untagged.id, older.id])

        let workOnly = BookmarksHubFilter.filter(entries, query: "", tag: "工作")
        XCTAssertEqual(workOnly.map(\.id), [older.id])

        let byQuery = BookmarksHubFilter.filter(entries, query: "预算", tag: nil)
        XCTAssertEqual(byQuery.map(\.id), [newer.id, older.id])
    }

    func testNewRequestUsesModelRatesAndRestoredRequestKeepsSavedRates() throws {
        var claudeSpec = ModelSpec(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4")
        let preset = try XCTUnwrap(ModelPricingCatalog.match(modelID: claudeSpec.id))
        ModelPricingCatalog.apply(preset, to: &claudeSpec)

        let target = ResolvedModelTarget(
            providerID: UUID(),
            providerName: "Discount Relay",
            protocolType: .anthropic,
            modelID: claudeSpec.id,
            modelDisplayName: claudeSpec.displayName,
            accentHex: "#D97757",
            supportsVision: true,
            supportsReasoning: true
        )

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
        record.finish(.succeeded, elapsedMs: 900)

        XCTAssertEqual(try XCTUnwrap(record.estimatedCost), 0.1215, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(record.estimatedCacheSavings), 0.2085, accuracy: 0.000_001)

        var legacy = record.snapshot
        legacy.id = UUID()
        legacy.inputPricePerMillion = 1.5
        legacy.outputPricePerMillion = 7.5
        legacy.cacheReadPricePerMillion = 0.15
        legacy.cacheWritePricePerMillion = 1.875
        let data = try JSONEncoder().encode(legacy)
        let restored = RequestRecord(snapshot: try JSONDecoder().decode(RequestRecord.Snapshot.self, from: data))
        XCTAssertEqual(try XCTUnwrap(restored.estimatedCost), 0.06075, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(restored.estimatedCacheSavings), 0.10425, accuracy: 0.000_001)
    }

    func testMonthlyBudgetEvaluatorDetectsUnconfiguredNormalWarningAndExceeded() {
        let spent = ["USD": 16.5, "CNY": 12.0]

        let unconfigured = MonthlyBudgetEvaluator.evaluate(spentByCurrency: spent, limit: 0, currency: "USD")
        XCTAssertEqual(unconfigured.level, .unconfigured)

        let normal = MonthlyBudgetEvaluator.evaluate(spentByCurrency: spent, limit: 30, currency: "USD", alertRatio: 0.8)
        XCTAssertEqual(normal.level, .normal)
        XCTAssertEqual(normal.remaining, 13.5, accuracy: 0.001)

        let warning = MonthlyBudgetEvaluator.evaluate(spentByCurrency: spent, limit: 20, currency: "USD", alertRatio: 0.8)
        XCTAssertEqual(warning.level, .warning)
        XCTAssertEqual(warning.ratio, 0.825, accuracy: 0.001)

        let exceeded = MonthlyBudgetEvaluator.evaluate(spentByCurrency: spent, limit: 15, currency: "USD", alertRatio: 0.8)
        XCTAssertEqual(exceeded.level, .exceeded)
        XCTAssertEqual(exceeded.remaining, 0, accuracy: 0.001)
    }

    func testWebDAVEndpointValidationAndBasicAuthRejectsPublicHTTPAndTraversal() throws {
        let resolved = try WebDAVSyncService.resolvedTarget(
            serverURL: "https://dav.jianguoyun.com/dav",
            remotePath: "/Fugue/fugue-sync.enc.json"
        )
        XCTAssertEqual(resolved.targetURL.absoluteString, "https://dav.jianguoyun.com/dav/Fugue/fugue-sync.enc.json")
        XCTAssertEqual(resolved.parentDirectories.map(\.absoluteString), ["https://dav.jianguoyun.com/dav/Fugue/"])

        let lan = try WebDAVSyncService.resolvedTarget(
            serverURL: "http://192.168.1.50:5005/webdav/",
            remotePath: "sync.enc.json"
        )
        XCTAssertEqual(lan.targetURL.absoluteString, "http://192.168.1.50:5005/webdav/sync.enc.json")
        XCTAssertTrue(lan.parentDirectories.isEmpty)

        XCTAssertThrowsError(
            try WebDAVSyncService.resolvedTarget(serverURL: "http://dav.example.com/dav/", remotePath: "sync.json")
        ) { error in
            XCTAssertEqual(error as? WebDAVSyncError, .insecurePublicHTTP)
        }

        XCTAssertThrowsError(
            try WebDAVSyncService.resolvedTarget(serverURL: "https://dav.example.com/dav/", remotePath: "../escape.json")
        ) { error in
            XCTAssertEqual(error as? WebDAVSyncError, .invalidRemotePath)
        }

        XCTAssertEqual(
            WebDAVSyncService.basicAuthHeader(username: "alice", password: "secret"),
            "Basic YWxpY2U6c2VjcmV0"
        )
    }
}
