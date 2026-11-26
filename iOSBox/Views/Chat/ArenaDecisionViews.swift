import SwiftData
import SwiftUI

struct ArenaDecisionEditor: View {
    let entry: ArenaDecision
    let message: ChatMessage
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var tags: String
    @State private var reason: String
    @State private var issue: String?

    init(entry: ArenaDecision, message: ChatMessage) {
        self.entry = entry
        self.message = message
        _tags = State(initialValue: entry.tags.joined(separator: "，"))
        _reason = State(initialValue: entry.reason)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !entry.question.isEmpty { Section("提问") { Text(verbatim: entry.question) } }
                Section("采纳理由") {
                    TextField("为什么选择这条回答？", text: $reason, axis: .vertical).lineLimit(3...10)
                    TextField("标签，以逗号分隔", text: $tags)
                }
                ArenaDecisionAnswers(entry: entry)
                if let issue { Text(verbatim: issue).foregroundStyle(.red) }
            }
            .navigationTitle("记录采纳理由")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try entry.save(tags: ArenaDecision.tags(from: tags), reason: reason, to: message, in: context); dismiss() }
                        catch { issue = error.localizedDescription }
                    }
                    .disabled(ArenaDecision.tags(from: tags).isEmpty && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ArenaDecisionAnswers: View {
    let entry: ArenaDecision
    var body: some View {
        Section("当时的回答") {
            ForEach(entry.answers) { answer in
                DisclosureGroup {
                    if !answer.content.isEmpty { Text(verbatim: answer.content).textSelection(.enabled) }
                    ForEach(answer.attachments) { attachment in
                        if let image = attachment.cachedImage { Image(uiImage: image).resizable().scaledToFit() }
                        else { Text(verbatim: attachment.extractedText ?? attachment.fileName).textSelection(.enabled) }
                    }
                    if let issue = answer.issue { Text(verbatim: issue).foregroundStyle(.secondary) }
                    if let time = answer.elapsedMs { LabeledContent("耗时", value: "\(time) ms") }
                    if let speed = answer.tokensPerSecond { LabeledContent("输出速度", value: String(format: "%.1f tok/s", speed)) }
                    if let cost = answer.estimatedCost, let currency = answer.currency {
                        LabeledContent("估算费用", value: RequestLedger.costText(cost, currency: currency))
                    }
                } label: {
                    VStack(alignment: .leading) {
                        if entry.selectedID == answer.id {
                            Label { Text(verbatim: answer.model) } icon: { Image(systemName: "checkmark.circle.fill") }
                                .accessibilityValue("已采纳")
                        } else { Text(verbatim: answer.model) }
                        Text(verbatim: answer.provider).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ArenaDecisionLibrary: View {
    @Query(filter: #Predicate<ChatMessage> { $0.comparisonGroupID != nil && $0.assistanceMetadataData != nil })
    private var comparisonMessages: [ChatMessage]
    @State private var query = ""

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = comparisonMessages.flatMap { $0.assistanceMetadata.arenaDecisions ?? [] }.filter { item in
            item.isDeleted != true && (term.isEmpty || item.tags.contains(where: { $0.localizedStandardContains(term) }) ||
                item.question.localizedStandardContains(term) || item.reason.localizedStandardContains(term))
        }.sorted { $0.updatedTimestamp > $1.updatedTimestamp }
        List {
            if entries.isEmpty {
                if term.isEmpty {
                    ContentUnavailableView("暂无采纳记录", systemImage: "checkmark.bubble",
                        description: Text("在多模型对比的主回复下记录采纳理由，即可在这里回看当时的回答。"))
                } else { ContentUnavailableView.search(text: term) }
            }
            ForEach(entries) { entry in
                NavigationLink {
                    if let message = comparisonMessages.first(where: { $0.id == entry.selectedID }) {
                        ArenaDecisionDetail(message: message, decisionID: entry.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: entry.question.isEmpty ? entry.answers.first(where: { $0.id == entry.selectedID })?.model ?? "" : entry.question)
                            .lineLimit(2).font(.headline)
                        if !entry.reason.isEmpty { Text(verbatim: entry.reason).lineLimit(2) }
                        if !entry.tags.isEmpty { Text(verbatim: entry.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜索标签、提问或采纳理由")
        .navigationTitle("模型对比记录")
    }
}

private struct ArenaDecisionDetail: View {
    let message: ChatMessage
    let decisionID: UUID
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ArenaDecision?
    @State private var deleting: ArenaDecision?
    @State private var issue: String?

    var body: some View {
        List {
            if let entry = message.assistanceMetadata.arenaDecisions?.first(where: { $0.id == decisionID && $0.isDeleted != true }) {
                if !entry.question.isEmpty { Section("提问") { Text(verbatim: entry.question).textSelection(.enabled) } }
                Section("采纳理由") {
                    if !entry.reason.isEmpty { Text(verbatim: entry.reason).textSelection(.enabled) }
                    if !entry.tags.isEmpty { Text(verbatim: entry.tags.joined(separator: " · ")).foregroundStyle(.secondary) }
                    Button("编辑") { editing = entry }
                }
                ArenaDecisionAnswers(entry: entry)
                Section { Button("删除采纳记录", role: .destructive) { deleting = entry } }
            }
            if let issue { Text(verbatim: issue).foregroundStyle(.red) }
        }
        .navigationTitle("采纳记录")
        .sheet(item: $editing) { entry in ArenaDecisionEditor(entry: entry, message: message) }
        .confirmationDialog("删除这条采纳记录？",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { entry in
                Button("删除", role: .destructive) {
                    do { try entry.delete(from: message, in: context); dismiss() } catch { issue = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            }
    }
}
