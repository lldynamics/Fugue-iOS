import ActivityKit
import SwiftUI
import WidgetKit

struct IOSBoxGenerationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IOSBoxGenerationAttributes.self) { context in
            LockScreenLiveActivityView(
                attributes: context.attributes,
                state: context.state
            )
            .widgetURL(deepLinkURL(for: context.attributes.conversationID))
            .activityBackgroundTint(.black.opacity(0.82))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.cyan)
                        Text(context.state.visibleSpeaker)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .privacySensitive(context.state.presentation == .preview)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.totalTurns > 1 {
                        Text("\(min(context.state.completedTurns + 1, context.state.totalTurns))/\(context.state.totalTurns)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.14), in: Capsule())
                    } else {
                        Text(context.attributes.modeBadge)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if let title = context.state.visibleTitle {
                                Text(title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .privacySensitive()
                            }
                            Spacer(minLength: 8)
                            Text(context.state.phaseText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                        }
                        if let snippet = context.state.visibleSnippet {
                            Text(snippet)
                                .font(.caption2)
                                .foregroundStyle(.primary.opacity(0.9))
                                .lineLimit(2)
                                .privacySensitive()
                        }
                        if context.state.totalTurns > 1 {
                            ProgressView(
                                value: Double(min(context.state.completedTurns, context.state.totalTurns)),
                                total: Double(max(1, context.state.totalTurns))
                            )
                            .tint(.cyan)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                if context.state.totalTurns > 1 {
                    Text("\(min(context.state.completedTurns + 1, context.state.totalTurns))/\(context.state.totalTurns)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                } else {
                    Text(String(context.state.phaseText.prefix(4)))
                        .font(.caption2.weight(.medium))
                }
            } minimal: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
            }
            .widgetURL(deepLinkURL(for: context.attributes.conversationID))
        }
    }

    private func deepLinkURL(for conversationID: String) -> URL? {
        guard UUID(uuidString: conversationID) != nil else { return nil }
        return URL(string: "iosbox://conversation/\(conversationID)")
    }
}

private struct LockScreenLiveActivityView: View {
    let attributes: IOSBoxGenerationAttributes
    let state: IOSBoxGenerationAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cyan)
                Text(state.visibleSpeaker)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .privacySensitive(state.presentation == .preview)
                Spacer(minLength: 6)
                Text(attributes.modeBadge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.16), in: Capsule())
            }

            HStack {
                if let title = state.visibleTitle {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .privacySensitive()
                }
                Spacer(minLength: 8)
                Text(state.phaseText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
            }

            if let snippet = state.visibleSnippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .privacySensitive()
            }

            if state.totalTurns > 1 {
                ProgressView(
                    value: Double(min(state.completedTurns, state.totalTurns)),
                    total: Double(max(1, state.totalTurns))
                )
                .tint(.cyan)
            }
        }
        .padding(14)
    }
}
