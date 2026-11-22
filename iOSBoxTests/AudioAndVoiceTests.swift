import Foundation
import XCTest
@testable import iOSBox

private final class AudioStubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data, Int) -> (Int, [String: String], Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    private static var counts: [String: Int] = [:]

    static func register(host: String, handler: @escaping Handler) {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        handlers[key] = handler
        counts[key] = 0
    }

    static func count(for host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[host.lowercased(), default: 0]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        let host = url.host?.lowercased() ?? ""
        let bodyData = Self.readBody(from: request)

        Self.lock.lock()
        let attempt = Self.counts[host, default: 0] + 1
        Self.counts[host] = attempt
        let handler = Self.handlers[host]
        Self.lock.unlock()

        guard let handler else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        let (statusCode, headers, payload) = handler(request, bodyData, attempt)
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty {
            client.urlProtocol(self, didLoad: payload)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let direct = request.httpBody {
            return direct
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            result.append(buffer, count: read)
        }
        return result
    }
}

final class AudioAndVoiceTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeConsentDefaults(accepted: Bool) throws -> (UserDefaults, String) {
        let suite = "audio-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        AppCompliance.setAcceptedAIDisclosure(accepted, defaults: defaults)
        return (defaults, suite)
    }

    func testAudioEndpointResolution() throws {
        XCTAssertEqual(
            try EndpointResolver.audioTranscriptionsEndpoint(baseURL: "https://api.openai.com").absoluteString,
            "https://api.openai.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            try EndpointResolver.audioTranscriptionsEndpoint(baseURL: "https://api.groq.com/openai/v1/chat/completions").absoluteString,
            "https://api.groq.com/openai/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            try EndpointResolver.audioTranscriptionsEndpoint(baseURL: "https://custom.example.com/proxy#").absoluteString,
            "https://custom.example.com/proxy/audio/transcriptions"
        )
        XCTAssertEqual(
            try EndpointResolver.audioSpeechEndpoint(baseURL: "https://api.openai.com/v1/models").absoluteString,
            "https://api.openai.com/v1/audio/speech"
        )
        XCTAssertEqual(
            try EndpointResolver.audioSpeechEndpoint(baseURL: "https://api.openai.com/v1/audio/transcriptions").absoluteString,
            "https://api.openai.com/v1/audio/speech"
        )
        XCTAssertEqual(
            try EndpointResolver.audioSpeechEndpoint(baseURL: "http://192.168.1.50:8000").absoluteString,
            "http://192.168.1.50:8000/v1/audio/speech"
        )
        XCTAssertThrowsError(try EndpointResolver.audioTranscriptionsEndpoint(baseURL: "invalid-url"))
    }

    func testWhisperTranscribeMultipartKeyRotationAndSecurityGuards() async throws {
        let (defaults, suite) = try makeConsentDefaults(accepted: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        let host = "audio-stub-\(UUID().uuidString.lowercased()).example.com"
        AudioStubURLProtocol.register(host: host) { request, bodyData, attempt in
            if attempt == 1 {
                return (
                    429,
                    ["Content-Type": "application/json"],
                    Data(#"{"error":{"message":"Rate limited"}}"#.utf8)
                )
            }
            let body = String(decoding: bodyData, as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
            XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh"))
            XCTAssertTrue(body.contains("filename=\"my_meeting_.m4a\""))
            XCTAssertFalse(body.contains("../"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "stage-b")
            return (
                200,
                ["Content-Type": "application/json"],
                Data(#"{"text":"下周三上午十点对齐交付物。"}"#.utf8)
            )
        }

        let transcript = try await AudioTranscriptionService.transcribe(
            AudioTranscriptionRequest(
                baseURL: "https://\(host)/v1",
                apiKey: "sk-1",
                apiKeys: ["sk-2"],
                customHeaders: [CustomHeader(key: "X-Trace", value: "stage-b")],
                model: "whisper-large-v3-turbo",
                language: "zh",
                fileName: "../my\"meeting\n.m4a",
                mimeType: "audio/mp4",
                audioData: Data([0x01, 0x02, 0x03])
            ),
            keyRouter: APIKeyPoolRouter(),
            session: makeSession(),
            consentDefaults: defaults
        )

        XCTAssertEqual(transcript, "下周三上午十点对齐交付物。")
        XCTAssertEqual(AudioStubURLProtocol.count(for: host), 2)

        do {
            _ = try await AudioTranscriptionService.transcribe(
                AudioTranscriptionRequest(
                    baseURL: "http://api.openai.com/v1",
                    apiKey: "sk-1",
                    fileName: "a.m4a",
                    mimeType: "audio/mp4",
                    audioData: Data([0x01])
                ),
                session: makeSession(),
                consentDefaults: defaults
            )
            XCTFail("Expected plain HTTP public host rejection")
        } catch is LLMError {
            // Expected
        }

        let (noConsentDefaults, noConsentSuite) = try makeConsentDefaults(accepted: false)
        defer { noConsentDefaults.removePersistentDomain(forName: noConsentSuite) }
        do {
            _ = try await AudioTranscriptionService.transcribe(
                AudioTranscriptionRequest(
                    baseURL: "https://\(host)/v1",
                    apiKey: "sk-1",
                    fileName: "a.m4a",
                    mimeType: "audio/mp4",
                    audioData: Data([0x01])
                ),
                session: makeSession(),
                consentDefaults: noConsentDefaults
            )
            XCTFail("Expected consent rejection")
        } catch is AppCompliance.ConsentRequired {
            // Expected
        }
    }

    func testCloudSpeechSynthesizerAndTextCleaning() async throws {
        let (defaults, suite) = try makeConsentDefaults(accepted: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        let host = "tts-stub-\(UUID().uuidString.lowercased()).example.com"
        let mp3Bytes = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x22])
        AudioStubURLProtocol.register(host: host) { request, bodyData, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-tts")
            XCTAssertTrue(request.url?.path.hasSuffix("/v1/audio/speech") == true)
            let json = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
            XCTAssertEqual(json["model"] as? String, "tts-1-hd")
            XCTAssertEqual(json["voice"] as? String, "nova")
            XCTAssertEqual(json["response_format"] as? String, "mp3")
            return (200, ["Content-Type": "audio/mpeg"], mp3Bytes)
        }

        let audioData = try await CloudSpeechSynthesizer.synthesize(
            CloudTTSRequest(
                baseURL: "https://\(host)/v1",
                apiKey: "sk-tts",
                model: "tts-1-hd",
                voice: "nova",
                input: "欢迎使用夜奔语音朗读。"
            ),
            keyRouter: APIKeyPoolRouter(),
            session: makeSession(),
            consentDefaults: defaults
        )
        XCTAssertEqual(audioData, mp3Bytes)

        let cleaned = SpeechService.cleanForSpeech("## 结论\n**请查看** [文档](https://example.com) ```swift\nlet x = 1\n```")
        XCTAssertFalse(cleaned.contains("**"))
        XCTAssertFalse(cleaned.contains("https://"))
        XCTAssertTrue(cleaned.contains("请查看"))
        XCTAssertTrue(cleaned.contains("文档"))
        XCTAssertTrue(cleaned.contains("代码片段"))

        let longText = "第一段结束。" + String(repeating: "a", count: 3800) + "第二段结束。" + String(repeating: "b", count: 500)
        let trimmed = CloudSpeechSynthesizer.prepareInputText(longText, maxCharacters: 4096)
        XCTAssertLessThanOrEqual(trimmed.count, 4096)
        XCTAssertTrue(trimmed.hasSuffix("第二段结束。"))
    }

    func testMeetingMinutesPromptBuilder() {
        let comps = DateComponents(year: 2026, month: 11, day: 22)
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let prompt = MeetingMinutesPromptBuilder.buildPrompt(
            transcript: "下周一上午十点前提交设计稿",
            sourceLabel: "sync.m4a",
            mode: .meetingMinutes,
            date: date
        )
        XCTAssertTrue(prompt.contains("2026-11-22"))
        XCTAssertTrue(prompt.contains("sync.m4a"))
        XCTAssertTrue(prompt.contains("YYYY-MM-DD HH:mm"))
        XCTAssertTrue(prompt.contains("下周一上午十点前提交设计稿"))

        let raw = MeetingMinutesPromptBuilder.buildPrompt(transcript: "  保留原样  ", mode: .insertRaw)
        XCTAssertEqual(raw, "保留原样")
    }
}
