import Foundation
import os
import SwiftData
import XCTest
@testable import iOSBox

private final class PracticeSocketFixture: LiveVoiceSocket, @unchecked Sendable {
    private let incoming = AsyncStream<URLSessionWebSocketTask.Message>.makeStream()
    private let sent = OSAllocatedUnfairLock(initialState: [Data]())

    var events: [[String: Any]] {
        sent.withLock { $0 }.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
    var types: [String] { events.compactMap { $0["type"] as? String } }

    func resume() {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { incoming.continuation.finish() }

    func deliver(_ event: [String: Any]) throws {
        incoming.continuation.yield(.data(try JSONSerialization.data(withJSONObject: event)))
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = incoming.stream.makeAsyncIterator()
        guard let message = await iterator.next() else { throw CancellationError() }
        return message
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { throw URLError(.cannotDecodeContentData) }
        let data = Data(text.utf8)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        sent.withLock { $0.append(data) }
        if event["type"] as? String == "session.update" { try deliver(["type": "session.updated"]) }
    }
}

@MainActor final class LanguagePracticeTests: XCTestCase {
    func testSpeakerGateRejectsShortEchoesAndPreservesTheFirstSyllable() {
        func packet(_ amplitude: Int16) -> Data {
            [Int16](repeating: amplitude, count: 960).withUnsafeBytes { Data($0) }
        }
        var gate = PracticeMicrophoneGate()
        let echo = packet(35), impulse = packet(1_000), onset = packet(90), voice = packet(650)
        let silence = packet(0)
        let noise = [echo, echo, impulse, echo, echo, echo, echo, echo]
        var output = Data()
        for input in noise { if let sent = gate.process(input, speakerAudible: true) { output.append(sent) } }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
        for input in [onset, voice, voice, voice] {
            if let sent = gate.process(input, speakerAudible: true) { output.append(sent) }
        }
        XCTAssertEqual(Data(output.suffix(4 * voice.count)), onset + voice + voice + voice)
        XCTAssertEqual(gate.process(silence, speakerAudible: true), silence)
        XCTAssertEqual(gate.process(onset, speakerAudible: false), onset)
        XCTAssertEqual(output.count, (noise.count + 4) * voice.count)
    }

    func testSpeakerPlaysEveryQueuedSampleAndDiscardsInterruptedTails() {
        let audio = VoiceProcessingAudioIO(bufferMilliseconds: 120)
        func render(_ count: Int) -> Data {
            var result = Data(count: count)
            result.withUnsafeMutableBytes { audio.render(into: $0.baseAddress!, count: count) }
            return result
        }
        let first = Data(repeating: 1, count: 1_920)
        let second = Data(repeating: 2, count: 3_840)
        audio.beginItem()
        audio.enqueue(first)
        XCTAssertEqual(render(960), Data(repeating: 0, count: 960))
        XCTAssertEqual(audio.renderedFrames, 0)
        audio.enqueue(second)
        XCTAssertEqual(render(2_880), first + second.prefix(960))
        XCTAssertEqual(render(2_880), second.dropFirst(960))
        XCTAssertEqual(audio.renderedFrames, 2_880)
        _ = render(2_400)
        let tail = Data(repeating: 3, count: 480)
        audio.enqueue(tail)
        audio.finishEnqueuing()
        XCTAssertEqual(render(960), tail + Data(repeating: 0, count: 480))
        XCTAssertEqual(audio.longestGapFrames, 1_200)
        XCTAssertEqual(audio.gapCount, 1)
        XCTAssertNotNil(audio.firstOutputTime)
        audio.enqueue(second)
        audio.discardPlayback()
        XCTAssertEqual(render(960), Data(repeating: 0, count: 960))
        XCTAssertEqual(audio.renderedFrames, 0)
        audio.beginItem()
        audio.enqueue(tail)
        audio.finishEnqueuing()
        XCTAssertEqual(render(480), tail)
        XCTAssertEqual(audio.longestGapFrames, 0)
    }

    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func eventually(_ test: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if test() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(test(), file: file, line: line)
    }

    private func withVoice(tapToTalk: Bool, observeLesson: ((PracticeCall) -> Void)? = nil, _ body: (LiveVoiceSession, PracticeSocketFixture, AsyncStream<Data>.Continuation) async throws -> Void) async throws {
        let db = try container()
        let provider = ProviderConfig(name: "Fixture", protocolType: .openAIResponses, baseURL: "https://api.openai.com/v1")
        db.mainContext.insert(provider)
        let previousConsent = AppCompliance.hasAcceptedAIDisclosure()
        AppCompliance.setAcceptedAIDisclosure(true)
        XCTAssertTrue(KeychainService.shared.saveAPIKey("synthetic-practice", for: provider.credentialID))
        defer {
            KeychainService.shared.deleteAPIKey(for: provider.credentialID)
            AppCompliance.setAcceptedAIDisclosure(previousConsent)
        }
        let socket = PracticeSocketFixture()
        let input = AsyncStream<Data>.makeStream()
        let voice = LiveVoiceSession(pcmInput: input.stream) { _, _ in socket }
        defer { input.continuation.finish(); voice.stop() }
        defer { withExtendedLifetime(db) {} }
        let instructions = PracticeProfile().instructions(targets: [], helpLanguage: "zh-Hans")
        var call: PracticeCall?
        if let observeLesson {
            let plan = PracticeLesson(profile: PracticeProfile(), providerID: provider.id, reviewModelID: "", targets: [])
            let created = try PracticeCall(provider: provider, model: "fixture-realtime", lesson: plan, resuming: nil, in: db.mainContext)
            call = created
            observeLesson(created)
        }
        await voice.start(provider: provider, model: "fixture-realtime", practiceInstructions: instructions, practiceLanguage: "en", tapToTalk: tapToTalk, practiceCall: call)
        try await eventually { voice.readyForSpeech && socket.types.contains("response.create") }
        try await body(voice, socket, input.continuation)
    }

    func testManualInterruptionGatesMicrophoneAndWaitsForLastTranscript() async throws {
        try await withVoice(tapToTalk: true) { voice, socket, mic in
            let setup = try XCTUnwrap(socket.events.first?["session"] as? [String: Any])
            XCTAssertTrue((setup["instructions"] as? String)?.contains("CEFR B1") == true)
            let formats = try XCTUnwrap(setup["audio"] as? [String: Any])
            let config = try XCTUnwrap(formats["input"] as? [String: Any])
            let transcription = try XCTUnwrap(config["transcription"] as? [String: String])
            XCTAssertEqual(transcription["model"], LiveVoiceSession.practiceTranscriptionModel)
            XCTAssertTrue(transcription["prompt"]?.contains("English") == true)
            XCTAssertTrue(config["turn_detection"] is NSNull)
            try socket.deliver(["type": "response.created", "response": ["id": "opening"]])
            let quiet = Data(repeating: 0, count: 96_000).base64EncodedString()
            try socket.deliver(["type": "response.output_audio.delta", "response_id": "opening", "item_id": "greeting", "delta": quiet])
            try await eventually { voice.outputAudioFrames >= 48_000 }
            var captured = 0
            voice.observeMicrophone = { _ in captured += 1 }
            mic.yield(Data(repeating: 1, count: 6_000))
            try await eventually { captured == 1 }
            XCTAssertFalse(socket.types.contains("input_audio_buffer.append"))
            await voice.beginManualTurn()
            XCTAssertEqual(voice.manualTurn, .recording)
            XCTAssertEqual(voice.interruptedPlaybackCount, 1)
            XCTAssertEqual(Array(socket.types.suffix(2)), ["response.cancel", "conversation.item.truncate"])
            // A delta already in flight at the time of cancellation must not play during the learner's turn.
            try socket.deliver(["type": "response.output_audio.delta", "response_id": "opening", "item_id": "late", "delta": quiet])
            try socket.deliver(["type": "response.done", "response": ["id": "opening"]])
            let spoken = Data(repeating: 2, count: 12_000)
            mic.yield(spoken)
            try await eventually { captured == 2 }
            let end = Task { await voice.finishPractice() }
            try await eventually { socket.types.contains("input_audio_buffer.commit") }
            let appends = socket.events.filter { $0["type"] as? String == "input_audio_buffer.append" }
            XCTAssertEqual(appends.count, 1)
            XCTAssertEqual(appends.first?["audio"] as? String, spoken.base64EncodedString())
            XCTAssertEqual(socket.types.filter { $0 == "response.create" }.count, 1)
            try socket.deliver(["type": "input_audio_buffer.committed", "item_id": "learner"])
            try socket.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "learner", "transcript": "Yesterday I go."])
            await end.value
            XCTAssertEqual(voice.lines.filter { $0.role == .user }.map(\.text), ["Yesterday I go."])
            XCTAssertFalse(voice.incompleteTranscript)
            XCTAssertFalse(voice.running)
            XCTAssertEqual(voice.outputAudioFrames, 48_000)
        }
    }

