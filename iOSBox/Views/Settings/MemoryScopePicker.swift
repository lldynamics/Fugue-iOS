import SwiftData
import SwiftUI

struct MemoryScopePicker: View {
    @Binding var selection: Set<UUID>?
    @Query(sort: \PersonalMemory.createdAt) private var memories: [PersonalMemory]
    @State private var collections: [NamedMemoryCollection] = []
    @State private var showingNameEditor = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var error: String?

    private var enabledIDs: Set<UUID> { Set(memories.filter(\.isEnabled).map(\.id)) }
    private var checkedIDs: Set<UUID> { (selection ?? enabledIDs).intersection(enabledIDs) }

    var body: some View {
        List {
            Section {
                Toggle("使用所有已启用的记忆", isOn: Binding(get: { selection == nil }, set: { all in
                    selection = all ? nil : enabledIDs
                }))
                if let allowed = selection {
                    ForEach(memories.filter(\.isEnabled)) { memory in
                        Toggle(memory.content, isOn: Binding(get: { allowed.contains(memory.id) }, set: { include in
                            if include { selection?.insert(memory.id) } else { selection?.remove(memory.id) }
                        }))
                    }
                }
            }
            Section {
                ForEach(collections) { group in
                    HStack {
                        Button {
                            selection = group.selection(among: enabledIDs)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: group.name).foregroundStyle(.primary)
                                Text("套用 \(group.selection(among: enabledIDs).count) 条已启用的记忆")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        Menu {
                            Button("重命名") { edit(group) }
                            Button("删除集合", role: .destructive) {
                                update { try PresetKnowledgeStore.shared.deleteMemoryCollection(group.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(Text("管理集合「\(group.name)」"))
                    }
                }
                Button { edit(nil) } label: { Label("将当前选择存为集合", systemImage: "plus") }
                    .disabled(checkedIDs.isEmpty)
            } header: {
                Text("记忆集合")
            } footer: {
                Text("套用时复制当前已启用的条目。之后重命名或删除集合，会保留个人记忆和已套用的范围。")
            }
            if let error { Text(verbatim: error).foregroundStyle(DS.StatusText.error) }
        }
        .navigationTitle("可使用的个人记忆")
        .onAppear { update {} }
        .alert("集合名称", isPresented: $showingNameEditor) {
            TextField("例如：工作、写作", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                update {
                    if let editingID { try PresetKnowledgeStore.shared.renameMemoryCollection(editingID, to: name) }
                    else { try PresetKnowledgeStore.shared.saveMemoryCollection(name: name, memoryIDs: checkedIDs) }
                }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > NamedMemoryCollection.maximumNameLength)
        }
    }

    private func edit(_ group: NamedMemoryCollection?) {
        editingID = group?.id
        name = group?.name ?? ""
        showingNameEditor = true
    }

    private func update(_ action: () throws -> Void) {
        do {
            try action()
            collections = try PresetKnowledgeStore.shared.memoryCollections()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
