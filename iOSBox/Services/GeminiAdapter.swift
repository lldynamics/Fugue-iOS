import Foundation

enum GeminiAdapter {
    private struct WireOptions: Sendable {
        var includeNativeSearch: Bool
        var includeThinkingConfig: Bool
        var includeSamplingParams: Bool
    }

    static func streamChat(
        _ request: LLMChatRequest,
        capabilityCache: GatewayCapabilityCache = .shared,
        keyRouter: APIKeyPoolRouter = .shared,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let hasThinkingConfig = thinkingConfig(for: request) != nil
        let initial = WireOptions(
            includeNativeSearch: request.enableNativeSearch && !capabilityCache.isUnsupported(
                .nativeSearch,
                protocolType: .gemini,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            includeThinkingConfig: !capabilityCache.isUnsupported(
                .thinkingConfig,
                protocolType: .gemini,
                baseURL: request.baseURL,
                modelID: request.modelID
            ),
            includeSamplingParams: !capabilityCache.isUnsupported(
                .samplingParams,
                protocolType: .gemini,
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
                    protocolType: .gemini,
                    modelID: request.modelID
                )
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if !activeKey.isEmpty {
                    urlRequest.setValue(activeKey, forHTTPHeaderField: "x-goog-api-key")
                }
                LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)
                let payload = buildRequestBody(
                    request,
                    includeNativeSearch: state.includeNativeSearch,
                    includeThinkingConfig: state.includeThinkingConfig,
                    includeSamplingParams: state.includeSamplingParams
                )
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
                return urlRequest
            },
            degradeOn400: { _, detail, state, newlyDisabled in
                let lower = detail.lowercased()
                if LLMClient.isUnrecoverable400(lower) {
                    return false
                }
                if hasThinkingConfig && state.includeThinkingConfig
                    && (lower.contains("thinking") || lower.contains("budget") || lower.contains("thinkinglevel")) {
                    state.includeThinkingConfig = false
                    newlyDisabled.insert(.thinkingConfig)
                    return true
                }
                let mentionsNativeSearch = LLMClient.mentionsNativeSearchIdentifier(lower)
                if state.includeNativeSearch && (mentionsNativeSearch || (request.tools.isEmpty && (lower.contains("tools") || lower.contains("tool")))) {
                    state.includeNativeSearch = false
                    newlyDisabled.insert(.nativeSearch)
                    return true
                }
                if state.includeSamplingParams && (lower.contains("temperature") || lower.contains("topp") || lower.contains("top_p")) {
                    state.includeSamplingParams = false
                    newlyDisabled.insert(.samplingParams)
                    return true
                }
                let mentionsCustomToolsOnly = !request.tools.isEmpty
                    && !mentionsNativeSearch
                    && (lower.contains("tools") || lower.contains("tool"))
                if !mentionsCustomToolsOnly
                    && LLMClient.isGenericParameterRejection400(lower)
                    && hasThinkingConfig
                    && state.includeThinkingConfig {
                    state.includeThinkingConfig = false
                    newlyDisabled.insert(.thinkingConfig)
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
        var reportedFinish = false
        var accumulatedThought = ""

        // Gemini inlineData image generation responses routinely exceed 2 MB per SSE event.
        for try await dataPart in SSEDecoder.events(bytes, maximumBytes: 20 * 1024 * 1024, onActivity: onActivity) {
            try Task.checkCancellation()
            if dataPart == "[DONE]" { completed = true; break }
            if dataPart.isEmpty { continue }
            let obj = try SSEDecoder.jsonObject(dataPart)

            if let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                throw LLMError.apiError(msg)
            }

            // The whole prompt was rejected; there will be no candidates.
            if let feedback = obj["promptFeedback"] as? [String: Any],
               let blockReason = feedback["blockReason"] as? String, !blockReason.isEmpty {
                throw LLMError.apiError(String(localized: "提问内容被 Gemini 安全策略拦截（\(blockReason)），请调整后重试。"))
            }

            if let candidates = obj["candidates"] as? [[String: Any]],
               let first = candidates.first {
                if let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let fnCall = part["functionCall"] as? [String: Any],
                           let name = fnCall["name"] as? String, !name.isEmpty {
                            let argsObj = fnCall["args"]
                            let argsJSON: String
                            if let argsObj, JSONSerialization.isValidJSONObject(argsObj),
                               let data = try? JSONSerialization.data(withJSONObject: argsObj) {
                                argsJSON = String(decoding: data, as: UTF8.self)
                            } else {
                                argsJSON = "{}"
                            }
                            let sig = part["thoughtSignature"] as? String
                            continuation.yield(.toolCall(LLMToolCall(
                                id: UUID().uuidString,
                                name: name,
                                argumentsJSON: argsJSON,
                                thoughtSignature: sig
                            )))
                            continue
                        }

                        if let inline = part["inlineData"] as? [String: Any],
                           let dataB64 = inline["data"] as? String, !dataB64.isEmpty {
                            let mime = (inline["mimeType"] as? String) ?? "image/png"
                            if mime.lowercased().hasPrefix("image/") {
                                let ext = mime.lowercased().contains("jpeg") || mime.lowercased().contains("jpg")
                                    ? "jpg"
                                    : (mime.lowercased().contains("webp") ? "webp" : "png")
                                let padding = dataB64.hasSuffix("==") ? 2 : (dataB64.hasSuffix("=") ? 1 : 0)
                                let byteCount = max(0, dataB64.utf8.count / 4 * 3 - padding)
                                let attachment = MessageAttachment(
                                    kind: .image,
                                    fileName: "generated.\(ext)",
                                    mimeType: mime,
                                    dataBase64: dataB64,
                                    extractedText: nil,
                                    byteSize: byteCount
                                ).withBoundedImagePayload
                                if attachment.dataBase64 != nil { continuation.yield(.attachmentDelta(attachment)) }
                                continue
                            }
                        }

                        let text = (part["text"] as? String) ?? ""
                        let isThought = (part["thought"] as? Bool) ?? false
                        let sig = part["thoughtSignature"] as? String

                        if isThought {
                            if !text.isEmpty {
                                accumulatedThought += text
                                continuation.yield(.reasoningDelta(text))
                            }
                            if let sig, !sig.isEmpty {
                                continuation.yield(.thinkingBlock(LLMThinkingBlock(
                                    thinking: accumulatedThought,
                                    signature: sig
                                )))
                                accumulatedThought = ""
                            }
                        } else {
                            if let sig, !sig.isEmpty {
                                // Gemini 2.5/3 delivers `thoughtSignature` on trailing empty-text
                                // or non-empty visible text parts.
                                continuation.yield(.thinkingBlock(LLMThinkingBlock(
                                    thinking: accumulatedThought,
                                    signature: sig
                                )))
                                accumulatedThought = ""
                            }
                            if !text.isEmpty {
                                continuation.yield(.contentDelta(text))
                            }
                        }
                    }
                }
                if let grounding = first["groundingMetadata"] as? [String: Any],
                   let chunks = grounding["groundingChunks"] as? [[String: Any]] {
                    for chunk in chunks {
                        if let web = chunk["web"] as? [String: Any],
                           let uri = web["uri"] as? String, !uri.isEmpty {
                            let title = (web["title"] as? String) ?? uri
                            continuation.yield(.groundingSource(title: title, url: uri))
                        }
                    }
                }
                if let finish = first["finishReason"] as? String, !finish.isEmpty { completed = true }
                if !reportedFinish,
                   let reason = LLMFinishReason.fromProviderValue(first["finishReason"] as? String) {
                    reportedFinish = true
                    continuation.yield(.finished(reason))
                }
            }

            if let usage = obj["usageMetadata"] as? [String: Any] {
                let promptTok = LLMUsage.valid(usage["promptTokenCount"] as? Int)
                let candTok = usage["candidatesTokenCount"] as? Int
                let thoughtTok = usage["thoughtsTokenCount"] as? Int
                // Thinking tokens are billed as output, so include them.
                let completionTok = LLMUsage.combined(candTok, thoughtTok)
                if promptTok != nil || completionTok != nil {
                    continuation.yield(.usage(promptTokens: promptTok, completionTokens: completionTok))
                }
                if let cachedTok = LLMUsage.valid(usage["cachedContentTokenCount"] as? Int), cachedTok > 0 {
                    continuation.yield(.cacheUsage(cachedTokens: cachedTok, cacheWriteTokens: nil))
                }
            }
        }

