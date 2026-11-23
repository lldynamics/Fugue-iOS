import SwiftUI
import SwiftData

struct ModelCatalogRequest: Equatable {
    let protocolType: APIProtocolType
    let baseURL: String
    var apiKey: String
    var extraKeys: [String] = []
    var headers: [CustomHeader] = []

    static func saved(for provider: ProviderConfig) -> Self {
        Self(protocolType: provider.protocolType, baseURL: provider.baseURL,
             apiKey: provider.apiKey,
             extraKeys: provider.extraAPIKeys, headers: provider.resolvedCustomHeaders)
    }

    var canFetch: Bool {
        guard let url = try? EndpointResolver.modelsEndpoint(baseURL: baseURL, protocolType: protocolType),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != "api.example.com" else { return false }
        return !NetworkLocation.isPlainHTTPToPublicHost(baseURL: baseURL)
    }

    var fetchOnOpen: Bool {
        canFetch && (!apiKey.isEmpty || !extraKeys.isEmpty || headers.contains { $0.isEnabled && !$0.value.isEmpty }
                     || NetworkLocation.isLocalOrPrivate(baseURL: baseURL) || OpenAICompatibleAdapter.isOpenRouter(baseURL))
    }

    func fetch() async throws -> [ModelSpec] {
        try await LLMClient.fetchModels(providerName: "", protocolType: protocolType, baseURL: baseURL, apiKey: apiKey,
                                        apiKeys: extraKeys, customHeaders: headers)
    }
}

@MainActor @Observable
final class ProviderModelCatalog {
    private(set) var lastRequest: ModelCatalogRequest?
    private(set) var models: [ModelSpec]?
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        lastRequest = nil
        models = nil
        isLoading = false
        error = nil
    }

    @discardableResult
    func refresh(request: ModelCatalogRequest, load: @escaping (ModelCatalogRequest) async throws -> [ModelSpec] = { try await $0.fetch() },
                 onSuccess: @escaping ([ModelSpec]) throws -> Void = { _ in }) -> Task<Void, Never>? {
        guard request.canFetch else { return nil }
        task?.cancel()
        lastRequest = request
        isLoading = true
        error = nil
        task = Task {
            do {
                let fetched = ProviderConfig.deduplicated(try await load(request))
                try Task.checkCancellation()
                try onSuccess(fetched)
                models = fetched
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
            task = nil
        }
        return task
    }

    /// Saved order is the account's preference order. Discovery only changes availability.
    static func merging(_ fetched: [ModelSpec], with saved: [ModelSpec], choosing selected: String? = nil,
                        fromAPI: Bool = true) -> [ModelSpec] {
        let catalog = ProviderConfig.deduplicated(fetched)
        let live = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var result = ProviderConfig.deduplicated(saved).map { saved -> ModelSpec in
            var item = saved
            if fromAPI && item.catalogStatus != .manual {
                item.catalogStatus = live[item.id] == nil ? .unlisted : .listed
                if let discovered = live[item.id] {
                    item.retiredStarterDefault = nil
                    if item.displayName == item.id { item.displayName = discovered.displayName }
                }
            }
            return item
        }
        let savedIDs = Set(result.map(\.id))
        for var item in catalog where !savedIDs.contains(item.id) {
            item.isEnabled = false
            if fromAPI { item.catalogStatus = .listed }
            result.append(item)
        }
        if let selected, !selected.isEmpty {
            var spec = ModelSpec(id: selected)
            if let index = result.firstIndex(where: { $0.id == selected }) { spec = result.remove(at: index) }
            if fromAPI && live[selected] == nil { spec.catalogStatus = .manual }
            spec.isEnabled = true
            result.insert(spec, at: 0)
        }
        return result
    }

    @discardableResult
    static func save(_ fetched: [ModelSpec], to provider: ProviderConfig, in context: ModelContext) throws -> Int {
        let previous = provider.models
        let merged = merging(fetched, with: previous)
        guard merged != previous else { return 0 }
        provider.models = merged
        do { try context.save() } catch {
            provider.models = previous
            throw error
        }
        return merged.count - previous.count
    }
}

/// Share a conversation's directory requests between its initial selection and its model picker.
@MainActor @Observable
final class ChatModelDirectory {
    private(set) var catalogs: [UUID: ProviderModelCatalog] = [:]

