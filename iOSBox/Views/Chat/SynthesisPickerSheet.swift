import SwiftUI
import SwiftData

struct SynthesisPickerSheet: View {
    let conversation: Conversation
    let groupID: UUID
    let providers: [ProviderConfig]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var consent = AIConsentGate()
    @State private var selectedID: String?
    @State private var search = ""
    @State private var error: String?

    private var targets: [ResolvedModelTarget] { ChatEngine.shared.availableTargets(from: providers) }
    private var eligible: Int {
        ArenaSynthesis.eligibleSources(in: ConversationTree.activeMessages(in: conversation), groupID: groupID).count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let selected = targets.first(where: { $0.id == selectedID }) {
                        LabeledContent("裁判模型", value: selected.modelDisplayName)
                        LabeledContent("服务商", value: selected.providerName)
                    }
                    Text("将原问题、相关上下文及 \(eligible) 条完整答案发送给所选裁判，产生一次额外请求。失败、取消和截断的答案不参与。")
                        .font(.footnote)
                    Text("汇总会列出共识、分歧和待核实项。模型意见一致不代表事实已经核实。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(DS.StatusText.error) }
                ForEach(providers.filter(\.isReadyForChat)) { provider in
                    let models = provider.enabledModels.filter {
                        search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
                    }
                    if !models.isEmpty {
                        Section(provider.name) {
                            ForEach(models) { spec in
                                let target = provider.makeTarget(for: spec)
                                Button {
                                    selectedID = target.id
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(spec.displayName).foregroundStyle(.primary)
                                            Text(spec.id).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedID == target.id { Image(systemName: "checkmark.circle.fill") }
                                    }
                                }
                            }
                        }
                    }
                }
                if targets.isEmpty { Text("暂无已启用的模型") }
            }
            .searchable(text: $search, prompt: "搜索模型名称或 ID")
            .navigationTitle("选择裁判模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始汇总") { start() }
                        .disabled(selectedID == nil || eligible < 2 || ChatEngine.shared.isGenerating(in: conversation.id))
                }
            }
            .aiConsentSheet(consent)
            .onAppear { selectedID = targets.first { $0.id == conversation.primaryTarget?.id }?.id ?? targets.first?.id }
        }
    }

    private func start() {
        guard let target = targets.first(where: { $0.id == selectedID }) else { return }
        let provider = providers.first { $0.id == target.providerID }
        let recipient = AppCompliance.recipient(provider: provider?.name ?? target.providerName,
                                                model: target.modelDisplayName, baseURL: provider?.baseURL ?? "")
        consent.perform(recipients: [recipient]) { synthesize(target) }
    }

    private func synthesize(_ target: ResolvedModelTarget) {
        let result = ChatEngine.shared.synthesize(groupID: groupID, target: target,
                                                 in: conversation, providers: providers, context: context)
        switch result {
        case .started: dismiss()
        case .busy: error = String(localized: "请等待当前生成结束后重试。")
        case .insufficientAnswers: error = String(localized: "至少需要两条完整答案才能汇总。")
        case .unavailableModel: error = String(localized: "模型已被删除或停用，请重新选择。")
        case .missingQuestion: error = String(localized: "未找到原始问题，无法汇总。")
        }
    }
}
