import Foundation
import CoreFoundation

struct ReadablePage: Equatable {
    var url: URL
    var title: String
    var text: String
    var isTruncated: Bool
}

enum URLReaderError: LocalizedError {
    case unsafeURL, destinationNotApproved, tooLarge, unsupportedType, empty, http(Int)
    var errorDescription: String? {
        switch self {
        case .unsafeURL: return String(localized: "网页精读仅支持不含账号密码的公开 HTTPS 链接。")
        case .destinationNotApproved: return String(localized: "用户已拒绝访问")
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

    typealias RedirectAuthorization = @Sendable (URL) async -> Bool
    typealias Exchange = (URLRequest, Set<String>?) async throws -> (Data, HTTPURLResponse)

    static func requestIdentity(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.port == 443 { components.port = nil }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        return components.string ?? url.absoluteString
    }

    static func read(_ url: URL, session suppliedSession: URLSession? = nil,
                     authorizeRedirect: RedirectAuthorization? = nil) async throws -> ReadablePage {
        var request = URLRequest(url: url)
        request.setValue("text/html, text/plain;q=0.9", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request, accepting: ["text/html", "application/xhtml+xml", "text/plain"],
                                               session: suppliedSession, authorizeRedirect: authorizeRedirect)
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
                      session suppliedSession: URLSession? = nil,
                      authorizeRedirect: RedirectAuthorization? = nil) async throws -> (Data, HTTPURLResponse) {
        try await follow(request, accepting: types, authorizeRedirect: authorizeRedirect) { request, types in
            if let suppliedSession {
                // In-process URLProtocol fixtures can supply a session. Production always uses pinned HTTPS.
                let (bytes, result) = try await suppliedSession.bytes(for: request, delegate: ReaderFixtureDelegate())
                defer { bytes.task.cancel() }
                guard let response = result as? HTTPURLResponse else { throw URLReaderError.empty }
                guard (200..<300).contains(response.statusCode) else { return (Data(), response) }
                try checkResponse(response, accepting: types)
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maximumBytes else { throw URLReaderError.tooLarge }
                    data.append(byte)
                }
                return (data, response)
            }
            return try await PinnedHTTPSReader.exchange(request, accepting: types)
        }
    }

    static func follow(_ initial: URLRequest, accepting types: Set<String>?,
                       authorizeRedirect: RedirectAuthorization?, exchange: Exchange) async throws -> (Data, HTTPURLResponse) {
        guard let original = initial.url, let originalHost = original.host?.lowercased() else { throw URLReaderError.unsafeURL }
        var request = initial
        var permitted = Set([requestIdentity(original)])
        for redirects in 0...5 {
            try Task.checkCancellation()
            guard let url = request.url else { throw URLReaderError.unsafeURL }
            try validate(url)
            let (data, response) = try await exchange(request, types)
            if [301, 302, 303, 307, 308].contains(response.statusCode) {
                guard redirects < 5, let location = response.value(forHTTPHeaderField: "Location"),
                      !location.isEmpty, let next = URL(string: location, relativeTo: url)?.absoluteURL
                else { throw URLReaderError.http(response.statusCode) }
                try validate(next)
                if initial.value(forHTTPHeaderField: "Authorization") != nil, next.host?.lowercased() != originalHost {
                    throw URLReaderError.unsafeURL
                }
                let key = requestIdentity(next)
                if !permitted.contains(key), let authorizeRedirect {
                    guard await authorizeRedirect(next) else { throw URLReaderError.destinationNotApproved }
                    permitted.insert(key)
                }
                request.url = next
            } else {
                try checkResponse(response, accepting: types)
                guard data.count <= maximumBytes else { throw URLReaderError.tooLarge }
                return (data, response)
            }
        }
        throw URLReaderError.unsafeURL
    }

    static func checkResponse(_ response: HTTPURLResponse, accepting types: Set<String>?) throws {
        guard (200..<300).contains(response.statusCode) else { throw URLReaderError.http(response.statusCode) }
        if let types, !types.contains(response.mimeType?.lowercased() ?? "") { throw URLReaderError.unsupportedType }
        guard response.expectedContentLength <= maximumBytes else { throw URLReaderError.tooLarge }
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

private final class ReaderFixtureDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum HTMLTextExtractor {
    private static let hidden: Set<String> = ["script", "style", "noscript", "nav", "header", "footer", "form", "svg", "template", "aside"]
    private static let blocks: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "br", "hr", "tr", "blockquote", "section"]
    private static let names = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]

    static func extract(_ html: String, url: URL) throws -> ReadablePage {
        try Task.checkCancellation()
        let bytes = Array(html.utf8.prefix(2 * 1024 * 1024))
        let sections: Set<String> = ["title", "article", "main", "body"]
        var ranges: [String: Range<Int>] = [:]
        var opening: [String: Int] = [:]
        var suppressed: String?
        scan(bytes, in: bytes.indices, text: { _ in }) { name, closing, selfClosing, range in
            if let hidden = suppressed {
                if closing && name == hidden { suppressed = nil }
            } else if !closing && Self.hidden.contains(name) && !(name == "svg" && selfClosing) {
                suppressed = name
            } else if sections.contains(name) && ranges[name] == nil {
                if closing, let start = opening[name] { ranges[name] = start..<range.lowerBound }
                else if !closing && opening[name] == nil { opening[name] = range.upperBound }
            }
        }
        let title = ranges["title"].map { render(bytes, in: $0) } ?? url.host ?? ""
        let body = ranges["article"] ?? ranges["main"] ?? ranges["body"] ?? bytes.indices
        let text = render(bytes, in: body)
        try Task.checkCancellation()
        guard !text.isEmpty else { throw URLReaderError.empty }
        return ReadablePage(url: url, title: String(title.prefix(300)),
                            text: String(text.prefix(URLReader.maximumCharacters)),
                            isTruncated: text.count > URLReader.maximumCharacters)
    }

    static func plainText(_ html: String) -> String {
        let bytes = Array(html.utf8.prefix(2 * 1024 * 1024))
        return render(bytes, in: bytes.indices)
    }

    private static func render(_ bytes: [UInt8], in range: Range<Int>) -> String {
        var visible = [UInt8]()
        var suppressed: String?
        scan(bytes, in: range, text: { span in
            if suppressed == nil { visible.append(contentsOf: bytes[span]) }
        }) { name, closing, selfClosing, _ in
            if let hidden = suppressed {
                if closing && name == hidden { suppressed = nil }
            } else if !closing && hidden.contains(name) && !(name == "svg" && selfClosing) {
                suppressed = name
                visible.append(32)
            } else {
                visible.append(blocks.contains(name) ? 10 : 32)
            }
        }

        let decoded = decodeEntities(String(decoding: visible, as: UTF8.self))
        let limit = URLReader.maximumCharacters + 1
        var remaining = limit
        var result = ""
        var line = ""
        var pendingSpace = false
        func flush() {
            guard !line.isEmpty else { return }
            if !result.isEmpty && remaining > 0 {
                let separator = String("\n\n".prefix(remaining))
                result.append(separator)
                remaining -= separator.count
            }
            let part = line.prefix(remaining)
            result.append(contentsOf: part)
            remaining -= part.count
            line.removeAll(keepingCapacity: true)
        }
        for scalar in decoded.unicodeScalars {
            if remaining == 0 { break }
            if CharacterSet.newlines.contains(scalar) {
                flush()
                pendingSpace = false
            } else if CharacterSet.whitespaces.contains(scalar) {
                pendingSpace = !line.isEmpty
            } else {
                if pendingSpace { line.append(" "); pendingSpace = false }
                line.unicodeScalars.append(scalar)
            }
        }
        flush()
        return result
    }

    private static func scan(_ bytes: [UInt8], in range: Range<Int>, text: (Range<Int>) -> Void,
                             tag: (String, Bool, Bool, Range<Int>) -> Void) {
        var index = range.lowerBound
        var textStart = index
        var nextCancellationCheck = index
        let end = range.upperBound
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        while index < end {
            if index >= nextCancellationCheck {
                guard !Task.isCancelled else { return }
                nextCancellationCheck = index + 4_096
            }
            guard bytes[index] == 60, index + 1 < end else { index += 1; continue }
            let start = index
            if start + 4 <= end && bytes[start..<start + 4].elementsEqual([60, 33, 45, 45]) {
                text(textStart..<start)
                var next = start + 4
                while next + 2 < end && !bytes[next..<next + 3].elementsEqual([45, 45, 62]) {
                    if next & 4095 == 0 && Task.isCancelled { return }
                    next += 1
                }
                index = min(end, next + 3)
                textStart = index
                continue
            }
            let closing = bytes[index + 1] == 47
            var next = start + (closing ? 2 : 1)
            guard next < end else { break }
            let special = bytes[next] == 33 || bytes[next] == 63
            guard special || letter(bytes[next]) else { index += 1; continue }
            let nameStart = next
            while next < end && next - nameStart < 64 &&
                (letter(bytes[next]) || (48...57).contains(bytes[next]) || bytes[next] == 45) { next += 1 }
            let name = special ? "" : String(decoding: bytes[nameStart..<next], as: UTF8.self).lowercased()
            var quote: UInt8?
            while next < end && next - start < 8192 {
                let value = bytes[next]
                if let activeQuote = quote {
                    if value == activeQuote { quote = nil }
                } else if value == 62 || value == 60 {
                    break
                } else if value == 34 || value == 39 {
                    quote = value
                }
                next += 1
            }
            if next < end, bytes[next] == 62, quote == nil {
                text(textStart..<start)
                var tail = next - 1
                while tail > start && [9, 10, 12, 13, 32].contains(bytes[tail]) { tail -= 1 }
                tag(name, closing, bytes[tail] == 47, start..<next + 1)
                index = next + 1
                textStart = index
            } else {
                index = max(start + 1, next)
            }
        }
        text(textStart..<end)
    }

    static func decodeEntities(_ input: String) -> String {
        let bytes = Array(input.utf8)
        var decoded = [UInt8]()
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 38, index + 1 < bytes.count,
               let end = bytes[(index + 1)..<min(bytes.count, index + 24)].firstIndex(of: 59) {
                let key = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                var value = names[key]
                if key.hasPrefix("#x"), let code = UInt32(key.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { value = String(scalar) }
                else if key.hasPrefix("#"), let code = UInt32(key.dropFirst()), let scalar = UnicodeScalar(code) { value = String(scalar) }
                if let value {
                    decoded.append(contentsOf: value.utf8)
                    index = end + 1
                    continue
                }
            }
            decoded.append(bytes[index])
            index += 1
        }
        return String(decoding: decoded, as: UTF8.self)
    }
}
