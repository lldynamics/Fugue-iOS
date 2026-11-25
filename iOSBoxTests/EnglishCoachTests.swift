import XCTest
@testable import iOSBox

final class EnglishCoachTests: XCTestCase {

    // MARK: - Word-Level Shadowing Alignment & Scoring

    func testShadowingExactAndContractionMatch() {
        let expected = "I'll follow up on the fix and keep you posted."
        let spoken = "I will follow up on the fix and keep you posted"
        let result = EnglishShadowingEvaluator.evaluate(
            expectedSentence: expected,
            spokenTranscript: spoken
        )
        XCTAssertEqual(result.score, 100)
        XCTAssertTrue(result.missedWords.isEmpty)
        XCTAssertTrue(result.fuzzyWords.isEmpty)
        XCTAssertEqual(result.tokens.count, 10)
        XCTAssertTrue(result.tokens.allSatisfy { $0.state == .accurate })

        // Reverse direction: expected "I will" (2 words) vs spoken "I'll" (1 contraction)
        let reverse = EnglishShadowingEvaluator.evaluate(
            expectedSentence: "I will keep you posted.",
            spokenTranscript: "I'll keep you posted"
        )
        XCTAssertEqual(reverse.score, 100)
        XCTAssertEqual(reverse.tokens.count, 5)
        XCTAssertTrue(reverse.tokens.allSatisfy { $0.state == .accurate })
    }

    func testShadowingDetectsMissedAndSubstitutedWords() {
        let expected = "We hit a slight snag with the payment gateway."
        let spoken = "We heat a slight snack with payment"
        let result = EnglishShadowingEvaluator.evaluate(
            expectedSentence: expected,
            spokenTranscript: spoken
        )
        XCTAssertLessThan(result.score, 85)
        XCTAssertTrue(result.missedWords.contains("hit"))
        XCTAssertTrue(result.missedWords.contains("the"))
        XCTAssertTrue(result.missedWords.contains("gateway."))

        let hitToken = result.tokens.first { $0.expectedWord == "hit" }
        XCTAssertEqual(hitToken?.state, .missed)
        XCTAssertEqual(hitToken?.heardWord, "heat")

        // "slight" and "with" should still align accurately despite surrounding errors
        let slightToken = result.tokens.first { $0.expectedWord == "slight" }
        XCTAssertEqual(slightToken?.state, .accurate)
    }

    func testShadowingFuzzyMinorInflection() {
        let expected = "Nothing major, just an unexpected timeout issue."
        let spoken = "Nothing major just an unexpected timeouts issue"
        let result = EnglishShadowingEvaluator.evaluate(
            expectedSentence: expected,
            spokenTranscript: spoken
        )
        let timeoutToken = result.tokens.first { $0.expectedWord == "timeout" }
        XCTAssertEqual(timeoutToken?.state, .fuzzy)
        XCTAssertGreaterThanOrEqual(result.score, 90)
    }

    // MARK: - Persistent Store, Memory & Study Journal

