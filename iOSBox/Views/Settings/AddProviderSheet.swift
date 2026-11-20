import SwiftUI
import SwiftData

struct AddProviderSheet: View {
    var onCreated: (ProviderConfig) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var saveError: String?
    @State private var selectedTemplateID: String = "custom_openai"
    @State private var name: String = String(localized: "自定义服务商")
    @State private var protocolType: APIProtocolType = .openAICompatible
    @State private var baseURL = "https://api.example.com/v1"
    @State private var apiKey: String = ""
    @State private var accentHex: String = "#3F6EF6"
    @State private var iconSymbol = "slider.horizontal.below.square.and.square.filled"
    @State private var catalog = ProviderModelCatalog()
    @State private var chosenID: String?
    @State private var manualFirstModelID: String = ""

    private var request: ModelCatalogRequest {
        ModelCatalogRequest(protocolType: protocolType, baseURL: baseURL, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var suggestions: [ModelSpec] {
        ProviderTemplate.matching(baseURL: baseURL, protocolType: protocolType)?.suggestedModels ?? []
    }

    private var selectedID: String {
        let manual = manualFirstModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        let options = catalog.models ?? suggestions
        if let chosenID, options.contains(where: { $0.id == chosenID }) { return chosenID }
        return options.first?.id ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError { Text(saveError).foregroundStyle(.red) }
                Section("快速选择常见模板（或自定义）") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ProviderTemplate.catalog) { tpl in
                                let isChosen = selectedTemplateID == tpl.id
                                Button {
                                    applyTemplate(tpl)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Image(systemName: tpl.iconSymbol)
                                                .foregroundStyle(Color(hex: tpl.accentHex))
                                            Text(tpl.protocolType.shortBadge)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(tpl.name)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 136, alignment: .leading)
                                    .padding(10)
                                    .background(
                                        isChosen ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(isChosen ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("接口协议与地址") {
                    TextField("服务商显示名称", text: $name)

                    Picker("API 协议类型", selection: Binding(get: { protocolType }, set: { newProtocol in
                        baseURL = ProviderTemplate.baseURLAfterProtocolChange(currentBaseURL: baseURL, from: protocolType, to: newProtocol)
                        protocolType = newProtocol
                    })) {
                        ForEach(APIProtocolType.allCases) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Base URL（如 https://api.xxx.com/v1）", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.subheadline.monospaced())

                        Text("实际对话端点：\(EndpointResolver.previewChatEndpoint(baseURL: baseURL, protocolType: protocolType))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        InsecureHTTPWarningView(baseURL: baseURL)
                    }
                }

                Section {
                    SecureField("粘贴 API Key（加密保存在系统钥匙串）", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Key")
                } footer: {
                    Text("API Key 仅保存在本机 iOS 安全钥匙串（Keychain）中，直连目标接口，不经过任何第三方服务器。")
                }

                Section {
                    ModelCatalogPicker(catalog: catalog, request: request, fallback: suggestions, fallbackTitle: "内置参考模型",
                                       selected: selectedID, refresh: refreshModels) { model in
                        manualFirstModelID = ""
                        chosenID = model.id
                    }
                    ModelCatalogRefreshButton(catalog: catalog, request: request, refresh: refreshModels)
                    TextField("手动输入模型 ID", text: $manualFirstModelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                } header: {
                    if catalog.models == nil { Text("初始模型（可选）") } else { Text("接口返回的模型") }
                } footer: {
                    Text("填写连接信息后可获取当前接口提供的模型。也可以直接输入模型 ID。")
                }
            }
            .navigationTitle("添加自定义 API")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        createProvider()
                    }
                    .fontWeight(.semibold)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || catalog.isLoading
                    )
                }
            }
            .onChange(of: request) { _, _ in
                catalog.reset()
                chosenID = nil
            }
            .onDisappear { catalog.reset() }
        }
    }

    private func applyTemplate(_ tpl: ProviderTemplate) {
        if URLComponents(string: baseURL)?.host != URLComponents(string: tpl.baseURL)?.host { apiKey = "" }
        if selectedTemplateID != tpl.id { manualFirstModelID = "" }
        selectedTemplateID = tpl.id
        name = tpl.id == "custom_openai" ? String(localized: "自定义服务商") : tpl.name
        protocolType = tpl.protocolType
        baseURL = tpl.baseURL
        accentHex = tpl.accentHex
        iconSymbol = tpl.iconSymbol
    }

    private func refreshModels() {
        catalog.refresh(request: request)
    }

    private func createProvider() {
        var initialModels = ProviderModelCatalog.merging(catalog.models ?? suggestions, with: [], choosing: selectedID,
                                                        fromAPI: catalog.models != nil)
        if !manualFirstModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !initialModels.isEmpty {
            initialModels[0].catalogStatus = .manual
        }
        let provider = ProviderConfig(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            protocolType: protocolType,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            iconSymbol: iconSymbol,
            accentHex: accentHex,
            isEnabled: true,
            sortOrder: Int(Date().timeIntervalSince1970),
            models: initialModels
        )

        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard KeychainService.shared.saveAPIKey(request.apiKey, for: provider.id) else {
                saveError = String(localized: "保存失败，请保留输入并重试。")
                return
            }
        }
        modelContext.insert(provider)
        do { try modelContext.save() } catch {
            modelContext.delete(provider)
            provider.deleteAllSecrets()
            saveError = error.localizedDescription
            return
        }
        dismiss()
        onCreated(provider)
    }
}
