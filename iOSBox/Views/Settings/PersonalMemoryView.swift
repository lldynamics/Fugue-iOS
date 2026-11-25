import SwiftUI
import SwiftData

struct PersonalMemoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PersonalMemory.createdAt) private var memories: [PersonalMemory]
    @State private var scopeStore = MemoryScopeStore.shared
    @State private var editor: MemoryDraft?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(memories) { memory in
                    let tags = scopeStore.tags(for: memory.id)
                    HStack {
                        Button {
                            editor = MemoryDraft(id: memory.id, text: memory.content, tagsText: tags.joined(separator: ", "))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(memory.content).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                if !tags.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(tags, id: \.self) { tag in
                                            Text("#\(tag)")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color(.secondarySystemBackground), in: Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        Spacer()
                        Toggle("启用记忆", isOn: Binding(get: { memory.isEnabled }, set: {
                            let old = memory.isEnabled
                            memory.isEnabled = $0
                            do { try context.save() } catch { memory.isEnabled = old; self.error = error.localizedDescription }
                        }))
                        .labelsHidden()
                        .accessibilityLabel(String(localized: "启用记忆") + ": " + memory.content)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { remove(memory) }
                        Button("编辑") {
                            editor = MemoryDraft(id: memory.id, text: memory.content, tagsText: tags.joined(separator: ", "))
                        }
                    }
                }
                Button { editor = MemoryDraft() } label: { Label("添加记忆", systemImage: "plus") }
                    .disabled(memories.count >= PersonalMemory.maximumCount)
            } header: { Text("个人长期记忆") } footer: {
                Text("手动记录职业、技术栈或语言偏好，最多 20 条，每条 500 字。启用会话记忆后，这些内容会随请求发送给所选模型及备用服务商；可在发送前临时关闭。不会自动提取聊天内容。")
            }
            Section {
                Text("记忆保存在本机，并包含在完整 JSON 备份中。删除记忆不会清除服务商已收到的内容，也不会改写历史回答。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("个人长期记忆")
        .sheet(item: $editor) { draft in MemoryEditorSheet(draft: draft) }
    }

    private func remove(_ memory: PersonalMemory) {
        do {
            try context.save()
            let transaction = ModelContext(context.container)
            let id = memory.id
            if let item = try transaction.fetch(FetchDescriptor<PersonalMemory>(predicate: #Predicate { $0.id == id })).first {
                transaction.delete(item)
                try transaction.save()
                if !context.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                    SyncTombstoneStore.shared.recordDeletion(kind: .memory, id: id)
                }
                scopeStore.remove(memoryID: id)
                context.processPendingChanges()
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct MemoryDraft: Identifiable {
    var id = UUID()
    var text = ""
    var tagsText = ""
}

private struct MemoryEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let draft: MemoryDraft
    @State private var text: String
    @State private var tagsText: String
    @State private var error: String?

    init(draft: MemoryDraft) {
        self.draft = draft
        _text = State(initialValue: draft.text)
        _tagsText = State(initialValue: draft.tagsText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("记忆内容") {
                    TextField("例如：我使用 Swift，偏好简体中文回答。", text: $text, axis: .vertical).lineLimit(5...12)
                    Text("\(text.count) / 500").font(.caption).foregroundStyle(text.count > 500 ? .red : .secondary)
                }
                Section {
                    TextField("留空为全局记忆，或逗号分隔如：工程, 写作", text: $tagsText)
                } header: {
                    Text("适用分区标签（可选）")
                } footer: {
                    Text("为记忆打上标签后，在对应标签的项目空间对话中会自动命中；留空则在所有对话中生效。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("编辑记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 500)
                }
            }
        }
    }

    private func save() {
        do {
            try context.save()
            let transaction = ModelContext(context.container)
            let items = try transaction.fetch(FetchDescriptor<PersonalMemory>())
            if let item = items.first(where: { $0.id == draft.id }) { item.content = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else {
                guard items.count < PersonalMemory.maximumCount else { return }
                transaction.insert(PersonalMemory(id: draft.id, content: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            try transaction.save()
            MemoryScopeStore.shared.setTags(ProjectWorkspace.normalizedTags(from: tagsText), for: draft.id)
            context.processPendingChanges()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
