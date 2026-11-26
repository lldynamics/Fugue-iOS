import XCTest

@MainActor final class ModelWorkshopFlowTests: XCTestCase {
    func testSemanticShelfSearchLeadsToTheMatchingPassage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-ui-test-source-layout", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.openWorkspaceLibrary()
        app.selectWorkshopSection("书架")
        app.buttons["书架语义检索"].tap()
        let toggle = app.switches["山路手记"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 6), app.debugDescription)
        let nested = toggle.switches.firstMatch
        (nested.exists ? nested : toggle).tap()
        let field = app.textFields["用自己的话描述要找的内容"]
        field.tap()
        field.typeText("晒茶的竹匾")
        app.buttons["按意思搜索"].tap()
        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "山路手记", "溪边的旧路")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 12), app.debugDescription)
        hit.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "reading.highlight", "晒茶的竹匾")).firstMatch.waitForExistence(timeout: 6))
    }

    func testPersonalQuestionPersistsWithoutRunningPaidModels() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.openWorkspaceDrawerIfNeeded()
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "山路手记")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), app.debugDescription)
        chat.tap()
        let sample = "作者怎样写出雨后的变化？"
        let question = app.staticTexts[sample].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 8), app.debugDescription)
        question.press(forDuration: 1)
        app.buttons["存入盲测题库"].tap()
        let save = app.buttons["仅保存题目"]
        XCTAssertTrue(save.waitForExistence(timeout: 6))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["删除这道题"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.openWorkspaceSettings()
        let entry = app.buttons["盲测题库"]
        for _ in 0..<6 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable, app.debugDescription)
        entry.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "题目")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", sample)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
    }
}
