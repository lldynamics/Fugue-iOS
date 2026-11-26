@preconcurrency import AVFAudio
import Foundation
import Observation
import os

/// Convert the microphone's negotiated hardware format before it leaves the audio callback.
final class VoiceInputConverter: @unchecked Sendable {
    let converter: AVAudioConverter
    private let framesReceived = OSAllocatedUnfairLock(initialState: 0)
    var capturedFrames: Int { framesReceived.withLock { $0 } }
    let target: AVAudioFormat
    init?(_ input: AVAudioFormat, rate: Double) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target) else { return nil }
        self.target = target
        self.converter = converter
    }
    func convert(_ source: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength)*target.sampleRate/source.format.sampleRate)) + 20
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
        { [self] buffer, _ in
            guard let bytes = convert(buffer) else { return }
            framesReceived.withLock { $0 += bytes.count / 2 }
            continuation.yield(bytes)
        }
    }
}

protocol LiveVoiceSocket: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: LiveVoiceSocket {}

@MainActor @Observable final class LiveVoiceSession {
    struct Line: Identifiable {
        var id = UUID()
        let role: MessageRole
        var text: String
        var itemOrder: Int? = nil
        var startedAt = Date()
        var interrupted = false
        var isFinal = false
    }
    var lines: [Line] = []
    var muted = false
    @ObservationIgnored var checkpoint: (([Line]) throws -> Void)?
    private var inChat = false
    var status = ""
    private(set) var lastFailure: String?
    var running = false
    private var generation = UUID()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var duplex: VoiceProcessingAudioIO?
    private var socket: (any LiveVoiceSocket)?
    private var session: URLSession?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var audioStream: AsyncStream<Data>.Continuation?
    private var validateProvider: (() throws -> Void)?
    private var audioActive = false
    private var inputWatchdog: Task<Void, Never>?
    private var routeUpdates: Task<Void, Never>?
    private var builtInSpeakerActive = false
    private var utteranceEnded = true

    /// An injected PCM stream uses the same encoder, socket, VAD and speaker as microphone input.
    @ObservationIgnored private let pcmInput: AsyncStream<Data>?
    @ObservationIgnored var observeMicrophone: ((Data) -> Void)?
    typealias SocketFactory = (URLSession, URLRequest) -> any LiveVoiceSocket
    @ObservationIgnored private let makeSocket: SocketFactory
    init(pcmInput: AsyncStream<Data>? = nil, makeSocket: @escaping SocketFactory = { session, request in
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        return socket
    }) {
        self.pcmInput = pcmInput
        self.makeSocket = makeSocket
    }

    enum ManualTurn { case idle, preparing, recording, waiting }
    private(set) var manualTurn = ManualTurn.idle
    private(set) var readyForSpeech = false
    private(set) var isFinishing = false
    private(set) var incompleteTranscript = false
    private(set) var usesTapTurns = false
    private(set) var changingTurnMode = false
    private(set) var speakerRequiresTapTurns = false
    private var automaticUtterance: String?
    private var needsGreeting = false
    private var coaching = false
    @ObservationIgnored private var practiceCall: PracticeCall?
    @ObservationIgnored private var checkpointTimer: Task<Void, Never>?
    private(set) var finishedPracticeNormally = false
    private var learnerTurnEndedAt: UInt64?
    private(set) var lastBargeInLocalStopMs: Double?
    var audibleReplyLatencyMs: Int? {
        guard let start = learnerTurnEndedAt, let rendered = duplex?.firstOutputTime, rendered >= start else { return nil }
        return Int((rendered - start) / 1_000_000)
    }
    var speakerGapCount: Int? { duplex?.gapCount }
    var interruptedTutorLines: Set<UUID> { Set(lines.filter { $0.role == .assistant && $0.interrupted }.map(\.id)) }
    @ObservationIgnored private var turnAudio = Data()
    private var activeResponse: String?
    private var cancelledResponses = Set<String>()
    private var cancelEventIDs = Set<String>()
    private var waitingForCommit = false
    private var pendingTranscripts = Set<String>()
    private static let maxTurnBytes = 24_000 * 2 * 60
    static let practiceTranscriptionModel = "gpt-4o-transcribe"


