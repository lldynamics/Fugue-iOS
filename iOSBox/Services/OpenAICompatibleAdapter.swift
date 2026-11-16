import Foundation

enum OpenAICompatibleAdapter {
    static func streamChat(
        _ request: LLMChatRequest,
        session: URLSession
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
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

                    let payload = buildRequestBody(request)
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
                        continuation.yield(.done)
                        continuation.finish()
                        return
                    }

                    var thinkParser = ThinkTagStreamParser()
                    var receivedNativeReasoning = false

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
                                for segment in thinkParser.feed(content) {
                                    switch segment {
                                    case .reasoning(let r):
                                        continuation.yield(.reasoningDelta(r))
                                    case .content(let c):
                                        continuation.yield(.contentDelta(c))
                                    }
                                }
                            }
                        }
                    }

                    if !receivedNativeReasoning {
                        for segment in thinkParser.finish() {
                            switch segment {
                            case .reasoning(let r):
                                continuation.yield(.reasoningDelta(r))
                            case .content(let c):
                                continuation.yield(.contentDelta(c))
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

        let isStrictReasoner = request.modelID.lowercased().contains("reasoner")
            || request.modelID.lowercased().hasPrefix("o1")
            || request.modelID.lowercased().hasPrefix("o3")
            || request.modelID.lowercased().hasPrefix("o4")

        if let temp = request.temperature, !isStrictReasoner {
            body["temperature"] = temp
        }
        if request.topP < 0.999, !isStrictReasoner {
            body["top_p"] = request.topP
        }
        if let maxTokens = request.maxOutputTokens, maxTokens > 0 {
            body["max_tokens"] = maxTokens
        }
        return body
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
            for seg in parser.feed(content) + parser.finish() {
                switch seg {
                case .reasoning(let r): continuation.yield(.reasoningDelta(r))
                case .content(let c): continuation.yield(.contentDelta(c))
                }
            }
        }
        if let usage = obj["usage"] as? [String: Any] {
            continuation.yield(.usage(
                promptTokens: usage["prompt_tokens"] as? Int,
                completionTokens: usage["completion_tokens"] as? Int
            ))
        }
    }

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
