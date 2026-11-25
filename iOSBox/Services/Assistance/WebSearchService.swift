import Foundation

enum WebSearchProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case tavily
    case brave
    case exa
    case searxng

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tavily: return "Tavily"
        case .brave: return "Brave Search"
        case .exa: return "Exa"
        case .searxng: return String(localized: "SearXNG（自建）")
        }
    }

    var keychainAccount: String {
        switch self {
        case .tavily: return TavilySearchClient.keychainAccount
        case .brave: return "search/brave"
        case .exa: return "search/exa"
        case .searxng: return "search/searxng"
        }
    }

    var requiresAPIKey: Bool {
        self != .searxng
    }

    var consoleURL: URL? {
        switch self {
        case .tavily: return URL(string: "https://app.tavily.com")
        case .brave: return URL(string: "https://api.search.brave.com")
        case .exa: return URL(string: "https://dashboard.exa.ai")
        case .searxng: return URL(string: "https://docs.searxng.org")
        }
    }

    var ledgerProviderID: UUID {
        switch self {
        case .tavily: return TavilySearchClient.providerID
        case .brave: return UUID(uuidString: "A56C061D-E51A-49AA-81EC-0E6CFABF73B1")!
        case .exa: return UUID(uuidString: "B56C061D-E51A-49AA-81EC-0E6CFABF73E2")!
        case .searxng: return UUID(uuidString: "C56C061D-E51A-49AA-81EC-0E6CFABF73S3".replacingOccurrences(of: "S", with: "5"))!
        }
    }
}

enum WebSearchService {
    static let providerDefaultsKey = "iosbox.pref.webSearchProvider"
    static let searxngBaseURLDefaultsKey = "iosbox.pref.searxngBaseURL"
    static let jinaFallbackDefaultsKey = "iosbox.pref.jinaReaderFallbackEnabled"
    static let jinaKeychainAccount = "search/jina"
    static let maximumBytes = 1_048_576

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func activeProvider(defaults: UserDefaults = .standard) -> WebSearchProvider {
        guard let raw = defaults.string(forKey: providerDefaultsKey),
              let parsed = WebSearchProvider(rawValue: raw) else {
            return .tavily
        }
        return parsed
    }

    static func activeLedgerTarget(defaults: UserDefaults = .standard) -> ResolvedModelTarget {
        let provider = activeProvider(defaults: defaults)
        if provider == .tavily { return TavilySearchClient.ledgerTarget }
        return ResolvedModelTarget(
            providerID: provider.ledgerProviderID,
            providerName: provider.displayName,
            protocolType: .openAICompatible,
            modelID: "web-search",
            modelDisplayName: "\(provider.displayName) Search",
            accentHex: "#408060",
            supportsVision: false,
            supportsReasoning: false
        )
    }

    static func isConfigured(
        provider: WebSearchProvider? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let chosen = provider ?? activeProvider(defaults: defaults)
        switch chosen {
        case .tavily, .brave, .exa:
            return !KeychainService.shared.loadSecret(account: chosen.keychainAccount).isEmpty
        case .searxng:
            let base = defaults.string(forKey: searxngBaseURLDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return validateSearXNGBaseURL(base) != nil
        }
    }

    static func validateSearXNGBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        if NetworkLocation.isPlainHTTPToPublicHost(baseURL: trimmed) {
            return nil
        }
        return url
    }

