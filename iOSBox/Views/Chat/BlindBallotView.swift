import SwiftUI

struct BlindRound: Identifiable {
    let id: UUID
}

struct BlindBallotView: View {
    let groupID: UUID
    let messages: [ChatMessage]
    let isGenerating: Bool
    let initialAnswer: UUID?
    let vote: (ChatMessage) throws -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var questionSize: CGFloat = 43
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedID: UUID?
    @State private var visibleID: UUID?
    @State private var openedIDs: Set<UUID> = []
    @State private var error: String?

    private var candidates: [ChatMessage] {
        ArenaSynthesis.blindDisplayOrder(for: ArenaSynthesis.sources(in: messages, groupID: groupID), groupID: groupID)
    }

    private var question: ChatMessage? {
        guard let first = messages.firstIndex(where: { $0.comparisonGroupID == groupID }) else { return nil }
        let parent = messages[first].parentMessageID
        return messages[..<first].last { $0.role == .user && $0.id == parent }
            ?? messages[..<first].last { $0.role == .user }
    }

    private var revealed: Bool { candidates.contains { $0.assistanceMetadata.blindArenaRevealed } }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 720 && !typeSize.isAccessibilitySize
                let pool = candidates
                ScrollView {
                    VStack(spacing: wide ? 32 : 20) {
                        if let question {
                            if !question.content.isEmpty {
                                Text(verbatim: question.content)
                                    .font(wide ? .system(size: questionSize, weight: .bold) : .title2.bold())
                                    .multilineTextAlignment(.center)
                                    .textSelection(.enabled)
                            } else {
                                Label("附件消息", systemImage: "paperclip").font(.title2)
                            }
                        }
                        Text(revealed ? "已揭晓模型" : "投票后揭晓模型")
                            .foregroundStyle(.secondary)
                        if wide {
                            VStack(spacing: 0) {
                                ForEach(Array(stride(from: 0, to: pool.count, by: 2)), id: \.self) { i in
                                    if i > 0 { Divider() }
                                    HStack(alignment: .top, spacing: 0) {
                                        answer(pool[i], index: i, wide: true)
                                        Divider()
                                        if i + 1 < pool.count { answer(pool[i + 1], index: i + 1, wide: true) }
                                        else { Color.clear.frame(minWidth: 0, maxWidth: .infinity).frame(height: 1) }
                                    }
                                    .frame(minHeight: min(265, geometry.size.height * 0.33), alignment: .top)
                                }
                            }
                            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DS.Surface.hairline) }
                        } else if let first = pool.first {
                            let visible = pool.first { $0.id == visibleID } ?? first
                            Picker("查看回答", selection: Binding(get: { visible.id }, set: {
                                visibleID = $0
                                openedIDs.insert($0)
                            })) {
                                ForEach(Array(pool.enumerated()), id: \.element.id) { i, item in
                                    Text(verbatim: Self.letter(i)).tag(item.id)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("ballot.answers")
                            if !revealed {
                                let opened = pool.filter { openedIDs.contains($0.id) }.count
                                Group {
                                    if opened < pool.count {
                                        Text("已打开 \(opened)/\(pool.count) 个回答，建议先比较。")
                                    } else {
                                        Text("已打开 \(opened)/\(pool.count) 个回答。")
                                    }
                                }
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("ballot.opened")
                            }
                            if let index = pool.firstIndex(where: { $0.id == visible.id }) {
                                answer(visible, index: index, wide: false)
                                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DS.Surface.hairline) }
                            }
                        }
                    }
                    .padding(.horizontal, wide ? 40 : 16)
                    .padding(.vertical, wide ? min(82, max(32, geometry.size.height * 0.08)) : 16)
                    .frame(maxWidth: 1190)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !revealed {
                    let eligible = candidates.filter(ArenaSynthesis.isComplete)
                    let chosen = eligible.first { $0.id == selectedID }
                    VStack(spacing: 4) {
                        Group {
                            if isGenerating {
                                Text("等待回答完成后再投票。")
                            } else if eligible.count < 2 {
                                Text("至少需要两个完整回答才能投票。")
                            } else if chosen == nil {
                                Text("请选择一个回答后投票。")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Button {
                            guard let chosen else { return }
                            do { try vote(chosen) } catch { self.error = error.localizedDescription }
                        } label: {
                            Text("投票并揭晓").font(.headline).frame(minWidth: widthClass == .regular ? 300 : 180, minHeight: 36)
                        }
                        .disabled(isGenerating || eligible.count < 2 || chosen == nil)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("ballot.vote")
                    }
                    .padding()
                    .padding(.bottom, widthClass == .regular ? 30 : 0)
                }
            }
            .navigationTitle("双盲对比")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("对话", systemImage: "chevron.backward") }
                    .accessibilityIdentifier("ballot.close")
                }
            }
            .onAppear {
                visibleID = initialAnswer
                markVisibleAnswerOpened()
            }
            .onChange(of: candidates.map(\.id)) { _, _ in markVisibleAnswerOpened() }
            .alert("无法更新对话记录", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(verbatim: error ?? "") }
        }
    }

    private func markVisibleAnswerOpened() {
        if let answer = candidates.first(where: { $0.id == visibleID }) ?? candidates.first {
            openedIDs.insert(answer.id)
        }
    }

    private static func letter(_ index: Int) -> String {
        let letters = ["A", "B", "C", "D", "E", "F"]
        return letters.indices.contains(index) ? letters[index] : String(index + 1)
    }

    private func answer(_ message: ChatMessage, index: Int, wide: Bool) -> some View {
        let letter = Self.letter(index)
        let checked = revealed ? message.assistanceMetadata.blindArenaBallot != nil : selectedID == message.id
        return VStack(alignment: .leading, spacing: 16) {
            Button {
                selectedID = message.id
            } label: {
                HStack {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    Text("回答 \(letter)").font(wide ? .title.bold() : .title3.bold())
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked ? .isSelected : [])
            .accessibilityIdentifier("ballot.choose." + letter)
            .disabled(revealed || isGenerating || !ArenaSynthesis.isComplete(message))
            if revealed {
                Text(verbatim: "\(message.providerName) · \(message.modelDisplayName)")
                    .font(.subheadline.bold()).accessibilityIdentifier("ballot.identity." + letter)
            }
            if !message.content.isEmpty {
                MarkdownContentView(text: message.content, isStreaming: message.isStreaming, textScale: wide ? 1.4 : 1)
            }
            if message.isStreaming { ProgressView().accessibilityLabel("正在生成…") }
            else if !ArenaSynthesis.isComplete(message) {
                Text("此回答未完成").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }
}
