import SwiftUI

struct MessageStudyDeckView: View {
    let deckName: String
    let conversationID: UUID
    let messageID: UUID
    let flashcards: [StudyCardDraft]
    let quiz: StudyQuizBundle?
    let isGenerating: Bool
    var onSelectQuizOption: ((UUID, Int) -> Void)?
    var onFollowUpQuestion: ((String) -> Void)?

    @State private var saveError: String?
    @State private var flashcardStore = FlashcardStore.shared
    @State private var preferences = AppPreferences.shared
    @State private var flippedCardIDs: Set<UUID> = []
    @State private var shownHintIDs: Set<UUID> = []

    private var normalizedDeck: String {
        FlashcardStore.normalizeDeckName(deckName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saveError { Text(verbatim: saveError).font(.callout).foregroundStyle(.red) }
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在提炼互动助学卡片…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !flashcards.isEmpty {
                flashcardsContainer
            }

            if let quiz, !quiz.questions.isEmpty {
                quizContainer(quiz)
            }
        }
    }

    // MARK: - Inline Flashcards

    private var flashcardsContainer: some View {
        let unsavedCount = flashcards.filter { !flashcardStore.contains(front: $0.front, deckName: normalizedDeck) }.count

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                Text("记忆闪卡 · \(flashcards.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if unsavedCount > 0 {
                    Button {
                        do {
                            try flashcardStore.addDrafts(
                                flashcards,
                                deckName: normalizedDeck,
                                conversationID: conversationID,
                                messageID: messageID
                            )
                            saveError = nil
                            preferences.triggerLightHaptic()
                        } catch { saveError = error.localizedDescription }
                    } label: {
                        Label("全部收入卡包", systemImage: "plus.rectangle.on.folder.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.indigo.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Label("已全部入库", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(flashcards.enumerated()), id: \.element.id) { index, card in
                        inlineFlashcardItem(card, index: index + 1, total: flashcards.count)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.18), lineWidth: 1)
        )
    }

