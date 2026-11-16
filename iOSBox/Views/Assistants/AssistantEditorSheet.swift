import SwiftUI
import SwiftData

struct AssistantEditorSheet: View {
    let preset: AssistantPreset?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var iconEmoji: String = "🤖"
    @State private var subtitle: String = ""
    @State private var systemPrompt: String = ""
    @State private var temperature: Double = 0.7
    @State private var useCustomTemperature: Bool = true
    @State private var topP: Double = 1.0
    @State private var contextMessageLimit: Int = 20
    @State private var enableThinking: Bool = true

    private let emojiChoices = ["🤖", "✨", "💻", "🧠", "🌐", "✍️", "📊", "🎨", "📚", "🔍", "🧪", "⚖️"]

    var body: some View {
        NavigationStack {
            Form {
                Section("外观与名称") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(emojiChoices, id: \.self) { emoji in
                                Button {
                                    iconEmoji = emoji
                                } label: {
                                    Text(emoji)
                                        .font(.title2)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            iconEmoji == emoji
                                                ? Color.accentColor.opacity(0.2)
                                                : Color(.secondarySystemBackground),
                                            in: Circle()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    TextField("助手名称（例如：Swift 专家）", text: $name)
                    TextField("简短描述（可选）", text: $subtitle)
                }

                Section("System Prompt（系统提示词）") {
                    TextField("定义角色身份、输出风格与约束条件…", text: $systemPrompt, axis: .vertical)
                        .lineLimit(5...12)
                }

                Section("默认参数") {
                    Toggle("默认开启深度思考", isOn: $enableThinking)
                    Toggle("自定义随机度 (Temperature)", isOn: $useCustomTemperature)
                    if useCustomTemperature {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", temperature))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $temperature, in: 0.0...2.0, step: 0.05)
                    }
                    Stepper("默认携带上下文：\(contextMessageLimit == 0 ? "全部" : "\(contextMessageLimit) 条")", value: $contextMessageLimit, in: 0...60, step: 4)
                }
            }
            .navigationTitle(preset == nil ? "新建助手预设" : "编辑助手预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        savePreset()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let p = preset {
                    name = p.name
                    iconEmoji = p.iconEmoji
                    subtitle = p.subtitle
                    systemPrompt = p.systemPrompt
                    temperature = p.temperature
                    useCustomTemperature = p.useCustomTemperature
                    topP = p.topP
                    contextMessageLimit = p.contextMessageLimit
                    enableThinking = p.enableThinking
                }
            }
        }
    }

    private func savePreset() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if let existing = preset {
            existing.name = trimmedName
            existing.iconEmoji = iconEmoji
            existing.subtitle = subtitle
            existing.systemPrompt = systemPrompt
            existing.temperature = temperature
            existing.useCustomTemperature = useCustomTemperature
            existing.topP = topP
            existing.contextMessageLimit = contextMessageLimit
            existing.enableThinking = enableThinking
        } else {
            let created = AssistantPreset(
                name: trimmedName,
                iconEmoji: iconEmoji,
                subtitle: subtitle,
                systemPrompt: systemPrompt,
                temperature: temperature,
                useCustomTemperature: useCustomTemperature,
                topP: topP,
                contextMessageLimit: contextMessageLimit,
                enableThinking: enableThinking,
                sortOrder: Int(Date().timeIntervalSince1970)
            )
            modelContext.insert(created)
        }
        try? modelContext.save()
        dismiss()
    }
}
