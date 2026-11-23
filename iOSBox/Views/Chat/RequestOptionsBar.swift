import SwiftUI
import SwiftData

struct RequestOptionsBar: View {
    @Bindable var conversation: Conversation
    let providers: [ProviderConfig]
    let text: String
    let attachments: [MessageAttachment]
    var quotedText: String? = nil
    let options: ComposerRequestOptions
    let onOpenOptions: () -> Void

    @State private var debouncedText: String = ""

    private var activeOptions: [String] {
        var labels: [String] = []
        if options.useSearch { labels.append(String(localized: "本次联网")) }
        if options.omitMemory && conversation.assistanceSettings.usePersonalMemory {
            labels.append(String(localized: "本次不使用记忆"))
        }
        if !conversation.isArenaMode && !conversation.isGroupMode && conversation.assistanceSettings.enableAgentTools {
            labels.append(String(localized: "本会话允许工具"))
        }
        return labels
    }

    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
            || (quotedText?.isEmpty == false)
    }

    private var effectiveTarget: ResolvedModelTarget? {
        if let target = options.forSend(in: conversation, quote: quotedText).overrideTarget { return target }
        guard let primary = conversation.primaryTarget else { return nil }
        if conversation.assistanceSettings.automaticRouting {
            return AssistancePolicy.route(
                primary: primary,
                settings: conversation.assistanceSettings,
                text: text,
                attachments: attachments,
                providers: providers
            ) ?? primary
        }
        return primary
    }

    var body: some View {
        let routedTarget: ResolvedModelTarget? = {
            guard !conversation.isArenaMode, !conversation.isGroupMode, options.temporaryTarget == nil,
                  conversation.assistanceSettings.automaticRouting,
                  let primary = conversation.primaryTarget else { return nil }
            return AssistancePolicy.route(
                primary: primary,
                settings: conversation.assistanceSettings,
                text: text,
                attachments: attachments,
                providers: providers
            )
        }()
        let routingUnavailable = !conversation.isArenaMode && !conversation.isGroupMode && options.temporaryTarget == nil
            && conversation.assistanceSettings.automaticRouting && conversation.primaryTarget != nil && routedTarget == nil
        let skippingMemory = options.omitMemory && conversation.assistanceSettings.usePersonalMemory
        let showBar = hasDraftContent || routedTarget != nil || routingUnavailable || skippingMemory

        if showBar {
            HStack(spacing: 8) {
                if skippingMemory {
                    Button(action: onOpenOptions) {
                        Text("本次不使用记忆")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                if routingUnavailable {
                    Text("路由模型不可用，请检查会话参数中的能力路由。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let target = routedTarget, target.id != conversation.primaryTarget?.id {
                    Text("本次模型：\(target.providerName) · \(target.modelDisplayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if hasDraftContent {
                    let textForEstimate = text.count <= 96 ? text : (debouncedText.isEmpty ? text : debouncedText)
                    let estimate = TokenEstimator.estimateUpcomingInput(
                        conversation: conversation,
                        providers: providers,
                        draftText: textForEstimate,
                        attachments: attachments,
                        quotedText: quotedText,
                        target: effectiveTarget,
                        omitMemory: skippingMemory, omitKnowledge: options.omitKnowledge
                    )
                    HStack(spacing: 4) {
                        Text("预估输入 ~\(estimate.inputTokens) tok")
                        if let cost = estimate.estimatedCostText {
                            Text("· 约 \(cost)")
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 5)
            .padding(.bottom, 2)
            .task(id: text) {
                if text.count <= 96 {
                    debouncedText = text
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled {
                    debouncedText = text
                }
            }
        }
    }
}

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
            .foregroundStyle(omitted ? Color.secondary : AppPreferences.shared.accentTheme.readableText)
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
    let draftText: String
    let targets: [ResolvedModelTarget]
    let onOpenArena: () -> Void
    let onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("仅本条消息") {
                    Toggle("联网搜索", isOn: Binding(get: { options.useSearch }, set: {
                        options.setSearch($0, draft: draftText)
                    }))
                    if options.useSearch {
                        TextField("搜索词（仅发送此内容给 Tavily）", text: $options.searchQuery, axis: .vertical)
                        Text("搜索词将发送给 Tavily；来源摘要将发送给回答模型。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !conversation.assistanceSettings.knowledgeVolumeIDs.isEmpty {
                        Toggle("本次不使用知识库", isOn: $options.omitKnowledge)
                    }
                    if conversation.assistanceSettings.usePersonalMemory {
                        Toggle("本次不使用记忆", isOn: $options.omitMemory)
                    }
                    if !conversation.isArenaMode && !conversation.isGroupMode && !targets.isEmpty {
                        Picker("本次临时指定模型", selection: $options.temporaryTarget) {
                            Text("恢复默认模型").tag(ResolvedModelTarget?.none)
                            ForEach(targets) { target in
                                Text("\(target.providerName) · \(target.modelDisplayName)").tag(Optional(target))
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
                    if !conversation.isGroupMode {
                        if conversation.isArenaMode {
                            Button("退出对比") { conversation.isArenaMode = false }
                        } else {
                            Button("多模型对比", action: onOpenArena)
                        }
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
    @State private var scheduleError: String?
    @State private var memoryLimitError: String?
    @State private var savedScheduleToast: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if metadata.memoryCount > 0 {
                Text("已使用 \(metadata.memoryCount) 条个人记忆").font(.caption2).foregroundStyle(.secondary)
            }
            if let notice = metadata.routeNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(metadata.fallbackNotices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "arrow.triangle.branch").font(.caption2).foregroundStyle(.orange)
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

            if let savedScheduleToast {
                Label(savedScheduleToast, systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }

            if let message, !metadata.proposedSchedules.isEmpty {
                ForEach(metadata.proposedSchedules) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Label(item.kind.badgeTitle, systemImage: item.kind.symbol)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.teal)
                            if let dt = item.scheduledAt {
                                Text(dt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !item.notes.isEmpty {
                            Text(item.notes)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Button(item.kind.confirmButtonTitle) {
                                Task { @MainActor in
                                    do {
                                        try await ChatEngine.shared.confirmScheduleProposal(item, on: message, context: modelContext)
                                        AppPreferences.shared.triggerLightHaptic()
                                        savedScheduleToast = item.kind == .reminder
                                            ? String(localized: "已加入系统提醒事项")
                                            : String(localized: "已写入系统日历")
                                    } catch {
                                        scheduleError = error.localizedDescription
                                    }
                                }
                            }
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                            .tint(.teal)
                            .controlSize(.mini)

                            Button("忽略") {
                                ChatEngine.shared.dismissScheduleProposal(item, on: message, context: modelContext)
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
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
                                    memoryLimitError = String(localized: "个人长期记忆已达到上限（\(PersonalMemory.maximumCount) 条），请先在「服务商 → 个人长期记忆」清理后再保存。")
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
        .alert("日程提示", isPresented: Binding(get: { scheduleError != nil }, set: { if !$0 { scheduleError = nil } })) {
            Button("好", role: .cancel) { scheduleError = nil }
        } message: {
            Text(verbatim: scheduleError ?? "")
        }
        .alert("记忆容量已满", isPresented: Binding(get: { memoryLimitError != nil }, set: { if !$0 { memoryLimitError = nil } })) {
            Button("好", role: .cancel) { memoryLimitError = nil }
        } message: {
            Text(verbatim: memoryLimitError ?? "")
        }
    }
}
