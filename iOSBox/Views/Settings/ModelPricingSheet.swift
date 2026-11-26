import SwiftUI
import SwiftData

struct ModelPricingSheet: View {
    let provider: ProviderConfig
    let modelID: String
    var defaultBackfill: Bool = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allRecords: [RequestRecord]

    @State private var input = ""
    @State private var output = ""
    @State private var cacheRead = ""
    @State private var cacheWrite = ""
    @State private var currency = "USD"
    @State private var backfillUnpriced = false
    @State private var error: String?

    @State private var initialModel: ModelSpec?
    @State private var automaticModel: ModelSpec?
    @State private var fetchingPrice = false

    private var unpricedRecordCount: Int {
        allRecords.filter {
            $0.providerID == provider.id && $0.modelID == modelID && $0.kind != .webSearch
                && $0.status != .running && $0.status != .blocked && !$0.hasModelPricing
        }.count
    }

    private var supportsPriceSync: Bool {
        OpenAICompatibleAdapter.isOpenRouter(provider.baseURL)
            || URLComponents(string: provider.baseURL)?.host?.lowercased() == "api.openai.com"
    }

    private func matchesFields(_ model: ModelSpec) -> Bool {
        model.inputPricePerMillion == price(input) && model.outputPricePerMillion == price(output)
            && model.cacheReadPricePerMillion == price(cacheRead) && model.cacheWritePricePerMillion == price(cacheWrite)
            && (model.priceCurrency ?? "USD") == currency
    }

    private var automaticSource: ModelPriceSource? {
        guard let automaticModel, matchesFields(automaticModel) else { return nil }
        return automaticModel.priceSource
    }

    private func loadFields(_ spec: ModelSpec) {
        input = spec.inputPricePerMillion.map(String.init(describing:)) ?? ""
        output = spec.outputPricePerMillion.map(String.init(describing:)) ?? ""
        cacheRead = spec.cacheReadPricePerMillion.map(String.init(describing:)) ?? ""
        cacheWrite = spec.cacheWritePricePerMillion.map(String.init(describing:)) ?? ""
        currency = spec.priceCurrency ?? "USD"
        automaticModel = spec.priceSource == .manual || spec.priceSource == nil ? nil : spec
    }

    private func fetchPrice() async {
        let baseURL = provider.baseURL
        defer { fetchingPrice = false }
        do {
            let published = try await ProviderPricing.publishedModel(id: modelID, baseURL: baseURL)
            try Task.checkCancellation()
            guard baseURL == provider.baseURL, let model = published else {
                error = String(localized: "服务商暂未提供此模型的可用单价。")
                return
            }
            loadFields(model)
        } catch {
            if !Task.isCancelled { self.error = String(localized: "获取单价失败，请稍后重试。") }
        }
    }

    private func price(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return RequestRecord.validPrice(Double(trimmed.replacingOccurrences(of: ",", with: ".")))
    }

