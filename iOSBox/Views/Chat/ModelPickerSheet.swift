import SwiftUI
import SwiftData

enum ModelPricingDisplay {
    static func rateText(_ rate: Double) -> String {
        if rate > 0 && rate < 0.000001 {
            return rate.formatted(.number.notation(.scientific).precision(.significantDigits(1...6)))
        }
        return rate.formatted(.number.precision(.significantDigits(1...6)))
    }

    static func configuredRates(for model: ModelSpec) -> (currency: String, input: Double, output: Double)? {
        guard let input = RequestRecord.validPrice(model.inputPricePerMillion),
              let output = RequestRecord.validPrice(model.outputPricePerMillion),
              let currency = model.priceCurrency, RequestRecord.currencies.contains(currency) else { return nil }
        return (currency, input, output)
    }

    static func label(for model: ModelSpec) -> String {
        guard let rates = configuredRates(for: model) else { return String(localized: "单价未完整设置") }
        let input = rateText(rates.input)
        let output = rateText(rates.output)
        return String(localized: "\(rates.currency) 输入 \(input) / 输出 \(output) · 每百万 Token")
    }
}

struct ModelPickerSheet: View {
    enum Mode {
        case single
        case arenaMulti
    }

    let mode: Mode
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    let directory: ChatModelDirectory
    @Bindable var conversation: Conversation
    let selectSingle: (ResolvedModelTarget) throws -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingSetup = false
    @State private var verified: ResolvedModelTarget?
    @State private var selectionError: String?
    @State private var searchText: String = ""
    @State private var draftArenaTargets: [ResolvedModelTarget] = []
    @State private var draftBlindMode = false
    @State private var preferences = AppPreferences.shared
    @State private var configuredProviders: [ProviderConfig] = []

    private var allEnabledTargets: [(provider: ProviderConfig, spec: ModelSpec, target: ResolvedModelTarget)] {
        configuredProviders.flatMap { provider in
            provider.enabledModels.map { spec in
                (provider, spec, provider.makeTarget(for: spec))
            }
        }
    }

    private var favoriteEntries: [(provider: ProviderConfig, spec: ModelSpec, target: ResolvedModelTarget)] {
        allEnabledTargets.filter { $0.spec.isStarred }
    }

