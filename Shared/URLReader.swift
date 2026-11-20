import Darwin
import Foundation
import CoreFoundation

struct ReadablePage: Equatable {
    var url: URL
    var title: String
    var text: String
    var isTruncated: Bool
}

enum URLReaderError: LocalizedError {
    case unsafeURL, tooLarge, unsupportedType, empty, http(Int)
    var errorDescription: String? {
        switch self {
        case .unsafeURL: return String(localized: "网页精读仅支持不含账号密码的公开 HTTPS 链接。")
        case .tooLarge: return String(localized: "网页超过 2 MB，无法在分享窗口中读取。请改为分享选中的文字。")
        case .unsupportedType: return String(localized: "该链接不是 HTML 或纯文本网页。PDF 请在 App 中作为附件发送。")
        case .empty: return String(localized: "未提取到正文。网页可能需要登录或 JavaScript，可在 Safari 选中文字后分享。")
        case .http(let code): return String(localized: "网页读取失败（HTTP \(code)）。")
        }
    }
}

enum URLReader {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumCharacters = 60_000

    private static let blockedDomains: [String] = [
        "internal", "test", "localdomain", "home.arpa",
        "nip.io", "sslip.io", "xip.io",
        "localtest.me", "lvh.me", "vcap.me", "traefik.me",
        "ts.net", "plex.direct"
    ]

    static func validate(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", let rawHost = c.host, !rawHost.isEmpty,
              c.user == nil, c.password == nil, c.port == nil || c.port == 443 else {
            throw URLReaderError.unsafeURL
        }
        let normalizedHost = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty,
              !NetworkLocation.isLocalOrPrivate(host: normalizedHost),
              !NetworkLocation.isIPv4Literal(normalizedHost),
              !rawHost.contains(":"), !rawHost.allSatisfy({ $0.isNumber || $0 == "." }),
              !blockedDomains.contains(where: { normalizedHost == $0 || normalizedHost.hasSuffix("." + $0) }) else {
            throw URLReaderError.unsafeURL
        }
    }

    /// Resolves DNS records for `host` and rejects if any returned A/AAAA record maps to a private,
    /// loopback, link-local, CGNAT, or NAT64-local IP (defending against custom domains pointing at LAN).
    static func verifyPublicDNSResolution(for host: String) async throws {
        let cleanHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_family = AF_UNSPEC
            var res: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(cleanHost, nil, &hints, &res)
            guard status == 0, let head = res else {
                throw URLReaderError.unsafeURL
            }
            defer { freeaddrinfo(head) }

            var sawAnyAddress = false
            var cursor: UnsafeMutablePointer<addrinfo>? = head
            while let info = cursor {
                defer { cursor = info.pointee.ai_next }
                if info.pointee.ai_family == AF_INET, let sa = info.pointee.ai_addr {
                    let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var addr = sin.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buf)
                        sawAnyAddress = true
                        if NetworkLocation.isLocalOrPrivate(host: ip) {
                            throw URLReaderError.unsafeURL
                        }
                    }
                } else if info.pointee.ai_family == AF_INET6, let sa = info.pointee.ai_addr {
                    let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    var addr6 = sin6.sin6_addr
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &addr6, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                        let ip = String(cString: buf)
                        sawAnyAddress = true
                        if NetworkLocation.isLocalOrPrivate(host: ip) {
                            throw URLReaderError.unsafeURL
                        }
                    }
                }
            }
            if !sawAnyAddress {
                throw URLReaderError.unsafeURL
            }
        }.value
    }

    /// No cookies, credentials, JavaScript, subresources or ambient browser session.
    /// Redirects and resolved peer IPs are validated before any content is returned.
    static func read(_ url: URL, session suppliedSession: URLSession? = nil) async throws -> ReadablePage {
        var request = URLRequest(url: url)
        request.setValue("text/html, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request, accepting: ["text/html", "application/xhtml+xml", "text/plain"], session: suppliedSession)
        let finalURL = response.url ?? url
        let source = decode(data, charset: response.textEncodingName)
        if response.mimeType?.lowercased() == "text/plain" {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw URLReaderError.empty }
            return ReadablePage(url: finalURL, title: finalURL.host ?? "", text: String(trimmed.prefix(maximumCharacters)),
                                isTruncated: trimmed.count > maximumCharacters)
        }
        return try HTMLTextExtractor.extract(source, url: finalURL)
    }

    static func fetch(_ request: URLRequest, accepting types: Set<String>? = nil,
                      session suppliedSession: URLSession? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let initialHost = url.host else { throw URLReaderError.unsafeURL }
        try validate(url)
        let enforceLivePeerIP = (suppliedSession == nil)
        if enforceLivePeerIP {
            try await verifyPublicDNSResolution(for: initialHost)
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = suppliedSession ?? URLSession(configuration: config)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let authenticatedHost = request.value(forHTTPHeaderField: "Authorization") == nil ? nil : url.host?.lowercased()
        let delegate = ReaderRedirectDelegate(authenticatedHost: authenticatedHost, enforceLivePeerIP: enforceLivePeerIP)
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        if delegate.sawPrivatePeerAddress {
            bytes.task.cancel()
            throw URLReaderError.unsafeURL
        }
        guard let response = response as? HTTPURLResponse, let finalURL = response.url else { throw URLReaderError.empty }
        try validate(finalURL)
        if enforceLivePeerIP, let finalHost = finalURL.host, finalHost.caseInsensitiveCompare(initialHost) != .orderedSame {
            try await verifyPublicDNSResolution(for: finalHost)
        }
        if let authenticatedHost, finalURL.host?.lowercased() != authenticatedHost { throw URLReaderError.unsafeURL }
        guard (200..<300).contains(response.statusCode) else { throw URLReaderError.http(response.statusCode) }
        if let types, !types.contains(response.mimeType?.lowercased() ?? "") { throw URLReaderError.unsupportedType }
        guard response.expectedContentLength <= maximumBytes else { throw URLReaderError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if delegate.sawPrivatePeerAddress { throw URLReaderError.unsafeURL }
            guard data.count < maximumBytes else { throw URLReaderError.tooLarge }
            data.append(byte)
        }
        if delegate.sawPrivatePeerAddress {
            throw URLReaderError.unsafeURL
        }
        return (data, response)
    }

    static func decode(_ data: Data, charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
    }
}