    private func isOptionalFieldValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || price(trimmed) != nil
    }

    private var isValid: Bool {
        let baseValid = (input.trimmingCharacters(in: .whitespaces).isEmpty && output.trimmingCharacters(in: .whitespaces).isEmpty)
            || (price(input) != nil && price(output) != nil)
        return baseValid && isOptionalFieldValid(cacheRead) && isOptionalFieldValid(cacheWrite)
    }

    private func applyPreset(_ preset: ModelPricingCatalog.Preset) {
        automaticModel = nil
        currency = preset.currency
        input = String(describing: preset.inputPerMillion)
        output = String(describing: preset.outputPerMillion)
        cacheRead = preset.cacheReadPerMillion.map { String(describing: $0) } ?? ""
        cacheWrite = preset.cacheWritePerMillion.map { String(describing: $0) } ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                if supportsPriceSync {
                    Section {
                        Button {
                            error = nil
                            fetchingPrice = true
                        } label: {
                            if fetchingPrice { ProgressView() } else { Label("从服务商获取单价", systemImage: "arrow.clockwise") }
                        }
                    } footer: {
                        switch automaticSource {
                        case .openAIShortContext: Text("OpenAI 标准档短上下文参考价。长上下文或其他服务档位的费用可能不同。")
                        case .openAIStandard: Text("来自 OpenAI 官方标准价目表。")
                        case .openRouter: Text("来自 OpenRouter 模型目录。")
                        case .variableRoute: Text("按实际路由计费，服务商没有固定单价。")
                        default: EmptyView()
                        }
                    }
                }
                Section("快捷填充参考单价") {
                    if let matched = ModelPricingCatalog.match(modelID: modelID) {
                        Button {
                            applyPreset(matched)
                        } label: {
                            Label("一键填入：\(matched.label)", systemImage: "wand.and.stars")
                                .font(.subheadline.weight(.medium))
                        }
                    }

                    Menu {
                        ForEach(ModelPricingCatalog.presets) { preset in
                            Button(preset.label) {
                                applyPreset(preset)
                            }
                        }
                    } label: {
                        Label("从主流模型单价表选择…", systemImage: "list.bullet.rectangle")
                            .font(.subheadline)
                    }
                }

                Section {
                    Text(modelID).font(.subheadline.monospaced())
                    Picker("币种", selection: $currency) {
                        ForEach(RequestRecord.currencies, id: \.self) { Text($0).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每百万输入 Token 单价").font(.caption).foregroundStyle(.secondary)
                        TextField("未设置", text: $input).keyboardType(.decimalPad)
                            .accessibilityLabel("每百万输入 Token 单价")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每百万输出 Token 单价").font(.caption).foregroundStyle(.secondary)
                        TextField("未设置", text: $output).keyboardType(.decimalPad)
                            .accessibilityLabel("每百万输出 Token 单价")
                    }
                } header: {
                    Text("模型计价")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每百万缓存命中单价（选填）").font(.caption).foregroundStyle(.secondary)
                        TextField("留空则按普通输入计价", text: $cacheRead).keyboardType(.decimalPad)
                            .accessibilityLabel("每百万缓存命中单价")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每百万缓存写入单价（选填）").font(.caption).foregroundStyle(.secondary)
                        TextField("留空则按普通输入计价", text: $cacheWrite).keyboardType(.decimalPad)
                            .accessibilityLabel("每百万缓存写入单价")
                    }
                } header: {
                    Text("Prompt 缓存折扣（选填）")
                } footer: {
                    Text("填写缓存命中或写入单价后，新请求将自动按实际缓存 Token 折算费用并统计缓存节省金额。单价只影响新请求，清空输入与输出两项可停止计价。")
                }

                if unpricedRecordCount > 0 && price(input) != nil && price(output) != nil {
                    Section {
                        Toggle("同步补算历史未定价请求（\(unpricedRecordCount) 次）", isOn: $backfillUnpriced)
                    } footer: {
                        Text("开启后，仅对缺少单价的历史记录补充本次单价，不会覆盖已有计价快照。")
                    }
                }

                if !isValid { Text("请同时填写两个非负单价，或同时留空。").foregroundStyle(DS.StatusText.warning) }
                if let error { Text(error).foregroundStyle(DS.StatusText.error) }
            }
            .disabled(fetchingPrice)
            .task(id: fetchingPrice) { if fetchingPrice { await fetchPrice() } }
            .navigationTitle("设置单价")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!isValid || fetchingPrice)
                }
            }
            .onAppear {
                backfillUnpriced = defaultBackfill
                if let spec = provider.models.first(where: { $0.id == modelID }) {
                    initialModel = spec
                    loadFields(spec)
                }
            }
        }
    }

    private func save() {
        var models = provider.models
        let existingIndex = models.firstIndex(where: { $0.id == modelID })
        if existingIndex == nil {
            var created = ModelSpec(id: modelID, isEnabled: false)
            created.catalogStatus = .manual
            models.append(created)
        }
        guard let index = models.firstIndex(where: { $0.id == modelID }) else {
            error = String(localized: "模型已被删除，请关闭后重试。")
            return
        }
        let old = provider.models
        let inVal = price(input)
        let outVal = price(output)
        models[index].inputPricePerMillion = inVal
        models[index].outputPricePerMillion = outVal
        models[index].cacheReadPricePerMillion = inVal == nil ? nil : price(cacheRead)
        models[index].cacheWritePricePerMillion = inVal == nil ? nil : price(cacheWrite)
        models[index].priceCurrency = inVal == nil ? nil : currency
        let source = automaticSource ?? .manual
        let modelUnchanged = initialModel.map { matchesFields($0) && source == ($0.priceSource ?? .manual) } ?? false
        if modelUnchanged && (!backfillUnpriced || unpricedRecordCount == 0) {
            dismiss()
            return
        }
        models[index].priceSource = source
        provider.models = models
        if backfillUnpriced && inVal != nil && outVal != nil {
            _ = RequestLedger.backfillUnpricedRecords(
                in: allRecords,
                providerID: provider.id,
                modelID: modelID,
                spec: models[index]
            )
        }
        do { try context.save(); dismiss() }
        catch {
            provider.models = old
            self.error = String(localized: "保存失败，请保留输入并重试。")
        }
    }
}
