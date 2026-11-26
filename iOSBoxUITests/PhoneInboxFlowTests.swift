import XCTest

@MainActor
final class PhoneInboxFlowTests: XCTestCase {
    private func launch(_ arguments: [String] = []) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-ui-test-source-layout", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["inbox.resume"].waitForExistence(timeout: 8))
        return app
    }

    func testResumeAndNewQuestionKeepIndependentDrafts() throws {
        let app = try launch()
        let resume = app.buttons["inbox.resume"]
        let newQuestion = app.buttons["inbox.newQuestion"]
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        let original = "帮我把这份走访笔记整理成三个要点。"
        XCTAssertTrue(resume.label.contains(original))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "inbox.recent.")).count, 3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iPhone conversation inbox"
        shot.lifetime = .keepAlways
        add(shot)

        resume.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(input.value as? String, original)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        newQuestion.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertNotEqual(input.value as? String, original)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("An independent question")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.label.contains("An independent question"), resume.label)
        app.buttons["inbox.archive"].tap()
        let old = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", original)).firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 5))
        old.tap()
        XCTAssertEqual(input.value as? String, original)
    }

    func testToolsSearchAndLibraryUseTheInboxRoutes() throws {
        let app = try launch()
        app.buttons["inbox.attach"].tap()
        XCTAssertTrue(app.staticTexts["添加内容"].waitForExistence(timeout: 6), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["inbox.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("访谈笔记对比")
        let hit = app.buttons["打开对话"]
        XCTAssertTrue(hit.waitForExistence(timeout: 6), app.debugDescription)
        hit.tap()
        XCTAssertTrue(app.staticTexts["怎样让一份访谈笔记更容易复用？"].waitForExistence(timeout: 6), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if app.navigationBars.buttons["关闭"].isHittable { app.navigationBars.buttons["关闭"].tap() }
        let library = app.buttons["workspace.tab.library"]
        if !library.isHittable { app.navigationBars.buttons.element(boundBy: 0).tap() }
        library.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5))
        for id in ["books", "presets", "friends"] {
            XCTAssertTrue(app.buttons["workspace.workshop.\(id)"].exists)
        }
        let libraryShot = XCTAttachment(screenshot: app.screenshot())
        libraryShot.name = "iPhone library"
        libraryShot.lifetime = .keepAlways
        add(libraryShot)
        app.buttons["workspace.workshop.books"].tap()
        XCTAssertTrue(app.navigationBars["书架"].waitForExistence(timeout: 5))
    }

    func testEmptyEnglishInboxDoesNotCreateAnUntouchedDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-model-picker", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let empty = app.staticTexts["No conversations yet"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workspace.tab.library"].label, "Library")
        app.buttons["inbox.newQuestion"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["inbox.resume"].exists)
    }

    func testLargeTextKeepsInboxActionsReachableInDarkMode() throws {
        let app = try launch(["-ui-test-dark-appearance", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = "iPhone inbox in dark mode with large text"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(hasDarkCanvas(screenshot), "The visible inbox background should use the dark color scheme.")
        for id in ["inbox.search", "inbox.resume", "inbox.attach", "inbox.newQuestion", "workspace.tab.library"] {
            let control = app.buttons[id]
            XCTAssertTrue(control.isHittable, id)
            // Accessibility returns screen coordinates after a floating-point transform.
            XCTAssertGreaterThanOrEqual(min(control.frame.height, control.frame.width) + 0.000001, 44, id)
        }
    }

    private func hasDarkCanvas(_ screenshot: XCUIScreenshot) -> Bool {
        guard let image = screenshot.image.cgImage,
              let margin = image.cropping(to: CGRect(x: image.width / 100, y: image.height / 2, width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixel = context.data else { return false }
        context.draw(margin, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel.load(as: UInt8.self) < 85
    }
}
