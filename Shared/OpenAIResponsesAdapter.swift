import Foundation

/// Native adapter for the OpenAI Responses API (`/v1/responses`), supporting SSE text deltas,
/// reasoning summaries, native `web_search_preview`, and multi-turn `function_call` / `function_call_output`.
enum OpenAIResponsesAdapter {
    private struct WireOptions: Sendable {
        var useReasoningOption: Bool
        var useReasoningSummary: Bool
        var useNativeSearch: Bool
        var useStoreFalse: Bool
        var useSamplingParams: Bool
    }

    struct StreamParserState: Sendable {
        var activeFunctionCalls: [String: (callID: String, name: String, arguments: String)] = [:]
        var emittedToolCallIDs: Set<String> = []
        var emittedImageIDs: Set<String> = []
        var emittedVisibleText = false
        var completed = false
        var reportedFinish = false
    }

    private static func isReasoningFamilyModel(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        let base = lower.split(separator: "/").last.map(String.init) ?? lower
        if base.contains("-chat") { return false }
        return base.contains("reasoner") || ["o1", "o3", "o4", "gpt-5", "gpt-6"].contains { base.hasPrefix($0) }
    }

    static func streamChat(
        _ request: LLMChatRequest,
        capabilityCache: GatewayCapabilityCache = .shared,
        keyRouter: APIKeyPoolRouter = .shared,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let wantsReasoning = request.supportsReasoning && request.enableThinking
        let initial = WireOptions(
            useReasoningOption: wantsReasoning && !capabilityCache.isUnsupported(
                .reasoningParams,
                protocolType: .openAIResponses,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useReasoningSummary: wantsReasoning && !capabilityCache.isUnsupported(
                .reasoningSummary,
                protocolType: .openAIResponses,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useNativeSearch: request.enableNativeSearch && !capabilityCache.isUnsupported(
                .nativeSearch,
                protocolType: .openAIResponses,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useStoreFalse: !capabilityCache.isUnsupported(
                .storeFlag,
                protocolType: .openAIResponses,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useSamplingParams: !capabilityCache.isUnsupported(
                .samplingParams,
                protocolType: .openAIResponses,
                baseURL: request.baseURL,
                modelID: request.modelID
            )
        )

        let omitSamplingByModel = isReasoningFamilyModel(request.modelID) || wantsReasoning
        let hasSamplingParams = !omitSamplingByModel && (request.temperature != nil || request.topP < 0.999)

        return LLMClient.streamWithResilience(
            request: request,
            initialState: initial,
            capabilityCache: capabilityCache,
            keyRouter: keyRouter,
            session: session,
            buildURLRequest: { activeKey, state in
                let url = try EndpointResolver.chatEndpoint(
                    baseURL: request.baseURL,
                    protocolType: .openAIResponses,
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
                let body = buildRequestBody(
                    request,
                    includeReasoning: state.useReasoningOption,
                    includeReasoningSummary: state.useReasoningSummary,
                    includeNativeSearch: state.useNativeSearch,
                    includeStoreFalse: state.useStoreFalse,
                    includeSamplingParams: state.useSamplingParams
                )
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
                return urlRequest
            },
            degradeOn400: { _, detail, state, newlyDisabled in
                let lower = detail.lowercased()
                if LLMClient.isUnrecoverable400(lower) {
                    return false
                }
                // Degrade `reasoning.summary` first (unverified orgs reject `summary: "auto"` while supporting `effort`).
                if state.useReasoningOption && state.useReasoningSummary
                    && (lower.contains("summary") || lower.contains("verified") || lower.contains("organization")) {
                    state.useReasoningSummary = false
                    newlyDisabled.insert(.reasoningSummary)
                    return true
                }
                if state.useReasoningOption && (lower.contains("reasoning") || lower.contains("effort")) {
                    state.useReasoningOption = false
                    newlyDisabled.insert(.reasoningParams)
                    return true
                }
                if state.useStoreFalse && lower.contains("store") {
                    state.useStoreFalse = false
                    newlyDisabled.insert(.storeFlag)
                    return true
                }
                if hasSamplingParams && state.useSamplingParams && (lower.contains("temperature") || lower.contains("top_p")) {
                    state.useSamplingParams = false
                    newlyDisabled.insert(.samplingParams)
                    return true
                }
                let mentionsNativeSearch = LLMClient.mentionsNativeSearchIdentifier(lower)
                if state.useNativeSearch && (mentionsNativeSearch || (request.tools.isEmpty && (lower.contains("tools") || lower.contains("tool")))) {
                    state.useNativeSearch = false
                    newlyDisabled.insert(.nativeSearch)
                    return true
                }
                let mentionsCustomToolsOnly = !request.tools.isEmpty
                    && !mentionsNativeSearch
                    && (lower.contains("tools") || lower.contains("tool"))
                if !mentionsCustomToolsOnly && LLMClient.isGenericParameterRejection400(lower) {
                    if state.useNativeSearch && request.tools.isEmpty {
                        state.useNativeSearch = false
                        newlyDisabled.insert(.nativeSearch)
                        return true
                    }
                    if state.useReasoningOption && state.useReasoningSummary {
                        state.useReasoningSummary = false
                        newlyDisabled.insert(.reasoningSummary)
                        return true
                    }
                    if state.useReasoningOption {
                        state.useReasoningOption = false
                        newlyDisabled.insert(.reasoningParams)
                        return true
                    }
                    if state.useStoreFalse {
                        state.useStoreFalse = false
                        newlyDisabled.insert(.storeFlag)
                        return true
                    }
                }
                return false
            },
            consumeStream: { bytes, response, touch, continuation in
                try await consumeAcceptedResponse(
                    bytes: bytes,
                    response: response,
                    expectsImage: request.wantsImage,
                    onActivity: touch,
                    continuation: continuation
                )
            }
        )
    }

    // MARK: - Request Builder

    static func reasoningEffort(for budgetTokens: Int) -> String {
        switch budgetTokens {
        case ..<4096: return "low"
        case 4096..<12288: return "medium"
        default: return "high"
        }
    }

    private static func attachmentPlaceholder(for attachments: [MessageAttachment]) -> String {
        if attachments.contains(where: { $0.kind == .image }) {
            return "[图片]"
        }
        return "[附件]"
    }

    static func buildRequestBody(
        _ request: LLMChatRequest,
        includeReasoning: Bool = true,
        includeReasoningSummary: Bool = true,
        includeNativeSearch: Bool = false,
        includeStoreFalse: Bool = true,
        includeSamplingParams: Bool = true
    ) -> [String: Any] {
        let sanitizedMessages = LLMClient.sanitizeToolHistory(request.messages)
        var inputItems: [[String: Any]] = []

        for msg in sanitizedMessages {
            switch msg.role {
            case .system:
                continue

            case .user:
                var contentParts: [[String: Any]] = []
                if !msg.content.isEmpty {
                    contentParts.append([
                        "type": "input_text",
                        "text": msg.content
                    ])
                }
                for att in msg.attachments {
                    switch att.kind {
                    case .image:
                        if let b64 = att.dataBase64, !b64.isEmpty {
                            contentParts.append([
                                "type": "input_image",
                                "image_url": "data:\(att.mimeType);base64,\(b64)"
                            ])
                        }
                    case .document:
                        if att.mimeType == "application/pdf", let b64 = att.dataBase64, !b64.isEmpty {
                            contentParts.append([
                                "type": "input_file",
                                "filename": att.fileName,
                                "file_data": "data:application/pdf;base64,\(b64)"
                            ])
                        } else if let extracted = att.extractedText, !extracted.isEmpty {
                            contentParts.append([
                                "type": "input_text",
                                "text": "[\(att.fileName)]\n\(extracted)"
                            ])
                        }
                    }
                }
                if contentParts.isEmpty {
                    contentParts.append([
                        "type": "input_text",
                        "text": attachmentPlaceholder(for: msg.attachments)
                    ])
                }
                inputItems.append([
                    "type": "message",
                    "role": "user",
                    "content": contentParts
                ])

            case .assistant:
                if !msg.content.isEmpty {
                    inputItems.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            ["type": "output_text", "text": msg.content]
                        ]
                    ])
                } else if msg.toolCalls.isEmpty {
                    inputItems.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            ["type": "output_text", "text": attachmentPlaceholder(for: msg.attachments)]
                        ]
                    ])
                }
                for call in msg.toolCalls {
                    inputItems.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.argumentsJSON
                    ])
                }

