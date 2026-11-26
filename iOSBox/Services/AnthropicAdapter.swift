import Foundation

enum AnthropicAdapter {
    private static let anthropicVersion = "2023-06-01"

    private struct WireOptions: Sendable {
        var useCache: Bool
        var useNativeSearch: Bool
        var useThinking: Bool
        var clampMaxTokensTo4096: Bool
    }

    static func streamChat(
        _ request: LLMChatRequest,
        capabilityCache: GatewayCapabilityCache = .shared,
        keyRouter: APIKeyPoolRouter = .shared,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let initial = WireOptions(
            useCache: request.enablePromptCaching && !capabilityCache.isUnsupported(
                .promptCaching,
                protocolType: .anthropic,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useNativeSearch: request.enableNativeSearch && !capabilityCache.isUnsupported(
                .nativeSearch,
                protocolType: .anthropic,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            useThinking: request.enableThinking && request.supportsReasoning && !capabilityCache.isUnsupported(
                .thinkingConfig,
                protocolType: .anthropic,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            clampMaxTokensTo4096: false
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
                    protocolType: .anthropic,
                    modelID: request.modelID
                )
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
                if !activeKey.isEmpty {
                    urlRequest.setValue(activeKey, forHTTPHeaderField: "x-api-key")
                }
                LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)
                let payload = buildRequestBody(
                    request,
                    includeCacheControl: state.useCache,
                    includeNativeSearch: state.useNativeSearch,
                    includeThinking: state.useThinking,
                    maxTokensCap: state.clampMaxTokensTo4096 ? 4096 : nil
                )
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
                return urlRequest
            },
            degradeOn400: { _, detail, state, newlyDisabled in
                let lower = detail.lowercased()
                if LLMClient.isUnrecoverable400(lower) {
                    return false
                }
                if state.useCache && lower.contains("cache_control") {
                    state.useCache = false
                    newlyDisabled.insert(.promptCaching)
                    return true
                }
                if state.useThinking && (lower.contains("thinking") || lower.contains("budget_tokens") || lower.contains("adaptive") || lower.contains("display")) {
                    state.useThinking = false
                    newlyDisabled.insert(.thinkingConfig)
                    return true
                }
                let mentionsNativeSearch = LLMClient.mentionsNativeSearchIdentifier(lower)
                if state.useNativeSearch && (mentionsNativeSearch || (request.tools.isEmpty && (lower.contains("tools") || lower.contains("tool")))) {
                    state.useNativeSearch = false
                    newlyDisabled.insert(.nativeSearch)
                    return true
                }
                if !state.clampMaxTokensTo4096 && lower.contains("max_tokens") {
                    state.clampMaxTokensTo4096 = true
                    return true
                }
                return false
            },
            consumeStream: { bytes, _, touch, continuation in
                try await consumeAcceptedResponse(
                    bytes: bytes,
                    onActivity: touch,
                    continuation: continuation
                )
            }
        )
    }

