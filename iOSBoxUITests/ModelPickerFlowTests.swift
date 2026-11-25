import Network
import XCTest

@MainActor
final class ModelPickerFlowTests: XCTestCase {
    func testQuickSetupRequiresReverificationAfterEditingTheKey() throws {
        continueAfterFailure = false
        let ready = expectation(description: "Loopback fixture ready")
        let probe = expectation(description: "Verification request received")
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
        app.launch()
        app.buttons["chatComposer.model"].tap()
        app.buttons["从剪贴板一键配 Key 并测通"].tap()
        let config = app.descendants(matching: .any).matching(identifier: "quickSetup.configInput").firstMatch
        XCTAssertTrue(config.waitForExistence(timeout: 8), app.debugDescription)
        config.tap()
        config.typeText("http://127.0.0.1:\(try XCTUnwrap(listener.port).rawValue)/v1")
        app.buttons["识别"].tap()
        let verify = app.buttons["一键拉取并测通模型"]
        for _ in 0..<5 where !verify.isHittable { app.swipeUp() }
        XCTAssertTrue(verify.isHittable, app.debugDescription)
        verify.tap()
        wait(for: [probe], timeout: 10)
        let done = app.buttons["完成并开始对话"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)

        let key = app.secureTextFields["quickSetup.apiKey"]
        for _ in 0..<5 where !key.isHittable { app.swipeDown() }
        XCTAssertTrue(key.isHittable, app.debugDescription)
        key.tap()
        key.typeText("changed-key")
        XCTAssertTrue(verify.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(done.exists)
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
}
