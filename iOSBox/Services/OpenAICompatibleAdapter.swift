import Foundation

enum OpenAICompatibleAdapter {
    private struct WireOptions: Sendable {
        var useUsageOption: Bool
        var useNativeSearch: Bool
        var useReasoningContent: Bool
        var useReasoningParams: Bool
        var useMaxCompletionTokens: Bool
        var useSamplingParams: Bool
    }

    static func streamChat(
        _ request: LLMChatRequest,
        capabilityCache: GatewayCapabilityCache = .shared,
        keyRouter: APIKeyPoolRouter = .shared,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let baseModel = baseModelName(request.modelID)
        let viaOpenRouter = isOpenRouter(request.baseURL)
        let isOpenAIReasoning = isOpenAIReasoningModel(baseModel)
        let directOpenAIHost = isDirectOpenAIHost(request.baseURL)
        let defaultMaxCompletion = isOpenAIReasoning && !viaOpenRouter
        let resolvedMaxCompletion: Bool
        if capabilityCache.isUnsupported(.maxCompletionTokens, protocolType: .openAICompatible, baseURL: request.baseURL, modelID: request.modelID) {
            resolvedMaxCompletion = false
        } else if capabilityCache.isUnsupported(.requiresMaxCompletionTokens, protocolType: .openAICompatible, baseURL: request.baseURL, modelID: request.modelID) {
            resolvedMaxCompletion = true
        } else {
            resolvedMaxCompletion = defaultMaxCompletion
        }

        let hasReasoningParams = !reasoningParameters(for: request).isEmpty
        let hasMaxTokens = (request.maxOutputTokens ?? 0) > 0
        let omitSampling = isOpenAIReasoning || baseModel.contains("reasoner")
        let hasSamplingParams = !omitSampling && (request.temperature != nil || request.topP < 0.999)
        let hasAssistantReasoningContent = !directOpenAIHost
            && (!isOpenAIReasoning || viaOpenRouter)
            && request.messages.contains { $0.role == .assistant && !$0.toolCalls.isEmpty && !$0.reasoningContent.isEmpty }

        let initial = WireOptions(
            useUsageOption: !capabilityCache.isUnsupported(
                .streamOptions,
                protocolType: .openAICompatible,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useNativeSearch: request.enableNativeSearch && !capabilityCache.isUnsupported(
                .nativeSearch,
                protocolType: .openAICompatible,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useReasoningContent: !capabilityCache.isUnsupported(
                .reasoningContent,
                protocolType: .openAICompatible,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useReasoningParams: !capabilityCache.isUnsupported(
                .reasoningParams,
                protocolType: .openAICompatible,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useMaxCompletionTokens: resolvedMaxCompletion,
            useSamplingParams: !capabilityCache.isUnsupported(
                .samplingParams,
                protocolType: .openAICompatible,
                baseURL: request.baseURL,
                modelID: request.modelID
            )
        )
        return LLMClient.streamWithResilience(
            request: request,
            initialState: initial,
            capabilityCache: capabilityCache,
            keyRouter: keyRouter,
            session: session,
            buildURLRequest: { activeKey, state in
                let url = try EndpointResolver.chatEndpoint(
                    baseURL: request.baseURL,
                    protocolType: .openAICompatible,
                    modelID: request.modelID
                )
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if !activeKey.isEmpty {
                    urlRequest.setValue("Bearer \(activeKey)", forHTTPHeaderField: "Authorization")
                }
                LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)
                let payload = buildRequestBody(
                    request,
                    includeUsageOption: state.useUsageOption,
                    includeNativeSearch: state.useNativeSearch,
                    includeReasoningContent: state.useReasoningContent,
                    includeReasoningParams: state.useReasoningParams,
                    useMaxCompletionTokens: state.useMaxCompletionTokens,
                    includeSamplingParams: state.useSamplingParams
                )
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
                return urlRequest
            },
            degradeOn400: { _, detail, state, newlyDisabled in
                let lower = detail.lowercased()
                if LLMClient.isUnrecoverable400(lower) {
                    return false
                }
                if state.useUsageOption && (lower.contains("stream_options") || lower.contains("include_usage")) {
                    state.useUsageOption = false
                    newlyDisabled.insert(.streamOptions)
                    return true
                }
                if state.useReasoningContent && lower.contains("reasoning_content") {
                    state.useReasoningContent = false
                    newlyDisabled.insert(.reasoningContent)
                    return true
                }
                if hasReasoningParams && state.useReasoningParams
                    && (lower.contains("reasoning_effort") || lower.contains("enable_thinking")
                        || lower.contains("thinking_budget") || lower.contains("thinking")
                        || lower.contains("reasoning")) {
                    state.useReasoningParams = false
                    newlyDisabled.insert(.reasoningParams)
                    return true
                }
                if hasMaxTokens && state.useMaxCompletionTokens && lower.contains("max_completion_tokens") {
                    state.useMaxCompletionTokens = false
                    newlyDisabled.insert(.maxCompletionTokens)
                    return true
                }
                if hasMaxTokens && !state.useMaxCompletionTokens && lower.contains("max_tokens")
                    && (lower.contains("max_completion_tokens") || lower.contains("unsupported") || lower.contains("not supported") || lower.contains("not allowed")) {
                    state.useMaxCompletionTokens = true
                    newlyDisabled.insert(.requiresMaxCompletionTokens)
                    return true
                }
                if hasSamplingParams && state.useSamplingParams && (lower.contains("temperature") || lower.contains("top_p")) {
                    state.useSamplingParams = false
                    newlyDisabled.insert(.samplingParams)
                    return true
                }
                if state.useNativeSearch && (lower.contains("web_search") || lower.contains("plugins") || lower.contains("unknown") || lower.contains("unrecognized")) {
                    state.useNativeSearch = false
                    newlyDisabled.insert(.nativeSearch)
                    return true
                }
                // Generic fallback when a gateway rejects extra/unknown fields without naming the exact key.
                if LLMClient.isGenericParameterRejection400(lower) {
                    if state.useNativeSearch {
                        state.useNativeSearch = false
                        newlyDisabled.insert(.nativeSearch)
                        return true
                    }
                    if hasReasoningParams && state.useReasoningParams {
                        state.useReasoningParams = false
                        newlyDisabled.insert(.reasoningParams)
                        return true
                    }
                    if state.useUsageOption {
                        state.useUsageOption = false
                        newlyDisabled.insert(.streamOptions)
                        return true
                    }
                    if hasAssistantReasoningContent && state.useReasoningContent {
                        state.useReasoningContent = false
                        newlyDisabled.insert(.reasoningContent)
                        return true
                    }
                    if hasMaxTokens && state.useMaxCompletionTokens {
                        state.useMaxCompletionTokens = false
                        newlyDisabled.insert(.maxCompletionTokens)
                        return true
                    }
                }
                return false
            },
            consumeStream: { bytes, response, touch, continuation in
                try await consumeAcceptedResponse(
                    bytes: bytes,
                    response: response,
                    onActivity: touch,
                    continuation: continuation
                )
            }
        )
    }

    private static func consumeAcceptedResponse(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        onActivity: @escaping @Sendable () -> Void,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        // Graceful fallback for custom gateways that return non-streaming JSON
        if contentType.contains("application/json") && !contentType.contains("event-stream") {
            continuation.yield(.nonStreamingResponse)
            let maxJSONBytes = 16 * 1024 * 1024
            var fullData = Data()
            var sinceTouch = 0
            for try await b in bytes {
                try Task.checkCancellation()
                fullData.append(b)
                guard fullData.count <= maxJSONBytes else {
                    throw LLMError.interruptedStream
                }
                sinceTouch += 1
                if sinceTouch >= 1024 {
                    sinceTouch = 0
                    onActivity()
                }
            }
            onActivity()
            try emitNonStreamingJSON(fullData, continuation: continuation)
            return
        }

        var thinkParser = ThinkTagStreamParser()
        var receivedNativeReasoning = false
        var completed = false
        var reportedFinish = false
        var pendingToolCalls: [Int: (id: String, name: String, args: String)] = [:]

        for try await dataPart in SSEDecoder.events(bytes, onActivity: onActivity) {
            try Task.checkCancellation()
            if dataPart == "[DONE]" { completed = true; break }
            if dataPart.isEmpty { continue }
            let obj = try SSEDecoder.jsonObject(dataPart)

            if let errDict = obj["error"] as? [String: Any],
               let errMsg = errDict["message"] as? String {
                throw LLMError.apiError(errMsg)
            }

            if let usage = obj["usage"] as? [String: Any] {
                let prompt = LLMUsage.valid(usage["prompt_tokens"] as? Int)
                let completion = LLMUsage.valid(usage["completion_tokens"] as? Int)
                if prompt != nil || completion != nil {
                    continuation.yield(.usage(promptTokens: prompt, completionTokens: completion))
                }
                let cached = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
                    ?? (usage["prompt_cache_hit_tokens"] as? Int)
                if let cached = LLMUsage.valid(cached), cached > 0 {
                    continuation.yield(.cacheUsage(cachedTokens: cached, cacheWriteTokens: nil))
                }
            }

            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else {
                continue
            }

            if let finish = first["finish_reason"] as? String, !finish.isEmpty { completed = true }
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

            if let annotations = delta["annotations"] as? [[String: Any]] {
                for ann in annotations where (ann["type"] as? String) == "url_citation" {
                    if let cite = ann["url_citation"] as? [String: Any],
                       let url = cite["url"] as? String, !url.isEmpty {
                        let title = (cite["title"] as? String) ?? url
                        continuation.yield(.groundingSource(title: title, url: url))
                    }
                }
            }

            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for (offset, tc) in toolCalls.enumerated() {
                    let index: Int
                    if let explicit = tc["index"] as? Int {
                        index = explicit
                    } else if let tcID = tc["id"] as? String, !tcID.isEmpty,
                              let matchedKey = pendingToolCalls.first(where: { $0.value.id == tcID })?.key {
                        index = matchedKey
                    } else if toolCalls.count > 1 {
                        index = offset
                    } else if let tcID = tc["id"] as? String, !tcID.isEmpty,
                              let maxKey = pendingToolCalls.keys.max(),
                              !(pendingToolCalls[maxKey]?.id.isEmpty ?? true) {
                        index = maxKey + 1
                    } else {
                        index = pendingToolCalls.keys.max() ?? 0
                    }
                    guard (0..<64).contains(index) else { throw LLMError.unavailableTool }
                    var entry = pendingToolCalls[index] ?? (id: "", name: "", args: "")
                    if let tcID = tc["id"] as? String, !tcID.isEmpty {
                        entry.id = tcID
                    }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { entry.name += name }
                        if let args = fn["arguments"] as? String { entry.args += args }
                    }
                    guard entry.id.utf8.count <= 256, entry.name.utf8.count <= 128,
                          entry.args.utf8.count <= 64 * 1024 else { throw LLMError.unavailableTool }
                    pendingToolCalls[index] = entry
                }
            }

            if !reportedFinish,
               let reason = LLMFinishReason.fromProviderValue(first["finish_reason"] as? String) {
                reportedFinish = true
                continuation.yield(.finished(reason))
            }
        }

        guard completed else { throw LLMError.interruptedStream }
        if !receivedNativeReasoning {
            emit(thinkParser.finish(), to: continuation)
        }
        for index in pendingToolCalls.keys.sorted() {
            if let entry = pendingToolCalls[index], !entry.name.isEmpty {
                continuation.yield(.toolCall(LLMToolCall(
                    id: entry.id.isEmpty ? UUID().uuidString : entry.id,
                    name: entry.name,
                    argumentsJSON: entry.args.isEmpty ? "{}" : entry.args
                )))
            }
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

    static func buildRequestBody(
        _ request: LLMChatRequest,
        includeUsageOption: Bool = true,
        includeNativeSearch: Bool? = nil,
        includeReasoningContent: Bool = true,
        includeReasoningParams: Bool = true,
        useMaxCompletionTokens: Bool? = nil,
        includeSamplingParams: Bool = true
    ) -> [String: Any] {
        let useNativeSearch = includeNativeSearch ?? request.enableNativeSearch
        let sanitizedMessages = LLMClient.sanitizeToolHistory(request.messages)
        var wireMessages: [[String: Any]] = []
        let baseModel = baseModelName(request.modelID)
        let viaOpenRouter = isOpenRouter(request.baseURL)
        let isOpenAIReasoning = isOpenAIReasoningModel(baseModel)
        let directOpenAIHost = isDirectOpenAIHost(request.baseURL)

        let trimmedSystem = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            wireMessages.append([
                "role": "system",
                "content": trimmedSystem
            ])
        }

        for msg in sanitizedMessages {
            if msg.role == .tool {
                wireMessages.append([
                    "role": "tool",
                    "tool_call_id": msg.toolCallID ?? "",
                    "content": msg.content
                ])
                continue
            }

            if msg.role == .assistant && !msg.toolCalls.isEmpty {
                var assistantObj: [String: Any] = [
                    "role": "assistant",
                    "tool_calls": msg.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.argumentsJSON
                            ]
                        ] as [String: Any]
                    }
                ]
                assistantObj["content"] = msg.content.isEmpty ? NSNull() : msg.content
                if includeReasoningContent && !msg.reasoningContent.isEmpty && !directOpenAIHost && (!isOpenAIReasoning || viaOpenRouter) {
                    assistantObj["reasoning_content"] = msg.reasoningContent
                }
                wireMessages.append(assistantObj)
                continue
            }

            let roleStr = msg.role == .assistant ? "assistant" : "user"
            let combinedText = LLMClient.composeTextWithDocuments(
                text: msg.content,
                attachments: msg.attachments,
                includePDFText: true
            )
            let imageAttachments = msg.attachments.filter { $0.kind == .image && $0.dataBase64 != nil }

            let newContent: Any
            if imageAttachments.isEmpty || msg.role == .assistant {
                if combinedText.isEmpty && msg.role == .assistant && !msg.attachments.isEmpty {
                    newContent = "[Generated image: \(msg.attachments.map(\.fileName).joined(separator: ", "))]"
                } else {
                    newContent = combinedText.isEmpty ? "..." : combinedText
                }
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
                if parts.isEmpty {
                    parts.append(["type": "text", "text": "..."])
                }
                newContent = parts
            }

            if let last = wireMessages.last, (last["role"] as? String) == roleStr,
               last["tool_calls"] == nil {
                let mergedContent: Any
                if let prevStr = last["content"] as? String, let newStr = newContent as? String {
                    mergedContent = prevStr.isEmpty ? newStr : (newStr.isEmpty ? prevStr : "\(prevStr)\n\n\(newStr)")
                } else {
                    var combinedParts = asContentParts(last["content"])
                    combinedParts.append(contentsOf: asContentParts(newContent))
                    mergedContent = combinedParts
                }
                wireMessages[wireMessages.count - 1]["content"] = mergedContent
            } else {
                wireMessages.append([
                    "role": roleStr,
                    "content": newContent
                ])
            }
        }

