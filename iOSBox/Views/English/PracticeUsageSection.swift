import SwiftData
import SwiftUI

struct PracticeUsageSection: View {
    let chat: Conversation
    @Query private var records: [RequestRecord]

    init(chat: Conversation) {
        self.chat = chat
        let id = chat.id
        _records = Query(filter: #Predicate<RequestRecord> { $0.conversationID == id }, sort: \.startedAt)
    }

    var body: some View {
        if let lesson = chat.assistanceSettings.voicePractice {
            let stages: [RequestKind] = [.practiceVoice, .practiceTranscription, .practiceReview]
            let billed = records.filter { stages.contains($0.kind) }
            Section("本课用量") {
                LabeledContent("实际通话时长", value: lesson.callSeconds.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? String(localized: "未知"))
                if let name = billed.first?.providerName { LabeledContent("陪练账号", value: name) }
                let costs = RequestLedger.costs(billed)
                let unknown = billed.contains { $0.estimatedCost == nil } || lesson.realtimeModelID == nil
                LabeledContent(unknown ? "已知部分估算" : "本课预估费用", value: costs.isEmpty ? String(localized: "未知") :
                    costs.keys.sorted().compactMap { key in costs[key].map { RequestLedger.costText($0, currency: key) } }.joined(separator: " + "))
                ForEach(stages, id: \.rawValue) { kind in
                    let rows = billed.filter { $0.kind == kind }
                    DisclosureGroup(kind.title) {
                        if rows.isEmpty {
                            Text(kind == .practiceReview && !lesson.reviewed ? "尚未生成复盘" : "没有已记录的用量").foregroundStyle(.secondary)
                        } else {
                            Text(Set(rows.map(\.modelID)).sorted().joined(separator: " · ")).font(.caption)
                            let inputTotal = total(rows.compactMap(\.promptTokens))
                            LabeledContent("已返回输入 Token", value: inputTotal)
                                .accessibilityElement(children: .ignore).accessibilityLabel("已返回输入 Token")
                                .accessibilityValue(inputTotal).accessibilityIdentifier("practice.usage.input." + kind.rawValue)
                            LabeledContent("已返回输出 Token", value: total(rows.compactMap(\.completionTokens)))
                            if kind.usesAudioPricing {
                                let meters = rows.compactMap(\.practiceMeter)
                                let input = meters.compactMap(\.audioInput), output = meters.compactMap(\.audioOutput)
                                if !input.isEmpty { LabeledContent("其中音频输入 Token", value: total(input)) }
                                if kind == .practiceVoice, !output.isEmpty { LabeledContent("其中音频输出 Token", value: total(output)) }
                                let seconds = meters.compactMap(\.seconds)
                                if !seconds.isEmpty { LabeledContent("转写时长", value: Duration.seconds(seconds.reduce(0, +)).formatted()) }
                            }
                            let costs = RequestLedger.costs(rows)
                            if costs.isEmpty { LabeledContent("预估费用", value: String(localized: "未知")) }
                            ForEach(costs.keys.sorted(), id: \.self) { key in
                                LabeledContent("已知部分估算", value: RequestLedger.costText(costs[key] ?? 0, currency: key))
                            }
                            if rows.contains(where: { $0.estimatedCost == nil }) {
                                Text("部分请求缺少用量或对应单价。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.accessibilityIdentifier("practice.usage." + kind.rawValue)
                }
            }
        }
    }

    private func total(_ counts: [Int]) -> String {
        counts.isEmpty ? String(localized: "未返回") : counts.reduce(0, LLMUsage.saturatedSum).formatted()
    }
}
