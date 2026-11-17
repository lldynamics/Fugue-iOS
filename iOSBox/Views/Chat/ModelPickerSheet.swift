import SwiftUI

struct ModelPickerSheet: View {
    enum Mode {
        case single
        case arenaMulti
    }

    let mode: Mode
    let providers: [ProviderConfig]
    @Bindable var conversation: Conversation
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var draftArenaTargets: [ResolvedModelTarget] = []

    private var enabledProviders: [ProviderConfig] {
        providers.filter { $0.isEnabled && !$0.enabledModels.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if enabledProviders.isEmpty {
                    ContentUnavailableView(
                        "暂无已启用的模型",
                        systemImage: "server.rack",
                        description: Text("请前往底部「服务商」页面填入 API Key，一键拉取或手动添加模型")
                    )
                } else {
                    List {
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

                        ForEach(enabledProviders) { provider in
                            let filteredModels = filterModels(provider.enabledModels)
                            if !filteredModels.isEmpty {
                                Section {
                                    ForEach(filteredModels) { spec in
                                        let target = provider.makeTarget(for: spec)
                                        modelRow(target: target, provider: provider)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color(hex: provider.accentHex))
                                            .frame(width: 8, height: 8)
                                        Text(provider.name)
                                        Spacer()
                                        if KeychainService.shared.hasAPIKey(for: provider.id) {
                                            Text("Key 已就绪")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else {
                                            Text("未填 Key")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "搜索模型名称或 ID")
                }
            }
            .navigationTitle(mode == .single ? "切换对话模型" : "选择并发对比模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if mode == .arenaMulti {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("开启对比 (\(draftArenaTargets.count))") {
                            conversation.arenaTargets = draftArenaTargets
                            conversation.isArenaMode = true
                            dismiss()
                        }
                        .fontWeight(.semibold)
                        .disabled(draftArenaTargets.count < 2)
                    }
                }
            }
            .onAppear {
                if mode == .arenaMulti {
                    if !conversation.arenaTargets.isEmpty {
                        draftArenaTargets = conversation.arenaTargets
                    } else if let primary = conversation.primaryTarget {
                        draftArenaTargets = [primary]
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(target: ResolvedModelTarget, provider: ProviderConfig) -> some View {
        let isSelected: Bool = {
            switch mode {
            case .single:
                return conversation.primaryTarget?.id == target.id && !conversation.isArenaMode
            case .arenaMulti:
                return draftArenaTargets.contains(where: { $0.id == target.id })
            }
        }()

        Button {
            switch mode {
            case .single:
                conversation.primaryTarget = target
                conversation.isArenaMode = false
                dismiss()
            case .arenaMulti:
                if let idx = draftArenaTargets.firstIndex(where: { $0.id == target.id }) {
                    draftArenaTargets.remove(at: idx)
                } else if draftArenaTargets.count < 4 {
                    draftArenaTargets.append(target)
                }
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(target.modelDisplayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        if target.supportsReasoning {
                            Text("思考")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.purple.opacity(0.12), in: Capsule())
                        }
                        if target.supportsVision {
                            Text("识图")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                        }
                    }

                    if target.modelID != target.modelDisplayName {
                        Text(target.modelID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
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
    }

    private func filterModels(_ models: [ModelSpec]) -> [ModelSpec] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q)
        }
    }
}
