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
    @State private var cardDragX: CGFloat = 0

    private var theme: DS.AccentTheme { preferences.accentTheme }

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
            .background(DS.Surface.canvas.ignoresSafeArea())
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
                    .foregroundStyle(theme.readableText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(theme.softFill, in: Capsule())

                Spacer()

                if isFlipped && abs(cardDragX) > 22 {
                    Text(cardDragX > 0 ? String(localized: "右滑 · 良好") : String(localized: "左滑 · 重来"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(cardDragX > 0 ? DS.AccentTheme.teal.readableText : .red)
                        .transition(.opacity)
                } else {
                    Text("\(currentIndex + 1) / \(queue.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: Double(currentIndex), total: Double(max(queue.count, 1)))
                .tint(theme.solidFill)
        }
    }

    private func flipCardStage(card: StudyFlashcard) -> some View {
        ZStack {
            // Front Stationery Card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("正面 · 回想问题", systemImage: "sparkle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.readableText)
                    Spacer()
                    FugueSealMark(character: "学", size: 20, theme: theme)
                }

                Spacer(minLength: 6)

                ScrollView {
                    Text(card.front)
                        .font(DS.Typography.prose(size: 21, serif: preferences.literarySerifBody, weight: .semibold))
                        .lineSpacing(6)
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
                            .background(theme.softFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Button {
                            showHint = true
                        } label: {
                            Label("查看提示", systemImage: "lightbulb")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.readableText)
                                .frame(minHeight: DS.TouchTarget.minimum)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 6)

                HStack {
                    Spacer()
                    Label("轻点卡片翻面核对答案", systemImage: "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 24, style: .continuous)
                    .fill(theme.solidFill)
                    .frame(height: 3.5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(DS.Surface.strongBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)
            .opacity(isFlipped ? 0 : 1)
            .accessibilityHidden(isFlipped)

            // Back Stationery Card (counter-rotated 180 deg)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("背面 · 标准解析", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.AccentTheme.teal.readableText)
                    Spacer()
                    Text("左右滑动也可记分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(card.front)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Divider().overlay(DS.Surface.hairline)

                ScrollView {
                    Text(card.back)
                        .font(DS.Typography.prose(size: 17, serif: preferences.literarySerifBody))
                        .lineSpacing(5.5)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 4)

                HStack {
                    Spacer()
                    Text("左滑「重来」· 右滑「良好」，或点选下方间隔档位")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 24, style: .continuous)
                    .fill(DS.AccentTheme.teal.solidFill)
                    .frame(height: 3.5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(DS.Surface.strongBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            .opacity(isFlipped ? 1 : 0)
            .accessibilityHidden(!isFlipped)
        }
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
        .offset(x: cardDragX)
        .rotationEffect(.degrees(Double(cardDragX) * 0.04))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                isFlipped.toggle()
            }
            preferences.triggerSelectionHaptic()
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    guard isFlipped else { return }
                    cardDragX = value.translation.width * 0.85
                }
                .onEnded { value in
                    guard isFlipped else { return }
                    if value.translation.width > 72 {
                        cardDragX = 0
                        submitRating(.good, for: card)
                    } else if value.translation.width < -72 {
                        cardDragX = 0
                        submitRating(.again, for: card)
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            cardDragX = 0
                        }
                    }
                }
        )
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
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                        .padding(.vertical, 8)
                        .background(ratingColor(rating).opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(ratingColor(rating).opacity(0.24), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
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
                    .foregroundStyle(theme.solidForeground)
                    .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                    .padding(.vertical, 10)
                    .background(theme.solidFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var completionSummary: some View {
        VStack(spacing: 16) {
            Spacer()
            FugueSealMark(character: "成", size: 54, theme: theme)

            Text("完成本轮闪卡复习！")
                .font(.system(.title3, design: preferences.literarySerifBody ? .serif : .default).weight(.bold))

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
                    .foregroundStyle(theme.solidForeground)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .frame(minHeight: DS.TouchTarget.minimum)
                    .background(theme.solidFill, in: Capsule())
            }
            .buttonStyle(.plain)
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
        cardDragX = 0
        isFlipped = false
        showHint = false
        currentIndex += 1
    }

    private func ratingColor(_ rating: StudyReviewRating) -> Color {
        switch rating {
        case .again: return .red
        case .hard: return DS.AccentTheme.amber.readableText
        case .good: return DS.AccentTheme.cobalt.readableText
        case .easy: return DS.AccentTheme.teal.readableText
        }
    }
}

struct FlashcardEditorSheet: View {
    let existingCard: StudyFlashcard?
    var defaultDeckName: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?
    @State private var store = FlashcardStore.shared
    @State private var preferences = AppPreferences.shared

    @State private var deckName = ""
    @State private var front = ""
    @State private var back = ""
    @State private var hint = ""

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var canSave: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError { Text(verbatim: saveError).foregroundStyle(.red) }
                if !canSave {
                    Text("填写正面和背面后可保存。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("所属卡组") {
                    TextField("例如：Swift 并发 / 《渡河记》", text: $deckName)
                    if !store.deckNames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(store.deckNames, id: \.self) { name in
                                    Button(name) {
                                        deckName = name
                                    }
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(deckName == name ? theme.readableText : .primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        deckName == name ? theme.softFill : DS.Surface.subtle,
                                        in: Capsule()
                                    )
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                Section("正面（必填：回想提问）") {
                    TextEditor(text: $front)
                        .frame(minHeight: 80)
                }

                Section("背面（必填：核心答案与解析）") {
                    TextEditor(text: $back)
                        .frame(minHeight: 110)
                }

                Section("记忆线索（选填）") {
                    TextField("卡壳时给自己的小提示…", text: $hint)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Surface.grouped)
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
