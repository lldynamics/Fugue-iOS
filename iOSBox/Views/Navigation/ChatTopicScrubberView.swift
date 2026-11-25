import SwiftUI

/// Whisper-quiet vertical chapter tick rail along the trailing edge of long conversations.
/// Dragging or tapping jumps instantaneously across user prompt milestones.
struct ChatTopicScrubberView: View {
    struct PromptMilestone: Identifiable {
        let id: UUID
        let index: Int
        let preview: String
    }

    let milestones: [PromptMilestone]
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
            .accessibilityHidden(true)
        }
    }
}