private final class ReaderRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let authenticatedHost: String?
    private let enforceLivePeerIP: Bool
    init(authenticatedHost: String?, enforceLivePeerIP: Bool) {
        self.authenticatedHost = authenticatedHost
        self.enforceLivePeerIP = enforceLivePeerIP
    }
    private let lock = NSLock()
    private var redirectCount = 0
    private var _sawPrivatePeerAddress = false

    var sawPrivatePeerAddress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _sawPrivatePeerAddress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirectCount += 1
        let withinLimit = redirectCount <= 5
        lock.unlock()
        guard withinLimit, let url = request.url, (try? URLReader.validate(url)) != nil,
              authenticatedHost == nil || url.host?.lowercased() == authenticatedHost else {
            completionHandler(nil); return
        }
        guard enforceLivePeerIP, let nextHost = url.host else {
            completionHandler(request)
            return
        }
        Task {
            do {
                try await URLReader.verifyPublicDNSResolution(for: nextHost)
                completionHandler(request)
            } catch {
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard enforceLivePeerIP else { return }
        for tx in metrics.transactionMetrics {
            if let remoteIP = tx.remoteAddress, NetworkLocation.isLocalOrPrivate(host: remoteIP) {
                lock.lock()
                _sawPrivatePeerAddress = true
                lock.unlock()
                task.cancel()
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

enum HTMLTextExtractor {
    private static let titleRegex = try! NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#)
    private static let commentRegex = try! NSRegularExpression(pattern: #"(?is)<!--.*?-->"#)
    private static let boilerplateRegex = try! NSRegularExpression(pattern: #"(?is)<(script|style|noscript|nav|header|footer|form|svg|template|aside)\b[^>]*>.*?</\1\s*>"#)
    private static let articleRegex = try! NSRegularExpression(pattern: #"(?is)<article\b[^>]*>(.*?)</article\s*>"#)
    private static let mainRegex = try! NSRegularExpression(pattern: #"(?is)<main\b[^>]*>(.*?)</main\s*>"#)
    private static let bodyRegex = try! NSRegularExpression(pattern: #"(?is)<body\b[^>]*>(.*?)</body\s*>"#)
    private static let blockTagRegex = try! NSRegularExpression(pattern: #"(?i)</?(?:p|div|h[1-6]|li|br|hr|tr|blockquote|section)\b[^>]*>"#)
    private static let anyTagRegex = try! NSRegularExpression(pattern: #"(?s)<[^>]*>"#)
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"[\t\p{Zs}]+"#)
    private static let entityRegex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#)

    /// A bounded, non-rendering text extractor. It intentionally doesn't use a WebView or
    /// NSAttributedString's HTML importer, both of which can fetch external resources.
    static func extract(_ html: String, url: URL) throws -> ReadablePage {
        let title = plainText(firstCapture(titleRegex, in: html) ?? url.host ?? "")
        var cleaned = replacing(commentRegex, in: html, with: " ")
        cleaned = replacing(boilerplateRegex, in: cleaned, with: " ")
        let body = firstCapture(articleRegex, in: cleaned)
            ?? firstCapture(mainRegex, in: cleaned)
            ?? firstCapture(bodyRegex, in: cleaned) ?? cleaned
        let text = plainText(body)
        guard !text.isEmpty else { throw URLReaderError.empty }
        return ReadablePage(url: url, title: String(title.prefix(300)),
                            text: String(text.prefix(URLReader.maximumCharacters)),
                            isTruncated: text.count > URLReader.maximumCharacters)
    }

    static func plainText(_ html: String) -> String {
        var text = replacing(blockTagRegex, in: html, with: "\n")
        text = replacing(anyTagRegex, in: text, with: " ")
        text = decodeEntities(text)
        return text.components(separatedBy: .newlines).map {
            replacing(whitespaceRegex, in: $0, with: " ").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func decodeEntities(_ input: String) -> String {
        let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]
        var result = input
        for match in entityRegex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed() {
            guard let full = Range(match.range, in: result), let keyRange = Range(match.range(at: 1), in: input) else { continue }
            let key = String(input[keyRange])
            var value = names[key]
            if key.hasPrefix("#x"), let code = UInt32(key.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { value = String(scalar) }
            else if key.hasPrefix("#"), let code = UInt32(key.dropFirst()), let scalar = UnicodeScalar(code) { value = String(scalar) }
            if let value { result.replaceSubrange(full, with: value) }
        }
        return result
    }

    private static func firstCapture(_ re: NSRegularExpression, in text: String) -> String? {
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func replacing(_ re: NSRegularExpression, in text: String, with replacement: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
