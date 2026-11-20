import Network
import XCTest

@MainActor
final class ModelPickerFlowTests: XCTestCase {
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
        app.buttons["新建"].tap()
        app.buttons["普通对话"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "chatComposer.input").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("keep this draft")
        let heading = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "选择模型")).firstMatch
        heading.tap()
        let configure = app.buttons["modelPicker.configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 8))
        configure.tap()
        let setup = app.navigationBars["连接模型"]
        XCTAssertTrue(setup.waitForExistence(timeout: 8))
        setup.buttons["取消"].tap()
        XCTAssertTrue(configure.waitForExistence(timeout: 8))
        configure.tap()
        app.buttons["Local Fixture"].tap()
        let enable = app.switches["provider.enabled"]
        XCTAssertTrue(enable.waitForExistence(timeout: 8))
        enable.tap()
        let verify = app.buttons["验证连接并使用此模型"]
        for _ in 0..<7 where !verify.isHittable { app.swipeUp() }
        XCTAssertTrue(verify.isEnabled)
        verify.tap()
        wait(for: [probe], timeout: 10)
        let selected = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "fixture-chat")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(field.value as? String, "keep this draft")
    }
}