    static func search(
        query: String,
        provider: WebSearchProvider? = nil,
        defaults: UserDefaults = .standard,
        session: URLSession? = nil
    ) async throws -> SearchEvidence {
        let chosen = provider ?? activeProvider(defaults: defaults)
        switch chosen {
        case .tavily:
            let key = KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount)
            return try await TavilySearchClient.search(query: query, apiKey: key, session: session)
        case .brave:
            let key = KeychainService.shared.loadSecret(account: WebSearchProvider.brave.keychainAccount)
            return try await searchBrave(query: query, apiKey: key, session: session)
        case .exa:
            let key = KeychainService.shared.loadSecret(account: WebSearchProvider.exa.keychainAccount)
            return try await searchExa(query: query, apiKey: key, session: session)
        case .searxng:
            let base = defaults.string(forKey: searxngBaseURLDefaultsKey) ?? ""
            let token = KeychainService.shared.loadSecret(account: WebSearchProvider.searxng.keychainAccount)
            return try await searchSearXNG(query: query, baseURL: base, bearerToken: token.isEmpty ? nil : token, session: session)
        }
    }

    // MARK: - Brave Search

    static func searchBrave(query: String, apiKey: String, session: URLSession? = nil) async throws -> SearchEvidence {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= TavilySearchClient.maximumQueryCharacters else { throw SearchError.invalidQuery }
        guard !apiKey.isEmpty else { throw SearchError.missingKey }
        try Task.checkCancellation()

        var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: clean),
            URLQueryItem(name: "count", value: "5")
        ]
        guard let url = comps.url else { throw SearchError.invalidQuery }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await fetchBounded(request: request, session: session)
        return try decodeBrave(data, query: clean)
    }

    static func decodeBrave(_ data: Data, query: String, now: Date = Date()) throws -> SearchEvidence {
        struct Response: Decodable {
            struct Web: Decodable {
                struct Item: Decodable {
                    var title: String?
                    var url: String
                    var description: String?
                }
                var results: [Item]?
            }
            var web: Web?
        }
        guard data.count <= maximumBytes else { throw SearchError.tooLarge }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw SearchError.invalidResponse }
        return try buildEvidence(
            items: (decoded.web?.results ?? []).map { ($0.title, $0.url, $0.description) },
            query: query,
            now: now
        )
    }

    // MARK: - Exa Search

    static func searchExa(query: String, apiKey: String, session: URLSession? = nil) async throws -> SearchEvidence {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= TavilySearchClient.maximumQueryCharacters else { throw SearchError.invalidQuery }
        guard !apiKey.isEmpty else { throw SearchError.missingKey }
        try Task.checkCancellation()

        var request = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": clean,
            "numResults": 5,
            "contents": ["text": ["maxCharacters": 1200]]
        ])

        let data = try await fetchBounded(request: request, session: session)
        return try decodeExa(data, query: clean)
    }

    static func decodeExa(_ data: Data, query: String, now: Date = Date()) throws -> SearchEvidence {
        struct Response: Decodable {
            struct Item: Decodable {
                var title: String?
                var url: String
                var text: String?
                var highlights: [String]?
            }
            var results: [Item]
        }
        guard data.count <= maximumBytes else { throw SearchError.tooLarge }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw SearchError.invalidResponse }
        return try buildEvidence(
            items: decoded.results.map { item in
                let snippet = item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? item.text
                    : item.highlights?.joined(separator: " ")
                return (item.title, item.url, snippet)
            },
            query: query,
            now: now
        )
    }

    // MARK: - SearXNG (Self-Hosted)

    static func searchSearXNG(
        query: String,
        baseURL: String,
        bearerToken: String? = nil,
        session: URLSession? = nil
    ) async throws -> SearchEvidence {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= TavilySearchClient.maximumQueryCharacters else { throw SearchError.invalidQuery }
        guard let root = validateSearXNGBaseURL(baseURL) else { throw SearchError.missingKey }
        try Task.checkCancellation()

        let searchURL = root.path.lowercased().hasSuffix("/search")
            ? root
            : root.appendingPathComponent("search")
        guard var comps = URLComponents(url: searchURL, resolvingAgainstBaseURL: false) else {
            throw SearchError.invalidQuery
        }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "format", value: "json"))
        items.append(URLQueryItem(name: "q", value: clean))
        comps.queryItems = items
        guard let url = comps.url else { throw SearchError.invalidQuery }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let data = try await fetchBounded(request: request, session: session)
        return try decodeSearXNG(data, query: clean)
    }

    static func decodeSearXNG(_ data: Data, query: String, now: Date = Date()) throws -> SearchEvidence {
        struct Response: Decodable {
            struct Item: Decodable {
                var title: String?
                var url: String
                var content: String?
            }
            var results: [Item]
        }
        guard data.count <= maximumBytes else { throw SearchError.tooLarge }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw SearchError.invalidResponse }
        return try buildEvidence(
            items: decoded.results.map { ($0.title, $0.url, $0.content) },
            query: query,
            now: now
        )
    }

    // MARK: - Helpers

    private static func buildEvidence(
        items: [(title: String?, url: String, snippet: String?)],
        query: String,
        now: Date
    ) throws -> SearchEvidence {
        var seen = Set<String>()
        var sources: [SearchSource] = []
        for item in items {
            guard sources.count < 5 else { break }
            guard item.url.count <= 4096,
                  let url = URL(string: item.url),
                  (try? URLReader.validate(url)) != nil,
                  seen.insert(url.absoluteString).inserted else { continue }
            let snippet = String((item.snippet ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
            guard !snippet.isEmpty else { continue }
            sources.append(SearchSource(
                id: sources.count + 1,
                title: String((item.title ?? url.host ?? "").prefix(300)),
                url: url,
                snippet: snippet
            ))
        }
        guard !sources.isEmpty else { throw SearchError.noResults }
        return SearchEvidence(query: query, searchedAt: now, sources: sources, credits: nil)
    }

    private static func fetchBounded(request: URLRequest, session: URLSession?) async throws -> Data {
        let (bytes, response) = try await (session ?? Self.session).bytes(for: request, delegate: NoRedirectSearchDelegate())
        guard let http = response as? HTTPURLResponse else { throw SearchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SearchError.http(http.statusCode) }
        guard response.expectedContentLength <= maximumBytes else { throw SearchError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw SearchError.tooLarge }
            data.append(byte)
        }
        return data
    }
}

enum JinaReaderClient {
    static let maximumBytes = 1_048_576

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        return URLSession(configuration: config)
    }()

    static func read(url: URL, apiKey: String? = nil, session: URLSession? = nil) async throws -> ReadablePage {
        try URLReader.validate(url)
        guard let readerURL = URL(string: "https://r.jina.ai/\(url.absoluteString)") else {
            throw SearchError.invalidQuery
        }
        var request = URLRequest(url: readerURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await (session ?? Self.session).bytes(for: request, delegate: NoRedirectSearchDelegate())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SearchError.invalidResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { break }
            data.append(byte)
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw SearchError.noResults }
        let titleLine = raw
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("Title:") })?
            .replacingOccurrences(of: "Title:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titleLine?.isEmpty == false ? titleLine! : (url.host ?? "Webpage"))
        let capped = String(raw.prefix(24_000))
        return ReadablePage(
            url: url,
            title: String(title.prefix(200)),
            text: capped,
            isTruncated: raw.count > 24_000 || data.count >= maximumBytes
        )
    }
}

private final class NoRedirectSearchDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
