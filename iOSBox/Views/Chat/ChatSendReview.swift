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
    let send: () -> Void

    struct InputEstimate: Identifiable {
        let id: String
        let name: String
        let cost: String?
    }
}

struct ChatSendReviewSheet: View {
    let review: ChatSendReview
    let confirm: () -> Void
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
                            LabeledContent("个人记忆", value: String(review.memoryCount))
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
                        ForEach(review.inputEstimates) { estimate in
                            LabeledContent(estimate.name, value: estimate.cost ?? String(localized: "输入价格未知"))
                        }
                    } header: {
                        Text("请求数与输入费用估算")
                    } footer: {
                        Text("仅估算首轮回答的输入费用。检索结果、输出、标题、重试及联网费用按实际用量计费。")
                    }
                }
            }
            .navigationTitle("发送前确认")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("发送", action: confirm) }
            }
        }
    }
}
