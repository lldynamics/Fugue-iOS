import SwiftData
import SwiftUI

/// Whisper-quiet vertical chapter tick rail along the trailing edge of long conversations.
/// Dragging or tapping jumps instantaneously across user prompt milestones.
struct ChatTopicScrubberView: View {
    struct PromptMilestone: Identifiable {
        let id: UUID
        let index: Int
        let preview: String

        static func questions(in messages: [ChatMessage]) -> [Self] {
            let questions = messages.filter { $0.role == .user && !$0.assistanceMetadata.isContextDivider }
            return questions.enumerated().map { index, item in
                var preview = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if preview.isEmpty { preview = item.attachments.map(\.fileName).joined(separator: ", ") }
                if preview.isEmpty { preview = item.assistanceMetadata.quotedExcerpt ?? "" }
                return Self(id: item.id, index: index, preview: String(preview.prefix(160)))
            }
        }
    }

    let milestones: [PromptMilestone]
    let openDirectory: () -> Void
    let onSelectMilestone: (UUID) -> Void

    @State private var activeIndex: Int?
    @State private var preferences = AppPreferences.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var displayedMilestones: [PromptMilestone] {
        guard milestones.count > 18 else { return milestones }
        let strideStep = max(1, Int(ceil(Double(milestones.count) / 18.0)))
        var sampled: [PromptMilestone] = []
        for idx in stride(from: 0, to: milestones.count, by: strideStep) {
            sampled.append(milestones[idx])
        }
        if sampled.last?.id != milestones.last?.id, let last = milestones.last {
            sampled.append(last)
        }
        return sampled
    }

    var body: some View {
        let items = displayedMilestones
        if items.count >= 3 {
            HStack(spacing: DS.Spacing.sm) {
                if let activeIndex, items.indices.contains(activeIndex) {
                    let hit = items[activeIndex]
                    HStack(spacing: 6) {
                        Text("第 \(hit.index + 1) 问")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(theme.readableText)
                        Text(hit.preview)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 230, alignment: .leading)
                    .dsFloatingIsland(cornerRadius: DS.Radius.pill)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .trailing)))
                }

                GeometryReader { geo in
                    VStack(spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, _ in
                            let isCurrent = activeIndex == idx
                            Capsule()
                                .fill(isCurrent ? theme.solidFill : Color.secondary.opacity(0.32))
                                .frame(width: isCurrent ? 13 : 7, height: isCurrent ? 3 : 2)
                                .animation(.snappy(duration: 0.16), value: isCurrent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 5)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let height = max(geo.size.height, 1)
                                let ratio = min(max(value.location.y / height, 0), 0.999)
                                let targetIdx = Int(ratio * CGFloat(items.count))
                                if activeIndex != targetIdx, items.indices.contains(targetIdx) {
                                    activeIndex = targetIdx
                                    preferences.triggerSelectionHaptic()
                                    onSelectMilestone(items[targetIdx].id)
                                }
                            }
                            .onEnded { _ in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    activeIndex = nil
                                }
                            }
                    )
                }
                .frame(width: 24, height: CGFloat(items.count) * 10 + 16)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("问题目录")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openDirectory() }
        }
    }
}


struct QuestionDirectorySheet: View {
    let conversation: Conversation
    let jump: (UUID) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOther: ChatTopicScrubberView.PromptMilestone?
    @State private var error: String?

    var body: some View {
        let active = ChatTopicScrubberView.PromptMilestone.questions(in: ConversationTree.activeMessages(in: conversation))
        let activeIDs = Set(active.map(\.id))
        let others = ChatTopicScrubberView.PromptMilestone.questions(in: conversation.sortedMessages.filter { !activeIDs.contains($0.id) })
        let siblings = ConversationTree.branchSiblingsMap(in: conversation)
        NavigationStack {
            List {
                Section("当前分支") {
                    ForEach(active) { question in
                        Button {
                            dismiss()
                            jump(question.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("第 \(question.index + 1) 问").font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: question.preview)
                                if let variants = siblings[question.id], variants.count > 1 {
                                    Label("\(variants.count) 个分支", systemImage: "arrow.triangle.branch")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    Section("其他分支") {
                        ForEach(others) { question in
                            Button { selectedOther = question } label: { Text(verbatim: question.preview) }
                                .disabled(ChatEngine.shared.isGenerating(in: conversation.id))
                        }
                    }
                }
            }
            .navigationTitle("问题目录")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("切换至这个问题所在的分支？", isPresented: Binding(get: { selectedOther != nil },
                                 set: { if !$0 { selectedOther = nil } }), presenting: selectedOther) { question in
                Button("切换分支并定位") {
                    guard !ChatEngine.shared.isGenerating(in: conversation.id),
                          let message = conversation.messages.first(where: { $0.id == question.id }) else { return }
                    let previous = conversation.activeLeafMessageID
                    ConversationTree.switchBranch(to: message, in: conversation)
                    do { try context.save(); dismiss(); jump(message.id) }
                    catch { conversation.activeLeafMessageID = previous; self.error = error.localizedDescription }
                }
            }
            .alert("无法更新对话记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { }
            } message: { Text(error ?? "") }
        }
    }
}
