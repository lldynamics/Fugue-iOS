import SwiftUI

struct FlashcardReviewSheet: View {
    let initialCards: [StudyFlashcard]
    let sessionTitle: String
    var onJumpToConversation: ((UUID, UUID?) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var store = FlashcardStore.shared
    @State private var preferences = AppPreferences.shared

    @State private var queue: [StudyFlashcard] = []
    @State private var currentIndex = 0
    @State private var isFlipped = false
    @State private var showHint = false
    @State private var goodOrEasyCount = 0
    @State private var reviewedTotal = 0

    private var currentCard: StudyFlashcard? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let saveError { Text(verbatim: saveError).foregroundStyle(.red) }
                if let card = currentCard {
                    progressHeader(card: card)
                    flipCardStage(card: card)
                    ratingControls(card: card)
                } else {
                    completionSummary
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .navigationTitle(sessionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if let card = currentCard,
                   let convID = card.sourceConversationID,
                   let onJumpToConversation {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                            onJumpToConversation(convID, card.sourceMessageID)
                        } label: {
                            Label("原对话", systemImage: "bubble.left.and.bubble.right")
                                .font(.caption)
                        }
                    }
                }
            }
            .onAppear {
                if queue.isEmpty {
                    queue = initialCards
                }
            }
        }
    }

    private func progressHeader(card: StudyFlashcard) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(card.deckName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.12), in: Capsule())

                Spacer()

                Text("\(currentIndex + 1) / \(queue.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(currentIndex), total: Double(max(queue.count, 1)))
                .tint(.indigo)
        }
    }

    private func flipCardStage(card: StudyFlashcard) -> some View {
        ZStack {
            // Front Face
            VStack(alignment: .leading, spacing: 14) {
                Label("正面 · 回想问题", systemImage: "questionmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)

                Spacer(minLength: 6)

                ScrollView {
                    Text(card.front)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let hint = card.hint, !hint.isEmpty {
                    if showHint {
                        Text("💡 \(hint)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Button {
                            showHint = true
                        } label: {
                            Label("查看提示", systemImage: "lightbulb")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.indigo)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 6)

                HStack {
                    Spacer()
                    Label("轻点卡片翻转核对答案", systemImage: "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.indigo.opacity(0.22), lineWidth: 1.2)
            )
            .opacity(isFlipped ? 0 : 1)
            .accessibilityHidden(isFlipped)

            // Back Face (counter-rotated so text is upright after 180 deg flip)
            VStack(alignment: .leading, spacing: 14) {
                Label("背面 · 标准解析", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)

                Text(card.front)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Divider()

                ScrollView {
                    Text(card.back)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 4)

                HStack {
                    Spacer()
                    Text("请根据刚才的回想顺畅度选择下方间隔档位")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.teal.opacity(0.32), lineWidth: 1.2)
            )
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            .opacity(isFlipped ? 1 : 0)
            .accessibilityHidden(!isFlipped)
        }
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                isFlipped.toggle()
            }
            preferences.triggerSelectionHaptic()
        }
    }

    @ViewBuilder
    private func ratingControls(card: StudyFlashcard) -> some View {
        if isFlipped {
            HStack(spacing: 8) {
                ForEach(StudyReviewRating.allCases) { rating in
                    Button {
                        submitRating(rating, for: card)
                    } label: {
                        VStack(spacing: 3) {
                            Text(rating.title)
                                .font(.footnote.weight(.bold))
                            Text(card.nextIntervalLabel(for: rating))
                                .font(.caption2.monospacedDigit())
                                .opacity(0.85)
                        }
                        .foregroundStyle(ratingColor(rating))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(ratingColor(rating).opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    isFlipped = true
                }
                preferences.triggerSelectionHaptic()
            } label: {
                Text("显示答案")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.indigo, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var completionSummary: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)

            Text("完成本轮闪卡复习！")
                .font(.title3.weight(.bold))

            if reviewedTotal > 0 {
                let accuracy = Int((Double(goodOrEasyCount) / Double(reviewedTotal) * 100).rounded())
                Text("共巩固 \(reviewedTotal) 张卡片 · 顺畅掌握率 \(accuracy)%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .background(Color.indigo, in: Capsule())
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private func submitRating(_ rating: StudyReviewRating, for card: StudyFlashcard) {
        do { try store.recordReview(cardID: card.id, rating: rating) }
        catch { saveError = error.localizedDescription; return }
        saveError = nil
        reviewedTotal += 1
        if rating == .good || rating == .easy {
            goodOrEasyCount += 1
        }
        preferences.triggerLightHaptic()
        isFlipped = false
        showHint = false
        currentIndex += 1
    }

    private func ratingColor(_ rating: StudyReviewRating) -> Color {
        switch rating {
        case .again: return .red
        case .hard: return .orange
        case .good: return .blue
        case .easy: return .green
        }
    }
}

struct FlashcardEditorSheet: View {
    let existingCard: StudyFlashcard?
    var defaultDeckName: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var store = FlashcardStore.shared

    @State private var deckName = ""
    @State private var front = ""
    @State private var back = ""
    @State private var hint = ""

    private var canSave: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError { Text(verbatim: saveError).foregroundStyle(.red) }
                Section("所属卡组") {
                    TextField("例如：Swift 并发 / 《渡河记》", text: $deckName)
                    if !store.deckNames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(store.deckNames, id: \.self) { name in
                                    Button(name) {
                                        deckName = name
                                    }
                                    .font(.caption)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        deckName == name ? Color.indigo.opacity(0.18) : Color(.secondarySystemBackground),
                                        in: Capsule()
                                    )
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                Section("正面（回想提问）") {
                    TextEditor(text: $front)
                        .frame(minHeight: 80)
                }

                Section("背面（核心答案与解析）") {
                    TextEditor(text: $back)
                        .frame(minHeight: 110)
                }

                Section("记忆线索（选填）") {
                    TextField("卡壳时给自己的小提示…", text: $hint)
                }
            }
            .navigationTitle(existingCard == nil ? String(localized: "新建闪卡") : String(localized: "编辑闪卡"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            if let existingCard {
                                try store.updateCard(id: existingCard.id, deckName: deckName, front: front, back: back, hint: hint)
                            } else {
                                try store.addCard(deckName: deckName, front: front, back: back, hint: hint)
                            }
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let existingCard {
                    deckName = existingCard.deckName
                    front = existingCard.front
                    back = existingCard.back
                    hint = existingCard.hint ?? ""
                } else if deckName.isEmpty {
                    deckName = defaultDeckName
                }
            }
        }
    }
}
