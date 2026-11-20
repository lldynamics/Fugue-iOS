import SwiftUI
import SwiftData

@main
struct iOSBoxApp: App {
    @UIApplicationDelegateAdaptor(PersonaRefreshDelegate.self) private var refreshDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let sharedModelContainer: ModelContainer
    private let startupNotice: String?

    #if DEBUG && targetEnvironment(simulator)
    private let testingPicker = ProcessInfo.processInfo.arguments.contains("-ui-test-model-picker")
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if testingPicker {
            let schema = Schema(versionedSchema: CurrentSchema.self)
            sharedModelContainer = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            startupNotice = nil
            if let rawPort = ProcessInfo.processInfo.environment["UI_TEST_MODEL_PORT"], let port = UInt16(rawPort) {
                var model = ModelSpec(id: "fixture-chat")
                model.catalogStatus = .manual
                let provider = ProviderConfig(name: "Local Fixture", protocolType: .openAICompatible,
                                              baseURL: "http://127.0.0.1:\(port)/v1", isEnabled: false, models: [model])
                sharedModelContainer.mainContext.insert(provider)
                try! sharedModelContainer.mainContext.save()
            }
            return
        }
        #endif
        let result = AppRuntime.persistence
        sharedModelContainer = result.container
        startupNotice = result.startupNotice
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
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in exportedFiles {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) >= maxAge else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if testingPicker {
                ConversationListView(pendingConversationToOpen: .constant(nil))
            } else { appContent }
            #else
            appContent
            #endif
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            // Persist any streamed-but-unsaved content before the app may be suspended.
            if newPhase == .background {
                try? sharedModelContainer.mainContext.save()
                PersonaRefreshDelegate.schedule(in: sharedModelContainer.mainContext)
            }
        }
    }

    private var appContent: some View {
        MainTabView(startupNotice: startupNotice)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    _ = await PersonaFeedService.shared.refresh(in: sharedModelContainer.mainContext)
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                }
            }
    }
}
