import AppIntents
import SwiftData

struct ModelEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "AI 模型"
    static var defaultQuery = ModelEntityQuery()
    var id: String
    var name: String
    var provider: String
    var supportsVision: Bool
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(provider)")
    }
}

struct ModelEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ModelEntity] {
        let ready = try await all()
        return identifiers.map { id in
            ready.first { $0.id == id }
                ?? ModelEntity(id: id, name: String(localized: "模型暂不可用"), provider: "", supportsVision: false)
        }
    }
    func entities(matching string: String) async throws -> [ModelEntity] {
        try await all().filter { ($0.name + " " + $0.provider).localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [ModelEntity] { try await all() }

    @MainActor private func all() throws -> [ModelEntity] {
        let context = AppRuntime.persistence.container.mainContext
        DataSeeder.seedIfNeeded(context: context)
        let providers = try context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))
        return ProviderConfig.readyTargets(in: providers).map {
            ModelEntity(id: $0.id, name: $0.modelDisplayName, provider: $0.providerName, supportsVision: $0.supportsVision)
        }
    }
}
