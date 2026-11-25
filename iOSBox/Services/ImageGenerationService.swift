import Foundation
import UIKit

enum ImageAspectSize: String, CaseIterable, Identifiable, Sendable {
    case square = "1024x1024"
    case landscape = "1536x1024"
    case portrait = "1024x1536"
    case wide = "1792x1024"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: return String(localized: "方形 1:1")
        case .landscape: return String(localized: "横图 3:2")
        case .portrait: return String(localized: "竖图 2:3")
        case .wide: return String(localized: "宽屏 16:9")
        }
    }
}

struct ImageGenerationRequest: Sendable {
    let providerName: String
    let protocolType: APIProtocolType
    let baseURL: String
    let apiKey: String
    let apiKeys: [String]
    let customHeaders: [CustomHeader]
    let modelID: String
    let prompt: String
    let size: ImageAspectSize
    let quality: String
    let referenceImageData: Data?
    let referenceImageMimeType: String?
}

struct GeneratedImageResult: Sendable {
    let imageData: Data
    let mimeType: String
    let revisedPrompt: String?
}

enum ImageGenerationError: LocalizedError, Equatable {
    case emptyPrompt
    case unsupportedProtocol
    case insecurePublicHTTP
    case missingCredentials
    case httpError(Int, String)
    case invalidResponse
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyPrompt: return String(localized: "请输入绘图或修图描述。")
        case .unsupportedProtocol: return String(localized: "当前服务商协议暂不支持文生图，请选择 OpenAI 兼容、Responses API 或 Gemini 服务商。")
        case .insecurePublicHTTP: return String(localized: "公网接口必须使用 HTTPS 加密传输。")
        case .missingCredentials: return String(localized: "请先为所选服务商配置 API Key。")
        case .httpError(let code, let detail): return "HTTP \(code)：\(detail)"
        case .invalidResponse: return String(localized: "服务端未返回有效的图片数据。")
        case .imageTooLarge: return String(localized: "返回的图片超过大小限制。")
        }
    }
}

