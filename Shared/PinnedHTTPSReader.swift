import Darwin
import Foundation
import Network
import Security

/// A single-use public-web transport. DNS supplies numeric endpoints, while TLS and HTTP still
/// authenticate and address the original hostname. Redirects are handled by URLReader.
enum PinnedHTTPSReader {
    static func exchange(_ request: URLRequest, accepting types: Set<String>?) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, let host = url.host?.lowercased(), !host.isEmpty else {
            throw URLReaderError.unsafeURL
        }
        let requestBytes = try makeRequest(request, host: host)
        let deadline = DispatchTime.now() + 30
        let addresses = try await resolve(host)
        var lastError: Error = URLError(.cannotConnectToHost)
        for (index, address) in addresses.prefix(4).enumerated() {
            try Task.checkCancellation()
            guard DispatchTime.now() < deadline else { throw URLError(.timedOut) }
            let attemptDeadline = index + 1 < min(addresses.count, 4) ? min(deadline, .now() + 8) : deadline
            let operation = Exchange(endpoint: address, host: host, url: url, types: types, bytes: requestBytes)
            do {
                return try await operation.run(connectDeadline: attemptDeadline, requestDeadline: deadline)
            } catch let failure as ConnectFailure {
                lastError = failure.cause
            }
        }
        throw lastError
    }

    private struct ConnectFailure: Error { let cause: Error }

    static func publicEndpoint(_ ip: String) -> NWEndpoint.Host? {
        guard !NetworkLocation.isLocalOrPrivate(host: ip) else { return nil }
        if let address = IPv4Address(ip), let first = address.rawValue.first, first < 224 {
            return .ipv4(address)
        }
        if let address = IPv6Address(ip) {
            let bytes = Array(address.rawValue)
            // Global unicast, excluding IPv6 transition forms, and the well-known NAT64 prefix.
            let native = (bytes[0] & 0xe0) == 0x20 &&
                !(bytes[0] == 0x20 && bytes[1] == 0x02) &&
                !(bytes[0..<4].elementsEqual([0x20, 0x01, 0, 0]))
            let nat64 = bytes[0..<12].elementsEqual([0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0])
            if native || (nat64 && bytes[12] < 224) { return .ipv6(address) }
        }
        return nil
    }

    private static func resolve(_ host: String) async throws -> [NWEndpoint.Host] {
        let result = try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_family = AF_UNSPEC
            var results: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &results) == 0, let head = results else { throw URLReaderError.unsafeURL }
            defer { freeaddrinfo(head) }
            var addresses: [NWEndpoint.Host] = []
            var current: UnsafeMutablePointer<addrinfo>? = head
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            while let info = current {
                defer { current = info.pointee.ai_next }
                guard [AF_INET, AF_INET6].contains(info.pointee.ai_family) else { continue }
                let status = getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer,
                                         socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                guard status == 0, let address = publicEndpoint(String(cString: buffer)) else {
                    throw URLReaderError.unsafeURL
                }
                if !addresses.contains(address) { addresses.append(address) }
            }
            guard !addresses.isEmpty else { throw URLReaderError.unsafeURL }
            return addresses
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func makeRequest(_ request: URLRequest, host: String) throws -> Data {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              host.utf8.allSatisfy({ (33...126).contains($0) }) else { throw URLReaderError.unsafeURL }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let target = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard target.hasPrefix("/"), target.utf8.count <= 16_384,
              target.utf8.allSatisfy({ (33...126).contains($0) }) else { throw URLReaderError.unsafeURL }
        var fields = ["GET \(target) HTTP/1.1", "Host: \(host)", "Connection: close",
                      "Accept-Encoding: identity", "User-Agent: Fugue/1.0"]
        for name in ["Accept", "Authorization"] {
            guard let value = request.value(forHTTPHeaderField: name) else { continue }
            guard value.utf8.count <= 8_192, value.utf8.allSatisfy({ (32...126).contains($0) }) else {
                throw URLReaderError.unsafeURL
            }
            fields.append("\(name): \(value)")
        }
        return Data((fields.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private final class Exchange: @unchecked Sendable {
        // Network callbacks and cancellation share one serial queue.
        private let queue = DispatchQueue(label: "com.iosbox.public-https")
        private let connection: NWConnection
        private let bytes: Data
        private var parser: ResponseParser
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var cancelled = false
        private var requestStarted = false

        init(endpoint: NWEndpoint.Host, host: String, url: URL, types: Set<String>?, bytes: Data) {
            self.bytes = bytes
            parser = ResponseParser(url: url, types: types)
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            host.withCString { sec_protocol_options_set_tls_server_name(options, $0) }
            sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
            sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
            sec_protocol_options_set_verify_block(options, { _, presented, complete in
                let trust = sec_trust_copy_ref(presented).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, host as CFString)
                guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
                      SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
                    complete(false)
                    return
                }
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let privacy = NWParameters.PrivacyContext(description: "Fugue public HTTPS")
            privacy.proxyConfigurations = []
            parameters.setPrivacyContext(privacy)
            connection = NWConnection(host: endpoint, port: .https, using: parameters)
        }

        func run(connectDeadline: DispatchTime, requestDeadline: DispatchTime) async throws -> (Data, HTTPURLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async { [self] in
                        guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                        self.continuation = continuation
                        self.connection.stateUpdateHandler = { [weak self] state in
                            guard let self, self.continuation != nil else { return }
                            switch state {
                            case .ready:
                                guard !self.requestStarted else { return }
                                self.requestStarted = true
                                self.send()
                            case .failed(let error), .waiting(let error): self.finishTransportError(error)
                            case .cancelled: self.finish(.failure(CancellationError()))
                            default: break
                            }
                        }
                        self.queue.asyncAfter(deadline: connectDeadline) { [weak self] in
                            guard let self, !self.requestStarted else { return }
                            self.finishTransportError(URLError(.timedOut))
                        }
                        self.queue.asyncAfter(deadline: requestDeadline) { [weak self] in
                            self?.finishTransportError(URLError(.timedOut))
                        }
                        self.connection.start(queue: self.queue)
                    }
                }
            } onCancel: {
                queue.async {
                    self.cancelled = true
                    self.finish(.failure(CancellationError()))
                }
            }
        }

        private func send() {
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                guard let self, self.continuation != nil else { return }
                if let error { self.finish(.failure(error)) }
                else { self.receive() }
            })
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, end, error in
                guard let self, self.continuation != nil else { return }
                if let error { self.finish(.failure(error)); return }
                do {
                    if let result = try self.parser.receive(data ?? Data(), end: end) {
                        self.finish(.success(result))
                    } else {
                        self.receive()
                    }
                } catch { self.finish(.failure(error)) }
            }
        }

        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
            guard let continuation else { return }
            self.continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation.resume(with: result)
        }

        private func finishTransportError(_ error: Error) {
            // Once a GET may have been sent, retrying could send it and its credentials twice.
            finish(.failure(requestStarted ? error : ConnectFailure(cause: error)))
        }
    }

    struct ResponseParser {
        private enum Phase { case headers, fixed(Int), untilEnd, chunkSize, chunk(Int), chunkEnd, trailers }
        private static let newline = Data([13, 10])
        private static let headerEnd = Data([13, 10, 13, 10])
        let url: URL
        let types: Set<String>?
        private var pending = Data()
        private var response: HTTPURLResponse?
        private var body = Data()
        private var phase: Phase = .headers
        private var received = 0
        private var interimResponses = 0

        init(url: URL, types: Set<String>?) { self.url = url; self.types = types }

        mutating func receive(_ data: Data, end: Bool = false) throws -> (Data, HTTPURLResponse)? {
            received += data.count
            guard received <= URLReader.maximumBytes + 128 * 1024 else { throw URLReaderError.tooLarge }
            pending.append(data)
            while true {
                switch phase {
                case .headers:
                    guard let marker = pending.range(of: Self.headerEnd) else { return try waiting(end, limit: 32_768) }
                    let count = marker.lowerBound - pending.startIndex
                    guard count <= 32_768 else { throw URLReaderError.tooLarge }
                    let heading = String(decoding: pending.prefix(count), as: UTF8.self)
                    pending.removeFirst(count + 4)
                    let parsed = try parseHead(heading)
                    if (100..<200).contains(parsed.statusCode) {
                        interimResponses += 1
                        guard parsed.statusCode != 101, interimResponses <= 4 else { throw URLError(.badServerResponse) }
                        continue
                    }
                    response = parsed
                    guard (200..<300).contains(parsed.statusCode) else { return (Data(), parsed) }
                    try URLReader.checkResponse(parsed, accepting: types)
                    let encoding = parsed.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
                    guard encoding == "identity" else { throw URLReaderError.unsupportedType }
                    if parsed.statusCode == 204 || parsed.statusCode == 205 { return (Data(), parsed) }
                    if let transfer = parsed.value(forHTTPHeaderField: "Transfer-Encoding") {
                        guard transfer.lowercased() == "chunked",
                              parsed.value(forHTTPHeaderField: "Content-Length") == nil else { throw URLError(.badServerResponse) }
                        phase = .chunkSize
                    } else if let length = parsed.value(forHTTPHeaderField: "Content-Length") {
                        guard let count = Int(length), count >= 0 else { throw URLError(.badServerResponse) }
                        guard count <= URLReader.maximumBytes else { throw URLReaderError.tooLarge }
                        phase = .fixed(count)
                    } else {
                        phase = .untilEnd
                    }
                case .fixed(let remaining):
                    let used = min(remaining, pending.count)
                    try consume(used)
                    if used == remaining { return completed() }
                    phase = .fixed(remaining - used)
                    return try waiting(end)
                case .untilEnd:
                    try consume(pending.count)
                    return end ? completed() : nil
                case .chunkSize:
                    guard let marker = pending.range(of: Self.newline) else { return try waiting(end, limit: 1_024) }
                    let count = marker.lowerBound - pending.startIndex
                    guard count <= 1_024 else { throw URLError(.badServerResponse) }
                    let line = String(decoding: pending.prefix(count), as: UTF8.self)
                    pending.removeFirst(count + 2)
                    let size = line.prefix(while: { $0 != ";" }).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                    guard !size.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let length = Int(size, radix: 16) else { throw URLError(.badServerResponse) }
                    guard length <= URLReader.maximumBytes - body.count else { throw URLReaderError.tooLarge }
                    phase = length == 0 ? .trailers : .chunk(length)
                case .chunk(let remaining):
                    let used = min(remaining, pending.count)
                    try consume(used)
                    phase = used == remaining ? .chunkEnd : .chunk(remaining - used)
                    if used < remaining { return try waiting(end) }
                case .chunkEnd:
                    guard pending.count >= 2 else { return try waiting(end) }
                    guard pending.starts(with: Self.newline) else { throw URLError(.badServerResponse) }
                    pending.removeFirst(2)
                    phase = .chunkSize
                case .trailers:
                    if pending.starts(with: Self.newline) || pending.range(of: Self.headerEnd) != nil { return completed() }
                    return try waiting(end, limit: 32_768)
                }
            }
        }

        private mutating func consume(_ count: Int) throws {
            guard count <= URLReader.maximumBytes - body.count else { throw URLReaderError.tooLarge }
            body.append(contentsOf: pending.prefix(count))
            pending.removeFirst(count)
        }

        private func waiting(_ end: Bool, limit: Int = .max) throws -> (Data, HTTPURLResponse)? {
            guard pending.count <= limit else { throw URLReaderError.tooLarge }
            guard !end else { throw URLError(.badServerResponse) }
            return nil
        }

        private func completed() -> (Data, HTTPURLResponse)? {
            response.map { (body, $0) }
        }

        private func parseHead(_ heading: String) throws -> HTTPURLResponse {
            let lines = heading.components(separatedBy: "\r\n")
            let first = (lines.first ?? "").split(separator: " ", maxSplits: 2)
            guard (2...3).contains(first.count), ["HTTP/1.0", "HTTP/1.1"].contains(String(first[0])),
                  let status = Int(first[1]), (100...599).contains(status), lines.count <= 129 else {
                throw URLError(.badServerResponse)
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let separator = line.firstIndex(of: ":"), separator > line.startIndex else { throw URLError(.badServerResponse) }
                let name = line[..<separator].lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0) }),
                      !value.utf8.contains(where: { ($0 < 32 && $0 != 9) || $0 == 127 }) else { throw URLError(.badServerResponse) }
                if let old = headers[name] {
                    if ["location", "content-length", "transfer-encoding", "content-encoding", "content-type"].contains(name), old != value {
                        throw URLError(.badServerResponse)
                    }
                } else { headers[name] = value }
            }
            guard let result = HTTPURLResponse(url: url, statusCode: status, httpVersion: String(first[0]), headerFields: headers)
            else { throw URLError(.badServerResponse) }
            return result
        }
    }
}
