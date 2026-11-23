import SwiftData
import SwiftUI

struct NewChatDefaultsView: View {
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @State private var preferences = AppPreferences.shared
    @State private var connecting = false

    var body: some View {
        let targets = ProviderConfig.readyTargets(in: providers)
        Form {
            Section {
                Picker("默认模型", selection: $preferences.defaultTargetID) {
                    Text("多个可用模型时手动选择").tag(String?.none)
                    if let id = preferences.defaultTargetID, !targets.contains(where: { $0.id == id }) {
                        Text("原默认模型不可用").tag(Optional(id))
                    }
                    ForEach(targets) { target in
                        Text(verbatim: "\(target.providerName) · \(target.modelDisplayName)").tag(Optional(target.id))
                    }
                }
                .accessibilityIdentifier("newChat.defaultModel")
                if targets.isEmpty { Button("连接模型") { connecting = true } }
            }
            Section {
                Picker("默认助手", selection: $preferences.defaultAssistantID) {
                    Text("不使用助手").tag(UUID?.none)
                    if let id = preferences.defaultAssistantID, !presets.contains(where: { $0.id == id }) {
                        Text("原默认助手已移除").tag(Optional(id))
                    }
                    ForEach(presets) { preset in Text(verbatim: preset.name).tag(Optional(preset.id)) }
                }
                .accessibilityIdentifier("newChat.defaultAssistant")
            } footer: { Text("只应用于新对话。助手绑定的知识库可在每次发送前关闭。") }
        }
        .navigationTitle("新对话默认设置")
        .sheet(isPresented: $connecting) {
            FirstModelSetupSheet { preferences.defaultTargetID = $0.id }
        }
    }
}
