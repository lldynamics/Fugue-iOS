import SwiftUI
import SwiftData
import UIKit

extension Notification.Name {
    static let fugueOpenCommandPalette = Notification.Name("FugueOpenCommandPalette")
    static let fugueToggleInspector = Notification.Name("FugueToggleInspector")
    static let fugueCreateNewChat = Notification.Name("FugueCreateNewChat")
    static let fugueSwitchPadSpace = Notification.Name("FugueSwitchPadSpace")
}

@MainActor @Observable
final class WorkspaceNavigation {
    enum ModalDestination: String, Identifiable {
        case workshop
        case settings
        case usage

        var id: String { rawValue }
    }

    enum PadSpace: String, CaseIterable, Hashable, Identifiable {
        case chat
        case bookshelf
        case friends
        case workshop
        case settings
        case usage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chat: return String(localized: "对话")
            case .bookshelf: return String(localized: "书架")
            case .friends: return String(localized: "好友")
            case .workshop: return String(localized: "工作台")
            case .settings: return String(localized: "设置")
            case .usage: return String(localized: "用量")
            }
        }

        var symbol: String {
            switch self {
            case .chat: return "bubble.left.and.bubble.right"
            case .bookshelf: return "books.vertical"
            case .friends: return "person.2"
            case .workshop: return "square.grid.2x2"
            case .settings: return "gearshape"
            case .usage: return "chart.bar.xaxis"
            }
        }
    }

    var assistantSection: AssistantListView.WorkshopSection = .friends
    var padSpace: PadSpace = .chat
    var isDrawerPresented = false
    var isCommandPalettePresented = false
    var activeModal: ModalDestination?

    private var usesPadSpaces: Bool {
        UIDevice.current.userInterfaceIdiom != .phone
    }

    func openChat() {
        padSpace = .chat
        isDrawerPresented = false
        activeModal = nil
    }

    func openWorkshop(_ section: AssistantListView.WorkshopSection? = nil) {
        if let section {
            assistantSection = section
        }
        isDrawerPresented = false
        if usesPadSpaces {
            activeModal = nil
            switch section {
            case .books:
                padSpace = .bookshelf
            case .friends:
                padSpace = AppPreferences.shared.showsBookFriends ? .friends : .workshop
            default:
                padSpace = .workshop
            }
        } else {
            activeModal = .workshop
        }
    }

    func openFriends() {
        isDrawerPresented = false
        if usesPadSpaces {
            activeModal = nil
            padSpace = AppPreferences.shared.showsBookFriends ? .friends : .workshop
        } else {
            assistantSection = .friends
            activeModal = .workshop
        }
    }

    func openSettings() {
        isDrawerPresented = false
        if usesPadSpaces {
            activeModal = nil
            padSpace = .settings
        } else {
            activeModal = .settings
        }
    }

    func openUsage() {
        isDrawerPresented = false
        if usesPadSpaces {
            activeModal = nil
            padSpace = .usage
        } else {
            activeModal = .usage
        }
    }

    func closeModal() {
        activeModal = nil
        if usesPadSpaces && padSpace != .chat {
            padSpace = .chat
        }
    }

    func openBookshelf() {
        openWorkshop(.books)
    }

    func routeLegacySection(_ index: Int) {
        switch index {
        case 1: openWorkshop()
        case 2: openSettings()
        case 3: openUsage()
        default:
            openChat()
        }
    }
}

struct MainTabView: View {
    /// Shown once if the local database had to be rebuilt at launch.
    var startupNotice: String?

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
        ConversationListView(
            pendingConversationToOpen: $pendingConversationToOpen,
            pendingMessageRoute: $pendingMessageRouteToOpen,
            selectSection: { navigation.routeLegacySection($0) },
            onStartChatWithPreset: { startChat(with: $0) }
        )
        .environment(navigation)
        .tint(preferences.accentTheme.tintColor)
        .background(DS.Surface.canvas.ignoresSafeArea())
        .sheet(item: $navigation.activeModal) { destination in
            switch destination {
            case .workshop:
                AssistantListView(
                    activeSection: $navigation.assistantSection,
                    onClose: { navigation.closeModal() }
                ) { preset in
                    startChat(with: preset)
                }
                .environment(navigation)
                .tint(preferences.accentTheme.tintColor)

            case .settings:
                ProviderListView(onClose: { navigation.closeModal() })
                    .environment(navigation)
                    .tint(preferences.accentTheme.tintColor)

            case .usage:
                RequestLedgerView(onClose: { navigation.closeModal() })
                    .environment(navigation)
                    .tint(preferences.accentTheme.tintColor)

            }
        }
        .onChange(of: preferences.showsUsageTab) { _, shows in
            if !shows && navigation.activeModal == .usage {
                navigation.activeModal = .settings
            }
            if !shows && navigation.padSpace == .usage {
                navigation.padSpace = .settings
            }
        }
        .onChange(of: preferences.showsBookFriends) { _, shows in
            if !shows && navigation.padSpace == .friends {
                navigation.padSpace = .chat
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fugueSwitchPadSpace)) { notification in
            guard UIDevice.current.userInterfaceIdiom != .phone,
                  let raw = notification.object as? String,
                  let space = WorkspaceNavigation.PadSpace(rawValue: raw) else { return }
            switch space {
            case .chat: navigation.openChat()
            case .bookshelf: navigation.openBookshelf()
            case .friends: navigation.openFriends()
            case .workshop: navigation.openWorkshop()
            case .settings: navigation.openSettings()
            case .usage:
                if preferences.showsUsageTab { navigation.openUsage() } else { navigation.openSettings() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fugueOpenCommandPalette)) { _ in
            guard UIDevice.current.userInterfaceIdiom != .phone else { return }
            navigation.isCommandPalettePresented.toggle()
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
            if action != nil {
                navigation.openChat()
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

    // An in-memory scene must not consume pending receipts or publish its temporary records to Spotlight.
    private var hasPersistentStore: Bool {
        modelContext.container.configurations.contains { !$0.isStoredInMemoryOnly }
    }

    private func refreshSystemEntries() {
        entryRouter.drainPendingInbox()
        if entryRouter.pendingQuickAction != nil {
            navigation.openChat()
        }
        guard hasPersistentStore else { return }
        integration.refresh(context: modelContext)
        do {
            if let store = try? SystemEntryStore() { try ExternalReceiptImporter.drain(store, context: modelContext) }
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
            navigation.openChat()
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

        navigation.openChat()
        Task { @MainActor in
            await Task.yield()
            pendingConversationToOpen = conv
        }
    }
}
