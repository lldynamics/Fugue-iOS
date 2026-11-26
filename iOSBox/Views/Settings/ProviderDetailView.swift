import SwiftUI
import SwiftData
import UIKit

struct ProviderDetailView: View {
    private enum ModelListFilter: String, CaseIterable, Identifiable {
        case all
        case enabled
        case vision
        case reasoning
        case free
        case unlisted

        var id: String { rawValue }
    }

    private struct InspectedModelID: Identifiable {
        let id: String
    }

    private static let iconOptions: [String] = [
        "server.rack", "bolt.horizontal.circle", "arrow.triangle.branch", "brain.head.profile",
        "cpu.fill", "sparkles", "wand.and.stars", "cloud.fill",
        "bolt.fill", "moon.stars.fill", "cube.transparent.fill", "desktopcomputer"
    ]

    private static let accentHexOptions: [String] = [
        "#3F6EF6", "#0D9488", "#10A37F", "#6366F1",
        "#7C3AED", "#D97757", "#F55036", "#059669",
        "#0284C7", "#E11D48"
    ]

    @Bindable var provider: ProviderConfig
    var onVerifiedModel: ((ResolvedModelTarget) -> Void)? = nil
    let correctKey: (ProviderSetupDraft) -> Void
    @State private var setupModelID: String?
    @State private var setupTask: Task<Void, Never>?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var saveError: String?
    @State private var keySaved = false
    @State private var keyWriteFailed = false
    @State private var apiKeyInput: String = ""
    @State private var revealAPIKey: Bool = false
    @State private var keyCoordinator: APIKeySaveCoordinator?
    @FocusState private var isAPIKeyFocused: Bool
    @State private var catalog = ProviderModelCatalog()
    @State private var isPinging: Bool = false
    @State private var selectedProbeModelID: String?
    @State private var fetchBannerMessage: String?
    @State private var fetchBannerIsError: Bool = false
    @State private var modelSearchText: String = ""
    @State private var modelFilter: ModelListFilter = .all
    @State private var isReorderingModels: Bool = false
    @State private var pricingModel: ModelSpec?
    @State private var inspectedModel: InspectedModelID?

    @State private var showMoreConnectionSettings: Bool = false
    @State private var showAppearanceSheet: Bool = false
    @State private var shareAccessEnabled: Bool = false
    @State private var shareAccessError: String?

    @State private var showAddModelSheet: Bool = false
    @State private var newModelID: String = ""
    @State private var newModelDisplayName: String = ""
    @State private var newModelVision: Bool = true
    @State private var newModelReasoning: Bool = false

    @State private var showHeaderEditorSheet: Bool = false
    @State private var editingHeaderID: UUID?
    @State private var newHeaderKey: String = ""
    @State private var newHeaderValue: String = ""
    @State private var newHeaderIsSecret: Bool = false

    @State private var extraAPIKeys: [String] = []
    @State private var showAddExtraKeySheet: Bool = false
    @State private var newExtraKeyInput: String = ""
    @State private var idleTimeoutSelection: Int = 0
    @State private var balanceStore = ProviderBalanceStore.shared
    @State private var cooldownTick: Int = 0
    @State private var keyProbeStatus: [String: (ok: Bool, text: String)] = [:]
    @State private var probingKeyDigest: String?
    @State private var editingLabelKeyRaw: String?
    @State private var keyLabelDraft: String = ""

    private var activePoolKeyCount: Int {
        var seen = Set<String>()
        let all = [apiKeyInput] + extraAPIKeys
        for raw in all {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { seen.insert(t) }
        }
        return seen.count
    }

    private var mismatchedIssuer: ProviderTemplate? {
        ProviderTemplate.mismatchedIssuer(apiKey: apiKeyInput, baseURL: provider.baseURL)
    }

    private var catalogRequest: ModelCatalogRequest {
        ModelCatalogRequest(protocolType: provider.protocolType, baseURL: provider.baseURL,
                            apiKey: LLMClient.sanitizedAPIKey(apiKeyInput),
                            extraKeys: extraAPIKeys, headers: provider.resolvedCustomHeaders)
    }

    private var setupSelection: String {
        let enabled = provider.enabledModels
        if let setupModelID, enabled.contains(where: { $0.id == setupModelID }) { return setupModelID }
        return enabled.first?.id ?? ""
    }

    private var activeProbeSpec: ModelSpec? {
        let enabled = provider.enabledModels
        if let selectedProbeModelID, let hit = enabled.first(where: { $0.id == selectedProbeModelID }) {
            return hit
        }
        return enabled.first
    }

    private var isReadyWithDraftKey: Bool {
        if provider.isReadyForChat { return true }
        guard provider.isEnabled, !provider.enabledModels.isEmpty,
              let url = try? EndpointResolver.chatEndpoint(baseURL: provider.baseURL, protocolType: provider.protocolType),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              !NetworkLocation.isPlainHTTPToPublicHost(baseURL: provider.baseURL) else { return false }
        return activePoolKeyCount > 0
    }

    private var unlistedCount: Int {
        provider.models.filter { $0.catalogStatus == .unlisted }.count
    }

    private var freeModelCount: Int {
        provider.models.filter { Self.isFreeModel($0) }.count
    }

