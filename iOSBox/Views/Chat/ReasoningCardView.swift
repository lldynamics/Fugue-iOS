import SwiftUI

struct ReasoningCardView: View {
    let reasoning: String
    let isActivelyThinking: Bool
    let durationMs: Int?

    @State private var isExpanded: Bool = false
    @State private var hasUserToggled: Bool = false
    @State private var preferences = AppPreferences.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var effectiveExpanded: Bool {
        if hasUserToggled {
            return isExpanded
        }
        return isActivelyThinking || !preferences.autoCollapseReasoning
    }

    private var headerTitle: String {
        if isActivelyThinking {
            return String(localized: "深度思考中…")
        }
        if let ms = durationMs, ms > 0 {
            let seconds = Double(ms) / 1000.0
            return String(localized: "已深度思考（\(seconds, format: .number.precision(.fractionLength(1))) 秒）")
        }
        return String(localized: "已深度思考")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    let current = effectiveExpanded
                    hasUserToggled = true
                    isExpanded = !current
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    if isActivelyThinking {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.readableText)
                            .accessibilityHidden(true)
                    }

                    Text(headerTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(effectiveExpanded ? String(localized: "收起批注") : String(localized: "展开批注"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(effectiveExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, 9)
                .frame(minHeight: DS.TouchTarget.minimum)
                .background(DS.Surface.subtle.opacity(0.82), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if effectiveExpanded {
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(theme.solidFill.opacity(0.55))
                        .frame(width: 2)

                    if isActivelyThinking && !hasUserToggled {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(reasoning)
                                    .font(DS.Typography.prose(size: 14, serif: preferences.literarySerifBody))
                                    .foregroundStyle(.secondary)
                                    .lineSpacing(4.5)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear
                                    .frame(height: 1)
                                    .id("REASONING_END")
                            }
                            .frame(maxHeight: 165)
                            .onChange(of: reasoning.utf8.count) { _, _ in
                                proxy.scrollTo("REASONING_END", anchor: .bottom)
                            }
                        }
                    } else {
                        Text(reasoning)
                            .font(DS.Typography.prose(size: 14, serif: preferences.literarySerifBody))
                            .foregroundStyle(.secondary)
                            .lineSpacing(4.5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, DS.Spacing.sm)
                .padding(.vertical, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
