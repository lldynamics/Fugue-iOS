import Foundation
import SwiftData

enum TranscriptActionMode: Sendable {
    case meetingMinutes
    case voiceNoteCleanup
    case insertRaw
}

enum MeetingMinutesPromptBuilder {
    static func buildPrompt(
        transcript: String,
        sourceLabel: String? = nil,
        mode: TranscriptActionMode,
        date: Date = Date()
    ) -> String {
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTranscript.isEmpty else { return "" }
        if mode == .insertRaw {
            return cleanTranscript
        }

        let sourceLine: String
        if let label = sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            sourceLine = String(localized: "（来源：\(label)）")
        } else {
            sourceLine = ""
        }

        switch mode {
        case .meetingMinutes:
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            df.dateFormat = "yyyy-MM-dd"
            let dateStr = df.string(from: date)
            return """
            请根据以下语音转写文本整理一份结构清晰的「会议纪要与行动项」\(sourceLine)（参考日期：\(dateStr)）：

            要求：
            1. **一句话结论 (TL;DR)**：提炼核心议题与最终结论。
            2. **关键讨论要点**：按主题分点列出重要信息、共识与分歧（去除口水话与重复）。
            3. **待办行动项与日程**：列出具体待办、负责人（如提及），若涉及具体时间或截止日期请换算为明确日期时间格式（例如 `YYYY-MM-DD HH:mm` 或 `YYYY-MM-DD`）。
            4. **待确认问题**：如有遗留问题请单独标出；全篇请保持客观、忠于原文。

            <transcript>
            \(cleanTranscript)
            </transcript>
            """

        case .voiceNoteCleanup:
            return """
            请将以下语音口述转写整理为通顺、精炼、可直接转发微信或办公软件的书面文字\(sourceLine)：

            要求：
            1. 去除口头禅（嗯、啊、那个等）、重复与明显语病，补全标点并合理分段。
            2. 如包含多个事项或要点，请使用简洁条理的编号/要点列表呈现。
            3. 忠实保留原意，不要凭空增删事实或数据。

            <transcript>
            \(cleanTranscript)
            </transcript>
            """

        case .insertRaw:
            return cleanTranscript
        }
    }
}

struct AudioTranscriptionRequest: Sendable {
    let baseURL: String
    let apiKey: String
    let apiKeys: [String]
    let customHeaders: [CustomHeader]
    let model: String
    let language: String
    let fileName: String
    let mimeType: String
    let audioData: Data

    init(
        baseURL: String,
        apiKey: String,
        apiKeys: [String] = [],
        customHeaders: [CustomHeader] = [],
        model: String = "whisper-1",
        language: String = "",
        fileName: String,
        mimeType: String,
        audioData: Data
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiKeys = apiKeys
        self.customHeaders = customHeaders
        self.model = model
        self.language = language
        self.fileName = fileName
        self.mimeType = mimeType
        self.audioData = audioData
    }
}

struct CloudTTSRequest: Sendable {
    let baseURL: String
    let apiKey: String
    let apiKeys: [String]
    let customHeaders: [CustomHeader]
    let model: String
    let voice: String
    let input: String

    init(
        baseURL: String,
        apiKey: String,
        apiKeys: [String] = [],
        customHeaders: [CustomHeader] = [],
        model: String = "tts-1",
        voice: String = "alloy",
        input: String
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiKeys = apiKeys
        self.customHeaders = customHeaders
        self.model = model
        self.voice = voice
        self.input = input
    }
}

