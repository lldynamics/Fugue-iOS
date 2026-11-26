import XCTest

@MainActor final class ModelWorkshopFlowTests: XCTestCase {
    func testEditSelectedRectangleAndSlideComparisonOnIPad() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Hardware acceptance only")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_REGION_UI_FIXTURE"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "真机验收 · 选区改图")).firstMatch
        if !chat.isHittable { app.openWorkspaceDrawerIfNeeded() }
        chat.tap()
        app.buttons["attachment.editRegion"].firstMatch.tap()
        let canvas = app.descendants(matching: .any).matching(identifier: "regionEditor.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 6))
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.75))
        start.press(forDuration: 0.15, thenDragTo: end)
        XCTAssertFalse((canvas.value as? String ?? "").isEmpty, "Drag must leave a nonempty selection")
        let field = app.textFields["描述选区内的修改"]
        field.tap(); field.typeText("Change the selected red rectangle to solid blue.")
        app.buttons["regionEditor.dismissKeyboard"].tap()
        let send = app.buttons["regionEditor.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let toggle = app.switches["与编辑前对照"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 90))
        for _ in 0..<4 where !canvas.isHittable { app.swipeDown() }
        let before = canvas.value as? String
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)).press(forDuration: 0.12,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.50)))
        XCTAssertNotEqual(canvas.value as? String, before)
        let proof = XCTAttachment(screenshot: canvas.screenshot())
        proof.name = "Foreground version comparison"; proof.lifetime = .keepAlways; add(proof)
        #endif
    }

    func testLiveVoiceOnForegroundIPad() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Interactive acceptance requires a physical device")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_LIVE_MIC_ACCEPTANCE"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.openWorkspaceSettings()
        let entry = app.buttons["实时语音"]
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        let start = app.buttons["liveVoice.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let status = app.staticTexts["liveVoice.status"]
        XCTAssertTrue(status.wait(for: \.label, toEqual: "正在通话 · 可以直接插话", timeout: 35))
        print("FUGUE_UI_MIC connected")
        let response = app.staticTexts["liveVoice.transcript.assistant"].firstMatch
        let responding = response.waitForExistence(timeout: 35)
        if responding { print("FUGUE_UI_MIC model answered") }
        let indicator = app.staticTexts["liveVoice.interruptions"]
        let interrupted = indicator.waitForExistence(timeout: 80)
        let blue = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND (label CONTAINS[c] %@ OR label CONTAINS %@)", "liveVoice.transcript.assistant", "blue", "蓝")).firstMatch
        let panelX = (status.frame.midX - app.frame.minX) / app.frame.width
        func scrollPanel(from: CGFloat, to: CGFloat) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: panelX, dy: from))
            start.press(forDuration: 0.08, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: panelX, dy: to)))
        }
        var answered = false
        for _ in 0..<7 where interrupted && !answered {
            answered = blue.waitForExistence(timeout: 2)
            if !answered { scrollPanel(from: 0.82, to: 0.36) }
        }
        let finish = app.buttons["结束通话"]
        for _ in 0..<6 where !finish.isHittable { scrollPanel(from: 0.35, to: 0.85) }
        finish.tap()
        XCTAssertTrue(interrupted, "No interruption of pending playback")
        XCTAssertTrue(answered, "No follow-up about blue")
        let newCall = app.buttons["开始新通话"]
        for _ in 0..<5 where !newCall.exists { scrollPanel(from: 0.82, to: 0.35) }
        XCTAssertTrue(newCall.waitForExistence(timeout: 5), "Transcript was not saved")
        #endif
    }

    func testOpenAIPracticeControlsOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an iPad and an external speaker")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_PRACTICE_SPEAKER_FIXTURE"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.openWorkspaceSettings()
        let entry = app.buttons["实时语音"]
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        app.buttons["liveVoice.practice"].tap()
        let mode = app.buttons["practice.turnMode"]
        if mode.exists, (mode.label + (mode.value as? String ?? "")).contains("点按") {
            mode.tap()
            let option = app.menuItems["自动插话"]
            (option.exists ? option : app.buttons["自动插话"].firstMatch).tap()
        }
        let start = app.buttons["practice.start"]
        for _ in 0..<5 where !start.isHittable { app.swipeUp() }
        start.tap()
        let handoff = app.buttons["practice.switchToTap"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 35))
        let tutor = app.staticTexts["liveVoice.transcript.assistant"].firstMatch
        XCTAssertTrue(tutor.waitForExistence(timeout: 12))
        handoff.tap()
        let turn = app.buttons["practice.takeTurn"]
        XCTAssertTrue(turn.waitForExistence(timeout: 10))
        turn.tap()
        XCTAssertTrue(turn.wait(for: \.label, toEqual: "说完了", timeout: 6))
        print("FUGUE_PRACTICE manual")
        fflush(nil)
        let learner = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND (label CONTAINS[c] %@ OR label CONTAINS[c] %@)", "liveVoice.transcript.user", "notebook", "bookstore")).firstMatch
        XCTAssertFalse(learner.waitForExistence(timeout: 7))
        turn.tap()
        XCTAssertTrue(learner.waitForExistence(timeout: 20))
        let original = learner.label
        let finish = app.buttons["practice.finish"]
        for _ in 0..<4 where !finish.isHittable { app.swipeDown() }
        finish.tap()
        let source = app.buttons["practice.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 55))
        XCTAssertFalse(source.label.isEmpty)
        XCTAssertTrue(original.contains(source.label), "The review must quote the learner's recorded turn")
        source.tap()
        XCTAssertTrue(app.staticTexts[original].firstMatch.waitForExistence(timeout: 10))
        #endif
    }

    func testBlindVoteWithTwoRealModelsOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real model acceptance requires a physical device")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_DEVICE_ACCEPTANCE"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.openWorkspaceSettings()
        let entry = app.buttons["盲测题库"]
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        let field = app.descendants(matching: .any).matching(identifier: "modelWorkshop.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let panelX = (field.frame.midX - app.frame.minX) / app.frame.width
        func scrollResults() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: panelX, dy: 0.84))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: panelX, dy: 0.30))
            start.press(forDuration: 0.08, thenDragTo: end)
        }
        for name in ["gpt-6.2-sol", "gpt-6.2-astra"] {
            let row = app.switches.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            XCTAssertTrue(row.isHittable)
            let nested = row.switches.firstMatch
            (nested.exists ? nested : row).tap()
        }
        field.tap()
        field.typeText("Return only the result of 6 times 7.")
        app.buttons["modelWorkshop.dismissKeyboard"].tap()
        let run = app.buttons["modelWorkshop.run"]
        for _ in 0..<4 where !run.isHittable { scrollResults() }
        run.tap()
        let vote = app.buttons["modelWorkshop.vote.0"]
        for _ in 0..<12 where !vote.isHittable {
            if !vote.waitForExistence(timeout: 2) || !vote.isHittable { scrollResults() }
        }
        XCTAssertTrue(vote.isHittable)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "42").count, 2)
        vote.tap()
        let selection = app.staticTexts["modelWorkshop.selection"]
        for _ in 0..<5 where !selection.exists { scrollResults() }
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertTrue(selection.label.contains("回答 1"), selection.label)
        #endif
    }

    func testPracticeHistoryLinksOriginalSpeechAndSchedulesNextLesson() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-ui-test-voice-practice", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.openWorkspaceSettings()
        let entry = app.buttons["实时语音"]
        for _ in 0..<6 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        app.buttons["liveVoice.practice"].tap()
        XCTAssertTrue(app.navigationBars["语言陪练"].waitForExistence(timeout: 6))
        let history = app.buttons["practice.history"]
        for _ in 0..<4 where !history.isHittable { app.swipeUp() }
        history.tap()
        app.buttons["practice.record"].firstMatch.tap()
        let usage = app.buttons["practice.usage.practiceVoice"]
        for _ in 0..<3 where !usage.isHittable { app.swipeUp() }
        XCTAssertTrue(usage.exists)
        usage.tap()
        XCTAssertTrue(app.staticTexts["fixture-voice"].exists)
        let inputTokens = app.descendants(matching: .any)["practice.usage.input.practiceVoice"]
        XCTAssertEqual(inputTokens.value as? String, "25")
        usage.tap()
        let schedule = app.buttons["practice.schedule"]
        for _ in 0..<3 where !schedule.isHittable { app.swipeUp() }
        schedule.tap()
        XCTAssertEqual(schedule.label, "移出复习")
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "Practice review and original quote"
        proof.lifetime = .keepAlways
        add(proof)
        app.buttons["practice.source"].tap()
        XCTAssertTrue(app.staticTexts["Yesterday I go to the bookstore."].firstMatch.waitForExistence(timeout: 6))
        for destination in ["练习复盘", "练习记录", "语言陪练"] {
            let bar = app.navigationBars.buttons
            let back = bar.matching(NSPredicate(format: "identifier == %@ AND label == %@", "BackButton", destination)).firstMatch
            (back.exists ? back : bar["BackButton"].firstMatch).tap()
        }
        XCTAssertTrue(app.navigationBars["语言陪练"].waitForExistence(timeout: 5))
        let due = app.staticTexts["Yesterday I went"]
        for _ in 0..<3 where !due.isHittable { app.swipeUp() }
        XCTAssertTrue(due.exists)
        #else
        throw XCTSkip("Isolated simulator fixture")
        #endif
    }

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
