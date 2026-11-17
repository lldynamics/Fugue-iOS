import SwiftUI
import SwiftData

struct AssistantListView: View {
    var onStartChatWithPreset: (AssistantPreset) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]

    @State private var editingPreset: AssistantPreset?
    @State private var showCreateSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presets) { preset in
                        HStack(spacing: 12) {
                            Text(preset.iconEmoji)
                                .font(.system(size: 28))
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(preset.name)
                                        .font(.body.weight(.semibold))
                                    if preset.enableThinking {
                                        Text("思考")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.purple)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.purple.opacity(0.12), in: Capsule())
                                    }
                                }

                                Text(preset.subtitle.isEmpty ? preset.systemPrompt : preset.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Button {
                                onStartChatWithPreset(preset)
                            } label: {
                                Text("对话")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingPreset = preset
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                modelContext.delete(preset)
                                try? modelContext.save()
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                editingPreset = preset
                            } label: {
                                Label("编辑", systemImage: "slider.horizontal.3")
                            }
                            .tint(.blue)
                        }
                    }
                } header: {
                    Text("点击卡片可编辑提示词与采样参数，点击「对话」立即创建专属会话")
                }
            }
            .navigationTitle("助手预设")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("新建助手", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editingPreset) { preset in
                AssistantEditorSheet(preset: preset)
            }
            .sheet(isPresented: $showCreateSheet) {
                AssistantEditorSheet(preset: nil)
            }
        }
    }
}
