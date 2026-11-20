import Darwin
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
            return isPrivateIPv4(octets)
        }
        if host.contains(":") {
            if let bytes = ipv6Bytes(host) {
                return isPrivateIPv6(bytes)
            }
            // Fallback string checks for malformed/zone-suffixed IPv6 literals
            let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
            if bare == "::" || bare == "::1" || bare.hasPrefix("fc") || bare.hasPrefix("fd") || isIPv6LinkLocal(bare) {
                return true
            }
            if bare.hasPrefix("::ffff:") {
                let mapped = String(bare.dropFirst("::ffff:".count))
                if ipv4Octets(mapped) != nil {
                    return isLocalOrPrivate(host: mapped)
                }
                return true
            }
            return false
        }
        // Unqualified names ("my-mac", "nas") only resolve on the local network.
        return !host.contains(".")
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _):
            return true
        case (172, 16...31), (192, 168), (169, 254), (198, 18...19):
            return true
        case (100, 64...127):
            return true // CGNAT range, used by Tailscale
        default:
            return false
        }
    }

    private static func ipv6Bytes(_ rawHost: String) -> [UInt8]? {
        let stripped = rawHost.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawHost
        var addr6 = in6_addr()
        guard inet_pton(AF_INET6, stripped, &addr6) == 1 else { return nil }
        return withUnsafeBytes(of: &addr6) { Array($0) }
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        let allZero = bytes.allSatisfy { $0 == 0 }
        if allZero { return true } // ::
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true } // ::1
        if (bytes[0] & 0xFE) == 0xFC { return true } // fc00::/7 unique local
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true } // fe80::/10 link-local
        // IPv4-mapped IPv6 (::ffff:0:0/96) and IPv4-translated/compatible prefixes
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isPrivateIPv4([Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15])])
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isPrivateIPv4([Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15])])
        }
        // RFC 6052 / RFC 8215 NAT64 prefixes: 64:ff9b::/96 (well-known) and 64:ff9b:1::/48 (local-use)
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B {
            if bytes[4] == 0x00 && bytes[5] == 0x01 {
                return true
            }
            if bytes[4..<12].allSatisfy({ $0 == 0 }) {
                return isPrivateIPv4([Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15])])
            }
        }
        return false
    }

    /// True if `host` is any IPv4 literal form (standard dotted-quad, shorthand `127.1`,
    /// octal `0177.0.0.1`, hex `0x7f.0.0.1`, or integer `2130706433`).
    static func isIPv4Literal(_ rawHost: String) -> Bool {
        ipv4Octets(normalized(rawHost)) != nil
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
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    }

    /// Matches the full `fe80::/10` link-local IPv6 range (`fe80:` through `febf:`).
    private static func isIPv6LinkLocal(_ host: String) -> Bool {
        let firstSegment = host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard firstSegment.count == 4, let value = UInt16(firstSegment, radix: 16) else {
            return false
        }
        return (value & 0xFFC0) == 0xFE80
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        if parts.count == 4 {
            let octets = parts.compactMap { seg -> Int? in
                guard !seg.isEmpty, seg.allSatisfy(\.isNumber) else { return nil }
                if seg.count > 1 && seg.hasPrefix("0") { return nil }
                return Int(seg)
            }
            if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
                return octets
            }
        }
        // Handle legacy/alternate IPv4 forms (octal, hex, shorthand like 127.1 or 0x7f.0.0.1)
        // only when every label is a valid numeric literal.
        guard parts.allSatisfy({ isNumericIPv4Segment($0) }) else { return nil }
        var addr = in_addr()
        guard inet_aton(host, &addr) == 1 else { return nil }
        let ip = UInt32(bigEndian: addr.s_addr)
        return [
            Int((ip >> 24) & 0xFF),
            Int((ip >> 16) & 0xFF),
            Int((ip >> 8) & 0xFF),
            Int(ip & 0xFF)
        ]
    }

    private static func isNumericIPv4Segment(_ seg: Substring) -> Bool {
        guard !seg.isEmpty else { return false }
        if seg.hasPrefix("0x") || seg.hasPrefix("0X") {
            let digits = seg.dropFirst(2)
            return !digits.isEmpty && digits.allSatisfy(\.isHexDigit)
        }
        return seg.allSatisfy(\.isNumber)
    }
}
