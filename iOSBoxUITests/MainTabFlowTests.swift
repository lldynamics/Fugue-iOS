import XCTest

@MainActor
final class MainTabFlowTests: XCTestCase {
    func testNormalLaunchOpensAllFourTabs() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if app.staticTexts["请解锁设备。受保护的数据可用后，将自动重新打开本地数据库。"].exists {
            app.buttons["重试"].tap()
        }
        if UIDevice.current.userInterfaceIdiom == .phone, !app.navigationBars["夜奔"].exists {
            let history = app.buttons["chat.history"]
            if history.waitForExistence(timeout: 5) { history.tap() }
        }
        var failures: [String] = []
        for (tab, title) in [("对话", "夜奔"), ("工作台", "工作台"), ("设置", "服务商与设置"), ("用量", "用量与测速")] {
            if tab != "对话" {
                let closeModal = app.navigationBars.buttons["完成"]
                if closeModal.exists && closeModal.isHittable {
                    closeModal.tap()
                }
                if UIDevice.current.userInterfaceIdiom == .phone, !app.navigationBars["夜奔"].exists {
                    let history = app.buttons["chat.history"]
                    if history.waitForExistence(timeout: 5) { history.tap() }
                }
                if tab == "设置", UIDevice.current.userInterfaceIdiom == .pad,
                   let settings = app.buttons.matching(identifier: "设置").allElementsBoundByIndex.first(where: \.isHittable) {
                    settings.tap()
                    if app.buttons["服务商与设置"].exists {
                        app.buttons["服务商与设置"].tap()
                    }
                } else if tab == "用量", !app.buttons.matching(NSPredicate(format: "label == %@", "用量")).firstMatch.exists {
                    let settingsBtn = try XCTUnwrap(app.buttons.matching(identifier: "设置").allElementsBoundByIndex.first(where: \.isHittable), "设置")
                    settingsBtn.tap()
                    let ledgerBtn = app.buttons["用量与费用账本"]
                    XCTAssertTrue(ledgerBtn.waitForExistence(timeout: 5))
                    ledgerBtn.tap()
                } else {
                    var matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", tab)).allElementsBoundByIndex
                    if tab == "工作台", let sidebar = app.buttons.matching(identifier: "工作台").allElementsBoundByIndex.first(where: \.isHittable) {
                        matches = [sidebar]
                    }
                    let button = try XCTUnwrap(matches.first(where: \.isHittable), tab)
                    button.tap()
                }
            }
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), title)
            XCTAssertFalse(app.alerts["本地存储提示"].exists)

            if tab == "用量" {
                let completed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "完整 ")).firstMatch
                XCTAssertTrue(completed.waitForExistence(timeout: 5), app.debugDescription)
                let usage = XCTAttachment(screenshot: app.screenshot())
                usage.name = "Usage summary and contrast"
                usage.lifetime = .keepAlways
                add(usage)
            }
            failures += try accessibilityFailures(in: app, tab: tab)
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func accessibilityFailures(in app: XCUIApplication, tab: String) throws -> [String] {
        var observations: [String] = []
        var failures: [String] = []
        var coveredLabels = Set<String>()
        let bottomBar = app.tabBars.allElementsBoundByIndex.first { $0.frame.midY > app.frame.midY }
            ?? app.otherElements.matching(identifier: "workspace.bottomDock").allElementsBoundByIndex.first { $0.frame.midY > app.frame.midY }
        // The floating tab bar / bottom dock also fades content immediately above its frame.
        let readableBottom = bottomBar.map { $0.frame.minY - 16 } ?? app.frame.maxY

        func audit(rechecking labels: Set<String>? = nil) throws {
            try app.performAccessibilityAudit(for: [.hitRegion, .contrast]) { issue in
                let element = issue.element
                let label = element?.label ?? ""
                let detail = "\(issue.compactDescription) · \(label)"
                observations.append(detail)
                if let labels, !labels.contains(label) { return true }
                // XCTest separately reports advisory near-passes for standard system text.
                if issue.auditType == .contrast, issue.compactDescription.contains("nearly passed") { return true }
                if labels == nil, issue.auditType == .contrast, let element, !label.isEmpty,
                   element.frame.maxY >= readableBottom {
                    coveredLabels.insert(label)
                } else {
                    failures.append("\(tab) · \(detail)")
                }
                return true
            }
        }
        try audit()
        if !coveredLabels.isEmpty {
            let dragX = tab == "对话" && UIDevice.current.userInterfaceIdiom == .phone ? 0.38 : 0.5
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: dragX, dy: 0.72))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: dragX, dy: 0.38))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            let top = app.navigationBars.firstMatch.frame.maxY
            for label in coveredLabels {
                let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                let visible = matches.allElementsBoundByIndex.contains { $0.frame.minY >= top && $0.frame.maxY < readableBottom && !$0.frame.isEmpty }
                if !visible { failures.append("\(tab) · Could not recheck unobscured text · \(label)") }
            }
            observations.append("After scrolling covered labels into view")
            try audit(rechecking: coveredLabels)
        }
        let report = XCTAttachment(string: observations.joined(separator: "\n"))
        report.name = "Accessibility \(tab)"
        report.lifetime = .keepAlways
        add(report)
        return failures
    }
}
