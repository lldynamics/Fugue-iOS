import CoreSpotlight
import SwiftUI
import SwiftData

struct MainTabView: View {
    /// Shown once if the local database had to be rebuilt at launch.
    var startupNotice: String?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var integration = SystemIntegration.shared
    @State private var entryRouter = SystemEntryRouter.shared
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var selectedTab: Int = 0
    @State private var pendingConversationToOpen: Conversation?
    @State private var pendingMessageRouteToOpen: ConversationMessageRoute?
    @State private var showStartupNotice = false
    @State private var hasSyncedSpotlightOnLaunch = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ConversationListView(
                pendingConversationToOpen: $pendingConversationToOpen,
                pendingMessageRoute: $pendingMessageRouteToOpen
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

            RequestLedgerView()
                .tabItem { Label("用量", systemImage: "chart.bar.xaxis") }
                .tag(3)
        }
        .onAppear {
            DataSeeder.seedIfNeeded(context: modelContext)
            refreshSystemEntries()
            if activeStartupNotice != nil {
                showStartupNotice = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSystemEntries() }
        }
        .onChange(of: SystemIntegration.fingerprint(providers)) { _, _ in
            integration.refresh(context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("IOSBoxCredentialsChanged"))) { _ in
            integration.refresh(context: modelContext)
        }
        .onChange(of: entryRouter.conversationID) { _, _ in openRoutedConversation() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let parsed = SpotlightIndexService.parseIdentifier(raw) {
                entryRouter.messageID = parsed.messageID
                entryRouter.conversationID = parsed.conversationID
            }
        }
        .onOpenURL { url in
            guard url.scheme?.lowercased() == "iosbox",
                  url.host?.lowercased() == "conversation" else { return }
            let rawID = url.pathComponents.dropFirst().first ?? ""
            if let id = UUID(uuidString: rawID) {
                entryRouter.messageID = nil
                entryRouter.conversationID = id
            }
        }
        .alert("本地存储提示", isPresented: $showStartupNotice) {
            Button("知道了", role: .cancel) {
                PersistenceController.acknowledgePendingRebuildNotice()
            }
        } message: {
            Text(activeStartupNotice ?? "")
        }
    }

    private var activeStartupNotice: String? {
        startupNotice ?? PersistenceController.pendingRebuildNotice()
    }

    private func refreshSystemEntries() {
        integration.refresh(context: modelContext)
        do {
            if let store = try? SystemEntryStore() { try ExternalReceiptImporter.drain(store, context: modelContext) }
            try ExternalReceiptImporter.drain(ReaderSheet.localStore, context: modelContext)
        } catch { integration.error = error.localizedDescription }
        if !hasSyncedSpotlightOnLaunch {
            hasSyncedSpotlightOnLaunch = true
            SpotlightIndexService.shared.syncRecentConversations(in: modelContext)
        }
        openRoutedConversation()
    }

    private func openRoutedConversation() {
        guard let id = entryRouter.conversationID else { return }
        let targetMsgID = entryRouter.messageID
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        if let conversation = try? modelContext.fetch(descriptor).first {
            selectedTab = 0
            if let targetMsgID {
                pendingMessageRouteToOpen = ConversationMessageRoute(conversation: conversation, messageID: targetMsgID)
            } else {
                pendingConversationToOpen = conversation
            }
            entryRouter.conversationID = nil
            entryRouter.messageID = nil
        }
    }

    private func startChat(with preset: AssistantPreset) {
        let ready = ProviderConfig.readyTargets(in: providers)

        let conv = Conversation(
            title: preset.name,
            primaryTarget: ready.first,
            arenaTargets: Array(ready.prefix(2))
        )
        conv.applyPreset(preset)
        modelContext.insert(conv)
        try? modelContext.save()

        selectedTab = 0
        Task { @MainActor in
            await Task.yield()
            pendingConversationToOpen = conv
        }
    }
}
