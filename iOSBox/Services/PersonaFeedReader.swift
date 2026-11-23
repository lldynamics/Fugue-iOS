import Foundation

struct PersonaFeedBatch {
    var items: [PersonaFeedItem]
    var checkpoint: PersonaFeed.Checkpoint
}

struct PersonaFeedReader {
    static let xTokenAccount = "persona-x-read-bearer"
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    var fetch: Fetch = { try await URLReader.fetch($0) }
    var token: @Sendable () -> String = { KeychainService.shared.loadSecret(account: xTokenAccount) }

    static func source(_ input: String, kind: PersonaFeed.Kind) throws -> PersonaFeed {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .blog:
            guard let url = URL(string: raw) else { throw URLReaderError.unsafeURL }
            try URLReader.validate(url)
            return PersonaFeed(kind: kind, address: url.absoluteString)
        case .x:
            var handle = raw
            if raw.contains("/") {
                guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
                      ["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"].contains(url.host?.lowercased() ?? ""),
                      url.user == nil, url.password == nil, url.port == nil,
                      url.pathComponents.count == 2 else { throw PersonaError.invalidAccount }
                handle = url.lastPathComponent
            }
            if handle.hasPrefix("@") { handle.removeFirst() }
            guard handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil else { throw PersonaError.invalidAccount }
            return PersonaFeed(kind: kind, address: handle.lowercased())
        }
    }

    func read(_ feed: PersonaFeed, now: Date = Date()) async throws -> PersonaFeedBatch {
        switch feed.kind {
        case .blog: return try await readBlog(feed)
        case .x: return try await readX(feed, now: now)
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
            guard attempt == 0, let discovered = SubscriptionFeedParser.discover(in: URLReader.decode(data, charset: response.textEncodingName), at: finalURL),
                  discovered != finalURL else { throw PersonaError.invalidFeed }
            url = discovered
        }
        throw PersonaError.invalidFeed
    }

    private func readBlog(_ feed: PersonaFeed) async throws -> PersonaFeedBatch {
        var state = feed.checkpoint ?? .init()
        guard let original = URL(string: feed.address) else { throw PersonaError.invalidFeed }
        let result: (url: URL, items: [PersonaFeedItem])
        if let cached = state.feedURL, cached != original {
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

    private struct Lookup: Decodable {
        struct User: Decodable { let id: String }
        let data: User
    }
    private struct Timeline: Decodable {
        struct Post: Decodable { let id: String; let text: String; let created_at: String? }
        struct Meta: Decodable { let next_token: String?; let newest_id: String?; let result_count: Int }
        let data: [Post]?
        let meta: Meta
    }

    private func readX(_ feed: PersonaFeed, now: Date) async throws -> PersonaFeedBatch {
        let handle = try Self.source(feed.address, kind: .x).address
        let bearer = token().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bearer.isEmpty else { throw PersonaError.missingToken }
        var state = feed.checkpoint ?? .init()
        func request<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
            var parts = URLComponents()
            parts.scheme = "https"
            parts.host = "api.x.com"
            parts.path = path
            parts.queryItems = query.isEmpty ? nil : query
            guard let url = parts.url else { throw PersonaError.invalidAccount }
            var req = URLRequest(url: url)
            req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            do {
                let (data, _) = try await fetch(req)
                return try JSONDecoder().decode(T.self, from: data)
            } catch URLReaderError.http(let status) { throw PersonaError.api(status) }
        }
        if state.userID == nil {
            let user: Lookup = try await request("/2/users/by/username/" + handle)
            state.userID = user.data.id
        }
        guard let id = state.userID, isPostID(id) else { throw PersonaError.invalidAccount }
        let initial = feed.checkpoint == nil
        var query = [URLQueryItem(name: "max_results", value: initial ? "5" : "100"),
                     URLQueryItem(name: "tweet.fields", value: "created_at"), URLQueryItem(name: "exclude", value: "retweets")]
        if let since = state.sinceID { query.append(.init(name: "since_id", value: since)) }
        else if let start = state.startedAt { query.append(.init(name: "start_time", value: ISO8601DateFormatter().string(from: start))) }
        let endpoint = "/2/users/" + id + "/tweets"
        var page: Timeline
        if let next = state.nextPage {
            do { page = try await request(endpoint, query: query + [.init(name: "pagination_token", value: next)]) }
            catch PersonaError.api(400) {
                state.pendingNewestID = nil
                page = try await request(endpoint, query: query)
            }
        } else { page = try await request(endpoint, query: query) }
        let posts = page.data ?? []
        guard posts.count == page.meta.result_count, posts.allSatisfy({ isPostID($0.id) }) else { throw PersonaError.invalidFeed }
        let newest = state.pendingNewestID ?? page.meta.newest_id ?? posts.first?.id
        state.startedAt = state.startedAt ?? now
        if initial {
            state.sinceID = newest
            return PersonaFeedBatch(items: [], checkpoint: state)
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var batch = state.pendingItems ?? []
        var known = Set(batch.map(\.id))
        for post in posts where known.insert(post.id).inserted {
            guard let url = URL(string: "https://x.com/i/web/status/" + post.id) else { throw PersonaError.invalidFeed }
            batch.append(PersonaFeedItem(id: post.id, title: String(post.text.prefix(500)), url: url,
                                         published: post.created_at.flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }))
        }
        // X returns newest-first pages. Keep the oldest window; any newer overflow is fetched
        // again from the last published ID, which bounds persisted checkpoint size across polls.
        batch.sort { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count }
        if batch.count > 400 {
            batch.removeLast(batch.count - 400)
            state.truncatedBatch = true
        }
        state.nextPage = page.meta.next_token
        if state.nextPage != nil {
            state.pendingNewestID = newest
            state.pendingItems = batch
            return PersonaFeedBatch(items: [], checkpoint: state)
        }
        state.sinceID = (state.truncatedBatch == true ? batch.last?.id : newest) ?? state.sinceID
        state.pendingNewestID = nil
        state.pendingItems = nil
        state.truncatedBatch = nil
        return PersonaFeedBatch(items: batch, checkpoint: state)
    }

    private func isPostID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 20 && id.utf8.allSatisfy { (48...57).contains($0) }
    }
}
