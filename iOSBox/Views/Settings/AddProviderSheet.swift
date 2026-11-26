import SwiftUI
import SwiftData
import UIKit

struct AddProviderSheet: View {
    var onCreated: (ProviderConfig) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var saveError: String?
    @State private var draft = ProviderSetupDraft()
    @State private var showingAdvanced = false
    @State private var catalog = ProviderModelCatalog()
    @State private var chosenID: String?
    @State private var clipboardHint: String?

    private var request: ModelCatalogRequest {
        ModelCatalogRequest(protocolType: draft.protocolType, baseURL: draft.baseURL, apiKey: LLMClient.sanitizedAPIKey(draft.apiKey))
    }

    private var selectedID: String {
        let manual = draft.manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        let options = catalog.models ?? draft.suggestedModels
        if let chosenID, options.contains(where: { $0.id == chosenID }) { return chosenID }
        return options.first?.id ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError { Text(saveError).foregroundStyle(DS.StatusText.error) }
                ProviderSetupPicker(draft: $draft)
                ProviderSetupKeySection(draft: $draft)
                Section {
                    DisclosureGroup("高级设置", isExpanded: $showingAdvanced) {
                        TextField("服务商显示名称", text: $draft.name)
                        ProviderSetupProtocolPicker(draft: $draft)
                        TextField("Base URL", text: $draft.baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("实际对话端点：\(EndpointResolver.previewChatEndpoint(baseURL: draft.baseURL, protocolType: draft.protocolType))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        InsecureHTTPWarningView(baseURL: draft.baseURL)
                    }
                    Button { fillFromClipboard() } label: {
                        Label("从剪贴板识别 Key 与地址", systemImage: "doc.on.clipboard")
                    }
                    if let clipboardHint { Text(clipboardHint).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    ModelCatalogPicker(catalog: catalog, request: request, fallback: draft.suggestedModels, fallbackTitle: "内置参考模型",
                                       selected: selectedID, refresh: refreshModels) { model in
                        draft.manualModelID = ""
                        chosenID = model.id
                    }
                    ModelCatalogRefreshButton(catalog: catalog, request: request, refresh: refreshModels)
                    TextField("手动输入模型 ID", text: $draft.manualModelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                } header: {
                    if catalog.models == nil { Text("初始模型（可选）") } else { Text("接口返回的模型") }
                } footer: {
                    Text("填写连接信息后可获取当前接口提供的模型。也可以直接输入模型 ID。")
                }
            }
            .navigationTitle("手动添加服务商")
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
                        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !request.canFetch || catalog.isLoading
                    )
                }
            }
            .onChange(of: request) { _, _ in
                catalog.reset()
                chosenID = nil
            }
            .onChange(of: draft.serviceID) {
                if ["custom_openai", "ollama"].contains(draft.serviceID) { showingAdvanced = true }
            }
            .onDisappear { catalog.reset() }
        }
    }

    private func fillFromClipboard() {
        let raw = UIPasteboard.general.string ?? ""
        guard let candidate = ClipboardProviderParser.parse(raw) else {
            clipboardHint = String(localized: "剪贴板中未检测到可识别的 Key 或接口地址。")
            return
        }
        draft.apply(candidate)
        clipboardHint = candidate.confidenceNote
    }

    private func refreshModels() {
        catalog.refresh(request: request)
    }

    private func createProvider() {
        var initialModels = ProviderModelCatalog.merging(catalog.models ?? draft.suggestedModels, with: [], choosing: selectedID,
                                                        fromAPI: catalog.models != nil)
        if !draft.manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !initialModels.isEmpty {
            initialModels[0].catalogStatus = .manual
        }
        let provider = ProviderConfig(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            protocolType: draft.protocolType,
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            iconSymbol: draft.iconSymbol,
            accentHex: draft.accentHex,
            isEnabled: true,
            sortOrder: Int(Date().timeIntervalSince1970),
            models: initialModels
        )

        if !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard KeychainService.shared.saveAPIKey(request.apiKey, for: provider.credentialID) else {
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