        guard completed else { throw LLMError.interruptedStream }
    }

    static func buildRequestBody(
        _ request: LLMChatRequest,
        includeNativeSearch: Bool? = nil,
        includeThinkingConfig: Bool = true,
        includeSamplingParams: Bool = true
    ) -> [String: Any] {
        let useNativeSearch = includeNativeSearch ?? request.enableNativeSearch
        let sanitizedMessages = LLMClient.sanitizeToolHistory(request.messages)
        var contents: [[String: Any]] = []

        for msg in sanitizedMessages {
            let roleStr = msg.role == .assistant ? "model" : "user"
            var parts: [[String: Any]] = []

            if msg.role == .tool {
                parts.append([
                    "functionResponse": [
                        "name": msg.toolName ?? "",
                        "response": ["content": msg.content]
                    ]
                ])
            } else if msg.role == .assistant && !msg.toolCalls.isEmpty {
                for block in msg.thinkingBlocks where block.kind == .thinking && (!block.thinking.isEmpty || (block.signature?.isEmpty == false)) {
                    var thoughtPart: [String: Any] = [
                        "text": block.thinking,
                        "thought": true
                    ]
                    if let sig = block.signature, !sig.isEmpty {
                        thoughtPart["thoughtSignature"] = sig
                    }
                    parts.append(thoughtPart)
                }
                if !msg.content.isEmpty {
                    parts.append(["text": msg.content])
                }
                for call in msg.toolCalls {
                    var part: [String: Any] = [
                        "functionCall": [
                            "name": call.name,
                            "args": call.argumentsDictionary
                        ]
                    ]
                    if let sig = call.thoughtSignature {
                        part["thoughtSignature"] = sig
                    }
                    parts.append(part)
                }
            } else {
                for att in msg.attachments {
                    if att.kind == .image, let base64 = att.dataBase64 {
                        parts.append([
                            "inlineData": [
                                "mimeType": att.mimeType,
                                "data": base64
                            ]
                        ])
                    } else if msg.role == .user, att.kind == .document, att.mimeType == "application/pdf", let base64 = att.dataBase64 {
                        parts.append([
                            "inlineData": [
                                "mimeType": "application/pdf",
                                "data": base64
                            ]
                        ])
                    }
                }

                let textPart = LLMClient.composeTextWithDocuments(
                    text: msg.content,
                    attachments: msg.attachments,
                    includePDFText: false
                )
                if !textPart.isEmpty {
                    parts.append(["text": textPart])
                } else if parts.isEmpty {
                    parts.append(["text": "..."])
                }
            }

            if let last = contents.last, (last["role"] as? String) == roleStr,
               var existingParts = last["parts"] as? [[String: Any]] {
                existingParts.append(contentsOf: parts)
                contents[contents.count - 1]["parts"] = existingParts
            } else {
                contents.append([
                    "role": roleStr,
                    "parts": parts
                ])
            }
        }

        if let firstRole = contents.first?["role"] as? String, firstRole != "user" {
            contents.insert([
                "role": "user",
                "parts": [["text": String(localized: "继续")]]
            ], at: 0)
        }

        var body: [String: Any] = [
            "contents": contents
        ]

        let trimmedSystem = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": trimmedSystem]]
            ]
        }

        var generationConfig: [String: Any] = [:]
        if includeSamplingParams {
            generationConfig["topP"] = request.topP
            if let temp = request.temperature {
                generationConfig["temperature"] = temp
            }
        }
        if let maxTokens = request.maxOutputTokens, maxTokens > 0 {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if includeThinkingConfig, let thinkingConfig = thinkingConfig(for: request) {
            generationConfig["thinkingConfig"] = thinkingConfig
        }
        if let schema = request.schemaObject {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseJsonSchema"] = schema
        }
        if request.wantsImage { generationConfig["responseModalities"] = ["TEXT", "IMAGE"] }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }
        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersObject
                    ] as [String: Any]
                }
            ]]
        } else if useNativeSearch {
            body["tools"] = [["google_search": [:] as [String: Any]]]
        }
        return body
    }

    /// Gemini 2.5 uses a token `thinkingBudget`; Gemini 3 and 4 use a coarse `thinkingLevel`
    /// (the two must not be combined). Image generation variants reject `thinkingConfig`.
    static func thinkingConfig(for request: LLMChatRequest) -> [String: Any]? {
        let lower = request.modelID.lowercased()
        if lower.contains("-image") || lower.hasPrefix("imagen") {
            return nil
        }
        let usesThinkingLevel = lower.contains("gemini-3") || lower.contains("gemini-4")
        let isGemini25 = lower.contains("gemini-2.5")
        let isThinkingCapable = request.supportsReasoning || usesThinkingLevel || isGemini25 || lower.contains("thinking")
        guard isThinkingCapable else { return nil }

        let budget = max(1024, request.thinkingBudgetTokens)

        if usesThinkingLevel {
            let level = (!request.enableThinking || budget <= 4096) ? "low" : "high"
            return ["thinkingLevel": level, "includeThoughts": request.enableThinking]
        }

        let isFlash = lower.contains("flash")
        if !request.enableThinking {
            // Flash / Flash-Lite can turn thinking off; Pro cannot, so keep its default.
            return isFlash ? ["thinkingBudget": 0] : nil
        }
        let maxBudget = isFlash ? 24_576 : 32_768
        return ["includeThoughts": true, "thinkingBudget": min(budget, maxBudget)]
    }

    static func fetchModels(
        baseURL: String,
        apiKey: String,
        customHeaders: [CustomHeader],
        session: URLSession
    ) async throws -> [ModelSpec] {
        let url = try EndpointResolver.modelsEndpoint(baseURL: baseURL, protocolType: .gemini)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        LLMClient.applyCustomHeaders(customHeaders, to: &req)

        return try await ModelListTransport.pages(request: req, session: session, itemsKey: "models", cursorName: "pageToken") { page, items in
            let models = try items.compactMap { item -> ModelSpec? in
                guard let name = item["name"] as? String else { throw URLError(.cannotParseResponse) }
                if let methods = item["supportedGenerationMethods"] as? [String], !methods.contains("generateContent") { return nil }
                if let outputs = item["supportedOutputModalities"] as? [String],
                   !outputs.contains(where: { $0.lowercased() == "text" }) { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                guard !id.isEmpty else { throw URLError(.cannotParseResponse) }
                return ModelSpec(id: id, displayName: item["displayName"] as? String)
            }
            return (models, page["nextPageToken"] as? String)
        }
    }
}
