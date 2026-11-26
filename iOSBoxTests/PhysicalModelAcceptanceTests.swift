import XCTest
import NaturalLanguage
@preconcurrency import AVFAudio
import SwiftData
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import iOSBox

/// Log the ordering of real turn events without recording microphone samples or learner transcripts.
private final class PracticeEventSocket: LiveVoiceSocket {
    let task: URLSessionWebSocketTask
    init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
    }
    func resume() { task.resume() }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { task.cancel(with: closeCode, reason: reason) }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let text) where text.utf8.count < 8_192: data = Data(text.utf8)
        case .data(let value) where value.count < 8_192: data = value
        default: return message
        }
        if let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let type = event["type"] as? String,
           ["input_audio_buffer.speech_started", "input_audio_buffer.speech_stopped", "input_audio_buffer.committed",
            "response.created", "response.done", "response.output_audio_transcript.done"].contains(type) {
            let result = event["response"] as? [String: Any]
            let response = result?["id"] as? String ?? event["response_id"] as? String ?? ""
            print("FUGUE_TURN \(type) \(response.suffix(5)) \(result?["status"] as? String ?? "")")
        }
        return message
    }
}

/// Explicit hardware acceptance only. Only synthetic content is used. Credentials stay in the app.
final class PhysicalModelAcceptanceTests: XCTestCase {
    private func requireDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPad or iPhone required")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_DEVICE_ACCEPTANCE"] == "1", "Opt-in hardware acceptance")
        #endif
    }

    @MainActor private func account() throws -> (ModelContainer, ProviderConfig, [TaskModel]) {
        try requireDevice()
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let db = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)])
        let providers = try db.mainContext.fetch(FetchDescriptor<ProviderConfig>())
        let accounts = providers.filter { $0.protocolType == .openAIResponses && $0.isReadyForChat }
        guard accounts.count == 1, let provider = accounts.first else { throw XCTSkip("Select one Responses account for hardware acceptance") }
        try AppCompliance.requireConsent()
        let models = TaskModel.options([provider])
        print("FUGUE_DEVICE officialOpenAI=\(URLComponents(string: provider.baseURL)?.host?.lowercased() == "api.openai.com") models=\(models.map(\.spec.id).joined(separator: ","))")
        return (db, provider, models)
    }

    @MainActor func testCapabilitiesOnRealAccount() async throws {
        let (db, _, models) = try account()
        defer { withExtendedLifetime(db) {} }
        let model = try XCTUnwrap(models.first)
        for probe in CapabilityProbe.allCases {
            do {
                try await probe.test(model)
                XCTAssertEqual(probe.result(model)?.passed, true, probe.rawValue)
            } catch {
                XCTFail("\(probe.rawValue): \(error.localizedDescription)")
            }
        }
    }

    @MainActor func testSourceChecksAndExtraction() async throws {
        let (db, _, models) = try account()
        defer { withExtendedLifetime(db) {} }
        let model = try XCTUnwrap(models.first)
        let passage = KnowledgePassage(id: 1, volumeID: UUID(), documentTitle: "验收", sectionTitle: "入库", excerpt: "采购组收到了12支蓝色铅笔。")
        let sources = [ReadingCitation(passage)]
        let checks = try await ClaimCheckSheet.check("采购组收到了蓝色铅笔。铅笔有30支。", evidence: sources, model: model)
        for verdict in ["原文支持", "原文相悖"] {
            XCTAssertTrue(checks.contains { $0.verdict == verdict && $0.citation(in: sources) != nil }, verdict)
        }
        let cells = try await ModelWorkshop.extractRows(sources: [passage], columns: ["物品", "数量"], model: model)
        XCTAssertTrue(cells.contains { $0.column == "数量" && $0.value.contains("12") && $0.source != nil })
        XCTAssertTrue(ModelWorkshop.csv(cells).contains("铅笔"))
    }

    @MainActor func testTwoModelsAndRecommendation() async throws {
        let (db, provider, models) = try account()
        guard models.count >= 2 else { return XCTFail("Two enabled models required") }
        let start = Date()
        for model in models.prefix(2) {
            let result = try await model.run("", input: "只输出数字，七乘六等于多少？")
            XCTAssertEqual(result.text.trimmingCharacters(in: .whitespacesAndNewlines), "42", model.spec.id)
        }
        let records = try db.mainContext.fetch(FetchDescriptor<RequestRecord>(predicate: #Predicate { $0.startedAt >= start }))
        let ranked = ModelRecommendation.rank(providers: [provider], recent: records, requirement: "全部", preference: "速度优先", currency: "USD", budget: "", estimate: 12)
        XCTAssertEqual(ranked.filter { $0.count > 0 }.count, 2)
        let times = ranked.compactMap(\.ms)
        XCTAssertEqual(times, times.sorted())
    }

    @MainActor func testThreeStepReview() async throws {
        let (db, _, models) = try account()
        defer { withExtendedLifetime(db) {} }
        guard models.count >= 2 else { return XCTFail("Two enabled models required") }
        let brief = "写一句中文入库通知，写明收到12支蓝色铅笔。"
        let draft = try await models[0].run("Write a draft in the user's language.", input: brief).text
        let critique = try await models[1].run("Review the draft against the brief. Identify specific corrections.", input: "Brief:\n\(brief)\nDraft:\n\(draft)").text
        let final = try await models[0].run("Revise the draft against the brief, considering the review. Return only the final text.", input: "Brief:\n\(brief)\nDraft:\n\(draft)\nReview:\n\(critique)").text
        XCTAssertTrue(final.contains("铅笔") && final.contains("蓝"))
        let diff = DraftRevision(original: draft, revision: final)
        XCTAssertEqual(diff.text(accepting: Set(diff.changes.filter(\.changed).map(\.id))), final)
    }

    @MainActor func testPrepareSyntheticImageForForegroundAcceptance() throws {
        try requireDevice()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_REGION_UI_FIXTURE"] == "1")
        let (db, _, models) = try account()
        let id = UUID(uuidString: "BF781998-2E2D-45B9-AF1B-43B530EED99A")!
        if try db.mainContext.fetchCount(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })) > 0 { return }
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 160)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { ctx in
            UIColor.red.setFill(); ctx.fill(bounds)
        }
        let target = try XCTUnwrap(models.first)
        let chat = Conversation(id: id, title: "真机验收 · 选区改图", primaryTarget: target.provider.makeTarget(for: target.spec))
        let message = ChatMessage(role: .assistant, content: "用于验证局部修改的红色样图。", sortIndex: 0)
        message.attachments = [.init(kind: .image, fileName: "acceptance.png", mimeType: "image/png",
            dataBase64: bytes.base64EncodedString(), extractedText: nil, byteSize: bytes.count)]
        db.mainContext.insert(chat); message.conversation = chat; db.mainContext.insert(message)
        try db.mainContext.save()
    }

    @MainActor func testRealImageEditingTool() async throws {
        let (db, _, models) = try account()
        defer { withExtendedLifetime(db) {} }
        let model = try XCTUnwrap(models.first)
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rect = CGRect(x: 64, y: 64, width: 128, height: 128)
        let base = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.green.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            ctx.fill(rect)
        }
        let source = try XCTUnwrap(base.pngData())
        let input = MessageAttachment(kind: .image, fileName: "sample.png", mimeType: "image/png", dataBase64: source.base64EncodedString(), extractedText: nil, byteSize: source.count)
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let library = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = library.mainContext
        let message = ChatMessage(role: .user, content: "验收", sortIndex: 0)
        message.attachments = [input]
        context.insert(message)
        try context.save()
        let id = try await RegionImageEditor.edit(model, message: message, attachmentID: input.id, base: base, parent: nil,
            selection: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), prompt: "Replace the entire red square with solid blue. Return the edited image.", context: context)
        let readback = ModelContext(library)
        let saved = try XCTUnwrap(readback.fetch(FetchDescriptor<ChatMessage>()).first?.attachments.first)
        XCTAssertEqual(saved.dataBase64, input.dataBase64)
        let version = try XCTUnwrap(saved.editedVersions?.first)
        XCTAssertEqual(version.id, id)
        XCTAssertNil(version.parent)
        let image = try XCTUnwrap(UIImage(data: version.png))
        for (label, picture) in [("Original synthetic image", base), ("Edited synthetic image", image)] {
            let proof = XCTAttachment(image: picture)
            proof.name = label; proof.lifetime = .keepAlways
            add(proof)
        }
        func pixels(_ value: UIImage) throws -> [UInt8] {
            let cg = try XCTUnwrap(value.cgImage)
            XCTAssertEqual(cg.width, 256); XCTAssertEqual(cg.height, 256)
            var data = [UInt8](repeating: 0, count: 256 * 256 * 4)
            data.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(cg, in: CGRect(origin: .zero, size: size))
            }
            return data
        }
        let before = try pixels(base), after = try pixels(image)
        var outsideChanged = 0
        var blueInside = 0
        for y in 0..<256 {
            for x in 0..<256 {
                let pos = (y * 256 + x) * 4
                if rect.contains(CGPoint(x: x, y: y)) {
                    if after[pos + 2] > after[pos] { blueInside += 1 }
                } else if before[pos..<pos+4] != after[pos..<pos+4] { outsideChanged += 1 }
            }
        }
        print("FUGUE_IMAGE outsideChanged=\(outsideChanged) blueInside=\(blueInside) of 16384")
        XCTAssertEqual(outsideChanged, 0)
        XCTAssertGreaterThan(blueInside, 128 * 128 * 9 / 10)
    }

    @MainActor func testMicrophoneDeliversPCMOnThisRoute() async throws {
        try requireDevice()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_LIVE_MIC_ACCEPTANCE"] == "1")
        let (db, provider, _) = try account()
        defer { withExtendedLifetime(db) {} }
        let session = LiveVoiceSession()
        defer { session.stop() }
        var sent = 0
        session.observeMicrophone = { sent += $0.count / 2 }
        await session.start(provider: provider, model: "gpt-realtime")
        for _ in 0..<300 where sent < 24000 && session.running { try await Task.sleep(for: .milliseconds(100)) }
        print("FUGUE_MIC delivered=\(sent) status=\(session.status)")
        XCTAssertGreaterThanOrEqual(sent, 24000, session.status)
    }

    @MainActor private func spokenPCM(_ text: String) async throws -> Data {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let stream = AsyncStream<Data>.makeStream()
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                stream.continuation.finish()
                return
            }
            if let converter = VoiceInputConverter(pcm.format, rate: 24000), let data = converter.convert(pcm) {
                stream.continuation.yield(data)
            }
        }
        var data = Data()
        for await fragment in stream.stream { data.append(fragment) }
        withExtendedLifetime(synthesizer) {}
        XCTAssertGreaterThan(data.count, 24000)
        return data
    }

    @MainActor func testOpenAIPracticeGreetingManualTurnReviewAndNextLesson() async throws {
        let (db, provider, models) = try account()
        defer { withExtendedLifetime(db) {} }
        let reviewer = try XCTUnwrap(models.first)
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let samples = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var profile = PracticeProfile()
        profile.scene = "At a bookstore, talk about a book the learner bought yesterday."
        profile.tapToTalk = true
        let plan = PracticeLesson(profile: profile, providerID: provider.id, reviewModelID: reviewer.spec.id, targets: [])
        let call = try PracticeCall(provider: provider, model: "gpt-realtime", lesson: plan, resuming: nil, in: samples.mainContext)
        let input = AsyncStream<Data>.makeStream()
        let voice = LiveVoiceSession(pcmInput: input.stream)
        defer { input.continuation.finish(); voice.stop() }
        let spoken = try await spokenPCM("Yesterday I go to the bookstore and buy a book about travel.")
        await voice.start(provider: provider, model: "gpt-realtime", practiceInstructions: call.instructions, practiceLanguage: profile.language, tapToTalk: true, practiceCall: call)
        for _ in 0..<200 where voice.outputAudioFrames < 12000 && voice.running { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThan(voice.outputAudioFrames, 0, voice.status)
        await voice.beginManualTurn()
        guard voice.manualTurn == .recording else { return XCTFail(voice.status) }
        for pos in stride(from: 0, to: spoken.count, by: 1920) {
            input.continuation.yield(spoken.subdata(in: pos..<min(pos + 1920, spoken.count)))
            try await Task.sleep(for: .milliseconds(40))
        }
        await voice.submitManualTurn()
        for _ in 0..<200 where voice.lines.filter({ $0.role == .assistant }).count < 2 && voice.running { try await Task.sleep(for: .milliseconds(100)) }
        for _ in 0..<120 where !voice.lines.contains(where: { $0.role == .user && $0.isFinal }) && voice.running {
            try await Task.sleep(for: .milliseconds(100))
        }
        voice.stop()
        XCTAssertTrue(voice.lines.contains { $0.role == .user && $0.text.localizedCaseInsensitiveContains("book") })
        XCTAssertGreaterThanOrEqual(voice.lines.filter { $0.role == .assistant }.count, 2)
        let chat = call.chat, learnerIDs = chat.assistanceSettings.voicePractice?.learnerTurnIDs
        let saved = try XCTUnwrap(chat.assistanceSettings.voicePractice)
        XCTAssertEqual(saved.isResumable, true)
        let resumed = try PracticeCall(provider: provider, model: "gpt-realtime", lesson: saved, resuming: chat, in: samples.mainContext)
        XCTAssertTrue(resumed.instructions.localizedCaseInsensitiveContains("book"))
        voice.lines = []
        await voice.start(provider: provider, model: "gpt-realtime", practiceInstructions: resumed.instructions, practiceLanguage: profile.language, tapToTalk: true, practiceCall: resumed)
        for _ in 0..<200 where !voice.finishedPlayingItem && voice.running { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(voice.finishedPlayingItem, voice.status)
        await voice.finishPractice()
        XCTAssertEqual(chat.assistanceSettings.voicePractice?.learnerTurnIDs, learnerIDs)
        XCTAssertEqual(chat.assistanceSettings.voicePractice?.isResumable, false)
        let charges = try samples.mainContext.fetch(FetchDescriptor<RequestRecord>())
        XCTAssertTrue(charges.contains { $0.kind == .practiceVoice && ($0.practiceMeter?.audioOutput ?? 0) > 0 })
        XCTAssertTrue(charges.contains { $0.kind == .practiceTranscription && ($0.promptTokens ?? 0) > 0 })
        try await LanguagePractice.review(chat, using: reviewer, helpLanguage: "zh")
        let lessonID = chat.id
        let reviews = try db.mainContext.fetch(FetchDescriptor<RequestRecord>(predicate: #Predicate { $0.conversationID == lessonID }))
        XCTAssertTrue(reviews.contains { $0.kind == .practiceReview && ($0.completionTokens ?? 0) > 0 })
        print("FUGUE_PRACTICE resumed=true seconds=\(Int(chat.assistanceSettings.voicePractice?.callSeconds ?? 0)) voiceRecords=\(charges.filter { $0.kind == .practiceVoice }.count) transcriptionRecords=\(charges.filter { $0.kind == .practiceTranscription }.count) reviewRecords=\(reviews.count)")
        let card = try XCTUnwrap(LanguagePractice.cards(in: chat).first)
        try LanguagePractice.setScheduled(true, cardID: card.id, in: chat)
        let targets = LanguagePractice.dueTargets(in: [chat], language: "en", providerID: provider.id)
        XCTAssertEqual(targets.first?.expression, card.expression)
        XCTAssertTrue(profile.instructions(targets: targets, helpLanguage: "zh").contains(card.expression))
    }

    /// The host plays each learner utterance through its speaker when it sees the corresponding cue.
    @MainActor func testCoachingOnSpeakerThenTapAndReview() async throws {
        try requireDevice()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_PRACTICE_SPEAKER_FIXTURE"] == "1")
        let (db, provider, models) = try account()
        try XCTSkipUnless(LiveVoiceSession.isOpenAI(provider))
        let reviewer = try XCTUnwrap(models.first)
        let voice = LiveVoiceSession(makeSocket: PracticeEventSocket.init)
        let idleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            voice.stop()
            UIApplication.shared.isIdleTimerDisabled = idleTimer
            withExtendedLifetime(db) {}
        }

        var profile = PracticeProfile()
        profile.scene = "At a bookstore, talk about yesterday's shopping."
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let samples = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let plan = PracticeLesson(profile: profile, providerID: provider.id, reviewModelID: reviewer.spec.id, targets: [])
        let call = try PracticeCall(provider: provider, model: "gpt-realtime", lesson: plan, resuming: nil, in: samples.mainContext)
        let instructions = profile.instructions(targets: [], helpLanguage: "zh")
            + "\nIf asked to count, recite every number up to the requested number, slowly and out loud. For this exercise keep counting until the learner interrupts."
        var microphoneFrames = 0
        var levels: [Double] = []
        voice.observeMicrophone = { data in
            microphoneFrames += data.count / 2
            let rms = data.withUnsafeBytes { raw -> Double in
                var squares = 0.0
                for i in stride(from: 0, to: data.count - 1, by: 8) {
                    let sample = Double(raw.loadUnaligned(fromByteOffset: i, as: Int16.self)) / 32768
                    squares += sample * sample
                }
                return sqrt(squares / Double(max(1, (data.count + 7) / 8)))
            }
            levels.append(20 * log10(max(0.000001, rms)))
        }
        func reportLevels(_ phase: String) {
            let sorted = levels.sorted()
            if !sorted.isEmpty {
                let db = [50, 90, 99, 100].map { Int(sorted[(sorted.count - 1) * $0 / 100]) }
                print("FUGUE_PRACTICE micDBFS phase=\(phase) percentiles=\(db)")
            }
            levels.removeAll(keepingCapacity: true)
        }
        func waitFor(_ seconds: Int, _ predicate: () -> Bool) async throws -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(seconds)
            while voice.running && !predicate() && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(80))
            }
            return predicate()
        }
        func cue(_ name: String) {
            print("FUGUE_PRACTICE " + name)
            fflush(nil)
        }
        func heard(_ role: MessageRole, _ word: String) -> Bool {
            voice.lines.contains { $0.role == role && $0.text.localizedCaseInsensitiveContains(word) }
        }
        await voice.start(provider: provider, model: "gpt-realtime", practiceInstructions: instructions, practiceLanguage: profile.language, practiceCall: call)
        let started = try await waitFor(35) { voice.finishedPlayingItem }
        let audio = AVAudioSession.sharedInstance()
        let speaker = audio.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        let mic = audio.currentRoute.inputs.contains { $0.portType == .builtInMic }
        let falseStarts = voice.interruptedPlaybackCount
        reportLevels("opening")
        if let gap = voice.longestSpeakerGapMilliseconds {
            print("FUGUE_PRACTICE opening longestOutputGapMs=\(gap)")
            XCTAssertLessThan(gap, 150, "The greeting ran out of speaker audio mid-utterance")
        }
        print("FUGUE_PRACTICE greeting=\(started) speaker=\(speaker) mic=\(mic) volume=\(audio.outputVolume) mode=\(audio.mode.rawValue) inputFrames=\(microphoneFrames) rendered=\(voice.renderedItemFrames) falseStarts=\(falseStarts)")
        guard voice.running else { return XCTFail(voice.lastFailure ?? voice.status) }
        guard speaker && mic && audio.outputVolume > 0 else { return XCTFail("Requires the iPad's built-in microphone and an audible speaker") }
        XCTAssertTrue(started, voice.status)
        XCTAssertEqual(falseStarts, 0, "The iPad interrupted its own speaker before any learner speech")
        cue("count")
        let counting = try await waitFor(30) {
            heard(.user, "count") && voice.renderedItemFrames >= 9_600 && voice.remainingItemFrames >= 30_000
        }
        print("FUGUE_PRACTICE counting=\(counting) playedMs=\(voice.renderedItemFrames / 24) queuedMs=\(voice.remainingItemFrames / 24)")
        XCTAssertTrue(counting, "The barge-in cue requires audible counting with more speech queued")
        let priorInterruptions = voice.interruptedPlaybackCount
        reportLevels("count")
        cue("barge")
        let redirected = try await waitFor(18) { heard(.user, "blue") && heard(.assistant, "blue") }
        let interrupted = voice.interruptedPlaybackCount > priorInterruptions
        reportLevels("barge")
        let automaticTurns = voice.lines.filter { $0.role == .user }.count
        let interruptionCount = voice.interruptedPlaybackCount - priorInterruptions
        print("FUGUE_PRACTICE heardBlue=\(heard(.user, "blue")) repliedBlue=\(heard(.assistant, "blue")) interrupted=\(interrupted) truncations=\(interruptionCount) turns=\(automaticTurns)")
        if !redirected, automaticTurns == 2, heard(.user, "count"),
           let index = voice.lines.lastIndex(where: { $0.role == .user && $0.text.localizedCaseInsensitiveContains("blue") }) {
            let reply = voice.lines.dropFirst(index + 1).first { $0.role == .assistant }
            print("FUGUE_PRACTICE scriptedFollowup=\(reply.map { String($0.text.prefix(140)) } ?? "(no reply)")")
        }
        if !heard(.user, "blue"), automaticTurns == 2, heard(.assistant, "blue"),
           let line = voice.lines.last(where: { $0.role == .user }),
           ["count", "word", "say", "stop", "blew", "蓝"].contains(where: line.text.localizedCaseInsensitiveContains) {
            print("FUGUE_PRACTICE scriptedInterruptionASR=\(line.text.prefix(120))")
        }
        XCTAssertTrue(redirected, "The spoken interruption should be transcribed and change the model's answer")
        XCTAssertTrue(interrupted, "The active speaker output should be truncated on interruption")
        XCTAssertEqual(automaticTurns, 2, "Only the count request and the interruption should be attributed to the learner")
        if redirected {
            let completed = try await waitFor(15) { voice.finishedPlayingItem }
            XCTAssertTrue(completed, "The spoken follow-up should play to its final sample")
        }

        await voice.switchToTapTurns()
        guard voice.running, voice.usesTapTurns else { return XCTFail(voice.status) }
        let priorUserTurns = Set(voice.lines.filter { $0.role == .user }.map(\.id))
        await voice.beginManualTurn()
        guard voice.manualTurn == .recording else { return XCTFail(voice.status) }
        cue("manual")
        try await Task.sleep(for: .seconds(7))
        XCTAssertEqual(voice.manualTurn, .recording)
        XCTAssertFalse(heard(.user, "notebook"), "The learner's manual turn must wait for submission")
        await voice.submitManualTurn()
        func manualIndex() -> Int? {
            voice.lines.firstIndex { $0.role == .user && !priorUserTurns.contains($0.id)
                && ($0.text.localizedCaseInsensitiveContains("notebook") || $0.text.localizedCaseInsensitiveContains("bookstore")) }
        }
        let replied = try await waitFor(20) {
            guard let index = manualIndex() else { return false }
            return voice.lines.dropFirst(index + 1).contains { $0.role == .assistant && !$0.text.isEmpty }
        }
        let playedToEnd = try await waitFor(30) { voice.finishedPlayingItem }
        print("FUGUE_PRACTICE naturalEnd=\(playedToEnd) renderedReplyMs=\(voice.renderedItemFrames / 24) longestGapMs=\(voice.longestSpeakerGapMilliseconds ?? -1)")
        print("FUGUE_PRACTICE route=\(audio.currentRoute.outputs.map(\.portType.rawValue)) replyFirstRenderMs=\(voice.audibleReplyLatencyMs ?? -1) playbackGaps=\(voice.speakerGapCount ?? -1) vadToLocalStopMs=\(voice.lastBargeInLocalStopMs ?? -1)")
        XCTAssertTrue(playedToEnd, "The complete manual reply should reach the speaker")
        if let gap = voice.longestSpeakerGapMilliseconds { XCTAssertLessThan(gap, 150) }
        await voice.finishPractice()
        print("FUGUE_PRACTICE tapped=\(voice.usesTapTurns) manualSource=\(manualIndex() != nil) manualReply=\(replied) incomplete=\(voice.incompleteTranscript) userTurns=\(voice.lines.filter { $0.role == .user }.count)")
        XCTAssertTrue(replied, "The manual turn and the reply should both appear in order")
        XCTAssertFalse(voice.incompleteTranscript)
        let source = try XCTUnwrap(manualIndex().map { voice.lines[$0] })
        let chat = call.chat
        try await LanguagePractice.review(chat, using: reviewer, helpLanguage: "zh")
        let card = try XCTUnwrap(LanguagePractice.cards(in: chat).first { $0.messageID == source.id && source.text.contains($0.quote) })
        try LanguagePractice.setScheduled(true, cardID: card.id, in: chat)
        let fresh = ModelContext(samples)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<Conversation>()).first)
        let targets = LanguagePractice.dueTargets(in: [saved], language: "en", providerID: provider.id)
        XCTAssertTrue(targets.contains { $0.messageID == source.id && $0.expression == card.expression })
        print("FUGUE_PRACTICE review=\(reviewer.spec.id) groundedCards=\(LanguagePractice.cards(in: saved).count) originalScheduled=\(targets.contains { $0.messageID == source.id })")
    }

    @MainActor func testRealtimeInterruptionWithSpokenFixtures() async throws {
        let (db, provider, _) = try account()
        defer { withExtendedLifetime(db) {} }
        let first = try await spokenPCM("Please count slowly out loud from one to fifty, one number at a time.")
        let second = try await spokenPCM("Stop counting. Say only the word blue.")
        let input = AsyncStream<Data>.makeStream()
        let session = LiveVoiceSession(pcmInput: input.stream)
        defer { input.continuation.finish(); session.stop() }
        await session.start(provider: provider, model: "gpt-realtime")
        let silence = Data(repeating: 0, count: 1920)
        func play(_ data: Data) async throws {
            for pos in stride(from: 0, to: data.count, by: silence.count) {
                input.continuation.yield(data.subdata(in: pos..<min(pos + silence.count, data.count)))
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        for _ in 0..<150 where !session.audioReady && session.running { try await Task.sleep(for: .milliseconds(100)) }
        guard session.audioReady else { return XCTFail(session.status) }
        try await play(first)
        for _ in 0..<400 where session.outputAudioFrames < 24000 && session.running { try await play(silence) }
        guard session.outputAudioFrames >= 24000 else { return XCTFail("No audible model response: " + session.status) }
        try await play(second)
        for _ in 0..<500 where !session.lines.contains(where: { $0.role == .assistant && $0.text.localizedCaseInsensitiveContains("blue") }) && session.running {
            try await play(silence)
        }
        print("FUGUE_FIXTURE interruptions=\(session.interruptedPlaybackCount) audioFrames=\(session.outputAudioFrames)")
        XCTAssertGreaterThan(session.interruptedPlaybackCount, 0, session.status)
        XCTAssertTrue(session.lines.contains { $0.role == .assistant && $0.text.localizedCaseInsensitiveContains("blue") })
    }

    @MainActor func testSpokenInterruptionOnPhysicalDevice() async throws {
        try requireDevice()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_LIVE_MIC_ACCEPTANCE"] == "1", "Interactive microphone acceptance")
        let (db, provider, _) = try account()
        defer { withExtendedLifetime(db) {} }
        let session = LiveVoiceSession()
        defer { session.stop() }
        var microphoneFrames = 0
        var peak = 0
        session.observeMicrophone = { data in
            microphoneFrames += data.count / 2
            data.withUnsafeBytes { raw in
                for pos in stride(from: 0, to: data.count - 1, by: 16) {
                    peak = max(peak, abs(Int(raw.loadUnaligned(fromByteOffset: pos, as: Int16.self))))
                }
            }
        }
        print("FUGUE_VOICE starting; allow microphone if prompted")
        await session.start(provider: provider, model: "gpt-realtime")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(100))
        var last = ""
        var reportedAudio = false
        func blue(_ role: MessageRole) -> Bool {
            session.lines.contains { $0.role == role && ($0.text.localizedCaseInsensitiveContains("blue") || $0.text.contains("蓝")) }
        }
        repeat {
            if last != session.status {
                last = session.status
                print("FUGUE_VOICE " + last)
            }
            if !reportedAudio && session.outputAudioFrames > 0 {
                reportedAudio = true
                print("FUGUE_VOICE model audio reached speaker")
            }
            if session.interruptedPlaybackCount > 0, blue(.user), blue(.assistant) { break }
            if !session.running { break }
            try await Task.sleep(for: .milliseconds(200))
        } while clock.now < deadline
        print("FUGUE_VOICE microphoneFrames=\(microphoneFrames) peak=\(peak) frames=\(session.outputAudioFrames) interruptions=\(session.interruptedPlaybackCount) userTurns=\(session.lines.filter { $0.role == .user }.count)")
        XCTAssertTrue(blue(.user), "The microphone did not transcribe the second instruction")
        XCTAssertTrue(blue(.assistant), "The model did not answer the second instruction")
        XCTAssertGreaterThan(session.outputAudioFrames, 0, last)
        XCTAssertGreaterThan(session.interruptedPlaybackCount, 0, last)
        XCTAssertGreaterThanOrEqual(session.lines.filter { $0.role == .user }.count, 2)
    }

    @MainActor func testSystemModelGeneratesFromSyntheticChineseExcerpt() async throws {
        try requireDevice()
        let result = try await ModelWorkshop.generateLocally(action: "摘要", input: "采购组今天收到了蓝色铅笔。请用一句中文概括，保留颜色和物品名称。")
        XCTAssertTrue(result.contains("蓝") && result.contains("铅笔"))
    }

    func testChineseSemanticRetrievalAcrossTopics() async throws {
        try requireDevice()
        let cases = [
            ("小朋友开心的时候做了什么？", "孩子高兴地拍了拍手，随后蹦蹦跳跳地离开。"),
            ("医生如何帮助病人？", "大夫为患者开了处方，并安排复诊。"),
            ("要坐什么车去机场？", "旅客乘坐大巴前往航站楼。"),
            ("饭菜放在哪里才不会坏？", "剩余食物需要冷藏，避免变质。"),
            ("暴雨过后河水有什么变化？", "强降雨使溪流的水位明显上升。"),
            ("怎样避免密码泄漏？", "账户口令应当妥善保管，不要告诉他人。"),
            ("什么时候应该给植物浇水？", "盆土变干时再补充水分。"),
            ("电池没电了怎么办？", "手机电量耗尽时可接入充电器。")
        ]
        let chapters = (cases.map { $0.1 } + ["螺栓的螺距为两毫米。"]).enumerated().map { BookChapter(title: String($0.offset), text: $0.element) }
        let book = BookManuscript(title: "样本", chapters: chapters)
        let doc = KnowledgeDocumentSnapshot(id: UUID(), title: book.title, manuscript: try book.encoded())
        let search = ProjectKnowledgeSearch()
        var hits = 0
        for (index, item) in cases.enumerated() {
            let result = try await search.retrieve(from: [doc], query: item.0, maxPassages: 1, semantic: true)
            if result.passages.first?.chapterIndex == index { hits += 1 }
            else { print("FUGUE_SEMANTIC missed=\(index) got=\(result.passages.first?.chapterIndex ?? -1)") }
        }
        print("FUGUE_SEMANTIC top1=\(hits)/\(cases.count)")
        XCTAssertGreaterThanOrEqual(hits, 6)
    }

    func testRealChineseSemanticModelOnBookshelf() async throws {
        try requireDevice()
        let question = "小朋友开心的时候做了什么？"
        let lang = PassageSemantics.language(for: question)
        let sentence = NLEmbedding.sentenceEmbedding(for: lang)
        let contextual = PassageSemantics.contextualModel(for: question)
        let scorer = PassageSemantics().scorer(for: question)
        guard let id = scorer.model else {
            return XCTFail("No active Chinese embedding. Sentence model: \(sentence != nil), contextual assets: \(contextual?.hasAvailableAssets == true)")
        }
        let happyText = "孩子高兴地拍了拍手，随后蹦蹦跳跳地离开。"
        let unrelated = "螺栓的螺距为两毫米。"
        let book = BookManuscript(title: "验收样本", chapters: [.init(title: "甲", text: unrelated), .init(title: "乙", text: happyText)])
        let doc = KnowledgeDocumentSnapshot(id: UUID(), title: book.title, manuscript: try book.encoded())
        let evidence = try await ProjectKnowledgeSearch().retrieve(from: [doc], query: question, maxPassages: 1, semantic: true)
        XCTAssertEqual(evidence.passages.first?.excerpt, happyText, "Embedding: \(id)")
    }
}