    private func inlineFlashcardItem(_ card: StudyCardDraft, index: Int, total: Int) -> some View {
        let isFlipped = flippedCardIDs.contains(card.id)
        let isSaved = flashcardStore.contains(front: card.front, deckName: normalizedDeck)
        let showHint = shownHintIDs.contains(card.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(index)/\(total) · \(isFlipped ? String(localized: "解析") : String(localized: "问题"))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isFlipped ? .teal : .indigo)

                Spacer()

                Button {
                    if !isSaved {
                        do {
                            try flashcardStore.addCard(
                                deckName: normalizedDeck,
                                front: card.front,
                                back: card.back,
                                hint: card.hint,
                                sourceConversationID: conversationID,
                                sourceMessageID: messageID
                            )
                            saveError = nil
                            preferences.triggerSelectionHaptic()
                        } catch { saveError = error.localizedDescription }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isSaved ? "checkmark.circle.fill" : "plus.circle")
                        Text(isSaved ? String(localized: "已入库") : String(localized: "收入卡包"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSaved ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isSaved)
            }

            Text(isFlipped ? card.back : card.front)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isFlipped, let hint = card.hint, !hint.isEmpty {
                if showHint {
                    Text("💡 \(hint)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        shownHintIDs.insert(card.id)
                    } label: {
                        Text("显示提示")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.indigo)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text(isFlipped ? String(localized: "点击切回正面") : String(localized: "点击翻转看答案"))
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 248)
        .frame(minHeight: 138)
        .background(
            isFlipped ? Color.teal.opacity(0.08) : Color(.systemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFlipped ? Color.teal.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                if isFlipped {
                    flippedCardIDs.remove(card.id)
                } else {
                    flippedCardIDs.insert(card.id)
                }
            }
            preferences.triggerSelectionHaptic()
        }
    }

    // MARK: - Inline Multiple-Choice Quiz

    private func quizContainer(_ quiz: StudyQuizBundle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checklist.checked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Text(quiz.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if quiz.answeredCount > 0 {
                    Text("得分 \(quiz.correctCount)/\(quiz.questions.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(quiz.correctCount == quiz.questions.count ? .green : .teal)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.teal.opacity(0.12), in: Capsule())
                }
            }

            ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { qIdx, q in
                quizQuestionCard(q, number: qIdx + 1)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.2), lineWidth: 1)
        )
    }

    private func quizQuestionCard(_ q: StudyQuizQuestion, number: Int) -> some View {
        let letters = ["A", "B", "C", "D", "E"]
        let correctAnswerText = q.options.indices.contains(q.correctIndex) ? q.options[q.correctIndex] : ""
        let cardBack = q.explanation.isEmpty ? correctAnswerText : "\(correctAnswerText)\n\n\(q.explanation)"
        let alreadySaved = flashcardStore.contains(front: q.question, deckName: normalizedDeck)

        return VStack(alignment: .leading, spacing: 8) {
            Text("\(number). \(q.question)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 6) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { optIdx, option in
                    let prefix = optIdx < letters.count ? letters[optIdx] : "\(optIdx + 1)"
                    let isSelected = q.selectedIndex == optIdx
                    let isRightOption = optIdx == q.correctIndex

                    Button {
                        guard !q.isAnswered else { return }
                        preferences.triggerSelectionHaptic()
                        onSelectQuizOption?(q.id, optIdx)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(prefix).")
                                .font(.caption.monospaced().weight(.bold))
                                .foregroundStyle(optionForeground(answered: q.isAnswered, isSelected: isSelected, isRight: isRightOption))

                            Text(option)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if q.isAnswered {
                                if isRightOption {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else if isSelected {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            optionBackground(answered: q.isAnswered, isSelected: isSelected, isRight: isRightOption),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(optionBorder(answered: q.isAnswered, isSelected: isSelected, isRight: isRightOption), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if q.isAnswered {
                if !q.explanation.isEmpty {
                    Text(q.explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                HStack(spacing: 10) {
                    Button {
                        do {
                            try flashcardStore.addCard(
                                deckName: normalizedDeck,
                                front: q.question,
                                back: cardBack,
                                sourceConversationID: conversationID,
                                sourceMessageID: messageID
                            )
                            saveError = nil
                            preferences.triggerLightHaptic()
                        } catch { saveError = error.localizedDescription }
                    } label: {
                        Label(
                            alreadySaved ? String(localized: "已转闪卡") : String(localized: "错题转闪卡"),
                            systemImage: alreadySaved ? "checkmark.circle.fill" : "plus.rectangle.on.rectangle"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(alreadySaved ? .green : .indigo)
                    }
                    .buttonStyle(.plain)
                    .disabled(alreadySaved)

                    if !q.isCorrect, let onFollowUpQuestion {
                        Button {
                            onFollowUpQuestion(q.question)
                        } label: {
                            Label("追问这道题", systemImage: "quote.opening")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.teal)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func optionForeground(answered: Bool, isSelected: Bool, isRight: Bool) -> Color {
        guard answered else { return .secondary }
        if isRight { return .green }
        if isSelected { return .red }
        return .secondary
    }

    private func optionBackground(answered: Bool, isSelected: Bool, isRight: Bool) -> Color {
        guard answered else { return Color(.secondarySystemBackground).opacity(0.6) }
        if isRight { return Color.green.opacity(0.12) }
        if isSelected { return Color.red.opacity(0.12) }
        return Color(.secondarySystemBackground).opacity(0.35)
    }

    private func optionBorder(answered: Bool, isSelected: Bool, isRight: Bool) -> Color {
        guard answered else { return Color.primary.opacity(0.07) }
        if isRight { return Color.green.opacity(0.45) }
        if isSelected { return Color.red.opacity(0.45) }
        return Color.clear
    }
}
