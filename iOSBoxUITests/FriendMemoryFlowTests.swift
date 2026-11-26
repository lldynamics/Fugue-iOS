import XCTest

@MainActor
final class FriendMemoryFlowTests: XCTestCase {
    private func launchFriendsWorkspace() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-workspaces",
            "-ui-test-source-layout",
            "-ui-test-personas",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN"
        ]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.buttons["inbox.resume"].waitForExistence(timeout: 8), app.debugDescription)
            let friendsTab = app.buttons["workspace.tab.friends"]
            XCTAssertTrue(friendsTab.waitForExistence(timeout: 5), app.debugDescription)
            friendsTab.tap()
            if !app.navigationBars["好友"].waitForExistence(timeout: 3) {
                friendsTab.tap()
            }
            XCTAssertTrue(app.navigationBars["好友"].waitForExistence(timeout: 5), app.debugDescription)
        } else {
            app.openWorkspaceLibrary()
            app.selectWorkshopSection("好友")
        }
        return app
    }

    func testPersonaMemoryFlowsBetweenFriendsListAndPrivateChat() {
        let app = launchFriendsWorkspace()

        let openMemoryButton = app.buttons["林舟 的好友记忆"]
        XCTAssertTrue(openMemoryButton.waitForExistence(timeout: 6), app.debugDescription)
        openMemoryButton.tap()

        let sheetNav = app.navigationBars["好友持续记忆"]
        XCTAssertTrue(sheetNav.waitForExistence(timeout: 6), app.debugDescription)

        let addEntryButton = app.buttons["friendMemory.addEntry"]
        XCTAssertTrue(addEntryButton.waitForExistence(timeout: 5), app.debugDescription)
        addEntryButton.tap()

        let entryInput = app.descendants(matching: .any).matching(identifier: "friendMemory.newEntryInput").firstMatch
        XCTAssertTrue(entryInput.waitForExistence(timeout: 5), app.debugDescription)
        entryInput.tap()
        entryInput.typeText("每周日清晨在东山步道观鸟")

        let confirmAdd = app.buttons["friendMemory.confirmAddEntry"]
        XCTAssertTrue(confirmAdd.isEnabled)
        confirmAdd.tap()

        XCTAssertTrue(app.staticTexts["每周日清晨在东山步道观鸟"].waitForExistence(timeout: 5), app.debugDescription)

        let editSummaryButton = app.buttons["friendMemory.editSummary"]
        XCTAssertTrue(editSummaryButton.waitForExistence(timeout: 5), app.debugDescription)
        editSummaryButton.tap()

        let summaryField = app.descendants(matching: .any).matching(identifier: "friendMemory.summaryInput").firstMatch
        XCTAssertTrue(summaryField.waitForExistence(timeout: 5), app.debugDescription)
        summaryField.tap()
        summaryField.typeText("常交流田野观察手记")
        app.navigationBars["编辑关系小结"].buttons["保存"].tap()

        XCTAssertTrue(app.staticTexts["常交流田野观察手记"].waitForExistence(timeout: 5), app.debugDescription)

        sheetNav.buttons["完成"].tap()

        let privateChatButton = app.buttons["与 林舟 私聊"]
        for _ in 0..<20 where sheetNav.exists || !privateChatButton.isHittable {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTAssertTrue(privateChatButton.isHittable, app.debugDescription)
        privateChatButton.tap()

        let chatMemoryToolbarButton = app.buttons["chat.friendMemory"]
        XCTAssertTrue(chatMemoryToolbarButton.waitForExistence(timeout: 6), app.debugDescription)
        chatMemoryToolbarButton.tap()

        XCTAssertTrue(app.navigationBars["好友持续记忆"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["常交流田野观察手记"].waitForExistence(timeout: 5), app.debugDescription)
        let syncedEntry = app.staticTexts["每周日清晨在东山步道观鸟"]
        for _ in 0..<3 where !syncedEntry.exists {
            app.swipeUp()
        }
        XCTAssertTrue(syncedEntry.exists, app.debugDescription)

        let clearAll = app.buttons["friendMemory.clearAll"]
        for _ in 0..<3 where !clearAll.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(clearAll.waitForExistence(timeout: 5), app.debugDescription)
        clearAll.tap()

        let confirmClear = app.buttons["清空全部记忆"]
        XCTAssertTrue(confirmClear.waitForExistence(timeout: 5), app.debugDescription)
        confirmClear.tap()

        XCTAssertFalse(app.staticTexts["每周日清晨在东山步道观鸟"].exists)
        app.navigationBars["好友持续记忆"].buttons["完成"].tap()
    }

    func testBookFriendMemorySheetDisplaysChapterScopeAndToggles() {
        let app = launchFriendsWorkspace()

        let bookFriendMemoryButton = app.buttons["旅人 的好友记忆"]
        for _ in 0..<3 where !bookFriendMemoryButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(bookFriendMemoryButton.waitForExistence(timeout: 6), app.debugDescription)
        bookFriendMemoryButton.tap()

        let sheetNav = app.navigationBars["好友持续记忆"]
        XCTAssertTrue(sheetNav.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "山路手记", "启程")).firstMatch.exists,
            app.debugDescription
        )

        let enableToggle = app.switches["friendMemory.enableToggle"]
        let autoExtractToggle = app.switches["friendMemory.autoExtractToggle"]
        XCTAssertTrue(enableToggle.exists)
        XCTAssertTrue(autoExtractToggle.exists)

        sheetNav.buttons["完成"].tap()
    }
}
