import SwiftUI

struct ReasoningCardView: View {
    let reasoning: String
    let isActivelyThinking: Bool
    let durationMs: Int?

    @State private var isExpanded: Bool = false
    @State private var hasUserToggled: Bool = false

    private var effectiveExpanded: Bool {
        if hasUserToggled {
            return isExpanded
        }
        return isActivelyThinking
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    let current = effectiveExpanded
                    hasUserToggled = true
                    isExpanded = !current
                }
            } label: {
                HStack(spacing: 7) {
                    if isActivelyThinking {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "brain")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                    }

                    Text(headerTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.82))

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(effectiveExpanded ? 90 : 0))

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Color.purple.opacity(0.09), in: Capsule())
            }
            .buttonStyle(.plain)

            if effectiveExpanded {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.purple.opacity(0.38))
                        .frame(width: 2.5)

                    Text(reasoning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.vertical, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
