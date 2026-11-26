import XCTest

@MainActor
extension XCUIApplication {
    func openWorkspaceDrawerIfNeeded(file: StaticString = #filePath, line: UInt = #line) {
        if navigationBars["历史"].exists || navigationBars["夜奔"].exists { return }
        if UIDevice.current.userInterfaceIdiom == .phone {
            let inbox = buttons["inbox.search"]
            let chatsTab = buttons["workspace.tab.conversation"]
            if !inbox.isHittable {
                if chatsTab.isHittable { chatsTab.tap() }
                else { navigationBars.buttons.element(boundBy: 0).tap() }
            }
            if !navigationBars["历史"].exists {
                let archive = buttons["inbox.archive"]
                (archive.isHittable ? archive : inbox).tap()
            }
            XCTAssertTrue(navigationBars["历史"].waitForExistence(timeout: 5), debugDescription, file: file, line: line)
            return
        }
        let history = buttons["chat.history"]
        if history.isHittable {
            history.tap()
            let list = navigationBars.matching(NSPredicate(format: "identifier IN %@", ["历史", "夜奔"])).firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 5), debugDescription, file: file, line: line)
        }
    }

    func openWorkspaceLibrary(file: StaticString = #filePath, line: UInt = #line) {
        if UIDevice.current.userInterfaceIdiom == .phone {
            let library = buttons["workspace.tab.library"]
            if !library.isHittable { openWorkspaceDrawerIfNeeded(file: file, line: line) }
            library.tap()
        } else {
            buttons["工作台"].tap()
        }
    }

    func openWorkspaceSettings(file: StaticString = #filePath, line: UInt = #line) {
        let workshopTab = buttons["workspace.tab.library"]
        let phoneSettings = buttons["workspace.settings"]
        if workshopTab.isHittable && !phoneSettings.isHittable { workshopTab.tap() }
        if phoneSettings.isHittable {
            phoneSettings.tap()
        } else {
            let settings = buttons["设置"].firstMatch
            if !settings.isHittable { openWorkspaceDrawerIfNeeded(file: file, line: line) }
            XCTAssertTrue(settings.isHittable, debugDescription, file: file, line: line)
            guard settings.isHittable else { return }
            settings.tap()
            if buttons["服务商与设置"].isHittable { buttons["服务商与设置"].tap() }
        }
        XCTAssertTrue(navigationBars["服务商与设置"].waitForExistence(timeout: 5), debugDescription, file: file, line: line)
    }

    func selectWorkshopSection(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let destinations = ["好友": "friends", "书架": "books",
                            "助手预设": "presets", "圆桌": "roundtables", "学习": "study"]
        if let section = destinations[title], buttons["workspace.settings"].isHittable {
            let shortcut = buttons["workspace.workshop.\(section)"]
            for _ in 0..<4 where !shortcut.isHittable { swipeUp() }
            XCTAssertTrue(shortcut.isHittable, debugDescription, file: file, line: line)
            if shortcut.isHittable { shortcut.tap() }
            return
        }
        let segment = buttons[title].firstMatch
        let categories = descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "分类"))
            .firstMatch

        for _ in 0..<4 where !segment.isHittable && !categories.isHittable {
            swipeDown()
        }
        if segment.isHittable {
            segment.tap()
            return
        }

        XCTAssertTrue(categories.isHittable, debugDescription, file: file, line: line)
        guard categories.isHittable else { return }
        categories.tap()

        let option = descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), debugDescription, file: file, line: line)
        if option.exists { option.tap() }
    }
}
