import XCTest

@MainActor
final class OptionalModuleFlowTests: XCTestCase {
    func testDisabledEnglishModuleStillOpensItsExistingJournal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-ui-test-learning-journal",
                               "-iosbox.pref.moduleEnglishCoachEnabled", "NO",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad { app.openWorkspaceDrawerIfNeeded() }
        app.openWorkspaceLibrary()
        let manage = app.buttons["library.optionalModules"]
        for _ in 0..<3 where !manage.isHittable { app.swipeUp() }
        manage.tap()
        XCTAssertEqual(app.switches["optionalModules.english"].value as? String, "0")
        app.buttons["学习日志"].tap()
        XCTAssertTrue(app.staticTexts["Archived lesson"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testEnableEnglishFromLibraryOpenStudyAndTurnItOffAgain() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-iosbox.pref.moduleEnglishCoachEnabled", "NO",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .pad { app.openWorkspaceDrawerIfNeeded() }
        app.openWorkspaceLibrary()
        let studyShortcut = app.buttons["workspace.workshop.study"]
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        if isPhone { XCTAssertFalse(studyShortcut.exists) }

        app.setOptionalModule("optionalModules.english", enabled: true)
        app.selectWorkshopSection("学习")
        let tutor = app.buttons["AI 英语私教"]
        XCTAssertTrue(tutor.waitForExistence(timeout: 5), app.debugDescription)
        tutor.tap()
        XCTAssertTrue(app.staticTexts["语习私教"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(tutor.waitForExistence(timeout: 5), app.debugDescription)
        if isPhone {
            app.navigationBars["学习"].buttons["完成"].tap()
        } else {
            app.selectWorkshopSection("书架")
        }
        app.setOptionalModule("optionalModules.english", enabled: false)
        XCTAssertFalse(studyShortcut.exists)
        XCTAssertFalse(tutor.exists)
        if !isPhone {
            let categories = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "分类")).firstMatch
            if categories.isHittable { categories.tap() }
            XCTAssertFalse(app.buttons["学习"].exists)
        }
    }
}
