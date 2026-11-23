import XCTest

@MainActor
final class ReadingAndBallotFlowTests: XCTestCase {
    private func launch(personas: Bool = false, sourceLayout: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
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
        if !input.exists { draft.tap() }
        XCTAssertTrue(input.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(input.value as? String, "帮我把这份走访笔记整理成三个要点。")
        XCTAssertEqual(app.buttons.matching(identifier: "chatComposer.model").count, 1)
        capture("Writing-workspace")
        app.buttons["chatComposer.model"].tap()
        app.navigationBars["连接模型"].buttons["取消"].tap()
        XCTAssertEqual(input.value as? String, "帮我把这份走访笔记整理成三个要点。")
    }

    func testChooseBlindModeFromTheWritingEditorAndKeepTheDraft() {
        let app = launch()
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        if !input.exists {
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "新对话")).firstMatch.tap()
        }
        app.buttons["单聊"].tap()
        app.buttons["双盲对比"].tap()
        let picker = app.navigationBars["选择并发对比模型"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        picker.buttons["关闭"].tap()
        XCTAssertEqual(input.value as? String, "帮我把这份走访笔记整理成三个要点。")
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
        XCTAssertFalse(next.exists)
        let shelf = app.buttons["reading.bookshelf"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 8), app.debugDescription)
        shelf.tap()
        let read = app.buttons["继续阅读"]
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
        XCTAssertLessThan(model.frame.midY, app.frame.height * 0.25)
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

    func testBookFriendKeepsSeparateProgressAndModelControls() {
        let app = launch(sourceLayout: true)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "旅人私聊")).firstMatch.tap()
        let progress = app.buttons["bookChat.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        let model = app.buttons["chatComposer.model"]
        XCTAssertTrue(model.isHittable)
        XCTAssertLessThan(model.frame.midY, app.frame.height * 0.35)
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
        let app = launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "山路手记")).firstMatch.tap()
        let more = app.buttons["reply.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8), app.debugDescription)
        if !more.isHittable { app.swipeUp() }
        for id in ["reply.copy", "reply.regenerate", "reply.more"] {
            let item = app.buttons[id]
            XCTAssertTrue(item.isHittable, id)
            XCTAssertGreaterThanOrEqual(item.frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(item.frame.height, 44, id)
        }
        XCTAssertFalse(app.buttons["朗读回复"].exists)
        capture("Reply actions with large text")
        more.tap()
        for title in ["朗读回复", "提取待办与日程", "复制 Markdown 原文"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 4), title)
        }
    }

    func testDirectoryShowsPeopleAndBookFriendsAndKeepsShelfSeparate() {
        let app = launch(personas: true, sourceLayout: true)
        let sidebar = app.buttons["好友与书架"]
        if sidebar.exists && sidebar.isHittable { sidebar.tap() } else { app.buttons["好友"].tap() }
        XCTAssertTrue(app.buttons["林舟"].waitForExistence(timeout: 8), app.debugDescription)
        let bookFriend = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "旅人", "山路手记")).firstMatch
        XCTAssertTrue(bookFriend.exists, app.debugDescription)
        capture("People and book friends together")
        let invitation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "friend.invite.")).firstMatch
        if !invitation.isHittable { app.swipeUp() }
        invitation.tap()
        XCTAssertTrue(app.navigationBars["邀请进群"].waitForExistence(timeout: 5))
        app.navigationBars["邀请进群"].buttons["取消"].tap()
        app.buttons["书架"].tap()
        XCTAssertTrue(app.buttons["开始阅读"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["林舟"].exists)
    }

    private func openUsage(in app: XCUIApplication) {
        if app.buttons["设置"].exists && app.buttons["设置"].isHittable {
            app.buttons["设置"].tap()
            app.buttons["用量与测速"].tap()
        } else {
            app.buttons["用量"].tap()
        }
    }

    func testUnpricedRequestShowsItsCountAndPricingState() {
        let app = launch(extraArguments: ["-ui-test-unpriced-usage"])
        openUsage(in: app)
        XCTAssertTrue(app.staticTexts["未定价"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["完整 1"].exists)
        XCTAssertFalse(app.staticTexts["usage.empty"].exists)
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
        func openTab(_ name: String) throws {
            let settings = app.buttons["设置"]
            if name == "服务商", settings.exists, settings.isHittable {
                settings.tap()
                app.buttons["服务商与设置"].tap()
                return
            }
            let sidebar = app.buttons["好友与书架"]
            if name == "好友", sidebar.exists, sidebar.isHittable { sidebar.tap(); return }
            let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name))
            try XCTUnwrap(matches.allElementsBoundByIndex.first(where: \.isHittable), app.debugDescription).tap()
        }
        try openTab("服务商")
        app.buttons["新对话默认设置"].tap()
        let model = app.buttons["newChat.defaultModel"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), app.debugDescription)
        model.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sample-b")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        XCTAssertTrue(app.buttons["newChat.defaultAssistant"].exists)
        try openTab("好友")
        let person = app.buttons["林舟"]
        XCTAssertTrue(person.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["私聊"].isHittable)
        app.buttons["邀请进群"].tap()
        XCTAssertTrue(app.buttons["创建新群"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars["邀请进群"].buttons["取消"].tap()
        app.buttons["私聊"].tap()
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
    }

    func testSelectAnonymousAnswerThenReveal() {
        let app = launch()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "访谈笔记盲评")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), app.debugDescription)
        chat.tap()
        let choice = app.buttons["ballot.choose.A"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8), app.debugDescription)
        let vote = app.buttons["ballot.vote"]
        XCTAssertFalse(vote.isEnabled)
        XCTAssertFalse(app.staticTexts["ballot.identity.A"].exists)
        if app.segmentedControls["ballot.answers"].exists {
            app.segmentedControls["ballot.answers"].buttons["B"].tap()
            XCTAssertTrue(app.buttons["ballot.choose.B"].exists)
            app.segmentedControls["ballot.answers"].buttons["A"].tap()
        } else {
            let other = app.buttons["ballot.choose.B"]
            XCTAssertTrue(other.isHittable)
            XCTAssertEqual(choice.frame.width, other.frame.width, accuracy: 2)
        }
        choice.tap()
        XCTAssertTrue(vote.isEnabled)
        capture("Blind-comparison")
        vote.tap()
        XCTAssertTrue(app.staticTexts["ballot.identity.A"].waitForExistence(timeout: 8))
        XCTAssertFalse(vote.exists)
        app.buttons["ballot.close"].tap()
        app.buttons["查看选票"].tap()
        XCTAssertTrue(app.staticTexts["ballot.identity.A"].waitForExistence(timeout: 8))
    }

    func testCitationOpensOriginalAndQuotesIntoSameChat() {
        let app = launch()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), app.debugDescription)
        chat.tap()
        let citation = app.buttons["reading.citation.1"]
        let sources = app.buttons["找到 1 段相关原文"]
        XCTAssertTrue(sources.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(citation.exists && citation.isHittable)
        sources.tap()
        XCTAssertTrue(citation.waitForExistence(timeout: 8), app.debugDescription)
        citation.tap()
        XCTAssertTrue(app.staticTexts["reading.highlight"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["reading.highlight"].label.contains("草倒向同一侧"))
        capture("Source-and-conversation")
        app.buttons["reading.quote"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["chatComposer.quote"].label, "路边的草倒向同一侧")
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
