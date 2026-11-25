import Foundation
import Observation

struct MCPToolInfo: Codable, Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let inputSchemaJSON: String
}

struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var endpointURL: String
    var isEnabled: Bool = true
    var authHeaderName: String = "Authorization"
    var discoveredTools: [MCPToolInfo] = []
    var disabledToolNames: Set<String> = []
    var lastConnectedAt: Date? = nil

    var keychainAccount: String { "mcp/server/\(id.uuidString)" }

    var shortPrefix: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    var activeTools: [MCPToolInfo] {
        guard isEnabled else { return [] }
        return discoveredTools.filter { !disabledToolNames.contains($0.name) }
    }

    func namespacedToolName(for rawName: String) -> String {
        let sanitized = rawName.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-")) ? ch : "_"
        }
        let base = "mcp__\(shortPrefix)__\(String(sanitized))"
        return String(base.prefix(64))
    }
}

enum MCPClientError: LocalizedError, Equatable {
    case invalidEndpoint
    case insecurePublicHTTP
    case httpStatus(Int)
    case httpDetail(Int, String)
    case invalidResponse
    case rpcError(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return String(localized: "MCP 服务地址无效，请输入完整的 HTTPS 或局域网 HTTP 端点。")
        case .insecurePublicHTTP: return String(localized: "公网 MCP 服务必须使用 HTTPS 加密连接。")
        case .httpStatus(let code): return String(localized: "MCP 服务返回 HTTP \(code) 错误。")
        case .httpDetail(let code, let detail): return "MCP HTTP \(code)：\(detail)"
        case .invalidResponse: return String(localized: "无法解析 MCP 服务返回的 JSON-RPC 数据。")
        case .rpcError(let msg): return String(localized: "MCP 工具执行失败：\(msg)")
        case .tooLarge: return String(localized: "MCP 服务响应超出大小上限。")
        }
    }
}

/// Persists Remote MCP server configurations (auth header secrets remain in Keychain).
@MainActor
@Observable
final class MCPServerStore {
    static let shared = MCPServerStore()

    private(set) var servers: [MCPServerConfig] = []
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = MCPServerStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("Fugue", isDirectory: true)
            .appendingPathComponent("mcp-servers.json")
    }

    func upsert(_ server: MCPServerConfig) {
        var clean = server
        clean.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.endpointURL = server.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.name.isEmpty, !clean.endpointURL.isEmpty else { return }

        if let idx = servers.firstIndex(where: { $0.id == clean.id }) {
            servers[idx] = clean
        } else {
            servers.append(clean)
        }
        persist()
    }

    func delete(id: UUID, purgeKeychain: Bool = true) {
        if let existing = servers.first(where: { $0.id == id }), purgeKeychain {
            _ = KeychainService.shared.saveSecret("", account: existing.keychainAccount)
        }
        servers.removeAll { $0.id == id }
        persist()
    }

    func enabledToolDefinitions() -> [LLMToolDefinition] {
        var defs: [LLMToolDefinition] = []
        for server in servers where server.isEnabled {
            for tool in server.activeTools {
                let desc = "[\(server.name)] \(tool.description)"
                defs.append(LLMToolDefinition(
                    name: server.namespacedToolName(for: tool.name),
                    description: String(desc.prefix(600)),
                    parametersSchemaJSON: tool.inputSchemaJSON
                ))
            }
        }
        return defs
    }

    func resolveToolCall(namespacedName: String) -> (server: MCPServerConfig, tool: MCPToolInfo)? {
        for server in servers where server.isEnabled {
            for tool in server.activeTools {
                if server.namespacedToolName(for: tool.name) == namespacedName {
                    return (server, tool)
                }
            }
        }
        return nil
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return
        }
        servers = decoded
    }

    private func persist() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(servers) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Streamable HTTP JSON-RPC 2.0 client for Remote MCP servers (`initialize`, `tools/list`, `tools/call`).
/// Supports both direct `application/json` responses and `text/event-stream` (SSE) JSON-RPC envelopes.
enum MCPClient {
    static let maximumResponseBytes = 2 * 1_048_576
    static let protocolVersion = "2025-03-26"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()

