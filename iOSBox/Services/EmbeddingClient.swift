import CryptoKit
import Foundation

enum EmbeddingClientError: LocalizedError {
    case consentRequired
    case unsupportedProtocol
    case insecurePublicHTTP
    case emptyInput
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .consentRequired:
            return String(localized: "请先确认向量服务的接收方和数据用途并授权。")
        case .unsupportedProtocol:
            return String(localized: "当前服务商协议不支持向量嵌入接口，请选择 OpenAI 兼容或 Gemini 服务商。")
        case .insecurePublicHTTP:
            return String(localized: "公网向量接口仅允许使用 HTTPS。")
        case .emptyInput:
            return String(localized: "向量嵌入输入为空。")
        case .invalidResponse:
            return String(localized: "向量接口返回格式无法识别或维度不一致。")
        case .httpError(let code, let detail):
            return String(localized: "向量接口请求失败（HTTP \(code)）：\(detail)")
        }
    }
}

struct EmbeddingConfig: Equatable, Sendable {
    let providerID: UUID
    let providerName: String
    let protocolType: APIProtocolType
    let baseURL: String
    let apiKey: String
    let extraKeys: [String]
    let customHeaders: [CustomHeader]
    let modelID: String

    var endpoint: URL {
        get throws {
            try EndpointResolver.embeddingsEndpoint(baseURL: baseURL, protocolType: protocolType, modelID: modelID)
        }
    }

    func consentScope(for endpoint: URL) -> String {
        let recipient = [providerID.uuidString, protocolType.rawValue, endpoint.absoluteString, modelID]
        return SHA256.hash(data: Data(recipient.joined(separator: "\n").utf8)).description
    }

    /// Unique model space key so vectors from different providers/models are never mixed.
    var cacheKey: String {
        let host = URLComponents(string: baseURL)?.host?.lowercased() ?? "local"
        return "api:\(protocolType.rawValue):\(host):\(modelID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

enum EmbeddingConsent {
    static let key = "iosbox.embeddingConsent.v1"

    static func allows(_ config: EmbeddingConfig) -> Bool {
        guard let endpoint = try? config.endpoint else { return false }
        return UserDefaults.standard.string(forKey: key) == config.consentScope(for: endpoint)
    }
}

enum EmbeddingClient {
    static let presetModels: [String] = [
        "text-embedding-3-small",
        "text-embedding-3-large",
        "BAAI/bge-m3",
        "nomic-embed-text",
        "text-embedding-004"
    ]

    static let maxBatchSize = 32
    static let maxInputCharacters = 2_000

    // Every embedding request is authorized for one endpoint, so a redirect needs a new configuration.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let noRedirects = NoRedirects()

    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    @MainActor
    static func eligibleProviders(from providers: [ProviderConfig]) -> [ProviderConfig] {
        providers.filter { provider in
            guard !provider.isDeleted, provider.isEnabled else { return false }
            guard provider.protocolType == .openAICompatible || provider.protocolType == .openAIResponses || provider.protocolType == .gemini else { return false }
            guard !NetworkLocation.isPlainHTTPToPublicHost(baseURL: provider.baseURL) else { return false }
            return NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL) || provider.hasAuthentication
        }
    }

    @MainActor
    static func resolvedConfig(
        providers: [ProviderConfig],
        preferences: AppPreferences? = nil
    ) -> EmbeddingConfig? {
        let preferences = preferences ?? .shared
        guard preferences.ragHybridEmbeddingEnabled else { return nil }
        let eligible = eligibleProviders(from: providers)
        let selected: ProviderConfig?
        if let preferredID = preferences.ragEmbeddingProviderID {
            selected = eligible.first { $0.id == preferredID }
        } else {
            selected = eligible.first
        }
        guard let provider = selected else { return nil }
        let model = preferences.ragEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        return EmbeddingConfig(
            providerID: provider.id,
            providerName: provider.name,
            protocolType: provider.protocolType,
            baseURL: provider.baseURL,
            apiKey: provider.apiKey,
            extraKeys: provider.extraAPIKeys,
            customHeaders: provider.resolvedCustomHeaders,
            modelID: model
        )
    }

    @MainActor
    static func authorizedConfig(providers: [ProviderConfig]) -> EmbeddingConfig? {
        guard let config = resolvedConfig(providers: providers), EmbeddingConsent.allows(config) else { return nil }
        return config
    }

    /// Embeds an array of texts in bounded batches, returning L2-normalized Float32 vectors aligned 1:1 with `texts`.
    static func embed(
        texts: [String],
        config: EmbeddingConfig,
        session: URLSession? = nil
    ) async throws -> [[Float]] {
        guard !texts.isEmpty else { throw EmbeddingClientError.emptyInput }
        guard config.protocolType == .openAICompatible || config.protocolType == .openAIResponses || config.protocolType == .gemini else {
            throw EmbeddingClientError.unsupportedProtocol
        }
        if NetworkLocation.isPlainHTTPToPublicHost(baseURL: config.baseURL) {
            throw EmbeddingClientError.insecurePublicHTTP
        }
        let endpoint = try config.endpoint
        let scope = config.consentScope(for: endpoint)
        guard UserDefaults.standard.string(forKey: EmbeddingConsent.key) == scope else {
            throw EmbeddingClientError.consentRequired
        }

        let sanitized = texts.map { raw -> String in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return " " }
            return String(trimmed.prefix(maxInputCharacters))
        }

        var allVectors: [[Float]] = []
        allVectors.reserveCapacity(sanitized.count)

        var start = 0
        while start < sanitized.count {
            try Task.checkCancellation()
            let end = min(start + maxBatchSize, sanitized.count)
            let batch = Array(sanitized[start..<end])
            let vectors = try await embedBatch(batch, config: config, endpoint: endpoint, scope: scope, session: session ?? defaultSession)
            guard vectors.count == batch.count else {
                throw EmbeddingClientError.invalidResponse
            }
            allVectors.append(contentsOf: vectors)
            start = end
        }
        return allVectors
    }