    private static func consumeAcceptedResponse(
        bytes: URLSession.AsyncBytes,
        onActivity: @escaping @Sendable () -> Void,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        var completed = false
        var baseInputTokens: Int?
        var inputTokens: Int?
        var outputTokens: Int?
        var cachedTokens: Int?
        var cacheWriteTokens: Int?
        var pendingToolBlocks: [Int: (id: String, name: String, json: String, initialInput: Any?)] = [:]
        var pendingThinkingBlocks: [Int: (thinking: String, signature: String)] = [:]

        eventLoop: for try await dataPart in SSEDecoder.events(bytes, onActivity: onActivity) {
            try Task.checkCancellation()
            if dataPart == "[DONE]" { completed = true; break }
            if dataPart.isEmpty { continue }
            let obj = try SSEDecoder.jsonObject(dataPart)
            guard let eventType = obj["type"] as? String else { throw LLMError.interruptedStream }

            switch eventType {
            case "message_stop":
                completed = true
                break eventLoop

            case "message_start":
                if let msg = obj["message"] as? [String: Any],
                   let usage = msg["usage"] as? [String: Any] {
                    let baseIn = LLMUsage.valid(usage["input_tokens"] as? Int)
                    let cacheRead = LLMUsage.valid(usage["cache_read_input_tokens"] as? Int)
                    let cacheWrite = LLMUsage.valid(usage["cache_creation_input_tokens"] as? Int)
                    if let baseIn { baseInputTokens = baseIn }
                    if let cacheRead, cacheRead > 0 { cachedTokens = cacheRead }
                    if let cacheWrite, cacheWrite > 0 { cacheWriteTokens = cacheWrite }
                    inputTokens = LLMUsage.combined(baseIn, cacheRead, cacheWrite)
                }

            case "content_block_start":
                if let index = obj["index"] as? Int,
                   let block = obj["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String {
                    if blockType == "tool_use",
                       let id = block["id"] as? String,
                       let name = block["name"] as? String {
                        pendingToolBlocks[index] = (id: id, name: name, json: "", initialInput: block["input"])
                    } else if blockType == "thinking" {
                        let initialThinking = block["thinking"] as? String ?? ""
                        let initialSig = block["signature"] as? String ?? ""
                        if !initialThinking.isEmpty {
                            continuation.yield(.reasoningDelta(initialThinking))
                        }
                        pendingThinkingBlocks[index] = (thinking: initialThinking, signature: initialSig)
                    } else if blockType == "redacted_thinking",
                              let data = block["data"] as? String, !data.isEmpty {
                        continuation.yield(.thinkingBlock(LLMThinkingBlock(redactedData: data)))
                    } else if blockType == "web_search_tool_result",
                              let items = block["content"] as? [[String: Any]] {
                        for item in items where (item["type"] as? String) == "web_search_result" {
                            if let url = item["url"] as? String, !url.isEmpty {
                                let title = (item["title"] as? String) ?? url
                                continuation.yield(.groundingSource(title: title, url: url))
                            }
                        }
                    }
                }

            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String {
                    let blockIndex = obj["index"] as? Int
                    if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                        if let blockIndex {
                            var entry = pendingThinkingBlocks[blockIndex] ?? (thinking: "", signature: "")
                            entry.thinking += thinking
                            pendingThinkingBlocks[blockIndex] = entry
                        }
                        continuation.yield(.reasoningDelta(thinking))
                    } else if deltaType == "signature_delta", let sig = delta["signature"] as? String, !sig.isEmpty {
                        if let blockIndex {
                            var entry = pendingThinkingBlocks[blockIndex] ?? (thinking: "", signature: "")
                            entry.signature += sig
                            pendingThinkingBlocks[blockIndex] = entry
                        }
                    } else if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        continuation.yield(.contentDelta(text))
                    } else if deltaType == "input_json_delta",
                              let index = blockIndex,
                              let partial = delta["partial_json"] as? String,
                              var entry = pendingToolBlocks[index] {
                        entry.json += partial
                        pendingToolBlocks[index] = entry
                    }
                }

            case "content_block_stop":
                if let index = obj["index"] as? Int {
                    if let thinkingEntry = pendingThinkingBlocks.removeValue(forKey: index) {
                        continuation.yield(.thinkingBlock(LLMThinkingBlock(
                            thinking: thinkingEntry.thinking,
                            signature: thinkingEntry.signature.isEmpty ? nil : thinkingEntry.signature
                        )))
                    }
                    if let entry = pendingToolBlocks.removeValue(forKey: index) {
                        emitToolCall(entry, to: continuation)
                    }
                }

            case "message_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let reason = LLMFinishReason.fromProviderValue(delta["stop_reason"] as? String) {
                    continuation.yield(.finished(reason))
                }
                if let usage = obj["usage"] as? [String: Any] {
                    if let deltaIn = LLMUsage.valid(usage["input_tokens"] as? Int) {
                        baseInputTokens = max(baseInputTokens ?? 0, deltaIn)
                    }
                    if let deltaCacheRead = LLMUsage.valid(usage["cache_read_input_tokens"] as? Int), deltaCacheRead > 0 {
                        cachedTokens = max(cachedTokens ?? 0, deltaCacheRead)
                    }
                    if let deltaCacheWrite = LLMUsage.valid(usage["cache_creation_input_tokens"] as? Int), deltaCacheWrite > 0 {
                        cacheWriteTokens = max(cacheWriteTokens ?? 0, deltaCacheWrite)
                    }
                    if let updatedCombined = LLMUsage.combined(baseInputTokens, cachedTokens, cacheWriteTokens) {
                        inputTokens = max(inputTokens ?? 0, updatedCombined)
                    }
                    if let outTok = LLMUsage.valid(usage["output_tokens"] as? Int) {
                        outputTokens = max(outputTokens ?? 0, outTok)
                    }
                    if inputTokens != nil || outputTokens != nil {
                        continuation.yield(.usage(promptTokens: inputTokens, completionTokens: outputTokens))
                    }
                }