    static func validateEndpoint(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            throw MCPClientError.invalidEndpoint
        }
        if NetworkLocation.isPlainHTTPToPublicHost(baseURL: trimmed) {
            throw MCPClientError.insecurePublicHTTP
        }
        return url
    }

    static func discoverTools(
        endpointURL: String,
        authHeaderName: String = "Authorization",
        authHeaderValue: String = "",
        session: URLSession? = nil
    ) async throws -> [MCPToolInfo] {
        let url = try validateEndpoint(endpointURL)
        let sessionID = try await initializeSession(
            url: url,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            session: session
        )
        let listPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [String: Any]()
        ]
        let (result, _) = try await sendJSONRPC(
            url: url,
            body: listPayload,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            mcpSessionID: sessionID,
            session: session
        )
        return try parseToolsList(result: result)
    }

    static func callTool(
        endpointURL: String,
        authHeaderName: String = "Authorization",
        authHeaderValue: String = "",
        toolName: String,
        arguments: [String: Any],
        session: URLSession? = nil
    ) async throws -> String {
        let url = try validateEndpoint(endpointURL)
        let sessionID = try await initializeSession(
            url: url,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            session: session
        )
        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": arguments
            ]
        ]
        let (result, _) = try await sendJSONRPC(
            url: url,
            body: callPayload,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            mcpSessionID: sessionID,
            session: session
        )
        return parseToolCallContent(result: result)
    }

    private static func initializeSession(
        url: URL,
        authHeaderName: String,
        authHeaderValue: String,
        session: URLSession?
    ) async throws -> String? {
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "Fugue",
                    "version": "1.0"
                ]
            ]
        ]
        let (_, sessionID) = try await sendJSONRPC(
            url: url,
            body: initPayload,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            mcpSessionID: nil,
            session: session
        )
        // Best-effort initialized notification
        let notifyPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ]
        _ = try? await sendNotification(
            url: url,
            body: notifyPayload,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            mcpSessionID: sessionID,
            session: session
        )
        return sessionID
    }

    private static func makeRequest(
        url: URL,
        body: [String: Any],
        authHeaderName: String,
        authHeaderValue: String,
        mcpSessionID: String?
    ) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(protocolVersion, forHTTPHeaderField: "Mcp-Protocol-Version")
        let headerName = authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerVal = authHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headerName.isEmpty && !headerVal.isEmpty {
            req.setValue(headerVal, forHTTPHeaderField: headerName)
        }
        if let mcpSessionID, !mcpSessionID.isEmpty {
            req.setValue(mcpSessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func sendNotification(
        url: URL,
        body: [String: Any],
        authHeaderName: String,
        authHeaderValue: String,
        mcpSessionID: String?,
        session: URLSession?
    ) async throws {
        let req = try makeRequest(
            url: url,
            body: body,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            mcpSessionID: mcpSessionID
        )
        _ = try await (session ?? Self.session).data(for: req, delegate: SameOriginRedirectDelegate.shared)
    }

    private static func sendJSONRPC(
        url: URL,
        body: [String: Any],
        authHeaderName: String,
        authHeaderValue: String,
        mcpSessionID: String?,
        session: URLSession?
    ) async throws -> (result: [String: Any], sessionID: String?) {
        let req = try makeRequest(
            url: url,
            body: body,
            authHeaderName: authHeaderName,
            authHeaderValue: authHeaderValue,
            mcpSessionID: mcpSessionID
        )
        let (bytes, response) = try await (session ?? Self.session).bytes(for: req, delegate: SameOriginRedirectDelegate.shared)
        guard let http = response as? HTTPURLResponse else { throw MCPClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var errBuf = Data()
            for try await byte in bytes {
                errBuf.append(byte)
                if errBuf.count >= 4096 { break }
            }
            let detail = LLMClient.extractReadableErrorMessage(from: errBuf)
            if !errBuf.isEmpty && !detail.isEmpty {
                throw MCPClientError.httpDetail(http.statusCode, detail)
            }
            throw MCPClientError.httpStatus(http.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw MCPClientError.tooLarge }
            data.append(byte)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let returnedSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") ?? mcpSessionID
        let parsed = try decodeJSONRPCEnvelope(data: data, contentType: contentType)
        return (parsed, returnedSession)
    }

    // MARK: - Pure Decoders (Unit-Testable)

    static func decodeJSONRPCEnvelope(data: Data, contentType: String) throws -> [String: Any] {
        let jsonData: Data
        if contentType.lowercased().contains("text/event-stream") || looksLikeSSE(data) {
            let text = String(decoding: data, as: UTF8.self)
            var lastPayload: Data?
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    let body = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if body.hasPrefix("{"), let candidate = body.data(using: .utf8) {
                        lastPayload = candidate
                    }
                }
            }
            guard let extracted = lastPayload else { throw MCPClientError.invalidResponse }
            jsonData = extracted
        } else {
            jsonData = data
        }

        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        if let err = obj["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "JSON-RPC error"
            throw MCPClientError.rpcError(msg)
        }
        guard let result = obj["result"] as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        return result
    }

    static func parseToolsList(result: [String: Any]) throws -> [MCPToolInfo] {
        guard let rawTools = result["tools"] as? [[String: Any]] else {
            throw MCPClientError.invalidResponse
        }
        var tools: [MCPToolInfo] = []
        for item in rawTools {
            guard let name = item["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let desc = (item["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let schemaObj = (item["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
            let schemaData = (try? JSONSerialization.data(withJSONObject: schemaObj, options: [.sortedKeys])) ?? Data("{\"type\":\"object\",\"properties\":{}}".utf8)
            tools.append(MCPToolInfo(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                description: desc.isEmpty ? name : desc,
                inputSchemaJSON: String(decoding: schemaData, as: UTF8.self)
            ))
        }
        return tools
    }

    static func parseToolCallContent(result: [String: Any]) -> String {
        var parts: [String] = []
        if let content = result["content"] as? [[String: Any]] {
            for block in content {
                if let text = block["text"] as? String, !text.isEmpty {
                    parts.append(text)
                } else if let resource = block["resource"] as? [String: Any],
                          let text = resource["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            }
        }
        if parts.isEmpty,
           let raw = try? JSONSerialization.data(withJSONObject: result),
           let fallback = String(data: raw, encoding: .utf8) {
            parts.append(fallback)
        }
        let joined = parts.joined(separator: "\n")
        let bounded = String(joined.prefix(16_000))
        return "Untrusted external MCP tool output:\n\(bounded)"
    }

    private static func looksLikeSSE(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.hasPrefix("event:") || prefix.hasPrefix("data:")
    }
}
