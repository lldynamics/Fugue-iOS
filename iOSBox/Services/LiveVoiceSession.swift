@preconcurrency import AVFAudio
import Foundation
import Observation

/// Convert the microphone's negotiated hardware format before it leaves the audio callback.
private final class VoiceInputConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    init?(_ input: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target) else { return nil }
        self.target = target
        self.converter = converter
    }
    func convert(_ source: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength)*16000/source.format.sampleRate)) + 20
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard status != .error, let samples = output.int16ChannelData?[0], output.frameLength > 0 else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength)*2)
    }
    func tap(_ continuation: AsyncStream<Data>.Continuation) -> AVAudioNodeTapBlock {
        { [self] buffer, _ in if let bytes = convert(buffer) { continuation.yield(bytes) } }
    }
}

@MainActor @Observable final class LiveVoiceSession {
    struct Line: Identifiable { var id = UUID(); let role: MessageRole; var text: String }
    var lines: [Line] = []
    var status = ""
    var running = false
    private var generation = UUID()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var audioStream: AsyncStream<Data>.Continuation?
    private var validateProvider: (() throws -> Void)?
    private var audioActive = false
    private var utteranceEnded = true

    func start(provider: ProviderConfig, model: String) async {
        guard !running, lines.isEmpty else { return }
        running = true
        let id = UUID(); generation = id
        do {
            try AppCompliance.requireConsent()
            guard await AVAudioApplication.requestRecordPermission() else { throw ModelTaskError.invalid("请允许麦克风访问") }
            guard generation == id, running else { return }
            guard provider.hasConfiguredChatAPI, provider.protocolType == .gemini,
                  let address = URLComponents(string: provider.baseURL), address.scheme == "https",
                  address.host?.lowercased() == "generativelanguage.googleapis.com",
                  address.port == nil || address.port == 443, !provider.apiKey.isEmpty else {
                throw ModelTaskError.invalid("实时语音需要 Google 官方 Gemini API 账号")
            }
            let originalAddress = provider.baseURL
            validateProvider = { [weak provider] in
                guard let provider, provider.modelContext != nil, !provider.isDeleted, provider.isEnabled,
                      provider.protocolType == .gemini, provider.baseURL == originalAddress else { throw LLMError.unavailableModel }
            }
            let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
            var request = URLRequest(url: url); request.setValue(provider.apiKey, forHTTPHeaderField: "x-goog-api-key")
            let session = URLSession(configuration: .ephemeral, delegate: SameOriginRedirectDelegate.shared, delegateQueue: nil)
            self.session = session
            let socket = session.webSocketTask(with: request); self.socket = socket
            socket.maximumMessageSize = 4 * 1024 * 1024
            socket.resume()
            let setup = ["model": model.hasPrefix("models/") ? model : "models/" + model,
                         "generationConfig": ["responseModalities": ["AUDIO"]],
                         "inputAudioTranscription": [:], "outputAudioTranscription": [:]] as [String: Any]
            try await Self.send(["setup": setup], to: socket)
            status = "正在连接语音模型…"
            receiver = Task {
                do {
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        guard generation == id else { return }
                        let data: Data
                        switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = event["error"] as? [String: Any] { throw ModelTaskError.invalid(error["message"] as? String ?? "语音服务发生错误") }
                        if event["setupComplete"] != nil && engine == nil {
                            try startAudio(socket, id: id)
                            status = "正在通话 · 可以直接插话"
                        }
                        if let content = event["serverContent"] as? [String: Any] { receive(content) }
                    }
                } catch { if generation == id { stop(); status = error.localizedDescription } }
            }
        } catch { if generation == id { stop(); status = error.localizedDescription } }
    }

    private static func send(_ json: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
    }
    private func startAudio(_ socket: URLSessionWebSocketTask, id: UUID) throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try audio.setActive(true); audioActive = true
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let convert = VoiceInputConverter(format),
              let playback = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { throw ModelTaskError.invalid("音频格式不可用") }
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: playback)
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(10))
        audioStream = stream.continuation
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: convert.tap(stream.continuation))
        self.engine = engine; self.player = player
        engine.prepare(); try engine.start(); player.play()
        sender = Task {
            do {
                for await bytes in stream.stream {
                    try Task.checkCancellation()
                    try AppCompliance.requireConsent()
                    try validateProvider?()
                    try await Self.send(["realtimeInput": ["audio": ["mimeType":"audio/pcm;rate=16000", "data":bytes.base64EncodedString()]]], to: socket)
                }
            } catch { if generation == id { stop(); status = error.localizedDescription } }
        }
    }

    func receive(_ content: [String: Any]) {
        if content["interrupted"] as? Bool == true { player?.stop(); player?.play(); utteranceEnded = true }
        for (key, role) in [("inputTranscription", MessageRole.user), ("outputTranscription", .assistant)] {
            if let trans = content[key] as? [String: Any], let text = trans["text"] as? String, !text.isEmpty {
                if !utteranceEnded, let last = lines.indices.last, lines[last].role == role { lines[last].text += text }
                else { lines.append(Line(role: role, text: text)) }
                utteranceEnded = false
            }
        }
        if content["turnComplete"] as? Bool == true { utteranceEnded = true }
        guard let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]],
              let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { return }
        for part in parts {
            guard let blob = part["inlineData"] as? [String: Any], let mime = blob["mimeType"] as? String,
                  mime.hasPrefix("audio/pcm"), let base64 = blob["data"] as? String, let data = Data(base64Encoded: base64), data.count >= 2,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
                  let samples = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = buffer.frameCapacity
            data.withUnsafeBytes { bytes in
                for i in 0..<Int(buffer.frameLength) {
                    samples[i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2*i, as: Int16.self))) / 32768
                }
            }
            player?.scheduleBuffer(buffer)
        }
    }
    func stop() {
        generation = UUID(); validateProvider = nil
        sender?.cancel(); receiver?.cancel(); sender = nil; receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        audioStream?.finish(); audioStream = nil
        engine?.inputNode.removeTap(onBus: 0); player?.stop(); engine?.stop(); engine = nil; player = nil
        if audioActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); audioActive = false }
        running = false; utteranceEnded = true; status = "通话已结束"
    }
}
