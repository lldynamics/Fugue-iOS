import Foundation

// MARK: - Learner Profile & Preferences

enum EnglishProficiencyLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case a2
    case b1
    case b2
    case c1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a2: return String(localized: "A2 · 基础开口")
        case .b1: return String(localized: "B1 · 日常交流")
        case .b2: return String(localized: "B2 · 职场进阶")
        case .c1: return String(localized: "C1 · 母语地道")
        }
    }

    var subtitle: String {
        switch self {
        case .a2: return String(localized: "能说简单短句，希望克服开口紧张、积累高频生活表达")
        case .b1: return String(localized: "能应付日常话题，但连贯度不足、时态与介词容易出错")
        case .b2: return String(localized: "能阅读英文资料与开会，希望告别中式英语、表达更自然得体")
        case .c1: return String(localized: "追求母语级词汇张力、微妙语气拿捏与高阶演讲思辨")
        }
    }

    var promptDescriptor: String {
        switch self {
        case .a2: return "CEFR A2 (Elementary: use clear, high-frequency everyday vocabulary and short natural sentences)"
        case .b1: return "CEFR B1 (Intermediate: everyday & workplace fluency, phrasal verbs, natural linking)"
        case .b2: return "CEFR B2 (Upper-Intermediate: nuanced professional & social idioms, eliminating Chinglish)"
        case .c1: return "CEFR C1 (Advanced: idiomatic precision, subtle register control, executive/native articulation)"
        }
    }
}

enum EnglishLearningGoal: String, Codable, CaseIterable, Identifiable, Sendable {
    case dailyLife
    case techAndWork
    case jobInterview
    case travelAbroad
    case speakingExam

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dailyLife: return String(localized: "日常闲聊与社交")
        case .techAndWork: return String(localized: "外企协作与技术沟通")
        case .jobInterview: return String(localized: "英文面试与职业发展")
        case .travelAbroad: return String(localized: "海外差旅与生活实景")
        case .speakingExam: return String(localized: "雅思 / 托福口语思辨")
        }
    }

    var icon: String {
        switch self {
        case .dailyLife: return "cup.and.saucer.fill"
        case .techAndWork: return "laptopcomputer"
        case .jobInterview: return "person.text.rectangle.fill"
        case .travelAbroad: return "airplane"
        case .speakingExam: return "graduationcap.fill"
        }
    }

    var promptDescriptor: String {
        switch self {
        case .dailyLife: return "Casual social conversation, small talk, expressing opinions and feelings naturally"
        case .techAndWork: return "Global software/product team collaboration, standups, code/design reviews, async updates"
        case .jobInterview: return "Behavioral (STAR) and technical interviews, salary negotiation, career storytelling"
        case .travelAbroad: return "Airports, hotels, dining, medical/emergency situations, local cultural chatting"
        case .speakingExam: return "IELTS/TOEFL speaking parts 1-3, structured impromptu reasoning, rich lexical resource"
        }
    }
}

enum EnglishAccentPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case us = "en-US"
    case uk = "en-GB"

    var id: String { rawValue }
    var localeIdentifier: String { rawValue }

    var title: String {
        switch self {
        case .us: return String(localized: "美式发音 (US)")
        case .uk: return String(localized: "英式发音 (UK)")
        }
    }
}

struct EnglishLearnerProfile: Codable, Equatable, Sendable {
    var level: EnglishProficiencyLevel = .b1
    var goal: EnglishLearningGoal = .techAndWork
    var accent: EnglishAccentPreference = .us
    var dailyMinutes: Int = 15
    var customInterest: String = ""
    var preferredTargetID: String? = nil
    var difficultyAdjustment: Int = 0
}

// MARK: - Persistent Learner Memory

struct EnglishWeakWordItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var word: String
    var heardAs: [String] = []
    var missCount: Int = 1
    var lastMissedAt: Date = Date()
}

struct EnglishGrammarBlindspot: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var pattern: String
    var userExample: String
    var nativeFix: String
    var occurrences: Int = 1
    var updatedAt: Date = Date()
}

struct EnglishMasteredChunk: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var phrase: String
    var phonetic: String
    var meaningZh: String
    var sampleSentence: String
    var masteredAt: Date = Date()
    var exportedToFlashcard: Bool = false
}

