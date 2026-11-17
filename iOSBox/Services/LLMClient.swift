import Foundation

enum LLMError: LocalizedError {
    case invalidURL(String)
    case missingAPIKey(String)
    case httpError(Int, String)
    case apiError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return String(localized: "无效的接口地址：\(raw)")
        case .missingAPIKey(let provider):
            return String(localized: "请先在「服务商」页面为「\(provider)」配置 API Key（本地服务若免鉴权可忽略）")
        case .httpError(let code, let detail):
            return "HTTP \(code)：\(detail)"
        case .apiError(let msg):
            return msg
        case .emptyResponse:
            return String(localized: "服务端未返回有效内容")
        }
    }
}

struct LLMPromptMessage: Sendable {
    let role: MessageRole
    let content: String
    let attachments: [MessageAttachment]
}

struct LLMChatRequest: Sendable {
    let providerName: String
    let protocolType: APIProtocolType
    let baseURL: String
    let apiKey: String
    let customHeaders: [CustomHeader]
    let modelID: String
    /// Per-model capability flag (user-editable in provider settings). Drives whether
    /// thinking / reasoning parameters are sent at all.
    let supportsReasoning: Bool
    let systemPrompt: String
    let messages: [LLMPromptMessage]
    let temperature: Double?
    let topP: Double
    let maxOutputTokens: Int?
    let enableThinking: Bool
    let thinkingBudgetTokens: Int
}

/// Abnormal reasons a generation stopped. A normal, complete answer emits nothing.
enum LLMFinishReason: String, Codable, Sendable {
    /// Hit the max output token limit; the answer is likely incomplete.
    case length
    /// Blocked or truncated by the provider's safety / content policy.
    case contentFilter = "content_filter"

    /// Maps provider-specific stop reasons (OpenAI `finish_reason`, Anthropic `stop_reason`,
    /// Gemini `finishReason`) to the abnormal cases we surface. Returns nil for normal stops.
    static func fromProviderValue(_ raw: String?) -> LLMFinishReason? {
        guard let value = raw?.lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "length", "max_tokens", "model_context_window_exceeded":
            return .length
        case "content_filter", "refusal", "safety", "recitation", "prohibited_content",
             "blocklist", "spii", "image_safety":
            return .contentFilter
        default:
            return nil
        }
    }

    var userNotice: String {
        switch self {
        case .length:
            return String(localized: "回复已达到最大输出长度，内容可能不完整。可在会话参数中调大「最大输出 Tokens」后重答。")
        case .contentFilter:
            return String(localized: "回复被模型服务商的安全策略拦截或截断。")
        }
    }
}

enum LLMStreamEvent: Sendable {
    case reasoningDelta(String)
    case contentDelta(String)
    case usage(promptTokens: Int?, completionTokens: Int?)
    case finished(LLMFinishReason)
    case done
}

enum LLMClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        switch request.protocolType {
        case .openAICompatible:
            return OpenAICompatibleAdapter.streamChat(request, session: session)
        case .anthropic:
            return AnthropicAdapter.streamChat(request, session: session)
        case .gemini:
            return GeminiAdapter.streamChat(request, session: session)
        }
    }

    static func fetchModels(
        providerName: String,
        protocolType: APIProtocolType,
        baseURL: String,
        apiKey: String,
        customHeaders: [CustomHeader]
    ) async throws -> [ModelSpec] {
        switch protocolType {
        case .openAICompatible:
            return try await OpenAICompatibleAdapter.fetchModels(
                baseURL: baseURL,
                apiKey: apiKey,
                customHeaders: customHeaders,
                session: session
            )
        case .anthropic:
            return try await AnthropicAdapter.fetchModels(
                baseURL: baseURL,
                apiKey: apiKey,
                customHeaders: customHeaders,
                session: session
            )
        case .gemini:
            return try await GeminiAdapter.fetchModels(
                baseURL: baseURL,
                apiKey: apiKey,
                customHeaders: customHeaders,
                session: session
            )
        }
    }

    // MARK: - Shared HTTP Utilities

    static func applyCustomHeaders(_ headers: [CustomHeader], to urlRequest: inout URLRequest) {
        for header in headers where header.isEnabled {
            let k = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty {
                urlRequest.setValue(v, forHTTPHeaderField: k)
            }
        }
    }

    static func validateHTTPResponse(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count >= 32_768 { break }
            }
            let message = extractReadableErrorMessage(from: errorData)
            throw LLMError.httpError(http.statusCode, message)
        }
    }

    static func validateDataResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = extractReadableErrorMessage(from: data)
            throw LLMError.httpError(http.statusCode, message)
        }
    }

    static func extractReadableErrorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return String(localized: "请求失败（无详细错误信息）") }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errDict = json["error"] as? [String: Any],
               let msg = errDict["message"] as? String, !msg.isEmpty {
                return msg
            }
            if let errStr = json["error"] as? String, !errStr.isEmpty {
                return errStr
            }
            if let msg = json["message"] as? String, !msg.isEmpty {
                return msg
            }
            if let detail = json["detail"] as? String, !detail.isEmpty {
                return detail
            }
        }
        let raw = String(decoding: data.prefix(600), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? String(localized: "请求被服务端拒绝") : raw
    }

    static func composeTextWithDocuments(text: String, attachments: [MessageAttachment], includePDFText: Bool) -> String {
        var blocks: [String] = []
        for item in attachments where item.kind == .document {
            if item.mimeType == "application/pdf" && !includePDFText && item.dataBase64 != nil {
                continue
            }
            if let extracted = item.extractedText, !extracted.isEmpty {
                blocks.append("<attachment name=\"\(item.fileName)\">\n\(extracted)\n</attachment>")
            } else {
                blocks.append(String(localized: "[附件: \(item.fileName) (\(item.formattedSize))]"))
            }
        }
        if !text.isEmpty {
            blocks.append(text)
        }
        return blocks.joined(separator: "\n\n")
    }
}
