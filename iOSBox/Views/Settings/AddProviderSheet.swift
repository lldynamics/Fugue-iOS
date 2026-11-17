import SwiftUI
import SwiftData

struct AddProviderSheet: View {
    var onCreated: (ProviderConfig) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplateID: String = "custom_openai"
    @State private var name: String = "自定义服务商"
    @State private var protocolType: APIProtocolType = .openAICompatible
    @State private var baseURL: String = "https://api.openai.com/v1"
    @State private var apiKey: String = ""
    @State private var accentHex: String = "#3F6EF6"
    @State private var iconSymbol: String = "server.rack"
    @State private var suggestedModels: [ModelSpec] = []
    @State private var manualFirstModelID: String = ""

    var body: some View {
        NavigationStack {
            Form {
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

                    Picker("API 协议类型", selection: $protocolType) {
                        ForEach(APIProtocolType.allCases) { proto in
                            Text(proto.displayName).tag(proto)
                        }
                    }
                    .onChange(of: protocolType) { oldProto, newProto in
                        baseURL = ProviderTemplate.baseURLAfterProtocolChange(
                            currentBaseURL: baseURL,
                            from: oldProto,
                            to: newProto
                        )
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

                if suggestedModels.isEmpty {
                    Section("初始模型（可选，创建后也可一键拉取）") {
                        TextField("例如：gpt-4.1 / deepseek-r1 / claude-sonnet-4-5", text: $manualFirstModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())
                    }
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
                        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .onAppear {
                if let first = ProviderTemplate.catalog.first {
                    applyTemplate(first)
                }
            }
        }
    }

    private func applyTemplate(_ tpl: ProviderTemplate) {
        selectedTemplateID = tpl.id
        name = tpl.id == "custom_openai" ? "自定义服务商" : tpl.name
        protocolType = tpl.protocolType
        baseURL = tpl.baseURL
        accentHex = tpl.accentHex
        iconSymbol = tpl.iconSymbol
        suggestedModels = tpl.suggestedModels
    }

    private func createProvider() {
        var initialModels = suggestedModels
        let manual = manualFirstModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty && !initialModels.contains(where: { $0.id == manual }) {
            initialModels.append(ModelSpec(id: manual))
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
        modelContext.insert(provider)

        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            KeychainService.shared.saveAPIKey(apiKey, for: provider.id)
        }
        try? modelContext.save()
        dismiss()
        onCreated(provider)
    }
}