struct EnglishLearnerMemory: Codable, Equatable, Sendable {
    var weakWords: [EnglishWeakWordItem] = []
    var grammarBlindspots: [EnglishGrammarBlindspot] = []
    var masteredChunks: [EnglishMasteredChunk] = []
    var tutorNotes: String = ""

    func promptContextSummary() -> String {
        var sections: [String] = []
        if !weakWords.isEmpty {
            let topWords = weakWords
                .sorted { ($0.missCount, $0.lastMissedAt) > ($1.missCount, $1.lastMissedAt) }
                .prefix(8)
                .map { item in
                    let heard = item.heardAs.isEmpty ? "" : " (misheard as: \(item.heardAs.prefix(2).joined(separator: "/")))"
                    return "\(item.word) [x\(item.missCount)]\(heard)"
                }
            sections.append("Pronunciation weak words to recycle: " + topWords.joined(separator: ", "))
        }
        if !grammarBlindspots.isEmpty {
            let topSpots = grammarBlindspots
                .sorted { ($0.occurrences, $0.updatedAt) > ($1.occurrences, $1.updatedAt) }
                .prefix(6)
                .map { "\($0.pattern) (e.g. \"\($0.userExample)\" -> \"\($0.nativeFix)\")" }
            sections.append("Recurring grammar/Chinglish blindspots: " + topSpots.joined(separator: "; "))
        }
        if !masteredChunks.isEmpty {
            let recent = masteredChunks.prefix(10).map(\.phrase)
            sections.append("Recently learned expressions (spiral review occasionally, avoid exact duplicate lessons): " + recent.joined(separator: ", "))
        }
        if !tutorNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Long-term tutor observations: " + tutorNotes)
        }
        return sections.isEmpty
            ? "New learner (no prior mistakes recorded yet). Establish an encouraging baseline."
            : sections.joined(separator: "\n")
    }
}

// MARK: - Autonomous Daily Lesson & Drills

struct EnglishLessonChunk: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var phrase: String
    var phonetic: String
    var meaningZh: String
    var usageTip: String
    var chinglishTrap: String
    var nativeExample: String
    var exampleZh: String
}

struct EnglishShadowingDrill: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var sentence: String
    var translationZh: String
    var focusTip: String
    var bestScore: Int? = nil
    var lastSpokenTranscript: String? = nil
    var lastEvaluationTokens: [ShadowingWordResult]? = nil
    var aiCoachFeedback: String? = nil
}

enum ShadowingWordState: String, Codable, Equatable, Sendable {
    case accurate
    case fuzzy
    case missed
}

struct ShadowingWordResult: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var expectedWord: String
    var state: ShadowingWordState
    var heardWord: String? = nil
}

struct EnglishRoleplayTurn: Codable, Identifiable, Equatable, Sendable {
    enum Speaker: String, Codable, Sendable {
        case tutor
        case learner
    }

    var id: UUID = UUID()
    var speaker: Speaker
    var text: String
    var hintZh: String? = nil
    var grammarCorrection: String? = nil
    var nativeRecast: String? = nil
    var blindspotPattern: String? = nil
    var usedTargetPhrases: [String] = []
    var createdAt: Date = Date()
}

struct EnglishDailyLesson: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var dateKey: String
    var dayNumber: Int
    var title: String
    var scenarioBrief: String
    var tutorGreeting: String
    var roleplayMission: String
    var chunks: [EnglishLessonChunk]
    var drills: [EnglishShadowingDrill]
    var roleplayTurns: [EnglishRoleplayTurn] = []
    var activatedPhrases: [String] = []
    var isCompleted: Bool = false
    var createdAt: Date = Date()

    var completedDrillCount: Int {
        drills.filter { $0.bestScore != nil }.count
    }

    var averageDrillScore: Int? {
        let scores = drills.compactMap(\.bestScore)
        guard !scores.isEmpty else { return nil }
        return Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
    }

    var learnerTurnCount: Int {
        roleplayTurns.filter { $0.speaker == .learner }.count
    }
}

// MARK: - Study Journal Log

struct EnglishRecastPair: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var learnerSaid: String
    var nativeVersion: String
    var note: String
}

struct EnglishStudyLogEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var lessonID: UUID
    var dateKey: String
    var createdAt: Date = Date()
    var lessonTitle: String
    var shadowingCompletedCount: Int
    var averagePronunciationScore: Int?
    var spokenTurnCount: Int
    var recastPairs: [EnglishRecastPair]
    var newChunks: [String]
    var tutorSummary: String
}