private enum AudioHTTPExecutor {
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func executeWithKeyRotation(
        baseURL: String,
        primaryKey: String,
        extraKeys: [String],
        keyRouter: APIKeyPoolRouter,
        session: URLSession,
        maxResponseBytes: Int,
        consentDefaults: UserDefaults,
        buildURLRequest: (String) throws -> URLRequest
    ) async throws -> (Data, String?) {
        try AppCompliance.requireConsent(defaults: consentDefaults)
        guard !NetworkLocation.isPlainHTTPToPublicHost(baseURL: baseURL) else {
            throw LLMError.invalidURL(baseURL)
        }

        let orderedKeys = try keyRouter.orderedKeys(
            from: [primaryKey] + extraKeys,
            protocolType: .openAICompatible,
            baseURL: baseURL
        )
        let activeSession = session
        var lastError: Error?

        for (index, candidateKey) in orderedKeys.prefix(4).enumerated() {
            var req = try buildURLRequest(candidateKey)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (bytes, response) = try await activeSession.bytes(for: req, delegate: SameOriginRedirectDelegate.shared)
                defer { bytes.task.cancel() }
                try await LLMClient.validateHTTPResponse(response, bytes: bytes)
                if response.expectedContentLength > Int64(maxResponseBytes) {
                    throw LLMError.apiError(String(localized: "音频响应数据超出大小上限。"))
                }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maxResponseBytes else {
                        throw LLMError.apiError(String(localized: "音频响应数据超出大小上限。"))
                    }
                    data.append(byte)
                }
                keyRouter.markHealthy(key: candidateKey, protocolType: .openAICompatible, baseURL: baseURL)
                let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                return (data, contentType)
            } catch let err as LLMError {
                if case .httpError(let status, _) = err,
                   [401, 402, 403, 429].contains(status),
                   index + 1 < min(orderedKeys.count, 4) {
                    keyRouter.markUnhealthy(
                        key: candidateKey,
                        protocolType: .openAICompatible,
                        baseURL: baseURL,
                        statusCode: status
                    )
                    lastError = err
                    continue
                }
                throw err
            }
        }
        throw lastError ?? LLMError.emptyResponse
    }
}

enum AudioTranscriptionService {
    static let maxAudioBytes = 25 * 1024 * 1024
    static let maxResponseBytes = 4 * 1024 * 1024

    static let presetModels = [
        "whisper-1",
        "gpt-4o-mini-transcribe",
        "whisper-large-v3-turbo",
        "FunAudioLLM/SenseVoiceSmall"
    ]

    static var presetLanguages: [(code: String, label: String)] {
        [
            ("", String(localized: "自动识别")),
            ("zh", "中文"),
            ("en", "English"),
            ("ja", "日本語")
        ]
    }

    enum AudioCapabilityKind: Sendable {
        case transcription
        case speech
    }

    private static let incompatibleAudioChatOnlyHosts: Set<String> = [
        "api.deepseek.com",
        "openrouter.ai",
        "generativelanguage.googleapis.com",
        "api.anthropic.com",
        "api.x.ai",
        "api.perplexity.ai",
        "api.moonshot.cn",
        "api.moonshot.ai",
        "open.bigmodel.cn",
        "ark.cn-beijing.volces.com"
    ]

    static func supportsOpenAIAudioTranscriptions(baseURL: String) -> Bool {
        guard let parsed = normalizedHostAndPath(from: baseURL) else { return false }
        if parsed.path.hasSuffix("/audio/transcriptions") {
            return true
        }
        return !isKnownChatOnlyNonAudioEndpoint(host: parsed.host, path: parsed.path)
    }

    static func supportsOpenAIAudioSpeech(baseURL: String) -> Bool {
        guard let parsed = normalizedHostAndPath(from: baseURL) else { return false }
        if parsed.path.hasSuffix("/audio/speech") {
            return true
        }
        if parsed.host == "api.groq.com" || parsed.host.hasSuffix(".groq.com") {
            return false
        }
        return !isKnownChatOnlyNonAudioEndpoint(host: parsed.host, path: parsed.path)
    }

    private static func normalizedHostAndPath(from baseURL: String) -> (host: String, path: String)? {
        var cleaned = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("#") {
            cleaned.removeLast()
        }
        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        guard !cleaned.isEmpty,
              let components = URLComponents(string: cleaned),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        return (host, components.path.lowercased())
    }

    private static func isKnownChatOnlyNonAudioEndpoint(host: String, path: String) -> Bool {
        if incompatibleAudioChatOnlyHosts.contains(host) {
            return true
        }
        if host.hasSuffix(".deepseek.com") || host.hasSuffix(".openrouter.ai") || host.hasSuffix(".anthropic.com") {
            return true
        }
        if (host == "dashscope.aliyuncs.com" || host == "dashscope-intl.aliyuncs.com" || host.hasSuffix(".aliyuncs.com")),
           path.contains("compatible-mode") {
            return true
        }
        return false
    }

    @MainActor
    static func resolveAudioProvider(
        in providers: [ProviderConfig],
        preferredID: UUID?,
        capability: AudioCapabilityKind = .transcription
    ) -> ProviderConfig? {
        let eligible = providers.filter {
            !$0.isDeleted && $0.isEnabled && ($0.protocolType == .openAICompatible || $0.protocolType == .openAIResponses) && $0.hasConfiguredChatAPI
        }
        if let preferredID, let exact = eligible.first(where: { $0.id == preferredID }) {
            return exact
        }
        let compatible = eligible.filter { provider in
            switch capability {
            case .speech:
                return supportsOpenAIAudioSpeech(baseURL: provider.baseURL)
            case .transcription:
                return supportsOpenAIAudioTranscriptions(baseURL: provider.baseURL)
            }
        }
        if let fullAudio = compatible.first(where: { supportsOpenAIAudioSpeech(baseURL: $0.baseURL) }) {
            return fullAudio
        }
        return compatible.first
    }