    func update(configured providers: [ProviderConfig], automaticIDs: Set<UUID>? = nil, in context: ModelContext) {
        let available = providers.filter(\.hasConfiguredChatAPI)
        let ids = Set(available.map(\.id))
        for id in Array(catalogs.keys) where !ids.contains(id) { catalogs.removeValue(forKey: id)?.reset() }
        for provider in available {
            let request = ModelCatalogRequest.saved(for: provider)
            guard catalogs[provider.id]?.lastRequest != request else { continue }
            catalogs.removeValue(forKey: provider.id)?.reset()
            guard automaticIDs?.contains(provider.id) != false else { continue }
            let models = provider.models
            // Explicit deployments also work with gateways without a directory endpoint.
            if models.isEmpty || models.contains(where: { $0.isEnabled && $0.catalogStatus != .manual }) {
                refresh(provider, request: request, in: context)
            }
        }
    }

    func refresh(_ provider: ProviderConfig, in context: ModelContext) {
        guard provider.hasConfiguredChatAPI else { return }
        refresh(provider, request: .saved(for: provider), in: context)
    }

    private func refresh(_ provider: ProviderConfig, request: ModelCatalogRequest, in context: ModelContext) {
        let catalog = catalogs[provider.id] ?? ProviderModelCatalog()
        catalogs[provider.id] = catalog
        catalog.refresh(request: request, onSuccess: { models in
            guard provider.modelContext != nil, provider.hasConfiguredChatAPI,
                  ModelCatalogRequest.saved(for: provider) == request else { throw CancellationError() }
            try ProviderModelCatalog.save(models, to: provider, in: context)
        })
    }

    func reset() {
        for catalog in catalogs.values { catalog.reset() }
        catalogs.removeAll()
    }
}

struct ModelCatalogRefreshButton: View {
    let catalog: ProviderModelCatalog
    let request: ModelCatalogRequest
    let refresh: () -> Void

    var body: some View {
        Button(action: refresh) {
            if catalog.isLoading {
                HStack { ProgressView(); Text("正在获取模型…") }
            } else {
                Label("从接口获取模型", systemImage: "arrow.clockwise")
            }
        }
        .disabled(!request.canFetch || catalog.isLoading)
        if let error = catalog.error {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
    }
}

struct ModelCatalogPicker: View {
    let catalog: ProviderModelCatalog
    let request: ModelCatalogRequest
    let fallback: [ModelSpec]
    let fallbackTitle: LocalizedStringKey
    let selected: String
    let refresh: () -> Void
    let choose: (ModelSpec) -> Void
    @State private var showing = false
    @State private var search = ""

    var body: some View {
        Button {
            search = ""
            showing = true
            if request.fetchOnOpen && catalog.models == nil && !catalog.isLoading { refresh() }
        } label: {
            HStack(spacing: 8) {
                Text("使用模型")
                Spacer()
                let name = (catalog.models ?? []).first { $0.id == selected }?.displayName
                    ?? fallback.first { $0.id == selected }?.displayName
                Group {
                    if let name { Text(verbatim: name) } else if !selected.isEmpty { Text(verbatim: selected) } else { Text("选择模型") }
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            NavigationStack {
                List {
                    Section { ModelCatalogRefreshButton(catalog: catalog, request: request, refresh: refresh) }
                    if let live = catalog.models {
                        Section("接口返回的模型") { rows(live) }
                    } else if !catalog.isLoading {
                        Section(fallbackTitle) { rows(fallback) }
                    }
                }
                .searchable(text: $search, prompt: "搜索模型名称或 ID")
                .navigationTitle("选择模型")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showing = false } } }
            }
        }
    }

    @ViewBuilder private func rows(_ models: [ModelSpec]) -> some View {
        let filtered = models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)
            || $0.displayName.localizedCaseInsensitiveContains(search) }
        if filtered.isEmpty {
            if search.isEmpty {
                Text("可从接口获取模型，或返回手动输入模型 ID。").foregroundStyle(.secondary)
            } else {
                Text("没有匹配的模型").foregroundStyle(.secondary)
            }
        }
        ForEach(filtered) { model in
            Button {
                choose(model)
                showing = false
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: model.displayName).foregroundStyle(.primary)
                        if model.displayName != model.id {
                            Text(verbatim: model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.id == selected { Image(systemName: "checkmark") }
                }
            }
        }
    }
}
