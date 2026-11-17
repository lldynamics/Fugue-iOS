import Foundation

enum AnthropicAdapter {
    private static let anthropicVersion = "2023-06-01"

    static func streamChat(
        _ request: LLMChatRequest,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
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
                    if !request.apiKey.isEmpty {
                        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
                    }
                    LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)

                    let payload = buildRequestBody(request)
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    try await LLMClient.validateHTTPResponse(response, bytes: bytes)

                    var inputTokens: Int?
                    var outputTokens: Int?

                    for try await rawLine in bytes.lines {
                        try Task.checkCancellation()
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard line.hasPrefix("data:") else { continue }
                        let dataPart = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if dataPart == "[DONE]" { break }

                        guard let jsonData = dataPart.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let eventType = obj["type"] as? String else {
                            continue
                        }

                        switch eventType {
                        case "message_start":
                            if let msg = obj["message"] as? [String: Any],
                               let usage = msg["usage"] as? [String: Any],
                               let inTok = usage["input_tokens"] as? Int {
                                inputTokens = inTok
                            }

                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               let deltaType = delta["type"] as? String {
                                if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                                    continuation.yield(.reasoningDelta(thinking))
                                } else if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                                    continuation.yield(.contentDelta(text))
                                }
                            }

                        case "message_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               let reason = LLMFinishReason.fromProviderValue(delta["stop_reason"] as? String) {
                                continuation.yield(.finished(reason))
                            }
                            if let usage = obj["usage"] as? [String: Any],
                               let outTok = usage["output_tokens"] as? Int {
                                outputTokens = outTok
                                continuation.yield(.usage(promptTokens: inputTokens, completionTokens: outTok))
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

                    if inputTokens != nil || outputTokens != nil {
                        continuation.yield(.usage(promptTokens: inputTokens, completionTokens: outputTokens))
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
        var wireMessages: [[String: Any]] = []

        for msg in request.messages {
            let roleStr = msg.role == .assistant ? "assistant" : "user"
            var blocks: [[String: Any]] = []

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
                blocks.append([
                    "type": "text",
                    "text": "..."
                ])
            }

            // Merge consecutive messages of the same role as required by Anthropic API
            if let last = wireMessages.last, (last["role"] as? String) == roleStr,
               var existingBlocks = last["content"] as? [[String: Any]] {
                existingBlocks.append(contentsOf: blocks)
                wireMessages[wireMessages.count - 1]["content"] = existingBlocks
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
                "content": [["type": "text", "text": "继续"]]
            ], at: 0)
        }

        let shouldEnableThinking = request.enableThinking && request.supportsReasoning
        let requestedMax = request.maxOutputTokens ?? 0
        let finalMaxTokens: Int
        var budget = max(1024, request.thinkingBudgetTokens)
        if shouldEnableThinking {
            // Respect an explicit, sufficient user limit; otherwise leave room for the visible
            // answer while staying within the smallest output cap among thinking-capable
            // Claude models. budget_tokens must stay below max_tokens.
            if requestedMax > budget + 1024 {
                finalMaxTokens = requestedMax
            } else {
                finalMaxTokens = min(budget + 8192, thinkingOutputCap)
            }
            budget = max(1024, min(budget, finalMaxTokens - 2048))
        } else if requestedMax > 0 {
            finalMaxTokens = requestedMax
        } else {
            finalMaxTokens = defaultMaxTokens(for: request.modelID)
        }

        var body: [String: Any] = [
            "model": request.modelID,
            "max_tokens": finalMaxTokens,
            "messages": wireMessages,
            "stream": true
        ]

        let trimmedSystem = request.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            body["system"] = trimmedSystem
        }

        if shouldEnableThinking {
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": budget
            ]
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

        let (data, response) = try await session.data(for: req)
        try LLMClient.validateDataResponse(response, data: data)

        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = dict["data"] as? [[String: Any]] else {
            return []
        }

        return arr.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["display_name"] as? String) ?? id
            return ModelSpec(id: id, displayName: name, isEnabled: true)
        }
    }
}
