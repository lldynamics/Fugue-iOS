import SwiftUI
import SwiftData

@MainActor @Observable
final class WorkspaceNavigation {
    var tab = 0
    var assistantSection: AssistantListView.WorkshopSection = .friends

    func openBookshelf() {
        assistantSection = .books
        tab = 1
    }
}

struct MainTabView: View {
    /// Shown once if the local database had to be rebuilt at launch.
    var startupNotice: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var integration = SystemIntegration.shared
    @State private var entryRouter = SystemEntryRouter.shared
    @State private var preferences = AppPreferences.shared
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var navigation = WorkspaceNavigation()
    @State private var pendingConversationToOpen: Conversation?
    @State private var pendingMessageRouteToOpen: ConversationMessageRoute?
    @State private var showStartupNotice = false
    @State private var hasSyncedSpotlightOnLaunch = false

    var body: some View {
        TabView(selection: $navigation.tab) {
            ConversationListView(
                pendingConversationToOpen: $pendingConversationToOpen,
                pendingMessageRoute: $pendingMessageRouteToOpen,
                selectSection: { navigation.tab = $0 }
            )
            .toolbar(horizontalSizeClass == .regular ? .hidden : .automatic, for: .tabBar)
            .tabItem {
                Label("对话", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(0)

            AssistantListView(activeSection: $navigation.assistantSection) { preset in
                startChat(with: preset)
            }
            .tabItem {
                Label("好友", systemImage: "person.2.fill")
            }
            .tag(1)

            ProviderListView()
                .tabItem {
                    Label(preferences.simpleDailyMode ? String(localized: "设置") : String(localized: "服务商"), systemImage: preferences.simpleDailyMode ? "gearshape.fill" : "server.rack")
                }
                .tag(2)

            if !preferences.simpleDailyMode {
                RequestLedgerView()
                    .tabItem { Label("用量", systemImage: "chart.bar.xaxis") }
                    .tag(3)
            }
        }
        .environment(navigation)
        .tint(preferences.accentTheme.tintColor)
        .onChange(of: preferences.simpleDailyMode) { _, isSimple in
            if isSimple && navigation.tab == 3 {
                navigation.tab = 2
            }
        }
        .onAppear {
            guard hasPersistentStore else { return }
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
            if hasPersistentStore { integration.refresh(context: modelContext) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("IOSBoxCredentialsChanged"))) { _ in
            if hasPersistentStore { integration.refresh(context: modelContext) }
        }
        .onChange(of: entryRouter.conversationID) { _, _ in openRoutedConversation() }
        .onChange(of: entryRouter.pendingQuickAction, initial: true) { _, action in
            if action != nil { navigation.tab = 0 }
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

    // An in-memory scene must not consume pending receipts or publish its temporary records to Spotlight.
    private var hasPersistentStore: Bool {
        modelContext.container.configurations.contains { !$0.isStoredInMemoryOnly }
    }

    private func refreshSystemEntries() {
        entryRouter.drainPendingInbox()
        if entryRouter.pendingQuickAction != nil {
            navigation.tab = 0
        }
        guard hasPersistentStore else { return }
        integration.refresh(context: modelContext)
        do {
            if let store = try? SystemEntryStore() { try ExternalReceiptImporter.drain(store, context: modelContext) }
            try ExternalReceiptImporter.drain(ReaderSheet.localStore, context: modelContext)
        } catch { integration.error = error.localizedDescription }
        if !hasSyncedSpotlightOnLaunch || SpotlightIndexService.shared.needsLegacyPreviewPurge {
            hasSyncedSpotlightOnLaunch = true
            SpotlightIndexService.shared.syncRecentConversations(in: modelContext)
        }
        WidgetSnapshotService.shared.sync(context: modelContext)
        openRoutedConversation()
    }

    private func openRoutedConversation() {
        guard let id = entryRouter.conversationID else { return }
        let targetMsgID = entryRouter.messageID
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        if let conversation = try? modelContext.fetch(descriptor).first {
            navigation.tab = 0
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
            primaryTarget: AppPreferences.shared.initialTarget(from: ready),
            arenaTargets: Array(ready.prefix(2))
        )
        conv.applyPreset(preset)
        modelContext.insert(conv)
        try? modelContext.save()

        navigation.tab = 0
        Task { @MainActor in
            await Task.yield()
            pendingConversationToOpen = conv
        }
    }
}
