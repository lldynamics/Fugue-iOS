import SwiftUI

struct ArenaComparisonGroupView: View {
    let groupID: UUID
    let messages: [ChatMessage]
    let isBlindMode: Bool
    let isGenerating: Bool
    let onToggleBlindMode: (() -> Void)?
    let searchFocus: MessageSearchFocus?
    let onVote: (ChatMessage) -> Void
    let onFollowUp: (ChatMessage) -> Void
    let onRegenerateSingle: (ChatMessage) -> Void
    let onContinueSingle: ((ChatMessage) -> Void)?
    let onSelectRevision: ((ChatMessage, Int) -> Void)?
    let onQuote: ((String) -> Void)?
    let onToggleBookmark: ((ChatMessage) -> Void)?
    let onForkConversation: ((ChatMessage) -> Void)?
    let onSynthesize: () -> Void
    let onCrossCritique: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var activeTabID: UUID?
    @State private var sideBySideLayout: Bool = false
    @State private var didApplyInitialLayout = false

    private var isRevealed: Bool {
        !isBlindMode || messages.filter { !$0.isSynthesis }.contains { $0.assistanceMetadata.blindArenaRevealed }
    }

    private var orderedMessages: [ChatMessage] {
        if !isRevealed {
            return ArenaSynthesis.blindDisplayOrder(for: messages, groupID: groupID)
        }
        return messages
    }

    private var currentActiveMessage: ChatMessage? {
        let pool = orderedMessages
        if let activeTabID, let found = pool.first(where: { $0.id == activeTabID }) {
            return found
        }
        return isRevealed ? (pool.first(where: \.isSelectedInGroup) ?? pool.first) : pool.first
    }

    private func displayName(for msg: ChatMessage, in list: [ChatMessage]) -> String {
        if msg.isSynthesis {
            return String(localized: "汇总 · \(msg.modelDisplayName)")
        }
        if !isRevealed {
            let candidates = list.filter { !$0.isSynthesis }
            if let idx = candidates.firstIndex(where: { $0.id == msg.id }) {
                return ArenaSynthesis.blindLabel(at: idx)
            }
        }
        return msg.modelDisplayName
    }

    var body: some View {
        let pool = orderedMessages
        let completeCount = messages.filter { !$0.isSynthesis && ArenaSynthesis.isComplete($0) }.count

        VStack(alignment: .leading, spacing: 10) {
            // Header bar
            HStack(spacing: 6) {
                Image(systemName: "square.split.2x1.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("多模型并发对比 (\(messages.filter { !$0.isSynthesis }.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if let onToggleBlindMode {
                    Button(action: onToggleBlindMode) {
                        HStack(spacing: 3) {
                            Image(systemName: isBlindMode ? "eye.slash.fill" : "eye")
                            Text("双盲")
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isBlindMode ? Color.accentColor : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            isBlindMode ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

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

            HStack(spacing: 8) {
                Button(action: onSynthesize) {
                    Label("由裁判模型综合提炼", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating || completeCount < 2)

                if let onCrossCritique {
                    Button(action: onCrossCritique) {
                        Label("互评修正", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isGenerating || completeCount < 2)
                }
            }

            if completeCount < 2 {
                Text("至少需要两条完整答案才能汇总。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !isRevealed {
                Text("双盲评测中：投票选出最佳回复后将揭晓模型身份。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if isBlindMode && isRevealed && !messages.contains(where: { $0.assistanceMetadata.blindArenaBallot != nil }) {
                Text("此轮已揭晓，未记录独立选票。").font(.caption2).foregroundStyle(.secondary)
            }

            if sideBySideLayout {
                if horizontalSizeClass == .regular && pool.count >= 2 {
                    let colCount = min(pool.count, 3)
                    let cols = Array(repeating: GridItem(.flexible(minimum: 220), spacing: 12, alignment: .top), count: colCount)
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
                        ForEach(pool) { msg in
                            singleModelCard(msg, in: pool)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(pool) { msg in
                                singleModelCard(msg, in: pool)
                                    .frame(width: 305)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                }
            } else {
                // Model tab strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pool) { msg in
                            let isSelectedTab = (currentActiveMessage?.id == msg.id)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    activeTabID = msg.id
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isRevealed || msg.isSynthesis ? Color(hex: msg.accentHex) : Color.secondary)
                                        .frame(width: 7, height: 7)

                                    Text(displayName(for: msg, in: pool))
                                        .font(.caption.weight(isSelectedTab ? .semibold : .regular))
                                        .lineLimit(1)

                                    if msg.isStreaming {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else if msg.errorMessage != nil {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else if isRevealed && msg.isSelectedInGroup {
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
                    singleModelCard(active, in: pool)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
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
    private func singleModelCard(_ msg: ChatMessage, in pool: [ChatMessage]) -> some View {
        let title = displayName(for: msg, in: pool)
        let blindOverride = (!isRevealed && !msg.isSynthesis) ? title : nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(blindOverride != nil ? Color.secondary : Color(hex: msg.accentHex))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(blindOverride ?? msg.modelDisplayName)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if blindOverride == nil {
                        Text(msg.providerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if msg.assistanceMetadata.blindArenaBallot != nil {
                    Label("盲评得票", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }

            HStack {
                if !isRevealed && !msg.isSynthesis {
                    Button("投票并揭晓") {
                        activeTabID = msg.id
                        onVote(msg)
                    }
                    .disabled(!ArenaSynthesis.isComplete(msg) || ArenaSynthesis.eligibleSources(in: pool, groupID: groupID).count < 2)
                }
                Button { onFollowUp(msg) } label: {
                    if isRevealed && msg.isSelectedInGroup {
                        Label("当前追问回复", systemImage: "checkmark.circle")
                    } else {
                        Text("沿这条回答追问")
                    }
                }
                .disabled(msg.isSynthesis && (!ArenaSynthesis.isComplete(msg) || !ArenaSynthesis.isCurrent(msg, in: messages)))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isGenerating)

            if msg.isSynthesis {
                Label("裁判汇总", systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                if !ArenaSynthesis.isCurrent(msg, in: messages) {
                    Text("原答案已更新，此汇总已过期，不会用于后续上下文。请重新汇总。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Divider().opacity(0.5)

            MessageRowView(
                message: msg,
                isCompactCard: true,
                blindLabel: blindOverride,
                onSelectRevision: onSelectRevision.map { handler in { idx in handler(msg, idx) } },
                onRegenerate: { if msg.isSynthesis { onSynthesize() } else { onRegenerateSingle(msg) } },
                onRegenerateWithCurrentModel: nil,
                onContinueGeneration: onContinueSingle.map { handler in { handler(msg) } },
                onQuote: onQuote,
                onToggleBookmark: onToggleBookmark.map { handler in { handler(msg) } },
                onForkConversation: onForkConversation.map { handler in { handler(msg) } }
            )
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    isRevealed && msg.isSelectedInGroup ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
    }
}
