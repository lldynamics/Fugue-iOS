import SwiftUI
import SwiftData

struct AssistanceSettingsSection: View {
    @Bindable var conversation: Conversation

    var body: some View {
        Section {
            Toggle("使用个人记忆", isOn: binding(\.usePersonalMemory))
            if conversation.assistanceSettings.usePersonalMemory {
                NavigationLink("本会话使用的记忆") {
                    MemoryScopePicker(selection: Binding(get: { conversation.assistanceSettings.scopedMemoryIDs },
                                                          set: { conversation.assistanceSettings.scopedMemoryIDs = $0 }))
                }
            }
            NavigationLink("管理个人长期记忆") { PersonalMemoryView() }
        } header: { Text("跨模型个人记忆") } footer: {
            Text("开启后，将启用的记忆发送给此会话使用的模型。发送前可选择「本次不使用记忆」。")
        }
        if !conversation.isGroupMode && !conversation.isArenaMode {
            Section { ModelRoutingLink(conversation: conversation) }
        }

        Section {
            Toggle("启用提示词缓存 (Prompt Caching)", isOn: binding(\.enablePromptCaching))
            if !conversation.isGroupMode && !conversation.isArenaMode {
                Toggle("开启智能工具 (联网 / 网页 / 记忆建议)", isOn: binding(\.enableAgentTools))
            }
            Toggle("首轮对话后自动生成标题", isOn: binding(\.autoGenerateTitle))
        } header: { Text("智能增强") } footer: {
            Text("提示词缓存可显著降低 Anthropic 长上下文与系统提示词成本；智能工具仅在单聊生效，记忆建议需经你手动确认后才会保存。")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AssistanceSettings, Bool>) -> Binding<Bool> {
        Binding(get: { conversation.assistanceSettings[keyPath: keyPath] }, set: { conversation.assistanceSettings[keyPath: keyPath] = $0 })
    }

}

struct ModelRoutingLink: View {
    @Bindable var conversation: Conversation
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    var body: some View {
        let configured = conversation.assistanceSettings.fallbackTargets
        let usable = AssistancePolicy.fallbackAvailability(after: conversation.primaryTarget?.id, configured: configured,
            available: ProviderConfig.readyTargets(in: providers)).compactMap { $0 }.count
        NavigationLink {
            ModelRoutingSettings(conversation: conversation)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("模型路由与备用模型")
                Group {
                    if configured.isEmpty {
                        Text("尚未设置备用模型")
                    } else if usable > 0 && conversation.assistanceSettings.fallbackEnabled {
                        Text("备用已启用 · \(usable) 个可用，\(configured.count - usable) 个不可用")
                    } else {
                        Text("备用未启用 · \(usable) 个可用，\(configured.count - usable) 个不可用")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ModelRoutingSettings: View {
    @Bindable var conversation: Conversation
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    private var available: [ResolvedModelTarget] { ProviderConfig.readyTargets(in: providers) }

    var body: some View {
        let backups = conversation.assistanceSettings.fallbackTargets
        let alternatives = conversation.primaryTarget.map { primary in available.filter { $0.id != primary.id } } ?? []
        let availability = AssistancePolicy.fallbackAvailability(after: conversation.primaryTarget?.id, configured: backups, available: alternatives)
        let hasUsableBackup = availability.contains { $0 != nil }
        Form {
            Section {
                Toggle("按输入类型选择模型", isOn: $conversation.assistanceSettings.automaticRouting)
                if conversation.assistanceSettings.automaticRouting {
                    targetPicker("图片模型", selected: conversation.assistanceSettings.imageTarget, targets: available.filter(\.supportsVision)) {
                        conversation.assistanceSettings.imageTarget = $0
                    }
                    targetPicker("代码模型", selected: conversation.assistanceSettings.codeTarget, targets: available) {
                        conversation.assistanceSettings.codeTarget = $0
                    }
                }
            } header: { Text("能力路由") } footer: {
                Text("仅用于单聊新消息。图片优先；含 Markdown 代码围栏或代码文件时使用代码模型。其余输入使用当前模型。未配置图片模型时会检查当前模型的识图能力；指定模型不可用时保留输入并提示。")
            }
            Section {
                Toggle("启用故障降级", isOn: Binding(get: { hasUsableBackup && conversation.assistanceSettings.fallbackEnabled },
                    set: { conversation.assistanceSettings.fallbackEnabled = $0 }))
                    .disabled(!hasUsableBackup)
                if conversation.primaryTarget == nil {
                    Text("请先选择主回答模型。").foregroundStyle(.secondary)
                } else if !hasUsableBackup {
                    Text("选择备用模型后即可启用故障降级。").foregroundStyle(.secondary)
                }
                ForEach(Array(backups.enumerated()), id: \.offset) { index, target in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(index + 1). \(target.providerName) · \(target.modelDisplayName)")
                            Text(availability[index] == nil ? "当前不可用" : "可用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            conversation.assistanceSettings.fallbackTargets.remove(at: index)
                            if !AssistancePolicy.fallbackAvailability(after: conversation.primaryTarget?.id,
                                configured: conversation.assistanceSettings.fallbackTargets, available: alternatives).contains(where: { $0 != nil }) {
                                conversation.assistanceSettings.fallbackEnabled = false
                            }
                        } label: { Image(systemName: "minus.circle") }.accessibilityLabel("移除备用模型")
                    }
                }
                if backups.count < AssistancePolicy.maxFallbackTargets {
                    let choices = alternatives.filter { target in !backups.contains(where: { $0.id == target.id }) }
                    Menu("添加备用模型") {
                        ForEach(choices) { target in
                            Button("\(target.providerName) · \(target.modelDisplayName)") {
                                conversation.assistanceSettings.fallbackTargets.append(target)
                                if !hasUsableBackup { conversation.assistanceSettings.fallbackEnabled = true }
                            }
                        }
                    }
                    .disabled(choices.isEmpty)
                    if conversation.primaryTarget != nil && choices.isEmpty && !hasUsableBackup {
                        Text("请先启用另一个可用模型。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("备用链路（按顺序）") } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("备用模型适用于单聊的发送、重新生成和继续生成。快捷指令发送、圆桌和多模型对比固定使用指定模型。")
                    Text("限流、服务暂时不可用或超时且尚无输出时，按顺序尝试备用模型。上下文及本次选用的记忆会发送给备用服务商，每次尝试独立记账。")
                }
            }
        }
        .navigationTitle("模型路由与备用模型")
    }

    private func targetPicker(_ title: LocalizedStringKey, selected: ResolvedModelTarget?, targets: [ResolvedModelTarget],
                              set: @escaping (ResolvedModelTarget?) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selected?.id ?? "" }, set: { id in set(targets.first { $0.id == id }) })) {
            Text("使用当前模型").tag("")
            if let selected, !targets.contains(where: { $0.id == selected.id }) {
                Text("已不可用：\(selected.modelDisplayName)").tag(selected.id)
            }
            ForEach(targets) { target in Text("\(target.providerName) · \(target.modelDisplayName)").tag(target.id) }
        }
    }
}
