import XCTest

@MainActor
extension XCUIApplication {
    func selectWorkshopSection(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
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
