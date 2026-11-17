import SwiftUI

struct ArenaComparisonGroupView: View {
    let messages: [ChatMessage]
    let onSelectWinner: (ChatMessage) -> Void
    let onRegenerateSingle: (ChatMessage) -> Void

    @State private var activeTabID: UUID?
    @State private var sideBySideLayout: Bool = false

    private var currentActiveMessage: ChatMessage? {
        if let activeTabID, let found = messages.first(where: { $0.id == activeTabID }) {
            return found
        }
        return messages.first(where: \.isSelectedInGroup) ?? messages.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: "square.split.2x1.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("多模型并发对比 (\(messages.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        sideBySideLayout.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sideBySideLayout ? "rectangle.stack" : "rectangle.split.2x1")
                        Text(sideBySideLayout ? String(localized: "标签视图") : String(localized: "并排横滑"))
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if sideBySideLayout {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(messages) { msg in
                            singleModelCard(msg)
                                .frame(width: 305)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            } else {
                // Model tab strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(messages) { msg in
                            let isSelectedTab = (currentActiveMessage?.id == msg.id)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    activeTabID = msg.id
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(hex: msg.accentHex))
                                        .frame(width: 7, height: 7)

                                    Text(msg.modelDisplayName)
                                        .font(.caption.weight(isSelectedTab ? .semibold : .regular))
                                        .lineLimit(1)

                                    if msg.isStreaming {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else if msg.errorMessage != nil {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else if msg.isSelectedInGroup {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(
                                    isSelectedTab
                                        ? Color.accentColor.opacity(0.15)
                                        : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelectedTab ? Color.accentColor.opacity(0.6) : Color.clear,
                                        lineWidth: 1
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let active = currentActiveMessage {
                    singleModelCard(active)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func singleModelCard(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: msg.accentHex))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(msg.modelDisplayName)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Text(msg.providerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    onSelectWinner(msg)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: msg.isSelectedInGroup ? "checkmark.circle.fill" : "circle")
                        Text(msg.isSelectedInGroup ? String(localized: "上下文主回复") : String(localized: "设为上下文"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(msg.isSelectedInGroup ? Color.accentColor : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        msg.isSelectedInGroup ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.5)

            MessageRowView(
                message: msg,
                isCompactCard: true,
                onRegenerate: { onRegenerateSingle(msg) },
                onRegenerateWithCurrentModel: nil
            )
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    msg.isSelectedInGroup ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
    }
}
