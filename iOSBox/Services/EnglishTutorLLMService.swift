import Foundation
import SwiftData

enum EnglishTutorError: LocalizedError {
    case noReadyModel
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .noReadyModel:
            return String(localized: "尚未配置可用的 AI 模型，请先在设置或底部连接服务商。")
        case .invalidJSON:
            return String(localized: "模型返回的课程格式未能解析，请重试或切换其他模型。")
        }
    }
}

struct RoleplayExchangeResponse: Sendable {
    let tutorReply: String
    let tutorHintZh: String?
    let grammarCorrection: String?
    let nativeRecast: String?
    let blindspotPattern: String?
    let usedTargetPhrases: [String]
}

enum EnglishTutorLLMService {
    @MainActor
    static func resolveTutorTarget(
        preferredID: String?,
        providers: [ProviderConfig]
    ) -> (target: ResolvedModelTarget, provider: ProviderConfig, spec: ModelSpec)? {
        let readyProviders = providers.filter(\.isReadyForChat)
        let candidates: [(ResolvedModelTarget, ProviderConfig, ModelSpec)] = readyProviders.flatMap { provider in
            provider.enabledModels.map { spec in
                (provider.makeTarget(for: spec), provider, spec)
            }
        }
        guard !candidates.isEmpty else { return nil }
        if let preferredID, let hit = candidates.first(where: { $0.0.id == preferredID }) {
            return hit
        }
        if let defaultID = AppPreferences.shared.defaultTargetID,
           let hit = candidates.first(where: { $0.0.id == defaultID }) {
            return hit
        }
        return candidates.first
    }

    // MARK: - 1. Autonomous Daily Lesson Generation

