import Foundation

struct PersonaFeedBatch {
    var items: [PersonaFeedItem]
    var checkpoint: PersonaFeed.Checkpoint
}

struct PersonaFeedReader {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    var fetch: Fetch = { try await URLReader.fetch($0) }

    static func source(_ input: String, kind: PersonaFeed.Kind) throws -> PersonaFeed {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .blog:
            guard let url = URL(string: raw) else { throw URLReaderError.unsafeURL }
            try URLReader.validate(url)
            return PersonaFeed(kind: kind, address: url.absoluteString)
        case .x:
            throw PersonaError.invalidFeed
        }
    }

    func read(_ feed: PersonaFeed) async throws -> PersonaFeedBatch {
        switch feed.kind {
        case .blog: return try await readBlog(feed)
        case .x: throw PersonaError.invalidFeed
        }
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lScheme = lhs.scheme?.lowercased(),
              let rScheme = rhs.scheme?.lowercased(),
              lScheme == rScheme,
              let lHost = lhs.host?.lowercased(),
              let rHost = rhs.host?.lowercased(),
              lHost == rHost else {
            return false
        }
        return effectivePort(of: lhs) == effectivePort(of: rhs)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// Both the importer and the subscription poller use the blog's own advertised feed.
    func blogEntries(at address: URL) async throws -> (url: URL, items: [PersonaFeedItem]) {
        var url = address
        for attempt in 0...1 {
            try URLReader.validate(url)
            var request = URLRequest(url: url)
            request.setValue("application/atom+xml, application/rss+xml, application/xml, text/xml, text/html;q=0.5", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            let finalURL = response.url ?? url
            try URLReader.validate(finalURL)
            if var items = try? SubscriptionFeedParser.parse(data, url: finalURL) {
                if items.allSatisfy({ $0.published != nil }) {
                    items.sort { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
                }
                return (finalURL, items)
            }
            guard attempt == 0,
                  let discovered = SubscriptionFeedParser.discover(in: URLReader.decode(data, charset: response.textEncodingName), at: finalURL),
                  discovered != finalURL,
                  Self.isSameOrigin(discovered, finalURL) else { throw PersonaError.invalidFeed }
            url = discovered
        }
        throw PersonaError.invalidFeed
    }

    private func readBlog(_ feed: PersonaFeed) async throws -> PersonaFeedBatch {
        var state = feed.checkpoint ?? .init()
        guard let original = URL(string: feed.address) else { throw PersonaError.invalidFeed }
        let result: (url: URL, items: [PersonaFeedItem])
        if let cached = state.feedURL, cached != original, Self.isSameOrigin(cached, original) {
            do { result = try await blogEntries(at: cached) }
            catch URLReaderError.http(404) { result = try await blogEntries(at: original) }
            catch PersonaError.invalidFeed { result = try await blogEntries(at: original) }
        } else { result = try await blogEntries(at: original) }
        state.feedURL = result.url
        let window = result.items.prefix(256)
        let ids = window.map(\.id)
        let known = Set(state.recentIDs)
        let latestIDs = Set(ids)
        state.recentIDs = Array((ids + state.recentIDs.filter { !latestIDs.contains($0) }).prefix(512))
        let newItems = feed.checkpoint == nil ? [] : Array(window.filter { !known.contains($0.id) }.reversed())
        return PersonaFeedBatch(items: newItems, checkpoint: state)
    }
}
