import SwiftData
import SwiftUI

struct FirstModelSetupSheet: View {
    var continuesToGroup = false
    let onConnected: (ResolvedModelTarget) -> Void

    var body: some View {
        QuickKeySetupSheet(isFirstConnection: true, continuesToGroup: continuesToGroup) { _, target in
            onConnected(target)
        }
    }
}

struct ManualConnectionProvidersView: View {
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @State private var addedProvider: ProviderConfig?
    @State private var adding = false
    let correctKey: (ProviderSetupDraft) -> Void
    let onConnected: (ProviderConfig, ResolvedModelTarget) -> Void

    var body: some View {
        List {
            ForEach(providers) { provider in
                NavigationLink {
                    details(provider)
                } label: {
                    Label(provider.name, systemImage: provider.iconSymbol)
                }
            }
            Button { adding = true } label: { Label("手动添加服务商", systemImage: "plus") }
        }
        .navigationTitle("选择服务商")
        .sheet(isPresented: $adding) { AddProviderSheet { addedProvider = $0 } }
        .navigationDestination(item: $addedProvider) { details($0) }
    }

    private func details(_ provider: ProviderConfig) -> some View {
        ProviderDetailView(provider: provider, onVerifiedModel: { onConnected(provider, $0) }, correctKey: correctKey)
    }
}

@MainActor
enum ModelSetup {
    static func verificationAdvice(for error: Error, checkingModel: Bool = false) -> String {
        if let error = error as? LLMError {
            switch error {
            case .invalidURL:
                return String(localized: "请检查接口地址和协议类型。")
            case .missingAPIKey:
                return String(localized: "请填写当前服务商的 API Key。")
            case .httpError(401, _):
                return String(localized: "HTTP 401 · 密钥验证失败。请确认密钥由所选服务商签发，并完整粘贴。")
            case .httpError(403, _):
                return String(localized: "HTTP 403 · 服务商拒绝了请求。请检查项目的模型、接口和地区访问限制。")
            case .httpError(429, _):
                return String(localized: "接口暂时限流。请稍后重试，或检查服务商配额。")
            case .httpError(404, _) where checkingModel, .unavailableModel:
                return String(localized: "请核对模型 ID 及接口地址。")
            case .httpError(404, _):
                return String(localized: "模型列表地址不可用。请核对接口地址，或手动指定模型 ID。")
            default: break
            }
        }
        if let network = error as? URLError,
           [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .unsupportedURL].contains(network.code) {
            return String(localized: "无法连接接口。请检查接口地址和网络。")
        }
        return error.localizedDescription
    }

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
