import SwiftUI

/// Interactive word-level shadowing & pronunciation studio embedded in Today's Lesson.
struct EnglishShadowingSectionView: View {
    let drills: [EnglishShadowingDrill]
    let accent: EnglishAccentPreference
    let coachingDrillID: UUID?
    let onEvaluateDrill: (UUID, ShadowingEvaluationSummary) -> Void
    let onRequestAICoach: (EnglishShadowingDrill) -> Void

    @State private var speechCoach = EnglishSpeechCoachService.shared
    @State private var preferences = AppPreferences.shared
    @State private var recordingDrillID: UUID?
    @State private var liveTranscript: String = ""
    @State private var liveSegments: [(word: String, confidence: Float)] = []
    @State private var manualPracticeDrill: EnglishShadowingDrill?
    @State private var manualSpokenDraft: String = ""

    private var theme: DS.AccentTheme { preferences.accentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Label("跟读文本对照", systemImage: "waveform.badge.mic")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("点单词可单独慢读")
                    .font(.caption2)
                    .foregroundStyle(DS.Surface.inkSecondary)
            }

            if let err = speechCoach.speechError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(DS.StatusText.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }

            ForEach(Array(drills.enumerated()), id: \.element.id) { index, drill in
                drillCard(drill, number: index + 1)
            }
        }
        .sheet(item: $manualPracticeDrill) { drill in
            NavigationStack {
                Form {
                    Section("目标原句") {
                        Text(drill.sentence)
                            .font(.body.weight(.semibold))
                    }
                    Section("输入或听写你读出的句子（便于无麦克风环境测试评分）") {
                        TextField("输入英文句子检验对齐评分…", text: $manualSpokenDraft, axis: .vertical)
                            .lineLimit(2...4)
                            .textInputAutocapitalization(.never)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(DS.Surface.grouped)
                .navigationTitle("检验跟读对齐")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { manualPracticeDrill = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("评分") {
                            let summary = EnglishShadowingEvaluator.evaluate(
                                expectedSentence: drill.sentence,
                                spokenTranscript: manualSpokenDraft
                            )
                            onEvaluateDrill(drill.id, summary)
                            manualPracticeDrill = nil
                        }
                        .disabled(manualSpokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private func drillCard(_ drill: EnglishShadowingDrill, number: Int) -> some View {
        let isRecordingThis = recordingDrillID == drill.id && speechCoach.isRecording

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text("句 \(number)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(theme.readableText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.softFill, in: Capsule())

                if let score = drill.bestScore {
                    DSBadge(
                        text: String(localized: "识别文本匹配度 \(score)%"),
                        icon: score >= 85 ? "checkmark.seal.fill" : "arrow.clockwise",
                        style: score >= 85 ? .accent(.teal) : .accent(.amber)
                    )
                }

                Spacer()

                Button {
                    manualSpokenDraft = drill.lastSpokenTranscript ?? ""
                    manualPracticeDrill = drill
                } label: {
                    Image(systemName: "keyboard")
                        .font(.caption)
                        .foregroundStyle(DS.Surface.inkSecondary)
                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("模拟跟读评分")
            }

            // Interactive Word-by-Word Colored Display
            interactiveWordFlow(for: drill)

            Text(drill.translationZh)
                .font(.footnote)
                .foregroundStyle(DS.Surface.inkSecondary)

            if !drill.focusTip.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "ear")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.readableText)
                        .padding(.top, 2)
                    Text(drill.focusTip)
                        .font(.caption)
                        .foregroundStyle(DS.Surface.inkSecondary)
                }
            }

            if isRecordingThis {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.solidFill)
                        .frame(width: 8, height: 8)
                    Text(liveTranscript.isEmpty ? String(localized: "请朗读上方英文原句…") : liveTranscript)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            } else if let tokens = drill.lastEvaluationTokens {
                let wrongPairs = tokens.compactMap { t -> String? in
                    guard t.state == .missed else { return nil }
                    if let heard = t.heardWord, !heard.isEmpty {
                        return String(localized: "\(t.expectedWord) → 识别为“\(heard)”")
                    }
                    return String(localized: "未匹配：\(t.expectedWord)")
                }
                if !wrongPairs.isEmpty {
                    Text(wrongPairs.prefix(4).joined(separator: "  ·  "))
                        .font(.caption2)
                        .foregroundStyle(DS.AccentTheme.vermilion.readableText)
                }
            }

            if let feedback = drill.aiCoachFeedback, !feedback.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(theme.solidFill)
                        .frame(width: 2.5)
                    Text(feedback)
                        .font(DS.Typography.prose(size: 13.5, serif: preferences.literarySerifBody))
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Surface.subtle, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            }

            // Action Bar (44pt minimum touch targets)
            HStack(spacing: DS.Spacing.xs) {
                Button {
                    preferences.triggerSelectionHaptic()
                    speechCoach.speakEnglish(drill.sentence, accent: accent, slow: false)
                } label: {
                    Label("常速", systemImage: "speaker.wave.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .background(DS.Surface.subtle, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    preferences.triggerSelectionHaptic()
                    speechCoach.speakEnglish(drill.sentence, accent: accent, slow: true)
                } label: {
                    Label("慢读", systemImage: "tortoise.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: DS.TouchTarget.minimum)
                        .background(DS.Surface.subtle, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    toggleDrillRecording(drill)
                } label: {
                    Label(
                        isRecordingThis ? String(localized: "完成评分") : String(localized: "跟读"),
                        systemImage: isRecordingThis ? "stop.fill" : "mic.fill"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.solidForeground)
                    .padding(.horizontal, 14)
                    .frame(minHeight: DS.TouchTarget.minimum)
                    .background(isRecordingThis ? Color.red : theme.solidFill, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if drill.lastSpokenTranscript != nil {
                    Button {
                        onRequestAICoach(drill)
                    } label: {
                        if coachingDrillID == drill.id {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: DS.TouchTarget.minimum, minHeight: DS.TouchTarget.minimum)
                        } else {
                            Label("练习建议", systemImage: "sparkle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.readableText)
                                .padding(.horizontal, 10)
                                .frame(minHeight: DS.TouchTarget.minimum)
                                .background(theme.softFill, in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(coachingDrillID != nil)
                }
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, borderColor: DS.Surface.hairline, padding: DS.Spacing.md)
    }

    @ViewBuilder
    private func interactiveWordFlow(for drill: EnglishShadowingDrill) -> some View {
        let tokens: [ShadowingWordResult] = drill.lastEvaluationTokens ?? drill.sentence
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { ShadowingWordResult(expectedWord: $0, state: .accurate, heardWord: nil) }
        let hasEvaluated = drill.lastEvaluationTokens != nil

        WrappingWordFlowLayout(spacing: 6, lineSpacing: 7) {
            ForEach(tokens) { item in
                Button {
                    preferences.triggerSelectionHaptic()
                    speechCoach.speakEnglish(item.expectedWord, accent: accent, slow: true)
                } label: {
                    Text(item.expectedWord)
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .foregroundStyle(wordForeground(item.state, evaluated: hasEvaluated))
                        .padding(.horizontal, hasEvaluated ? 6 : 2)
                        .padding(.vertical, 2)
                        .background(
                            wordBackground(item.state, evaluated: hasEvaluated),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func wordForeground(_ state: ShadowingWordState, evaluated: Bool) -> Color {
        guard evaluated else { return .primary }
        switch state {
        case .accurate: return DS.AccentTheme.teal.readableText
        case .fuzzy: return DS.AccentTheme.amber.readableText
        case .missed: return DS.AccentTheme.vermilion.readableText
        }
    }

    private func wordBackground(_ state: ShadowingWordState, evaluated: Bool) -> Color {
        guard evaluated else { return .clear }
        switch state {
        case .accurate: return DS.AccentTheme.teal.softFill
        case .fuzzy: return DS.AccentTheme.amber.softFill
        case .missed: return DS.AccentTheme.vermilion.softFill
        }
    }

    private func toggleDrillRecording(_ drill: EnglishShadowingDrill) {
        if recordingDrillID == drill.id && speechCoach.isRecording {
            speechCoach.stopRecording()
            let summary = EnglishShadowingEvaluator.evaluate(
                expectedSentence: drill.sentence,
                spokenTranscript: liveTranscript,
                segmentConfidences: liveSegments
            )
            onEvaluateDrill(drill.id, summary)
            recordingDrillID = nil
            return
        }

        liveTranscript = ""
        liveSegments = []
        recordingDrillID = drill.id
        preferences.triggerSelectionHaptic()
        speechCoach.startEnglishRecording(accent: accent) { transcript, segments, isFinal in
            liveTranscript = transcript
            liveSegments = segments
            if isFinal {
                let summary = EnglishShadowingEvaluator.evaluate(
                    expectedSentence: drill.sentence,
                    spokenTranscript: transcript,
                    segmentConfidences: segments
                )
                onEvaluateDrill(drill.id, summary)
                recordingDrillID = nil
            }
        }
    }
}

/// Lightweight custom `Layout` that wraps tappable word tokens across lines cleanly.
struct WrappingWordFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += rowHeight + lineSpacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, currentX + size.width)
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
        return CGSize(width: usedWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            currentX += size.width + spacing
        }
    }
}