    private static func embedBatch(
        _ batch: [String],
        config: EmbeddingConfig,
        endpoint: URL,
        scope: String,
        session: URLSession
    ) async throws -> [[Float]] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let headers = config.customHeaders.filter {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Host") != .orderedSame
        }

        switch config.protocolType {
        case .openAICompatible, .openAIResponses:
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
            LLMClient.applyCustomHeaders(headers, to: &request)
            let body: [String: Any] = [
                "model": config.modelID,
                "input": batch,
                "encoding_format": "float"
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

        case .gemini:
            if !config.apiKey.isEmpty {
                request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
            }
            LLMClient.applyCustomHeaders(headers, to: &request)
            let normalizedModel = config.modelID.hasPrefix("models/") ? config.modelID : "models/\(config.modelID)"
            let requestsPayload: [[String: Any]] = batch.map { text in
                [
                    "model": normalizedModel,
                    "content": ["parts": [["text": text]]]
                ]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["requests": requestsPayload])

        case .anthropic:
            throw EmbeddingClientError.unsupportedProtocol
        }

        guard UserDefaults.standard.string(forKey: EmbeddingConsent.key) == scope else {
            throw EmbeddingClientError.consentRequired
        }
        let (data, response) = try await session.data(for: request, delegate: noRedirects)
        guard let http = response as? HTTPURLResponse else {
            throw EmbeddingClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(400), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EmbeddingClientError.httpError(http.statusCode, detail.isEmpty ? "Request failed" : detail)
        }

        switch config.protocolType {
        case .openAICompatible, .openAIResponses:
            return try parseOpenAIEmbeddings(data, expectedCount: batch.count)
        case .gemini:
            return try parseGeminiEmbeddings(data, expectedCount: batch.count)
        case .anthropic:
            throw EmbeddingClientError.unsupportedProtocol
        }
    }

    static func parseOpenAIEmbeddings(_ data: Data, expectedCount: Int) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]],
              rows.count == expectedCount else {
            throw EmbeddingClientError.invalidResponse
        }
        var ordered = [(index: Int, vector: [Float])]()
        ordered.reserveCapacity(rows.count)
        for (fallbackIdx, row) in rows.enumerated() {
            let idx = (row["index"] as? Int) ?? fallbackIdx
            guard let numbers = row["embedding"] as? [NSNumber], !numbers.isEmpty else {
                throw EmbeddingClientError.invalidResponse
            }
            let vector = try normalizeVector(numbers.map(\.floatValue))
            ordered.append((idx, vector))
        }
        ordered.sort { $0.index < $1.index }
        let vectors = ordered.map(\.vector)
        guard let dim = vectors.first?.count, vectors.allSatisfy({ $0.count == dim }) else {
            throw EmbeddingClientError.invalidResponse
        }
        return vectors
    }

    static func parseGeminiEmbeddings(_ data: Data, expectedCount: Int) throws -> [[Float]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["embeddings"] as? [[String: Any]],
              list.count == expectedCount else {
            throw EmbeddingClientError.invalidResponse
        }
        var vectors: [[Float]] = []
        vectors.reserveCapacity(list.count)
        for item in list {
            guard let numbers = item["values"] as? [NSNumber], !numbers.isEmpty else {
                throw EmbeddingClientError.invalidResponse
            }
            vectors.append(try normalizeVector(numbers.map(\.floatValue)))
        }
        guard let dim = vectors.first?.count, vectors.allSatisfy({ $0.count == dim }) else {
            throw EmbeddingClientError.invalidResponse
        }
        return vectors
    }

    static func normalizeVector(_ raw: [Float]) throws -> [Float] {
        guard !raw.isEmpty else { throw EmbeddingClientError.invalidResponse }
        var sumSq: Double = 0
        for value in raw {
            guard value.isFinite else { throw EmbeddingClientError.invalidResponse }
            sumSq += Double(value) * Double(value)
        }
        let norm = sumSq.squareRoot()
        guard norm > 1e-9 else { throw EmbeddingClientError.invalidResponse }
        let inv = Float(1.0 / norm)
        return raw.map { $0 * inv }
    }

    static func dotSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var normA: Double = 0
        var normB: Double = 0
        for i in a.indices {
            let av = Double(a[i])
            let bv = Double(b[i])
            dot += av * bv
            normA += av * av
            normB += bv * bv
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 1e-9 else { return 0 }
        return dot / denom
    }
}