    private var recentEntries: [(provider: ProviderConfig, spec: ModelSpec, target: ResolvedModelTarget)] {
        let map = Dictionary(uniqueKeysWithValues: allEnabledTargets.map { ($0.target.id, $0) })
        let favoriteIDs = Set(favoriteEntries.map { $0.target.id })
        return preferences.recentModelIDs.compactMap { id in
            guard !favoriteIDs.contains(id) else { return nil }
            return map[id]
        }.prefix(5).map { $0 }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if configuredProviders.isEmpty {
                    ContentUnavailableView {
                        Label("尚未配置可用的 API", systemImage: "server.rack")
                    } description: {
                        Text("请在「设置」中配置 API 连接并启用模型。")
                    } actions: {
                        configureButton.buttonStyle(.borderedProminent)
                    }
                    .background(DS.Surface.grouped)
                } else {
                    List {
                        if allEnabledTargets.count < (mode == .arenaMulti ? 2 : 1) {
                            Section { configureButton }
                        }
                        if mode == .arenaMulti {
                            Section {
                                HStack {
                                    Image(systemName: "bolt.horizontal.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                    Text("勾选 2–4 个模型，发送消息时将同时并发请求并同屏对比结果。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Text("能力是本地标记，可能按名称推测；显示的基础单价不含服务商倍率。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }

                        if isSearching && allEnabledTargets.isEmpty {
                            Section {
                                Text("暂无可选模型，请在「设置」中启用模型。")
                                    .foregroundStyle(.secondary)
                                configureButton
                            }
                        } else if isSearching && configuredProviders.allSatisfy({ filterModels($0.enabledModels).isEmpty }) {
                            Section {
                                ContentUnavailableView {
                                    Label("没有匹配的模型", systemImage: "magnifyingglass")
                                } description: {
                                    Text("请尝试其他模型名称或 ID。")
                                } actions: {
                                    Button("清除搜索") { searchText = "" }
                                }
                                .accessibilityIdentifier("modelPicker.noMatches")
                            }
                        }

                        if mode == .arenaMulti && !isSearching {
                            Section {
                                Toggle("双盲对比", isOn: $draftBlindMode)
                                    .accessibilityIdentifier("modelPicker.blindArena")
                            }
                        }

                        if !isSearching && !favoriteEntries.isEmpty {
                            Section {
                                ForEach(favoriteEntries, id: \.target.id) { entry in
                                    modelRow(target: entry.target, spec: entry.spec, provider: entry.provider, showProviderSubtitle: true)
                                }
                            } header: {
                                Label("常用置顶", systemImage: "star.fill")
                            }
                        }

                        if !isSearching && !recentEntries.isEmpty {
                            Section {
                                ForEach(recentEntries, id: \.target.id) { entry in
                                    modelRow(target: entry.target, spec: entry.spec, provider: entry.provider, showProviderSubtitle: true)
                                }
                            } header: {
                                Label("最近使用", systemImage: "clock.arrow.circlepath")
                            }
                        }

                        ForEach(configuredProviders) { provider in
                            let filteredModels = filterModels(provider.enabledModels)
                            if !filteredModels.isEmpty || !isSearching {
                                Section {
                                    if filteredModels.isEmpty {
                                        Text("暂无可选模型，请刷新列表或在「设置」中启用模型。").foregroundStyle(.secondary)
                                    }
                                    ForEach(filteredModels) { spec in
                                        let target = provider.makeTarget(for: spec)
                                        modelRow(target: target, spec: spec, provider: provider, showProviderSubtitle: false)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color(hex: provider.accentHex))
                                            .frame(width: 8, height: 8)
                                        Text(provider.name)
                                        Spacer()
                                        if directory.catalogs[provider.id]?.isLoading == true {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Button { directory.refresh(provider, in: modelContext) } label: {
                                                Image(systemName: "arrow.clockwise")
                                                    .foregroundStyle(preferences.accentTheme.readableText)
                                                    .frame(width: DS.TouchTarget.minimum + 2, height: DS.TouchTarget.minimum + 2)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(Text("刷新 \(provider.name) 的模型列表"))
                                        }
                                    }
                                } footer: {
                                    if directory.catalogs[provider.id]?.isLoading == true {
                                        Text("正在刷新模型列表…")
                                    } else if directory.catalogs[provider.id]?.error != nil {
                                        Text("刷新失败，显示已保存的模型。")
                                    } else if directory.catalogs[provider.id]?.models != nil {
                                        Text("已刷新，显示已启用的模型。")
                                    } else {
                                        Text("显示已保存的模型。")
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(DS.Surface.grouped)
                    .searchable(text: $searchText, prompt: "搜索模型名称或 ID")
                }
            }
            .navigationTitle(mode == .single ? String(localized: "切换对话模型") : String(localized: "选择并发对比模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if mode == .arenaMulti {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("开启对比 (\(draftArenaTargets.count))") {
                            let valid = validTargets(draftArenaTargets)
                            guard valid.count >= 2 else { draftArenaTargets = valid; return }
                            let previous = (conversation.arenaTargetsData, conversation.isArenaMode,
                                            conversation.isGroupMode, conversation.assistanceSettingsData)
                            conversation.arenaTargets = valid
                            conversation.isGroupMode = false
                            conversation.isArenaMode = true
                            conversation.assistanceSettings.blindArenaMode = draftBlindMode
                            do { try modelContext.save() }
                            catch {
                                (conversation.arenaTargetsData, conversation.isArenaMode,
                                 conversation.isGroupMode, conversation.assistanceSettingsData) = previous
                                selectionError = error.localizedDescription
                                return
                            }
                            for item in valid {
                                preferences.recordRecentModel(item)
                            }
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(draftArenaTargets.count < 2)
                    }
                }
            }
            .sheet(isPresented: $showingSetup, onDismiss: finishSetup) {
                FirstModelSetupSheet { verified = $0 }
            }
            .alert("操作失败", isPresented: Binding(get: { selectionError != nil }, set: { if !$0 { selectionError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(verbatim: selectionError ?? "") }
            .onAppear {
                reloadProviders()
                if mode == .arenaMulti {
                    draftBlindMode = conversation.assistanceSettings.blindArenaMode
                    let validExisting = validTargets(conversation.arenaTargets)
                    if !validExisting.isEmpty {
                        draftArenaTargets = validExisting
                    } else if let primary = conversation.primaryTarget,
                              let resolvedPrimary = validTargets([primary]).first {
                        draftArenaTargets = [resolvedPrimary]
                    }
                }
            }
            .onChange(of: SystemIntegration.fingerprint(providers)) { reloadProviders() }
            .onReceive(NotificationCenter.default.publisher(for: .init("IOSBoxCredentialsChanged"))) { _ in reloadProviders() }
        }
    }

    private var configureButton: some View {
        Button { showingSetup = true } label: { Label("配置 API 与模型", systemImage: "plus.circle") }
            .accessibilityIdentifier("modelPicker.configure")
    }

    private func finishSetup() {
        guard let target = verified else { return }
        verified = nil
        reloadProviders()
        if mode == .single { choose(target) }
        else if !draftArenaTargets.contains(where: { $0.id == target.id }), draftArenaTargets.count < 4 {
            draftArenaTargets.append(target)
        }
    }

    private func choose(_ target: ResolvedModelTarget) {
        do {
            try selectSingle(target)
            preferences.recordRecentModel(target)
            preferences.triggerSelectionHaptic()
            dismiss()
        } catch { selectionError = error.localizedDescription }
    }

    private func validTargets(_ selected: [ResolvedModelTarget]) -> [ResolvedModelTarget] {
        let ready = ProviderConfig.readyTargets(in: providers)
        return selected.compactMap { target in ready.first { $0.id == target.id } }
    }

    private func reloadProviders() {
        configuredProviders = providers.filter(\.hasConfiguredChatAPI)
        directory.update(configured: configuredProviders, in: modelContext)
        if mode == .arenaMulti { draftArenaTargets = validTargets(draftArenaTargets) }
    }

    @ViewBuilder
    private func modelRow(target: ResolvedModelTarget, spec: ModelSpec, provider: ProviderConfig, showProviderSubtitle: Bool) -> some View {
        let isSelected: Bool = {
            switch mode {
            case .single:
                return conversation.primaryTarget?.id == target.id && !conversation.isArenaMode && !conversation.isGroupMode
            case .arenaMulti:
                return draftArenaTargets.contains(where: { $0.id == target.id })
            }
        }()

        HStack(spacing: 10) {
            Button {
                guard let target = validTargets([target]).first else { reloadProviders(); return }
                switch mode {
                case .single:
                    choose(target)
                case .arenaMulti:
                    if let idx = draftArenaTargets.firstIndex(where: { $0.id == target.id }) {
                        draftArenaTargets.remove(at: idx)
                    } else if draftArenaTargets.count < 4 {
                        draftArenaTargets.append(target)
                    }
                    preferences.triggerSelectionHaptic()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(target.modelDisplayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if target.supportsReasoning || target.supportsVision {
                            HStack(spacing: 6) {
                                if target.supportsReasoning {
                                    Text("思考")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(DS.AccentTheme.indigo.readableText)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.purple.opacity(0.12), in: Capsule())
                                }
                                if target.supportsVision {
                                    Text("识图")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(DS.AccentTheme.cobalt.readableText)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                }
                            }
                        }

                        if showProviderSubtitle {
                            Text("\(provider.name) · \(target.modelID)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if target.modelID != target.modelDisplayName {
                            Text(target.modelID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Text(ModelPricingDisplay.label(for: spec))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: mode == .single ? "checkmark.circle.fill" : "checkmark.square.fill")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                    } else if mode == .arenaMulti {
                        Image(systemName: "square")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                toggleFavorite(provider: provider, modelID: spec.id)
            } label: {
                Image(systemName: spec.isStarred ? "star.fill" : "star")
                    .font(.subheadline)
                    .foregroundStyle(spec.isStarred ? .yellow : .secondary.opacity(0.5))
                    .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spec.isStarred
                ? Text("取消置顶 \(provider.name) 的 \(target.modelDisplayName)")
                : Text("置顶 \(provider.name) 的 \(target.modelDisplayName)"))
        }
        .contextMenu {
            Button("设为默认模型") {
                if let live = validTargets([target]).first { preferences.defaultTargetID = live.id }
            }
        }
    }

    private func toggleFavorite(provider: ProviderConfig, modelID: String) {
        var list = provider.models
        guard let idx = list.firstIndex(where: { $0.id == modelID }) else { return }
        list[idx].isStarred.toggle()
        provider.models = list
        try? modelContext.save()
        preferences.triggerSelectionHaptic()
    }

    private func filterModels(_ models: [ModelSpec]) -> [ModelSpec] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }
}
