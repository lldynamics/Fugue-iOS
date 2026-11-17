import SwiftUI
import SwiftData
import UIKit

struct ProviderDetailView: View {
    @Bindable var provider: ProviderConfig
    @Environment(\.modelContext) private var modelContext

    @State private var apiKeyInput: String = ""
    @State private var revealAPIKey: Bool = false
    @State private var isFetchingModels: Bool = false
    @State private var fetchBannerMessage: String?
    @State private var fetchBannerIsError: Bool = false
    @State private var modelSearchText: String = ""

    @State private var showAddModelSheet: Bool = false
    @State private var newModelID: String = ""
    @State private var newModelDisplayName: String = ""
    @State private var newModelVision: Bool = true
    @State private var newModelReasoning: Bool = false

    @State private var showAddHeaderSheet: Bool = false
    @State private var newHeaderKey: String = ""
    @State private var newHeaderValue: String = ""
    @State private var newHeaderIsSecret: Bool = false

    private var filteredModels: [ModelSpec] {
        let q = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return provider.models }
        return provider.models.filter {
            $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        Form {
            Section("基础连接配置") {
                HStack {
                    Text("启用该服务商")
                    Spacer()
                    Toggle("", isOn: $provider.isEnabled)
                        .labelsHidden()
                }

                TextField("服务商名称", text: $provider.name)

                Picker("接口协议", selection: Binding(
                    get: { provider.protocolType },
                    set: { newProtocol in
                        let oldProtocol = provider.protocolType
                        provider.protocolType = newProtocol
                        provider.baseURL = ProviderTemplate.baseURLAfterProtocolChange(
                            currentBaseURL: provider.baseURL,
                            from: oldProtocol,
                            to: newProtocol
                        )
                    }
                )) {
                    ForEach(APIProtocolType.allCases) { proto in
                        Text(proto.displayName).tag(proto)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("https://api.example.com/v1", text: $provider.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.subheadline.monospaced())

                    Text("请求预览：\(EndpointResolver.previewChatEndpoint(baseURL: provider.baseURL, protocolType: provider.protocolType, sampleModel: provider.models.first?.id ?? "model-id"))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    InsecureHTTPWarningView(baseURL: provider.baseURL)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Group {
                        if revealAPIKey {
                            TextField("输入或粘贴 API Key", text: $apiKeyInput)
                        } else {
                            SecureField("输入或粘贴 API Key", text: $apiKeyInput)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.monospaced())
                    .onChange(of: apiKeyInput) { _, newValue in
                        KeychainService.shared.saveAPIKey(newValue, for: provider.id)
                    }

                    Button {
                        revealAPIKey.toggle()
                    } label: {
                        Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealAPIKey ? "隐藏 API Key" : "显示 API Key")

                    Button {
                        if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !clip.isEmpty {
                            apiKeyInput = clip
                        }
                    } label: {
                        Text("粘贴")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text("API Key（iOS 钥匙串加密存储）")
                    Spacer()
                    if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("已保存")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            } footer: {
                Text("支持随时修改；若使用末尾带 # 的自定义网关地址可跳过自动拼接 /v1。")
            }

            Section {
                ForEach(provider.customHeaders) { header in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(header.key)
                                    .font(.caption.monospaced().weight(.semibold))
                                if header.isSecret {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(header.isSecret ? "••••••••（已存入钥匙串）" : header.value)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            provider.removeCustomHeader(id: header.id)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除请求头 \(header.key)")
                    }
                }

                Button {
                    newHeaderKey = ""
                    newHeaderValue = ""
                    newHeaderIsSecret = false
                    showAddHeaderSheet = true
                } label: {
                    Label("添加自定义 HTTP Header", systemImage: "plus.circle")
                        .font(.footnote)
                }
            } header: {
                Text("自定义请求头（可选）")
            }

            Section {
                Button {
                    Task { await fetchRemoteModels() }
                } label: {
                    HStack {
                        if isFetchingModels {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在请求 /models 拉取可用模型…")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text("一键从接口拉取模型列表 (/models)")
                                .fontWeight(.semibold)
                        }
                    }
                }
                .disabled(isFetchingModels)

                Button {
                    newModelID = ""
                    newModelDisplayName = ""
                    newModelVision = true
                    newModelReasoning = false
                    showAddModelSheet = true
                } label: {
                    Label("手动添加模型 ID", systemImage: "plus")
                }

                if let banner = fetchBannerMessage {
                    HStack(spacing: 8) {
                        Image(systemName: fetchBannerIsError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundStyle(fetchBannerIsError ? .red : .green)
                        Text(banner)
                            .font(.caption)
                            .foregroundStyle(fetchBannerIsError ? .red : .secondary)
                    }
                }

                if provider.models.count > 5 {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("在 \(provider.models.count) 个模型中搜索…", text: $modelSearchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !modelSearchText.isEmpty {
                            Button {
                                modelSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除搜索")
                        }
                    }
                }

                ForEach(filteredModels) { spec in
                    modelConfigRow(spec)
                }
                .onDelete { offsets in
                    let idsToDelete = offsets.map { filteredModels[$0].id }
                    var updated = provider.models
                    updated.removeAll { idsToDelete.contains($0.id) }
                    provider.models = updated
                    try? modelContext.save()
                }
            } header: {
                HStack {
                    Text("模型列表（已启用 \(provider.enabledModels.count)/\(provider.models.count)）")
                    Spacer()
                    if !provider.models.isEmpty {
                        Menu("批量操作") {
                            Button("全部启用") {
                                provider.models = provider.models.map {
                                    var m = $0
                                    m.isEnabled = true
                                    return m
                                }
                                try? modelContext.save()
                            }
                            Button("全部停用") {
                                provider.models = provider.models.map {
                                    var m = $0
                                    m.isEnabled = false
                                    return m
                                }
                                try? modelContext.save()
                            }
                        }
                        .font(.caption)
                    }
                }
            } footer: {
                Text("启用后的模型会出现在聊天框的模型切换器与多模型并发对比列表中。左滑可删除模型。")
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            apiKeyInput = KeychainService.shared.loadAPIKey(for: provider.id)
        }
        .sheet(isPresented: $showAddModelSheet) {
            addModelSheet
        }
        .sheet(isPresented: $showAddHeaderSheet) {
            addHeaderSheet
        }
    }

    @ViewBuilder
    private func modelConfigRow(_ spec: ModelSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.displayName)
                        .font(.subheadline.weight(.medium))
                    Text(spec.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { spec.isEnabled },
                    set: { newVal in
                        updateModel(id: spec.id) { $0.isEnabled = newVal }
                    }
                ))
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Button {
                    updateModel(id: spec.id) { $0.supportsVision.toggle() }
                } label: {
                    Label("识图", systemImage: spec.supportsVision ? "eye.fill" : "eye.slash")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(spec.supportsVision ? .blue : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(spec.supportsVision ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    updateModel(id: spec.id) { $0.supportsReasoning.toggle() }
                } label: {
                    Label("思考链", systemImage: "brain")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(spec.supportsReasoning ? .purple : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(spec.supportsReasoning ? Color.purple.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var addModelSheet: some View {
        NavigationStack {
            Form {
                Section("模型标识") {
                    TextField("模型 ID（必填，如 deepseek-reasoner）", text: $newModelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.subheadline.monospaced())
                        .onChange(of: newModelID) { _, val in
                            newModelVision = ModelSpec.inferVisionSupport(modelID: val)
                            newModelReasoning = ModelSpec.inferReasoningSupport(modelID: val)
                        }

                    TextField("显示名称（选填，留空则同 ID）", text: $newModelDisplayName)
                }

                Section("模型能力标记") {
                    Toggle("支持图片多模态输入", isOn: $newModelVision)
                    Toggle("支持深度思考过程展示", isOn: $newModelReasoning)
                }
            }
            .navigationTitle("手动添加模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddModelSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        let trimmedID = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedID.isEmpty else { return }
                        var list = provider.models
                        let disp = newModelDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let spec = ModelSpec(
                            id: trimmedID,
                            displayName: disp.isEmpty ? trimmedID : disp,
                            isEnabled: true,
                            supportsVision: newModelVision,
                            supportsReasoning: newModelReasoning
                        )
                        if let existingIdx = list.firstIndex(where: { $0.id == trimmedID }) {
                            list[existingIdx] = spec
                        } else {
                            list.insert(spec, at: 0)
                        }
                        provider.models = list
                        try? modelContext.save()
                        showAddModelSheet = false
                    }
                    .fontWeight(.semibold)
                    .disabled(newModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addHeaderSheet: some View {
        NavigationStack {
            Form {
                Section("HTTP 请求头") {
                    TextField("Header 名称（如 HTTP-Referer）", text: $newHeaderKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: newHeaderKey) { _, key in
                            if CustomHeader.looksSensitive(key) {
                                newHeaderIsSecret = true
                            }
                        }
                    Group {
                        if newHeaderIsSecret {
                            SecureField("Header 值", text: $newHeaderValue)
                        } else {
                            TextField("Header 值", text: $newHeaderValue)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Section {
                    Toggle("敏感信息（存入钥匙串）", isOn: $newHeaderIsSecret)
                } footer: {
                    Text("用于鉴权 Token 等敏感值：只保存在 iOS 钥匙串中，不写入本地数据库，界面上也不再显示明文。")
                }
            }
            .navigationTitle("添加自定义 Header")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddHeaderSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let k = newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        provider.addCustomHeader(key: k, value: newHeaderValue, isSecret: newHeaderIsSecret)
                        try? modelContext.save()
                        showAddHeaderSheet = false
                    }
                    .disabled(newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func updateModel(id: String, mutate: (inout ModelSpec) -> Void) {
        var copy = provider.models
        guard let idx = copy.firstIndex(where: { $0.id == id }) else { return }
        mutate(&copy[idx])
        provider.models = copy
        try? modelContext.save()
    }

    private func fetchRemoteModels() async {
        isFetchingModels = true
        fetchBannerMessage = nil
        defer { isFetchingModels = false }

        do {
            let remoteSpecs = try await LLMClient.fetchModels(
                providerName: provider.name,
                protocolType: provider.protocolType,
                baseURL: provider.baseURL,
                apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                customHeaders: provider.resolvedCustomHeaders
            )

            guard !remoteSpecs.isEmpty else {
                fetchBannerIsError = true
                fetchBannerMessage = "接口返回成功，但未解析到可用模型，请尝试手动添加。"
                return
            }

            let existingModels = provider.models
            let hadNoEnabledModels = existingModels.allSatisfy { !$0.isEnabled }
            let autoEnableNew = remoteSpecs.count <= 20
            var merged = existingModels
            var seenIDs = Set(existingModels.map(\.id))
            var newlyAddedCount = 0

            // `seenIDs.insert` also skips duplicates inside the remote list itself.
            for (idx, remote) in remoteSpecs.enumerated() where seenIDs.insert(remote.id).inserted {
                var item = remote
                item.isEnabled = autoEnableNew || (hadNoEnabledModels && idx < 6)
                merged.append(item)
                newlyAddedCount += 1
            }

            provider.models = merged
            try? modelContext.save()

            fetchBannerIsError = false
            if remoteSpecs.count > 20 && newlyAddedCount > 0 {
                fetchBannerMessage = "成功拉取 \(remoteSpecs.count) 个模型（新增 \(newlyAddedCount) 个，已智能勾选常用项，可搜索按需开启）。"
            } else {
                fetchBannerMessage = "连接正常，共同步 \(remoteSpecs.count) 个可用模型（新增 \(newlyAddedCount) 个）。"
            }
        } catch {
            fetchBannerIsError = true
            fetchBannerMessage = error.localizedDescription
        }
    }
}
