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
    @State private var showingQRScanner = false
    @State private var parseNote: String?
    @State private var showAdvancedSettings = false
    @State private var showAllDiscoveredModels = false

    @State private var isBusy = false
    @State private var statusBanner: (ok: Bool, message: String)?
    @State private var verified: VerifiedProviderConnection?
    @State private var updateAccountID: UUID?
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
                if !matchingAccounts.isEmpty {
                    Section {
                        Picker("保存位置", selection: $updateAccountID) {
                            Text("添加独立账号").tag(UUID?.none)
                            ForEach(matchingAccounts) { account in
                                Text("更新「\(account.name)」").tag(Optional(account.id))
                            }
                        }
                        if updateAccountID == nil {
                            TextField("账号名称", text: $draft.name)
                        }
                    }
                }
                verificationSection

                Section {
                    DisclosureGroup("导入连接信息", isExpanded: $showingImport) {
                        Button { readFromSystemClipboard() } label: {
                            Label("读取剪贴板自动识别", systemImage: "doc.on.clipboard")
                        }
                        Button { showingQRScanner = true } label: {
                            Label("扫码或从相册识别二维码配置", systemImage: "qrcode.viewfinder")
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
                        if !isFirstConnection {
                            Button {
                                saveWithoutVerification()
                            } label: {
                                Label("暂不验证，直接保存服务商", systemImage: "tray.and.arrow.down")
                            }
                            .disabled(!canSaveWithoutVerification)
                        }
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
            .onChange(of: updateAccountID) { invalidateVerifiedConnection() }
            .onChange(of: matchingAccounts.map(\.id)) {
                if let updateAccountID, !matchingAccounts.contains(where: { $0.id == updateAccountID }) {
                    self.updateAccountID = nil
                    invalidateVerifiedConnection()
                }
            }
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
            .sheet(isPresented: $showingQRScanner) {
                QRCodeImportSheet { raw in
                    guard let candidate = ClipboardProviderParser.parse(raw) else { return false }
                    draft.apply(candidate)
                    showingImport = false
                    parseNote = nil
                    statusBanner = (true, candidate.confidenceNote)
                    return true
                }
            }
        }
    }

    private var canSaveWithoutVerification: Bool {
        let cleanName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanURL.isEmpty,
              !cleanURL.localizedCaseInsensitiveContains("api.example.com"),
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: cleanURL),
              ProviderTemplate.mismatchedIssuer(apiKey: draft.apiKey, baseURL: draft.baseURL) == nil else {
            return false
        }
        return (try? EndpointResolver.chatEndpoint(baseURL: cleanURL, protocolType: draft.protocolType)) != nil
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
            if let currentVerified = verified {
                Button {
                    do {
                        let (provider, target) = try currentVerified.save(in: modelContext)
                        self.verified = nil
                        finishConnection(provider, target: target)
                    } catch {
                        invalidateVerifiedConnection()
                        statusBanner = (false, error.localizedDescription)
                    }
                } label: {
                    Text(isFirstConnection ? String(localized: "保存并继续") : String(localized: "保存连接"))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("quickSetup.finish")
                .buttonStyle(.borderedProminent)

                companionModelPicker(for: currentVerified)
            } else {
                Button {
                    verificationTask?.cancel()
                    verificationTask = Task { await verify() }
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

    @ViewBuilder
    private func companionModelPicker(for currentVerified: VerifiedProviderConnection) -> some View {
        let pool = (currentVerified.fetched.isEmpty ? draft.suggestedModels : currentVerified.fetched)
            .filter { $0.id != currentVerified.chosenModel.id && $0.catalogStatus != .unlisted }
        if !pool.isEmpty {
            let totalEnabledCount = 1 + currentVerified.additionalEnabledModelIDs.intersection(Set(pool.map(\.id))).count
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("同时启用模型（共 \(totalEnabledCount) 个）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !currentVerified.additionalEnabledModelIDs.isEmpty {
                        Button("仅主模型") {
                            verified?.additionalEnabledModelIDs.removeAll()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    } else {
                        Button("推荐组合") {
                            let recommended = ClipboardProviderParser.pickRecommendedStarterModels(
                                from: [currentVerified.chosenModel] + pool,
                                primaryID: currentVerified.chosenModel.id,
                                protocolType: draft.protocolType,
                                limit: 4
                            )
                            verified?.additionalEnabledModelIDs = Set(recommended.map(\.id)).subtracting([currentVerified.chosenModel.id])
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }

                let displayed = showAllDiscoveredModels ? Array(pool.prefix(30)) : Array(pool.prefix(6))
                ForEach(displayed) { spec in
                    let isChecked = currentVerified.additionalEnabledModelIDs.contains(spec.id)
                    Button {
                        if isChecked {
                            verified?.additionalEnabledModelIDs.remove(spec.id)
                        } else {
                            verified?.additionalEnabledModelIDs.insert(spec.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isChecked ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: spec.displayName)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if spec.displayName != spec.id {
                                    Text(verbatim: spec.id)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if spec.supportsReasoning {
                                Image(systemName: "brain")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                            }
                            if spec.supportsVision {
                                Image(systemName: "eye")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if pool.count > 6 {
                    Button(showAllDiscoveredModels ? String(localized: "收起更多模型") : String(localized: "展开更多候选模型（共 \(pool.count) 个）")) {
                        showAllDiscoveredModels.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.top, 4)
        }
    }

    private func saveWithoutVerification() {
        let cleanName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = LLMClient.sanitizedAPIKey(draft.apiKey)
        let manual = draft.manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        var models = draft.suggestedModels
        if !manual.isEmpty {
            var spec = ModelSpec(id: manual)
            spec.catalogStatus = .manual
            models.removeAll { $0.id == manual }
            models.insert(spec, at: 0)
        }
        var availableName = cleanName.isEmpty ? "Provider" : cleanName
        let usedNames = Set(existingProviders.map(\.name))
        var suffix = 2
        while usedNames.contains(availableName) {
            availableName = "\(cleanName) (\(suffix))"
            suffix += 1
        }
        let provider = ProviderConfig(
            name: availableName,
            protocolType: draft.protocolType,
            baseURL: cleanURL,
            iconSymbol: draft.iconSymbol,
            accentHex: draft.accentHex,
            isEnabled: true,
            sortOrder: Int(Date().timeIntervalSince1970),
            models: models
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
            statusBanner = (false, error.localizedDescription)
            return
        }
        let fallbackSpec = provider.enabledModels.first ?? ModelSpec(id: manual.isEmpty ? "default" : manual)
        dismiss()
        onConnected(provider, provider.makeTarget(for: fallbackSpec))
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
        verified = nil
        statusBanner = nil
        showAllDiscoveredModels = false
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
        verified = nil
        guard let candidate = ClipboardProviderParser.parse(raw) else {
            parseNote = String(localized: "未识别到连接信息。请选择服务商并手动填写密钥或接口地址。")
            return
        }
        draft.apply(candidate)
        pasteInput = ""
        showingImport = false
        parseNote = nil
    }

    private var matchingAccounts: [ProviderConfig] {
        existingProviders.filter { VerifiedProviderConnection.matches($0, draft: draft) }
    }

    @MainActor
    private func verify() async {
        guard !Task.isCancelled else { return }
        let draft = self.draft
        let updateAccountID = self.updateAccountID
        let cleanName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = matchingAccounts.first { $0.id == updateAccountID }
        guard account?.id == updateAccountID else { return }
        let previous = account.map(SystemIntegration.connection)
        let cleanKey = LLMClient.sanitizedAPIKey(draft.apiKey)
        let cleanManual = draft.manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanURL.isEmpty,
              !cleanURL.localizedCaseInsensitiveContains("api.example.com"),
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: cleanURL) else {
            showAdvancedSettings = true
            statusBanner = (false, String(localized: "请填写有效的 HTTPS 接口地址或局域网地址。"))
            return
        }

        if cleanKey.isEmpty && (!NetworkLocation.isLocalOrPrivate(baseURL: cleanURL) || previous?.apiKey.isEmpty == false) {
            statusBanner = (false, String(localized: "请填写 API Key（仅本地局域网服务可免 Key）。"))
            return
        }

        isBusy = true
        statusBanner = nil
        defer { isBusy = false }

        do {
            // Verify the new primary on its own, but also check backups this account will retain.
            if let previous, OpenAICompatibleAdapter.isOpenRouter(cleanURL) {
                _ = try APIKeyPoolRouter.validatedKeys([cleanKey] + (previous.extraAPIKeys ?? []), baseURL: cleanURL)
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
                    customHeaders: previous?.headers ?? []
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
                        supportsVision: ModelSpec.inferVisionSupport(modelID: cleanManual),
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
                    customHeaders: previous?.headers ?? [],
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

            guard self.draft == draft, self.updateAccountID == updateAccountID else { return }
            let candidatePool = fetched.isEmpty ? fallbackCatalog : fetched
            let recommended = ClipboardProviderParser.pickRecommendedStarterModels(
                from: candidatePool,
                primaryID: chosenModel.id,
                protocolType: draft.protocolType,
                limit: 3
            )
            let extras = Set(recommended.map(\.id)).subtracting([chosenModel.id])
            verified = VerifiedProviderConnection(draft: draft, chosenModel: chosenModel, fetched: fetched,
                                                  updateAccountID: updateAccountID, previousConnection: previous,
                                                  additionalEnabledModelIDs: extras)
            statusBanner = (true, String(localized: "验证成功：\(chosenModel.displayName)（首字 \(ping.ttftMs) ms）。"))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            statusBanner = (false, ModelSetup.verificationAdvice(for: error))
        }
    }
}
