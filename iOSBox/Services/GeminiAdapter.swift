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

                        if let candidates = obj["candidates"] as? [[String: Any]],
                           let first = candidates.first,
                           let content = first["content"] as? [String: Any],
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

                        if let usage = obj["usageMetadata"] as? [String: Any] {
                            let promptTok = usage["promptTokenCount"] as? Int
                            let candTok = usage["candidatesTokenCount"] as? Int
                            if promptTok != nil || candTok != nil {
                                continuation.yield(.usage(promptTokens: promptTok, completionTokens: candTok))
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
        let lowerModel = request.modelID.lowercased()
        if request.enableThinking && (lowerModel.contains("2.5") || lowerModel.contains("gemini-3") || lowerModel.contains("thinking")) {
            generationConfig["thinkingConfig"] = [
                "includeThoughts": true
            ]
        }
        body["generationConfig"] = generationConfig
        return body
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
