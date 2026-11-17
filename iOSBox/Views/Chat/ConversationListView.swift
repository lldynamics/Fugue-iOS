import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Binding var selectedTab: Int
    @Binding var pendingConversationToOpen: Conversation?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \AssistantPreset.sortOrder) private var presets: [AssistantPreset]

    @State private var navigationPath: [Conversation] = []
    @State private var searchText: String = ""

    private var filteredConversations: [Conversation] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversations }
        return conversations.filter { conv in
            if conv.title.lowercased().contains(q) { return true }
            return conv.messages.contains { $0.content.lowercased().contains(q) }
        }
    }

    private var pinnedList: [Conversation] {
        filteredConversations.filter(\.isPinned)
    }

    private var regularList: [Conversation] {
        filteredConversations.filter { !$0.isPinned }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if conversations.isEmpty {
                    emptyConversationsPlaceholder
                } else {
                    List {
                        if !pinnedList.isEmpty {
                            Section("置顶对话") {
                                ForEach(pinnedList) { conv in
                                    conversationRow(conv)
                                }
                            }
                        }

                        Section(pinnedList.isEmpty ? String(localized: "全部对话") : String(localized: "最近对话")) {
                            ForEach(regularList) { conv in
                                conversationRow(conv)
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "搜索标题或聊天内容")
                }
            }
            .navigationTitle("iOSBox")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        createNewConversation(arenaMode: true)
                    } label: {
                        Label("并发对比", systemImage: "square.split.2x1")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createNewConversation(arenaMode: false)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .navigationDestination(for: Conversation.self) { conv in
                ChatDetailView(
                    conversation: conv,
                    onNavigateToProviders: {
                        selectedTab = 2
                    }
                )
            }
            .onChange(of: pendingConversationToOpen) { _, newValue in
                if let conv = newValue {
                    navigationPath = [conv]
                    pendingConversationToOpen = nil
                }
            }
        }
    }

    @ViewBuilder
    private func conversationRow(_ conv: Conversation) -> some View {
        NavigationLink(value: conv) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Text(conv.assistantEmoji)
                        .font(.title3)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(conv.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)

                        if conv.isArenaMode {
                            Text("对比")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }

                        Spacer()

                        Text(conv.updatedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 6) {
                        if let lastMsg = conv.sortedMessages.last {
                            Text(lastMsg.content.isEmpty ? (lastMsg.isStreaming ? String(localized: "正在生成…") : String(localized: "[附件消息]")) : lastMsg.content)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let target = conv.primaryTarget {
                            Text("\(target.providerName) · \(target.modelDisplayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("点击开始对话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                conv.isPinned.toggle()
                try? modelContext.save()
            } label: {
                Label(conv.isPinned ? String(localized: "取消置顶") : String(localized: "置顶"), systemImage: conv.isPinned ? "pin.slash" : "pin.fill")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteConversation(conv)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var emptyConversationsPlaceholder: some View {
        VStack(spacing: 18) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            Text("聚合你的所有 AI 模型")
                .font(.title3.weight(.bold))

            Text("自由接入 OpenAI 兼容中转、DeepSeek、OpenRouter、Claude 与 Gemini。\n既可单聊随时切换模型，也可一键开启多模型同屏对比。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            HStack(spacing: 12) {
                Button {
                    createNewConversation(arenaMode: false)
                } label: {
                    Label("新建对话", systemImage: "plus.bubble.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    createNewConversation(arenaMode: true)
                } label: {
                    Label("多模型对比", systemImage: "square.split.2x1")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Waits for any in-flight generation to fully stop before deleting,
    /// so streaming tasks never write into a deleted conversation.
    private func deleteConversation(_ conv: Conversation) {
        Task {
            await ChatEngine.shared.stopGenerationAndWait(for: conv.id)
            modelContext.delete(conv)
            try? modelContext.save()
        }
    }

    private func createNewConversation(arenaMode: Bool) {
        let allTargets = ChatEngine.shared.availableTargets(from: providers)
        let preferredPrimary = providers
            .filter { $0.isEnabled && KeychainService.shared.hasAPIKey(for: $0.id) }
            .flatMap { p in p.enabledModels.map { p.makeTarget(for: $0) } }
            .first ?? allTargets.first

        let arenaInitial = Array(allTargets.prefix(2))
        let conv = Conversation(
            title: Conversation.defaultTitle,
            isArenaMode: arenaMode && arenaInitial.count >= 2,
            primaryTarget: preferredPrimary,
            arenaTargets: arenaInitial
        )
        if let defaultPreset = presets.first {
            conv.applyPreset(defaultPreset)
        }
        modelContext.insert(conv)
        try? modelContext.save()
        navigationPath.append(conv)
    }
}
