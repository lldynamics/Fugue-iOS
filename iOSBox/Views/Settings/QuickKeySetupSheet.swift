import SwiftData
import SwiftUI
import UIKit

struct QuickKeySetupSheet: View {
    var onConnected: (ProviderConfig, ResolvedModelTarget) -> Void = { _, _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ProviderConfig.sortOrder) private var existingProviders: [ProviderConfig]

    @State private var pasteInput = ""
    @State private var name = "OpenAI"
    @State private var protocolType: APIProtocolType = .openAICompatible
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var apiKey = ""
    @State private var manualModelID = ""
    @State private var accentHex = "#10A37F"
    @State private var iconSymbol = "circle.hexagongrid.fill"
    @State private var suggestedModels: [ModelSpec] = []
    @State private var parseNote: String?
    @State private var showAdvancedSettings = false

    @State private var isBusy = false
    @State private var statusBanner: (ok: Bool, message: String)?
    @State private var connectedProvider: ProviderConfig?
    @State private var connectedTarget: ResolvedModelTarget?
    @State private var verificationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        readFromSystemClipboard()
                    } label: {
                        Label("读取剪贴板自动识别", systemImage: "doc.on.clipboard.fill")
                            .fontWeight(.semibold)
                    }
                    .disabled(isBusy)

                    HStack(spacing: 8) {
                        TextField("或粘贴含 URL / Key 的整段文本…", text: $pasteInput, axis: .vertical)
                            .accessibilityIdentifier("quickSetup.configInput")
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())
                        Button("识别") {
                            applyParsedInput(pasteInput)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy || pasteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let parseNote {
                        Text(parseNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("剪贴板智能识别")
                } footer: {
                    Text("仅在您点击上方按钮时读取一次剪贴板，自动提取常见服务商（OpenAI / DeepSeek / Claude / Gemini / OpenRouter / 中转站）的地址与密钥。")
                }

                Section {
                    LabeledContent("服务商", value: name)
                    SecureField("API Key（本地局域网可留空）", text: $apiKey)
                        .accessibilityIdentifier("quickSetup.apiKey")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("确认服务商和 API Key")
                } footer: {
                    Text("可在服务商控制台创建 API Key，免鉴权的局域网服务可留空。")
                }

                if let statusBanner {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: statusBanner.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(statusBanner.ok ? .green : .orange)
                            Text(statusBanner.message)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    if let connectedProvider, let connectedTarget {
                        Button {
                            dismiss()
                            onConnected(connectedProvider, connectedTarget)
                        } label: {
                            Label("完成并开始对话", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                    } else {
                        Button {
                            verificationTask?.cancel()
                            verificationTask = Task { await verifyAndSave() }
                        } label: {
                            HStack(spacing: 8) {
                                if isBusy {
                                    ProgressView()
                                } else {
                                    Image(systemName: "bolt.fill")
                                }
                                Text(isBusy ? "正在拉取并测通…" : "一键拉取并测通模型")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isBusy)
                    }
                } footer: {
                    Text("验证会发送一条测试消息，可能产生少量 API 费用。")
                }

                Section {
                    DisclosureGroup("高级设置", isExpanded: $showAdvancedSettings) {
                        TextField("服务商名称", text: $name)

                        Picker("API 协议类型", selection: Binding(
                            get: { protocolType },
                            set: { newProtocol in
                                baseURL = ProviderTemplate.baseURLAfterProtocolChange(
                                    currentBaseURL: baseURL,
                                    from: protocolType,
                                    to: newProtocol
                                )
                                protocolType = newProtocol
                            }
                        )) {
                            ForEach(APIProtocolType.allCases) { proto in
                                Text(proto.displayName).tag(proto)
                            }
                        }

                        TextField("Base URL", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.subheadline.monospaced())
                        InsecureHTTPWarningView(baseURL: baseURL)
                        TextField("指定测试模型 ID（留空则自动拉取优选）", text: $manualModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())
                    }
                    .accessibilityIdentifier("quickSetup.advanced")
                } footer: {
                    Text("修改接口地址、协议或指定测试模型。")
                }
            }
            .disabled(isBusy)
            .onChange(of: name) { _, _ in invalidateVerifiedConnection() }
            .onChange(of: protocolType) { _, _ in invalidateVerifiedConnection() }
            .onChange(of: baseURL) { _, _ in invalidateVerifiedConnection() }
            .onChange(of: apiKey) { _, _ in invalidateVerifiedConnection() }
            .onChange(of: manualModelID) { _, _ in invalidateVerifiedConnection() }
            .onDisappear { verificationTask?.cancel() }
            .navigationTitle("一键配 Key 并测通")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
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
        pasteInput = String(content.prefix(ClipboardProviderParser.maxInputChars))
        applyParsedInput(pasteInput)
    }

    private func applyParsedInput(_ raw: String) {
        statusBanner = nil
        connectedProvider = nil
        connectedTarget = nil
        guard let candidate = ClipboardProviderParser.parse(raw) else {
            parseNote = String(localized: "未能识别到有效 HTTPS 接口地址或 API Key，可直接在下方手动填写。")
            return
        }
        name = candidate.providerName
        protocolType = candidate.protocolType
        baseURL = candidate.baseURL
        if !candidate.apiKey.isEmpty {
            apiKey = candidate.apiKey
        }
        accentHex = candidate.accentHex
        iconSymbol = candidate.iconSymbol
        suggestedModels = candidate.suggestedModels
        parseNote = candidate.confidenceNote
    }

    @MainActor
    private func verifyAndSave() async {
        guard !Task.isCancelled else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = LLMClient.sanitizedAPIKey(apiKey)
        let cleanManual = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)

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
            var fetched: [ModelSpec] = []
            var fetchError: Error?
            do {
                fetched = try await LLMClient.fetchModels(
                    providerName: cleanName.isEmpty ? "Provider" : cleanName,
                    protocolType: protocolType,
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

            let templateFallback = ProviderTemplate.matching(baseURL: cleanURL, protocolType: protocolType)?.suggestedModels ?? []
            let fallbackCatalog = suggestedModels.isEmpty ? templateFallback : suggestedModels

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
                return ClipboardProviderParser.pickBestStarterModel(from: pool, protocolType: protocolType)
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
                    protocolType: protocolType,
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
                statusBanner = (false, "[\(chosenModel.id)] \(error.localizedDescription)")
                return
            }
            try Task.checkCancellation()

            let matchedExisting = existingProviders.first {
                normalizeURLForMatch($0.baseURL) == normalizeURLForMatch(cleanURL) &&
                    $0.protocolType == protocolType
            }

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
                    protocolType: protocolType,
                    baseURL: cleanURL,
                    iconSymbol: iconSymbol,
                    accentHex: accentHex,
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
            if AppPreferences.shared.defaultTargetID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                AppPreferences.shared.defaultTargetID = target.id
            }

            connectedProvider = savedProvider
            connectedTarget = target
            let countNote = fetched.isEmpty ? "" : String(localized: "（拉取 \(fetched.count) 个模型）")
            statusBanner = (
                true,
                String(localized: "已测通 \(target.modelDisplayName)（首字 \(ping.ttftMs) ms）\(countNote)，已保存并设为可用！")
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            statusBanner = (false, error.localizedDescription)
        }
    }

    private func normalizeURLForMatch(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("#") { cleaned.removeLast() }
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        return cleaned.lowercased()
    }
}
