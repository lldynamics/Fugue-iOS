import Foundation

/// Classifies a provider Base URL by where its host lives, using the parsed host instead of
/// substring checks (e.g. `api10.example.com` must not count as a private `10.x` address).
enum NetworkLocation {
    /// Loopback, link-local, private LAN ranges, CGNAT/Tailscale (100.64/10), `.local`
    /// mDNS names and unqualified host names.
    static func isLocalOrPrivate(baseURL: String) -> Bool {
        guard let host = host(of: baseURL) else { return false }
        return isLocalOrPrivate(host: host)
    }

    /// `http://` to a public host: API keys and conversations would travel in clear text,
    /// and App Transport Security blocks such loads anyway.
    static func isPlainHTTPToPublicHost(baseURL: String) -> Bool {
        guard let components = components(of: baseURL),
              components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty else {
            return false
        }
        return !isLocalOrPrivate(host: normalized(host))
    }

    static func isLocalOrPrivate(host rawHost: String) -> Bool {
        let host = normalized(rawHost)
        guard !host.isEmpty else { return false }

        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _):
                return true
            case (172, 16...31), (192, 168), (169, 254):
                return true
            case (100, 64...127):
                return true // CGNAT range, used by Tailscale
            default:
                return false
            }
        }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
        }
        // Unqualified names ("my-mac", "nas") only resolve on the local network.
        return !host.contains(".")
    }

    // MARK: - Helpers

    private static func components(of baseURL: String) -> URLComponents? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("#") {
            trimmed.removeLast()
        }
        return URLComponents(string: trimmed)
    }

    private static func host(of baseURL: String) -> String? {
        guard let host = components(of: baseURL)?.host, !host.isEmpty else { return nil }
        return normalized(host)
    }

    private static func normalized(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}
