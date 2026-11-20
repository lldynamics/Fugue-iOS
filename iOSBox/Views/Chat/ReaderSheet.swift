import SwiftUI
import SwiftData

struct ReaderSheet: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Environment(\.dismiss) private var dismiss
    let onConversation: (UUID) -> Void

    var body: some View {
        ReadingComposerView(input: ReadingInput(), models: entries, connection: { entry in
            guard let provider = providers.first(where: { $0.id == entry.target.providerID }),
                  provider.protocolType == entry.target.protocolType else { throw SystemEntryError.noModel }
            try provider.transmissionCheck(for: entry.target.modelID)()
            return SystemIntegration.connection(provider)
        }, persist: { receipt in
            // Main-app reader receipts use its private container; sharing need not be enabled.
            try localStore.save(receipt)
            if !receipt.isRunning { try ExternalReceiptImporter.drain(localStore, context: context) }
        }, close: { id in
            dismiss()
            if let id { onConversation(id) }
        })
    }

    private var entries: [SharedModelEntry] {
        providers.filter(\.isReadyForChat).flatMap { p in
            p.enabledModels.map { SharedModelEntry(target: p.makeTarget(for: $0), spec: $0, connectionID: p.id) }
        }
    }

    static var localStore: SystemEntryStore {
        SystemEntryStore(directory: URL.applicationSupportDirectory.appendingPathComponent("ReaderEntries", isDirectory: true))
    }
    private var localStore: SystemEntryStore { Self.localStore }
}
