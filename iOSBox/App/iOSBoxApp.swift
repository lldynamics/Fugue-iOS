import SwiftUI
import SwiftData

@main
struct iOSBoxApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let sharedModelContainer: ModelContainer
    private let startupNotice: String?

    init() {
        let result = PersistenceController.makeContainer()
        sharedModelContainer = result.container
        startupNotice = result.startupNotice
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(startupNotice: startupNotice)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            // Persist any streamed-but-unsaved content before the app may be suspended.
            if newPhase == .background {
                try? sharedModelContainer.mainContext.save()
            }
        }
    }
}