    @MainActor
    static func generateDailyLesson(
        profile: EnglishLearnerProfile,
        memory: EnglishLearnerMemory,
        dayNumber: Int,
        recentTopics: [String],
        customDirective: String? = nil,
        target: ResolvedModelTarget,
        provider: ProviderConfig,
        spec: ModelSpec,
        context: ModelContext
    ) async throws -> EnglishDailyLesson {
        let sysPrompt = """
        You are an elite personal English acquisition coach designing a textbook-free, spiral-review daily micro-lesson for a Mandarin-speaking learner.
        Output ONLY valid JSON with no markdown fences and no extra commentary.
        JSON Schema:
        {
          "title": "Concise English scenario title (4-7 words)",
          "scenarioBrief": "1-2 sentences in Simplified Chinese describing today's vivid real-life scenario and why it matters",
          "tutorGreeting": "Natural opening line in English spoken by you in roleplay to kick off the scenario",
          "roleplayMission": "1 clear sentence in Simplified Chinese telling the learner their goal in the roleplay",
          "chunks": [
            {
              "phrase": "idiomatic English chunk or phrasal verb",
              "phonetic": "IPA transcription e.g. /.../",
              "meaningZh": "precise meaning in Simplified Chinese",
              "usageTip": "brief nuance & register tip in Simplified Chinese",
              "chinglishTrap": "common Chinglish mistake to avoid in Simplified Chinese",
              "nativeExample": "natural spoken English example sentence (8-16 words)",
              "exampleZh": "natural Chinese translation"
            }
          ],
          "drills": [
            {
              "sentence": "English shadowing sentence (8-18 words, naturally incorporating weak words or today's chunks)",
              "translationZh": "Simplified Chinese translation",
              "focusTip": "Specific linking, stress, or rhythm coaching tip in Simplified Chinese"
            }
          ]
        }
        Rules:
        - Produce 3 high-utility chunks and 4 progressive shadowing sentences (from shorter to natural conversational length).
        - Actively weave 1-2 of the learner's previous shadowing practice words or grammar blindspots into today's drills if natural.
        - Avoid repeating recent scenario topics listed by the user.
        """

        let difficultyNote: String = {
            if profile.difficultyAdjustment > 0 {
                return "Calibration: slightly MORE challenging than baseline (\(profile.difficultyAdjustment) step up)."
            } else if profile.difficultyAdjustment < 0 {
                return "Calibration: slightly EASIER and shorter sentences (\(abs(profile.difficultyAdjustment)) step down)."
            }
            return "Calibration: standard for the selected CEFR level."
        }()

        var userLines: [String] = [
            "Day #\(dayNumber) Autonomous Lesson Request",
            "Target Level: \(profile.level.promptDescriptor)",
            "Primary Goal: \(profile.goal.promptDescriptor)",
            "Preferred Accent: \(profile.accent.title)",
            "Daily Duration Budget: \(profile.dailyMinutes) minutes",
            difficultyNote
        ]
        if !profile.customInterest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userLines.append("Learner Personal Context / Interests: \(profile.customInterest)")
        }
        if !recentTopics.isEmpty {
            userLines.append("Recent topics to avoid duplicating: \(recentTopics.prefix(8).joined(separator: " | "))")
        }
        if let customDirective, !customDirective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userLines.append("Special request for today's lesson: \(customDirective)")
        }
        userLines.append("\nPersistent Learner Memory:\n\(memory.promptContextSummary())")

        let raw = try await runCompletion(
            systemPrompt: sysPrompt,
            messages: [LLMPromptMessage(role: .user, content: userLines.joined(separator: "\n"))],
            temperature: 0.65,
            maxTokens: 2400,
            target: target,
            provider: provider,
            spec: spec,
            context: context
        )
        return try parseLessonJSON(raw, dayNumber: dayNumber)
    }

    // MARK: - 2. Shadowing Pronunciation & Intonation Coaching

    @MainActor
    static func coachShadowingAttempt(
        drill: EnglishShadowingDrill,
        spokenTranscript: String,
        missedWords: [String],
        fuzzyWords: [String],
        accent: EnglishAccentPreference,
        target: ResolvedModelTarget,
        provider: ProviderConfig,
        spec: ModelSpec,
        context: ModelContext
    ) async throws -> String {
        let sysPrompt = """
        根据标准句与转写文本，用简体中文指出有差异的词，并给出可选的复读、拆词或重音练习。转写可能存在识别误差。没有音频，无法判断学习者实际的口型、音素、音准和节奏。最多 3 条短建议，共 140 字以内。
        """
        let userPrompt = """
        目标口音：\(accent.title)
        标准原句：\(drill.sentence)
        识别结果：\(spokenTranscript.isEmpty ? "（未识别出清晰单词）" : spokenTranscript)
        未匹配词：\(missedWords.isEmpty ? "无" : missedWords.joined(separator: ", "))
        部分匹配词：\(fuzzyWords.isEmpty ? "无" : fuzzyWords.joined(separator: ", "))
        """
        let reply = try await runCompletion(
            systemPrompt: sysPrompt,
            messages: [LLMPromptMessage(role: .user, content: userPrompt)],
            temperature: 0.4,
            maxTokens: 512,
            target: target,
            provider: provider,
            spec: spec,
            context: context
        )
        return PlainTextFormatter.format(reply).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 3. Live Roleplay Reply with Silent Native Recast

    @MainActor
    static func replyInRoleplay(
        lesson: EnglishDailyLesson,
        profile: EnglishLearnerProfile,
        memory: EnglishLearnerMemory,
        learnerUtterance: String,
        target: ResolvedModelTarget,
        provider: ProviderConfig,
        spec: ModelSpec,
        context: ModelContext
    ) async throws -> RoleplayExchangeResponse {
        let targetPhraseList = lesson.chunks.map(\.phrase).joined(separator: ", ")
        let sysPrompt = """
        You are an engaging English roleplay partner and silent language coach.
        Scenario: \(lesson.title) — \(lesson.scenarioBrief)
        Learner Level: \(profile.level.promptDescriptor)
        Target expressions for today: [\(targetPhraseList)]
        Learner Memory:
        \(memory.promptContextSummary())

        Respond ONLY with valid JSON (no markdown fences):
        {
          "tutorReply": "Your natural in-character English reply (1-3 sentences, end with a natural follow-up question to keep the conversation flowing)",
          "tutorHintZh": "Brief Simplified Chinese translation or reply idea hint",
          "grammarCorrection": "Concise Simplified Chinese note if the learner's English had grammar/wording issues; empty string if already natural",
          "nativeRecast": "How a native speaker would naturally say the learner's exact thought in this context; empty string if learner's sentence was already idiomatic",
          "blindspotPattern": "Short Chinese tag (e.g. '过去时遗漏' / 'follow up 漏介词 on') ONLY if a clear grammar/Chinglish mistake occurred; otherwise empty string",
          "usedTargetPhrases": ["exact phrases from target list that the learner successfully used in this turn"]
        }
        """

        var history: [LLMPromptMessage] = []
        for turn in lesson.roleplayTurns.suffix(10) {
            history.append(LLMPromptMessage(
                role: turn.speaker == .tutor ? .assistant : .user,
                content: turn.text
            ))
        }
        history.append(LLMPromptMessage(role: .user, content: learnerUtterance))

        let raw = try await runCompletion(
            systemPrompt: sysPrompt,
            messages: history,
            temperature: 0.55,
            maxTokens: 900,
            target: target,
            provider: provider,
            spec: spec,
            context: context
        )
        return try parseRoleplayJSON(raw)
    }

    // MARK: - 4. Session Wrap-Up & Persistent Memory Consolidation

    @MainActor
    static func summarizeLessonForJournal(
        lesson: EnglishDailyLesson,
        profile: EnglishLearnerProfile,
        memory: EnglishLearnerMemory,
        target: ResolvedModelTarget,
        provider: ProviderConfig,
        spec: ModelSpec,
        context: ModelContext
    ) async throws -> (tutorSummary: String, updatedTutorNotes: String) {
        let sysPrompt = """
        你是学习者的私人英语教练。请根据今天微课的文本匹配度与实战对话表现，输出 JSON（不含代码块标记）：
        {
          "tutorSummary": "用温暖具体的简体中文写一段今日学习日志点评（60-120字），肯定亮点并指出1个明天可留意的小细节",
          "updatedTutorNotes": "结合旧学情备注与今日表现，更新供AI外教下次备课参考的精炼学情画像（简体中文，不超过160字）"
        }
        """

        let turnDigest = lesson.roleplayTurns.map { turn -> String in
            let prefix = turn.speaker == .tutor ? "Tutor" : "Learner"
            let fix = turn.nativeRecast.map { " [Recast: \($0)]" } ?? ""
            return "\(prefix): \(turn.text)\(fix)"
        }.joined(separator: "\n")

        let userPrompt = """
        今日主题：\(lesson.title)
        跟读完成：\(lesson.completedDrillCount)/\(lesson.drills.count)，平均文本匹配度（百分比）：\(lesson.averageDrillScore.map(String.init) ?? "未测")
        已激活目标短语：\(lesson.activatedPhrases.joined(separator: ", "))
        原有学情备注：\(memory.tutorNotes)
        对话记录：
        \(turnDigest)
        """

        let raw = try await runCompletion(
            systemPrompt: sysPrompt,
            messages: [LLMPromptMessage(role: .user, content: userPrompt)],
            temperature: 0.4,
            maxTokens: 700,
            target: target,
            provider: provider,
            spec: spec,
            context: context
        )
        let cleaned = extractJSONObject(from: raw)
        if let data = cleaned.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let summary = ((dict["tutorSummary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = ((dict["updatedTutorNotes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                return (summary, notes)
            }
        }
        return (
            String(localized: "完成了《\(lesson.title)》微课训练，继续保持开口节奏！"),
            memory.tutorNotes
        )
    }

    // MARK: - Core Completion & Parsers

    @MainActor
    private static func runCompletion(
        systemPrompt: String,
        messages: [LLMPromptMessage],
        temperature: Double,
        maxTokens: Int,
        target: ResolvedModelTarget,
        provider: ProviderConfig,
        spec: ModelSpec,
        context: ModelContext
    ) async throws -> String {
        let apiKey = provider.apiKey
        let isLocal = NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)
        if !provider.hasAuthentication && !isLocal {
            throw LLMError.missingAPIKey(provider.name)
        }
        let validateTarget = provider.transmissionCheck(for: target.modelID)

        var request = LLMChatRequest(
            providerName: provider.name,
            protocolType: provider.protocolType,
            baseURL: provider.baseURL,
            apiKey: apiKey,
            apiKeys: provider.extraAPIKeys,
            customHeaders: provider.resolvedCustomHeaders,
            modelID: target.modelID,
            supportsReasoning: spec.supportsReasoning,
            systemPrompt: systemPrompt,
            messages: messages,
            temperature: temperature,
            topP: 1.0,
            maxOutputTokens: maxTokens,
            enableThinking: false,
            thinkingBudgetTokens: 1024,
            idleTimeoutSeconds: provider.customIdleTimeout
        )
        request.validateBeforeSending = {
            try validateTarget()
        }

        var start = ContinuousClock.now
        var record = RequestRecord(
            target: target,
            spec: spec,
            conversationID: UUID(),
            messageID: UUID(),
            kind: .studyGeneration
        )
        context.insert(record)

        var collected = ""
        do {
            for try await event in LLMClient.streamChat(request) {
                let elapsed = Int(start.duration(to: .now).components.seconds * 1000)
                    + Int(start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
                if case .retrying(let status) = event {
                    record = record.startRetry(
                        after: status,
                        elapsedMs: max(1, elapsed),
                        target: target,
                        spec: spec,
                        in: context
                    )
                    collected = ""
                    start = .now
                    continue
                }
                record.observe(event, elapsedMs: max(0, elapsed))
                if case .contentDelta(let delta) = event {
                    collected += delta
                }
            }
            let totalMs = max(1, Int(start.duration(to: .now).components.seconds * 1000)
                + Int(start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000))
            record.finish(.succeeded, elapsedMs: totalMs)
            try? context.save()
            return collected
        } catch {
            let totalMs = max(1, Int(start.duration(to: .now).components.seconds * 1000)
                + Int(start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000))
            if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                record.finish(.cancelled, elapsedMs: totalMs)
            } else {
                if case LLMError.httpError(let status, _) = error {
                    record.httpStatus = status
                }
                record.finish(.failed, elapsedMs: totalMs)
            }
            try? context.save()
            throw error
        }
    }

    static func parseLessonJSON(_ raw: String, dayNumber: Int) throws -> EnglishDailyLesson {
        let cleaned = extractJSONObject(from: raw)
        guard let data = cleaned.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnglishTutorError.invalidJSON
        }

        let title = ((dict["title"] as? String) ?? "Daily English Practice").trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = ((dict["scenarioBrief"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let greeting = ((dict["tutorGreeting"] as? String) ?? "Hi! Ready to practice today's scenario together?").trimmingCharacters(in: .whitespacesAndNewlines)
        let mission = ((dict["roleplayMission"] as? String) ?? String(localized: "围绕今日场景自然交流，尝试用出今天学到的地道表达。")).trimmingCharacters(in: .whitespacesAndNewlines)

        let rawChunks = (dict["chunks"] as? [[String: Any]]) ?? []
        let chunks: [EnglishLessonChunk] = rawChunks.prefix(5).compactMap { item in
            let phrase = ((item["phrase"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = ((item["meaningZh"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, !meaning.isEmpty else { return nil }
            return EnglishLessonChunk(
                phrase: phrase,
                phonetic: ((item["phonetic"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                meaningZh: meaning,
                usageTip: ((item["usageTip"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                chinglishTrap: ((item["chinglishTrap"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                nativeExample: ((item["nativeExample"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                exampleZh: ((item["exampleZh"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let rawDrills = (dict["drills"] as? [[String: Any]]) ?? []
        let drills: [EnglishShadowingDrill] = rawDrills.prefix(6).compactMap { item in
            let sentence = ((item["sentence"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return nil }
            return EnglishShadowingDrill(
                sentence: sentence,
                translationZh: ((item["translationZh"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                focusTip: ((item["focusTip"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard !chunks.isEmpty || !drills.isEmpty else {
            throw EnglishTutorError.invalidJSON
        }

        return EnglishDailyLesson(
            dateKey: EnglishCoachStore.todayDateKey(),
            dayNumber: dayNumber,
            title: title,
            scenarioBrief: brief,
            tutorGreeting: greeting,
            roleplayMission: mission,
            chunks: chunks,
            drills: drills
        )
    }

    static func parseRoleplayJSON(_ raw: String) throws -> RoleplayExchangeResponse {
        let cleaned = extractJSONObject(from: raw)
        if let data = cleaned.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let reply = (dict["tutorReply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reply.isEmpty {
            let hint = (dict["tutorHintZh"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let corr = (dict["grammarCorrection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recast = (dict["nativeRecast"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = (dict["blindspotPattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let used = (dict["usedTargetPhrases"] as? [String]) ?? []
            return RoleplayExchangeResponse(
                tutorReply: reply,
                tutorHintZh: hint,
                grammarCorrection: corr,
                nativeRecast: recast,
                blindspotPattern: pattern,
                usedTargetPhrases: used
            )
        }
        // Fallback if a model replies in plain English without JSON
        let fallbackReply = PlainTextFormatter.format(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackReply.isEmpty else { throw EnglishTutorError.invalidJSON }
        return RoleplayExchangeResponse(
            tutorReply: fallbackReply,
            tutorHintZh: nil,
            grammarCorrection: nil,
            nativeRecast: nil,
            blindspotPattern: nil,
            usedTargetPhrases: []
        )
    }

    private static func extractJSONObject(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let thinkRegex = try? NSRegularExpression(pattern: #"(?is)<think>.*?</think>"#) {
            text = thinkRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let fenceRegex = try? NSRegularExpression(pattern: #"(?is)```(?:json)?\s*(\{.*\})\s*```"#),
           let match = fenceRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        if let first = text.firstIndex(of: "{"),
           let last = text.lastIndex(of: "}"),
           last > first {
            return String(text[first...last])
        }
        return text
    }
}