    var audioReady: Bool { duplex?.isRunning == true || engine?.isRunning == true }
    private var playbackItem: String?
    private var discardedItem: String?
    private var playbackStart: AVAudioFramePosition = 0
    private var playbackFrames: AVAudioFramePosition = 0
    private var receivedPlaybackEnd = false
    private var playbackContentIndex = 0
    private var realtimeItems: [String: (order: Int, startedAt: Date)] = [:]
    private(set) var interruptedPlaybackCount = 0
    private(set) var outputAudioFrames = 0

    static func isOpenAI(_ provider: ProviderConfig) -> Bool {
        provider.protocolType == .openAIResponses && officialHost(provider) == "api.openai.com"
    }

    private static func officialHost(_ provider: ProviderConfig) -> String? {
        guard let url = URLComponents(string: provider.baseURL), url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443 else { return nil }
        return url.host?.lowercased()
    }

    static func supports(_ provider: ProviderConfig) -> Bool {
        provider.hasConfiguredChatAPI && !provider.apiKey.isEmpty &&
        (isOpenAI(provider) || (provider.protocolType == .gemini && officialHost(provider) == "generativelanguage.googleapis.com"))
    }

    func start(provider: ProviderConfig, model: String, practiceInstructions: String? = nil,
               practiceLanguage: String? = nil, tapToTalk: Bool = false,
               chatContext: ConversationVoiceContext? = nil, practiceCall: PracticeCall? = nil,
               isCurrent: () -> Bool = { true }) async {
        guard !running, lines.isEmpty else { return }
        running = true
        self.practiceCall = practiceCall
        finishedPracticeNormally = false
        learnerTurnEndedAt = nil
        lastBargeInLocalStopMs = nil
        lastFailure = nil
        usesTapTurns = tapToTalk
        changingTurnMode = false
        speakerRequiresTapTurns = false
        automaticUtterance = nil
        coaching = practiceInstructions != nil
        inChat = chatContext != nil
        muted = false
        needsGreeting = coaching
        readyForSpeech = false
        isFinishing = false
        incompleteTranscript = false
        manualTurn = .idle
        turnAudio.removeAll()
        pendingTranscripts.removeAll()
        activeResponse = nil
        cancelledResponses.removeAll()
        cancelEventIDs.removeAll()
        waitingForCommit = false
        realtimeItems.removeAll()
        interruptedPlaybackCount = 0; outputAudioFrames = 0
        receivedPlaybackEnd = false
        playbackItem = nil; discardedItem = nil; playbackStart = 0; playbackFrames = 0
        let id = UUID(); generation = id
        do {
            try AppCompliance.requireConsent()
            if pcmInput == nil, !(await AVAudioApplication.requestRecordPermission()) { throw ModelTaskError.invalid("请允许麦克风访问") }
            guard generation == id, running else { return }
            guard Self.supports(provider), !model.isEmpty else { throw ModelTaskError.invalid("请选择支持实时音频的官方账号和模型") }
            guard isCurrent() else { throw AppCompliance.RequestChanged() }
            try AppCompliance.requireConsent()
            let openAI = Self.isOpenAI(provider)
            guard !inChat || openAI else { throw LLMError.unavailableModel }
            guard openAI || (!coaching && !usesTapTurns) else { throw LLMError.unavailableModel }
            let originalAddress = provider.baseURL
            let originalProtocol = provider.protocolType
            validateProvider = { [weak provider] in
                guard let provider, provider.modelContext != nil, !provider.isDeleted, provider.isEnabled,
                      provider.protocolType == originalProtocol, provider.baseURL == originalAddress else { throw LLMError.unavailableModel }
            }
            let url: URL
            if openAI {
                var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
                components.queryItems = [URLQueryItem(name: "model", value: model)]
                guard let endpoint = components.url else { throw LLMError.unavailableModel }
                url = endpoint
            } else {
                url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            if openAI {
                request.setValue("Bearer " + provider.apiKey, forHTTPHeaderField: "Authorization")
            } else { request.setValue(provider.apiKey, forHTTPHeaderField: "x-goog-api-key") }
            LLMClient.applyCustomHeaders(provider.resolvedCustomHeaders, to: &request)
            let session = URLSession(configuration: .ephemeral, delegate: SameOriginRedirectDelegate.shared, delegateQueue: nil)
            self.session = session
            let socket = makeSocket(session, request); self.socket = socket
            socket.resume()
            if openAI {
                var vad: [String: Any] = ["type": "server_vad", "create_response": true, "interrupt_response": true]
                if coaching { vad["silence_duration_ms"] = 800 }
                let builtInSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
                let speakerPractice = coaching && pcmInput == nil && builtInSpeaker
                if speakerPractice { vad["threshold"] = 0.625 }
                var transcription = ["model": coaching ? Self.practiceTranscriptionModel : "gpt-4o-mini-transcribe"]
                if coaching, let practiceLanguage, let language = Locale(identifier: "en").localizedString(forIdentifier: practiceLanguage) {
                    transcription["prompt"] = "This is a spoken \(language) lesson. Transcribe the learner verbatim, including short interruptions, repetitions, grammar mistakes and switches to another language. Preserve the words they actually said."
                }
                var input: [String: Any] = ["format": ["type": "audio/pcm", "rate": 24000],
                    "transcription": transcription,
                    "turn_detection": usesTapTurns ? NSNull() as Any : vad]
                if speakerPractice { input["noise_reduction"] = ["type": "far_field"] }
                var setup: [String: Any] = ["type": "realtime", "output_modalities": ["audio"], "audio": ["input": input]]
                setup["instructions"] = chatContext?.instructions ?? practiceInstructions
                try await Self.send(["type": "session.update", "session": setup], to: socket)
                for turn in chatContext?.history ?? [] {
                    guard running, generation == id else { return }
                    try validateProvider?()
                    try AppCompliance.requireConsent()
                    try await Self.send(turn.event, to: socket)
                }
            } else {
                let setup = ["model": model.hasPrefix("models/") ? model : "models/" + model,
                             "generationConfig": ["responseModalities": ["AUDIO"]],
                             "inputAudioTranscription": [:], "outputAudioTranscription": [:]] as [String: Any]
                try await Self.send(["setup": setup], to: socket)
            }
            guard generation == id else { return }
            status = String(localized: "正在连接语音模型…")
            receiver = Task {
                do {
                    while !Task.isCancelled {
                        let frame = try await socket.receive()
                        guard generation == id else { return }
                        let data: Data
                        switch frame { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let error = event["error"] as? [String: Any] {
                            // The server may finish a response while our targeted cancellation is in flight.
                            if error["code"] as? String == "response_cancel_not_active",
                               let eventID = error["event_id"] as? String, cancelEventIDs.remove(eventID) != nil { continue }
                            throw ModelTaskError.invalid(error["message"] as? String ?? "语音服务发生错误")
                        }
                        if (event["setupComplete"] != nil || (openAI && event["type"] as? String == "session.updated")) && !audioActive {
                            status = String(localized: "正在检查麦克风…")
                            try startAudio(socket, id: id, openAI: openAI)
                            if pcmInput != nil { try await audioBecameReady(socket) }
                        }
                        if openAI { try await receiveOpenAI(event, socket: socket) }
                        if let content = event["serverContent"] as? [String: Any] { receive(content) }
                    }
                } catch { if generation == id { fail(error.localizedDescription) } }
            }
        } catch { if generation == id { fail(error.localizedDescription) } }
    }

    private static func send(_ json: [String: Any], to socket: any LiveVoiceSocket) async throws {
        try await socket.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
    }
    private func startAudio(_ socket: any LiveVoiceSocket, id: UUID, openAI: Bool, voiceProcessing: Bool = true) throws {
        let audio = AVAudioSession.sharedInstance()
        if pcmInput == nil {
            try audio.setCategory(.playAndRecord, mode: voiceProcessing ? .voiceChat : .default, options: [.defaultToSpeaker, .allowBluetooth])
            if !voiceProcessing, #available(iOS 18.2, *), audio.isEchoCancelledInputAvailable {
                try? audio.setPrefersEchoCancelledInput(true)
            }
        } else {
            try audio.setCategory(.playback, mode: .default)
        }
        try audio.setActive(true); audioActive = true
        builtInSpeakerActive = audio.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        if openAI, coaching || inChat, pcmInput == nil {
            routeUpdates?.cancel()
            let changes = NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification)
            routeUpdates = Task { [weak self] in
                for await _ in changes {
                    guard !Task.isCancelled, let self, generation == id else { return }
                    builtInSpeakerActive = audio.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
                }
            }
        }
        if coaching && openAI && !usesTapTurns && !voiceProcessing && pcmInput == nil {
            var echoCancelled = false
            if #available(iOS 18.2, *) { echoCancelled = audio.isEchoCancelledInputEnabled }
            speakerRequiresTapTurns = builtInSpeakerActive && !echoCancelled
        }
        let captureRate = openAI ? 24000 : 16000
        let frames: AsyncStream<Data>
        var captureFrames: (() -> Int)?
        if pcmInput == nil && openAI && voiceProcessing {
            let io = VoiceProcessingAudioIO(bufferMilliseconds: coaching ? 2_400 : 240)
            do { try io.start() }
            catch {
                try startAudio(socket, id: id, openAI: openAI, voiceProcessing: false)
                return
            }
            duplex = io
            frames = io.microphone
            captureFrames = { io.capturedFrames }
        } else {
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            guard let playback = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else { throw ModelTaskError.invalid("音频格式不可用") }
            if let pcmInput { frames = pcmInput }
            else {
                let input = engine.inputNode
                do { try input.setVoiceProcessingEnabled(voiceProcessing) }
                catch where voiceProcessing {
                    try startAudio(socket, id: id, openAI: openAI, voiceProcessing: false)
                    return
                }
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, let convert = VoiceInputConverter(format, rate: Double(captureRate)) else { throw ModelTaskError.invalid("音频格式不可用") }
                captureFrames = { convert.capturedFrames }
                let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(10))
                frames = stream.stream
                audioStream = stream.continuation
                input.installTap(onBus: 0, bufferSize: 1024, format: format, block: convert.tap(stream.continuation))
            }
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: playback)
            self.engine = engine; self.player = player
            engine.prepare(); try engine.start(); player.play()
        }
        if let captureFrames {
            inputWatchdog = Task { [weak self] in
                var previousFrames = 0
                var announced = false
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, generation == id else { return }
                    let currentFrames = captureFrames()
                    if currentFrames - previousFrames >= captureRate / 2 {
                        if !announced {
                            announced = true
                            do { try await audioBecameReady(socket) }
                            catch {
                                if generation == id { fail(error.localizedDescription) }
                                return
                            }
                        }
                        previousFrames = currentFrames
                        continue
                    }
                    // A duplex graph can render a single buffer before its input clock stalls.
                    if voiceProcessing && !announced {
                        stopAudioGraph()
                        do { try startAudio(socket, id: id, openAI: openAI, voiceProcessing: false) }
                        catch { fail(error.localizedDescription) }
                    } else {
                        fail(String(localized: "麦克风没有提供音频，请检查输入设备后重试。"))
                    }
                    return
                }
            }
        }
        sender = Task {
            do {
                var automaticPacket = Data()
                var microphoneGate = PracticeMicrophoneGate()
                for await bytes in frames {
                    try Task.checkCancellation()
                    observeMicrophone?(bytes)
                    try AppCompliance.requireConsent()
                    try validateProvider?()
                    if coaching && !readyForSpeech { continue }
                    if usesTapTurns {
                        guard manualTurn == .recording, !isFinishing, turnAudio.count < Self.maxTurnBytes else { continue }
                        turnAudio.append(bytes.prefix(Self.maxTurnBytes - turnAudio.count))
                        if turnAudio.count == Self.maxTurnBytes {
                            status = String(localized: "已录满一分钟，点「说完了」发送。")
                        }
                        continue
                    }
                    if isFinishing || changingTurnMode { automaticPacket.removeAll(keepingCapacity: true); continue }
                    if openAI {
                        if duplex != nil {
                            // The hardware callback may be only a few milliseconds; coalesce it before each socket send.
                            automaticPacket.append(bytes)
                            if automaticPacket.count < 1_920 { continue }
                        }
                        var data = duplex == nil ? bytes : automaticPacket
                        automaticPacket.removeAll(keepingCapacity: true)
                        if (coaching || inChat), let duplex {
                            guard let gated = microphoneGate.process(data, speakerAudible: builtInSpeakerActive && duplex.speakerRecentlyRendered) else { continue }
                            data = gated
                        }
                        if muted { data = Data(repeating: 0, count: data.count) }
                        try await Self.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()], to: socket)
                        continue
                    }
                    try await Self.send(["realtimeInput": ["audio": ["mimeType":"audio/pcm;rate=16000", "data":bytes.base64EncodedString()]]], to: socket)
                }
            } catch { if generation == id && !Task.isCancelled { fail(error.localizedDescription) } }
        }
    }

    private func audioBecameReady(_ socket: any LiveVoiceSocket) async throws {
        guard !readyForSpeech, !isFinishing else { return }
        readyForSpeech = true
        if let practiceCall {
            practiceCall.connected()
            try savePracticeCheckpoint()
            let id = generation
            checkpointTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled, let self, generation == id else { return }
                    do { try savePracticeCheckpoint() } catch { fail(error.localizedDescription); return }
                }
            }
        }
        if speakerRequiresTapTurns {
            // Raw speaker capture otherwise sends the tutor's own voice back to VAD as a learner turn.
            await switchToTapTurns()
            guard running, usesTapTurns, !isFinishing else { return }
        }
        status = usesTapTurns ? String(localized: "轮流发言已就绪") : String(localized: "正在通话 · 可以直接插话")
        if needsGreeting {
            needsGreeting = false
            if usesTapTurns { manualTurn = .waiting }
            try validateProvider?()
            try AppCompliance.requireConsent()
            try await Self.send(["type": "response.create"], to: socket)
        }
    }

    /// Change turn detection on the existing practice session, retaining the conversation.
    func switchToTapTurns() async {
        guard coaching, readyForSpeech, !usesTapTurns, !changingTurnMode, !isFinishing, let socket else { return }
        let id = generation
        changingTurnMode = true
        do {
            try AppCompliance.requireConsent()
            try validateProvider?()
            if automaticUtterance != nil {
                try await flushAutomaticTurn(socket)
                for _ in 0..<25 where automaticUtterance != nil {
                    guard generation == id, !isFinishing else { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard automaticUtterance == nil else {
                    changingTurnMode = false
                    status = String(localized: "请等当前发言结束后再次切换。")
                    return
                }
            }
            guard generation == id, !isFinishing else { return }
            let input: [String: Any] = ["turn_detection": NSNull()]
            try await Self.send(["type": "session.update", "session": ["type": "realtime", "audio": ["input": input]]], to: socket)
            for _ in 0..<50 where changingTurnMode {
                guard generation == id, !isFinishing else { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            if generation == id && changingTurnMode { fail(String(localized: "语音服务未确认发言方式。")) }
        } catch { if generation == id { fail(error.localizedDescription) } }
    }

    private func flushAutomaticTurn(_ socket: any LiveVoiceSocket) async throws {
        // The microphone is already gated. One second of silence closes an open VAD turn.
        let silence = Data(repeating: 0, count: 48_000).base64EncodedString()
        try await Self.send(["type": "input_audio_buffer.append", "audio": silence], to: socket)
    }

    /// In manual mode the speaker stays silent throughout the learner's turn. Only that turn's PCM is sent.
    func beginManualTurn() async {
        guard usesTapTurns, readyForSpeech, !isFinishing, manualTurn == .idle, let socket else { return }
        let id = generation
        manualTurn = .preparing
        let truncate = interruptPlayback()
        do {
            try validateProvider?()
            try AppCompliance.requireConsent()
            if let response = activeResponse { try await cancelResponse(response, on: socket) }
            if let truncate { try await Self.send(truncate, to: socket) }
            guard generation == id, !isFinishing else { return }
            turnAudio.removeAll(keepingCapacity: true)
            manualTurn = .recording
            try savePracticeCheckpoint()
            status = String(localized: "正在听你说")
        } catch { if generation == id { fail(error.localizedDescription) } }
    }

    private func cancelResponse(_ response: String, on socket: any LiveVoiceSocket) async throws {
        guard cancelledResponses.insert(response).inserted else { return }
        let eventID = UUID().uuidString
        cancelEventIDs.insert(eventID)
        try await Self.send(["type": "response.cancel", "response_id": response, "event_id": eventID], to: socket)
    }

    func submitManualTurn() async {
        guard manualTurn == .recording, let socket else { return }
        let audio = turnAudio
        turnAudio = Data()
        guard audio.count >= 4_800 else {
            manualTurn = .idle
            do { try savePracticeCheckpoint() } catch { fail(error.localizedDescription); return }
            status = String(localized: "这句太短，请再说一次。")
            return
        }
        let id = generation
        manualTurn = .waiting
        learnerTurnEndedAt = DispatchTime.now().uptimeNanoseconds
        status = String(localized: "正在等待陪练回应…")
        do {
            waitingForCommit = true
            for offset in stride(from: 0, to: audio.count, by: 48_000) {
                guard generation == id else { return }
                try AppCompliance.requireConsent()
                try validateProvider?()
                let chunk = audio[offset..<min(offset + 48_000, audio.count)]
                try await Self.send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()], to: socket)
            }
            try await Self.send(["type": "input_audio_buffer.commit"], to: socket)
            if !isFinishing { try await Self.send(["type": "response.create"], to: socket) }
        } catch { if generation == id { fail(error.localizedDescription) } }
    }

    func finishPractice() async { await finishWithTranscript() }

    /// Drain the final user transcript before closing the realtime socket.
    func finishWithTranscript() async {
        guard running, !isFinishing else { return }
        isFinishing = true
        let id = generation
        if inChat || practiceCall != nil { _ = interruptPlayback() }
        player?.stop()
        duplex?.discardPlayback()
        if manualTurn == .recording { await submitManualTurn() }
        status = String(localized: "正在保存最后一句…")
        if !usesTapTurns, readyForSpeech, let socket {
            try? await flushAutomaticTurn(socket)
        }
        if practiceCall != nil, let activeResponse, let socket { try? await cancelResponse(activeResponse, on: socket) }
        for tick in 0..<40 {
            guard generation == id, !Task.isCancelled else { return }
            if !waitingForCommit && pendingTranscripts.isEmpty && (activeResponse == nil || practiceCall == nil) && (usesTapTurns || tick >= 8) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == id else { return }
        incompleteTranscript = incompleteTranscript || waitingForCommit || !pendingTranscripts.isEmpty
        finishedPracticeNormally = true
        stop()
    }

    private func playedFrames() -> AVAudioFramePosition {
        if let duplex { return duplex.renderedFrames }
        guard let time = player?.lastRenderTime, let position = player?.playerTime(forNodeTime: time) else { return 0 }
        return position.sampleTime
    }

    var renderedItemFrames: AVAudioFramePosition {
        max(0, min(playbackFrames, playedFrames() - playbackStart))
    }

    var longestSpeakerGapMilliseconds: Int? { duplex.map { $0.longestGapFrames / 24 } }
    var finishedPlayingItem: Bool { receivedPlaybackEnd && playbackFrames > 0 && renderedItemFrames == playbackFrames }
    var remainingItemFrames: AVAudioFramePosition { playbackFrames - renderedItemFrames }

    private func rememberItem(_ id: String) {
        if realtimeItems[id] == nil { realtimeItems[id] = (realtimeItems.count, Date()) }
    }

    // Input transcriptions may finish after the assistant has already started speaking.
    private func transcribe(item: String, role: MessageRole, text: String, final: Bool = false) {
        guard !text.isEmpty else { return }
        rememberItem(item)
        guard let turn = realtimeItems[item] else { return }
        let order = turn.order
        if let index = lines.lastIndex(where: { $0.itemOrder == order }) {
            if final { lines[index].text = text } else { lines[index].text += text }
            lines[index].isFinal = final
        } else {
            let index = lines.firstIndex { ($0.itemOrder ?? -1) > order } ?? lines.endIndex
            lines.insert(Line(role: role, text: text, itemOrder: order, startedAt: turn.startedAt, isFinal: final), at: index)
        }
    }

    private func receiveOpenAI(_ event: [String: Any], socket: any LiveVoiceSocket) async throws {
        let item = event["item_id"] as? String
        let responseID = event["response_id"] as? String
        let isCancelledOutput = responseID.map(cancelledResponses.contains) == true
        switch event["type"] as? String {
        case "session.updated" where changingTurnMode && !isFinishing:
            changingTurnMode = false
            usesTapTurns = true
            manualTurn = .idle
            status = String(localized: "轮流发言已就绪")
        case "conversation.item.added", "conversation.item.created":
            if let details = event["item"] as? [String: Any], let id = details["id"] as? String { rememberItem(id) }
        case "response.created":
            if let response = event["response"] as? [String: Any] { activeResponse = response["id"] as? String }
            if let activeResponse { try practiceCall?.meter(activeResponse, kind: .practiceVoice) }
            if usesTapTurns, manualTurn == .preparing || manualTurn == .recording, let activeResponse {
                // A reply to the last automatic turn can start after the switch has been acknowledged.
                try await cancelResponse(activeResponse, on: socket)
                return
            }
            if usesTapTurns && manualTurn == .waiting {
                manualTurn = .idle
                status = String(localized: "点「我来说」开始下一句。")
            }
        case "response.output_audio.delta":
            guard !isFinishing, !isCancelledOutput, let item, item != discardedItem, let data = event["delta"] as? String else { return }
            if playbackItem != item {
                duplex?.beginItem()
                receivedPlaybackEnd = false
                playbackStart = max(playedFrames(), playbackStart + playbackFrames)
                playbackFrames = 0
                playbackItem = item
                playbackContentIndex = event["content_index"] as? Int ?? 0
            }
            let frames = playPCM(data)
            playbackFrames += AVAudioFramePosition(frames)
            outputAudioFrames += frames
        case "input_audio_buffer.speech_started":
            let detectedAt = DispatchTime.now().uptimeNanoseconds
            if inChat {
                if let item { rememberItem(item) }
                // VAD cancels generation server-side. Drop packets already in flight for that response.
                if let activeResponse { cancelledResponses.insert(activeResponse) }
            }
            if coaching || inChat, let item {
                automaticUtterance = item
                pendingTranscripts.insert(item)
            }
            if let truncate = interruptPlayback() {
                lastBargeInLocalStopMs = Double(DispatchTime.now().uptimeNanoseconds - detectedAt) / 1_000_000
                try await Self.send(truncate, to: socket)
                try checkpoint?(lines)
            }
            try savePracticeCheckpoint()
        case "input_audio_buffer.speech_stopped":
            learnerTurnEndedAt = DispatchTime.now().uptimeNanoseconds
        case "response.output_audio.done":
            if let item, item == playbackItem {
                receivedPlaybackEnd = true
                duplex?.finishEnqueuing()
            }
        case "input_audio_buffer.committed":
            if inChat, let item { rememberItem(item) }
            if automaticUtterance == item { automaticUtterance = nil }
            waitingForCommit = false
            if coaching || inChat, let item { pendingTranscripts.insert(item) }
            if let item { try practiceCall?.meter(item, kind: .practiceTranscription) }
            try savePracticeCheckpoint()
        case "conversation.item.input_audio_transcription.failed":
            if let item { pendingTranscripts.remove(item) }
            incompleteTranscript = true
            if let item { try practiceCall?.meter(item, kind: .practiceTranscription, status: .failed) }
            try savePracticeCheckpoint()
        case "response.output_audio_transcript.delta":
            if !isFinishing, !isCancelledOutput, let item, item != discardedItem, let text = event["delta"] as? String {
                transcribe(item: item, role: .assistant, text: text)
            }
        case "response.output_audio_transcript.done":
            if !isFinishing, !isCancelledOutput, let item, item != discardedItem, let text = event["transcript"] as? String {
                transcribe(item: item, role: .assistant, text: text, final: true)
                try savePracticeCheckpoint()
                try checkpoint?(lines)
            }
        case "conversation.item.input_audio_transcription.delta":
            if inChat, let item, let text = event["delta"] as? String {
                transcribe(item: item, role: .user, text: text)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let item { pendingTranscripts.remove(item) }
            if let item { try practiceCall?.meter(item, kind: .practiceTranscription, usage: event["usage"] as? [String: Any], status: .succeeded) }
            if let item, let text = event["transcript"] as? String {
                transcribe(item: item, role: .user, text: text, final: true)
                try savePracticeCheckpoint()
                try checkpoint?(lines)
            }
        case "response.done":
            if let response = event["response"] as? [String: Any], let id = response["id"] as? String {
                let status: RequestStatus = switch response["status"] as? String {
                case "completed": .succeeded
                case "cancelled": .cancelled
                case "failed": .failed
                default: .incomplete
                }
                try practiceCall?.meter(id, kind: .practiceVoice, usage: response["usage"] as? [String: Any], status: status)
            }
            if let response = event["response"] as? [String: Any], response["status"] as? String == "failed" {
                let details = response["status_details"] as? [String: Any]
                let error = details?["error"] as? [String: Any]
                throw ModelTaskError.invalid(error?["message"] as? String ?? String(localized: "语音服务发生错误"))
            }
            if let response = event["response"] as? [String: Any], response["id"] as? String == activeResponse {
                activeResponse = nil
            }
            utteranceEnded = true
        default: break
        }
    }

    private func interruptPlayback() -> [String: Any]? {
        guard let item = playbackItem else { return nil }
        let heard = renderedItemFrames
        let pending = playbackFrames - heard
        let cutShort = pending > 0 || !receivedPlaybackEnd
        if inChat || practiceCall != nil, cutShort, let index = lines.lastIndex(where: { $0.itemOrder == realtimeItems[item]?.order }) {
            lines[index].interrupted = true
        }
        if cutShort { discardedItem = item }
        player?.stop()
        player?.play()
        duplex?.discardPlayback()
        playbackItem = nil
        playbackFrames = 0
        receivedPlaybackEnd = false
        playbackStart = 0
        utteranceEnded = true
        guard cutShort else { return nil }
        interruptedPlaybackCount += 1
        return ["type": "conversation.item.truncate", "item_id": item,
                "content_index": playbackContentIndex, "audio_end_ms": heard * 1000 / 24000]
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
        guard let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] else { return }
        for part in parts {
            guard let blob = part["inlineData"] as? [String: Any], let mime = blob["mimeType"] as? String,
                  mime.hasPrefix("audio/pcm"), let base64 = blob["data"] as? String else { continue }
            outputAudioFrames += playPCM(base64)
        }
    }

    private func playPCM(_ base64: String) -> Int {
        guard let data = Data(base64Encoded: base64), data.count >= 2, data.count.isMultiple(of: 2) else { return 0 }
        if let duplex { duplex.enqueue(data); return data.count / 2 }
        guard let player, let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?[0] else { return 0 }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { bytes in
            for i in 0..<Int(buffer.frameLength) {
                samples[i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2*i, as: Int16.self))) / 32768
            }
        }
        player.scheduleBuffer(buffer)
        return Int(buffer.frameLength)
    }
    private func stopAudioGraph() {
        routeUpdates?.cancel(); routeUpdates = nil
        inputWatchdog?.cancel()
        inputWatchdog = nil
        sender?.cancel()
        sender = nil
        audioStream?.finish(); audioStream = nil
        if pcmInput == nil { engine?.inputNode.removeTap(onBus: 0) }
        player?.stop(); engine?.stop(); engine = nil; player = nil
        duplex?.stop(); duplex = nil
        if audioActive { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); audioActive = false }
    }

    private func fail(_ message: String) {
        stop()
        lastFailure = message
        status = message
    }

    func stop() {
        if inChat || practiceCall != nil { _ = interruptPlayback() }
        checkpointTimer?.cancel(); checkpointTimer = nil
        if (coaching || inChat) && (waitingForCommit || !pendingTranscripts.isEmpty || !turnAudio.isEmpty) {
            incompleteTranscript = true
        }
        generation = UUID(); validateProvider = nil
        sender?.cancel(); receiver?.cancel(); sender = nil; receiver = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        stopAudioGraph()
        turnAudio = Data()
        readyForSpeech = false
        isFinishing = false
        changingTurnMode = false
        manualTurn = .idle
        running = false; utteranceEnded = true; status = String(localized: "通话已结束")
        do { try savePracticeIfNeeded() } catch { lastFailure = error.localizedDescription }
    }

    private func savePracticeCheckpoint() throws {
        try practiceCall?.checkpoint(lines, incomplete: incompleteTranscript, tapToTalk: speakerRequiresTapTurns ? nil : usesTapTurns, interrupted: interruptedTutorLines,
                                     pending: waitingForCommit || !pendingTranscripts.isEmpty || manualTurn == .recording)
    }

    func savePracticeIfNeeded() throws {
        try practiceCall?.close(self, completed: finishedPracticeNormally)
        practiceCall = nil
    }
}
