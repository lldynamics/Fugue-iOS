import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBindingSheet: View {
    @Binding var selectedVolumeIDs: [UUID]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var volumes: [BookVolume]

    @State private var pickingFile = false
    @State private var importing = false
    @State private var importError: String?
    @State private var preferences = AppPreferences.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pickingFile = true
                    } label: {
                        if importing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在导入并索引文档…")
                            }
                        } else {
                            Label("从文件导入新参考资料 (PDF / EPUB / MD / TXT)", systemImage: "doc.badge.plus")
                        }
                    }
                    .disabled(importing)

                    if !selectedVolumeIDs.isEmpty {
                        Button(role: .destructive) {
                            selectedVolumeIDs.removeAll()
                            preferences.triggerSelectionHaptic()
                        } label: {
                            Label("清空本会话已绑定的知识库", systemImage: "xmark.circle")
                        }
                    }
                } footer: {
                    Text("绑定参考资料后，单聊、Arena 并发对比与圆桌群聊会自动检索高相关原文片段并带精确章节/页码作答；开启「工具」时模型也可主动调用 search_documents 深入查阅。")
                }

                Section {
                    if volumes.isEmpty {
                        Text("书架中暂无文档。点击上方按钮即可导入技术文档、论文、财报或电子书（支持扫描版 PDF 离线 OCR）。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(volumes) { volume in
                            let isBound = selectedVolumeIDs.contains(volume.id)
                            Button {
                                toggleBinding(for: volume.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isBound ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(isBound ? .teal : .secondary)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: volume.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("共 \(volume.chapterTitles.count) 节 · \(ByteCountFormatter.string(fromByteCount: Int64(volume.displayByteCount), countStyle: .file))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("选择参考资料（已选 \(selectedVolumeIDs.count)/12）")
                }
            }
            .navigationTitle("本地参考知识库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .fileImporter(
                isPresented: $pickingFile,
                allowedContentTypes: [.plainText, .pdf] + ["epub", "md", "markdown"].compactMap { UTType(filenameExtension: $0) }
            ) { result in
                switch result {
                case .success(let url):
                    importAndBind(url)
                case .failure(let err):
                    if (err as NSError).code != NSUserCancelledError {
                        importError = err.localizedDescription
                    }
                }
            }
            .alert("书籍提示", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(verbatim: importError ?? "")
            }
        }
    }

    private func toggleBinding(for id: UUID) {
        if let idx = selectedVolumeIDs.firstIndex(of: id) {
            selectedVolumeIDs.remove(at: idx)
        } else if selectedVolumeIDs.count < 12 {
            selectedVolumeIDs.append(id)
        }
        preferences.triggerSelectionHaptic()
    }

    private func importAndBind(_ url: URL) {
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try BookImporter.read(url)
                }.value
                let stored = try BookLibrary.store(prepared, in: modelContext)
                if !selectedVolumeIDs.contains(stored.id) && selectedVolumeIDs.count < 12 {
                    selectedVolumeIDs.append(stored.id)
                }
                preferences.triggerLightHaptic()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}
