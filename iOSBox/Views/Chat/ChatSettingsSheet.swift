import SwiftUI
import SwiftData

struct ChatSettingsSheet: View {
    @Bindable var conversation: Conversation
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var preferences = AppPreferences.shared
    @State private var summaryStore = RollingContextSummaryStore.shared

    var body: some View {
        NavigationStack {
            Form {
                if !presets.isEmpty && !conversation.isGroupMode {
                    Section("一键套用助手角色") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(presets) { preset in
                                    let active = conversation.assistantID == preset.id
                                    Button {
                                        conversation.applyPreset(preset)
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(preset.iconEmoji)
                                            Text(preset.name)
                                                .font(.caption.weight(.medium))
                                        }
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 7)
                                        .background(
                                            active ? preferences.accentTheme.softFill : DS.Surface.subtle,
                                            in: Capsule()
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(
                                                active ? preferences.accentTheme.tintColor : DS.Surface.hairline,
                                                lineWidth: 1
                                            )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    TextField("输入系统提示词（System Prompt）…", text: $conversation.systemPrompt, axis: .vertical)
                        .lineLimit(3...10)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(PromptTemplateEngine.availableVariables) { item in
                                Button {
                                    if conversation.systemPrompt.isEmpty {
                                        conversation.systemPrompt = item.token
                                    } else {
                                        conversation.systemPrompt += " \(item.token)"
                                    }
                                } label: {
                                    Text(item.token)
                                        .font(.caption2.monospaced())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(DS.Surface.subtle, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("系统提示词 (System Prompt)")
                } footer: {
                    Text("对当前会话内的所有模型（含并发对比模型）生效。支持插入 {{date}}、{{time}}、{{model}} 等动态变量。")
                }

                AssistanceSettingsSection(conversation: conversation)

                Section("推理与深度思考") {
                    Toggle("启用深度思考 (Thinking / R1)", isOn: $conversation.enableThinking)

                    if conversation.enableThinking {
                        Stepper(
                            "思考 Token 预算：\(conversation.thinkingBudgetTokens)",
                            value: $conversation.thinkingBudgetTokens,
                            in: 1024...32768,
                            step: 1024
                        )
                        .font(.subheadline)
                    }
                }

                Section("采样与上下文控制") {
                    Toggle("自定义随机度 (Temperature)", isOn: $conversation.useCustomTemperature)

                    if conversation.useCustomTemperature {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Temperature")
                                Spacer()
                                Text(String(format: "%.2f", conversation.temperature))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $conversation.temperature, in: 0.0...2.0, step: 0.05)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Top P")
                            Spacer()
                            Text(String(format: "%.2f", conversation.topP))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $conversation.topP, in: 0.1...1.0, step: 0.05)
                    }

                    Picker("携带上下文条数", selection: $conversation.contextMessageLimit) {
                        ForEach(ContextLimitOptions.values(including: conversation.contextMessageLimit), id: \.self) { value in
                            Text(ContextLimitOptions.label(for: value)).tag(value)
                        }
                    }

                    Toggle("长对话自动滚动摘要", isOn: $preferences.autoRollingSummaryEnabled)

                    if let summary = summaryStore.summary(for: conversation.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("已压缩前 \(summary.coveredMessageCount) 条历史摘要", systemImage: "text.alignleft")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("清除摘要", role: .destructive) {
                                    summaryStore.remove(for: conversation.id)
                                }
                                .font(.caption)
                            }
                            Text(summary.summaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        .padding(.vertical, 2)
                    }

                    HStack {
                        Text("最大输出 Tokens (0=默认)")
                        Spacer()
                        TextField("0", value: $conversation.maxOutputTokens, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Surface.grouped)
            .navigationTitle("会话参数与预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                try? modelContext.save()
            }
        }
    }
}
