import XCTest

@MainActor
final class UIFollowupFixTests: XCTestCase {
    private func launch(_ extra: [String] = [], language: String = "zh-Hans", simple: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-test-workspaces", "-ui-test-personas", "-ui-test-model-details", "-ui-test-source-layout",
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN",
            "-iosbox.pref.simpleDailyMode", simple ? "YES" : "NO"
        ] + extra
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) {
        for _ in 0..<swipes where !element.isHittable { app.swipeUp() }
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openReadingChat(_ app: XCUIApplication) {
        app.openWorkspaceDrawerIfNeeded()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "山路手记")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 10), app.debugDescription)
        chat.tap()
    }

    func testChatAndModelPickerControlsHaveAccessibleHitTargets() throws {
        let app = launch(["-ui-audit-incomplete-currency"])
        openReadingChat(app)
        let edit = app.buttons["编辑重发"].firstMatch
        let more = app.buttons.matching(NSPredicate(format: "label == %@", "更多消息操作")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 8), app.debugDescription)
        for control in [edit, more] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, control.label)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, control.label)
        }
        app.buttons["chatComposer.model"].tap()
        let local = app.buttons["刷新 本地模型 的模型列表"]
        let legacy = app.buttons["刷新 币种缺失测试 的模型列表"]
        XCTAssertTrue(local.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(legacy.exists, app.debugDescription)
        for control in [local, legacy] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, control.label)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, control.label)
        }
        capture("Model picker after accessibility fixes", app: app)
        var issues: [String] = []
        try app.performAccessibilityAudit(for: [.hitRegion, .contrast]) { issue in
            guard let element = issue.element, element.isHittable else { return true }
            if ["识图", "思考", "刷新 本地模型 的模型列表", "刷新 币种缺失测试 的模型列表"].contains(element.label),
               issue.compactDescription.contains("failed") || issue.compactDescription.contains("too small") {
                issues.append("\(element.label): \(issue.compactDescription)")
            }
            return true
        }
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }

    func testGroupColorChoicesHaveRoomAndKeepSelection() {
        let app = launch(["-ui-audit-stale-group-model"])
        app.openWorkspaceDrawerIfNeeded()
        let group = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "失效模型测试群")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), app.debugDescription)
        group.tap()
        let title = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "失效模型测试群")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8), app.debugDescription)
        title.tap()
        let member = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试成员")).firstMatch
        reveal(member, in: app)
        XCTAssertTrue(member.isHittable, app.debugDescription)
        member.tap()
        let first = app.buttons["颜色方案 1"]
        reveal(first, in: app)
        XCTAssertTrue(first.isHittable, app.debugDescription)
        for index in 1...6 {
            let color = app.buttons["颜色方案 \(index)"]
            XCTAssertTrue(color.exists, app.debugDescription)
            XCTAssertGreaterThanOrEqual(color.frame.width, 44)
            XCTAssertGreaterThanOrEqual(color.frame.height, 44)
        }
        let second = app.buttons["颜色方案 2"]
        second.tap()
        XCTAssertTrue(second.isSelected)
        capture("Group color choices", app: app)
        let mix = app.buttons["一键混搭模型"]
        XCTAssertGreaterThanOrEqual(mix.frame.height, 44)
    }

    func testSimpleModeHidesGroupInvitationsAndKeepsUsageReachable() {
        let app = launch(simple: true)
        app.openWorkspaceDrawerIfNeeded()
        app.openWorkspaceLibrary()
        app.selectWorkshopSection("好友")
        XCTAssertTrue(app.buttons["与 林舟 私聊"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["邀请 林舟 进群"].exists)
        XCTAssertFalse(app.buttons["邀请 旅人 进群"].exists)
        app.navigationBars.buttons["完成"].tap()
        app.openWorkspaceDrawerIfNeeded()
        XCTAssertFalse(app.buttons["用量"].exists)
        app.openWorkspaceSettings()
        let usage = app.buttons["用量与费用账本"]
        reveal(usage, in: app)
        XCTAssertTrue(usage.isHittable, app.debugDescription)
        app.navigationBars["服务商与设置"].buttons["完成"].tap()
        app.openWorkspaceDrawerIfNeeded()
        let existingGroup = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "读书小组")).firstMatch
        XCTAssertTrue(existingGroup.waitForExistence(timeout: 8), app.debugDescription)
        existingGroup.tap()
        XCTAssertTrue(app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "读书小组")).firstMatch.waitForExistence(timeout: 8))

        app.terminate()
        let full = launch(simple: false)
        full.openWorkspaceDrawerIfNeeded()
        full.openWorkspaceLibrary()
        full.selectWorkshopSection("好友")
        XCTAssertTrue(full.buttons["邀请 林舟 进群"].waitForExistence(timeout: 8), full.debugDescription)
        XCTAssertTrue(full.buttons["邀请 旅人 进群"].exists)
    }

    func testWebDAVExplainsDisabledSyncAndKeepsFieldLabels() {
        let app = launch()
        app.openWorkspaceSettings()
        let webDAV = app.buttons["WebDAV 加密云同步"]
        reveal(webDAV, in: app)
        XCTAssertTrue(webDAV.isHittable, app.debugDescription)
        webDAV.tap()
        let path = app.textFields["远端文件路径"]
        XCTAssertTrue(path.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(path.value as? String, "Fugue/fugue-sync.enc.json")
        let explanation = app.staticTexts["请先填写服务器地址、账号、密码和至少 8 位的同步加密密码。"]
        reveal(explanation, in: app)
        XCTAssertTrue(explanation.isHittable, app.debugDescription)
        XCTAssertFalse(app.switches["开启自动静默同步"].isEnabled)
        capture("WebDAV field labels and sync explanation", app: app)
    }

    func testIncompleteWebDAVConfigurationStillAllowsTurningSyncOff() {
        let app = launch(["-iosbox.pref.webDAVAutoSyncEnabled", "YES"])
        app.openWorkspaceSettings()
        let webDAV = app.buttons["WebDAV 加密云同步"]
        reveal(webDAV, in: app)
        XCTAssertTrue(webDAV.isHittable, app.debugDescription)
        webDAV.tap()
        let toggle = app.switches["开启自动静默同步"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.isHittable && toggle.isEnabled, app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testProviderNameAndAPIKeyVisibilityControlRemainAccessible() {
        let app = launch()
        app.openWorkspaceSettings()
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本地模型")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 8), app.debugDescription)
        provider.tap()
        let name = app.textFields["服务商名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(name.value as? String, "本地模型")
        let showKey = app.buttons["显示 API Key"]
        reveal(showKey, in: app)
        XCTAssertTrue(showKey.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(showKey.frame.width, 44)
        XCTAssertGreaterThanOrEqual(showKey.frame.height, 44)
        showKey.tap()
        XCTAssertTrue(app.buttons["隐藏 API Key"].exists)
    }

    func testVoiceModelPresetsAreLabeledAndEasyToTap() {
        let app = launch()
        app.openWorkspaceSettings()
        let voice = app.buttons["语音转写与自然朗读"]
        reveal(voice, in: app)
        XCTAssertTrue(voice.isHittable, app.debugDescription)
        voice.tap()
        let model = app.textFields["转写模型"]
        XCTAssertTrue(model.waitForExistence(timeout: 8), app.debugDescription)
        let preset = app.buttons["gpt-4o-mini-transcribe"]
        XCTAssertTrue(preset.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(preset.frame.height, 44)
        capture("Voice model controls", app: app)
        preset.tap()
        XCTAssertEqual(model.value as? String, "gpt-4o-mini-transcribe")
    }

    func testLargeTextSettingsUseReadableControls() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        app.openWorkspaceSettings()
        let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "本地模型")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 8), app.debugDescription)
        let count = app.staticTexts["已启用 2 个模型"]
        XCTAssertTrue(count.exists, app.debugDescription)
        XCTAssertGreaterThan(count.frame.width, app.frame.width * 0.35)
        capture("Large type provider row", app: app)
        let appearance = app.buttons["阅读与交互偏好"]
        reveal(appearance, in: app)
        XCTAssertTrue(appearance.isHittable, app.debugDescription)
        appearance.tap()
        let large = app.buttons["大字"]
        reveal(large, in: app)
        XCTAssertTrue(large.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(large.frame.height, 44)
        capture("Large type reading size choices", app: app)
        large.tap()
        XCTAssertTrue(large.isSelected)
    }

    func testSimpleModeAlsoHidesInvitationsInBookFriendChat() {
        let app = launch(simple: true)
        app.openWorkspaceDrawerIfNeeded()
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "旅人私聊")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8), app.debugDescription)
        chat.tap()
        let menu = app.buttons["更多操作"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), app.debugDescription)
        menu.tap()
        XCTAssertTrue(app.buttons["调整阅读进度"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.buttons["邀请进群"].exists)
    }

    func testEnglishUsageHasSingularAndPluralRequests() {
        for (arguments, expected) in [
            (["-ui-test-unpriced-usage"], "Missing usage or pricing: 1 request (not counted as free)"),
            (["-ui-audit-tiny-cost"], "Missing usage or pricing: 0 requests (not counted as free)")
        ] {
            let app = launch(arguments, language: "en")
            let workshop = app.buttons["workspace.tab.library"]
            if workshop.isHittable { workshop.tap() }
            app.buttons["Usage"].firstMatch.tap()
            let text = app.staticTexts[expected]
            reveal(text, in: app)
            XCTAssertTrue(text.exists, app.debugDescription)
            app.terminate()
        }
    }
}
