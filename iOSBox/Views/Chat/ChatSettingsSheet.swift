import SwiftUI
import SwiftData

struct ChatSettingsSheet: View {
    @Bindable var conversation: Conversation
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]
    @Environment(\.dismiss) private var dismiss

    private let contextChoices: [(label: String, value: Int)] = [
        ("最近 4 条", 4),
        ("最近 10 条", 10),
        ("最近 20 条", 20),
        ("最近 50 条", 50),
        ("全部历史", 0)
    ]

    var body: some View {
        NavigationStack {
            Form {
                if !presets.isEmpty {
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
                                            active ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                                            in: Capsule()
                                        )
                                        .overlay(
                                            Capsule().strokeBorder(
                                                active ? Color.accentColor : Color.clear,
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
                } header: {
                    Text("系统提示词 (System Prompt)")
                } footer: {
                    Text("对当前会话内的所有模型（含并发对比模型）生效。")
                }

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
                        ForEach(contextChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
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
            .navigationTitle("会话参数与预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
