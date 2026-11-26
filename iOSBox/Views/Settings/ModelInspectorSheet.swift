import SwiftData
import SwiftUI
import UIKit

struct ModelInspectorSheet: View {
    @Bindable var provider: ProviderConfig
    let modelID: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var displayNameInput = ""
    @State private var isEnabled = true
    @State private var isStarred = false
    @State private var supportsVision = true
    @State private var supportsReasoning = false
    @State private var showPricingSheet = false
    @State private var isPinging = false
    @State private var pingBanner: (ok: Bool, text: String)?
    @State private var copiedID = false
    @State private var saveError: String?

    private var currentSpec: ModelSpec? {
        provider.models.first { $0.id == modelID }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Text(saveError).foregroundStyle(DS.StatusText.error)
                }

                Section("模型标识与显示别名") {
                    HStack {
                        Text(verbatim: modelID)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = modelID
                            copiedID = true
                        } label: {
                            Text(copiedID ? "已复制" : "复制 ID")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    HStack {
                        TextField("显示名称（留空则使用模型 ID）", text: $displayNameInput)
                            .onChange(of: displayNameInput) { _, newValue in
                                persist { spec in
                                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    spec.displayName = trimmed.isEmpty ? spec.id : trimmed
                                }
                            }
                        if !displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           displayNameInput.trimmingCharacters(in: .whitespacesAndNewlines) != modelID {
                            Button("重置") {
                                displayNameInput = modelID
                                persist { $0.displayName = $0.id }
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if let spec = currentSpec {
                    ModelMediaDetailSection(capabilities: spec.mediaCapabilities(baseURL: provider.baseURL))
                }

                Section("可用状态与能力") {
                    Toggle("启用此模型", isOn: $isEnabled)
                        .onChange(of: isEnabled) { _, val in
                            persist {
                                $0.isEnabled = val
                                if val && $0.catalogStatus == .unlisted { $0.catalogStatus = .manual }
                            }
                        }

                    Toggle("在模型切换器中常用置顶", isOn: $isStarred)
                        .onChange(of: isStarred) { _, val in
                            persist { $0.isStarred = val }
                        }

                    Toggle("识图（本地标记）", isOn: $supportsVision)
                        .onChange(of: supportsVision) { _, val in
                            persist { $0.supportsVision = val }
                        }

                    Toggle("支持深度思考过程展示", isOn: $supportsReasoning)
                        .onChange(of: supportsReasoning) { _, val in
                            persist { $0.supportsReasoning = val }
                        }
                }

                if let spec = currentSpec {
                    CapabilityChecks(model: TaskModel(provider: provider, spec: spec))
                    Section("计价配置") {
                        Button {
                            showPricingSheet = true
                        } label: {
                            HStack {
                                Label("单价设置", systemImage: "creditcard")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(ModelPricingDisplay.label(for: spec))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        if ModelPricingDisplay.configuredRates(for: spec) == nil,
                           let preset = ModelPricingCatalog.match(modelID: spec.id) {
                            Button {
                                persist { ModelPricingCatalog.apply(preset, to: &$0) }
                            } label: {
                                Label("一键填入主流参考价（\(preset.label)）", systemImage: "wand.and.stars")
                                    .font(.footnote)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await pingCurrentModel() }
                    } label: {
                        HStack {
                            if isPinging {
                                ProgressView().controlSize(.small)
                                Text("正在测试此模型…")
                            } else {
                                Label("单独测速验证此模型", systemImage: "bolt.horizontal.circle")
                            }
                        }
                    }
                    .disabled(isPinging || !provider.hasConfiguredChatAPI)

                    if let pingBanner {
                        HStack(spacing: 8) {
                            Image(systemName: pingBanner.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(pingBanner.ok ? .green : .red)
                            Text(pingBanner.text)
                                .font(.caption)
                                .foregroundStyle(pingBanner.ok ? Color.secondary : Color.red)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("连通性诊断")
                } footer: {
                    Text("仅向该模型发送一条极短测试请求，用于核对模型 ID 权限及首字响应延迟。")
                }
            }
            .navigationTitle("模型详情与测速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                guard let spec = currentSpec else { return }
                displayNameInput = spec.displayName
                isEnabled = spec.isSelectable
                isStarred = spec.isStarred
                supportsVision = spec.supportsVision
                supportsReasoning = spec.supportsReasoning
            }
            .sheet(isPresented: $showPricingSheet) {
                ModelPricingSheet(provider: provider, modelID: modelID)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func persist(_ mutate: (inout ModelSpec) -> Void) {
        var list = provider.models
        guard let idx = list.firstIndex(where: { $0.id == modelID }) else { return }
        let old = list
        mutate(&list[idx])
        guard list != old else { return }
        provider.models = list
        do {
            try modelContext.save()
            saveError = nil
        } catch {
            provider.models = old
            saveError = error.localizedDescription
        }
    }

    @MainActor
    private func pingCurrentModel() async {
        isPinging = true
        pingBanner = nil
        defer { isPinging = false }
        do {
            let result = try await LLMClient.pingModel(
                providerName: provider.name,
                protocolType: provider.protocolType,
                baseURL: provider.baseURL,
                apiKey: LLMClient.sanitizedAPIKey(provider.apiKey),
                apiKeys: provider.extraAPIKeys,
                customHeaders: provider.resolvedCustomHeaders,
                modelID: modelID,
                supportsReasoning: supportsReasoning,
                idleTimeoutSeconds: provider.customIdleTimeout
            )
            pingBanner = (true, String(localized: "连通正常 · 首字 \(result.ttftMs) ms（总耗时 \(result.totalMs) ms）"))
        } catch {
            pingBanner = (false, ModelSetup.verificationAdvice(for: error, checkingModel: true))
        }
    }
}
