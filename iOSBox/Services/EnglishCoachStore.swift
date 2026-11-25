import Foundation
import Observation

@MainActor
@Observable
final class EnglishCoachStore {
    static let shared = EnglishCoachStore()

    struct PersistedState: Codable {
        var hasCompletedOnboarding: Bool = false
        var profile: EnglishLearnerProfile = EnglishLearnerProfile()
        var memory: EnglishLearnerMemory = EnglishLearnerMemory()
        var activeLesson: EnglishDailyLesson? = nil
        var recentTopicTitles: [String] = []
        var journalEntries: [EnglishStudyLogEntry] = []
    }

    private(set) var hasCompletedOnboarding: Bool = false
    var profile: EnglishLearnerProfile = EnglishLearnerProfile() {
        didSet { save() }
    }
    private(set) var memory: EnglishLearnerMemory = EnglishLearnerMemory()
    private(set) var activeLesson: EnglishDailyLesson? = nil
    private(set) var recentTopicTitles: [String] = []
    private(set) var journalEntries: [EnglishStudyLogEntry] = []
    var storageError: String?

    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL? = EnglishCoachStore.defaultFileURL()) {
        self.fileURL = fileURL
        reload()
    }

    nonisolated static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("english-coach-store.json")
    }

    nonisolated static func todayDateKey(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    var currentStreakDays: Int {
        let uniqueDates = Set(journalEntries.map(\.dateKey))
        guard !uniqueDates.isEmpty else { return 0 }
        let cal = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var cursor = Date()
        let todayKey = formatter.string(from: cursor)
        if !uniqueDates.contains(todayKey) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
                  uniqueDates.contains(formatter.string(from: yesterday)) else {
                return 0
            }
            cursor = yesterday
        }

        var streak = 0
        while uniqueDates.contains(formatter.string(from: cursor)) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    var nextDayNumber: Int {
        max(1, journalEntries.count + 1)
    }

    func reload() {
        guard let fileURL else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(PersistedState.self, from: data)
            self.hasCompletedOnboarding = state.hasCompletedOnboarding
            self.profile = state.profile
            self.memory = state.memory
            self.activeLesson = state.activeLesson
            self.recentTopicTitles = state.recentTopicTitles
            self.journalEntries = state.journalEntries
            self.storageError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            self.storageError = nil
        } catch {
            self.storageError = error.localizedDescription
        }
    }

    func save() {
        guard let fileURL else { return }
        do {
            let state = PersistedState(
                hasCompletedOnboarding: hasCompletedOnboarding,
                profile: profile,
                memory: memory,
                activeLesson: activeLesson,
                recentTopicTitles: recentTopicTitles,
                journalEntries: journalEntries
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    func completeOnboarding(with updatedProfile: EnglishLearnerProfile) {
        self.profile = updatedProfile
        self.hasCompletedOnboarding = true
        save()
    }

    func setActiveLesson(_ lesson: EnglishDailyLesson) {
        var seeded = lesson
        if seeded.roleplayTurns.isEmpty && !seeded.tutorGreeting.isEmpty {
            seeded.roleplayTurns = [
                EnglishRoleplayTurn(
                    speaker: .tutor,
                    text: seeded.tutorGreeting,
                    hintZh: seeded.roleplayMission
                )
            ]
        }
        self.activeLesson = seeded
        if !recentTopicTitles.contains(seeded.title) {
            recentTopicTitles.insert(seeded.title, at: 0)
            if recentTopicTitles.count > 20 {
                recentTopicTitles = Array(recentTopicTitles.prefix(20))
            }
        }
        save()
    }

    func loadSampleStarterLesson() {
        let sample = EnglishDailyLesson(
            dateKey: Self.todayDateKey(),
            dayNumber: nextDayNumber,
            title: "Syncing Project Delays Gracefully",
            scenarioBrief: String(localized: "在跨国团队站会中，礼貌且专业地同步一项接口联调延期，并给出明确的兜底时间表。"),
            tutorGreeting: "Hey! Quick standup check-in — how is the API integration coming along for Friday's release?",
            roleplayMission: String(localized: "向 PM 说明联调遇到了一点阻碍，自然用出至少 2 个今日地道短语，并承诺明晚前跟进结果。"),
            chunks: [
                EnglishLessonChunk(
                    phrase: "hit a slight snag",
                    phonetic: "/hɪt ə slaɪt snæɡ/",
                    meaningZh: "遇到一点小波折 / 卡壳",
                    usageTip: "比 problem / trouble 更轻松得体，适合职场汇报可控的小阻碍。",
                    chinglishTrap: "避免生硬直译成 meet a small trouble",
                    nativeExample: "We hit a slight snag with the auth token refresh.",
                    exampleZh: "我们在鉴权令牌刷新上遇到了一点小波折。"
                ),
                EnglishLessonChunk(
                    phrase: "follow up on",
                    phonetic: "/ˈfɑːloʊ ʌp ɑːn/",
                    meaningZh: "继续跟进落实某事",
                    usageTip: "后接具体事项，不要漏掉介词 on。",
                    chinglishTrap: "切忌说成 follow this thing",
                    nativeExample: "I'll follow up on the edge cases by tomorrow evening.",
                    exampleZh: "明晚前我会把边界情况跟进到位。"
                ),
                EnglishLessonChunk(
                    phrase: "keep you posted",
                    phonetic: "/kiːp ju ˈpoʊstɪd/",
                    meaningZh: "随时向你同步最新进展",
                    usageTip: "高频地道收尾句，比 tell you news 自然得多。",
                    chinglishTrap: "不要说成 let you know new information",
                    nativeExample: "Let me run one more test and keep you posted.",
                    exampleZh: "我再跑一轮测试，随时跟你同步进展。"
                )
            ],
            drills: [
                EnglishShadowingDrill(
                    sentence: "We hit a slight snag with the payment gateway.",
                    translationZh: "我们在支付网关上遇到了一点小波折。",
                    focusTip: "注意 hit a (/hɪt‿ə/) 连读，slight 尾音 /t/ 轻触不重读。"
                ),
                EnglishShadowingDrill(
                    sentence: "Nothing major, just an unexpected timeout issue.",
                    translationZh: "不是大问题，只是一个意外的超时异常。",
                    focusTip: "just an (/dʒʌst‿ən/) 顺滑连读，重音落在 unexpected。"
                ),
                EnglishShadowingDrill(
                    sentence: "I'll follow up on the fix and keep you posted.",
                    translationZh: "我会跟进修复进展，并随时向你同步。",
                    focusTip: "follow up on 三词连贯过渡，keep you 中 /p/ 与 /j/ 自然衔接。"
                )
            ]
        )
        setActiveLesson(sample)
    }

    // MARK: - Shadowing Updates & Weak Word Memory

    func recordShadowingEvaluation(
        drillID: UUID,
        evaluation: ShadowingEvaluationSummary
    ) {
        guard var lesson = activeLesson,
              let idx = lesson.drills.firstIndex(where: { $0.id == drillID }) else { return }
        let previousBest = lesson.drills[idx].bestScore ?? 0
        lesson.drills[idx].bestScore = max(previousBest, evaluation.score)
        lesson.drills[idx].lastSpokenTranscript = evaluation.spokenTranscript
        lesson.drills[idx].lastEvaluationTokens = evaluation.tokens
        activeLesson = lesson

        for token in evaluation.tokens where token.state == .missed {
            let cleaned = EnglishShadowingEvaluator.cleanToken(token.expectedWord)
            guard cleaned.count >= 2 else { continue }
            recordWeakWord(cleaned, heardAs: token.heardWord)
        }
        save()
    }

    func setShadowingCoachFeedback(drillID: UUID, feedback: String) {
        guard var lesson = activeLesson,
              let idx = lesson.drills.firstIndex(where: { $0.id == drillID }) else { return }
        lesson.drills[idx].aiCoachFeedback = feedback
        activeLesson = lesson
        save()
    }

    func recordWeakWord(_ word: String, heardAs: String? = nil) {
        let lower = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return }
        let cleanHeard = heardAs?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = memory.weakWords.firstIndex(where: { $0.word.lowercased() == lower }) {
            memory.weakWords[idx].missCount += 1
            memory.weakWords[idx].lastMissedAt = Date()
            if let cleanHeard, !cleanHeard.isEmpty, !memory.weakWords[idx].heardAs.contains(cleanHeard) {
                memory.weakWords[idx].heardAs.insert(cleanHeard, at: 0)
                memory.weakWords[idx].heardAs = Array(memory.weakWords[idx].heardAs.prefix(4))
            }
        } else {
            memory.weakWords.insert(
                EnglishWeakWordItem(
                    word: lower,
                    heardAs: (cleanHeard?.isEmpty == false) ? [cleanHeard!] : [],
                    missCount: 1,
                    lastMissedAt: Date()
                ),
                at: 0
            )
            if memory.weakWords.count > 50 {
                memory.weakWords = Array(memory.weakWords.prefix(50))
            }
        }
    }

    func removeWeakWord(id: UUID) {
        memory.weakWords.removeAll { $0.id == id }
        save()
    }

    func removeGrammarBlindspot(id: UUID) {
        memory.grammarBlindspots.removeAll { $0.id == id }
        save()
    }

    // MARK: - Roleplay Turn & Memory Updates

    func appendRoleplayExchange(
        learnerText: String,
        grammarCorrection: String?,
        nativeRecast: String?,
        blindspotPattern: String?,
        usedPhrases: [String],
        tutorReply: String,
        tutorHintZh: String?
    ) {
        guard var lesson = activeLesson else { return }

        let detectedPhrases = detectUsedTargetPhrases(in: learnerText, lessonChunks: lesson.chunks, modelReported: usedPhrases)
        for p in detectedPhrases where !lesson.activatedPhrases.contains(p) {
            lesson.activatedPhrases.append(p)
        }

        let learnerTurn = EnglishRoleplayTurn(
            speaker: .learner,
            text: learnerText,
            grammarCorrection: (grammarCorrection?.isEmpty == false) ? grammarCorrection : nil,
            nativeRecast: (nativeRecast?.isEmpty == false) ? nativeRecast : nil,
            blindspotPattern: (blindspotPattern?.isEmpty == false) ? blindspotPattern : nil,
            usedTargetPhrases: detectedPhrases
        )
        let tutorTurn = EnglishRoleplayTurn(
            speaker: .tutor,
            text: tutorReply,
            hintZh: (tutorHintZh?.isEmpty == false) ? tutorHintZh : nil
        )
        lesson.roleplayTurns.append(learnerTurn)
        lesson.roleplayTurns.append(tutorTurn)
        activeLesson = lesson

        if let pattern = blindspotPattern?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pattern.isEmpty,
           let recast = nativeRecast?.trimmingCharacters(in: .whitespacesAndNewlines),
           !recast.isEmpty {
            recordGrammarBlindspot(pattern: pattern, userExample: learnerText, nativeFix: recast)
        }
        save()
    }

    private func detectUsedTargetPhrases(
        in text: String,
        lessonChunks: [EnglishLessonChunk],
        modelReported: [String]
    ) -> [String] {
        let lowerText = text.lowercased()
        var matched = Set(modelReported)
        for chunk in lessonChunks {
            let cleanPhrase = chunk.phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanPhrase.isEmpty && lowerText.contains(cleanPhrase) {
                matched.insert(chunk.phrase)
            }
        }
        return lessonChunks.map(\.phrase).filter { matched.contains($0) }
    }

    func recordGrammarBlindspot(pattern: String, userExample: String, nativeFix: String) {
        let normalized = pattern.lowercased()
        if let idx = memory.grammarBlindspots.firstIndex(where: { $0.pattern.lowercased() == normalized }) {
            memory.grammarBlindspots[idx].occurrences += 1
            memory.grammarBlindspots[idx].userExample = String(userExample.prefix(200))
            memory.grammarBlindspots[idx].nativeFix = String(nativeFix.prefix(200))
            memory.grammarBlindspots[idx].updatedAt = Date()
        } else {
            memory.grammarBlindspots.insert(
                EnglishGrammarBlindspot(
                    pattern: String(pattern.prefix(80)),
                    userExample: String(userExample.prefix(200)),
                    nativeFix: String(nativeFix.prefix(200))
                ),
                at: 0
            )
            if memory.grammarBlindspots.count > 40 {
                memory.grammarBlindspots = Array(memory.grammarBlindspots.prefix(40))
            }
        }
    }

    // MARK: - Complete Lesson & Archive to Study Journal

    func finalizeLessonToJournal(tutorSummary: String, updatedTutorNotes: String?) {
        guard var lesson = activeLesson else { return }
        lesson.isCompleted = true
        activeLesson = lesson

        for chunk in lesson.chunks {
            if !memory.masteredChunks.contains(where: { $0.phrase.lowercased() == chunk.phrase.lowercased() }) {
                memory.masteredChunks.insert(
                    EnglishMasteredChunk(
                        phrase: chunk.phrase,
                        phonetic: chunk.phonetic,
                        meaningZh: chunk.meaningZh,
                        sampleSentence: chunk.nativeExample
                    ),
                    at: 0
                )
            }
        }
        if memory.masteredChunks.count > 120 {
            memory.masteredChunks = Array(memory.masteredChunks.prefix(120))
        }
        if let notes = updatedTutorNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            memory.tutorNotes = String(notes.prefix(600))
        }

        let recasts: [EnglishRecastPair] = lesson.roleplayTurns.compactMap { turn in
            guard turn.speaker == .learner,
                  let recast = turn.nativeRecast, !recast.isEmpty,
                  recast.lowercased() != turn.text.lowercased() else { return nil }
            return EnglishRecastPair(
                learnerSaid: turn.text,
                nativeVersion: recast,
                note: turn.grammarCorrection ?? ""
            )
        }

        let entry = EnglishStudyLogEntry(
            lessonID: lesson.id,
            dateKey: Self.todayDateKey(),
            lessonTitle: lesson.title,
            shadowingCompletedCount: lesson.completedDrillCount,
            averagePronunciationScore: lesson.averageDrillScore,
            spokenTurnCount: lesson.learnerTurnCount,
            recastPairs: Array(recasts.prefix(6)),
            newChunks: lesson.chunks.map(\.phrase),
            tutorSummary: tutorSummary
        )

        if let existingIdx = journalEntries.firstIndex(where: { $0.lessonID == lesson.id }) {
            journalEntries[existingIdx] = entry
        } else {
            journalEntries.insert(entry, at: 0)
        }
        save()
    }

    func updateTutorNotes(_ notes: String) {
        memory.tutorNotes = String(notes.prefix(600))
        save()
    }

    func snapshotForBackup() -> PersistedState? {
        guard hasCompletedOnboarding || activeLesson != nil || !journalEntries.isEmpty || !memory.weakWords.isEmpty else {
            return nil
        }
        return PersistedState(
            hasCompletedOnboarding: hasCompletedOnboarding,
            profile: profile,
            memory: memory,
            activeLesson: activeLesson,
            recentTopicTitles: recentTopicTitles,
            journalEntries: journalEntries
        )
    }

    func mergeImported(_ incoming: PersistedState) {
        if incoming.hasCompletedOnboarding && !hasCompletedOnboarding {
            profile = incoming.profile
            hasCompletedOnboarding = true
        }
        if activeLesson == nil, let lesson = incoming.activeLesson {
            activeLesson = lesson
        }
        for w in incoming.memory.weakWords where !memory.weakWords.contains(where: { $0.word.caseInsensitiveCompare(w.word) == .orderedSame }) {
            memory.weakWords.append(w)
        }
        for g in incoming.memory.grammarBlindspots where !memory.grammarBlindspots.contains(where: { $0.pattern.caseInsensitiveCompare(g.pattern) == .orderedSame }) {
            memory.grammarBlindspots.append(g)
        }
        for c in incoming.memory.masteredChunks where !memory.masteredChunks.contains(where: { $0.phrase.caseInsensitiveCompare(c.phrase) == .orderedSame }) {
            memory.masteredChunks.append(c)
        }
        if memory.tutorNotes.isEmpty && !incoming.memory.tutorNotes.isEmpty {
            memory.tutorNotes = incoming.memory.tutorNotes
        }
        let existingIDs = Set(journalEntries.map(\.id))
        let existingLessons = Set(journalEntries.map(\.lessonID))
        for log in incoming.journalEntries where !existingIDs.contains(log.id) && !existingLessons.contains(log.lessonID) {
            journalEntries.append(log)
        }
        journalEntries.sort { $0.createdAt > $1.createdAt }
        for title in incoming.recentTopicTitles where !recentTopicTitles.contains(title) {
            recentTopicTitles.append(title)
        }
        save()
    }

    func exportChunkToSM2Flashcard(_ chunk: EnglishLessonChunk) throws -> Bool {
        let deckName = String(localized: "英语私教 · 地道表达")
        let clozeSentence: String = {
            if let range = chunk.nativeExample.range(of: chunk.phrase, options: .caseInsensitive) {
                var copy = chunk.nativeExample
                copy.replaceSubrange(range, with: "______")
                return copy
            }
            return chunk.nativeExample
        }()
        let front = "\(chunk.meaningZh)\n\n\(clozeSentence)"
        let back = "\(chunk.phrase) \(chunk.phonetic)\n\n例句：\(chunk.nativeExample)\n（\(chunk.exampleZh)）\n\n用法提示：\(chunk.usageTip)"
        if FlashcardStore.shared.contains(front: front, deckName: deckName) {
            return false
        }
        try FlashcardStore.shared.addCard(
            deckName: deckName,
            front: front,
            back: back,
            hint: chunk.chinglishTrap
        )
        if let idx = memory.masteredChunks.firstIndex(where: { $0.phrase.lowercased() == chunk.phrase.lowercased() }) {
            memory.masteredChunks[idx].exportedToFlashcard = true
            save()
        }
        return true
    }
}
