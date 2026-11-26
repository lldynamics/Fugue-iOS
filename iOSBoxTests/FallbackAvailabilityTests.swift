import XCTest
@testable import iOSBox

@MainActor
final class FallbackAvailabilityTests: XCTestCase {
    func testSettingsAndExecutionUseTheSameReadyBackupsAfterAccountOrModeChanges() {
        let spec = ModelSpec(id: "test-chat")
        let local = ProviderConfig(name: "Local", protocolType: .openAICompatible, baseURL: "http://localhost/v1", models: [spec])
        let backup = ProviderConfig(name: "Backup", protocolType: .openAICompatible, baseURL: "http://127.0.0.1/v1", models: [spec])
        let noKey = ProviderConfig(name: "No key", protocolType: .openAICompatible, baseURL: "https://fixture.invalid/v1", models: [spec])
        let providers = [local, backup, noKey]
        let primary = local.makeTarget(for: spec), good = backup.makeTarget(for: spec), stale = noKey.makeTarget(for: spec)
        let chat = Conversation(primaryTarget: primary)
        chat.assistanceSettings.fallbackTargets = [stale, primary, good, good]
        chat.assistanceSettings.fallbackEnabled = true
        let reply = ChatMessage(role: .assistant, target: primary)
        func retryTargets() -> [String] {
            ChatEngine.shared.replyFallbacks(for: reply, after: primary, in: chat, providers: providers).map(\.id)
        }
        let available = ProviderConfig.readyTargets(in: providers)
        let states = AssistancePolicy.fallbackAvailability(after: primary.id, configured: chat.assistanceSettings.fallbackTargets, available: available)
        XCTAssertEqual(states.map { $0?.id }, [nil, nil, good.id, nil])
        XCTAssertTrue(AssistancePolicy.fallbackAvailability(after: nil, configured: [good], available: available).allSatisfy { $0 == nil })
        XCTAssertEqual(retryTargets(), [good.id])
        chat.isArenaMode = true
        XCTAssertTrue(retryTargets().isEmpty)
        chat.isArenaMode = false
        chat.isGroupMode = true
        XCTAssertTrue(retryTargets().isEmpty)
        chat.isGroupMode = false
        backup.isEnabled = false
        XCTAssertTrue(retryTargets().isEmpty)
    }
}
