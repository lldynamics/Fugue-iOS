import SwiftUI
import SwiftData

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var selectedTab: Int = 0
    @State private var pendingConversationToOpen: Conversation?

    var body: some View {
        TabView(selection: $selectedTab) {
            ConversationListView(
                selectedTab: $selectedTab,
                pendingConversationToOpen: $pendingConversationToOpen
            )
            .tabItem {
                Label("对话", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(0)

            AssistantListView { preset in
                startChat(with: preset)
            }
            .tabItem {
                Label("助手", systemImage: "sparkles.rectangle.stack.fill")
            }
            .tag(1)

            ProviderListView()
                .tabItem {
                    Label("服务商", systemImage: "server.rack")
                }
                .tag(2)
        }
        .onAppear {
            DataSeeder.seedIfNeeded(context: modelContext)
        }
    }

    private func startChat(with preset: AssistantPreset) {
        let allTargets = ChatEngine.shared.availableTargets(from: providers)
        let preferred = providers
            .filter { $0.isEnabled && KeychainService.shared.hasAPIKey(for: $0.id) }
            .flatMap { p in p.enabledModels.map { p.makeTarget(for: $0) } }
            .first ?? allTargets.first

        let conv = Conversation(
            title: preset.name,
            primaryTarget: preferred,
            arenaTargets: Array(allTargets.prefix(2))
        )
        conv.applyPreset(preset)
        modelContext.insert(conv)
        try? modelContext.save()

        selectedTab = 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            pendingConversationToOpen = conv
        }
    }
}
