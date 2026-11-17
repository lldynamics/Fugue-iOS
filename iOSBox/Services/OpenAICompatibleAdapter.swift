import Foundation

enum OpenAICompatibleAdapter {
    static func streamChat(
        _ request: LLMChatRequest,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await performStream(request, includeUsageOption: true, session: session, continuation: continuation)
                    } catch LLMError.httpError(let code, let detail)
                                where (400...422).contains(code) && detail.lowercased().contains("stream_options") {
                        // Some strict gateways reject `stream_options`; retry once without it.
                        try await performStream(request, includeUsageOption: false, session: session, continuation: continuation)
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func performStream(
        _ request: LLMChatRequest,
        includeUsageOption: Bool,
        session: URLSession,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let url = try EndpointResolver.chatEndpoint(
            baseURL: request.baseURL,
            protocolType: .openAICompatible,
            modelID: request.modelID
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !request.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        }
        LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)

        let payload = buildRequestBody(request, includeUsageOption: includeUsageOption)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await session.bytes(for: urlRequest)
        try await LLMClient.validateHTTPResponse(response, bytes: bytes)

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        // Graceful fallback for custom gateways that return non-streaming JSON
        if contentType.contains("application/json") && !contentType.contains("event-stream") {
            var fullData = Data()
            for try await b in bytes {
                fullData.append(b)
            }
            try emitNonStreamingJSON(fullData, continuation: continuation)
            return
        }

        var thinkParser = ThinkTagStreamParser()
        var receivedNativeReasoning = false
        var reportedFinish = false

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(":") {
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if dataPart == "[DONE]" {
                break
            }
            guard let jsonData = dataPart.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let errDict = obj["error"] as? [String: Any],
               let errMsg = errDict["message"] as? String {
                throw LLMError.apiError(errMsg)
            }

            if let usage = obj["usage"] as? [String: Any] {
                let prompt = usage["prompt_tokens"] as? Int
                let completion = usage["completion_tokens"] as? Int
                if prompt != nil || completion != nil {
                    continuation.yield(.usage(promptTokens: prompt, completionTokens: completion))
                }
            }

            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else {
                continue
            }

            let delta = (first["delta"] as? [String: Any]) ?? (first["message"] as? [String: Any]) ?? [:]

            if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
               !reasoning.isEmpty {
                receivedNativeReasoning = true
                continuation.yield(.reasoningDelta(reasoning))
            }

            if let content = delta["content"] as? String, !content.isEmpty {
                if receivedNativeReasoning {
                    continuation.yield(.contentDelta(content))
                } else {
                    emit(thinkParser.feed(content), to: continuation)
                }
            }

            if !reportedFinish,
               let reason = LLMFinishReason.fromProviderValue(first["finish_reason"] as? String) {
                reportedFinish = true
                continuation.yield(.finished(reason))
            }
        }

        if !receivedNativeReasoning {
            emit(thinkParser.finish(), to: continuation)
        }
    }

    private static func emit(
        _ segments: [ThinkTagStreamParser.Segment],
        to continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        for segment in segments {
            switch segment {
            case .reasoning(let r):
                continuation.yield(.reasoningDelta(r))
            case .content(let c):
                continuation.yield(.contentDelta(c))
            }
        }
    }

    // MARK: - Request Body

    static func buildRequestBody(_ request: LLMChatRequest, includeUsageOption: Bool = true) -> [String: Any] {
        var wireMessages: [[String: Any]] = []

        let trimmedSystem = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            wireMessages.append([
                "role": "system",
                "content": trimmedSystem
            ])
        }

