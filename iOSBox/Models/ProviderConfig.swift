import Foundation
import SwiftData

@Model
final class ProviderConfig {
    @Attribute(.unique) var id: UUID
    var name: String
    var protocolRaw: String
    var baseURL: String
    var iconSymbol: String
    var accentHex: String
    var isEnabled: Bool
    var sortOrder: Int
    var modelsData: Data
    var headersData: Data
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        protocolType: APIProtocolType,
        baseURL: String,
        iconSymbol: String = "server.rack",
        accentHex: String = "#3F6EF6",
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        models: [ModelSpec] = [],
        customHeaders: [CustomHeader] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.protocolRaw = protocolType.rawValue
        self.baseURL = baseURL
        self.iconSymbol = iconSymbol
        self.accentHex = accentHex
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.modelsData = (try? JSONEncoder().encode(Self.deduplicated(models))) ?? Data()
        self.headersData = (try? JSONEncoder().encode(customHeaders)) ?? Data()
        self.notes = notes
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var protocolType: APIProtocolType {
        get { APIProtocolType(rawValue: protocolRaw) ?? .openAICompatible }
        set {
            protocolRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    /// Always unique by `id`: duplicates (from older data or remote lists) would crash
    /// `Dictionary(uniqueKeysWithValues:)` and confuse `ForEach` identity.
    var models: [ModelSpec] {
        get {
            guard !modelsData.isEmpty else { return [] }
            let decoded = (try? JSONDecoder().decode([ModelSpec].self, from: modelsData)) ?? []
            return Self.deduplicated(decoded)
        }
        set {
            modelsData = (try? JSONEncoder().encode(Self.deduplicated(newValue))) ?? Data()
            updatedAt = Date()
        }
    }

    /// Keeps the first occurrence of each model ID, preserving order.
    static func deduplicated(_ specs: [ModelSpec]) -> [ModelSpec] {
        var seen = Set<String>()
        return specs.filter { seen.insert($0.id).inserted }
    }

    var enabledModels: [ModelSpec] {
        models.filter(\.isEnabled)
    }

    var customHeaders: [CustomHeader] {
        get {
            guard !headersData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([CustomHeader].self, from: headersData)) ?? []
        }
        set {
            headersData = (try? JSONEncoder().encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }

    func makeTarget(for spec: ModelSpec) -> ResolvedModelTarget {
        ResolvedModelTarget(
            providerID: id,
            providerName: name,
            protocolType: protocolType,
            modelID: spec.id,
            modelDisplayName: spec.displayName,
            accentHex: accentHex,
            supportsVision: spec.supportsVision,
            supportsReasoning: spec.supportsReasoning
        )
    }
}
