import SwiftData
import SwiftUI

struct KnowledgeSearchSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var stats = FullTextIndexStats()
    @State private var isRebuildingFTS = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                LabeledContent("已索引对话 / 消息") {
                    Text("\(stats.conversationCount) / \(stats.messageCount)")
                        .monospacedDigit()
                }
                LabeledContent("已索引书架章节") {
                    Text("\(stats.bookChunkCount)")
                        .monospacedDigit()
                }
                LabeledContent("本地知识库检索切片") {
                    Text("\(stats.ragChunkCount)")
                        .monospacedDigit()
                }
                if stats.databaseBytes > 0 {
                    LabeledContent("索引库体积") {
                        Text(ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file))
                            .monospacedDigit()
                    }
                }

                Button {
                    Task { await rebuildFullTextIndex() }
                } label: {
                    if isRebuildingFTS {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在重建全文索引…")
                        }
                    } else {
                        Label("立即重建 FTS5 全文索引", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRebuildingFTS)
            } header: {
                Text("SQLite FTS5 全文与知识库索引")
            } footer: {
                Text("纯本机运行，支持中英多词分词与 BM25 相关性排序，可一次搜索全部对话正文、思考过程、附件名与书架文档，无需配置外部向量 API。")
            }

            if let statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .primary)
                }
            }
        }
        .navigationTitle("全文检索与知识库索引")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStats()
        }
    }

    private func refreshStats() async {
        stats = await FullTextSearchIndex.shared.stats()
    }

    private func rebuildFullTextIndex() async {
        isRebuildingFTS = true
        statusMessage = nil
        defer { isRebuildingFTS = false }
        do {
            let search = ConversationHistorySearch()
            stats = try await search.rebuildIndex(in: modelContext.container)
            statusIsError = false
            statusMessage = String(localized: "已完成 FTS5 全文索引重建：\(stats.messageCount) 条消息、\(stats.bookChunkCount) 个书架章节。")
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
