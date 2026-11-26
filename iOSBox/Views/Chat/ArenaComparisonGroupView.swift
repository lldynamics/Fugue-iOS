import SwiftUI

struct ArenaComparisonGroupView: View {
    let groupID: UUID
    let messages: [ChatMessage]
    let isGenerating: Bool
    let searchFocus: MessageSearchFocus?
    let onFollowUp: (ChatMessage) -> Void
    let onRegenerateSingle: (ChatMessage) -> Void
    let onContinueSingle: ((ChatMessage) -> Void)?
    let onSelectRevision: ((ChatMessage, Int) -> Void)?
    let onQuote: ((String) -> Void)?
    let onToggleBookmark: ((ChatMessage) -> Void)?
    let onForkConversation: ((ChatMessage) -> Void)?
    let onSynthesize: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var activeTabID: UUID?
    @State private var sideBySideLayout: Bool = false
    @State private var didApplyInitialLayout = false
    @State private var preferences = AppPreferences.shared

    private var currentActiveMessage: ChatMessage? {
        let pool = messages
        if let activeTabID, let found = pool.first(where: { $0.id == activeTabID }) {
            return found
        }
        return pool.first(where: \.isSelectedInGroup) ?? pool.first
    }

    private func displayName(for msg: ChatMessage) -> String {
        if msg.isSynthesis {
            return String(localized: "汇总 · \(msg.modelDisplayName)")
        }
        return msg.modelDisplayName
    }

    var body: some View {
        let pool = messages
        let completeCount = ArenaSynthesis.eligibleSources(in: messages, groupID: groupID).count
        let theme = preferences.accentTheme

        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Compact Header Row
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "square.split.2x1.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.readableText)
                    .accessibilityHidden(true)
                Text("多模型并发对比 (\(messages.filter { !$0.isSynthesis }.count))")
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
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, DS.Spacing.xxs)
                    .background(DS.Surface.neutralChipFill, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            // Answer-First Content Stage
            if sideBySideLayout {
                if horizontalSizeClass == .regular && pool.count >= 2 {
                    let colCount = min(pool.count, 3)
                    let cols = Array(repeating: GridItem(.flexible(minimum: 220), spacing: DS.Spacing.md, alignment: .top), count: colCount)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: DS.Spacing.md) {
                        ForEach(pool) { msg in
                            singleModelCard(msg)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: DS.Spacing.md) {
                            ForEach(pool) { msg in
                                singleModelCard(msg)
                                    .frame(width: 308)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                }
            } else {
                // Sleek model tab strip directly above the answer card
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.xs) {
                        ForEach(pool) { msg in
                            let isSelectedTab = (currentActiveMessage?.id == msg.id)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    activeTabID = msg.id
                                }
                            } label: {
                                HStack(spacing: DS.Spacing.xs) {
                                    Circle()
                                        .fill(Color(hex: msg.accentHex))
                                        .frame(width: 7, height: 7)

                                    Text(displayName(for: msg))
                                        .font(.caption.weight(isSelectedTab ? .semibold : .regular))
                                        .foregroundStyle(isSelectedTab ? .primary : .secondary)
                                        .lineLimit(1)

                                    if msg.isStreaming {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else if msg.errorMessage != nil {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(DS.StatusText.warning)
                                    } else if msg.isSelectedInGroup {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.caption2)
                                            .foregroundStyle(theme.readableText)
                                    }
                                }
                                .padding(.horizontal, DS.Spacing.md)
                                .padding(.vertical, 7)
                                .background(
                                    isSelectedTab ? DS.Surface.canvas : DS.Surface.neutralChipFill,
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        isSelectedTab ? theme.tintColor.opacity(0.45) : Color.clear,
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

            // Bottom Group Synthesis Bar (placed cleanly after reading)
            HStack(spacing: DS.Spacing.sm) {
                Button(action: onSynthesize) {
                    Label("汇总", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGenerating || completeCount < 2)

                Spacer(minLength: 0)
            }
            .padding(.top, 2)

            if completeCount < 2 {
                Text("至少需要两条完整答案才能汇总。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.subtle.opacity(0.7), padding: DS.Spacing.md)
        .onAppear {
            if !didApplyInitialLayout {
                didApplyInitialLayout = true
                if horizontalSizeClass == .regular && searchFocus == nil {
                    sideBySideLayout = true
                }
            }
        }
        .onChange(of: searchFocus, initial: true) { _, focus in
            guard let focus, focus.groupID == groupID else { return }
            sideBySideLayout = false
            activeTabID = focus.messageID
        }
        .onChange(of: messages.count) { _, _ in
            if let summary = messages.last(where: \.isSynthesis) { activeTabID = summary.id }
        }
    }

    @ViewBuilder
    private func singleModelCard(_ msg: ChatMessage) -> some View {
        let theme = preferences.accentTheme

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Identity header
            HStack(spacing: DS.Spacing.xs) {
                Circle()
                    .fill(Color(hex: msg.accentHex))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(msg.modelDisplayName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)

                Text("· \(msg.providerName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if msg.isSynthesis {
                    DSBadge(text: String(localized: "裁判汇总"), icon: "sparkles", style: .accent(theme))
                }
            }

            if msg.isSynthesis, !ArenaSynthesis.isCurrent(msg, in: messages) {
                Text("原答案已更新，此汇总已过期，不会用于后续上下文。请重新汇总。")
                    .font(.caption)
                    .foregroundStyle(DS.StatusText.warning)
            }

            // Answer content immediately visible
            MessageRowView(
                message: msg,
                isCompactCard: true,
                actions: MessageRowActions(
                    onSelectRevision: onSelectRevision.map { handler in { idx in handler(msg, idx) } },
                    onRegenerate: { if msg.isSynthesis { onSynthesize() } else { onRegenerateSingle(msg) } },
                    onContinueGeneration: onContinueSingle.map { handler in { handler(msg) } },
                    onQuote: onQuote,
                    onToggleBookmark: onToggleBookmark.map { handler in { handler(msg) } },
                    onForkConversation: onForkConversation.map { handler in { handler(msg) } }
                )
            )

            Divider().opacity(0.45)

            // Action controls cleanly anchored at card bottom
            HStack(spacing: DS.Spacing.sm) {
                Button { onFollowUp(msg) } label: {
                    if msg.isSelectedInGroup {
                        Label("当前追问回复", systemImage: "checkmark.circle.fill")
                    } else {
                        Text("沿这条回答追问")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGenerating || (msg.isSynthesis && (!ArenaSynthesis.isComplete(msg) || !ArenaSynthesis.isCurrent(msg, in: messages))))

                Spacer(minLength: 0)
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: DS.Radius.md,
                bottomLeadingRadius: DS.Radius.md,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color(hex: msg.accentHex).opacity(0.85))
            .frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(
                    msg.isSelectedInGroup ? theme.tintColor.opacity(0.45) : DS.Surface.hairline,
                    lineWidth: 1
                )
        )
    }
}