    @MainActor
    @discardableResult
    static func recordAudioLedgerEntry(
        baseURL: String,
        modelID: String,
        isSpeechSynthesis: Bool,
        status: RequestStatus,
        httpStatus: Int? = nil,
        elapsedMs: Int,
        context suppliedContext: ModelContext? = nil
    ) -> RequestRecord? {
        let context: ModelContext
        let allowFallbackTarget: Bool
        if let suppliedContext {
            context = suppliedContext
            allowFallbackTarget = true
        } else {
            let mainContext = AppRuntime.persistence.container.mainContext
            guard PersistenceController.canCommitUserData(in: mainContext),
                  mainContext.container.configurations.allSatisfy({ !$0.isStoredInMemoryOnly }) else {
                return nil
            }
            context = mainContext
            allowFallbackTarget = false
        }

        let providers = (try? context.fetch(FetchDescriptor<ProviderConfig>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        let targetHost = normalizedHostAndPath(from: baseURL)?.host ?? ""
        let matchedProvider = providers.first { p in
            guard !p.isDeleted else { return false }
            if p.baseURL.caseInsensitiveCompare(baseURL) == .orderedSame { return true }
            guard !targetHost.isEmpty else { return false }
            return normalizedHostAndPath(from: p.baseURL)?.host == targetHost
        }

        guard matchedProvider != nil || allowFallbackTarget else {
            return nil
        }

        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = cleanModel.isEmpty ? (isSpeechSynthesis ? "tts-1" : "whisper-1") : cleanModel
        let badge = isSpeechSynthesis ? "TTS" : "ASR"
        let providerID = matchedProvider?.id ?? UUID()
        let providerName = matchedProvider?.name ?? (targetHost.isEmpty ? "OpenAI Audio" : targetHost)
        let protocolType = matchedProvider?.protocolType ?? .openAICompatible
        let spec = matchedProvider?.models.first(where: { $0.id == effectiveModel })

        let target = ResolvedModelTarget(
            providerID: providerID,
            providerName: providerName,
            protocolType: protocolType,
            modelID: effectiveModel,
            modelDisplayName: "\(effectiveModel) (\(badge))",
            accentHex: "#3F6EF6",
            supportsVision: false,
            supportsReasoning: false
        )
        let ended = Date()
        let clampedMs = max(0, elapsedMs)
        let started = ended.addingTimeInterval(-Double(clampedMs) / 1000.0)
        let record = RequestRecord(
            target: target,
            spec: spec,
            conversationID: UUID(),
            messageID: UUID(),
            kind: .agentTool,
            now: started
        )
        record.isStreamed = false
        record.httpStatus = httpStatus
        record.finish(status, elapsedMs: clampedMs, now: ended)
        context.insert(record)
        try? context.save()
        return record
    }

    static func sanitizeFileName(_ raw: String) -> String {
        let tail = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = ""
        cleaned.reserveCapacity(trimmed.count)
        let forbidden: Set<Character> = ["\"", "'", ";", "/", "\\"]
        for ch in trimmed {
            if let ascii = ch.asciiValue {
                if ascii >= 0x20 && ascii < 0x7F && !forbidden.contains(ch) {
                    cleaned.append(ch)
                } else {
                    cleaned.append("_")
                }
            } else if !ch.isNewline {
                cleaned.append(ch)
            } else {
                cleaned.append("_")
            }
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "recording.m4a"
        }
        return String(cleaned.prefix(120))
    }

    static func mimeType(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "m4a", "mp4", "m4b": return "audio/mp4"
        case "mp3", "mpga", "mpeg": return "audio/mpeg"
        case "wav", "wave": return "audio/wav"
        case "webm": return "audio/webm"
        case "ogg", "oga", "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        case "aac": return "audio/aac"
        default: return "audio/mp4"
        }
    }

    static func readBoundedAudioData(from url: URL, maxBytes: Int = maxAudioBytes) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw AttachmentError.unsupportedBinary
        }
        if let size = values.fileSize, size > maxBytes {
            throw LLMError.apiError(String(localized: "音频文件超过 25 MB 上限，请剪辑后分段转写。"))
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard !data.isEmpty else {
            throw LLMError.apiError(String(localized: "音频文件为空，无法转写。"))
        }
        guard data.count <= maxBytes else {
            throw LLMError.apiError(String(localized: "音频文件超过 25 MB 上限，请剪辑后分段转写。"))
        }
        return data
    }

