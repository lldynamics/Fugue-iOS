import XCTest

@MainActor
final class ReadingAndBallotFlowTests: XCTestCase {
    private func launch(personas: Bool = false, sourceLayout: Bool = false, showHistory: Bool = true,
                        extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let original = XCUIDevice.shared.orientation
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = original }
        }
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if personas { app.launchArguments.append("-ui-test-personas") }
        if sourceLayout { app.launchArguments.append("-ui-test-source-layout") }
        app.launchArguments += extraArguments
        app.launch()
        if showHistory { app.openWorkspaceDrawerIfNeeded() }
        else if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["inbox.resume"].tap() }
        return app
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    func testOpenSavedWritingWorkspaceAndCancelSetup() {
        let app = launch()
        let draft = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "草稿", "走访笔记整理成三个要点")).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 8), app.debugDescription)
        capture("Draft shown in chat history")
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        if UIDevice.current.userInterfaceIdiom == .phone || !input.isHittable { draft.tap() }
        XCTAssertTrue(input.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(input.value as? String, "帮我把这份走访笔记整理成三个要点。")
        XCTAssertEqual(app.buttons.matching(identifier: "chatComposer.model").count, 1)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let model = app.buttons["chatComposer.model"]
            XCTAssertTrue(model.label.contains("连接模型"), model.label)
            verifyModelPosition(model, in: app, tabletTopFraction: 0.25)
        }
        capture("Writing-workspace")
        app.buttons["chatComposer.model"].tap()
        app.navigationBars["连接模型"].buttons["取消"].tap()
        XCTAssertEqual(input.value as? String, "帮我把这份走访笔记整理成三个要点。")
    }

    func testOpenComparisonPickerFromTheWritingEditorAndKeepTheDraft() {
        let app = launch(personas: true, showHistory: false,
                         extraArguments: ["-ui-test-model-details", "-iosbox.pref.simpleDailyMode", "YES"])
        XCTAssertFalse(app.buttons["双盲对比"].exists)
        let input = tapWritingDraftControl(app.buttons["chatComposer.compareModels"], in: app)
        let picker = app.navigationBars["选择并发对比模型"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertLessThan(picker.frame.midY, app.frame.height * 0.25)
        }
        picker.buttons["关闭"].tap()
        XCTAssertEqual(input.value as? String, "帮我把这份走访笔记整理成三个要点。")
    }

    func testModelPickerExplainsUnconfiguredPrices() {
        let app = launch(personas: true, showHistory: false, extraArguments: ["-ui-test-model-details"])
        let input = tapWritingDraftControl(app.buttons["chatComposer.model"], in: app)
        let picker = app.navigationBars["切换对话模型"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        let price = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "单价未完整设置")).firstMatch
        XCTAssertTrue(price.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "USD 输入", "输出")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["识图"].exists)
        XCTAssertTrue(app.staticTexts["思考"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "模型能力可能根据名称推测")).firstMatch.exists)
        capture("Model details in picker")
        picker.buttons["关闭"].tap()
        XCTAssertEqual(input.value as? String, "帮我把这份走访笔记整理成三个要点。")
    }

    private func tapWritingDraftControl(_ control: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let expected = "帮我把这份走访笔记整理成三个要点。"
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        if UIDevice.current.userInterfaceIdiom == .pad, !input.exists || input.value as? String != expected {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                                                      "草稿", "走访笔记整理成三个要点")).firstMatch
            if !row.isHittable { app.openWorkspaceDrawerIfNeeded() }
            XCTAssertTrue(row.waitForExistence(timeout: 8), app.debugDescription)
            row.tap()
        }
        let loaded = NSPredicate(format: "exists == true AND hittable == true AND value == %@", expected)
        wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: input)], timeout: 10)
        input.tap()
        input.typeText("x" + XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(input.value as? String, expected)

        var previousLayout: [CGRect]?
        let settled = NSPredicate { _, _ in
            guard input.isHittable, control.exists, control.isHittable else {
                previousLayout = nil
                return false
            }
            let window = app.frame
            let keyboard = app.keyboards.firstMatch
            let keyboardFrame = keyboard.exists ? keyboard.frame.intersection(window) : CGRect.null
            let button = control.frame
            let center = CGPoint(x: button.midX, y: button.midY)
            guard window.contains(center), !keyboardFrame.contains(center) else {
                previousLayout = nil
                return false
            }
            let layout = [input.frame, button, keyboardFrame]
            defer { previousLayout = layout }
            return layout == previousLayout
        }
        wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 12)
        // Use the observed position. XCUIElement.tap() can scroll a toolbar or composer
        // control after the keyboard moves and compute an offscreen hit point.
        let button = control.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: button.midX - app.frame.minX,
                                                                        dy: button.midY - app.frame.minY)).tap()
        return input
    }

    func testComposerUsesOneWebMenuAndOneVoiceMenu() {
        let app = launch(personas: true, showHistory: false, extraArguments: ["-ui-test-model-details"])
        let drawer = app.buttons["添加附件与能力"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 8), app.debugDescription)
        drawer.tap()

        let web = app.buttons["chatComposer.webMode"]
        XCTAssertTrue(web.waitForExistence(timeout: 5))
        web.tap()
        app.buttons["搜索"].tap()
        XCTAssertTrue(web.label.contains("联网"))
        web.tap()
        app.buttons["关闭搜索"].tap()
        XCTAssertEqual(web.label, "联网")

        let voice = app.buttons["chatComposer.voice"]
        XCTAssertTrue(voice.exists)
        voice.tap()
        XCTAssertTrue(app.buttons["语音输入"].exists)
        app.buttons["chatComposer.liveCall"].tap()
        let call = app.navigationBars["实时通话"]
        XCTAssertTrue(call.waitForExistence(timeout: 8), app.debugDescription)
        call.buttons["关闭"].tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()
        app.buttons["音频纪要"].tap()
        XCTAssertTrue(app.navigationBars["录音与音频转会议纪要"].waitForExistence(timeout: 8))
    }

    func testSaveParagraphNoteAndReturnToItsOriginalPassage() throws {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch.tap()
        if app.buttons["reading.open"].exists { app.buttons["reading.open"].tap() }
        let notes = app.buttons["reading.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(notes.isHittable)
        XCTAssertGreaterThanOrEqual(notes.frame.width, 44)
        XCTAssertGreaterThanOrEqual(notes.frame.height, 44)
        let paragraph = app.staticTexts["reading.paragraph.0"]
        XCTAssertTrue(paragraph.waitForExistence(timeout: 8))
        XCTAssertEqual(paragraph.label, "山路从村口开始。")
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.50)).press(forDuration: 1.0)
        let savePassage = app.buttons["摘录与批注"]
        XCTAssertTrue(savePassage.waitForExistence(timeout: 5), app.debugDescription)
        savePassage.tap()
        let note = app.descendants(matching: .any).matching(identifier: "reading.noteText").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 6))
        note.tap()
        note.typeText("A walking route")
        app.navigationBars.buttons["保存"].tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 6))
        notes.tap()
        let entry = app.staticTexts["A walking route"]
        XCTAssertTrue(entry.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.staticTexts["山路从村口开始。"].exists)
        XCTAssertTrue(app.staticTexts["启程"].exists)
        app.buttons["回到原文"].tap()
        let highlight = app.staticTexts["reading.highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(highlight.label.contains("山路从村口开始。"))

        highlight.coordinate(withNormalizedOffset: CGVector(dx: 0.13, dy: 0.50)).press(forDuration: 1.0)
        app.buttons["选择文本"].tap()
        let selectedText = app.textViews["reading.selectText"]
        XCTAssertTrue(selectedText.waitForExistence(timeout: 6), app.debugDescription)
        let saveSelection = app.buttons["reading.saveSelection"]
        XCTAssertFalse(saveSelection.isEnabled)
        selectedText.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 36, dy: 25)).press(forDuration: 1)
        XCTAssertTrue(saveSelection.isEnabled, app.debugDescription)
        saveSelection.tap()
        let selectedExcerpt = app.staticTexts["reading.noteExcerpt"]
        XCTAssertTrue(selectedExcerpt.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(selectedExcerpt.label.isEmpty)
        XCTAssertLessThan(selectedExcerpt.label.count, "山路从村口开始。".count)
        XCTAssertTrue("山路从村口开始。".contains(selectedExcerpt.label))
        app.navigationBars.buttons["保存"].tap()
        notes.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "回到原文").count, 2)
        capture("Reading notebook with a paragraph and a selected passage")
    }

    func testReturnToShelfAndStartAReadingConversation() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch.tap()
        if app.buttons["reading.open"].exists { app.buttons["reading.open"].tap() }
        let chapters = app.buttons["reading.chapters"]
        XCTAssertTrue(chapters.waitForExistence(timeout: 8), app.debugDescription)
        let next = app.buttons["reading.nextChapter"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(next.label.contains("溪边的旧路"))
        capture("Next chapter at the end of the text")
        next.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "退回石阶下")).firstMatch.waitForExistence(timeout: 5))
        let location = app.staticTexts["reading.location"]
        XCTAssertTrue(location.label.contains("山路手记"), location.label)
        XCTAssertTrue(location.label.contains("溪边的旧路"), location.label)
        XCTAssertFalse(next.exists)
        let shelf = app.buttons["reading.bookshelf"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 8), app.debugDescription)
        shelf.tap()
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "继续阅读《")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["shelf.progress"].label.contains("溪边的旧路"), app.debugDescription)
        read.tap()
        XCTAssertTrue(app.buttons["reading.chapters"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "退回石阶下")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let close = app.navigationBars["原文"].buttons["完成"]
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertLessThan(close.frame.midY, app.frame.height * 0.2, "从书架续读应使用整页")
        }
        if close.exists { close.tap() }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch.waitForExistence(timeout: 5))
    }

    func testBeforeSendingShowsBoundBookAndAllowsSkippingIt() {
        let app = launch(personas: true)
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch.tap()
        let sources = app.buttons["composer.knowledge"]
        XCTAssertTrue(sources.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(sources.label.contains("山路手记"), sources.label)
        let model = app.buttons["chatComposer.model"]
        XCTAssertTrue(model.isHittable)
        verifyModelPosition(model, in: app, tabletTopFraction: 0.25)
        if app.buttons["reading.open"].exists {
            XCTAssertEqual(sources.frame.midY, app.buttons["reading.open"].frame.midY, accuracy: 5)
        }
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        input.tap()
        input.typeText("draft")
        model.tap()
        let other = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sample-b")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 8), app.debugDescription)
        other.tap()
        XCTAssertTrue(model.label.contains("sample-b"), model.label)
        XCTAssertEqual(input.value as? String, "draft")

        sources.tap()
        let skip = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "本次不使用知识库")).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(sources.label.contains("已关闭"), sources.label)
        sources.tap()
        app.buttons["管理参考资料"].tap()
        let library = app.navigationBars["本地参考知识库"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.buttons["完成"].tap()
        XCTAssertTrue(sources.label.contains("已关闭"))
        XCTAssertEqual(input.value as? String, "draft")
    }

    private func verifyModelPosition(_ model: XCUIElement, in app: XCUIApplication, tabletTopFraction: CGFloat) {
        XCTAssertEqual(app.buttons.matching(identifier: "chatComposer.model").count, 1)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
            XCTAssertGreaterThan(model.frame.midY, app.frame.height * 0.5)
            XCTAssertLessThanOrEqual(model.frame.maxY, input.frame.minY + 1)
        } else {
            XCTAssertLessThan(model.frame.midY, app.frame.height * tabletTopFraction)
        }
    }

    func testPhoneFollowUpQuotesAnswerAndKeepsDraftWhenChangingModel() throws {
        let app = try openPhoneReply()
        let followUp = app.buttons["reply.followUp"]
        XCTAssertTrue(followUp.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["reply.regenerate"].exists)
        app.buttons["reply.more"].tap()
        let regenerate = app.buttons["重答"]
        XCTAssertTrue(regenerate.waitForExistence(timeout: 4), app.debugDescription)
        regenerate.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "原模型重答")).firstMatch.waitForExistence(timeout: 4), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.15)).tap()
        capture("Reply actions and model above input")
        followUp.tap()
        let quote = app.staticTexts["chatComposer.quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(quote.label.contains("山路手记 · 溪边的旧路"), quote.label)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        input.typeText("draft")
        let model = app.buttons["chatComposer.model"]
        model.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sample-b")).firstMatch.tap()
        XCTAssertTrue(model.label.contains("sample-b"), model.label)
        XCTAssertEqual(input.value as? String, "draft")
        XCTAssertTrue(quote.exists)
        app.buttons["移除引用"].tap()
        XCTAssertFalse(quote.exists)
        XCTAssertEqual(input.value as? String, "draft")
    }

    private func openPhoneReply() throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let app = launch(personas: true)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "山路手记")).firstMatch.tap()
        return app
    }

    private func selectWords(in paragraph: XCUIElement) throws -> String {
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        let body = try XCTUnwrap(paragraph.value as? String)
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.18)).press(forDuration: 1)
        return body
    }

    private func verifySelectedQuote(in app: XCUIApplication, from body: String) {
        let quote = app.staticTexts["chatComposer.quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(quote.label.isEmpty)
        XCTAssertNotEqual(quote.label, body)
        XCTAssertTrue(body.contains(quote.label), quote.label)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    func testPhoneFollowUpQuotesOnlySelectedText() throws {
        let app = try openPhoneReply()
        let body = try selectWords(in: app.textViews.matching(identifier: "reply.paragraph").firstMatch)
        let action = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "追问")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        action.tap()
        verifySelectedQuote(in: app, from: body)
        capture("Follow up on selected words")
    }

    func testPhoneReplyFooterUsesActiveSelection() throws {
        let app = try openPhoneReply()
        let body = try selectWords(in: app.textViews.matching(identifier: "reply.paragraph").firstMatch)
        app.buttons["reply.followUp"].tap()
        verifySelectedQuote(in: app, from: body)
    }

    func testPhoneCanQuoteSelectionFromFullReplySheet() throws {
        let app = try openPhoneReply()
        app.buttons["reply.more"].tap()
        app.buttons["选择文本"].tap()
        let quoteSelection = app.buttons["reply.quoteSelection"]
        XCTAssertTrue(quoteSelection.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(quoteSelection.isEnabled)
        let text = app.textViews["reply.selectText"]
        let body = try XCTUnwrap(text.value as? String)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.08)).press(forDuration: 1)
        XCTAssertTrue(quoteSelection.isEnabled)
        quoteSelection.tap()
        verifySelectedQuote(in: app, from: body)
    }

    func testPhoneComparisonKeepsRegenerateOnAnswer() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        let app = launch(personas: true)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "访谈笔记")).firstMatch.tap()
        let regenerate = app.buttons.matching(identifier: "reply.regenerate").firstMatch
        XCTAssertTrue(regenerate.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertFalse(app.buttons["reply.followUp"].exists)
        XCTAssertFalse(app.buttons["chatComposer.model"].exists)
    }

    func testBookFriendKeepsSeparateProgressAndModelControls() {
        let app = launch(sourceLayout: true)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "旅人私聊")).firstMatch.tap()
        let progress = app.buttons["bookChat.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        let model = app.buttons["chatComposer.model"]
        XCTAssertTrue(model.isHittable)
        verifyModelPosition(model, in: app, tabletTopFraction: 0.35)
        XCTAssertFalse(app.buttons["composer.knowledge"].exists)
        let open = app.buttons["reading.open"]
        if open.exists { open.tap() }
        let chapterProgress = app.staticTexts["reading.progress"]
        XCTAssertTrue(chapterProgress.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertFalse(app.buttons["reading.nextChapter"].exists)
        XCTAssertFalse(app.staticTexts["溪边的旧路"].exists)
        let done = app.navigationBars["原文"].buttons["完成"]
        if done.exists { done.tap() }
        progress.tap()
        XCTAssertTrue(app.navigationBars["阅读进度"].waitForExistence(timeout: 5))
    }

    func testReplyActionsRemainUsableAtLargeType() {
        let app = launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
                                          "-iosbox.pref.fontScale", "1.18"])
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "山路手记")).firstMatch.tap()
        let more = app.buttons["reply.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8), app.debugDescription)
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8), app.debugDescription)
        let composerTop = UIDevice.current.userInterfaceIdiom == .phone ? app.buttons["chatComposer.model"] : input
        for _ in 0..<3 where !more.isHittable || more.frame.maxY > composerTop.frame.minY {
            app.swipeUp()
        }
        XCTAssertLessThanOrEqual(more.frame.maxY, composerTop.frame.minY, app.debugDescription)
        let primaryAction = UIDevice.current.userInterfaceIdiom == .phone ? "reply.followUp" : "reply.regenerate"
        for id in ["reply.copy", primaryAction, "reply.more"] {
            let item = app.buttons[id]
            XCTAssertTrue(item.isHittable, id)
            XCTAssertGreaterThanOrEqual(item.frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(item.frame.height, 44, id)
        }
        XCTAssertFalse(app.buttons["朗读回复"].exists)
        capture("Reply actions with large text")
        more.tap()
        for title in ["朗读回复", "选择文本", "复制 Markdown 原文"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 4), title)
        }
    }

    func testLargeTextKeepsConversationTitlesSeparateFromBadges() {
        let app = launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let title = app.staticTexts["访谈笔记对比"]
        let badge = app.staticTexts["对比"]
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(badge.exists)
        XCTAssertGreaterThan(title.frame.width, app.frame.width * 0.35)
        XCTAssertGreaterThanOrEqual(badge.frame.minY, title.frame.maxY - 1)
        capture("Conversation titles at large text")
    }

    func testNewTopicKeepsDraftAndEarlierMessages() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch.tap()
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8), app.debugDescription)
        input.tap()
        input.typeText("保留这份草稿")
        app.buttons["添加附件与能力"].tap()
        XCTAssertTrue(app.staticTexts["添加内容"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["对话与发送设置"].exists)
        let settings = app.scrollViews["composer.tools.settings"]
        let newTopic = app.buttons["开始新话题"]
        for _ in 0..<4 where !newTopic.isHittable { settings.swipeLeft() }
        XCTAssertTrue(newTopic.isHittable, app.debugDescription)
        newTopic.tap()
        XCTAssertTrue(app.staticTexts["已清除上文，以下开启新话题"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["作者怎样写出雨后的变化？"].exists)
        XCTAssertEqual(input.value as? String, "保留这份草稿")
    }

    func testDirectoryShowsPeopleAndBookFriendsAndKeepsShelfSeparate() {
        let app = launch(personas: true, sourceLayout: true, extraArguments: ["-iosbox.pref.moduleGroupChatEnabled", "YES", "-iosbox.pref.moduleEnglishCoachEnabled", "YES"])
        app.openWorkspaceDrawerIfNeeded()
        app.openWorkspaceLibrary()
        app.selectWorkshopSection("好友")
        XCTAssertTrue(app.buttons["林舟"].waitForExistence(timeout: 8), app.debugDescription)
        let bookFriend = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "旅人", "山路手记")).firstMatch
        XCTAssertTrue(bookFriend.exists, app.debugDescription)
        capture("People and book friends together")
        let invitation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "friend.invite.")).firstMatch
        if !invitation.isHittable { app.swipeUp() }
        invitation.tap()
        XCTAssertTrue(app.navigationBars["邀请进群"].waitForExistence(timeout: 5))
        app.navigationBars["邀请进群"].buttons["取消"].tap()
        app.selectWorkshopSection("书架")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "开始阅读《")).firstMatch.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["林舟"].exists)
        app.selectWorkshopSection("学习")
        XCTAssertTrue(app.buttons["AI 英语私教"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["新建闪卡"].exists)
    }

    private func openUsage(in app: XCUIApplication) {
        app.openWorkspaceSettings()
        app.buttons["用量与费用账本"].tap()
    }

    func testUnpricedRequestShowsItsCountAndPricingState() {
        let app = launch(extraArguments: ["-ui-test-unpriced-usage"])
        openUsage(in: app)
        XCTAssertTrue(app.staticTexts["未定价"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["完整 1"].exists)
        XCTAssertFalse(app.staticTexts["usage.empty"].exists)
    }

    func testSettingsCanOpenBothProviderAndUsage() {
        let app = launch(personas: true)
        app.openWorkspaceSettings()
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本地模型")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 8), app.debugDescription)
        provider.tap()
        let details = app.navigationBars["本地模型"]
        XCTAssertTrue(details.waitForExistence(timeout: 8), app.debugDescription)
        details.buttons.firstMatch.tap()
        let usage = app.buttons["用量与费用账本"]
        XCTAssertTrue(usage.waitForExistence(timeout: 8), app.debugDescription)
        usage.tap()
        XCTAssertTrue(app.navigationBars["用量与测速"].waitForExistence(timeout: 8), app.debugDescription)
    }

    func testMixedPricingKeepsUnpricedRequestsVisibleBesideTheEstimate() {
        let app = launch(extraArguments: ["-ui-test-unpriced-usage", "-ui-test-mixed-pricing",
                                          "-iosbox.pref.monthlyBudgetLimit", "1.2", "-iosbox.pref.monthlyBudgetCurrency", "USD",
                                          "-iosbox.pref.monthlyBudgetAlertRatio", "0.8"])
        openUsage(in: app)
        XCTAssertTrue(app.staticTexts["另有 1 次未定价"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["完整 2"].exists)
        let warning = app.buttons["usage.budgetWarning"]
        XCTAssertTrue(warning.label.contains("已接近本月预算上限"), app.debugDescription)
        capture("Mixed pricing and monthly budget warning")
    }

    func testUsageSummaryPrecedesFiltersAndDistinguishesAnEmptyMonth() {
        let app = launch()
        openUsage(in: app)
        let empty = app.staticTexts["usage.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(empty.label, "本月还没有请求")
        let filters = app.buttons["usage.filters"]
        XCTAssertLessThan(app.staticTexts["请求次数"].firstMatch.frame.midY, filters.frame.midY)
        XCTAssertFalse(app.buttons["上个月"].exists)
        capture("Usage summary before filters")
        filters.tap()
        app.buttons["上个月"].tap()
        XCTAssertEqual(empty.label, "该月没有请求")
        app.buttons["下个月"].tap()
        XCTAssertEqual(empty.label, "本月还没有请求")
        app.buttons["usage.budget"].tap()
        XCTAssertTrue(app.navigationBars["设置月度预算"].waitForExistence(timeout: 5))
    }

    func testGroupKnowledgeMenuListsAllBoundBooksInTheToolbar() {
        let app = launch(sourceLayout: true)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "读书小组")).firstMatch.tap()
        let sources = app.buttons["composer.knowledge"]
        XCTAssertTrue(sources.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertLessThan(sources.frame.midY, app.frame.height * 0.25)
        XCTAssertTrue(sources.label.contains("山路手记") && sources.label.contains("走访笔记"), sources.label)
        XCTAssertFalse(app.buttons["chatComposer.model"].exists)
        sources.tap()
        let skip = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "本次不使用知识库")).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(sources.label.contains("已关闭"))
    }

    func testSettingsListConfiguredModelsAndDirectoryOpensPrivatePersona() throws {
        let app = launch(personas: true)
        app.openWorkspaceSettings()
        app.buttons["新对话默认设置"].tap()
        let model = app.buttons["newChat.defaultModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), app.debugDescription)
        model.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sample-b")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertTrue(app.buttons["newChat.defaultAssistant"].exists)
        app.navigationBars["新对话默认设置"].buttons.firstMatch.tap()
        let closeSettings = app.navigationBars["服务商与设置"].buttons["完成"]
        if closeSettings.isHittable { closeSettings.tap() }
        app.openWorkspaceLibrary()
        app.selectWorkshopSection("好友")
        let person = app.buttons["林舟"]
        XCTAssertTrue(person.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["与 林舟 私聊"].isHittable)
        app.buttons["邀请 林舟 进群"].tap()
        XCTAssertTrue(app.buttons["创建新群"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars["邀请进群"].buttons["取消"].tap()
        app.buttons["与 林舟 私聊"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["chatComposer.model"].label.contains("sample-b"), app.debugDescription)
    }

    func testDeletingAChatRequiresConfirmationAndCancelPreservesHistory() {
        let app = launch()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), app.debugDescription)
        func requestDeletion() {
            chat.press(forDuration: 1)
            let delete = app.buttons["删除"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5))
            delete.tap()
        }
        requestDeletion()
        let confirmation = app.alerts["删除这段对话？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["取消"].tap()
        XCTAssertTrue(chat.exists)
        requestDeletion()
        confirmation.buttons["删除"].tap()
        XCTAssertTrue(chat.waitForNonExistence(timeout: 5))
        let undo = app.buttons["history.undoDeletion"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), app.debugDescription)
        undo.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 5), app.debugDescription)
    }

    func testInspectorOpensSourceUsedByLatestReply() {
        let app = launch()
        app.openWorkspaceDrawerIfNeeded()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), app.debugDescription)
        chat.tap()
        let inspector = app.buttons["chat.inspector"]
        XCTAssertTrue(inspector.waitForExistence(timeout: 8), app.debugDescription)
        inspector.tap()
        let source = app.buttons["reading.citation.1"]
        for _ in 0..<3 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable, app.debugDescription)
        source.tap()
        XCTAssertTrue(app.staticTexts["reading.highlight"].waitForExistence(timeout: 8), app.debugDescription)
        app.buttons["reading.quote"].tap()
        XCTAssertTrue(app.staticTexts["chatComposer.quote"].label.contains("路边的草倒向同一侧"))
    }

    func testCitationOpensOriginalAndQuotesIntoSameChat() {
        let app = launch()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), app.debugDescription)
        chat.tap()
        // A passage already linked inline as a footnote is not repeated in a "found N passages" list.
        let citation = app.links["〔原文 1〕"]
        XCTAssertTrue(citation.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["找到 1 段相关原文"].exists)
        citation.tap()
        XCTAssertTrue(app.staticTexts["reading.highlight"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["reading.highlight"].label.contains("草倒向同一侧"))
        let location = app.staticTexts["reading.location"]
        XCTAssertTrue(location.label.contains("山路手记"), location.label)
        XCTAssertTrue(location.label.contains("溪边的旧路"), location.label)
        capture("Source-and-conversation")
        app.buttons["reading.quote"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let quote = app.staticTexts["chatComposer.quote"]
        XCTAssertTrue(quote.label.contains("山路手记") && quote.label.contains("溪边的旧路") && quote.label.contains("路边的草倒向同一侧"), quote.label)
        XCTAssertTrue(input.isHittable)
        XCTAssertGreaterThanOrEqual(input.frame.minY, quote.frame.maxY)
        XCTAssertLessThan(input.frame.minY - quote.frame.maxY, 80, "The quote should stay next to the input instead of filling the conversation.")
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.openWorkspaceDrawerIfNeeded()
            XCTAssertTrue(app.navigationBars["历史"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
    }

    func testInlineCitationOpensItsPassageWithoutExpandingRetrievedSources() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch.tap()
        let open = app.buttons["reading.open"]
        if open.exists { open.tap() }
        XCTAssertTrue(app.staticTexts["山路从村口开始。"].waitForExistence(timeout: 8), app.debugDescription)
        let done = app.navigationBars["原文"].buttons["完成"]
        if done.exists { done.tap() }
        let citation = app.links["〔原文 1〕"]
        XCTAssertTrue(citation.waitForExistence(timeout: 8), app.debugDescription)
        citation.tap()
        let highlight = app.staticTexts["reading.highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(highlight.label.contains("草倒向同一侧"))
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertGreaterThan(done.frame.midY, app.frame.height * 0.3, "聊天里查原文应从半屏打开")
        }
        app.buttons["reading.bookshelf"].tap()
        let progress = app.staticTexts["shelf.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(progress.label.contains("启程"), "临时查阅原文不应改写书架的阅读位置")
    }
}
