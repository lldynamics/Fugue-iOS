import SwiftUI
import SwiftData

struct AssistanceSettingsSection: View {
    @Bindable var conversation: Conversation
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    private var available: [ResolvedModelTarget] { ChatEngine.shared.availableTargets(from: providers) }

    var body: some View {
        Section {
            Toggle("使用个人记忆", isOn: binding(\.usePersonalMemory))
            NavigationLink("管理个人长期记忆") { PersonalMemoryView() }
        } header: { Text("跨模型个人记忆") } footer: {
            Text("开启后，将启用的记忆发送给此会话使用的模型。发送前可选择「本次不使用记忆」。")
        }
        if !conversation.isGroupMode {
            Section {
                Toggle("按输入类型选择模型", isOn: binding(\.automaticRouting))
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
                Toggle("启用故障降级", isOn: binding(\.fallbackEnabled))
                if conversation.assistanceSettings.fallbackEnabled {
                    ForEach(Array(conversation.assistanceSettings.fallbackTargets.enumerated()), id: \.offset) { index, target in
                        HStack {
                            Text("\(index + 1). \(target.providerName) · \(target.modelDisplayName)").font(.subheadline)
                            Spacer()
                            Button {
                                conversation.assistanceSettings.fallbackTargets.remove(at: index)
                            } label: { Image(systemName: "minus.circle") }.accessibilityLabel("移除备用模型")
                        }
                    }
                    if conversation.assistanceSettings.fallbackTargets.count < 3 {
                        Menu("添加备用模型") {
                            ForEach(available.filter { !conversation.assistanceSettings.fallbackTargets.contains($0) }) { target in
                                Button("\(target.providerName) · \(target.modelDisplayName)") {
                                    conversation.assistanceSettings.fallbackTargets.append(target)
                                }
                            }
                        }
                    }
                }
            } header: { Text("备用链路（按顺序）") } footer: {
                Text("仅单聊生效，最多 3 个备用模型。尚未收到正文或思考时，HTTP 429/502/503/504 或网络超时会按顺序切换；已输出、鉴权错误、内容拦截和取消不会切换。上下文及启用的记忆会发给备用服务商，每次尝试独立记账。")
            }
        }

        Section {
            Toggle("启用提示词缓存 (Prompt Caching)", isOn: binding(\.enablePromptCaching))
            if !conversation.isGroupMode {
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