            case .tool:
                if let callID = msg.toolCallID, !callID.isEmpty {
                    inputItems.append([
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": msg.content
                    ])
                }
            }
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "input": inputItems,
            "stream": true
        ]
        if includeStoreFalse {
            body["store"] = false
        }

        let instructions = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }

        let isReasoningEnabled = request.supportsReasoning && request.enableThinking
        if includeReasoning && isReasoningEnabled {
            var reasoningObj: [String: Any] = [
                "effort": reasoningEffort(for: request.thinkingBudgetTokens)
            ]
            if includeReasoningSummary {
                reasoningObj["summary"] = "auto"
            }
            body["reasoning"] = reasoningObj
        }

        let omitSampling = !includeSamplingParams || isReasoningFamilyModel(request.modelID) || isReasoningEnabled
        if !omitSampling {
            if let temp = request.temperature {
                body["temperature"] = temp
            }
            if request.topP < 0.999 {
                body["top_p"] = request.topP
            }
        }

        if let maxTokens = request.maxOutputTokens, maxTokens > 0 {
            body["max_output_tokens"] = maxTokens
        }

        var tools: [[String: Any]] = []
        for tool in request.tools {
            tools.append([
                "type": "function",
                "name": tool.name,
                "description": tool.description,
                "parameters": tool.parametersObject,
                // Responses API defaults `strict` to true, which rejects optional tool properties with HTTP 400.
                "strict": false
            ])
        }
        if request.wantsImage {
            tools.append(["type": "image_generation", "action": "edit", "output_format": "png"])
            body["tool_choice"] = ["type": "image_generation"]
        }
        if includeNativeSearch {
            tools.append(["type": "web_search_preview"])
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }

        if let schema = request.schemaObject { body["text"] = ["format": ["type": "json_schema", "name": "result", "strict": true, "schema": schema]] }
        return body
    }

    // MARK: - Stream Consumer & Event Parser

    private static func consumeAcceptedResponse(
        bytes: URLSession.AsyncBytes,
        response: URLResponse,
        expectsImage: Bool,
        onActivity: @escaping @Sendable () -> Void,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""

        if contentType.contains("application/json") && !contentType.contains("event-stream") {
            continuation.yield(.nonStreamingResponse)
            let fullData = try await readNonStreamingData(bytes, onActivity: onActivity)
            try emitNonStreamingJSON(fullData, continuation: continuation)
            return
        }

        var state = StreamParserState()
        for try await dataPart in SSEDecoder.events(bytes, maximumBytes: expectsImage ? 20 * 1024 * 1024 : SSEDecoder.defaultMaximumBytes, onActivity: onActivity) {
            try Task.checkCancellation()
            if dataPart == "[DONE]" { state.completed = true; break }
            if dataPart.isEmpty { continue }
            let obj = try SSEDecoder.jsonObject(dataPart)
            let events = try parseSSEEventObject(obj, state: &state)
            for event in events {
                continuation.yield(event)
            }
            if state.completed { break }
        }

        guard state.completed else {
            throw LLMError.interruptedStream
        }
    }

    private static func generatedImage(_ item: [String: Any], state: inout StreamParserState) -> LLMStreamEvent? {
        guard item["type"] as? String == "image_generation_call",
              let encoded = item["result"] as? String, !encoded.isEmpty else { return nil }
        let id = item["id"] as? String
        if let id, state.emittedImageIDs.contains(id) { return nil }
        let padding = encoded.hasSuffix("==") ? 2 : (encoded.hasSuffix("=") ? 1 : 0)
        let attachment = MessageAttachment(kind: .image, fileName: "edited.png", mimeType: "image/png",
            dataBase64: encoded, extractedText: nil, byteSize: max(0, encoded.utf8.count / 4 * 3 - padding)).withBoundedImagePayload
        guard attachment.dataBase64 != nil else { return nil }
        if let id { state.emittedImageIDs.insert(id) }
        return .attachmentDelta(attachment)
    }

    static func parseSSEEventObject(
        _ obj: [String: Any],
        state: inout StreamParserState
    ) throws -> [LLMStreamEvent] {
        if let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            throw LLMError.apiError(message)
        }

        let eventType = obj["type"] as? String ?? ""
        var emitted: [LLMStreamEvent] = []

        switch eventType {
        case "response.output_text.delta", "response.refusal.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                state.emittedVisibleText = true
                emitted.append(.contentDelta(delta))
            }

        case "response.refusal.done":
            if !state.emittedVisibleText,
               let refusal = obj["refusal"] as? String, !refusal.isEmpty {
                state.emittedVisibleText = true
                emitted.append(.contentDelta(refusal))
            }

        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                emitted.append(.reasoningDelta(delta))
            }

        case "response.output_item.added":
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let itemID = (item["id"] as? String) ?? (item["call_id"] as? String) ?? UUID().uuidString
                let callID = (item["call_id"] as? String) ?? itemID
                let name = (item["name"] as? String) ?? ""
                let args = (item["arguments"] as? String) ?? ""
                state.activeFunctionCalls[itemID] = (callID: callID, name: name, arguments: args)
            }

        case "response.function_call_arguments.delta":
            let itemID = (obj["item_id"] as? String) ?? ""
            let delta = (obj["delta"] as? String) ?? ""
            if !itemID.isEmpty, var entry = state.activeFunctionCalls[itemID] {
                entry.arguments += delta
                state.activeFunctionCalls[itemID] = entry
            }

        case "response.function_call_arguments.done":
            let itemID = (obj["item_id"] as? String) ?? ""
            let finalArgs = (obj["arguments"] as? String)
            if var entry = state.activeFunctionCalls[itemID] {
                if let finalArgs { entry.arguments = finalArgs }
                state.activeFunctionCalls[itemID] = entry
                if !entry.name.isEmpty && state.emittedToolCallIDs.insert(entry.callID).inserted {
                    emitted.append(.toolCall(LLMToolCall(
                        id: entry.callID,
                        name: entry.name,
                        argumentsJSON: entry.arguments.isEmpty ? "{}" : entry.arguments
                    )))
                }
            }

        case "response.output_item.done":
            if let item = obj["item"] as? [String: Any], let image = generatedImage(item, state: &state) { emitted.append(image) }
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "function_call" {
                let itemID = (item["id"] as? String) ?? ""
                let callID = (item["call_id"] as? String) ?? itemID
                let name = (item["name"] as? String) ?? state.activeFunctionCalls[itemID]?.name ?? ""
                let args = (item["arguments"] as? String) ?? state.activeFunctionCalls[itemID]?.arguments ?? "{}"
                if !name.isEmpty && !callID.isEmpty && state.emittedToolCallIDs.insert(callID).inserted {
                    emitted.append(.toolCall(LLMToolCall(
                        id: callID,
                        name: name,
                        argumentsJSON: args.isEmpty ? "{}" : args
                    )))
                }
            }

        case "response.completed", "response.incomplete":
            state.completed = true
            if let resp = obj["response"] as? [String: Any] {
                for item in resp["output"] as? [[String: Any]] ?? [] {
                    if let image = generatedImage(item, state: &state) { emitted.append(image) }
                }
                if !state.emittedVisibleText, let outputs = resp["output"] as? [[String: Any]] {
                    for item in outputs {
                        let kind = item["type"] as? String ?? ""
                        if kind == "message", let content = item["content"] as? [[String: Any]] {
                            for part in content where (part["type"] as? String) == "refusal" {
                                if let refusal = part["refusal"] as? String, !refusal.isEmpty {
                                    state.emittedVisibleText = true
                                    emitted.append(.contentDelta(refusal))
                                }
                            }
                        } else if kind == "refusal", let refusal = item["refusal"] as? String, !refusal.isEmpty {
                            state.emittedVisibleText = true
                            emitted.append(.contentDelta(refusal))
                        }
                    }
                }
                emitted.append(contentsOf: extractUsageAndFinishEvents(from: resp, state: &state))
            }

        case "response.failed":
            let resp = obj["response"] as? [String: Any]
            let errObj = resp?["error"] as? [String: Any]
            let msg = (errObj?["message"] as? String) ?? String(localized: "Responses API 请求失败")
            throw LLMError.apiError(msg)

        case "error":
            let msg = (obj["message"] as? String) ?? String(localized: "Responses API 流式错误")
            throw LLMError.apiError(msg)

        default:
            break
        }

        return emitted
    }

    private static func extractUsageAndFinishEvents(
        from resp: [String: Any],
        state: inout StreamParserState
    ) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        if let usage = resp["usage"] as? [String: Any] {
            let inputTokens = usage["input_tokens"] as? Int
            let outputTokens = usage["output_tokens"] as? Int
            if inputTokens != nil || outputTokens != nil {
                events.append(.usage(promptTokens: inputTokens, completionTokens: outputTokens))
            }
            if let details = usage["input_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int, cached > 0 {
                events.append(.cacheUsage(cachedTokens: cached, cacheWriteTokens: nil))
            }
        }
        if !state.reportedFinish,
           let incomplete = resp["incomplete_details"] as? [String: Any],
           let reasonRaw = incomplete["reason"] as? String {
            if reasonRaw == "max_output_tokens" {
                state.reportedFinish = true
                events.append(.finished(.length))
            } else if let mapped = LLMFinishReason.fromProviderValue(reasonRaw) {
                state.reportedFinish = true
                events.append(.finished(mapped))
            }
        }
        return events
    }

    static func readNonStreamingData<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maximumBytes: Int = 16 * 1024 * 1024,
        onActivity: @escaping @Sendable () -> Void
    ) async throws -> Data where Bytes.Element == UInt8 {
        var fullData = Data()
        var bytesSinceTouch = 0
        for try await b in bytes {
            try Task.checkCancellation()
            fullData.append(b)
            guard fullData.count <= maximumBytes else { throw LLMError.interruptedStream }
            if fullData.count <= 4096 || bytesSinceTouch >= 256 {
                bytesSinceTouch = 0
                onActivity()
            } else {
                bytesSinceTouch += 1
            }
        }
        onActivity()
        return fullData
    }

    static func parseNonStreamingResponse(_ data: Data) throws -> [LLMStreamEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.emptyResponse
        }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            throw LLMError.apiError(msg)
        }
        var state = StreamParserState()
        var events: [LLMStreamEvent] = []
        if let outputs = obj["output"] as? [[String: Any]] {
            for item in outputs {
                let kind = item["type"] as? String ?? ""
                if let image = generatedImage(item, state: &state) { events.append(image) }
                else if kind == "message", let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        let partType = part["type"] as? String ?? ""
                        if partType == "refusal", let refusal = part["refusal"] as? String, !refusal.isEmpty {
                            events.append(.contentDelta(refusal))
                        } else if let text = part["text"] as? String, !text.isEmpty {
                            events.append(.contentDelta(text))
                        } else if let refusal = part["refusal"] as? String, !refusal.isEmpty {
                            events.append(.contentDelta(refusal))
                        }
                    }
                } else if kind == "refusal",
                          let refusal = (item["refusal"] as? String) ?? (item["text"] as? String),
                          !refusal.isEmpty {
                    events.append(.contentDelta(refusal))
                } else if kind == "reasoning", let summaries = item["summary"] as? [[String: Any]] {
                    for s in summaries {
                        if let text = s["text"] as? String, !text.isEmpty {
                            events.append(.reasoningDelta(text))
                        }
                    }
                } else if kind == "function_call",
                          let name = item["name"] as? String, !name.isEmpty {
                    let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? UUID().uuidString
                    let args = (item["arguments"] as? String) ?? "{}"
                    events.append(.toolCall(LLMToolCall(id: callID, name: name, argumentsJSON: args)))
                }
            }
        } else if let text = obj["output_text"] as? String, !text.isEmpty {
            events.append(.contentDelta(text))
        } else if let refusal = obj["refusal"] as? String, !refusal.isEmpty {
            events.append(.contentDelta(refusal))
        }
        events.append(contentsOf: extractUsageAndFinishEvents(from: obj, state: &state))
        return events
    }

    private static func emitNonStreamingJSON(
        _ data: Data,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) throws {
        for ev in try parseNonStreamingResponse(data) {
            continuation.yield(ev)
        }
    }
}
