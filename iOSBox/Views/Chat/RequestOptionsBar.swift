import SwiftUI
import SwiftData

struct BoundKnowledgeMenu: View {
    let ids: [UUID]
    @Binding var omitted: Bool
    let compact: Bool
    let canManage: Bool
    let onManage: (() -> Void)?
    @Query private var books: [BookVolume]

    var body: some View {
        let titles = ids.map { id in books.first { $0.id == id }?.title ?? String(localized: "书籍不可用") }
        Menu {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in Text(verbatim: title) }
            Divider()
            Toggle("本次不使用知识库", isOn: $omitted)
            if let onManage {
                Button(action: onManage) { Label("管理参考资料", systemImage: "books.vertical") }
                    .disabled(!canManage)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: omitted ? "books.vertical" : "books.vertical.fill")
                if compact {
                    if omitted { Image(systemName: "minus.circle") }
                    else { Text(ids.count, format: .number) }
                } else {
                    Text(verbatim: omitted ? String(localized: "本次已关闭知识库") : titles.first ?? "")
                        .lineLimit(1).truncationMode(.tail)
                    if !omitted, titles.count > 1 { Text(verbatim: "+\(titles.count - 1)").fixedSize() }
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(omitted ? Color.secondary : Color.primary)
            .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(omitted ? String(localized: "本次已关闭知识库") : String(localized: "本次知识库：\(titles.joined(separator: "、"))"))
        .accessibilityIdentifier("composer.knowledge")
    }
}

struct ComposerOptionsSheet: View {
    @Bindable var conversation: Conversation
    @Binding var options: ComposerRequestOptions
    let targets: [ResolvedModelTarget]
    let onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var canSelectTemporaryTarget: Bool {
        !conversation.isArenaMode && !conversation.isGroupMode && !targets.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty ||
                    conversation.assistanceSettings.usePersonalMemory || canSelectTemporaryTarget {
                    Section("仅本条消息") {
                        if !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty {
                            Toggle("本次不使用知识库", isOn: $options.omitKnowledge)
                        }
                        if conversation.assistanceSettings.usePersonalMemory {
                            Toggle("本次不使用记忆", isOn: $options.omitMemory)
                        }
                        if canSelectTemporaryTarget {
                            Picker("本次临时指定模型", selection: $options.temporaryTarget) {
                                Text("恢复默认模型").tag(ResolvedModelTarget?.none)
                                ForEach(targets) { target in
                                    Text("\(target.providerName) · \(target.modelDisplayName)").tag(Optional(target))
                                }
                            }
                        }
                    }
                }
                Section("本会话") {
                    if !conversation.isGroupMode {
                        Toggle(
                            "服务商原生联网 (Gemini / Claude / OpenAI)",
                            isOn: Binding(
                                get: { conversation.assistanceSettings.enableNativeGrounding },
                                set: { conversation.assistanceSettings.enableNativeGrounding = $0 }
                            )
                        )
                    }
                    if !conversation.isGroupMode && !conversation.isArenaMode {
                        Toggle("本会话允许工具", isOn: Binding(get: { conversation.assistanceSettings.enableAgentTools },
                                                         set: { conversation.assistanceSettings.enableAgentTools = $0 }))
                        if conversation.assistanceSettings.enableNativeGrounding && conversation.assistanceSettings.enableAgentTools {
                            Text("同时开启时，Gemini 将优先使用自定义工具，Anthropic 若已配置 Tavily 将优先使用 Tavily 搜索。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if conversation.isArenaMode {
                        Button("退出对比") { conversation.isArenaMode = false }
                    }
                    Button("系统提示词与参数", action: onOpenSettings)
                }
            }
            .navigationTitle("发送选项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

struct AssistanceEvidenceView: View {
    let metadata: AssistanceMetadata
    var message: ChatMessage? = nil
    var showsKnowledge = true
    @Environment(\.modelContext) private var modelContext
    @State private var memoryLimitError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if metadata.memoryCount > 0 {
                Text("已使用 \(metadata.memoryCount) 条个人记忆").font(.caption2).foregroundStyle(.secondary)
            }
            if let notice = metadata.routeNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(metadata.fallbackNotices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "arrow.triangle.branch").font(.caption2).foregroundStyle(DS.StatusText.warning)
            }
            if !metadata.toolCalls.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(metadata.toolCalls) { call in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: call.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(call.succeeded ? .green : .orange)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(call.name)
                                        .font(.caption.monospaced().weight(.semibold))
                                    if !call.argumentsSummary.isEmpty {
                                        Text(call.argumentsSummary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if !call.resultSummary.isEmpty {
                                        Text(call.resultSummary)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label("工具调用 · \(metadata.toolCalls.count)", systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                }
            }
            if let search = metadata.search {
                DisclosureGroup {
                    Text(search.query).font(.caption).textSelection(.enabled)
                    Text(search.searchedAt, format: .dateTime).font(.caption2).foregroundStyle(.secondary)
                    ForEach(search.sources) { source in
                        if (try? URLReader.validate(source.url)) != nil {
                            Link(destination: source.url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(source.id)] \(source.title)").font(.caption)
                                    Text(source.url.host ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let credits = search.credits {
                        Text("搜索额度：\(credits.formatted()) credits").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("来源为搜索服务返回的摘要，并不代表已独立核实。")
                        .font(.caption2).foregroundStyle(.secondary)
                } label: {
                    Label("网页来源 · \(search.sources.count)", systemImage: "globe").font(.caption)
                }
            }

            if showsKnowledge, let kb = metadata.knowledgeEvidence, !kb.passages.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(kb.passages) { passage in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(passage.id)] \(passage.citationLabel)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.teal)
                                Text(verbatim: passage.excerpt)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Label("找到 \(kb.passages.count) 段相关原文", systemImage: "books.vertical.fill")
                        .font(.caption)
                        .foregroundStyle(.teal)
                }
            } else if metadata.knowledgeEvidence?.passages.isEmpty == true {
                Label("未找到相关原文", systemImage: "books.vertical")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let message, !metadata.proposedMemories.isEmpty {
                ForEach(metadata.proposedMemories, id: \.self) { fact in
                    VStack(alignment: .leading, spacing: 6) {
                        Label("记忆建议", systemImage: "brain.head.profile")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple)
                        Text(fact)
                            .font(.caption)
                            .foregroundStyle(.primary)
                        HStack(spacing: 8) {
                            Button("存入记忆") {
                                if !ChatEngine.shared.acceptMemoryProposal(fact, on: message, context: modelContext) {
                                    memoryLimitError = String(localized: "个人长期记忆已达到上限（\(PersonalMemory.maximumCount) 条），请先在「设置 → 个人长期记忆」清理后再保存。")
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)

                            Button("忽略") {
                                ChatEngine.shared.dismissMemoryProposal(fact, on: message, context: modelContext)
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .alert("记忆容量已满", isPresented: Binding(get: { memoryLimitError != nil }, set: { if !$0 { memoryLimitError = nil } })) {
            Button("好", role: .cancel) { memoryLimitError = nil }
        } message: {
            Text(verbatim: memoryLimitError ?? "")
        }
    }
}