            case "error":
                if let err = obj["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    throw LLMError.apiError(msg)
                }

            default:
                break
            }
        }

        guard completed else { throw LLMError.interruptedStream }
        for index in pendingThinkingBlocks.keys.sorted() {
            if let thinkingEntry = pendingThinkingBlocks.removeValue(forKey: index) {
                continuation.yield(.thinkingBlock(LLMThinkingBlock(
                    thinking: thinkingEntry.thinking,
                    signature: thinkingEntry.signature.isEmpty ? nil : thinkingEntry.signature
                )))
            }
        }
        for index in pendingToolBlocks.keys.sorted() {
            if let entry = pendingToolBlocks.removeValue(forKey: index) {
                emitToolCall(entry, to: continuation)
            }
        }
        if inputTokens != nil || outputTokens != nil {
            continuation.yield(.usage(promptTokens: inputTokens, completionTokens: outputTokens))
        }
        if cachedTokens != nil || cacheWriteTokens != nil {
            continuation.yield(.cacheUsage(cachedTokens: cachedTokens, cacheWriteTokens: cacheWriteTokens))
        }
    }

    private static func emitToolCall(
        _ entry: (id: String, name: String, json: String, initialInput: Any?),
        to continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) {
        let finalJSON: String
        if !entry.json.isEmpty {
            finalJSON = entry.json
        } else if let inputObj = entry.initialInput,
                  JSONSerialization.isValidJSONObject(inputObj),
                  let data = try? JSONSerialization.data(withJSONObject: inputObj) {
            finalJSON = String(decoding: data, as: UTF8.self)
        } else {
            finalJSON = "{}"
        }
        continuation.yield(.toolCall(LLMToolCall(id: entry.id, name: entry.name, argumentsJSON: finalJSON)))
    }

    static func buildRequestBody(
        _ request: LLMChatRequest,
        includeCacheControl: Bool? = nil,
        includeNativeSearch: Bool? = nil,
        includeThinking: Bool = true,
        maxTokensCap: Int? = nil
    ) -> [String: Any] {
        let useCache = includeCacheControl ?? request.enablePromptCaching
        let useNativeSearch = includeNativeSearch ?? request.enableNativeSearch
        let sanitizedMessages = LLMClient.sanitizeToolHistory(request.messages)
        // Anthropic requires every assistant `tool_use` turn to start with a signed `thinking` or
        // `redacted_thinking` block whenever `thinking` is enabled on the request. If an upstream
        // relay stripped signatures on an earlier tool round, degrade gracefully for this follow-up.
        let hasUnsignedAssistantToolTurn = sanitizedMessages.contains { msg in
            guard msg.role == .assistant && !msg.toolCalls.isEmpty else { return false }
            return !msg.thinkingBlocks.contains { block in
                switch block.kind {
                case .thinking: return block.signature?.isEmpty == false
                case .redactedThinking: return block.redactedData?.isEmpty == false
                }
            }
        }
        let wantsThinking = includeThinking && request.enableThinking && request.supportsReasoning && !hasUnsignedAssistantToolTurn
        let model = request.modelID.lowercased()
        let usesAdaptiveThinking = ["claude-sonnet-5", "claude-opus-5", "claude-haiku-5", "claude-fable-5",
                                    "claude-mythos-5", "claude-opus-4-7", "claude-opus-4-8"].contains { model.contains($0) }

        let requestedMax = request.maxOutputTokens ?? 0
        let unclampedMaxTokens: Int
        var budget = max(1024, request.thinkingBudgetTokens)
        if usesAdaptiveThinking {
            unclampedMaxTokens = requestedMax > 0 ? requestedMax : defaultMaxTokens(for: request.modelID)
        } else if wantsThinking {
            // Respect an explicit, sufficient user limit; otherwise leave room for the visible
            // answer while staying within the smallest output cap among thinking-capable
            // Claude models. budget_tokens must stay below max_tokens.
            if requestedMax > budget + 1024 {
                unclampedMaxTokens = requestedMax
            } else {
                unclampedMaxTokens = min(budget + 8192, thinkingOutputCap)
            }
            budget = max(1024, min(budget, unclampedMaxTokens - 4096))
        } else if requestedMax > 0 {
            unclampedMaxTokens = requestedMax
        } else {
            unclampedMaxTokens = defaultMaxTokens(for: request.modelID)
        }

        let finalMaxTokens = maxTokensCap.map { min(unclampedMaxTokens, $0) } ?? unclampedMaxTokens
        let shouldSendThinking: Bool
        if wantsThinking {
            if usesAdaptiveThinking {
                shouldSendThinking = finalMaxTokens > 0
            } else if finalMaxTokens > 1024 {
                budget = max(1024, min(budget, finalMaxTokens - 1024))
                shouldSendThinking = budget < finalMaxTokens
            } else {
                shouldSendThinking = false
            }
        } else {
            shouldSendThinking = false
        }

        var wireMessages: [[String: Any]] = []

        for msg in sanitizedMessages {
            let roleStr = msg.role == .assistant ? "assistant" : "user"
            var blocks: [[String: Any]] = []

            if msg.role == .tool {
                blocks.append([
                    "type": "tool_result",
                    "tool_use_id": msg.toolCallID ?? "",
                    "content": msg.content
                ])
            } else if msg.role == .assistant && !msg.toolCalls.isEmpty {
                if shouldSendThinking {
                    for tb in msg.thinkingBlocks {
                        switch tb.kind {
                        case .thinking:
                            if let sig = tb.signature, !sig.isEmpty {
                                blocks.append([
                                    "type": "thinking",
                                    "thinking": tb.thinking,
                                    "signature": sig
                                ])
                            }
                        case .redactedThinking:
                            if let data = tb.redactedData, !data.isEmpty {
                                blocks.append([
                                    "type": "redacted_thinking",
                                    "data": data
                                ])
                            }
                        }
                    }
                }
                if !msg.content.isEmpty {
                    blocks.append(["type": "text", "text": msg.content])
                }
                for call in msg.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.argumentsDictionary
                    ])
                }
            } else {
                if msg.role == .user {
                    for att in msg.attachments {
                        if att.kind == .image, let base64 = att.dataBase64 {
                            blocks.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": att.mimeType,
                                    "data": base64
                                ]
                            ])
                        } else if att.kind == .document, att.mimeType == "application/pdf", let base64 = att.dataBase64 {
                            blocks.append([
                                "type": "document",
                                "source": [
                                    "type": "base64",
                                    "media_type": "application/pdf",
                                    "data": base64
                                ]
                            ])
                        }
                    }
                }

                let textPart = LLMClient.composeTextWithDocuments(
                    text: msg.content,
                    attachments: msg.attachments,
                    includePDFText: false
                )
                if !textPart.isEmpty {
                    blocks.append([
                        "type": "text",
                        "text": textPart
                    ])
                } else if blocks.isEmpty {
                    let placeholder = (msg.role == .assistant && !msg.attachments.isEmpty)
                        ? "[Generated image: \(msg.attachments.map(\.fileName).joined(separator: ", "))]"
                        : "..."
                    blocks.append([
                        "type": "text",
                        "text": placeholder
                    ])
                }
            }

            // Merge consecutive messages of the same role as required by Anthropic API, UNLESS
            // appending a signed `thinking` block onto an earlier `text` assistant turn would
            // place `text` ahead of `thinking` and trigger an Anthropic HTTP 400.
            if let last = wireMessages.last, (last["role"] as? String) == roleStr,
               var existingBlocks = last["content"] as? [[String: Any]] {
                let incomingHasThinking = blocks.contains {
                    let t = ($0["type"] as? String) ?? ""
                    return t == "thinking" || t == "redacted_thinking"
                }
                let existingHasNonThinking = existingBlocks.contains {
                    let t = ($0["type"] as? String) ?? ""
                    return t != "thinking" && t != "redacted_thinking"
                }
                if roleStr == "assistant" && incomingHasThinking && existingHasNonThinking {
                    wireMessages.append([
                        "role": "user",
                        "content": [["type": "text", "text": String(localized: "继续")]]
                    ])
                    wireMessages.append([
                        "role": roleStr,
                        "content": blocks
                    ])
                } else {
                    existingBlocks.append(contentsOf: blocks)
                    wireMessages[wireMessages.count - 1]["content"] = existingBlocks
                }
            } else {
                wireMessages.append([
                    "role": roleStr,
                    "content": blocks
                ])
            }
        }

        // Anthropic requires the first message to have role "user"
        if let firstRole = wireMessages.first?["role"] as? String, firstRole != "user" {
            wireMessages.insert([
                "role": "user",
                "content": [["type": "text", "text": String(localized: "继续")]]
            ], at: 0)
        }

        if useCache && !wireMessages.isEmpty {
            let indicesToTag = wireMessages.count >= 2
                ? [wireMessages.count - 2, wireMessages.count - 1]
                : [wireMessages.count - 1]
            for idx in indicesToTag {
                if var blocks = wireMessages[idx]["content"] as? [[String: Any]], !blocks.isEmpty {
                    var lastBlock = blocks[blocks.count - 1]
                    lastBlock["cache_control"] = ["type": "ephemeral"]
                    blocks[blocks.count - 1] = lastBlock
                    wireMessages[idx]["content"] = blocks
                }
            }
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "max_tokens": finalMaxTokens,
            "messages": wireMessages,
            "stream": true
        ]

        let trimmedSystem = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            if useCache {
                body["system"] = [[
                    "type": "text",
                    "text": trimmedSystem,
                    "cache_control": ["type": "ephemeral"]
                ]]
            } else {
                body["system"] = trimmedSystem
            }
        }

        var allTools: [[String: Any]] = request.tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.parametersObject
            ]
        }
        if useNativeSearch && !allTools.contains(where: { ($0["name"] as? String) == "web_search" }) {
            allTools.append([
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": 3
            ])
        }
        if !allTools.isEmpty {
            body["tools"] = allTools
        }

        if shouldSendThinking {
            if usesAdaptiveThinking {
                body["thinking"] = ["type": "adaptive", "display": "summarized"]
            } else {
                body["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": budget
                ]
            }
        } else if let temp = request.temperature {
            body["temperature"] = min(1.0, max(0.0, temp))
        }

        return body
    }

    /// Smallest max-output limit among thinking-capable Claude models (Claude Opus 4: 32k).
    static let thinkingOutputCap = 32_000

    /// Legacy Claude 3 models (Haiku / Sonnet / Opus) cap output at 4096 tokens;
    /// newer models allow far more, so 4096 needlessly truncated long code answers.
    static func defaultMaxTokens(for modelID: String) -> Int {
        let lower = modelID.lowercased()
        let isLegacyClaude3 = lower.contains("claude-3-")
            && !lower.contains("claude-3-5")
            && !lower.contains("claude-3-7")
        return isLegacyClaude3 ? 4096 : 8192
    }

    static func fetchModels(
        baseURL: String,
        apiKey: String,
        customHeaders: [CustomHeader],
        session: URLSession
    ) async throws -> [ModelSpec] {
        let url = try EndpointResolver.modelsEndpoint(baseURL: baseURL, protocolType: .anthropic)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        LLMClient.applyCustomHeaders(customHeaders, to: &req)

        return try await ModelListTransport.pages(request: req, session: session, itemsKey: "data", cursorName: "after_id") { page, items in
            let models = try items.map { item -> ModelSpec in
                guard let id = item["id"] as? String, !id.isEmpty else { throw URLError(.cannotParseResponse) }
                return ModelSpec(id: id, displayName: item["display_name"] as? String)
            }
            guard page["has_more"] as? Bool == true else { return (models, nil) }
            guard let last = page["last_id"] as? String, !last.isEmpty else { throw URLError(.cannotParseResponse) }
            return (models, last)
        }
    }
}
