import SwiftUI
import SwiftData
import UIKit

struct ProviderDetailView: View {
    @Bindable var provider: ProviderConfig
    var onVerifiedModel: ((ResolvedModelTarget) -> Void)? = nil
    @State private var setupModelID: String?
    @State private var setupTask: Task<Void, Never>?
    @Environment(\.modelContext) private var modelContext

    @State private var saveError: String?
    @State private var keySaved = false
    @State private var keyWriteFailed = false
    @State private var apiKeyInput: String = ""
    @State private var revealAPIKey: Bool = false
    @State private var keyCoordinator: APIKeySaveCoordinator?
    @FocusState private var isAPIKeyFocused: Bool
    @State private var catalog = ProviderModelCatalog()
    @State private var isPinging: Bool = false
    @State private var fetchBannerMessage: String?
    @State private var fetchBannerIsError: Bool = false
    @State private var modelSearchText: String = ""
    @State private var pricingModel: ModelSpec?

    @State private var showAddModelSheet: Bool = false
    @State private var newModelID: String = ""
    @State private var newModelDisplayName: String = ""
    @State private var newModelVision: Bool = true
    @State private var newModelReasoning: Bool = false

    @State private var showAddHeaderSheet: Bool = false
    @State private var newHeaderKey: String = ""
    @State private var newHeaderValue: String = ""
    @State private var newHeaderIsSecret: Bool = false

    @State private var extraAPIKeys: [String] = []
    @State private var showAddExtraKeySheet: Bool = false
    @State private var newExtraKeyInput: String = ""
    @State private var idleTimeoutSelection: Int = 0

    private var activePoolKeyCount: Int {
        var seen = Set<String>()
        let all = [apiKeyInput] + extraAPIKeys
        for raw in all {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { seen.insert(t) }
        }
        return seen.count
    }

    private var catalogRequest: ModelCatalogRequest {
        ModelCatalogRequest(protocolType: provider.protocolType, baseURL: provider.baseURL,
                            apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                            extraKeys: extraAPIKeys, headers: provider.resolvedCustomHeaders)
    }

    private var setupSelection: String {
        let enabled = provider.enabledModels
        if let setupModelID, enabled.contains(where: { $0.id == setupModelID }) { return setupModelID }
        return enabled.first?.id ?? ""
    }