/// Unified client supporting OpenAI-compatible `/v1/images/generations` & `/v1/images/edits`
/// (OpenAI, SiliconFlow FLUX/Kolors, OneAPI gateways) and Gemini native image generation/editing.
enum ImageGenerationService {
    static let maximumImageBytes = 20 * 1_048_576

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 150
        return URLSession(configuration: config)
    }()

    private static let knownTextOnlyImageHosts: Set<String> = [
        "api.deepseek.com",
        "openrouter.ai",
        "api.groq.com",
        "api.mistral.ai",
        "api.perplexity.ai",
        "api.moonshot.cn",
        "api.minimaxi.com",
        "api.minimax.io"
    ]

    static func isImageModelID(_ modelID: String) -> Bool {
        let lower = modelID.lowercased()
        let markers = [
            "gpt-image", "dall-e", "flux", "kolors", "imagen",
            "image-preview", "image-generation", "seedream", "cogview",
            "wanx", "recraft", "ideogram", "stable-diffusion", "sdxl"
        ]
        return markers.contains { lower.contains($0) }
    }

    @MainActor
    static func eligibleProviders(from providers: [ProviderConfig]) -> [ProviderConfig] {
        providers.filter { provider in
            guard !provider.isDeleted, provider.isEnabled else { return false }
            guard provider.protocolType == .openAICompatible
                || provider.protocolType == .openAIResponses
                || provider.protocolType == .gemini else { return false }
            guard !NetworkLocation.isPlainHTTPToPublicHost(baseURL: provider.baseURL) else { return false }
            return NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL) || provider.hasAuthentication
        }
    }

    /// Selects the best provider and image model for autonomous Agent `generate_image` calls,
    /// prioritizing explicit image models and known image-capable endpoints while skipping
    /// chat-only gateways unless the user explicitly configured an image model on them.
    @MainActor
    static func preferredAgentProvider(from providers: [ProviderConfig]) -> (provider: ProviderConfig, modelID: String)? {
        var best: (score: Int, order: Int, provider: ProviderConfig, modelID: String)?

        for (idx, provider) in eligibleProviders(from: providers).enumerated() {
            let host = URL(string: provider.baseURL)?.host?.lowercased() ?? ""
            let explicitImageModel = provider.enabledModels.first { isImageModelID($0.id) }?.id

            if knownTextOnlyImageHosts.contains(host) && explicitImageModel == nil {
                continue
            }

            let resolvedModel: String
            let score: Int
            if let explicitImageModel {
                resolvedModel = explicitImageModel
                score = 100
            } else if host.contains("api.openai.com") {
                resolvedModel = "gpt-image-1"
                score = 80
            } else if provider.protocolType == .gemini || host.contains("generativelanguage.googleapis.com") {
                resolvedModel = "gemini-2.5-flash-image-preview"
                score = 75
            } else if host.contains("siliconflow") {
                resolvedModel = "black-forest-labs/FLUX.1-schnell"
                score = 70
            } else if host.contains("bigmodel.cn") {
                resolvedModel = "cogview-3-flash"
                score = 65
            } else if let suggested = suggestedModels(for: provider.protocolType).first {
                resolvedModel = suggested
                score = 40
            } else {
                continue
            }

            if best == nil || score > best!.score || (score == best!.score && idx < best!.order) {
                best = (score, idx, provider, resolvedModel)
            }
        }

        return best.map { ($0.provider, $0.modelID) }
    }

    static func makeAttachment(from result: GeneratedImageResult) -> MessageAttachment {
        var payload = result.imageData
        var mime = result.mimeType
        if payload.count > 6 * 1_048_576,
           let uiImg = UIImage(data: payload),
           let jpeg = uiImg.jpegData(compressionQuality: 0.86),
           jpeg.count < payload.count {
            payload = jpeg
            mime = "image/jpeg"
        }
        let ext: String
        if mime.contains("jpeg") || mime.contains("jpg") {
            ext = "jpg"
        } else if mime.contains("webp") {
            ext = "webp"
        } else {
            ext = "png"
        }
        return MessageAttachment(
            kind: .image,
            fileName: "generated-\(UUID().uuidString.prefix(6)).\(ext)",
            mimeType: mime,
            dataBase64: payload.base64EncodedString(),
            extractedText: nil,
            byteSize: payload.count
        )
    }

    static func suggestedModels(for protocolType: APIProtocolType) -> [String] {
        switch protocolType {
        case .openAICompatible, .openAIResponses:
            return ["gpt-image-1", "dall-e-3", "black-forest-labs/FLUX.1-schnell", "Kwai-Kolors/Kolors"]
        case .gemini:
            return ["gemini-2.5-flash-image-preview", "gemini-2.0-flash-exp-image-generation"]
        case .anthropic:
            return []
        }
    }

    static func generate(
        _ request: ImageGenerationRequest,
        session: URLSession? = nil
    ) async throws -> GeneratedImageResult {
        try AppCompliance.requireConsent()
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ImageGenerationError.emptyPrompt }
        if NetworkLocation.isPlainHTTPToPublicHost(baseURL: request.baseURL) {
            throw ImageGenerationError.insecurePublicHTTP
        }
        let isLocal = NetworkLocation.isLocalOrPrivate(baseURL: request.baseURL)
        let activeKey = ([request.apiKey] + request.apiKeys)
            .map(LLMClient.sanitizedAPIKey)
            .first { !$0.isEmpty } ?? ""
        if activeKey.isEmpty && !isLocal {
            throw ImageGenerationError.missingCredentials
        }

        switch request.protocolType {
        case .openAICompatible, .openAIResponses:
            if let refData = request.referenceImageData, !refData.isEmpty {
                return try await executeOpenAIImageEdit(request, prompt: prompt, refData: refData, activeKey: activeKey, session: session)
            } else {
                return try await executeOpenAIImageGeneration(request, prompt: prompt, activeKey: activeKey, session: session)
            }
        case .gemini:
            return try await executeGeminiImageGeneration(request, prompt: prompt, activeKey: activeKey, session: session)
        case .anthropic:
            throw ImageGenerationError.unsupportedProtocol
        }
    }

    // MARK: - OpenAI Compatible

    static func resolvedOpenAISize(for size: ImageAspectSize, modelID: String) -> String {
        let lower = modelID.lowercased()
        if lower.contains("gpt-image") {
            return size == .wide ? ImageAspectSize.landscape.rawValue : size.rawValue
        }
        if lower.contains("dall-e-3") {
            switch size {
            case .square: return "1024x1024"
            case .landscape, .wide: return "1792x1024"
            case .portrait: return "1024x1792"
            }
        }
        return size.rawValue
    }

    static func buildOpenAIGenerationBody(_ request: ImageGenerationRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.modelID,
            "prompt": request.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "n": 1,
            "size": resolvedOpenAISize(for: request.size, modelID: request.modelID)
        ]
        let lower = request.modelID.lowercased()
        if !lower.contains("gpt-image") {
            body["response_format"] = "b64_json"
        }
        if !request.quality.isEmpty && request.quality != "auto" {
            body["quality"] = request.quality
        }
        return body
    }

    private static func executeOpenAIImageGeneration(
        _ request: ImageGenerationRequest,
        prompt: String,
        activeKey: String,
        session: URLSession?
    ) async throws -> GeneratedImageResult {
        let url = try EndpointResolver.imagesGenerationsEndpoint(baseURL: request.baseURL)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if !activeKey.isEmpty {
            urlRequest.setValue("Bearer \(activeKey)", forHTTPHeaderField: "Authorization")
        }
        LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildOpenAIGenerationBody(request))

        let (data, response) = try await (session ?? Self.session).data(for: urlRequest, delegate: SameOriginRedirectDelegate.shared)
        try validateHTTP(response: response, data: data)
        return try await decodeOpenAIImageResponse(data, session: session)
    }

    private static func executeOpenAIImageEdit(
        _ request: ImageGenerationRequest,
        prompt: String,
        refData: Data,
        activeKey: String,
        session: URLSession?
    ) async throws -> GeneratedImageResult {
        let url = try EndpointResolver.imagesEditsEndpoint(baseURL: request.baseURL)
        let boundary = "FugueImageEdit-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if !activeKey.isEmpty {
            urlRequest.setValue("Bearer \(activeKey)", forHTTPHeaderField: "Authorization")
        }
        LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)

        var body = Data()
        func appendField(_ name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        appendField("model", value: request.modelID)
        appendField("prompt", value: prompt)
        appendField("size", value: resolvedOpenAISize(for: request.size, modelID: request.modelID))
        if !request.modelID.lowercased().contains("gpt-image") {
            appendField("response_format", value: "b64_json")
        }

        let mime = request.referenceImageMimeType ?? "image/png"
        let ext = mime.contains("jpeg") ? "jpg" : "png"
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"image\"; filename=\"reference.\(ext)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(refData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        urlRequest.httpBody = body

        let (data, response) = try await (session ?? Self.session).data(for: urlRequest, delegate: SameOriginRedirectDelegate.shared)
        try validateHTTP(response: response, data: data)
        return try await decodeOpenAIImageResponse(data, session: session)
    }

    static func decodeOpenAIImageResponse(
        _ data: Data,
        session: URLSession? = nil
    ) async throws -> GeneratedImageResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]],
              let first = list.first else {
            throw ImageGenerationError.invalidResponse
        }
        let revised = first["revised_prompt"] as? String
        if let b64 = first["b64_json"] as? String,
           let raw = Data(base64Encoded: b64), !raw.isEmpty {
            guard raw.count <= maximumImageBytes else { throw ImageGenerationError.imageTooLarge }
            return GeneratedImageResult(imageData: raw, mimeType: detectImageMimeType(raw), revisedPrompt: revised)
        }
        if let urlStr = first["url"] as? String,
           let imgURL = URL(string: urlStr),
           imgURL.scheme?.lowercased() == "https" {
            let (imgData, imgResp) = try await (session ?? Self.session).data(from: imgURL)
            guard let http = imgResp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !imgData.isEmpty else {
                throw ImageGenerationError.invalidResponse
            }
            guard imgData.count <= maximumImageBytes else { throw ImageGenerationError.imageTooLarge }
            return GeneratedImageResult(imageData: imgData, mimeType: detectImageMimeType(imgData), revisedPrompt: revised)
        }
        throw ImageGenerationError.invalidResponse
    }

    // MARK: - Gemini Native Image Generation / Editing

    static func buildGeminiImageBody(_ request: ImageGenerationRequest) -> [String: Any] {
        var parts: [[String: Any]] = [
            ["text": request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)]
        ]
        if let refData = request.referenceImageData, !refData.isEmpty {
            parts.append([
                "inlineData": [
                    "mimeType": request.referenceImageMimeType ?? "image/png",
                    "data": refData.base64EncodedString()
                ]
            ])
        }
        return [
            "contents": [
                ["role": "user", "parts": parts]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]
    }

    private static func executeGeminiImageGeneration(
        _ request: ImageGenerationRequest,
        prompt: String,
        activeKey: String,
        session: URLSession?
    ) async throws -> GeneratedImageResult {
        let url = try EndpointResolver.geminiGenerateContentEndpoint(baseURL: request.baseURL, modelID: request.modelID)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if !activeKey.isEmpty {
            urlRequest.setValue(activeKey, forHTTPHeaderField: "x-goog-api-key")
        }
        LLMClient.applyCustomHeaders(request.customHeaders, to: &urlRequest)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildGeminiImageBody(request))

        let (data, response) = try await (session ?? Self.session).data(for: urlRequest, delegate: SameOriginRedirectDelegate.shared)
        try validateHTTP(response: response, data: data)
        return try decodeGeminiImageResponse(data)
    }

    static func decodeGeminiImageResponse(_ data: Data) throws -> GeneratedImageResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]] else {
            throw ImageGenerationError.invalidResponse
        }
        var captionParts: [String] = []
        for candidate in candidates {
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }
            for part in parts {
                if let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    captionParts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let inline = (part["inlineData"] as? [String: Any]) ?? (part["inline_data"] as? [String: Any])
                if let inline,
                   let b64 = inline["data"] as? String,
                   let imgData = Data(base64Encoded: b64), !imgData.isEmpty {
                    guard imgData.count <= maximumImageBytes else { throw ImageGenerationError.imageTooLarge }
                    let mime = (inline["mimeType"] as? String) ?? (inline["mime_type"] as? String) ?? detectImageMimeType(imgData)
                    let revised = captionParts.isEmpty ? nil : captionParts.joined(separator: "\n")
                    return GeneratedImageResult(imageData: imgData, mimeType: mime, revisedPrompt: revised)
                }
            }
        }
        throw ImageGenerationError.invalidResponse
    }

    private static func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ImageGenerationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ImageGenerationError.httpError(http.statusCode, detail)
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
                return msg
            }
            if let msg = obj["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        let text = String(decoding: data.prefix(240), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func detectImageMimeType(_ data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/png"
    }
}