        if let firstNonSystem = wireMessages.firstIndex(where: { ($0["role"] as? String) != "system" }),
           (wireMessages[firstNonSystem]["role"] as? String) == "assistant" {
            wireMessages.insert([
                "role": "user",
                "content": String(localized: "继续")
            ], at: firstNonSystem)
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "messages": wireMessages,
            "stream": true
        ]

        let omitSampling = !includeSamplingParams || isOpenAIReasoning || baseModel.contains("reasoner")

        if let temp = request.temperature, !omitSampling {
            body["temperature"] = temp
        }
        if request.topP < 0.999, !omitSampling {
            body["top_p"] = request.topP
        }
        if let maxTokens = request.maxOutputTokens, maxTokens > 0 {
            let preferCompletionKey = useMaxCompletionTokens ?? (isOpenAIReasoning && !viaOpenRouter)
            let key = preferCompletionKey ? "max_completion_tokens" : "max_tokens"
            body[key] = maxTokens
        }
        if includeUsageOption {
            body["stream_options"] = ["include_usage": true]
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersObject
                    ] as [String: Any]
                ] as [String: Any]
            }
        }
        if useNativeSearch {
            if viaOpenRouter {
                body["plugins"] = [["id": "web"]]
            } else {
                body["web_search_options"] = ["search_context_size": "medium"]
            }
        }
        if includeReasoningParams {
            body.merge(reasoningParameters(for: request)) { _, new in new }
        }
        return body
    }

    static func reasoningParameters(for request: LLMChatRequest) -> [String: Any] {
        guard request.supportsReasoning else { return [:] }
        let baseModel = baseModelName(request.modelID)
        let budget = max(1024, request.thinkingBudgetTokens)

        if isOpenRouter(request.baseURL) {
            return request.enableThinking ? ["reasoning": ["max_tokens": budget]] : [:]
        }

        if isOpenAIReasoningModel(baseModel) {
            if baseModel.hasPrefix("o1-mini") || baseModel.hasPrefix("o1-preview") {
                return [:]
            }
            let effort: String
            if !request.enableThinking || budget <= 2048 {
                effort = "low"
            } else if budget <= 8192 {
                effort = "medium"
            } else {
                effort = "high"
            }
            return ["reasoning_effort": effort]
        }

        if URLComponents(string: request.baseURL)?.host?.lowercased() == "api.deepseek.com",
           baseModel == "deepseek-flash" || baseModel.hasPrefix("deepseek-v4") {
            return ["thinking": ["type": request.enableThinking ? "enabled" : "disabled"]]
        }

        if baseModel.contains("qwen3"), !baseModel.contains("instruct"), !baseModel.contains("thinking") {
            var params: [String: Any] = ["enable_thinking": request.enableThinking]
            if request.enableThinking {
                params["thinking_budget"] = budget
            }
            return params
        }

        return [:]
    }

    static func baseModelName(_ modelID: String) -> String {
        let lower = modelID.lowercased()
        return lower.split(separator: "/").last.map(String.init) ?? lower
    }

    private static func asContentParts(_ content: Any?) -> [[String: Any]] {
        if let parts = content as? [[String: Any]] {
            return parts
        }
        if let text = content as? String, !text.isEmpty {
            return [["type": "text", "text": text]]
        }
        return []
    }

    static func isOpenAIReasoningModel(_ baseModel: String) -> Bool {
        if baseModel.contains("-chat") { return false }
        return ["o1", "o3", "o4", "gpt-5", "gpt-6"].contains { baseModel.hasPrefix($0) }
    }

    static func isOpenRouter(_ baseURL: String) -> Bool {
        let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    private static func isDirectOpenAIHost(_ baseURL: String) -> Bool {
        let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        return host == "api.openai.com" || host.hasSuffix(".openai.com")
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
        if let annotations = message["annotations"] as? [[String: Any]] {
            for ann in annotations where (ann["type"] as? String) == "url_citation" {
                if let cite = ann["url_citation"] as? [String: Any],
                   let url = cite["url"] as? String, !url.isEmpty {
                    let title = (cite["title"] as? String) ?? url
                    continuation.yield(.groundingSource(title: title, url: url))
                }
            }
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let tcID = (tc["id"] as? String) ?? UUID().uuidString
                if let fn = tc["function"] as? [String: Any],
                   let name = fn["name"] as? String, !name.isEmpty {
                    let args = (fn["arguments"] as? String) ?? "{}"
                    continuation.yield(.toolCall(LLMToolCall(id: tcID, name: name, argumentsJSON: args)))
                }
            }
        }
        if let usage = obj["usage"] as? [String: Any] {
            continuation.yield(.usage(
                promptTokens: LLMUsage.valid(usage["prompt_tokens"] as? Int),
                completionTokens: LLMUsage.valid(usage["completion_tokens"] as? Int)
            ))
            let cached = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int)
                ?? (usage["prompt_cache_hit_tokens"] as? Int)
            if let cached = LLMUsage.valid(cached), cached > 0 {
                continuation.yield(.cacheUsage(cachedTokens: cached, cacheWriteTokens: nil))
            }
        }
        if let reason = LLMFinishReason.fromProviderValue(first["finish_reason"] as? String) {
            continuation.yield(.finished(reason))
        }
    }

    // MARK: - Models

    private static let nonChatModelPrefixes = [
        "gpt-image", "gpt-realtime", "gpt-live", "gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe",
        "gpt-4o-mini-tts", "gpt-4o-realtime", "text-embedding", "omni-moderation", "text-moderation",
        "whisper-", "tts-", "dall-e", "sora-"
    ]

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

        let json = try await ModelListTransport.json(for: req, session: session)
        let items: [[String: Any]]
        if let dict = json as? [String: Any], let arr = dict["data"] as? [[String: Any]] {
            items = arr
        } else if let dict = json as? [String: Any], let arr = dict["models"] as? [[String: Any]] {
            items = arr
        } else if let arr = json as? [[String: Any]] {
            items = arr
        } else {
            throw URLError(.cannotParseResponse)
        }
        guard items.count <= ModelListTransport.maximumEntries else { throw URLError(.dataLengthExceedsMaximum) }

        var ranked: [(model: ModelSpec, created: Double, position: Int)] = []
        var seen = Set<String>()
        for (position, item) in items.enumerated() {
            guard let rawID = (item["id"] as? String) ?? (item["name"] as? String) else { throw URLError(.cannotParseResponse) }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw URLError(.cannotParseResponse) }
            guard !seen.contains(id) else { continue }
            let architecture = item["architecture"] as? [String: Any]
            let outputs = (item["output_modalities"] ?? architecture?["output_modalities"]) as? [String]
            if let outputs, !outputs.contains("text") { continue }
            if url.host?.lowercased() == "api.openai.com", nonChatModelPrefixes.contains(where: id.hasPrefix) { continue }
            seen.insert(id)
            let displayName = (item["name"] as? String) ?? id
            let inputs = (item["input_modalities"] ?? architecture?["input_modalities"]) as? [String]
            let efforts = ((item["effort"] as? [String: Any])?["supported_levels"] ?? item["supported_reasoning_efforts"]) as? [String]
            let spec = ModelSpec(id: id, displayName: displayName, supportsVision: inputs?.contains("image"),
                                 supportsReasoning: efforts.map { !$0.isEmpty })
            ranked.append((spec, (item["created"] as? NSNumber)?.doubleValue ?? 0, position))
        }
        return ranked.sorted {
            if $0.created != $1.created { return $0.created > $1.created }
            return $0.position < $1.position
        }.map(\.model)
    }
}
