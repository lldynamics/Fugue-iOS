import SwiftData
import SwiftUI
import UIKit

struct QuickKeySetupSheet: View {
    let isFirstConnection: Bool
    let continuesToGroup: Bool
    let onConnected: (ProviderConfig, ResolvedModelTarget) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ProviderConfig.sortOrder) private var existingProviders: [ProviderConfig]

    @State private var pasteInput = ""
    @State private var draft: ProviderSetupDraft
    @State private var showingImport = false
    @State private var parseNote: String?
    @State private var showAdvancedSettings = false

    @State private var isBusy = false
    @State private var statusBanner: (ok: Bool, message: String)?
    @State private var connectedProvider: ProviderConfig?
    @State private var connectedTarget: ResolvedModelTarget?
    @State private var verificationTask: Task<Void, Never>?
    @State private var setDefault = AppPreferences.shared.defaultTargetID?.isEmpty ?? true
    @State private var choosingProvider = false

    init(isFirstConnection: Bool = false, continuesToGroup: Bool = false,
         draft: ProviderSetupDraft = ProviderSetupDraft(),
         onConnected: @escaping (ProviderConfig, ResolvedModelTarget) -> Void = { _, _ in }) {
        self.isFirstConnection = isFirstConnection
        self.continuesToGroup = continuesToGroup
        self.onConnected = onConnected
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if continuesToGroup { Text("连接后将继续选择群成员。").foregroundStyle(.secondary) }
                ProviderSetupPicker(draft: $draft)
                ProviderSetupKeySection(draft: $draft)
                verificationSection

                Section {
                    DisclosureGroup("导入连接信息", isExpanded: $showingImport) {
                        Button { readFromSystemClipboard() } label: {
                            Label("读取剪贴板自动识别", systemImage: "doc.on.clipboard")
                        }
                        HStack {
                            TextField("或粘贴含 URL / Key 的整段文本…", text: $pasteInput, axis: .vertical)
                                .accessibilityIdentifier("quickSetup.configInput")
                                .lineLimit(1...3)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("识别") { applyParsedInput(pasteInput) }
                                .buttonStyle(.bordered)
                                .disabled(pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let parseNote { Text(parseNote).font(.footnote).foregroundStyle(.secondary) }
                    }
                    DisclosureGroup("高级设置", isExpanded: $showAdvancedSettings) {
                        TextField("服务商名称", text: $draft.name)
                        ProviderSetupProtocolPicker(draft: $draft)
                        TextField("Base URL", text: $draft.baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        InsecureHTTPWarningView(baseURL: draft.baseURL)
                        TextField("指定测试模型 ID（留空则自动拉取优选）", text: $draft.manualModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if isFirstConnection {
                        Button { choosingProvider = true } label: {
                            Label("使用已保存的服务商", systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("quickSetup.savedProviders")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(isBusy)
            .onChange(of: draft) { invalidateVerifiedConnection() }
            .onChange(of: draft.serviceID) {
                parseNote = nil
                if ["custom_openai", "ollama"].contains(draft.serviceID) { showAdvancedSettings = true }
            }
            .onDisappear { verificationTask?.cancel() }
            .navigationTitle("连接模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFirstConnection ? String(localized: "取消") : String(localized: "关闭")) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $choosingProvider) {
                ManualConnectionProvidersView(correctKey: { corrected in
                    draft = corrected
                    choosingProvider = false
                }, onConnected: finishConnection)
            }
        }
    }

    private var verificationSection: some View {
        Section {
            Toggle("设为新对话的默认模型", isOn: $setDefault)
            if let statusBanner {
                Label {
                    Text(statusBanner.message).font(.footnote).textSelection(.enabled)
                } icon: {
                    Image(systemName: statusBanner.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(statusBanner.ok ? .green : .orange)
                }
            }
            if let connectedProvider, let connectedTarget {
                Button {
                    finishConnection(connectedProvider, target: connectedTarget)
                } label: {
                    Text(continuesToGroup ? String(localized: "继续选择群成员")
                         : isFirstConnection ? String(localized: "使用此模型") : String(localized: "完成"))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("quickSetup.finish")
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    verificationTask?.cancel()
                    verificationTask = Task { await verifyAndSave() }
                } label: {
                    HStack {
                        if isBusy { ProgressView() }
                        Text(isBusy ? "正在拉取并测通…" : "验证连接")
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("quickSetup.verify")
                .buttonStyle(.borderedProminent)
                .disabled(ProviderTemplate.mismatchedIssuer(apiKey: draft.apiKey, baseURL: draft.baseURL) != nil)
            }
        } footer: {
            Text("验证会发送一条测试消息，可能产生少量 API 费用。")
        }
    }

    private func finishConnection(_ provider: ProviderConfig, target: ResolvedModelTarget) {
        guard provider.modelContext != nil, provider.isReadyForChat,
              provider.enabledModels.contains(where: { $0.id == target.modelID }) else {
            statusBanner = (false, ModelSetup.verificationAdvice(for: LLMError.unavailableModel))
            choosingProvider = false
            return
        }
        if setDefault { AppPreferences.shared.defaultTargetID = target.id }
        if !continuesToGroup { dismiss() }
        onConnected(provider, target)
    }

    private func invalidateVerifiedConnection() {
        connectedProvider = nil
        connectedTarget = nil
        statusBanner = nil
    }

    private func readFromSystemClipboard() {
        let content = UIPasteboard.general.string ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parseNote = String(localized: "剪贴板为空，请先复制 Key 或接口配置文本。")
            return
        }
        applyParsedInput(content)
    }

    private func applyParsedInput(_ raw: String) {
        statusBanner = nil
        connectedProvider = nil
        connectedTarget = nil
        guard let candidate = ClipboardProviderParser.parse(raw) else {
            parseNote = String(localized: "未识别到连接信息。请选择服务商并手动填写密钥或接口地址。")
            return
        }
        draft.apply(candidate)
        pasteInput = ""
        showingImport = false
        parseNote = nil
    }

    private func existingProvider(for url: String) -> ProviderConfig? {
        existingProviders.first {
            normalizeURLForMatch($0.baseURL) == normalizeURLForMatch(url) && $0.protocolType == draft.protocolType
        }
    }

    @MainActor
    private func verifyAndSave() async {
        guard !Task.isCancelled else { return }
        let cleanName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = LLMClient.sanitizedAPIKey(draft.apiKey)
        let cleanManual = draft.manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanURL.isEmpty,
              !cleanURL.localizedCaseInsensitiveContains("api.example.com"),
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: cleanURL) else {
            showAdvancedSettings = true
            statusBanner = (false, String(localized: "请填写有效的 HTTPS 接口地址或局域网地址。"))
            return
        }

        if cleanKey.isEmpty && !NetworkLocation.isLocalOrPrivate(baseURL: cleanURL) {
            statusBanner = (false, String(localized: "请填写 API Key（仅本地局域网服务可免 Key）。"))
            return
        }

        isBusy = true
        statusBanner = nil
        defer { isBusy = false }

        do {
            // Verify the new primary on its own, but also check backups this account will retain.
            if let existing = existingProvider(for: cleanURL), OpenAICompatibleAdapter.isOpenRouter(cleanURL) {
                _ = try APIKeyPoolRouter.validatedKeys([cleanKey] + existing.extraAPIKeys, baseURL: cleanURL)
            }
            var fetched: [ModelSpec] = []
            var fetchError: Error?
            do {
                fetched = try await LLMClient.fetchModels(
                    providerName: cleanName.isEmpty ? "Provider" : cleanName,
                    protocolType: draft.protocolType,
                    baseURL: cleanURL,
                    apiKey: cleanKey,
                    apiKeys: [],
                    customHeaders: []
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                fetchError = error
            }
            try Task.checkCancellation()

            let fallbackCatalog = draft.suggestedModels

            let picked: ModelSpec? = {
                if !cleanManual.isEmpty {
                    return ModelSpec(
                        id: cleanManual,
                        displayName: cleanManual,
                        supportsVision: true,
                        supportsReasoning: ModelSpec.inferReasoningSupport(modelID: cleanManual)
                    )
                }
                let pool = fetched.isEmpty ? fallbackCatalog : fetched
                return ClipboardProviderParser.pickBestStarterModel(from: pool, protocolType: draft.protocolType)
            }()

            guard let chosenModel = picked else {
                if let fetchError {
                    throw fetchError
                }
                showAdvancedSettings = true
                statusBanner = (false, String(localized: "未从接口获取到可用模型，请填写“指定测试模型 ID”后重试。"))
                return
            }

            let providerTitle = cleanName.isEmpty ? "Provider" : cleanName
            let ping: LLMPingResult
            do {
                ping = try await LLMClient.pingModel(
                    providerName: providerTitle,
                    protocolType: draft.protocolType,
                    baseURL: cleanURL,
                    apiKey: cleanKey,
                    apiKeys: [],
                    customHeaders: [],
                    modelID: chosenModel.id,
                    supportsReasoning: chosenModel.supportsReasoning
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                showAdvancedSettings = true
                statusBanner = (false, "[\(chosenModel.id)] \(ModelSetup.verificationAdvice(for: error, checkingModel: true))")
                return
            }
            try Task.checkCancellation()

            let matchedExisting = existingProvider(for: cleanURL)

            var mergedModels = ProviderModelCatalog.merging(
                fetched.isEmpty ? fallbackCatalog : fetched,
                with: matchedExisting?.models ?? [],
                choosing: chosenModel.id,
                fromAPI: !fetched.isEmpty
            )
            if !cleanManual.isEmpty,
               !fetched.contains(where: { $0.id == chosenModel.id }),
               let idx = mergedModels.firstIndex(where: { $0.id == chosenModel.id }) {
                mergedModels[idx].catalogStatus = .manual
            }

            let savedProvider: ProviderConfig
            if let existing = matchedExisting {
                let previousModels = existing.models
                let previousEnabled = existing.isEnabled
                let previousName = existing.name
                let previousKey = existing.apiKey
                existing.name = providerTitle
                existing.models = mergedModels
                existing.isEnabled = true

                if !cleanKey.isEmpty {
                    guard KeychainService.shared.saveAPIKey(cleanKey, for: existing.credentialID) else {
                        existing.name = previousName
                        existing.models = previousModels
                        existing.isEnabled = previousEnabled
                        statusBanner = (false, String(localized: "钥匙串保存失败，请重试。"))
                        return
                    }
                }
                do {
                    try modelContext.save()
                } catch {
                    existing.name = previousName
                    existing.models = previousModels
                    existing.isEnabled = previousEnabled
                    if !cleanKey.isEmpty {
                        if previousKey.isEmpty {
                            KeychainService.shared.deleteAPIKey(for: existing.credentialID)
                        } else {
                            KeychainService.shared.saveAPIKey(previousKey, for: existing.credentialID)
                        }
                    }
                    throw error
                }
                savedProvider = existing
            } else {
                let provider = ProviderConfig(
                    name: providerTitle,
                    protocolType: draft.protocolType,
                    baseURL: cleanURL,
                    iconSymbol: draft.iconSymbol,
                    accentHex: draft.accentHex,
                    isEnabled: true,
                    sortOrder: Int(Date().timeIntervalSince1970),
                    models: mergedModels
                )
                if !cleanKey.isEmpty {
                    guard KeychainService.shared.saveAPIKey(cleanKey, for: provider.credentialID) else {
                        statusBanner = (false, String(localized: "钥匙串保存失败，请重试。"))
                        return
                    }
                }
                modelContext.insert(provider)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.delete(provider)
                    provider.deleteAllSecrets()
                    throw error
                }
                savedProvider = provider
            }

            let verifiedSpec = savedProvider.enabledModels.first(where: { $0.id == chosenModel.id }) ?? chosenModel
            let target = savedProvider.makeTarget(for: verifiedSpec)

            connectedProvider = savedProvider
            connectedTarget = target
            let countNote = fetched.isEmpty ? "" : String(localized: "（拉取 \(fetched.count) 个模型）")
            statusBanner = (
                true,
                String(localized: "已测通 \(target.providerName) · \(target.modelDisplayName)（首字 \(ping.ttftMs) ms）\(countNote)，已保存并设为可用！")
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            statusBanner = (false, ModelSetup.verificationAdvice(for: error))
        }
    }

    private func normalizeURLForMatch(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("#") { cleaned.removeLast() }
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned.lowercased()
    }
}
