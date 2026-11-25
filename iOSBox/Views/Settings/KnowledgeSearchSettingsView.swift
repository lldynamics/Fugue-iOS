import SwiftData
import SwiftUI

struct KnowledgeSearchSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \BookVolume.importedAt, order: .reverse) private var volumes: [BookVolume]
    @AppStorage(EmbeddingConsent.key) private var approvedScope = ""

    @State private var preferences = AppPreferences.shared
    @State private var stats = FullTextIndexStats()
    @State private var isRebuildingFTS = false
    @State private var isTestingEmbedding = false
    @State private var isIndexingVectors = false
    @State private var vectorProgressText: String?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var showClearVectorsConfirm = false
    @State private var showEmbeddingConsent = false
    @State private var pendingEmbeddingConsent: EmbeddingConfig?

    private var eligibleProviders: [ProviderConfig] {
        EmbeddingClient.eligibleProviders(from: providers)
    }

    private var configuredEmbedding: EmbeddingConfig? {
        EmbeddingClient.resolvedConfig(providers: providers, preferences: preferences)
    }

    private var authorizedEmbedding: EmbeddingConfig? {
        guard let config = configuredEmbedding, let endpoint = try? config.endpoint,
              approvedScope == config.consentScope(for: endpoint) else {
            return nil
        }
        return config
    }

    private var isBusy: Bool {
        isRebuildingFTS || isTestingEmbedding || isIndexingVectors
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("已索引对话 / 消息") {
                    Text("\(stats.conversationCount) / \(stats.messageCount)")
                        .monospacedDigit()
                }
                LabeledContent("已索引书架章节 / 闪卡") {
                    Text("\(stats.bookChunkCount) / \(stats.flashcardCount)")
                        .monospacedDigit()
                }
                LabeledContent("本地 RAG 切片 / 已向量化") {
                    Text("\(stats.ragChunkCount) / \(stats.ragEmbeddedChunkCount)")
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
                .disabled(isBusy)
            } header: {
                Text("SQLite FTS5 全文检索索引")
            } footer: {
                Text("支持中英多词分词与 BM25 相关性排序，可一次搜索全部对话正文、思考过程、附件名、书架文档与助学闪卡。")
            }

            Section {
                Toggle("启用向量 API 混合检索", isOn: $preferences.ragHybridEmbeddingEnabled)
                    .disabled(isBusy)

                if preferences.ragHybridEmbeddingEnabled {
                    if eligibleProviders.isEmpty {
                        Text("请先在「服务商与设置」中启用至少一个 OpenAI 兼容或 Gemini 服务商。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("向量服务商", selection: $preferences.ragEmbeddingProviderID) {
                            Text("自动（首选兼容服务商）").tag(UUID?.none)
                            ForEach(eligibleProviders) { provider in
                                Text(provider.name).tag(UUID?.some(provider.id))
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Embedding 模型").font(.caption).foregroundStyle(.secondary)
                            TextField("例如：text-embedding-3-small", text: $preferences.ragEmbeddingModel)
                                .accessibilityLabel("Embedding 模型")
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: DS.Spacing.xs) {
                                ForEach(EmbeddingClient.presetModels, id: \.self) { model in
                                    presetModelChip(model)
                                }
                            }
                        }

                        if let config = configuredEmbedding, let endpoint = try? config.endpoint {
                            LabeledContent("当前向量接收方", value: embeddingRecipient(config, endpoint: endpoint))
                            if authorizedEmbedding != nil {
                                Button("撤回向量服务授权", role: .destructive) { approvedScope = "" }
                            } else {
                                Button("查看并授权向量服务") {
                                    pendingEmbeddingConsent = config
                                    showEmbeddingConsent = true
                                }
                                .disabled(isBusy)
                            }
                        }

                        Button {
                            Task { await testEmbeddingEndpoint() }
                        } label: {
                            if isTestingEmbedding {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在测试向量接口…")
                                }
                            } else {
                                Label("测试向量接口", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .disabled(isBusy || authorizedEmbedding == nil)
                    }
                }

                Button {
                    Task { await indexBookshelfVectors() }
                } label: {
                    if isIndexingVectors {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(vectorProgressText ?? String(localized: "正在为书架生成向量索引…"))
                        }
                    } else {
                        Label(
                            authorizedEmbedding != nil
                                ? String(localized: "为书架文档生成混合向量索引（\(volumes.count) 本）")
                                : String(localized: "为书架文档预建本地检索索引（\(volumes.count) 本）"),
                            systemImage: "sparkles.rectangle.stack"
                        )
                    }
                }
                .disabled(isBusy || volumes.isEmpty)

                if stats.ragEmbeddedChunkCount > 0 {
                    Button("清除已缓存向量", role: .destructive) {
                        showClearVectorsConfirm = true
                    }
                    .disabled(isBusy)
                }
            } header: {
                Text("本地 RAG 混合检索（FTS5 + RRF）")
            } footer: {
                Text("授权当前向量服务后才能使用向量 API。服务不可用或授权撤回后，知识库检索会使用本地索引。")
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
        .alert("授权向量服务？", isPresented: $showEmbeddingConsent, presenting: pendingEmbeddingConsent) { config in
            Button("同意并授权") {
                defer { pendingEmbeddingConsent = nil }
                guard let current = configuredEmbedding,
                      let endpoint = try? config.endpoint, let currentEndpoint = try? current.endpoint,
                      config.consentScope(for: endpoint) == current.consentScope(for: currentEndpoint) else {
                    statusMessage = AppCompliance.RequestChanged().localizedDescription
                    statusIsError = true
                    return
                }
                approvedScope = config.consentScope(for: endpoint)
            }
            Button("暂不授权", role: .cancel) { pendingEmbeddingConsent = nil }
        } message: { config in
            if let endpoint = try? config.endpoint {
                Text("接收方为 \(embeddingRecipient(config, endpoint: endpoint))。生成书架索引会发送书架文档的原文片段。聊天和工具检索会发送查询词，以及绑定文档中需要生成向量的原文片段。服务商可能留存这些内容或收取费用。你可以随时撤回授权。")
            }
        }
        .alert("清除已缓存向量？", isPresented: $showClearVectorsConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                Task { await clearVectors() }
            }
        } message: {
            Text("将清空本地缓存的文档语义向量（不会删除书架原文和对话），下次检索或手动索引时会按当前模型重新生成。")
        }
    }

    private func embeddingRecipient(_ config: EmbeddingConfig, endpoint: URL) -> String {
        let origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let host = origin?.host ?? ""
        let address = origin?.port.map { "\(host):\($0)" } ?? host
        return "\(config.providerName) · \(config.modelID) (\(address))"
    }

    private func presetModelChip(_ model: String) -> some View {
        let selected = preferences.ragEmbeddingModel == model
        return Button {
            preferences.ragEmbeddingModel = model
            preferences.triggerSelectionHaptic()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: model)
                if selected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .font(.subheadline)
            .foregroundStyle(selected ? preferences.accentTheme.readableText : .primary)
            .padding(.horizontal, 12)
            .frame(minHeight: DS.TouchTarget.minimum + 2)
            .background(selected ? preferences.accentTheme.softFill : Color.secondary.opacity(0.10), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshStats() async {
        stats = await FullTextSearchIndex.shared.stats()
    }

    private func rebuildFullTextIndex() async {
        isRebuildingFTS = true
        statusMessage = nil
        defer { isRebuildingFTS = false }
        do {
            let cards = FlashcardStore.shared.cards
            let search = ConversationHistorySearch()
            stats = try await search.rebuildIndex(in: modelContext.container, flashcards: cards)
            statusIsError = false
            statusMessage = String(localized: "已完成 FTS5 全文索引重建：\(stats.messageCount) 条消息、\(stats.bookChunkCount) 个书架章节、\(stats.flashcardCount) 张闪卡。")
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func testEmbeddingEndpoint() async {
        guard let config = authorizedEmbedding else {
            statusIsError = true
            statusMessage = EmbeddingClientError.consentRequired.localizedDescription
            return
        }
        isTestingEmbedding = true
        statusMessage = nil
        defer { isTestingEmbedding = false }
        do {
            let vectors = try await EmbeddingClient.embed(texts: ["夜奔知识库混合检索连通测试"], config: config)
            let dim = vectors.first?.count ?? 0
            statusIsError = false
            statusMessage = String(localized: "向量接口测试成功：\(config.providerName) · \(config.modelID)（\(dim) 维）。")
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func indexBookshelfVectors() async {
        let config = authorizedEmbedding
        let snapshots = volumes.map {
            KnowledgeDocumentSnapshot(id: $0.id, title: $0.title, manuscript: $0.manuscript)
        }
        guard !snapshots.isEmpty else { return }

        isIndexingVectors = true
        statusMessage = nil
        defer {
            isIndexingVectors = false
            vectorProgressText = nil
        }

        var totalChunks = 0
        do {
            for (idx, snap) in snapshots.enumerated() {
                vectorProgressText = String(localized: "正在索引（\(idx + 1)/\(snapshots.count)）：\(snap.title)")
                totalChunks += try await ProjectKnowledgeSearch.shared.indexVolumeWithEmbeddings(
                    document: snap,
                    config: config
                )
            }
            await refreshStats()
            statusIsError = false
            statusMessage = String(localized: "已完成 \(snapshots.count) 本书架文档的持久化混合索引（共 \(totalChunks) 个切片向量）。")
        } catch {
            await refreshStats()
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func clearVectors() async {
        do {
            try await FullTextSearchIndex.shared.clearAllRAGEmbeddings()
            await refreshStats()
            statusIsError = false
            statusMessage = String(localized: "已清除全部文档向量缓存。")
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