    func testLongManualTurnWaitsForExplicitSendAndShortTapDoesNotCommit() async throws {
        try await withVoice(tapToTalk: true) { voice, socket, mic in
            try socket.deliver(["type": "response.created", "response": ["id": "opening"]])
            try socket.deliver(["type": "response.done", "response": ["id": "opening"]])
            try await eventually { voice.manualTurn == .idle }
            await voice.beginManualTurn()
            await voice.submitManualTurn()
            XCTAssertFalse(socket.types.contains("input_audio_buffer.commit"))
            await voice.beginManualTurn()
            mic.yield(Data(repeating: 1, count: 24_000 * 2 * 61))
            try await eventually { voice.status == String(localized: "已录满一分钟，点「说完了」发送。") }
            XCTAssertEqual(voice.manualTurn, .recording)
            XCTAssertFalse(socket.types.contains("input_audio_buffer.append"))
            await voice.submitManualTurn()
            XCTAssertEqual(socket.types.filter { $0 == "input_audio_buffer.commit" }.count, 1)
        }
    }

    func testSwitchingFromHandsFreeKeepsSessionAndCommitsExactlyOneManualReply() async throws {
        try await withVoice(tapToTalk: false) { voice, socket, mic in
            try socket.deliver(["type": "input_audio_buffer.speech_started", "item_id": "automatic"])
            var captured = 0
            voice.observeMicrophone = { _ in captured += 1 }
            let samples = Data(repeating: 3, count: 8_000)
            mic.yield(samples)
            try await eventually { socket.types.contains("input_audio_buffer.append") }
            let switching = Task { await voice.switchToTapTurns() }
            try await eventually { voice.changingTurnMode }
            try socket.deliver(["type": "input_audio_buffer.committed", "item_id": "automatic"])
            try socket.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "automatic", "transcript": "Hello."])
            await switching.value
            XCTAssertTrue(voice.usesTapTurns)
            XCTAssertEqual(socket.types.filter { $0 == "session.update" }.count, 2)
            XCTAssertEqual(socket.types.filter { $0 == "response.create" }.count, 1)
            let updates = socket.events.filter { $0["type"] as? String == "session.update" }
            let config = try XCTUnwrap(updates.first?["session"] as? [String: Any])
            let audio = try XCTUnwrap(config["audio"] as? [String: Any])
            let settings = try XCTUnwrap(audio["input"] as? [String: Any])
            XCTAssertEqual((settings["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")
            try await eventually { voice.lines.contains { $0.text == "Hello." } }
            await voice.beginManualTurn()
            try socket.deliver(["type": "response.created", "response": ["id": "late-automatic"]])
            try await eventually { socket.events.contains { $0["type"] as? String == "response.cancel" && $0["response_id"] as? String == "late-automatic" } }
            try socket.deliver(["type": "response.output_audio.delta", "item_id": "stale", "response_id": "late-automatic",
                                "delta": samples.base64EncodedString()])
            try socket.deliver(["type": "response.output_audio_transcript.delta", "item_id": "stale",
                                "response_id": "late-automatic", "delta": "Stale reply"])
            try socket.deliver(["type": "response.done", "response": ["id": "late-automatic"]])
            mic.yield(samples)
            try await eventually { captured == 2 }
            await voice.submitManualTurn()
            XCTAssertEqual(Array(socket.types.suffix(3)), ["input_audio_buffer.append", "input_audio_buffer.commit", "response.create"])
            try socket.deliver(["type": "input_audio_buffer.committed", "item_id": "manual"])
            try socket.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "manual", "transcript": "A small coffee, please."])
            try socket.deliver(["type": "response.created", "response": ["id": "coffee"]])
            try socket.deliver(["type": "response.output_audio_transcript.delta", "item_id": "barista", "response_id": "coffee", "delta": "Of course."])
            try await eventually { voice.lines.contains { $0.text == "Of course." } }
            try socket.deliver(["type": "response.output_audio_transcript.done", "item_id": "barista", "response_id": "coffee", "transcript": "Of course. One coffee."])
            try await eventually { voice.lines.contains { $0.text == "Of course. One coffee." } }
            await voice.finishPractice()
            XCTAssertEqual(voice.outputAudioFrames, 0)
            XCTAssertFalse(voice.lines.contains { $0.text == "Stale reply" })
            XCTAssertEqual(voice.lines.filter { $0.role == .user }.map(\.text), ["Hello.", "A small coffee, please."])
        }
    }

    func testReviewQuotesOnlyOriginalLearnerTurnsAndReusesScheduledExpressionOnce() async throws {
        let db = try container()
        let spec = ModelSpec(id: "reviewer")
        let provider = ProviderConfig(name: "Fixture", protocolType: .openAIResponses, baseURL: "https://api.openai.com/v1", models: [spec])
        db.mainContext.insert(provider)
        let accepted = AppCompliance.hasAcceptedAIDisclosure()
        AppCompliance.setAcceptedAIDisclosure(true)
        defer { AppCompliance.setAcceptedAIDisclosure(accepted) }
        let profile = PracticeProfile()
        let plan = PracticeLesson(profile: profile, providerID: provider.id, reviewModelID: spec.id, targets: [])
        let first = LiveVoiceSession.Line(role: .user, text: "Yesterday I go to the store.")
        let chat = try LanguagePractice.saveTranscript([.init(role: .assistant, text: "Tutor-only text"), first], model: "realtime",
                                                      lesson: plan, in: db.mainContext)
        let later = ChatMessage(role: .user, content: "Added after the call", sortIndex: 2)
        db.mainContext.insert(later)
        later.conversation = chat
        let output = #"{"cards":[{"source":1,"quote":"Yesterday I go","expression":"Yesterday I went","note":"过去发生的事情用 went。"},{"source":1,"quote":"Tutor-only text","expression":"hi","note":"wrong source"}]}"#
        let model = TaskModel(provider: provider, spec: spec) { request in
            XCTAssertNotNil(request.schemaObject)
            XCTAssertTrue(request.messages[0].content.contains("Yesterday I go"))
            XCTAssertFalse(request.messages[0].content.contains("Tutor-only"))
            XCTAssertFalse(request.messages[0].content.contains("after the call"))
            return AsyncThrowingStream { $0.yield(.contentDelta(output)); $0.finish() }
        }
        try await LanguagePractice.review(chat, using: model, helpLanguage: "zh-Hans")
        let reviewCharge = try XCTUnwrap(db.mainContext.fetch(FetchDescriptor<RequestRecord>()).first { $0.kind == .practiceReview })
        XCTAssertEqual(reviewCharge.conversationID, chat.id)
        let fresh = ModelContext(db)
        let reopened = try XCTUnwrap(fresh.fetch(FetchDescriptor<Conversation>()).first)
        let card = try XCTUnwrap(LanguagePractice.cards(in: reopened).first)
        XCTAssertEqual(card.messageID, first.id)
        XCTAssertEqual(card.quote, "Yesterday I go")
        XCTAssertEqual(LanguagePractice.cards(in: reopened).count, 1)
        XCTAssertTrue(LanguagePractice.dueTargets(in: [chat], language: "en", providerID: provider.id).isEmpty)
        let now = Date()
        try LanguagePractice.setScheduled(true, cardID: card.id, in: chat, now: now)
        let targets = LanguagePractice.dueTargets(in: [chat], language: "en", providerID: provider.id, now: now)
        XCTAssertTrue(LanguagePractice.dueTargets(in: [chat], language: "ja", providerID: provider.id, now: now).isEmpty)
        XCTAssertTrue(LanguagePractice.dueTargets(in: [chat], language: "en", providerID: UUID(), now: now).isEmpty)
        let target = try XCTUnwrap(targets.first)
        var next = plan
        next.targets = targets
        let instructions = next.profile.instructions(targets: targets, helpLanguage: "zh-Hans")
        XCTAssertTrue(instructions.contains(target.expression))
        XCTAssertFalse(instructions.contains(first.text))
        let secondChat = try LanguagePractice.saveTranscript([.init(role: .user, text: "Yesterday I went to a new hotel.")],
                                                            model: "realtime", lesson: next, in: db.mainContext)
        try LanguagePractice.rate(target, recalled: true, in: secondChat, now: now)
        try LanguagePractice.rate(target, recalled: false, in: secondChat, now: now)
        let scheduled = try XCTUnwrap(LanguagePractice.cards(in: chat).first)
        XCTAssertEqual(scheduled.successes, 1)
        XCTAssertGreaterThan(try XCTUnwrap(scheduled.due), now)
        XCTAssertEqual(secondChat.assistanceSettings.voicePractice?.targets.first?.recalled, true)
        XCTAssertTrue(LanguagePractice.dueTargets(in: [chat, secondChat], language: "en", providerID: provider.id, now: now).isEmpty)
        let backup = BackupService.snapshot(chat, forExport: true)
        XCTAssertEqual(backup.messages.first { $0.id == card.id }?.assistanceMetadata?.practiceCard?.expression, card.expression)
        let cleared = try BackupService.clearMessages(in: chat, context: db.mainContext)
        XCTAssertTrue(LanguagePractice.cards(in: chat).isEmpty)
        try BackupService.undoClear(cleared, in: db.mainContext)
        XCTAssertEqual(LanguagePractice.cards(in: chat).map(\.id), [first.id])
    }

    func testPausedLessonResumesWithConfirmedDialogueAndAccountsForEachBilledEventOnce() async throws {
        let db = try container(), ctx = db.mainContext
        var spec = ModelSpec(id: "fixture-realtime")
        spec.inputPricePerMillion = 2; spec.outputPricePerMillion = 4; spec.cacheReadPricePerMillion = 1
        spec.audioRates = .init(input: 10, output: 20, cachedInput: 3)
        spec.priceCurrency = "USD"
        let provider = ProviderConfig(name: "Fixture", protocolType: .openAIResponses, baseURL: "https://api.openai.com/v1", models: [spec])
        ctx.insert(provider)
        let plan = PracticeLesson(profile: PracticeProfile(), providerID: provider.id, reviewModelID: "", targets: [])
        let first = try PracticeCall(provider: provider, model: spec.id, lesson: plan, resuming: nil, in: ctx)
        let start = Date(timeIntervalSince1970: 1000)
        first.connected(at: start)
        let tutor = LiveVoiceSession.Line(role: .assistant, text: "unheard tutor ending", itemOrder: 1, isFinal: true)
        let learner = LiveVoiceSession.Line(role: .user, text: "I ordered tea", itemOrder: 0, isFinal: true)
        try first.checkpoint([tutor], incomplete: false, tapToTalk: nil, interrupted: [], now: start)
        try first.checkpoint([learner, tutor, .init(role: .assistant, text: "delta only")], incomplete: false, tapToTalk: true, interrupted: [tutor.id], now: start)
        XCTAssertEqual(first.chat.sortedMessages.map(\.id), [learner.id, tutor.id])
        let reported: [String: Any] = ["input_tokens": 30, "output_tokens": 20,
            "input_token_details": ["audio_tokens": 10, "cached_tokens": 8, "cached_tokens_details": ["audio_tokens": 3]],
            "output_token_details": ["audio_tokens": 12]]
        try first.meter("response-1", kind: .practiceVoice)
        try first.meter("response-1", kind: .practiceVoice, usage: reported, status: .cancelled)
        try first.meter("response-1", kind: .practiceVoice, usage: reported, status: .cancelled)
        try first.meter("item-1", kind: .practiceTranscription, usage: ["type": "duration", "seconds": 4.5], status: .succeeded)
        try first.meter("response-2", kind: .practiceVoice)
        try first.close(LiveVoiceSession(), completed: false, now: start.addingTimeInterval(12))
        let fresh = ModelContext(db)
        let reopened = try XCTUnwrap(fresh.fetch(FetchDescriptor<Conversation>()).first)
        let lesson = try XCTUnwrap(reopened.assistanceSettings.voicePractice)
        XCTAssertEqual(lesson.callSeconds, 12); XCTAssertEqual(lesson.isResumable, true)
        let charges = try fresh.fetch(FetchDescriptor<RequestRecord>())
        XCTAssertEqual(charges.count, 3)
        let metered = try XCTUnwrap(charges.first { $0.status == .cancelled })
        XCTAssertEqual(try XCTUnwrap(metered.estimatedCost), 386.0 / 1_000_000, accuracy: 0.000000001)
        XCTAssertEqual(metered.snapshot.practiceMeter?.audioInput, 10)
        XCTAssertNil(charges.first { $0.status == .interrupted }?.estimatedCost)
        XCTAssertEqual(charges.first { $0.kind == .practiceTranscription }?.practiceMeter?.seconds, 4.5)
        let backup = BackupArchive(formatVersion: BackupArchive.currentFormatVersion, exportedAt: .now, appVersion: "test", providers: [], presets: [],
                                   conversations: [BackupService.snapshot(reopened, forExport: true)], requests: charges.map(\.snapshot))
        let restored = try container()
        _ = try BackupService.apply(BackupService.decode(BackupService.encode(backup)), to: restored.mainContext)
        let restoredCharge = try XCTUnwrap(restored.mainContext.fetch(FetchDescriptor<RequestRecord>()).first { $0.id == metered.id })
        XCTAssertEqual(restoredCharge.estimatedCost, metered.estimatedCost)
        let resumed = try PracticeCall(provider: provider, model: spec.id, lesson: lesson, resuming: reopened, in: fresh)
        XCTAssertTrue(resumed.instructions.contains(learner.text)); XCTAssertFalse(resumed.instructions.contains(tutor.text))
        XCTAssertThrowsError(try PracticeCall(provider: provider, model: spec.id, lesson: lesson, resuming: first.chat, in: ctx))
        let later = start.addingTimeInterval(3600)
        resumed.connected(at: later)
        try resumed.close(LiveVoiceSession(), completed: true, now: later.addingTimeInterval(3))
        XCTAssertEqual(reopened.assistanceSettings.voicePractice?.callSeconds, 15)
        XCTAssertEqual(reopened.assistanceSettings.voicePractice?.isResumable, false)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(reopened.sortedMessages.map(\.id), [learner.id, tutor.id])
    }

    func testLiveEventsPersistBeforeDisconnectionAndDoNotDoubleCount() async throws {
        var lesson: PracticeCall?
        try await withVoice(tapToTalk: true, observeLesson: { lesson = $0 }) { voice, socket, _ in
            let chat = try XCTUnwrap(lesson?.chat)
            let ctx = try XCTUnwrap(chat.modelContext)
            try socket.deliver(["type": "response.created", "response": ["id": "r1"]])
            try socket.deliver(["type": "response.output_audio_transcript.done", "item_id": "t", "transcript": "Tea or coffee?"])
            let reply: [String: Any] = ["id":"r1", "status":"completed", "usage":["input_tokens":30, "output_tokens":13, "output_token_details":["audio_tokens":10]] as [String: Any]]
            try socket.deliver(["type": "response.done", "response": reply])
            try socket.deliver(["type": "response.done", "response": reply])
            try socket.deliver(["type":"input_audio_buffer.committed", "item_id":"u"])
            try socket.deliver(["type":"conversation.item.input_audio_transcription.completed", "item_id":"u",
                                "transcript":"Tea please", "usage":["type":"tokens", "input_tokens":9, "output_tokens":3] as [String: Any]])
            try await eventually { chat.sortedMessages.count == 2 }
            let reopened = try XCTUnwrap(ModelContext(ctx.container).fetch(FetchDescriptor<Conversation>()).first)
            XCTAssertEqual(reopened.sortedMessages.map(\.content), ["Tea or coffee?", "Tea please"])
            try socket.deliver(["type": "input_audio_buffer.speech_started", "item_id":"lost"])
            try await eventually { chat.assistanceSettings.voicePractice?.pendingTranscription == true }
            voice.stop()
            XCTAssertEqual(chat.assistanceSettings.voicePractice?.isResumable, true)
            XCTAssertEqual(chat.assistanceSettings.voicePractice?.incompleteTranscript, true)
            let charges = try ctx.fetch(FetchDescriptor<RequestRecord>())
            XCTAssertEqual(charges.count, 2)
            XCTAssertEqual(charges.first { $0.kind == .practiceVoice }?.practiceMeter?.audioOutput, 10)
            XCTAssertEqual(charges.first { $0.kind == .practiceTranscription }?.promptTokens, 9)
        }
    }

    func testGroundingRejectsUnknownQuotesAndDuplicateSources() throws {
        let turns = [LanguagePractice.Turn(id: UUID(), text: "Un café, por favor.")]
        let invalid = #"{"cards":[{"source":2,"quote":"Un café","expression":"un café","note":"out of range"},{"source":1,"quote":"invented","expression":"café","note":"unheard"}]}"#
        XCTAssertThrowsError(try LanguagePractice.validatedCards(from: invalid, turns: turns))
        XCTAssertTrue(try LanguagePractice.validatedCards(from: #"{"cards":[]}"#, turns: turns).isEmpty)
        XCTAssertNil(try JSONDecoder().decode(AssistanceSettings.self, from: Data("{}".utf8)).voicePractice)
        XCTAssertNil(try JSONDecoder().decode(AssistanceMetadata.self, from: Data("{}".utf8)).practiceCard)
    }
}

extension LanguagePracticeTests {
    func testInChatVoiceSeedsScopedHistoryInterruptsAndContinuesOriginalBranch() async throws {
        let db = try container()
        let context = db.mainContext
        let provider = ProviderConfig(name: "Voice fixture", protocolType: .openAIResponses, baseURL: "https://api.openai.com/v1",
                                      models: [ModelSpec(id: "text-fixture")])
        context.insert(provider)
        let textTarget = provider.makeTarget(for: ModelSpec(id: "text-fixture"))
        let chat = Conversation(systemPrompt: "Coach", primaryTarget: textTarget)
        context.insert(chat)
        func add(_ text: String, parent: UUID, role: MessageRole = .user) -> ChatMessage {
            let message = ChatMessage(role: role, content: text, sortIndex: chat.nextMessageSortIndex())
            message.parentMessageID = parent
            message.conversation = chat
            context.insert(message)
            chat.activeLeafMessageID = message.id
            return message
        }
        let old = add("Old topic", parent: ConversationTree.virtualRootID)
        let divider = add("", parent: old.id, role: .system)
        divider.assistanceMetadata.isContextDivider = true
        let sibling = add("Private sibling", parent: divider.id)
        let hidden = add("Excluded", parent: divider.id)
        hidden.assistanceMetadata.isExcludedFromContext = true
        let current = add("Help me rehearse", parent: hidden.id)
        let enabled = PersonalMemory(content: "Explain slowly")
        let disabled = PersonalMemory(content: "Disabled", isEnabled: false)
        let outside = PersonalMemory(content: "Outside scope")
        for memory in [enabled, disabled, outside] { context.insert(memory) }
        chat.assistanceSettings.usePersonalMemory = true
        chat.assistanceSettings.scopedMemoryIDs = [enabled.id, disabled.id]
        try context.save()
        let target = provider.makeTarget(for: ModelSpec(id: "voice-fixture"))
        let seed = ConversationVoiceContext(chat: chat, target: target, omitMemory: false, selectedIDs: nil, context: context)
        XCTAssertEqual(seed.history.map(\.text), [current.content])
        XCTAssertTrue(seed.instructions.contains(enabled.content))
        XCTAssertFalse(seed.instructions.contains(disabled.content))
        XCTAssertFalse(seed.instructions.contains(outside.content))
        XCTAssertEqual(ConversationVoiceContext(chat: chat, target: target, omitMemory: true, selectedIDs: nil, context: context).instructions, "Coach")
        XCTAssertEqual(ConversationVoiceContext(chat: chat, target: target, omitMemory: false, selectedIDs: [], context: context).instructions, "Coach")

        let consent = AppCompliance.hasAcceptedAIDisclosure()
        AppCompliance.setAcceptedAIDisclosure(true)
        XCTAssertTrue(KeychainService.shared.saveAPIKey("synthetic-voice", for: provider.credentialID))
        defer {
            KeychainService.shared.deleteAPIKey(for: provider.credentialID)
            AppCompliance.setAcceptedAIDisclosure(consent)
        }
        let input = AsyncStream<Data>.makeStream(), socket = PracticeSocketFixture()
        let voice = LiveVoiceSession(pcmInput: input.stream) { _, _ in socket }
        let writer = ConversationVoiceWriter(chat: chat, target: target, context: context)
        voice.checkpoint = { lines in try writer.save(lines) }
        defer { input.continuation.finish(); voice.stop() }
        await voice.start(provider: provider, model: target.modelID, chatContext: seed)
        try await eventually { voice.readyForSpeech }
        XCTAssertEqual(socket.types.prefix(2), ["session.update", "conversation.item.create"])
        XCTAssertEqual((socket.events.first?["session"] as? [String: Any])?["instructions"] as? String, seed.instructions)
        let item = try XCTUnwrap(socket.events[1]["item"] as? [String: Any])
        XCTAssertEqual((item["content"] as? [[String: String]])?.first?["text"], current.content)
        XCTAssertFalse(socket.types.contains("response.create"))

        try socket.deliver(["type": "input_audio_buffer.speech_started", "item_id": "q"])
        try socket.deliver(["type": "input_audio_buffer.committed", "item_id": "q"])
        try socket.deliver(["type": "conversation.item.input_audio_transcription.delta", "item_id": "q", "delta": "How"])
        try socket.deliver(["type": "response.output_audio_transcript.delta", "item_id": "a", "delta": "Begin"])
        try await eventually { voice.lines.map(\.text) == ["How", "Begin"] }
        try socket.deliver(["type": "response.output_audio_transcript.done", "item_id": "a", "transcript": "Begin with your name"])
        try socket.deliver(["type": "response.output_audio.delta", "item_id": "a",
                            "delta": Data(repeating: 0, count: 96_000).base64EncodedString()])
        try socket.deliver(["type": "input_audio_buffer.speech_started", "item_id": "q2"])
        try await eventually { socket.types.contains("conversation.item.truncate") }
        try socket.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "q", "transcript": "How do I start?"])
        try socket.deliver(["type": "response.output_audio_transcript.delta", "item_id": "a", "delta": "STALE"])
        try socket.deliver(["type": "input_audio_buffer.committed", "item_id": "q2"])
        try socket.deliver(["type": "conversation.item.input_audio_transcription.completed", "item_id": "q2", "transcript": "Shorter, please"])
        try await eventually { voice.lines.last?.text == "Shorter, please" }
        try socket.deliver(["type": "response.output_audio_transcript.done", "item_id": "b", "transcript": "Say hello."])
        try await eventually { voice.lines.last?.text == "Say hello." }
        await voice.finishWithTranscript()
        try writer.save(voice.lines, ending: true)
        try writer.save(voice.lines, ending: true)
        let active = ConversationTree.activeMessages(in: chat)
        XCTAssertEqual(active.suffix(4).map(\.id), voice.lines.map(\.id))
        XCTAssertEqual(chat.sortedMessages.suffix(4).map(\.id), voice.lines.map(\.id))
        XCTAssertEqual(active.suffix(4).first?.parentMessageID, current.id)
        XCTAssertFalse(active.contains { $0.id == sibling.id })
        let spoken = try XCTUnwrap(active.first { $0.role == .assistant })
        XCTAssertTrue(spoken.assistanceMetadata.isExcludedFromContext)
        XCTAssertFalse(spoken.content.contains("STALE"))
        XCTAssertEqual(spoken.modelID, target.modelID)
        XCTAssertEqual(chat.primaryTarget, textTarget)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        let history = ChatEngine.shared.buildPromptHistory(messages: active, limit: chat.contextMessageLimit)
        XCTAssertEqual(history.map(\.content), [current.content, "How do I start?", "Shorter, please", "Say hello."])
        let requests = OSAllocatedUnfairLock(initialState: [LLMChatRequest]())
        let engine = ChatEngine { request in
            requests.withLock { $0.append(request) }
            return AsyncThrowingStream { stream in
                stream.yield(.contentDelta("Of course."))
                stream.yield(.done)
                stream.finish()
            }
        }
        XCTAssertEqual(engine.sendUserMessage(text: "Now summarize.", attachments: [], in: chat,
                                               providers: [provider], context: context), .sent)
        try await eventually { !engine.isGenerating(in: chat.id) }
        let request = try XCTUnwrap(requests.withLock { $0.first })
        XCTAssertEqual(request.modelID, textTarget.modelID)
        XCTAssertEqual(request.messages.map(\.content), history.map(\.content) + ["Now summarize."])
        XCTAssertEqual(ConversationTree.activeMessages(in: chat).last?.content, "Of course.")
    }
}
