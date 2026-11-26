import XCTest

@MainActor
final class ProductUpgradeFlowTests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        return app
    }

    func testOfflineSampleOpensReaderWithoutConfiguringAModel() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let app = launch(["-ui-test-empty-workspace"])
        let sample = app.buttons["library.sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 8), app.debugDescription)
        sample.tap()
        XCTAssertTrue(app.buttons["reading.chapters"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "东岸的石阶")).firstMatch.exists)
    }

    func testGlobalSearchQuotesLocatedBookPassageIntoNewDraft() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let app = launch()
        app.buttons["inbox.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), app.debugDescription)
        search.tap()
        search.typeText("晒茶的竹匾")
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "山路手记", "溪边的旧路")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10), app.debugDescription)
        book.tap()
        let highlight = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "reading.highlight", "晒茶的竹匾")).firstMatch
        XCTAssertTrue(highlight.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(highlight.label.contains("晒茶的竹匾"), highlight.label)
        app.buttons["reading.quote"].tap()
        let destination = app.buttons["在新对话中提问"]
        XCTAssertTrue(destination.waitForExistence(timeout: 6), app.debugDescription)
        destination.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 8), app.debugDescription)
        let quote = app.staticTexts["chatComposer.quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 6), app.debugDescription)
        for part in ["山路手记", "溪边的旧路", "晒茶的竹匾"] { XCTAssertTrue(quote.label.contains(part), quote.label) }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Source quotation in unsent chat draft"
        image.lifetime = .keepAlways
        add(image)
    }

    func testCreateDiscussionFromTwoExistingBooks() {
        let app = launch(["-ui-test-source-layout"])
        app.openWorkspaceLibrary()
        app.selectWorkshopSection("书架")
        app.buttons["用一组资料新建对话"].tap()
        let first = app.buttons["山路手记"]
        XCTAssertTrue(first.waitForExistence(timeout: 6), app.debugDescription)
        first.tap()
        app.buttons["走访笔记"].tap()
        let create = app.buttons["library.createDiscussion"]
        XCTAssertTrue(create.isEnabled, app.debugDescription)
        create.tap()
        XCTAssertTrue(app.navigationBars["用一组资料新建对话"].waitForNonExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    func testExportPreviewsFileBeforeSharing() {
        let app = launch()
        app.openWorkspaceDrawerIfNeeded()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "访谈笔记对比")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        chat.tap()
        app.buttons["更多操作"].tap()
        app.buttons["分享与导出"].tap()
        XCTAssertTrue(app.navigationBars["分享与导出"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertEqual(app.switches["系统提示词"].value as? String, "0")
        app.buttons["预览导出文件"].tap()
        XCTAssertTrue(app.navigationBars["导出预览"].waitForExistence(timeout: 8), app.debugDescription)
    }
}
