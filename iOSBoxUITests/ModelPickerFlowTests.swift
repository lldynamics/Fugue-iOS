import Network
import XCTest

@MainActor
final class ModelPickerFlowTests: XCTestCase {
    func testArenaSendReviewShowsModelsAndCancelPreservesDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-ui-test-personas", "-ui-test-model-details",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["inbox.resume"].tap() }
        let mode = app.buttons["单聊"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 8), app.debugDescription)
        mode.tap()
        app.buttons["多模型对比"].tap()
        let picker = app.navigationBars["选择并发对比模型"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
        let twoModels = picker.buttons["开启对比 (2)"]
        for name in ["sample-a", "sample-b"] where !twoModels.exists {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            for _ in 0..<3 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.isHittable, app.debugDescription)
            if !row.isSelected { row.tap() }
        }
        XCTAssertTrue(twoModels.exists, app.debugDescription)
        XCTAssertTrue(twoModels.isEnabled, app.debugDescription)
        twoModels.tap()

        let field = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        let draft = field.value as? String
        XCTAssertFalse(draft?.isEmpty ?? true)
        app.buttons["发送"].tap()
        let review = app.navigationBars["发送前确认"]
        XCTAssertTrue(review.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "约 2 次模型请求")).firstMatch.exists)
        review.buttons["取消"].tap()
        XCTAssertEqual(field.value as? String, draft)
    }

    func testQuickSetupRequiresReverificationAfterEditingTheKey() throws {
        continueAfterFailure = false
        let ready = expectation(description: "Loopback fixture ready")
        let initialProbe = expectation(description: "Initial connection verified")
        let editedKeyProbe = expectation(description: "New API key verified before saving")
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "quick-setup-fixture")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let body: String, type: String
                if request.hasPrefix("GET /v1/models ") {
                    type = "application/json"
                    body = #"{"data":[{"id":"fixture-chat"}]}"#
                } else {
                    XCTAssertTrue(request.hasPrefix("POST /v1/chat/completions "))
                    if request.lowercased().contains("authorization: bearer changed-key\r\n") {
                        editedKeyProbe.fulfill()
                    } else {
                        XCTAssertFalse(request.lowercased().contains("authorization:"))
                        initialProbe.fulfill()
                    }
                    type = "text/event-stream"
                    body = "data: {\"choices\":[{\"delta\":{\"content\":\"pong\"}}]}\n\ndata: [DONE]\n\n"
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        wait(for: [ready], timeout: 10)

        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-model-picker", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["inbox.newQuestion"].tap() }
        app.buttons["chatComposer.model"].tap()
        app.buttons["导入连接信息"].tap()
        let config = app.descendants(matching: .any).matching(identifier: "quickSetup.configInput").firstMatch
        XCTAssertTrue(config.waitForExistence(timeout: 8), app.debugDescription)
        config.tap()
        config.typeText("http://127.0.0.1:\(try XCTUnwrap(listener.port).rawValue)/v1")
        app.buttons["识别"].tap()
        let verify = app.buttons["quickSetup.verify"]
        for _ in 0..<5 where !verify.isHittable { app.swipeDown() }
        XCTAssertTrue(verify.isHittable, app.debugDescription)
        verify.tap()
        wait(for: [initialProbe], timeout: 10)
        let done = app.buttons["quickSetup.finish"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)

        let key = app.secureTextFields["quickSetup.apiKey"]
        for _ in 0..<5 where !key.isHittable { app.swipeDown() }
        XCTAssertTrue(key.isHittable, app.debugDescription)
        key.tap()
        key.typeText("changed-key\n")
        XCTAssertTrue(verify.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(done.exists)
        for _ in 0..<4 where !verify.isHittable { app.swipeUp() }
        XCTAssertTrue(verify.isHittable, app.debugDescription)
        verify.tap()
        wait(for: [editedKeyProbe], timeout: 10)
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        done.tap()
        let selected = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                        "chatComposer.model", "fixture-chat")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testEmptyPickerCanCancelOrVerifyAndReturnToTheSameDraft() throws {
        continueAfterFailure = false
        let ready = expectation(description: "Loopback fixture ready")
        let probe = expectation(description: "Fixed verification request received")
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "model-picker-fixture")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let body: String, type: String
                if request.hasPrefix("GET /v1/models ") {
                    type = "application/json"
                    body = #"{"data":[{"id":"fixture-chat"}]}"#
                } else {
                    XCTAssertTrue(request.hasPrefix("POST /v1/chat/completions "))
                    XCTAssertFalse(request.contains("keep this draft"))
                    type = "text/event-stream"
                    body = "data: {\"choices\":[{\"delta\":{\"content\":\"pong\"}}]}\n\ndata: [DONE]\n\n"
                    probe.fulfill()
                }
                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        wait(for: [ready], timeout: 10)
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-model-picker", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["UI_TEST_MODEL_PORT"] = String(try XCTUnwrap(listener.port).rawValue)
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["inbox.newQuestion"].tap() }
        let field = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("keep this draft")
        let connect = app.buttons["chatComposer.model"]
        XCTAssertTrue(connect.isHittable, "The model button must be reachable while editing the first draft")
        connect.tap()
        let setup = app.navigationBars["连接模型"]
        XCTAssertTrue(setup.waitForExistence(timeout: 8), app.debugDescription)
        setup.buttons["取消"].tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        XCTAssertEqual(field.value as? String, "keep this draft")
        connect.tap()
        let manual = app.buttons["quickSetup.savedProviders"]
        for _ in 0..<4 where !manual.isHittable { app.swipeUp() }
        manual.tap()
        app.buttons["Local Fixture"].tap()
        let enable = app.switches["provider.enabled"]
        XCTAssertTrue(enable.waitForExistence(timeout: 8))
        let key = app.textFields["provider.setup.key"].firstMatch
        let secureKey = app.secureTextFields["provider.setup.key"].firstMatch
        XCTAssertTrue(key.exists || secureKey.exists)
        let enableControl = enable.switches.firstMatch
        XCTAssertTrue(enableControl.exists)
        enableControl.tap()
        let verify = app.buttons["provider.setup.verify"]
        XCTAssertTrue(verify.isEnabled, "Verification should be available after enabling the local provider.\n\(app.debugDescription)")
        let advanced = app.buttons["provider.setup.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        let address = app.textFields.matching(NSPredicate(format: "value CONTAINS %@", "127.0.0.1")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars["Local Fixture"].buttons.firstMatch.tap()
        for _ in 0..<7 where !verify.isHittable { app.swipeUp() }
        XCTAssertTrue(verify.isEnabled, app.debugDescription)
        verify.tap()
        wait(for: [probe], timeout: 10)
        let selected = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "chatComposer.model", "fixture-chat")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(field.value as? String, "keep this draft")
    }

    func testConfiguredChatCanConnectAnotherProviderAndCorrectItsIssuer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-ui-test-personas",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["inbox.resume"].tap() }
        app.buttons["chatComposer.model"].tap()
        app.buttons["modelPicker.configure"].tap()

        let service = app.buttons["providerSetup.service"]
        XCTAssertTrue(service.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["api.openai.com · Responses API"].exists)
        service.tap()
        XCTAssertFalse(app.buttons["OpenAI Responses API"].exists)
        app.buttons["OpenRouter"].tap()
        XCTAssertTrue(app.staticTexts["openrouter.ai · Chat Completions"].exists)

        let key = app.secureTextFields["quickSetup.apiKey"]
        key.tap()
        key.typeText("sk-proj-fixture\n")
        XCTAssertFalse(app.buttons["quickSetup.verify"].isEnabled)
        let correction = app.buttons["providerSetup.correctIssuer"]
        XCTAssertTrue(correction.isHittable, app.debugDescription)
        correction.tap()
        XCTAssertTrue(app.staticTexts["api.openai.com · Responses API"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["quickSetup.verify"].isEnabled)
        XCTAssertFalse(app.buttons["quickSetup.finish"].exists)
        app.navigationBars["连接模型"].buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["切换对话模型"].waitForExistence(timeout: 5))
    }

    func testSettingsCanCorrectAKeyInAnExistingProviderWithoutSavingItThere() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-workspaces", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.openWorkspaceSettings()
        app.buttons["settings.connectModel"].tap()
        XCTAssertTrue(app.staticTexts["api.openai.com · Responses API"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "ConnectModel"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars["连接模型"].buttons["关闭"].tap()

        app.buttons["手动添加服务商"].tap()
        app.buttons["providerSetup.service"].tap()
        app.buttons["OpenRouter"].tap()
        app.buttons["创建"].tap()
        XCTAssertTrue(app.navigationBars["OpenRouter"].waitForExistence(timeout: 5))
        let key = app.secureTextFields["provider.setup.key"]
        for _ in 0..<5 where !key.isHittable { app.swipeUp() }
        let original = key.value as? String
        key.tap()
        key.typeText("sk-proj-fixture\n")
        let fix = app.buttons["providerSetup.correctIssuer"]
        XCTAssertTrue(fix.waitForExistence(timeout: 5), app.debugDescription)
        fix.tap()
        XCTAssertTrue(app.staticTexts["api.openai.com · Responses API"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars["连接模型"].buttons["关闭"].tap()
        XCTAssertTrue(app.navigationBars["OpenRouter"].waitForExistence(timeout: 5))
        XCTAssertEqual(key.value as? String, original)
    }
}
