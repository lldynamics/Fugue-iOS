import CoreSpotlight
import SwiftUI
import SwiftData

@main
struct iOSBoxApp: App {
    @UIApplicationDelegateAdaptor(PersonaRefreshDelegate.self) private var refreshDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var runtime: AppRuntime

    #if DEBUG && targetEnvironment(simulator)
    private let testingWorkspaces = ProcessInfo.processInfo.arguments.contains("-ui-test-workspaces")
    private let testingPicker = ProcessInfo.processInfo.arguments.contains("-ui-test-model-picker")
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if testingPicker || testingWorkspaces {
            let schema = Schema(versionedSchema: CurrentSchema.self)
            let container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            _runtime = State(initialValue: AppRuntime(store: .init(container: container, startupNotice: nil)))
            if testingWorkspaces { try! WorkspaceTestContent.insert(in: container.mainContext) }
            if let rawPort = ProcessInfo.processInfo.environment["UI_TEST_MODEL_PORT"], let port = UInt16(rawPort) {
                var model = ModelSpec(id: "fixture-chat")
                model.catalogStatus = .manual
                let provider = ProviderConfig(name: "Local Fixture", protocolType: .openAICompatible,
                                              baseURL: "http://127.0.0.1:\(port)/v1", isEnabled: false, models: [model])
                container.mainContext.insert(provider)
                try! container.mainContext.save()
            }
            return
        }
        #endif
        _runtime = State(initialValue: AppRuntime.shared)
        Task.detached(priority: .utility) {
            Self.cleanupExpiredTemporaryExports()
        }
    }

    /// Removes temporary backup, Markdown, image, and Anki export files left in `tmp/` after prior share sheets.
    nonisolated static func cleanupExpiredTemporaryExports(
        in directory: URL = FileManager.default.temporaryDirectory,
        maxAge: TimeInterval = 2 * 3600,
        now: Date = Date()
    ) {
        let managedPrefixes = [
            "Fugue_Backup_",
            "Fugue-EncryptedBackup-",
            "Fugue-AnkiCards-",
            "Fugue-Artifact-",
            "Fugue_",
            "iOSBox_Backup_",
            "iOSBox-EncryptedBackup-",
            "iOSBox-AnkiCards-",
            "iOSBox-Artifact-",
            "iOSBox_"
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            let name = url.lastPathComponent
            guard managedPrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= maxAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }

        let exportsDir = directory.appendingPathComponent(ConversationExporter.exportsSubdirectoryName, isDirectory: true)
        if let exportedFiles = try? FileManager.default.contentsOfDirectory(
            at: exportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in exportedFiles {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true || (values.isDirectory == true && UUID(uuidString: url.lastPathComponent) != nil),
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) >= maxAge else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG && targetEnvironment(simulator)
                if testingPicker {
                    ConversationListView(pendingConversationToOpen: .constant(nil))
                } else if testingWorkspaces {
                    MainTabView()
                } else { appContent }
            #else
                appContent
            #endif
            }
            .modelContainer(runtime.store.container)
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                   let parsed = SpotlightIndexService.parseIdentifier(raw) {
                    SystemEntryRouter.shared.messageID = parsed.messageID
                    SystemEntryRouter.shared.conversationID = parsed.conversationID
                }
            }
            .onOpenURL { url in
                SystemEntryRouter.shared.route(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: QuickEntryInbox.didReceiveActionNotification)) { _ in
                SystemEntryRouter.shared.drainPendingInbox()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                runtime.retryStorageIfAvailable()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            #if DEBUG && targetEnvironment(simulator)
            if testingPicker || testingWorkspaces { return }
            #endif
            if newPhase == .active {
                runtime.retryStorageIfAvailable()
                SystemEntryRouter.shared.drainPendingInbox()
            } else if newPhase == .background {
                let context = runtime.store.container.mainContext
                guard PersistenceController.canCommitUserData(in: context) else { return }
                try? context.save()
                PersonaRefreshDelegate.schedule(in: context)
                WidgetSnapshotService.shared.sync(context: context)
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
        let store = runtime.store
        if PersistenceController.canCommitUserData(in: store.container.mainContext) {
            MainTabView(startupNotice: store.startupNotice)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        _ = await PersonaFeedService.shared.refresh(in: store.container.mainContext)
                        do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    }
                }
        } else {
            ContentUnavailableView {
                Label("本地数据库暂不可用", systemImage: "lock")
            } description: {
                Text(verbatim: store.startupNotice ?? "")
            } actions: {
                Button("重试") { runtime.retryStorageIfAvailable() }
            }
        }
    }
}