    private var isReadyWithDraftKey: Bool {
        if provider.isReadyForChat { return true }
        guard provider.isEnabled, !provider.enabledModels.isEmpty,
              let url = try? EndpointResolver.chatEndpoint(baseURL: provider.baseURL, protocolType: provider.protocolType),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: provider.baseURL) else { return false }
        return activePoolKeyCount > 0
    }

    private var filteredModels: [ModelSpec] {
        let q = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return provider.models }
        return provider.models.filter {
            $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        Form {
            if let saveError { Text(saveError).foregroundStyle(.red) }
            Section("基础连接配置") {
                HStack {
                    Text("启用该服务商")
                    Spacer()
                    Toggle("", isOn: $provider.isEnabled)
                        .accessibilityIdentifier("provider.enabled")
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

                Picker("流式空闲超时", selection: Binding(
                    get: { idleTimeoutSelection },
                    set: { newTimeout in
                        idleTimeoutSelection = newTimeout
                        provider.idleTimeoutSeconds = newTimeout
                        try? modelContext.save()
                    }
                )) {
                    ForEach(ProviderConnectionSettingsStore.supportedTimeoutOptions, id: \.self) { secs in
                        Text(ProviderConnectionSettingsStore.timeoutLabel(for: secs)).tag(secs)
                    }
                }
            }

            if onVerifiedModel == nil {
                ShareProviderAccessSection(provider: provider, onBeforeToggle: { flushPendingAPIKey() })
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
                    .focused($isAPIKeyFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.monospaced())
                    .submitLabel(.done)
                    .onSubmit { flushPendingAPIKey() }
                    .onChange(of: isAPIKeyFocused) { _, focused in
                        if !focused { flushPendingAPIKey() }
                    }
                    .onChange(of: apiKeyInput) { _, newValue in
                        let coordinator = ensureKeyCoordinator()
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != coordinator.lastSavedValue {
                            keySaved = false
                        } else {
                            keySaved = !trimmed.isEmpty
                        }
                        coordinator.scheduleSave(newValue)
                    }

                    Button {
                        revealAPIKey.toggle()
                    } label: {
                        Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(revealAPIKey ? String(localized: "隐藏 API Key") : String(localized: "显示 API Key"))

                    Button {
                        if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !clip.isEmpty {
                            apiKeyInput = clip
                            flushPendingAPIKey(overrideValue: clip)
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

                ForEach(Array(extraAPIKeys.enumerated()), id: \.offset) { idx, extraKey in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("轮询 Key #\(idx + 2)")
                                .font(.caption.weight(.semibold))
                            Text(KeychainService.maskedKeyPreview(extraKey))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            removeExtraAPIKey(at: idx)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除轮询 Key")
                    }
                }

                Button {
                    newExtraKeyInput = ""
                    showAddExtraKeySheet = true
                } label: {
                    Label("添加轮询 / 备用 API Key", systemImage: "key.radiowaves.forward")
                        .font(.footnote)
                }
            } header: {
                HStack {
                    Text("API Key（iOS 钥匙串加密存储）")
                    if keyWriteFailed {
                        Button("重试") {
                            flushPendingAPIKey(overrideValue: apiKeyInput)
                        }
                    }
                    Spacer()
                    if keySaved && activePoolKeyCount > 0 {
                        Text("已保存")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            } footer: {
                if activePoolKeyCount >= 2 {
                    Text("已启用 \(activePoolKeyCount) 个 Key 自动轮询，遇 429 限流或额度耗尽自动熔断切换。")
                } else {
                    Text("支持随时修改；若使用末尾带 # 的自定义网关地址可跳过自动拼接 /v1。")
                }
            }

            if let onVerifiedModel {
                Section {
                    ModelCatalogPicker(catalog: catalog, request: catalogRequest, fallback: provider.models.filter { $0.catalogStatus != .unlisted },
                                       fallbackTitle: "已配置的模型", selected: setupSelection, refresh: refreshModels,
                                       choose: chooseSetupModel)
                    ModelCatalogRefreshButton(catalog: catalog, request: catalogRequest, refresh: refreshModels)
                    Button {
                        flushPendingAPIKey()
                        guard !keyWriteFailed else { return }
                        let id = setupSelection
                        setupTask = Task {
                            isPinging = true
                            defer { isPinging = false }
                            do {
                                let target = try await ModelSetup.verify(provider: provider, modelID: id, context: modelContext)
                                onVerifiedModel(target)
                            } catch {
                                if !Task.isCancelled { saveError = error.localizedDescription }
                            }
                        }
                    } label: {
                        if isPinging { ProgressView() } else { Text("验证连接并使用此模型") }
                    }
                    .disabled(!isReadyWithDraftKey || setupSelection.isEmpty || keyWriteFailed || catalog.isLoading)
                } footer: {
                    Text("验证仅发送一条固定测试消息，可能产生少量 API 费用。验证成功后返回对话。")
                }
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
                            Text(header.isSecret ? String(localized: "••••••••（已存入钥匙串）") : header.value)
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
                if onVerifiedModel == nil {
                    ModelCatalogRefreshButton(catalog: catalog, request: catalogRequest, refresh: refreshModels)
                        .disabled(isPinging)
                }

                if onVerifiedModel == nil, let probeSpec = provider.enabledModels.first {
                    Button {
                        Task { await pingProviderModel(probeSpec) }
                    } label: {
                        HStack {
                            if isPinging {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在测速验证…")
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                                Text("测试连通性与首字测速 (\(probeSpec.displayName))")
                            }
                        }
                    }
                    .disabled(isPinging || catalog.isLoading)
                }

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
                            Divider()
                            Button("自动匹配主流参考单价") {
                                var matchedCount = 0
                                provider.models = provider.models.map { spec in
                                    var copy = spec
                                    if copy.inputPricePerMillion == nil,
                                       let preset = ModelPricingCatalog.match(modelID: copy.id) {
                                        ModelPricingCatalog.apply(preset, to: &copy)
                                        matchedCount += 1
                                    }
                                    return copy
                                }
                                try? modelContext.save()
                                fetchBannerIsError = false
                                fetchBannerMessage = String(localized: "已为 \(matchedCount) 个未设价模型填入参考单价。")
                            }
                        }
                        .font(.caption)
                    }
                }
            } footer: {
                Text("启用后的模型会出现在聊天框的模型切换器与多模型并发对比列表中。左滑可删除模型。")
            }
        }
        .disabled(onVerifiedModel != nil && isPinging)
        .onChange(of: catalogRequest) { _, _ in
            catalog.reset()
            fetchBannerMessage = nil
        }
        .onDisappear {
            catalog.reset()
            flushPendingAPIKey()
            setupTask?.cancel()
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let loaded = KeychainService.shared.loadAPIKey(for: provider.id)
            let loadedExtras = KeychainService.shared.loadExtraAPIKeys(for: provider.id)
            ensureKeyCoordinator().resetInitial(loaded)
            apiKeyInput = loaded
            extraAPIKeys = loadedExtras
            idleTimeoutSelection = provider.idleTimeoutSeconds
            keySaved = !loaded.isEmpty || !loadedExtras.isEmpty
        }
        .sheet(isPresented: $showAddModelSheet) {
            addModelSheet
        }
        .sheet(isPresented: $showAddHeaderSheet) {
            addHeaderSheet
        }
        .sheet(isPresented: $showAddExtraKeySheet) {
            addExtraKeySheet
        }
        .sheet(item: $pricingModel) { spec in
            ModelPricingSheet(provider: provider, modelID: spec.id)
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
                    if spec.catalogStatus == .unlisted {
                        Text("已移出可选列表，可手动启用").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { spec.isSelectable },
                    set: { newVal in
                        updateModel(id: spec.id) {
                            $0.isEnabled = newVal
                            if newVal && $0.catalogStatus == .unlisted { $0.catalogStatus = .manual }
                        }
                    }
                ))
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Button {
                    pricingModel = spec
                } label: {
                    let hasPrice = spec.inputPricePerMillion != nil && spec.outputPricePerMillion != nil
                    Label(
                        hasPrice
                            ? "\(spec.priceCurrency ?? "USD") \(spec.inputPricePerMillion!.formatted())/\(spec.outputPricePerMillion!.formatted())"
                            : String(localized: "单价"),
                        systemImage: "creditcard"
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(hasPrice ? .green : .primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(hasPrice ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)

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
                if let saveError { Text(saveError).foregroundStyle(.red) }
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
                        let index = list.firstIndex { $0.id == trimmedID }
                        var spec = index.map { list[$0] } ?? ModelSpec(id: trimmedID)
                        if !disp.isEmpty { spec.displayName = disp }
                        spec.supportsVision = newModelVision
                        spec.supportsReasoning = newModelReasoning
                        spec.isEnabled = true
                        spec.catalogStatus = .manual
                        if let existingIdx = index {
                            list[existingIdx] = spec
                        } else {
                            list.insert(spec, at: 0)
                        }
                        provider.models = list
                        try? modelContext.save()
                        if onVerifiedModel != nil {
                            catalog.reset()
                            setupModelID = trimmedID
                        }
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
                if let saveError { Text(saveError).foregroundStyle(.red) }
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
                        let oldHeaders = provider.customHeaders
                        guard provider.addCustomHeader(key: k, value: newHeaderValue, isSecret: newHeaderIsSecret) else {
                            saveError = String(localized: "保存失败，请保留输入并重试。")
                            return
                        }
                        do { try modelContext.save() } catch {
                            for header in provider.customHeaders where !oldHeaders.contains(where: { $0.id == header.id }) {
                                provider.removeCustomHeader(id: header.id)
                            }
                            saveError = error.localizedDescription
                            return
                        }
                        saveError = nil
                        showAddHeaderSheet = false
                    }
                    .disabled(newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addExtraKeySheet: some View {
        NavigationStack {
            Form {
                if let saveError { Text(saveError).foregroundStyle(.red) }
                Section {
                    HStack(spacing: 8) {
                        SecureField("输入或粘贴备用 API Key", text: $newExtraKeyInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())

                        Button {
                            if let clip = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !clip.isEmpty {
                                newExtraKeyInput = clip
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
                } footer: {
                    Text("多个 API Key 会按轮询（Round-Robin）分摊请求；当某个 Key 返回 429 限流、401/402/403 鉴权或余额不足时将自动冷却并秒切下一个 Key。")
                }
            }
            .navigationTitle("添加轮询 Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddExtraKeySheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let candidate = newExtraKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !candidate.isEmpty else { return }
                        flushPendingAPIKey()
                        let primaryTrimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if primaryTrimmed.isEmpty {
                            apiKeyInput = candidate
                            flushPendingAPIKey(overrideValue: candidate)
                            showAddExtraKeySheet = false
                            return
                        }
                        guard candidate != primaryTrimmed && !extraAPIKeys.contains(candidate) else {
                            showAddExtraKeySheet = false
                            return
                        }
                        let updated = extraAPIKeys + [candidate]
                        guard KeychainService.shared.saveExtraAPIKeys(updated, for: provider.id) else {
                            saveError = String(localized: "保存失败，请保留输入并重试。")
                            return
                        }
                        extraAPIKeys = updated
                        keySaved = true
                        saveError = nil
                        showAddExtraKeySheet = false
                    }
                    .fontWeight(.semibold)
                    .disabled(newExtraKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func removeExtraAPIKey(at index: Int) {
        guard extraAPIKeys.indices.contains(index) else { return }
        var updated = extraAPIKeys
        updated.remove(at: index)
        guard KeychainService.shared.saveExtraAPIKeys(updated, for: provider.id) else {
            saveError = String(localized: "保存失败，请保留输入并重试。")
            return
        }
        extraAPIKeys = updated
        keySaved = !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !updated.isEmpty
    }

    private func updateModel(id: String, mutate: (inout ModelSpec) -> Void) {
        var copy = provider.models
        guard let idx = copy.firstIndex(where: { $0.id == id }) else { return }
        mutate(&copy[idx])
        provider.models = copy
        try? modelContext.save()
    }

    private func chooseSetupModel(_ model: ModelSpec) {
        let previous = provider.models
        guard let index = previous.firstIndex(where: { $0.id == model.id }) else { return }
        if !previous[index].isEnabled || index != 0 {
            var updated = previous
            var selected = updated.remove(at: index)
            selected.isEnabled = true
            updated.insert(selected, at: 0)
            provider.models = updated
            do { try modelContext.save() } catch {
                provider.models = previous
                saveError = error.localizedDescription
                return
            }
        }
        setupModelID = model.id
    }

    private func refreshModels() {
        let request = catalogRequest
        fetchBannerMessage = nil
        catalog.refresh(request: request, onSuccess: { live in
            guard request == catalogRequest, provider.modelContext != nil, !provider.isDeleted else { throw CancellationError() }
            let added = try ProviderModelCatalog.save(live, to: provider, in: modelContext)
            fetchBannerIsError = false
            fetchBannerMessage = String(localized: "连接正常，共同步 \(live.count) 个可用模型（新增 \(added) 个）。")
        })
    }

    private func pingProviderModel(_ spec: ModelSpec) async {
        flushPendingAPIKey()
        isPinging = true
        fetchBannerMessage = nil
        defer { isPinging = false }

        do {
            let ping = try await LLMClient.pingModel(
                providerName: provider.name,
                protocolType: provider.protocolType,
                baseURL: provider.baseURL,
                apiKey: apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKeys: extraAPIKeys,
                customHeaders: provider.resolvedCustomHeaders,
                modelID: spec.id,
                supportsReasoning: spec.supportsReasoning,
                idleTimeoutSeconds: provider.customIdleTimeout
            )
            fetchBannerIsError = false
            fetchBannerMessage = String(localized: "连通正常 · 首字响应 \(ping.ttftMs) ms（总耗时 \(ping.totalMs) ms）")
        } catch {
            fetchBannerIsError = true
            fetchBannerMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func ensureKeyCoordinator() -> APIKeySaveCoordinator {
        if let existing = keyCoordinator {
            return existing
        }
        let providerID = provider.id
        let coordinator = APIKeySaveCoordinator(
            initialValue: KeychainService.shared.loadAPIKey(for: providerID),
            saveHandler: { trimmed in
                KeychainService.shared.saveAPIKey(trimmed, for: providerID)
            }
        )
        coordinator.onResult = { ok, trimmed in
            keySaved = ok && (!trimmed.isEmpty || !extraAPIKeys.isEmpty)
            keyWriteFailed = !ok
            saveError = ok ? nil : String(localized: "保存失败，请保留输入并重试。")
        }
        keyCoordinator = coordinator
        return coordinator
    }

    private func flushPendingAPIKey(overrideValue: String? = nil) {
        let coordinator = ensureKeyCoordinator()
        _ = coordinator.flushNow(overrideValue: overrideValue)
    }
}
