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
        for (tab, title) in [("对话", "夜奔"), ("好友", "好友与书架"), ("服务商", "服务商与设置"), ("用量", "用量与测速")] {
            if tab != "对话" {
                var matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", tab)).allElementsBoundByIndex
                if tab == "好友", let sidebar = app.buttons.matching(identifier: "好友与书架").allElementsBoundByIndex.first(where: \.isHittable) {
                    matches = [sidebar]
                }
                let button = try XCTUnwrap(matches.first(where: \.isHittable), tab)
                button.tap()
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
        // The floating tab bar also fades content immediately above its frame.
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
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.73))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.41))
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
