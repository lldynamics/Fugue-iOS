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
    @State private var thinkingBudgetTokens: Int = 4096
    @State private var maxOutputTokens: Int = 0
    @State private var knowledgeVolumeIDs: [UUID] = []
    @State private var savedNewPreset: AssistantPreset?
    @State private var bindingError: String?
    @State private var needsBindingReload = false
    @State private var damagedBindings = false
    @State private var showKnowledgePicker = false

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
                                                : DS.Surface.subtle,
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

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(PromptTemplateEngine.availableVariables) { item in
                                Button {
                                    if systemPrompt.isEmpty {
                                        systemPrompt = item.token
                                    } else {
                                        systemPrompt += " \(item.token)"
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
                }

                Section("默认参数") {
                    Toggle("默认开启深度思考", isOn: $enableThinking)
                    if enableThinking {
                        Stepper(
                            "思考 Token 预算：\(thinkingBudgetTokens)",
                            value: $thinkingBudgetTokens,
                            in: 1024...32768,
                            step: 1024
                        )
                    }

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

                    HStack {
                        Text("Top P")
                        Spacer()
                        Text(String(format: "%.2f", topP))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $topP, in: 0.1...1.0, step: 0.05)

                    Picker("默认携带上下文", selection: $contextMessageLimit) {
                        ForEach(ContextLimitOptions.values(including: contextMessageLimit), id: \.self) { value in
                            Text(ContextLimitOptions.label(for: value)).tag(value)
                        }
                    }

                    HStack {
                        Text("最大输出 Tokens (0=默认)")
                        Spacer()
                        TextField("0", value: $maxOutputTokens, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }

                Section {
                    Button {
                        showKnowledgePicker = true
                    } label: {
                        HStack {
                            Label("绑定本地参考知识库", systemImage: "books.vertical")
                            Spacer()
                            Text(knowledgeVolumeIDs.isEmpty ? String(localized: "未绑定") : String(localized: "已绑定 \(knowledgeVolumeIDs.count) 份"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("专属知识库 (NotebookLM 模式)")
                } footer: {
                    Text("使用此助手开启新对话时，将自动挂载所选书架文档并支持章节引用问答。")
                }
            }
            .sheet(isPresented: $showKnowledgePicker) {
                KnowledgeBindingSheet(selectedVolumeIDs: $knowledgeVolumeIDs)
            }
            .navigationTitle(preset == nil ? String(localized: "新建助手预设") : String(localized: "编辑助手预设"))
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
                    thinkingBudgetTokens = p.thinkingBudgetTokens
                    maxOutputTokens = p.maxOutputTokens
                }
                loadBindings()
            }
            .alert("助手资料存储提示", isPresented: Binding(get: { bindingError != nil }, set: { if !$0 { bindingError = nil } })) {
                if damagedBindings {
                    Button("归档损坏的绑定文件并重建", role: .destructive) {
                        do { try PresetKnowledgeStore.shared.preserveDamagedLibrary(); loadBindings() }
                        catch { bindingError = error.localizedDescription }
                    }
                }
                Button("好", role: .cancel) { }
            } message: {
                Text(verbatim: bindingError ?? "")
            }
        }
    }

    private func loadBindings() {
        do {
            let bindings = try PresetKnowledgeStore.shared.readableBindings()
            if let preset { knowledgeVolumeIDs = bindings[preset.id.uuidString] ?? [] }
            needsBindingReload = false
            damagedBindings = false
        } catch {
            needsBindingReload = true
            damagedBindings = error is DecodingError
            bindingError = error.localizedDescription
        }
    }

    private func savePreset() {
        if needsBindingReload { loadBindings(); return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let sanitizedMaxTokens = max(0, maxOutputTokens)

        let record: AssistantPreset
        if let existing = preset ?? savedNewPreset {
            existing.name = trimmedName
            existing.iconEmoji = iconEmoji
            existing.subtitle = subtitle
            existing.systemPrompt = systemPrompt
            existing.temperature = temperature
            existing.useCustomTemperature = useCustomTemperature
            existing.topP = topP
            existing.contextMessageLimit = contextMessageLimit
            existing.enableThinking = enableThinking
            existing.thinkingBudgetTokens = thinkingBudgetTokens
            existing.maxOutputTokens = sanitizedMaxTokens
            record = existing
        } else {
            let created = AssistantPreset(
                name: trimmedName,
                iconEmoji: iconEmoji,
                subtitle: subtitle,
                systemPrompt: systemPrompt,
                temperature: temperature,
                useCustomTemperature: useCustomTemperature,
                topP: topP,
                maxOutputTokens: sanitizedMaxTokens,
                contextMessageLimit: contextMessageLimit,
                enableThinking: enableThinking,
                thinkingBudgetTokens: thinkingBudgetTokens,
                sortOrder: Int(Date().timeIntervalSince1970)
            )
            modelContext.insert(created)
            savedNewPreset = created
            record = created
        }
        do {
            try modelContext.save()
            try PresetKnowledgeStore.shared.setVolumeIDs(knowledgeVolumeIDs, for: record.id)
            dismiss()
        } catch {
            damagedBindings = error is DecodingError
            bindingError = error.localizedDescription
        }
    }
}
