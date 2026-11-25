import XCTest
@testable import iOSBox

@MainActor
final class GroupSetupDraftPolicyTests: XCTestCase {
    func testMissingModelsAndEmptyGroupsKeepTheirExistingMembers() {
        let old = ProviderConfig(name: "Old", protocolType: .openAICompatible,
                                 baseURL: "http://127.0.0.1", models: [ModelSpec(id: "old-model")])
        let current = ProviderConfig(name: "Current", protocolType: .openAICompatible,
                                     baseURL: "http://127.0.0.1", models: [ModelSpec(id: "new-model")])
        let member = GroupMember(name: "Reader", rolePrompt: "Role", target: old.makeTarget(for: old.models[0]))

        XCTAssertEqual(GroupSetupDraftPolicy.existingMembers([member], providers: [current]), [member])
        XCTAssertTrue(GroupSetupDraftPolicy.existingMembers([], providers: [current]).isEmpty)
    }

    func testAvailableModelRefreshesItsDisplayInformation() {
        let provider = ProviderConfig(name: "Original", protocolType: .openAICompatible,
                                      baseURL: "http://127.0.0.1", models: [ModelSpec(id: "model")])
        let member = GroupMember(name: "Reader", rolePrompt: "Role", target: provider.makeTarget(for: provider.models[0]))
        provider.name = "Renamed"

        let result = GroupSetupDraftPolicy.existingMembers([member], providers: [provider])
        XCTAssertEqual(result.first?.target.id, member.target.id)
        XCTAssertEqual(result.first?.target.providerName, "Renamed")
        XCTAssertEqual(result.first?.rolePrompt, member.rolePrompt)
    }
}