    private static func isFreeModel(_ spec: ModelSpec) -> Bool {
        if spec.id.lowercased().hasSuffix(":free") { return true }
        guard let input = spec.inputPricePerMillion, let output = spec.outputPricePerMillion else { return false }
        return input == 0 && output == 0
    }

    private var canReorderModels: Bool {
        modelFilter == .all && modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && provider.models.count > 1
    }

    private var filteredModels: [ModelSpec] {
        let q = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return provider.models.filter { spec in
            let matchesFilter: Bool = {
                switch modelFilter {
                case .all: return true
                case .enabled: return spec.isSelectable
                case .vision: return spec.supportsVision && spec.catalogStatus != .unlisted
                case .reasoning: return spec.supportsReasoning && spec.catalogStatus != .unlisted
                case .free: return Self.isFreeModel(spec)
                case .unlisted: return spec.catalogStatus == .unlisted
                }
            }()
            guard matchesFilter else { return false }
            guard !q.isEmpty else { return true }
            return spec.id.lowercased().contains(q) || spec.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        Form {
            if onVerifiedModel != nil {
                firstSetupSections
            } else {
                fullSettingsSections
            }
        }
        .environment(\.editMode, .constant(isReorderingModels && canReorderModels ? .active : .inactive))
        .scrollContentBackground(.hidden)
        .background(DS.Surface.grouped)
        .disabled(onVerifiedModel != nil && isPinging)
        .onChange(of: catalogRequest) { _, _ in
            catalog.reset()
            fetchBannerMessage = nil
        }
        .onChange(of: canReorderModels) { _, allowed in
            if !allowed && isReorderingModels {
                isReorderingModels = false
            }
        }
        .onDisappear {
            catalog.reset()
            flushPendingAPIKey()
            setupTask?.cancel()
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let loaded = provider.apiKey
            let loadedExtras = provider.extraAPIKeys
            ensureKeyCoordinator().resetInitial(loaded)
            apiKeyInput = loaded
            extraAPIKeys = loadedExtras
            idleTimeoutSelection = provider.idleTimeoutSeconds
            keySaved = !loaded.isEmpty || !loadedExtras.isEmpty
            shareAccessEnabled = SystemIntegration.shared.isEnabled(provider)
        }
        .onChange(of: SystemIntegration.destinationDigest(for: provider)) {
            shareAccessEnabled = SystemIntegration.shared.isEnabled(provider)
        }
        .sheet(isPresented: $showAddModelSheet) {
            addModelSheet
        }
        .sheet(isPresented: $showHeaderEditorSheet) {
            headerEditorSheet
        }
        .sheet(isPresented: $showAddExtraKeySheet) {
            addExtraKeySheet
        }
        .sheet(isPresented: $showAppearanceSheet) {
            appearanceEditorSheet
        }
        .sheet(item: $pricingModel) { spec in
            ModelPricingSheet(provider: provider, modelID: spec.id)
        }
        .sheet(item: $inspectedModel) { item in
            ModelInspectorSheet(provider: provider, modelID: item.id)
        }
        .alert(
            "设置 Key 备注标签",
            isPresented: Binding(
                get: { editingLabelKeyRaw != nil },
                set: { if !$0 { editingLabelKeyRaw = nil; keyLabelDraft = "" } }
            )
        ) {
            TextField("例如：主力按量号、免费号 B", text: $keyLabelDraft)
            Button("取消", role: .cancel) {
                editingLabelKeyRaw = nil
                keyLabelDraft = ""
            }
            Button("保存") {
                if let rawKey = editingLabelKeyRaw {
                    ProviderConnectionSettingsStore.shared.setKeyLabel(keyLabelDraft, for: rawKey, providerID: provider.id)
                    cooldownTick &+= 1
                }
                editingLabelKeyRaw = nil
                keyLabelDraft = ""
            }
        } message: {
            Text("备注仅与密钥摘要关联保存在本机，方便在多 Key 轮询池中区分账号用途。")
        }
        .task(id: "\(provider.id.uuidString)-\(activePoolKeyCount)") {
            while !Task.isCancelled {
                let cooling = APIKeyPoolRouter.shared.coolingKeyCount(
                    keys: [apiKeyInput] + extraAPIKeys,
                    protocolType: provider.protocolType,
                    baseURL: provider.baseURL
                )
                if cooling > 0 {
                    cooldownTick &+= 1
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    @ViewBuilder
    private var fullSettingsSections: some View {
        if let saveError { Text(saveError).foregroundStyle(DS.StatusText.error) }
        Section("基础连接配置") {
            Toggle("启用该服务商", isOn: Binding(
                get: { provider.isEnabled },
                set: { newValue in
                    provider.isEnabled = newValue
                    if !newValue {
                        try? SystemIntegration.shared.setEnabled(false, provider: provider, context: modelContext)
                        shareAccessEnabled = false
                    }
                    try? modelContext.save()
                }
            ))
            .accessibilityIdentifier("provider.enabled")

            HStack(spacing: DS.Spacing.sm) {
                Button {
                    showAppearanceSheet = true
                } label: {
                    DSIconTile(
                        systemImage: provider.iconSymbol,
                        tint: Color(hex: provider.accentHex),
                        size: 38,
                        cornerRadius: DS.Radius.sm
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("自定义图标与颜色")

                VStack(alignment: .leading, spacing: 4) {
                    Text("服务商名称").font(.caption).foregroundStyle(.secondary)
                    TextField("例如：我的服务商", text: $provider.name)
                        .accessibilityLabel("服务商名称")
                }
            }

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

            if ProviderBalanceService.supportsBalanceQuery(protocolType: provider.protocolType, baseURL: provider.baseURL) {
                providerBalanceRow
            }
        }

        apiKeySection

        modelsManagementSection

        advancedConnectionSection
    }

    @ViewBuilder
    private var modelsManagementSection: some View {
        Section {
            if onVerifiedModel == nil {
                ModelCatalogRefreshButton(catalog: catalog, request: catalogRequest, refresh: refreshModels)
                    .disabled(isPinging)
            }

            if onVerifiedModel == nil, let probeSpec = activeProbeSpec {
                HStack(spacing: 8) {
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
                                    .lineLimit(1)
                            }
                        }
                    }
                    .disabled(isPinging || catalog.isLoading || mismatchedIssuer != nil)

                    if provider.enabledModels.count > 1 {
                        Spacer()
                        Menu {
                            ForEach(provider.enabledModels) { candidate in
                                Button {
                                    selectedProbeModelID = candidate.id
                                    Task { await pingProviderModel(candidate) }
                                } label: {
                                    HStack {
                                        Text(verbatim: candidate.displayName)
                                        if candidate.id == probeSpec.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text("换模型测")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPinging)
                    }
                }
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
                        .foregroundStyle(fetchBannerIsError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                }
            }

            if provider.models.count > 5 || modelFilter != .all {
                VStack(alignment: .leading, spacing: 8) {
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

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            filterChip(.all, title: String(localized: "全部 (\(provider.models.count))"))
                            filterChip(.enabled, title: String(localized: "已启用 (\(provider.enabledModels.count))"))
                            filterChip(.vision, title: String(localized: "识图"))
                            filterChip(.reasoning, title: String(localized: "思考"))
                            if freeModelCount > 0 || modelFilter == .free {
                                filterChip(.free, title: String(localized: "免费 (\(freeModelCount))"))
                            }
                            if unlistedCount > 0 || modelFilter == .unlisted {
                                filterChip(.unlisted, title: String(localized: "已下架 (\(unlistedCount))"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if filteredModels.isEmpty && !provider.models.isEmpty {
                HStack {
                    Text("当前筛选下无匹配模型")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重置筛选") {
                        modelFilter = .all
                        modelSearchText = ""
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
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
            .onMove(perform: canReorderModels ? moveModels : nil)
        } header: {
            HStack {
                Text("模型列表（已启用 \(provider.enabledModels.count)/\(provider.models.count)）")
                Spacer()
                if canReorderModels {
                    Button(isReorderingModels ? String(localized: "完成排序") : String(localized: "排序")) {
                        isReorderingModels.toggle()
                    }
                    .font(.caption)
                    .padding(.trailing, 8)
                }
                if !provider.models.isEmpty {
                    Menu {
                        if provider.models.count > 4 {
                            Button("仅保留推荐常用模型") {
                                let recommended = Set(
                                    ClipboardProviderParser.pickRecommendedStarterModels(
                                        from: provider.models,
                                        protocolType: provider.protocolType,
                                        limit: 4
                                    ).map(\.id)
                                )
                                guard !recommended.isEmpty else { return }
                                provider.models = provider.models.map {
                                    var m = $0
                                    if m.catalogStatus != .unlisted {
                                        m.isEnabled = recommended.contains(m.id)
                                    }
                                    return m
                                }
                                try? modelContext.save()
                                fetchBannerIsError = false
                                fetchBannerMessage = String(localized: "已精简启用 \(provider.enabledModels.count) 个推荐模型。")
                            }
                            Divider()
                        }
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
                        if unlistedCount > 0 {
                            Divider()
                            Button(role: .destructive) {
                                let removed = unlistedCount
                                provider.models = provider.models.filter { $0.catalogStatus != .unlisted }
                                if modelFilter == .unlisted { modelFilter = .all }
                                try? modelContext.save()
                                fetchBannerIsError = false
                                fetchBannerMessage = String(localized: "已清理 \(removed) 个已下架模型。")
                            } label: {
                                Label("清理已下架模型 (\(unlistedCount))", systemImage: "trash")
                            }
                        }
                    } label: {
                        Text("批量操作")
                            .frame(minHeight: DS.TouchTarget.minimum + 2)
                            .contentShape(Rectangle())
                    }
                    .font(.caption)
                }
            }
        } footer: {
            Text("点击模型名称可修改显示别名与单独测速；启用后的模型会出现在对话切换器与并发对比列表中。左滑可删除模型。")
        }
    }

    @ViewBuilder
    private var advancedConnectionSection: some View {
        let degradedCount = GatewayCapabilityCache.shared.degradedModelCount(
            protocolType: provider.protocolType,
            baseURL: provider.baseURL,
            modelIDs: provider.models.map(\.id)
        )
        Section {
            DisclosureGroup(isExpanded: $showMoreConnectionSettings) {
                Button {
                    showAppearanceSheet = true
                } label: {
                    HStack {
                        Label("图标与主题颜色", systemImage: "paintpalette")
                            .foregroundStyle(.primary)
                        Spacer()
                        DSIconTile(
                            systemImage: provider.iconSymbol,
                            tint: Color(hex: provider.accentHex),
                            size: 26,
                            cornerRadius: 6
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("备注说明（选填）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("记录充值后台网址、令牌分组说明或到期时间…", text: $provider.notes, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.subheadline)
                        .onChange(of: provider.notes) { _, _ in
                            provider.updatedAt = Date()
                            try? modelContext.save()
                        }
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

                Toggle("允许系统分享使用此服务商", isOn: Binding(
                    get: { shareAccessEnabled },
                    set: { enabled in
                        flushPendingAPIKey()
                        shareAccessEnabled = enabled
                        do {
                            try SystemIntegration.shared.setEnabled(enabled, provider: provider, context: modelContext)
                            shareAccessError = nil
                        } catch {
                            shareAccessError = error.localizedDescription
                        }
                    }
                ))
                if let shareAccessError {
                    Text(shareAccessError)
                        .font(.caption)
                        .foregroundStyle(DS.StatusText.error)
                }

                ForEach(provider.customHeaders) { header in
                    HStack(spacing: 10) {
                        Button {
                            editingHeaderID = header.id
                            newHeaderKey = header.key
                            newHeaderValue = header.isSecret ? "" : header.value
                            newHeaderIsSecret = header.isSecret
                            showHeaderEditorSheet = true
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(header.key)
                                        .font(.caption.monospaced().weight(.semibold))
                                        .foregroundStyle(header.isEnabled ? .primary : .secondary)
                                    if header.isSecret {
                                        Image(systemName: "lock.fill")
                                            .font(.caption2)
                                            .foregroundStyle(DS.StatusText.success)
                                    }
                                }
                                Text(header.isSecret ? String(localized: "••••••••（已存入钥匙串）") : header.value)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Toggle("启用请求头 \(header.key)", isOn: Binding(
                            get: { header.isEnabled },
                            set: { val in
                                var headers = provider.customHeaders
                                if let idx = headers.firstIndex(where: { $0.id == header.id }) {
                                    headers[idx].isEnabled = val
                                    provider.customHeaders = headers
                                    try? modelContext.save()
                                }
                            }
                        ))
                        .labelsHidden()
                        .controlSize(.small)

                        Button(role: .destructive) {
                            provider.removeCustomHeader(id: header.id)
                            try? modelContext.save()
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(DS.StatusText.error)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除请求头 \(header.key)")
                    }
                }

                Button {
                    editingHeaderID = nil
                    newHeaderKey = ""
                    newHeaderValue = ""
                    newHeaderIsSecret = false
                    showHeaderEditorSheet = true
                } label: {
                    Label("添加自定义 HTTP Header", systemImage: "plus.circle")
                        .font(.footnote)
                }

                Button {
                    let cleared = GatewayCapabilityCache.shared.clear(
                        protocolType: provider.protocolType,
                        baseURL: provider.baseURL,
                        modelIDs: provider.models.map(\.id)
                    )
                    fetchBannerIsError = false
                    fetchBannerMessage = cleared > 0
                        ? String(localized: "已重置 \(cleared) 个模型的网关参数兼容缓存。")
                        : String(localized: "当前服务商没有被降级屏蔽的网关参数。")
                } label: {
                    HStack {
                        Label("重置网关参数兼容缓存", systemImage: "arrow.counterclockwise")
                            .font(.footnote)
                        if degradedCount > 0 {
                            Spacer()
                            Text("\(degradedCount) 项已降级")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } label: {
                HStack {
                    Label("连接参数、请求头与备注", systemImage: "slider.horizontal.3")
                    Spacer()
                    let activeHeaders = provider.customHeaders.filter(\.isEnabled).count
                    if activeHeaders > 0 {
                        DSBadge(text: "Header \(activeHeaders)", style: .neutral)
                    }
                }
            }
        } footer: {
            Text("包含图标配色、服务商备注、系统分享授权、流式超时、自定义 HTTP Header 与网关兼容性排障。")
        }
    }

    private func filterChip(_ filter: ModelListFilter, title: String) -> some View {
        let selected = modelFilter == filter
        return Button {
            modelFilter = filter
        } label: {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func moveModels(from source: IndexSet, to destination: Int) {
        var updated = provider.models
        updated.move(fromOffsets: source, toOffset: destination)
        provider.models = updated
        try? modelContext.save()
    }

    private func moveModelToTop(id: String) {
        var updated = provider.models
        guard let idx = updated.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        let item = updated.remove(at: idx)
        updated.insert(item, at: 0)
        provider.models = updated
        try? modelContext.save()
    }

    @ViewBuilder
    private var firstSetupSections: some View {
        if !provider.isEnabled {
            Section {
                Toggle("启用该服务商", isOn: $provider.isEnabled)
                    .accessibilityIdentifier("provider.enabled")
            } footer: {
                Text("启用后才能验证并使用此服务商。")
            }
        }
        apiKeySection
        if let onVerifiedModel {
            Section {
                ModelCatalogPicker(catalog: catalog, request: catalogRequest, fallback: provider.models.filter { $0.catalogStatus != .unlisted },
                                   fallbackTitle: "已配置的模型", selected: setupSelection, refresh: refreshModels,
                                   choose: chooseSetupModel)
                ModelCatalogRefreshButton(catalog: catalog, request: catalogRequest, refresh: refreshModels)
                Button {
                    newModelID = ""
                    newModelDisplayName = ""
                    newModelVision = true
                    newModelReasoning = false
                    showAddModelSheet = true
                } label: {
                    Label("手动添加模型 ID", systemImage: "plus")
                }
                Button {
                    flushPendingAPIKey()
                    guard !keyWriteFailed else { return }
                    let id = setupSelection
                    saveError = nil
                    isPinging = true
                    setupTask = Task {
                        defer { isPinging = false }
                        do {
                            let target = try await ModelSetup.verify(provider: provider, modelID: id, context: modelContext)
                            onVerifiedModel(target)
                        } catch {
                            if !Task.isCancelled { saveError = ModelSetup.verificationAdvice(for: error, checkingModel: true) }
                        }
                    }
                } label: {
                    if isPinging {
                        HStack { ProgressView(); Text("正在验证连接…") }
                    } else {
                        Text("验证连接并使用此模型").fontWeight(.semibold)
                    }
                }
                .accessibilityIdentifier("provider.setup.verify")
                .disabled(!isReadyWithDraftKey || setupSelection.isEmpty || keyWriteFailed || catalog.isLoading || mismatchedIssuer != nil)
                if let saveError {
                    Text(saveError).foregroundStyle(DS.StatusText.error)
                }
            } header: {
                Text("选择模型并验证")
            } footer: {
                Text("验证仅发送一条固定测试消息，可能产生少量 API 费用。验证成功后返回对话。")
            }
        }
        Section {
            NavigationLink {
                ProviderDetailView(provider: provider, correctKey: correctKey)
            } label: {
                Label("高级设置", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("provider.setup.advanced")
        } footer: {
            Text("修改接口地址、协议、请求头或管理模型。")
        }
    }

    private var apiKeySection: some View {
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
                .accessibilityIdentifier("provider.setup.key")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
                .submitLabel(.done)
                .onSubmit { isAPIKeyFocused = false }
                .onChange(of: isAPIKeyFocused) { _, focused in
                    if !focused { flushPendingAPIKey() }
                }
                .onChange(of: apiKeyInput) { _, newValue in
                    let coordinator = ensureKeyCoordinator()
                    if mismatchedIssuer != nil {
                        coordinator.resetInitial(coordinator.lastSavedValue)
                        keySaved = false
                        keyWriteFailed = false
                        return
                    }
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
                        .frame(width: DS.TouchTarget.minimum + 2, height: DS.TouchTarget.minimum + 2)
                        .contentShape(Rectangle())
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

            if let issuer = mismatchedIssuer {
                ProviderKeyCorrection(issuer: issuer) {
                    let draft = ProviderSetupDraft(template: issuer, apiKey: apiKeyInput)
                    apiKeyInput = ensureKeyCoordinator().lastSavedValue
                    isAPIKeyFocused = false
                    correctKey(draft)
                }
            }

            let _ = cooldownTick
            if onVerifiedModel == nil, !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let primaryLabel = ProviderConnectionSettingsStore.shared.keyLabel(for: apiKeyInput, providerID: provider.id)
                let primaryCooling = APIKeyPoolRouter.shared.remainingCooldownSeconds(
                    key: apiKeyInput,
                    protocolType: provider.protocolType,
                    baseURL: provider.baseURL
                )
                if primaryLabel != nil || primaryCooling != nil {
                    HStack(spacing: 8) {
                        if let primaryLabel {
                            DSBadge(text: primaryLabel, style: .neutral)
                        }
                        if let secs = primaryCooling {
                            Text("主 Key 限流冷却剩余 \(secs)s")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("解除冷却") {
                                APIKeyPoolRouter.shared.markHealthy(
                                    key: apiKeyInput,
                                    protocolType: provider.protocolType,
                                    baseURL: provider.baseURL
                                )
                                cooldownTick &+= 1
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if onVerifiedModel == nil {
                ForEach(Array(extraAPIKeys.enumerated()), id: \.offset) { idx, extraKey in
                    let digest = ProviderConnectionSettingsStore.keyDigest(for: extraKey)
                    let customLabel = ProviderConnectionSettingsStore.shared.keyLabel(for: extraKey, providerID: provider.id)
                    let coolingSecs = APIKeyPoolRouter.shared.remainingCooldownSeconds(
                        key: extraKey,
                        protocolType: provider.protocolType,
                        baseURL: provider.baseURL
                    )
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(customLabel ?? String(localized: "备用 Key #\(idx + 1)"))
                                    .font(.caption.weight(.semibold))
                                if let coolingSecs {
                                    Text("冷却 \(coolingSecs)s")
                                        .font(.caption2.monospacedDigit().weight(.medium))
                                        .foregroundStyle(.orange)
                                } else if let probe = keyProbeStatus[digest] {
                                    Text(probe.text)
                                        .font(.caption2.monospacedDigit().weight(.medium))
                                        .foregroundStyle(probe.ok ? DS.StatusText.success : DS.StatusText.error)
                                }
                            }
                            Text(KeychainService.maskedKeyPreview(extraKey))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if probingKeyDigest == digest {
                            ProgressView().controlSize(.mini)
                        }
                        if coolingSecs != nil {
                            Button("恢复") {
                                APIKeyPoolRouter.shared.markHealthy(
                                    key: extraKey,
                                    protocolType: provider.protocolType,
                                    baseURL: provider.baseURL
                                )
                                cooldownTick &+= 1
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                        }
                        Menu {
                            if activeProbeSpec != nil {
                                Button {
                                    Task { await pingSpecificKey(extraKey) }
                                } label: {
                                    Label("单独测速此 Key", systemImage: "bolt.horizontal.circle")
                                }
                            }
                            Button {
                                keyLabelDraft = customLabel ?? ""
                                editingLabelKeyRaw = extraKey
                            } label: {
                                Label("设置备注标签…", systemImage: "tag")
                            }
                            Button {
                                promoteExtraKeyToPrimary(at: idx)
                            } label: {
                                Label("提升为主 Key", systemImage: "arrow.up.circle")
                            }
                            if coolingSecs != nil {
                                Button {
                                    APIKeyPoolRouter.shared.markHealthy(
                                        key: extraKey,
                                        protocolType: provider.protocolType,
                                        baseURL: provider.baseURL
                                    )
                                    cooldownTick &+= 1
                                } label: {
                                    Label("解除限流冷却", systemImage: "flame")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                ProviderConnectionSettingsStore.shared.setKeyLabel(nil, for: extraKey, providerID: provider.id)
                                removeExtraAPIKey(at: idx)
                            } label: {
                                Label("移除轮询 Key", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("管理备用 Key #\(idx + 1)")
                    }
                }

                HStack {
                    Button {
                        newExtraKeyInput = ""
                        showAddExtraKeySheet = true
                    } label: {
                        Label("添加轮询 / 备用 API Key", systemImage: "key.radiowaves.forward")
                            .font(.footnote)
                    }
                    if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Spacer()
                        Button {
                            keyLabelDraft = ProviderConnectionSettingsStore.shared.keyLabel(for: apiKeyInput, providerID: provider.id) ?? ""
                            editingLabelKeyRaw = apiKeyInput
                        } label: {
                            Text("主 Key 备注")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else if !extraAPIKeys.isEmpty {
                Text("已配置备用 Key，可在高级设置中管理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                if onVerifiedModel != nil {
                    Text("输入 API Key")
                } else {
                    Text("API Key（iOS 钥匙串加密存储）")
                }
                if keyWriteFailed {
                    Button("重试") {
                        flushPendingAPIKey(overrideValue: apiKeyInput)
                    }
                }
                Spacer()
                if keySaved && activePoolKeyCount > 0 {
                    Text("已保存")
                        .font(.caption2)
                        .foregroundStyle(DS.StatusText.success)
                }
            }
        } footer: {
            if onVerifiedModel != nil {
                Text("在服务商控制台创建 API Key 后粘贴到这里，密钥保存在本机钥匙串。免鉴权的局域网服务可留空。")
            } else if activePoolKeyCount >= 2 {
                Text("已启用 \(activePoolKeyCount) 个 Key 自动轮询，遇 429 限流或额度耗尽自动熔断切换。")
            } else {
                Text("支持随时修改；若使用末尾带 # 的自定义网关地址可跳过自动拼接 /v1。")
            }
        }
    }

    @ViewBuilder
    private func modelConfigRow(_ spec: ModelSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    inspectedModel = InspectedModelID(id: spec.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(spec.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(spec.isSelectable ? .primary : .secondary)
                            if !spec.isSelectable {
                                if spec.supportsReasoning {
                                    Image(systemName: "brain")
                                        .font(.caption2)
                                        .foregroundStyle(.purple.opacity(0.8))
                                }
                                if spec.supportsVision {
                                    Image(systemName: "eye")
                                        .font(.caption2)
                                        .foregroundStyle(.blue.opacity(0.8))
                                }
                                if Self.isFreeModel(spec) {
                                    DSBadge(text: String(localized: "免费"), style: .tinted(.green))
                                }
                            }
                        }
                        if spec.id != spec.displayName {
                            Text(spec.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(spec.isSelectable ? .primary : .secondary)
                        }
                        if spec.catalogStatus == .unlisted {
                            Text("已移出可选列表，可手动启用").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum + 2, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)

                Toggle("启用 \(spec.displayName)", isOn: Binding(
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

            if spec.isSelectable {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) { modelConfigActions(spec) }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { modelConfigActions(spec) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 0) { modelConfigActions(spec) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                inspectedModel = InspectedModelID(id: spec.id)
            } label: {
                Label("编辑别名与单独测速…", systemImage: "slider.horizontal.3")
            }
            Button {
                pricingModel = spec
            } label: {
                Label("设置单价…", systemImage: "creditcard")
            }
            if provider.models.first?.id != spec.id {
                Button {
                    moveModelToTop(id: spec.id)
                } label: {
                    Label("移至列表顶部", systemImage: "arrow.up.to.line")
                }
            }
            Divider()
            Button(role: .destructive) {
                provider.models = provider.models.filter { $0.id != spec.id }
                try? modelContext.save()
            } label: {
                Label("删除模型", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func modelConfigActions(_ spec: ModelSpec) -> some View {
        let rates = ModelPricingDisplay.configuredRates(for: spec)
        let price = rates.map {
            "\($0.currency) \(ModelPricingDisplay.rateText($0.input))/\(ModelPricingDisplay.rateText($0.output))"
        } ?? ModelPricingDisplay.label(for: spec)
        Button { pricingModel = spec } label: {
            Label(price, systemImage: "creditcard")
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: dynamicTypeSize.isAccessibilitySize)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(minWidth: DS.TouchTarget.minimum + 2, minHeight: DS.TouchTarget.minimum + 2)
                .background(rates == nil ? Color.secondary.opacity(0.08) : Color.green.opacity(0.12), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(spec.displayName) 的单价：\(price)"))

        Button { updateModel(id: spec.id) { $0.supportsVision.toggle() } } label: {
            Label("识图", systemImage: spec.supportsVision ? "eye.fill" : "eye.slash")
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: dynamicTypeSize.isAccessibilitySize)
                .font(.caption2.weight(.medium)).foregroundStyle(.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(minWidth: DS.TouchTarget.minimum + 2, minHeight: DS.TouchTarget.minimum + 2)
                .background(spec.supportsVision ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(spec.displayName) 的识图能力"))
        .accessibilityValue(spec.supportsVision ? Text("已开启") : Text("已关闭"))

        Button { updateModel(id: spec.id) { $0.supportsReasoning.toggle() } } label: {
            HStack(spacing: 4) {
                Label("思考链", systemImage: "brain")
                    .labelStyle(.titleAndIcon)
                Image(systemName: spec.supportsReasoning ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
            }
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: dynamicTypeSize.isAccessibilitySize)
            .font(.caption2.weight(.medium)).foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(minWidth: DS.TouchTarget.minimum + 2, minHeight: DS.TouchTarget.minimum + 2)
            .background(spec.supportsReasoning ? Color.purple.opacity(0.12) : Color.secondary.opacity(0.08), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(spec.displayName) 的思考能力"))
        .accessibilityValue(spec.supportsReasoning ? Text("已开启") : Text("已关闭"))
    }

    private var appearanceEditorSheet: some View {
        NavigationStack {
            Form {
                Section("主题颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(Self.accentHexOptions, id: \.self) { hex in
                            let selected = provider.accentHex.uppercased() == hex.uppercased()
                            Button {
                                provider.accentHex = hex
                                provider.updatedAt = Date()
                                try? modelContext.save()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 34, height: 34)
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("服务商图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(Self.iconOptions, id: \.self) { symbol in
                            let selected = provider.iconSymbol == symbol
                            Button {
                                provider.iconSymbol = symbol
                                provider.updatedAt = Date()
                                try? modelContext.save()
                            } label: {
                                DSIconTile(
                                    systemImage: symbol,
                                    tint: Color(hex: provider.accentHex),
                                    size: 44,
                                    cornerRadius: DS.Radius.sm
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                        .strokeBorder(selected ? Color(hex: provider.accentHex) : .clear, lineWidth: 2)
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("图标与主题颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showAppearanceSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addModelSheet: some View {
        NavigationStack {
            Form {
                if let saveError { Text(saveError).foregroundStyle(DS.StatusText.error) }
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

    private var headerEditorSheet: some View {
        NavigationStack {
            Form {
                if let saveError { Text(saveError).foregroundStyle(DS.StatusText.error) }
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
                            SecureField(editingHeaderID != nil ? "留空则保留原敏感值，输入可覆盖" : "Header 值", text: $newHeaderValue)
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
            .navigationTitle(editingHeaderID == nil ? String(localized: "添加自定义 Header") : String(localized: "编辑自定义 Header"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showHeaderEditorSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveEditedOrNewHeader()
                    }
                    .disabled(newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveEditedOrNewHeader() {
        let k = newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }

        if let editingID = editingHeaderID,
           let existingIdx = provider.customHeaders.firstIndex(where: { $0.id == editingID }) {
            var headers = provider.customHeaders
            let previous = headers[existingIdx]
            let account = KeychainService.headerAccount(providerID: provider.credentialID, headerID: editingID)
            if newHeaderIsSecret {
                if !newHeaderValue.isEmpty {
                    guard KeychainService.shared.saveSecret(newHeaderValue, account: account) else {
                        saveError = String(localized: "保存失败，请保留输入并重试。")
                        return
                    }
                } else if !previous.isSecret {
                    guard KeychainService.shared.saveSecret(previous.value, account: account) else {
                        saveError = String(localized: "保存失败，请保留输入并重试。")
                        return
                    }
                }
                headers[existingIdx] = CustomHeader(id: editingID, key: k, value: "", isEnabled: previous.isEnabled, isSecret: true)
            } else {
                if previous.isSecret {
                    KeychainService.shared.deleteSecret(account: account)
                }
                headers[existingIdx] = CustomHeader(id: editingID, key: k, value: newHeaderValue, isEnabled: previous.isEnabled, isSecret: false)
            }
            provider.customHeaders = headers
            do {
                try modelContext.save()
                saveError = nil
                showHeaderEditorSheet = false
            } catch {
                saveError = error.localizedDescription
            }
            return
        }

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
        showHeaderEditorSheet = false
    }

    private var addExtraKeySheet: some View {
        NavigationStack {
            Form {
                if let saveError { Text(saveError).foregroundStyle(DS.StatusText.error) }
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        TextField("输入或粘贴备用 API Key（支持换行或逗号批量粘贴多个）", text: $newExtraKeyInput, axis: .vertical)
                            .lineLimit(1...5)
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
                    Text("支持一次粘贴多把 Key（按换行或逗号自动拆分去重）。多个 API Key 会按轮询分摊请求；遇 429 限流或 401/402/403 异常时自动冷却并秒切下一个 Key。")
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
                        let candidates = newExtraKeyInput
                            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;，；")))
                            .map { LLMClient.sanitizedAPIKey($0) }
                            .filter { !$0.isEmpty }
                        guard !candidates.isEmpty else { return }
                        flushPendingAPIKey()
                        var remaining = candidates
                        var primaryTrimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if primaryTrimmed.isEmpty, let first = remaining.first {
                            apiKeyInput = first
                            flushPendingAPIKey(overrideValue: first)
                            primaryTrimmed = first
                            remaining.removeFirst()
                        }
                        var updated = extraAPIKeys
                        for item in remaining where item != primaryTrimmed && !updated.contains(item) {
                            updated.append(item)
                        }
                        if updated != extraAPIKeys {
                            guard KeychainService.shared.saveExtraAPIKeys(updated, for: provider.credentialID) else {
                                saveError = String(localized: "保存失败，请保留输入并重试。")
                                return
                            }
                            extraAPIKeys = updated
                        }
                        keySaved = !primaryTrimmed.isEmpty || !extraAPIKeys.isEmpty
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

    private func promoteExtraKeyToPrimary(at index: Int) {
        guard extraAPIKeys.indices.contains(index) else { return }
        flushPendingAPIKey()
        let promoted = extraAPIKeys[index]
        let oldPrimary = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedExtras = extraAPIKeys
        updatedExtras.remove(at: index)
        if !oldPrimary.isEmpty && !updatedExtras.contains(oldPrimary) {
            updatedExtras.insert(oldPrimary, at: 0)
        }
        guard KeychainService.shared.saveAPIKey(promoted, for: provider.credentialID),
              KeychainService.shared.saveExtraAPIKeys(updatedExtras, for: provider.credentialID) else {
            saveError = String(localized: "保存失败，请保留输入并重试。")
            return
        }
        ensureKeyCoordinator().resetInitial(promoted)
        apiKeyInput = promoted
        extraAPIKeys = updatedExtras
        keySaved = true
        saveError = nil
    }

    private func removeExtraAPIKey(at index: Int) {
        guard extraAPIKeys.indices.contains(index) else { return }
        var updated = extraAPIKeys
        updated.remove(at: index)
        guard KeychainService.shared.saveExtraAPIKeys(updated, for: provider.credentialID) else {
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

    @ViewBuilder
    private var providerBalanceRow: some View {
        let isLoading = balanceStore.loadingIDs.contains(provider.id)
        let snapshot = balanceStore.snapshot(for: provider, overrideKey: apiKeyInput)
        let errText = balanceStore.errors[provider.id]
        let hasKey = !LLMClient.sanitizedAPIKey(apiKeyInput).isEmpty

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("账户可用额度", systemImage: "wallet.bifold")
                    .font(.subheadline)
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if let snapshot {
                    Text(verbatim: snapshot.formattedAvailable)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(DS.StatusText.success)
                }
                Button {
                    flushPendingAPIKey()
                    Task {
                        await balanceStore.refresh(provider: provider, overrideKey: apiKeyInput)
                    }
                } label: {
                    Text(snapshot == nil ? String(localized: "查询余额") : String(localized: "刷新"))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoading || !hasKey || mismatchedIssuer != nil)
            }

            if let detail = snapshot?.formattedSecondaryDetail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let errText {
                Text(errText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func pingSpecificKey(_ rawKey: String) async {
        guard let spec = activeProbeSpec else { return }
        let clean = LLMClient.sanitizedAPIKey(rawKey)
        let digest = ProviderConnectionSettingsStore.keyDigest(for: clean)
        guard !clean.isEmpty, !digest.isEmpty else { return }
        probingKeyDigest = digest
        defer { probingKeyDigest = nil }
        do {
            let result = try await LLMClient.pingModel(
                providerName: provider.name,
                protocolType: provider.protocolType,
                baseURL: provider.baseURL,
                apiKey: clean,
                apiKeys: [],
                customHeaders: provider.resolvedCustomHeaders,
                modelID: spec.id,
                supportsReasoning: spec.supportsReasoning,
                idleTimeoutSeconds: provider.customIdleTimeout
            )
            APIKeyPoolRouter.shared.markHealthy(key: clean, protocolType: provider.protocolType, baseURL: provider.baseURL)
            keyProbeStatus[digest] = (true, "\(result.ttftMs) ms")
        } catch {
            keyProbeStatus[digest] = (false, String(localized: "异常"))
        }
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
                apiKey: LLMClient.sanitizedAPIKey(apiKeyInput),
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
            fetchBannerMessage = "[\(spec.id)] \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func ensureKeyCoordinator() -> APIKeySaveCoordinator {
        if let existing = keyCoordinator {
            return existing
        }
        let credentialID = provider.credentialID
        let coordinator = APIKeySaveCoordinator(
            initialValue: provider.apiKey,
            saveHandler: { trimmed in
                KeychainService.shared.saveAPIKey(trimmed, for: credentialID)
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
        if ProviderTemplate.mismatchedIssuer(apiKey: overrideValue ?? apiKeyInput, baseURL: provider.baseURL) != nil {
            coordinator.resetInitial(coordinator.lastSavedValue)
            return
        }
        _ = coordinator.flushNow(overrideValue: overrideValue)
    }
}
