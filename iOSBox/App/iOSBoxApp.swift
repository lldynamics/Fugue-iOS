import CoreSpotlight
import SwiftUI
import SwiftData
import UIKit

@MainActor
final class MultiSceneLockShieldCoordinator {
    static let shared = MultiSceneLockShieldCoordinator()

    private var sceneWindows: [ObjectIdentifier: UIWindow] = [:]
    private var isVisible = false
    private weak var activeController: AppLockController?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let windowScene = notification.object as? UIWindowScene else { return }
            MainActor.assumeIsolated {
                self?.syncWindow(for: windowScene)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let windowScene = notification.object as? UIWindowScene else { return }
            MainActor.assumeIsolated {
                self?.syncWindow(for: windowScene)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let windowScene = notification.object as? UIWindowScene else { return }
            MainActor.assumeIsolated {
                self?.removeWindow(for: windowScene)
            }
        }
    }

    var mountedWindowCount: Int {
        sceneWindows.values.filter { !$0.isHidden }.count
    }

    @discardableResult
    func update(visible: Bool, controller: AppLockController) -> Bool {
        isVisible = visible
        activeController = controller
        // Ensure legacy single-scene presenter window stays hidden so we never double-mount overlays.
        AppLockWindowPresenter.shared.update(visible: false, controller: controller)

        let connectedWindowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let validSceneIDs = Set(connectedWindowScenes.map(ObjectIdentifier.init))
        for staleID in sceneWindows.keys where !validSceneIDs.contains(staleID) {
            if let old = sceneWindows.removeValue(forKey: staleID) {
                old.isHidden = true
                old.rootViewController = nil
            }
        }

        for scene in connectedWindowScenes {
            syncWindow(for: scene)
        }
        return mountedWindowCount > 0
    }

    private func syncWindow(for scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        if isVisible, let controller = activeController {
            let overlay: UIWindow
            if let existing = sceneWindows[key], existing.windowScene === scene {
                overlay = existing
                if let hosting = overlay.rootViewController as? UIHostingController<AppLockOverlayView> {
                    hosting.rootView = AppLockOverlayView(controller: controller)
                }
            } else {
                let hosting = UIHostingController(rootView: AppLockOverlayView(controller: controller))
                hosting.view.backgroundColor = .clear
                let created = UIWindow(windowScene: scene)
                created.rootViewController = hosting
                created.windowLevel = .alert + 5
                created.backgroundColor = .clear
                sceneWindows[key] = created
                overlay = created
            }
            overlay.isHidden = false
            if scene.activationState == .foregroundActive || scene.windows.contains(where: \.isKeyWindow) {
                overlay.makeKeyAndVisible()
            }
        } else if let existing = sceneWindows[key] {
            let wasKey = existing.isKeyWindow
            existing.isHidden = true
            if wasKey {
                existing.resignKey()
                scene.windows.first(where: { $0 !== existing && !$0.isHidden })?.makeKey()
            }
        }
    }

    private func removeWindow(for scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        if let existing = sceneWindows.removeValue(forKey: key) {
            existing.isHidden = true
            existing.rootViewController = nil
        }
    }
}

