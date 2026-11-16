import SwiftUI
import SwiftData

@main
struct iOSBoxApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ProviderConfig.self,
            AssistantPreset.self,
            Conversation.self,
            ChatMessage.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            // Runs exactly once per process, before any UI or generation exists.
            InterruptedStreamRecovery.run(in: container)
            return container
        } catch {
            fatalError("无法初始化本地数据库 ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            MainTabView()
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
