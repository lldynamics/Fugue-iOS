import Foundation

enum GeminiAdapter {
    static func streamChat(
        _ request: LLMChatRequest,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try EndpointResolver.chatEndpoint(
                        baseURL: request.baseURL,
                        protocolType: .gemini,
                        modelID: request.modelID
                    )
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !request.apiKey.isEmpty {
                        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-goog-api-key")
                    }
                    LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)

                    let payload = buildRequestBody(request)
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try await LLMClient.validateHTTPResponse(response, bytes: bytes)

                    var reportedFinish = false

                    for try await rawLine in bytes.lines {
                        try Task.checkCancellation()
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard line.hasPrefix("data:") else { continue }
                        let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if dataPart == "[DONE]" || dataPart.isEmpty { continue }

                        guard let jsonData = dataPart.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                            continue
                        }

                        if let err = obj["error"] as? [String: Any],
                           let msg = err["message"] as? String {
                            throw LLMError.apiError(msg)
                        }

                        // The whole prompt was rejected; there will be no candidates.
                        if let feedback = obj["promptFeedback"] as? [String: Any],
                           let blockReason = feedback["blockReason"] as? String, !blockReason.isEmpty {
                            throw LLMError.apiError("提问内容被 Gemini 安全策略拦截（\(blockReason)），请调整后重试。")
                        }

                        if let candidates = obj["candidates"] as? [[String: Any]],
                           let first = candidates.first {
                            if let content = first["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]] {
                                for part in parts {
                                    guard let text = part["text"] as? String, !text.isEmpty else { continue }
                                    let isThought = (part["thought"] as? Bool) ?? false
                                    if isThought {
                                        continuation.yield(.reasoningDelta(text))
                                    } else {
                                        continuation.yield(.contentDelta(text))
                                    }
                                }
                            }
                            if !reportedFinish,
                               let reason = LLMFinishReason.fromProviderValue(first["finishReason"] as? String) {
                                reportedFinish = true
                                continuation.yield(.finished(reason))
                            }
                        }

                        if let usage = obj["usageMetadata"] as? [String: Any] {
                            let promptTok = usage["promptTokenCount"] as? Int
                            let candTok = usage["candidatesTokenCount"] as? Int
                            let thoughtTok = usage["thoughtsTokenCount"] as? Int
                            // Thinking tokens are billed as output, so include them.
                            let completionTok = (candTok != nil || thoughtTok != nil)
                                ? (candTok ?? 0) + (thoughtTok ?? 0) : nil
                            if promptTok != nil || completionTok != nil {
                                continuation.yield(.usage(promptTokens: promptTok, completionTokens: completionTok))
                            }
                        }
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

    static func buildRequestBody(_ request: LLMChatRequest) -> [String: Any] {
        var contents: [[String: Any]] = []

        for msg in request.messages {
            let roleStr = msg.role == .assistant ? "model" : "user"
            var parts: [[String: Any]] = []

            if msg.role == .user {
                for att in msg.attachments {
                    if att.kind == .image, let base64 = att.dataBase64 {
                        parts.append([
                            "inlineData": [
                                "mimeType": att.mimeType,
                                "data": base64
                            ]
                        ])
                    } else if att.kind == .document, att.mimeType == "application/pdf", let base64 = att.dataBase64 {
                        parts.append([
                            "inlineData": [
                                "mimeType": "application/pdf",
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
                parts.append(["text": textPart])
            } else if parts.isEmpty {
                parts.append(["text": "..."])
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

        var body: [String: Any] = [
            "contents": contents
        ]

        let trimmedSystem = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": trimmedSystem]]
            ]
        }

        var generationConfig: [String: Any] = [
            "topP": request.topP
        ]
        if let temp = request.temperature {
            generationConfig["temperature"] = temp
        }
        if let maxTokens = request.maxOutputTokens, maxTokens > 0 {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        if let thinkingConfig = thinkingConfig(for: request) {
            generationConfig["thinkingConfig"] = thinkingConfig
        }
        body["generationConfig"] = generationConfig
        return body
    }

    /// Gemini 2.5 uses a token `thinkingBudget`; Gemini 3 uses a coarse `thinkingLevel`
    /// (the two must not be combined). Returns nil to leave the model's default behavior.
    static func thinkingConfig(for request: LLMChatRequest) -> [String: Any]? {
        let lower = request.modelID.lowercased()
        let isGemini3 = lower.contains("gemini-3")
        let isGemini25 = lower.contains("gemini-2.5")
        let isThinkingCapable = request.supportsReasoning || isGemini3 || isGemini25 || lower.contains("thinking")
        guard isThinkingCapable else { return nil }

        let budget = max(1024, request.thinkingBudgetTokens)

        if isGemini3 {
            // Gemini 3 can't fully disable thinking; "low" is the cheapest level.
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

        let (data, response) = try await session.data(for: req)
        try LLMClient.validateDataResponse(response, data: data)

        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = dict["models"] as? [[String: Any]] else {
            return []
        }

        var specs: [ModelSpec] = []
        for item in models {
            guard let rawName = item["name"] as? String else { continue }
            let methods = (item["supportedGenerationMethods"] as? [String]) ?? []
            if !methods.isEmpty && !methods.contains("generateContent") {
                continue
            }
            let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
            let displayName = (item["displayName"] as? String) ?? id
            specs.append(ModelSpec(id: id, displayName: displayName, isEnabled: true))
        }
        return specs
    }
}