@main
struct iOSBoxApp: App {
    @UIApplicationDelegateAdaptor(PersonaRefreshDelegate.self) private var refreshDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var runtime: AppRuntime
    @State private var lockController = AppLockController.shared

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
            if testingWorkspaces && !ProcessInfo.processInfo.arguments.contains("-ui-test-empty-workspace") {
                try! WorkspaceTestContent.insert(in: container.mainContext)
            }
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
        AppLockController.shared.handleLaunch()
        SystemEntryRouter.shared.setLocked(AppLockController.shared.isLocked)
        Task.detached(priority: .utility) {
            Self.cleanupExpiredTemporaryExports()
        }
    }

    /// Removes temporary backup, Markdown, diagram, and image export files left in `tmp/` after prior share sheets.
    nonisolated static func cleanupExpiredTemporaryExports(
        in directory: URL = FileManager.default.temporaryDirectory,
        maxAge: TimeInterval = 2 * 3600,
        now: Date = Date()
    ) {
        let managedPrefixes = [
            "Fugue_Backup_",
            "Fugue-EncryptedBackup-",
            "Fugue-Artifact-",
            "Fugue-Diagram-",
            "Fugue_",
            "iOSBox_Backup_",
            "iOSBox-EncryptedBackup-",
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
                        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-ui-test-dark-appearance") ? .dark : nil)
                } else { appContent }
            #else
                appContent
            #endif
            }
            .modelContainer(runtime.store.container)
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                   let parsed = SpotlightIndexService.parseIdentifier(raw) {
                    SystemEntryRouter.shared.routeSpotlight(
                        conversationID: parsed.conversationID,
                        messageID: parsed.messageID
                    )
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
            lockController.handleScenePhaseChange(newPhase)
            SystemEntryRouter.shared.setLocked(lockController.isLocked)
            if newPhase == .active {
                runtime.retryStorageIfAvailable()
                SystemEntryRouter.shared.drainPendingInbox()
                if !lockController.isLocked {
                    let context = runtime.store.container.mainContext
                    Task {
                        await WebDAVAutoSyncCoordinator.shared.syncIfNeeded(trigger: .foreground, context: context)
                    }
                }
            } else if newPhase == .background {
                let context = runtime.store.container.mainContext
                guard PersistenceController.canCommitUserData(in: context) else { return }
                try? context.save()
                PersonaRefreshDelegate.schedule(in: context)
                WidgetSnapshotService.shared.sync(context: context)
                Task {
                    await WebDAVAutoSyncCoordinator.shared.syncIfNeeded(trigger: .background, context: context)
                }
            }
        }
        .onChange(of: lockController.isLocked, initial: true) { wasLocked, isLocked in
            #if DEBUG && targetEnvironment(simulator)
            if testingPicker || testingWorkspaces { return }
            #endif
            SystemEntryRouter.shared.setLocked(isLocked)
            if wasLocked && !isLocked && scenePhase == .active {
                let context = runtime.store.container.mainContext
                Task {
                    await WebDAVAutoSyncCoordinator.shared.syncIfNeeded(trigger: .foreground, context: context)
                }
            }
        }
        .onChange(of: AppPreferences.shared.appLockEnabled, initial: true) { _, lockEnabled in
            #if DEBUG && targetEnvironment(simulator)
            if testingPicker || testingWorkspaces { return }
            #endif
            let context = runtime.store.container.mainContext
            SpotlightIndexService.shared.handleAppLockChange(
                lockEnabled: lockEnabled,
                in: PersistenceController.canCommitUserData(in: context) ? context : nil
            )
            LiveActivityCoordinator.shared.handleAppLockChange(lockEnabled: lockEnabled)
            if PersistenceController.canCommitUserData(in: context) {
                WidgetSnapshotService.shared.sync(context: context, forceReload: true)
            }
        }
    }

    @State private var hasMountedSceneLockWindow = false

    @ViewBuilder
    private var appContent: some View {
        let store = runtime.store
        let shouldShowLockOverlay = lockController.isLocked || lockController.isPrivacyShieldVisible
        ZStack {
            Group {
                if PersistenceController.canCommitUserData(in: store.container.mainContext) {
                    MainTabView(startupNotice: store.startupNotice)
                        .task(id: "\(scenePhase)-\(lockController.isLocked)") {
                            guard scenePhase == .active, !lockController.isLocked else { return }
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
            .opacity(shouldShowLockOverlay ? 0 : 1)
            .allowsHitTesting(!shouldShowLockOverlay)
            .accessibilityHidden(shouldShowLockOverlay)

            // Only render inline fallback if no UIWindowScene shield window is currently attached,
            // avoiding duplicate interactive Face ID overlays in the same scene.
            if shouldShowLockOverlay && !hasMountedSceneLockWindow {
                AppLockOverlayView(controller: lockController)
            }
        }
        .onChange(of: shouldShowLockOverlay, initial: true) { _, visible in
            hasMountedSceneLockWindow = MultiSceneLockShieldCoordinator.shared.update(
                visible: visible,
                controller: lockController
            )
        }
    }
}