    @MainActor
    func testEnglishCoachStoreLifecycleAndPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("english-coach-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("coach.json")

        let store = EnglishCoachStore(fileURL: storeURL)
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertEqual(store.currentStreakDays, 0)

        var customProfile = EnglishLearnerProfile()
        customProfile.level = .b2
        customProfile.goal = .techAndWork
        customProfile.accent = .uk
        customProfile.customInterest = "SwiftUI architecture"
        store.completeOnboarding(with: customProfile)
        XCTAssertTrue(store.hasCompletedOnboarding)

        store.loadSampleStarterLesson()
        let lesson = try XCTUnwrap(store.activeLesson)
        XCTAssertEqual(lesson.chunks.count, 3)
        XCTAssertEqual(lesson.drills.count, 3)
        XCTAssertEqual(lesson.roleplayTurns.count, 1) // Tutor greeting seeded

        // Evaluate a shadowing drill with one mispronounced word
        let firstDrill = lesson.drills[0]
        let eval = EnglishShadowingEvaluator.evaluate(
            expectedSentence: firstDrill.sentence,
            spokenTranscript: "We heat a slight snag with the payment gateway"
        )
        store.recordShadowingEvaluation(drillID: firstDrill.id, evaluation: eval)
        XCTAssertTrue(store.memory.weakWords.contains { $0.word == "hit" && $0.heardAs.contains("heat") })

        // Append a roleplay exchange using one target chunk and recording a grammar blindspot
        store.appendRoleplayExchange(
            learnerText: "We hit a slight snag, I will follow this thing tomorrow.",
            grammarCorrection: "follow 后需接 up on 表示跟进事项",
            nativeRecast: "We hit a slight snag, and I'll follow up on it tomorrow.",
            blindspotPattern: "follow up 漏介词",
            usedPhrases: [],
            tutorReply: "Got it, thanks for the heads-up! Keep me posted.",
            tutorHintZh: "明白，谢谢提前同步！"
        )

        XCTAssertEqual(store.activeLesson?.activatedPhrases, ["hit a slight snag"])
        XCTAssertEqual(store.memory.grammarBlindspots.first?.pattern, "follow up 漏介词")

        // Finalize to journal
        store.finalizeLessonToJournal(
            tutorSummary: "表现很棒，注意 hit 的短元音 /ɪ/ 与 follow up on 的搭配。",
            updatedTutorNotes: "职场表达意愿强，需巩固短元音与短语动词介词。"
        )
        XCTAssertEqual(store.journalEntries.count, 1)
        XCTAssertEqual(store.currentStreakDays, 1)
        XCTAssertEqual(store.memory.masteredChunks.count, 3)
        XCTAssertEqual(store.journalEntries.first?.recastPairs.count, 1)

        // Reload from disk into a fresh instance to verify atomic JSON persistence
        let reloaded = EnglishCoachStore(fileURL: storeURL)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
        XCTAssertEqual(reloaded.profile.level, .b2)
        XCTAssertEqual(reloaded.profile.accent, .uk)
        XCTAssertEqual(reloaded.journalEntries.count, 1)
        XCTAssertEqual(reloaded.memory.weakWords.first?.word, "hit")
        XCTAssertTrue(reloaded.memory.promptContextSummary().contains("hit"))
        XCTAssertTrue(reloaded.memory.promptContextSummary().contains("follow up 漏介词"))
    }

    // MARK: - LLM JSON Parsers (Reasoning <think> & Code Fence Resilience)

    func testParseLessonAndRoleplayJSONWithThinkBlockAndFences() throws {
        let rawLesson = """
        <think>Designing a B2 tech standup lesson...</think>
        ```json
        {
          "title": "Pushing Back on Scope Creep",
          "scenarioBrief": "在需求评审中温和拒绝临时加塞的需求。",
          "tutorGreeting": "Can we squeeze this extra dashboard widget into Friday's sprint?",
          "roleplayMission": "礼貌说明排期已满，提议放入下个迭代。",
          "chunks": [
            {
              "phrase": "have a full plate",
              "phonetic": "/hæv ə fʊl pleɪt/",
              "meaningZh": "手头任务已排满",
              "usageTip": "委婉表达工作饱和",
              "chinglishTrap": "不要说 my work is very full",
              "nativeExample": "Our team already has a full plate this sprint.",
              "exampleZh": "我们团队这个迭代手头已经排满了。"
            }
          ],
          "drills": [
            {
              "sentence": "We already have a full plate for Friday's release.",
              "translationZh": "周五发版我们手头已经排满了。",
              "focusTip": "have a 连读为 /hæv‿ə/。"
            }
          ]
        }
        ```
        """
        let parsed = try EnglishTutorLLMService.parseLessonJSON(rawLesson, dayNumber: 3)
        XCTAssertEqual(parsed.dayNumber, 3)
        XCTAssertEqual(parsed.title, "Pushing Back on Scope Creep")
        XCTAssertEqual(parsed.chunks.first?.phrase, "have a full plate")
        XCTAssertEqual(parsed.drills.count, 1)

        let rawRoleplay = """
        <think>Checking learner grammar...</think>
        {"tutorReply":"Fair point! Should we slot it into next sprint instead?","tutorHintZh":"说得有道理，放进下个迭代如何？","grammarCorrection":"","nativeRecast":"","blindspotPattern":"","usedTargetPhrases":["have a full plate"]}
        """
        let exchange = try EnglishTutorLLMService.parseRoleplayJSON(rawRoleplay)
        XCTAssertEqual(exchange.tutorReply, "Fair point! Should we slot it into next sprint instead?")
        XCTAssertEqual(exchange.usedTargetPhrases, ["have a full plate"])
    }
}
