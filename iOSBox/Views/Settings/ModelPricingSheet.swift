import SwiftUI
import SwiftData

struct ModelPricingSheet: View {
    let provider: ProviderConfig
    let modelID: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var output = ""
    @State private var cacheRead = ""
    @State private var cacheWrite = ""
    @State private var currency = "USD"
    @State private var error: String?

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
        currency = preset.currency
        input = String(describing: preset.inputPerMillion)
        output = String(describing: preset.outputPerMillion)
        cacheRead = preset.cacheReadPerMillion.map { String(describing: $0) } ?? ""
        cacheWrite = preset.cacheWritePerMillion.map { String(describing: $0) } ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
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

                if !isValid { Text("请同时填写两个非负单价，或同时留空。").foregroundStyle(DS.StatusText.warning) }
                if let error { Text(error).foregroundStyle(DS.StatusText.error) }
            }
            .navigationTitle("设置单价")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!isValid)
                }
            }
            .onAppear {
                guard let spec = provider.models.first(where: { $0.id == modelID }) else { return }
                input = spec.inputPricePerMillion.map(String.init(describing:)) ?? ""
                output = spec.outputPricePerMillion.map(String.init(describing:)) ?? ""
                cacheRead = spec.cacheReadPricePerMillion.map(String.init(describing:)) ?? ""
                cacheWrite = spec.cacheWritePricePerMillion.map(String.init(describing:)) ?? ""
                currency = spec.priceCurrency ?? "USD"
            }
        }
    }

    private func save() {
        var models = provider.models
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
        provider.models = models
        do { try context.save(); dismiss() }
        catch {
            provider.models = old
            self.error = String(localized: "保存失败，请保留输入并重试。")
        }
    }
}
