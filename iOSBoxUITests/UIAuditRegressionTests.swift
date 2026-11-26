import UIKit
import XCTest

@MainActor
final class UIAuditRegressionTests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUnavailableGroupModelSurvivesOpeningAndSaving() {
        let app = launch(["-ui-test-personas", "-ui-test-model-details", "-ui-audit-stale-group-model"])
        app.openWorkspaceDrawerIfNeeded()
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "失效模型测试群")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), app.debugDescription)
        group.tap()
        let groupTitle = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "失效模型测试群")).firstMatch
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 10), app.debugDescription)
        groupTitle.tap()
        let member = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试成员")).firstMatch
        for _ in 0..<5 where !member.isHittable { app.swipeUp() }
        XCTAssertTrue(member.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(member.label.contains("已移除的服务商"), member.label)
        XCTAssertTrue(member.label.contains("old-model"), member.label)
        XCTAssertTrue(member.label.contains("模型待连接"), member.label)
        app.buttons["保存"].tap()
        XCTAssertTrue(groupTitle.waitForExistence(timeout: 8), app.debugDescription)
        groupTitle.tap()
        let savedMember = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试成员")).firstMatch
        for _ in 0..<5 where !savedMember.isHittable { app.swipeUp() }
        XCTAssertTrue(savedMember.label.contains("已移除的服务商"), savedMember.label)
        XCTAssertTrue(savedMember.label.contains("old-model"), savedMember.label)
    }

    func testExistingEmptyGroupDoesNotApplyDefaultTemplate() {
        let app = launch(["-ui-test-personas", "-ui-test-source-layout"])
        app.openWorkspaceDrawerIfNeeded()
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "读书小组")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), app.debugDescription)
        group.tap()
        let title = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "读书小组")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        title.tap()
        let hint = app.staticTexts["该群暂无成员，请选择上方模板或手动添加成员。"]
        for _ in 0..<4 where !hint.isHittable { app.swipeUp() }
        XCTAssertTrue(hint.exists, app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "林晓")).firstMatch.exists)
        XCTAssertFalse(app.buttons["保存"].isEnabled)
        capture("Empty group remains empty", app: app)
    }

    func testTinyUsageAndMissingCurrencyAreNotShownAsZeroOrUSD() {
        let app = launch(["-ui-audit-incomplete-currency", "-ui-audit-tiny-cost"])
        let workshop = app.buttons["workspace.tab.library"]
        if workshop.isHittable { workshop.tap() }
        app.buttons["用量"].tap()
        let amount = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "USD <")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 10), app.debugDescription)
        capture("Small nonzero estimate", app: app)
        let close = app.navigationBars["用量与测速"].buttons["完成"]
        if close.isHittable { close.tap() }
        app.openWorkspaceSettings()
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "币种缺失测试")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10), app.debugDescription)
        provider.tap()
        let price = app.buttons["legacy-pricing 的单价：单价未完整设置"]
        for _ in 0..<6 where !price.isHittable { app.swipeUp() }
        XCTAssertTrue(price.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(price.frame.height, 44)
        capture("Incomplete currency", app: app)
    }

    func testProviderSwitchesAndCapabilitiesHaveNamesStatesAndHitTargets() throws {
        let app = launch(["-ui-test-personas", "-ui-test-model-details"])
        app.openWorkspaceSettings()
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本地模型")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10), app.debugDescription)
        provider.tap()
        let enabled = app.switches["provider.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(enabled.label.contains("启用该服务商"), enabled.label)
        XCTAssertFalse(app.buttons["1x"].exists)
        var relatedIssues: [String] = []
        func auditVisibleControls() throws {
            let contentTop = app.navigationBars.firstMatch.frame.maxY
            let contentBottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            try app.performAccessibilityAudit(for: [.hitRegion, .contrast]) { issue in
                guard let element = issue.element, element.isHittable else { return true }
                guard element.frame.minY >= contentTop, element.frame.maxY <= contentBottom else { return true }
                let name = element.label
                if name == "启用 sample-a" || name.hasPrefix("sample-a 的") || name == "识图" || name == "思考链" || name.contains("USD 0.1/1") || name == "批量操作" {
                    relatedIssues.append("\(issue.auditType): \(issue.compactDescription) · \(name) · \(element.frame)")
                }
                return true
            }
        }
        try auditVisibleControls()
        let vision = app.buttons["sample-a 的识图能力"]
        for _ in 0..<6 where !vision.isHittable { app.swipeUp() }
        XCTAssertTrue(vision.isHittable, app.debugDescription)
        let modelSwitch = app.switches["启用 sample-a"]
        XCTAssertTrue(modelSwitch.exists, app.debugDescription)
        XCTAssertEqual(vision.value as? String, "已开启")
        for item in [vision, app.buttons["sample-a 的思考能力"], app.buttons["sample-a 的单价：USD 0.1/1"]] {
            XCTAssertTrue(item.exists, app.debugDescription)
            XCTAssertGreaterThanOrEqual(item.frame.width, 44)
            XCTAssertGreaterThanOrEqual(item.frame.height, 44)
            XCTAssertLessThan(item.frame.height, 65, "A normal-size label should not be squeezed into a tall icon-only control: \(item.label)")
        }
        XCTAssertGreaterThan(vision.frame.width, 50)
        XCTAssertGreaterThan(app.buttons["sample-a 的思考能力"].frame.width, 60)
        XCTAssertGreaterThan(app.buttons["sample-a 的单价：USD 0.1/1"].frame.width, 80)
        try auditVisibleControls()
        XCTAssertTrue(relatedIssues.isEmpty, relatedIssues.joined(separator: "\n"))
        vision.tap()
        XCTAssertEqual(vision.value as? String, "已关闭")
        capture("Accessible model controls", app: app)
    }

    func testSearchEmptyStateCanBeCleared() {
        let app = launch(["-ui-test-personas", "-ui-test-model-details"])
        if app.buttons["inbox.resume"].exists { app.buttons["inbox.resume"].tap() }
        if !app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch.exists {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "新对话")).firstMatch.tap()
        }
        app.buttons["chatComposer.model"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), app.debugDescription)
        search.tap()
        search.typeText("nomatchingmodel123")
        XCTAssertTrue(app.staticTexts["没有匹配的模型"].waitForExistence(timeout: 8), app.debugDescription)
        let clear = app.buttons["清除搜索"]
        XCTAssertTrue(clear.exists, app.debugDescription)
        clear.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sample-a")).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testEmptyPresetsAndBookActionsAreIdentifiable() {
        let app = launch(["-ui-test-personas", "-ui-test-source-layout"])
        app.openWorkspaceLibrary()
        app.selectWorkshopSection("助手预设")
        XCTAssertTrue(app.staticTexts["暂无助手预设"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["新建助手"].firstMatch.exists)
        app.selectWorkshopSection("书架")
        XCTAssertTrue(app.buttons["开始阅读《山路手记》"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["开始阅读《走访笔记》"].exists)
        XCTAssertTrue(app.buttons["《山路手记》的书籍操作"].exists)
        XCTAssertTrue(app.buttons["《走访笔记》的书籍操作"].exists)
    }

    func testLargeTypeRoundtablesHaveRoomForTitlesAndActions() {
        let app = launch(["-ui-test-personas", "-iosbox.pref.moduleGroupChatEnabled", "NO", "-iosbox.pref.simpleDailyMode", "NO",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        app.openWorkspaceLibrary()
        app.setOptionalModule("optionalModules.roundtables", enabled: true)
        app.selectWorkshopSection("圆桌")
        let title = app.staticTexts["创业点子审委会"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        let start = app.buttons["开始 创业点子审委会 圆桌对话"]
        XCTAssertTrue(start.exists)
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityLarge))
        let fullTitleWidth = (title.label as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(title.frame.width + 2, fullTitleWidth)
        XCTAssertGreaterThanOrEqual(start.frame.minY, title.frame.maxY)
        XCTAssertGreaterThanOrEqual(start.frame.height, 44)
        capture("Roundtables with large text", app: app)
    }

    func testLargeTypeModelControlsStackVertically() {
        let app = launch(["-ui-test-personas", "-ui-test-model-details", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        app.openWorkspaceSettings()
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本地模型")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 10), app.debugDescription)
        provider.tap()
        let vision = app.buttons["sample-a 的识图能力"]
        for _ in 0..<12 where !vision.isHittable { app.swipeUp() }
        XCTAssertTrue(vision.isHittable, app.debugDescription)
        let price = app.buttons["sample-a 的单价：USD 0.1/1"]
        let reasoning = app.buttons["sample-a 的思考能力"]
        XCTAssertTrue(price.exists && reasoning.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(vision.frame.minY, price.frame.maxY - 1)
        XCTAssertGreaterThanOrEqual(reasoning.frame.minY, vision.frame.maxY - 1)
        XCTAssertGreaterThanOrEqual(vision.frame.height, 44)
        capture("Model controls with large text", app: app)
    }
}