        for msg in request.messages {
            let roleStr = msg.role == .assistant ? "assistant" : "user"
            let combinedText = LLMClient.composeTextWithDocuments(
                text: msg.content,
                attachments: msg.attachments,
                includePDFText: true
            )
            let imageAttachments = msg.attachments.filter { $0.kind == .image && $0.dataBase64 != nil }

            if imageAttachments.isEmpty || msg.role == .assistant {
                wireMessages.append([
                    "role": roleStr,
                    "content": combinedText
                ])
            } else {
                var parts: [[String: Any]] = []
                if !combinedText.isEmpty {
                    parts.append([
                        "type": "text",
                        "text": combinedText
                    ])
                }
                for img in imageAttachments {
                    if let base64 = img.dataBase64 {
                        parts.append([
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(img.mimeType);base64,\(base64)"
                            ]
                        ])
                    }
                }
                wireMessages.append([
                    "role": roleStr,
                    "content": parts
                ])
            }
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "messages": wireMessages,
            "stream": true
        ]

        let baseModel = baseModelName(request.modelID)
        let viaOpenRouter = isOpenRouter(request.baseURL)
        let isOpenAIReasoning = isOpenAIReasoningModel(baseModel)
        // OpenAI reasoning models reject temperature/top_p; DeepSeek reasoner ignores them.
        let omitSampling = isOpenAIReasoning || baseModel.contains("reasoner")

        if let temp = request.temperature, !omitSampling {
            body["temperature"] = temp
        }
        if request.topP < 0.999, !omitSampling {
            body["top_p"] = request.topP
        }
        if let maxTokens = request.maxOutputTokens, maxTokens > 0 {
            // OpenAI reasoning models require `max_completion_tokens`; OpenRouter normalizes `max_tokens`.
            let key = (isOpenAIReasoning && !viaOpenRouter) ? "max_completion_tokens" : "max_tokens"
            body[key] = maxTokens
        }
        if includeUsageOption {
            // Without this, OpenAI-style streams never report token usage.
            body["stream_options"] = ["include_usage": true]
        }
        body.merge(reasoningParameters(for: request)) { _, new in new }
        return body
    }

    /// Maps the conversation's thinking switch / budget onto vendor-specific parameters.
    /// Only sent when the model is flagged as reasoning-capable.
    static func reasoningParameters(for request: LLMChatRequest) -> [String: Any] {
        guard request.supportsReasoning else { return [:] }
        let baseModel = baseModelName(request.modelID)
        let budget = max(1024, request.thinkingBudgetTokens)

        if isOpenRouter(request.baseURL) {
            return request.enableThinking ? ["reasoning": ["max_tokens": budget]] : [:]
        }

        if isOpenAIReasoningModel(baseModel) {
            let effort: String
            if !request.enableThinking || budget <= 2048 {
                // "low" is the lowest effort accepted by every OpenAI reasoning model generation.
                effort = "low"
            } else if budget <= 8192 {
                effort = "medium"
            } else {
                effort = "high"
            }
            return ["reasoning_effort": effort]
        }

        // Qwen3 hybrid models (DashScope / SiliconFlow / vLLM). Fixed-mode variants
        // (`-instruct-*`, `-thinking-*`) don't accept the switch.
        if baseModel.contains("qwen3"), !baseModel.contains("instruct"), !baseModel.contains("thinking") {
            var params: [String: Any] = ["enable_thinking": request.enableThinking]
            if request.enableThinking {
                params["thinking_budget"] = budget
            }
            return params
        }

        return [:]
    }

    /// "openai/o3-mini" → "o3-mini" (lowercased).
    static func baseModelName(_ modelID: String) -> String {
        let lower = modelID.lowercased()
        return lower.split(separator: "/").last.map(String.init) ?? lower
    }

    static func isOpenAIReasoningModel(_ baseModel: String) -> Bool {
        if baseModel.contains("-chat") { return false } // e.g. gpt-5-chat-latest is non-reasoning
        return ["o1", "o3", "o4", "gpt-5"].contains { baseModel.hasPrefix($0) }
    }

    static func isOpenRouter(_ baseURL: String) -> Bool {
        let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    private static func emitNonStreamingJSON(
        _ data: Data,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            let errMsg = LLMClient.extractReadableErrorMessage(from: data)
            throw LLMError.apiError(errMsg)
        }
        if let reasoning = (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String),
           !reasoning.isEmpty {
            continuation.yield(.reasoningDelta(reasoning))
        }
        if let content = message["content"] as? String, !content.isEmpty {
            var parser = ThinkTagStreamParser()
            emit(parser.feed(content) + parser.finish(), to: continuation)
        }
        if let usage = obj["usage"] as? [String: Any] {
            continuation.yield(.usage(
                promptTokens: usage["prompt_tokens"] as? Int,
                completionTokens: usage["completion_tokens"] as? Int
            ))
        }
        if let reason = LLMFinishReason.fromProviderValue(first["finish_reason"] as? String) {
            continuation.yield(.finished(reason))
        }
    }

    // MARK: - Models

    static func fetchModels(
        baseURL: String,
        apiKey: String,
        customHeaders: [CustomHeader],
        session: URLSession
    ) async throws -> [ModelSpec] {
        let url = try EndpointResolver.modelsEndpoint(baseURL: baseURL, protocolType: .openAICompatible)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        LLMClient.applyCustomHeaders(customHeaders, to: &req)

        let (data, response) = try await session.data(for: req)
        try LLMClient.validateDataResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let dict = json as? [String: Any], let arr = dict["data"] as? [[String: Any]] {
            items = arr
        } else if let dict = json as? [String: Any], let arr = dict["models"] as? [[String: Any]] {
            items = arr
        } else if let arr = json as? [[String: Any]] {
            items = arr
        } else {
            return []
        }

        var specs: [ModelSpec] = []
        var seen = Set<String>()
        for item in items {
            guard let id = (item["id"] as? String) ?? (item["name"] as? String),
                  !id.isEmpty,
                  !seen.contains(id) else {
                continue
            }
            seen.insert(id)
            let displayName = (item["name"] as? String) ?? id
            specs.append(ModelSpec(id: id, displayName: displayName, isEnabled: true))
        }
        return specs.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
