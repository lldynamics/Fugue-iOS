import SwiftData
import SwiftUI

struct FirstModelSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @State private var path: [ProviderConfig] = []
    @State private var adding = false
    @State private var showQuickSetup = false
    var continuesToGroup = false
    let onConnected: (ResolvedModelTarget) -> Void

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if continuesToGroup { Text("连接后将继续选择群成员。").foregroundStyle(.secondary) }
                Section("极速配置") {
                    Button {
                        showQuickSetup = true
                    } label: {
                        Label("从剪贴板一键配 Key 并测通", systemImage: "bolt.fill")
                            .fontWeight(.medium)
                    }
                }
                Section("选择服务商") {
                    ForEach(providers) { provider in
                        NavigationLink(value: provider) {
                            Label(provider.name, systemImage: provider.iconSymbol)
                        }
                    }
                    Button { adding = true } label: { Label("添加自定义 API", systemImage: "plus") }
                }
            }
            .navigationTitle("连接模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .navigationDestination(for: ProviderConfig.self) { provider in
                ProviderDetailView(provider: provider, onVerifiedModel: { target in
                    if !continuesToGroup { dismiss() }
                    onConnected(target)
                })
            }
            .sheet(isPresented: $adding) {
                AddProviderSheet { provider in path.append(provider) }
            }
            .sheet(isPresented: $showQuickSetup) {
                QuickKeySetupSheet { _, target in
                    if !continuesToGroup { dismiss() }
                    onConnected(target)
                }
            }
        }
    }
}

@MainActor
enum ModelSetup {
    static func use(_ target: ResolvedModelTarget, in chat: Conversation, context: ModelContext, exitGroup: Bool) throws {
        let id = target.providerID
        let provider = try context.fetch(FetchDescriptor<ProviderConfig>(predicate: #Predicate { $0.id == id })).first
        guard let provider, provider.isReadyForChat, let spec = provider.enabledModels.first(where: { $0.id == target.modelID }) else {
            throw SystemEntryError.noModel
        }
        let previous = (chat.primaryTargetData, chat.isArenaMode, chat.assistanceSettingsData)
        chat.primaryTarget = provider.makeTarget(for: spec)
        chat.isArenaMode = false
        if exitGroup { chat.isGroupMode = false }
        do { try context.save() } catch {
            (chat.primaryTargetData, chat.isArenaMode, chat.assistanceSettingsData) = previous
            throw error
        }
    }

    static func verify(provider: ProviderConfig, modelID: String, context: ModelContext,
                       probe: (SharedConnection, ResolvedModelTarget) async throws -> Void = ping) async throws -> ResolvedModelTarget {
        guard provider.isReadyForChat, let model = provider.enabledModels.first(where: { $0.id == modelID }) else {
            throw SystemEntryError.noModel
        }
        try context.save()
        let target = provider.makeTarget(for: model)
        let connection = SystemIntegration.connection(provider)
        try await probe(connection, target)
        try Task.checkCancellation()
        guard provider.modelContext != nil, provider.isReadyForChat,
              provider.enabledModels.contains(where: { $0.id == modelID }),
              provider.protocolType == target.protocolType, SystemIntegration.connection(provider) == connection else {
            throw LLMError.apiError(String(localized: "连接配置已更改，请重新验证。"))
        }
        return target
    }

    private static func ping(_ connection: SharedConnection, _ target: ResolvedModelTarget) async throws {
        _ = try await LLMClient.pingModel(providerName: target.providerName, protocolType: target.protocolType,
                                          baseURL: connection.baseURL, apiKey: connection.apiKey,
                                          apiKeys: connection.extraAPIKeys ?? [],
                                          customHeaders: connection.headers, modelID: target.modelID,
                                          supportsReasoning: target.supportsReasoning,
                                          idleTimeoutSeconds: connection.idleTimeoutSeconds.flatMap { $0 > 0 ? TimeInterval($0) : nil })
    }
}
