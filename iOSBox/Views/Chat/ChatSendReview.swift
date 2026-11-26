import SwiftUI

struct ChatSendReview: Identifiable {
    let id = UUID()
    let answerRecipients: [String]
    let titleRecipient: String?
    let attachmentCount: Int
    let memoryCount: Int
    let knowledgeCount: Int
    let searchRecipient: String?
    let searchQuery: String?
    let requestCount: String?
    let inputEstimates: [InputEstimate]
    var budgetNotice: String?
    var adjustModels: (() -> Void)?
    var memories: [MemoryItem] = []
    let send: (Set<UUID>?) -> Void

    struct MemoryItem: Identifiable {
        let id: UUID
        let content: String
    }

    struct InputEstimate: Identifiable {
        let id: String
        let name: String
        let cost: String?
    }
}

struct ChatSendReviewSheet: View {
    let review: ChatSendReview
    let confirm: (Set<UUID>?) -> Void
    @State private var excluded = Set<UUID>()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("回答模型与可能用到的备用模型") {
                    ForEach(review.answerRecipients, id: \.self) { Text($0) }
                    if let recipient = review.titleRecipient {
                        LabeledContent("生成标题的模型", value: recipient)
                    }
                }
                if review.attachmentCount > 0 || review.memoryCount > 0 || review.knowledgeCount > 0 {
                    Section("随对话请求发送") {
                        if review.attachmentCount > 0 {
                            LabeledContent("本条附件", value: String(review.attachmentCount))
                        }
                        if review.memoryCount > 0 {
                            DisclosureGroup {
                                ForEach(review.memories) { item in
                                    Toggle(item.content, isOn: Binding(get: { !excluded.contains(item.id) }, set: { included in
                                        if included { excluded.remove(item.id) } else { excluded.insert(item.id) }
                                    }))
                                }
                            } label: {
                                LabeledContent("个人记忆", value: String(review.memories.count - excluded.count))
                            }
                        }
                        if review.knowledgeCount > 0 {
                            LabeledContent("检索相关片段的资料", value: String(review.knowledgeCount))
                        }
                    }
                }
                if let search = review.searchRecipient {
                    Section("联网搜索") {
                        LabeledContent("搜索数据接收方", value: search)
                        if let query = review.searchQuery { Text(query).foregroundStyle(.secondary) }
                    }
                }
                if let count = review.requestCount {
                    Section {
                        LabeledContent("预计请求", value: count)
                        if let budgetNotice = review.budgetNotice {
                            Text(verbatim: budgetNotice).font(.subheadline.weight(.medium))
                                .accessibilityIdentifier("sendReview.budget")
                            if let adjustModels = review.adjustModels {
                                Button("调整参与模型或发言设置", action: adjustModels)
                            }
                        }
                        ForEach(review.inputEstimates) { estimate in
                            LabeledContent(estimate.name, value: estimate.cost ?? String(localized: "输入价格未知"))
                        }
                    } header: {
                        Text("请求数与输入费用估算")
                    } footer: {
                        Text("仅估算已安排发言的输入费用。后续接力、检索结果、输出、标题、重试及联网费用按实际用量计费。")
                    }
                }
            }
            .navigationTitle("发送前确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { confirm(Set(review.memories.map(\.id)).subtracting(excluded)) }
                }
            }
        }
    }
}
