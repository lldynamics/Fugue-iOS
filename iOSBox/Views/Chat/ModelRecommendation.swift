import SwiftData
import SwiftUI

struct ModelRecommendation: View {
    let providers: [ProviderConfig]
    let conversation: Conversation
    let draft: String
    let attachments: [MessageAttachment]
    let choose: (ResolvedModelTarget) -> Void
    @Environment(\.modelContext) private var context
    @State private var preference = "速度优先"
    @State private var currency = "CNY"
    @State private var budget = ""
    @State private var requirement = "全部"
    @State private var recent: [RequestRecord] = []
    @State private var open = false
    private struct Candidate: Identifiable {
        let id: String
        let model: TaskModel
        let ms: Double?
        let count: Int
        let estimate: Double?
    }
    var body: some View {
        DisclosureGroup("按任务推荐模型", isExpanded: $open) {
            Picker("用途", selection: $requirement) {
                Text("全部").tag("全部")
                ForEach(CapabilityProbe.allCases) { probe in Text(probe.title).tag(probe.rawValue) }
            }
            Picker("偏好", selection: $preference) { Text("速度优先").tag("速度优先"); Text("省钱优先").tag("省钱优先") }
            Picker("预算币种", selection: $currency) { ForEach(RequestRecord.currencies, id: \.self) { Text($0) } }
            TextField("本次预算（可选）", text: $budget).keyboardType(.decimalPad)
            Text("费用按预计输入和 1,000 个输出 Token 估算。速度取最近成功请求的首字中位数。").font(.caption)
            if open {
                let ranked = candidates()
                if ranked.isEmpty { Text("当前没有满足所选条件的模型") }
                ForEach(ranked.prefix(4)) { item in
                    Button {
                        choose(item.model.provider.makeTarget(for: item.model.spec))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.model.recipient)
                            let price = item.estimate.map { RequestLedger.costText($0, currency: currency) } ?? "所选币种费用未知"
                            let speed = item.ms.map { "\(Int($0)) ms（\(item.count) 次）" } ?? "速度样本不足"
                            Text(price + " · " + speed).font(.caption)
                        }
                    }
                }
            }
        }.task(id: open) {
            guard open else { return }
            var descriptor = FetchDescriptor<RequestRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
            descriptor.fetchLimit = 500
            recent = (try? context.fetch(descriptor)) ?? []
        }.onAppear {
            if attachments.contains(where: { $0.mimeType == "application/pdf" }) { requirement = CapabilityProbe.pdf.rawValue }
            else if attachments.contains(where: { $0.kind == .image }) { requirement = CapabilityProbe.image.rawValue }
        }
    }
    private func candidates() -> [Candidate] {
        let maxCost = Double(budget.replacingOccurrences(of: ",", with: "."))
        let estimate = TokenEstimator.estimateUpcomingInput(conversation: conversation, providers: providers, draftText: draft, attachments: attachments, quotedText: nil, target: nil).inputTokens
        return TaskModel.options(providers).compactMap { model -> Candidate? in
            if let probe = CapabilityProbe(rawValue: requirement), probe.result(model)?.passed != true { return nil }
            let times = recent.filter { $0.providerID == model.provider.id && $0.modelID == model.spec.id && $0.status == .succeeded }.compactMap { $0.firstContentMs.map(Double.init) }
            let rates = ModelPricingDisplay.configuredRates(for: model.spec)
            let price = rates.flatMap { $0.currency == currency ? ($0.input * Double(estimate) + $0.output * 1000) / 1_000_000 : nil }
            if !budget.isEmpty, !(price.map { $0 <= (maxCost ?? -1) } ?? false) { return nil }
            return Candidate(id: model.id, model: model, ms: RequestLedger.median(times), count: times.count, estimate: price)
        }.sorted {
            let a = preference == "速度优先" ? $0.ms : $0.estimate
            let b = preference == "速度优先" ? $1.ms : $1.estimate
            return a == b ? $0.model.recipient < $1.model.recipient : (a ?? .infinity) < (b ?? .infinity)
        }
    }
}