    static func buildMultipartBody(
        boundary: String,
        fileName: String,
        mimeType: String,
        audioData: Data,
        model: String,
        language: String
    ) -> Data {
        let safeFileName = sanitizeFileName(fileName)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = cleanModel.isEmpty ? "whisper-1" : cleanModel
        let cleanLang = language.trimmingCharacters(in: .whitespacesAndNewlines)

        var body = Data()
        func appendString(_ s: String) {
            body.append(Data(s.utf8))
        }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        appendString("\r\n")

        func appendField(name: String, value: String) {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            appendString("\(value)\r\n")
        }

        appendField(name: "model", value: effectiveModel)
        appendField(name: "response_format", value: "json")
        if !cleanLang.isEmpty {
            appendField(name: "language", value: cleanLang)
        }
        appendString("--\(boundary)--\r\n")
        return body
    }

    static func parseTranscriptionResponse(data: Data, contentType: String? = nil) throws -> String {
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw LLMError.emptyResponse
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errDict = json["error"] as? [String: Any],
               let msg = (errDict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !msg.isEmpty {
                throw LLMError.apiError(msg)
            }
            if let errStr = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !errStr.isEmpty {
                throw LLMError.apiError(errStr)
            }
            if let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            if let nested = json["data"] as? [String: Any],
               let text = (nested["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            throw LLMError.emptyResponse
        }
        if contentType?.lowercased().contains("application/json") == true {
            throw LLMError.emptyResponse
        }
        return raw
    }

    static func transcribe(
        _ request: AudioTranscriptionRequest,
        keyRouter: APIKeyPoolRouter = .shared,
        session: URLSession? = nil,
        consentDefaults: UserDefaults = AppCompliance.consentDefaults,
        ledgerContainer: ModelContainer? = nil
    ) async throws -> String {
        guard !request.audioData.isEmpty else {
            throw LLMError.apiError(String(localized: "音频内容为空，无法转写。"))
        }
        guard request.audioData.count <= maxAudioBytes else {
            throw LLMError.apiError(String(localized: "音频文件超过 25 MB 上限，请剪辑后分段转写。"))
        }

        let endpoint = try EndpointResolver.audioTranscriptionsEndpoint(baseURL: request.baseURL)
        let boundary = "FugueBoundary-\(UUID().uuidString)"
        let safeMime = mimeType(forFileName: request.fileName)
        let body = buildMultipartBody(
            boundary: boundary,
            fileName: request.fileName,
            mimeType: request.mimeType.isEmpty ? safeMime : request.mimeType,
            audioData: request.audioData,
            model: request.model,
            language: request.language
        )

        let shouldRecordLedger = ledgerContainer != nil || session == nil
        let startInstant = ContinuousClock.now
        do {
            let (data, contentType) = try await AudioHTTPExecutor.executeWithKeyRotation(
                baseURL: request.baseURL,
                primaryKey: request.apiKey,
                extraKeys: request.apiKeys,
                keyRouter: keyRouter,
                session: session ?? AudioHTTPExecutor.defaultSession,
                maxResponseBytes: maxResponseBytes,
                consentDefaults: consentDefaults
            ) { activeKey in
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                req.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
                if !activeKey.isEmpty {
                    req.setValue("Bearer \(activeKey)", forHTTPHeaderField: "Authorization")
                }
                LLMClient.applyCustomHeaders(request.customHeaders, to: &req)
                req.httpBody = body
                return req
            }
            let transcript = try parseTranscriptionResponse(data: data, contentType: contentType)
            if shouldRecordLedger {
                let d = startInstant.duration(to: .now)
                let elapsedMs = Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
                await MainActor.run {
                    _ = recordAudioLedgerEntry(
                        baseURL: request.baseURL,
                        modelID: request.model,
                        isSpeechSynthesis: false,
                        status: .succeeded,
                        httpStatus: 200,
                        elapsedMs: elapsedMs,
                        context: ledgerContainer?.mainContext
                    )
                }
            }
            return transcript
        } catch {
            if shouldRecordLedger, !(error is AppCompliance.ConsentRequired) {
                let d = startInstant.duration(to: .now)
                let elapsedMs = Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
                let status: RequestStatus = (error is CancellationError) ? .cancelled : .failed
                let httpCode: Int? = {
                    if case let LLMError.httpError(code, _) = error { return code }
                    return nil
                }()
                await MainActor.run {
                    _ = recordAudioLedgerEntry(
                        baseURL: request.baseURL,
                        modelID: request.model,
                        isSpeechSynthesis: false,
                        status: status,
                        httpStatus: httpCode,
                        elapsedMs: elapsedMs,
                        context: ledgerContainer?.mainContext
                    )
                }
            }
            throw error
        }
    }
}

enum CloudSpeechSynthesizer {
    static let maxInputCharacters = 4096
    static let maxAudioResponseBytes = 16 * 1024 * 1024

    static let presetModels = ["tts-1", "tts-1-hd", "gpt-4o-mini-tts"]
    static let presetVoices = ["alloy", "nova", "shimmer", "echo", "fable", "onyx"]

    static func prepareInputText(_ cleanedSpeechText: String, maxCharacters: Int = maxInputCharacters) -> String {
        let trimmed = cleanedSpeechText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        let prefix = String(trimmed.prefix(maxCharacters))
        let boundarySet = CharacterSet(charactersIn: "。！？.!?\n")
        if let lastRange = prefix.rangeOfCharacter(from: boundarySet, options: .backwards) {
            let candidate = String(prefix[..<lastRange.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= maxCharacters / 2 {
                return candidate
            }
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildRequestBody(model: String, voice: String, input: String) throws -> Data {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "model": cleanModel.isEmpty ? "tts-1" : cleanModel,
            "input": input,
            "voice": cleanVoice.isEmpty ? "alloy" : cleanVoice,
            "response_format": "mp3"
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func synthesize(
        _ request: CloudTTSRequest,
        keyRouter: APIKeyPoolRouter = .shared,
        session: URLSession? = nil,
        consentDefaults: UserDefaults = AppCompliance.consentDefaults,
        ledgerContainer: ModelContainer? = nil
    ) async throws -> Data {
        let prepared = prepareInputText(request.input)
        guard !prepared.isEmpty else {
            throw LLMError.emptyResponse
        }
        let endpoint = try EndpointResolver.audioSpeechEndpoint(baseURL: request.baseURL)
        let body = try buildRequestBody(model: request.model, voice: request.voice, input: prepared)

        let shouldRecordLedger = ledgerContainer != nil || session == nil
        let startInstant = ContinuousClock.now
        do {
            let (data, _) = try await AudioHTTPExecutor.executeWithKeyRotation(
                baseURL: request.baseURL,
                primaryKey: request.apiKey,
                extraKeys: request.apiKeys,
                keyRouter: keyRouter,
                session: session ?? AudioHTTPExecutor.defaultSession,
                maxResponseBytes: maxAudioResponseBytes,
                consentDefaults: consentDefaults
            ) { activeKey in
                var req = URLRequest(url: endpoint)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("audio/mpeg, audio/*", forHTTPHeaderField: "Accept")
                if !activeKey.isEmpty {
                    req.setValue("Bearer \(activeKey)", forHTTPHeaderField: "Authorization")
                }
                LLMClient.applyCustomHeaders(request.customHeaders, to: &req)
                req.httpBody = body
                return req
            }
            guard !data.isEmpty else {
                throw LLMError.emptyResponse
            }
            if shouldRecordLedger {
                let d = startInstant.duration(to: .now)
                let elapsedMs = Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
                await MainActor.run {
                    _ = AudioTranscriptionService.recordAudioLedgerEntry(
                        baseURL: request.baseURL,
                        modelID: request.model,
                        isSpeechSynthesis: true,
                        status: .succeeded,
                        httpStatus: 200,
                        elapsedMs: elapsedMs,
                        context: ledgerContainer?.mainContext
                    )
                }
            }
            return data
        } catch {
            if shouldRecordLedger, !(error is AppCompliance.ConsentRequired) {
                let d = startInstant.duration(to: .now)
                let elapsedMs = Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
                let status: RequestStatus = (error is CancellationError) ? .cancelled : .failed
                let httpCode: Int? = {
                    if case let LLMError.httpError(code, _) = error { return code }
                    return nil
                }()
                await MainActor.run {
                    _ = AudioTranscriptionService.recordAudioLedgerEntry(
                        baseURL: request.baseURL,
                        modelID: request.model,
                        isSpeechSynthesis: true,
                        status: status,
                        httpStatus: httpCode,
                        elapsedMs: elapsedMs,
                        context: ledgerContainer?.mainContext
                    )
                }
            }
            throw error
        }
    }
}
