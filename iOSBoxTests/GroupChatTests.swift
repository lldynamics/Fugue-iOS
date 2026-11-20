import XCTest
import SwiftData
@testable import iOSBox

private final class GroupRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LLMChatRequest] = []

    func append(_ request: LLMChatRequest) {
        lock.lock()
        defer { lock.unlock() }
        items.append(request)
    }

    var requests: [LLMChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@MainActor
final class GroupChatTests: XCTestCase {
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeLocalProvider() -> ProviderConfig {
        ProviderConfig(
            name: "Local Ollama",
            protocolType: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            iconSymbol: "desktopcomputer",
            accentHex: "#3F6EF6",
            isEnabled: true,
            models: [
                ModelSpec(id: "claude-sonnet", displayName: "Claude Sonnet"),
                ModelSpec(id: "deepseek-r1", displayName: "DeepSeek R1"),
                ModelSpec(id: "gemini-pro", displayName: "Gemini Pro")
            ]
        )
    }

    private func waitUntilIdle(_ engine: ChatEngine, conversationID: UUID, timeoutSeconds: Double = 5.0) async {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1000))
        while engine.isGenerating(in: conversationID) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testStreamSanitizerHoldsBackMetaTagAndStripsSelfPrefix() {
        var sanitizer = GroupStreamSanitizer(
            speakerName: "老王",
            speakerDisplayLabel: "毒舌架构师·老王"
        )

        let chunks = [
            "[毒舌架构师",
            "·老王]: ",
            "这个并发设计有硬伤，",
            "@沈总 你算算服务器成本？",
            " [[GROUP_",
            "META: next=@沈总 | intent=rebuttal | react=🤨]]"
        ]

        var streamedVisible = ""
        for chunk in chunks {
            let delta = sanitizer.ingest(chunk)
            XCTAssertFalse(delta.contains("GROUP_META"), "Hidden tail directive leaked during streaming: \(delta)")
            streamedVisible.append(delta)
        }

        let finalized = sanitizer.finalize()
        XCTAssertEqual(finalized.visibleText, "这个并发设计有硬伤，@沈总 你算算服务器成本？")
        XCTAssertFalse(streamedVisible.contains("[毒舌架构师·老王]"))
        XCTAssertFalse(finalized.directive.isPass)
        XCTAssertEqual(finalized.directive.nextTargetRaw, "@沈总")
        XCTAssertEqual(finalized.directive.suggestedIntent, .rebuttal)
        XCTAssertEqual(finalized.directive.reactionEmoji, "🤨")
    }

    func testStreamSanitizerDetectsSilentPass() {
        var sanitizer = GroupStreamSanitizer(speakerName: "沈总", speakerDisplayLabel: "早期投资人·沈总")
        let d1 = sanitizer.ingest("[PA")
        let d2 = sanitizer.ingest("SS]")
        XCTAssertEqual(d1 + d2, "")

        let finalized = sanitizer.finalize()
        XCTAssertTrue(finalized.directive.isPass)
        XCTAssertEqual(finalized.visibleText, "")
    }

    func testPerspectiveFlippedPromptHistoryMaintainsStrictAlternation() {
        let provider = makeLocalProvider()
        let targets = provider.enabledModels.map { provider.makeTarget(for: $0) }
        let lin = GroupMember(name: "林晓", title: "产品经理", avatarEmoji: "👩‍💼", rolePrompt: "产品视角", target: targets[0])
        let wang = GroupMember(name: "老王", title: "架构师", avatarEmoji: "🧑‍💻", rolePrompt: "技术视角", target: targets[1])

        let userMsg = ChatMessage(role: .user, content: "我们要不要上微服务？", sortIndex: 0)

        let linMsg = ChatMessage(role: .assistant, content: "业务还没跑通，先单体快上！", target: targets[0], sortIndex: 1)
        var linMeta = AssistanceMetadata()
        linMeta.groupMemberID = lin.id
        linMeta.groupMemberName = lin.name
        linMeta.groupMemberTitle = lin.title
        linMsg.assistanceMetadata = linMeta

        let wangMsg = ChatMessage(role: .assistant, content: "同意先单体，但模块边界要先划清。", target: targets[1], sortIndex: 2)
        var wangMeta = AssistanceMetadata()
        wangMeta.groupMemberID = wang.id
        wangMeta.groupMemberName = wang.name
        wangMeta.groupMemberTitle = wang.title
        wangMsg.assistanceMetadata = wangMeta

        let userFollowUp = ChatMessage(role: .user, content: "如果三个月后日活破十万呢？", sortIndex: 3)

        let historyForWang = GroupDiscussionCoordinator.buildPromptHistory(
            messages: [userMsg, linMsg, wangMsg, userFollowUp],
            for: wang,
            limit: 20
        )

        XCTAssertEqual(historyForWang.count, 3)
        XCTAssertEqual(historyForWang[0].role, .user)
        XCTAssertTrue(historyForWang[0].content.contains("[群主]: 我们要不要上微服务？"))
        XCTAssertTrue(historyForWang[0].content.contains("[产品经理·林晓]: 业务还没跑通"))

        XCTAssertEqual(historyForWang[1].role, .assistant)
        XCTAssertEqual(historyForWang[1].content, "同意先单体，但模块边界要先划清。")

        XCTAssertEqual(historyForWang[2].role, .user)
        XCTAssertTrue(historyForWang[2].content.contains("[群主]: 如果三个月后日活破十万呢？"))
    }

    func testSmartRelayHandoffSilentPassBurstSplitAndAskHostStop() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let provider = makeLocalProvider()
        context.insert(provider)

        let targets = provider.enabledModels.map { provider.makeTarget(for: $0) }
        let template = GroupRoomTemplate.builtInTemplates[0]
        let members = template.instantiate(using: targets)
        XCTAssertEqual(members.count, 3)

        let conv = Conversation(title: template.roomTitle, assistantEmoji: template.roomEmoji, primaryTarget: targets[0])
        var settings = AssistanceSettings()
        settings.isGroupMode = true
        settings.groupMembers = members
        settings.groupSpeakingMode = .smartRelay
        settings.groupSpeechStyle = .naturalShort
        settings.groupMaxRelayTurns = 3
        settings.groupSplitShortBubbles = true
        conv.assistanceSettings = settings
        context.insert(conv)
        try context.save()

        let capture = GroupRequestCapture()
        let engine = ChatEngine(stream: { req in
            capture.append(req)
            return AsyncThrowingStream { continuation in
                switch req.modelID {
                case "claude-sonnet":
                    continuation.yield(.contentDelta("先说直觉，这个点子切口很准！\n\n不过技术实现上有没有坑，@老王 你先给泼盆冷水？"))
                    continuation.yield(.contentDelta("[[GROUP_META: next=@老王 | intent=rebuttal | react=👍]]"))
                case "deepseek-r1":
                    // 老王 chooses to pass silently so fallback hands mic to 沈总
                    continuation.yield(.contentDelta("[PASS]"))
                default:
                    continuation.yield(.contentDelta("技术先不论，获客账算不过来。@群主 你们打算靠什么渠道冷启动？"))
                    continuation.yield(.contentDelta("[[GROUP_META: next=HOST | intent=probe | react=🤨]]"))
                }
                continuation.yield(.done)
                continuation.finish()
            }
        })

        let outcome = engine.sendUserMessage(
            text: "@林晓 我想做一个独立开发者记账小工具",
            attachments: [],
            in: conv,
            providers: [provider],
            context: context
        )
        XCTAssertEqual(outcome, .sent)
        await waitUntilIdle(engine, conversationID: conv.id)

        let active = ConversationTree.activeMessages(in: conv)
        // Expected: 1 user message + 2 split bubbles from 林晓 + (老王 passed, 0 bubbles) + 1 bubble from 沈总 = 4 messages
        XCTAssertEqual(active.count, 4)
        XCTAssertEqual(active[0].role, .user)
        XCTAssertEqual(active[0].assistanceMetadata.groupReactions.first?.emoji, "👍")

        XCTAssertEqual(active[1].assistanceMetadata.groupMemberName, "林晓")
        XCTAssertEqual(active[1].content, "先说直觉，这个点子切口很准！")
        XCTAssertEqual(active[2].assistanceMetadata.groupMemberName, "林晓")
        XCTAssertTrue(active[2].content.contains("@老王"))

        XCTAssertEqual(active[3].assistanceMetadata.groupMemberName, "沈总")
        XCTAssertTrue(active[3].assistanceMetadata.groupAskedHost)
        XCTAssertNotNil(active[3].assistanceMetadata.groupReplyToExcerpt)
    }

    func testGroupVoteSummaryAndBargeInInterruption() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let provider = makeLocalProvider()
        context.insert(provider)

        let targets = provider.enabledModels.map { provider.makeTarget(for: $0) }
        let members = Array(GroupRoomTemplate.builtInTemplates[1].instantiate(using: targets).prefix(2))

        let conv = Conversation(title: "红蓝辩论", assistantEmoji: "⚡", primaryTarget: targets[0])
        var settings = AssistanceSettings()
        settings.isGroupMode = true
        settings.groupMembers = members
        conv.assistanceSettings = settings
        context.insert(conv)

        let seedUser = ChatMessage(role: .user, content: "现在该不该全职独立开发？", sortIndex: 1)
        seedUser.conversation = conv
        conv.messages.append(seedUser)
        context.insert(seedUser)
        try context.save()

        let slowModeBox = LockedFlag()
        let engine = ChatEngine(stream: { req in
            AsyncThrowingStream { continuation in
                let task = Task {
                    if slowModeBox.isEnabled {
                        try? await Task.sleep(for: .seconds(10))
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                    }
                    if req.systemPrompt.contains("圆桌亮牌表决") {
                        continuation.yield(.contentDelta("【赞成】窗口期不等人，值得试半年。"))
                    } else if req.systemPrompt.contains("敲槌总结纪要") {
                        continuation.yield(.contentDelta("- 共识：先存够半年生活费\n- 分歧：全职还是副业起步"))
                    } else {
                        continuation.yield(.contentDelta("有了 12 个月存款那就可以冲了！ [[GROUP_META: next=NONE]]"))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        })

        // 1. Group Vote: both active members cast votes
        XCTAssertEqual(engine.startGroupVote(in: conv, providers: [provider], context: context), .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        let afterVote = ConversationTree.activeMessages(in: conv)
        let voteReplies = afterVote.filter { $0.assistanceMetadata.groupSpeechIntent == .vote }
        XCTAssertEqual(voteReplies.count, 2)

        // 2. Group Summary
        XCTAssertEqual(engine.summarizeGroupDiscussion(by: members[1], in: conv, providers: [provider], context: context), .sent)
        await waitUntilIdle(engine, conversationID: conv.id)
        let lastSummary = ConversationTree.activeMessages(in: conv).last
        XCTAssertEqual(lastSummary?.assistanceMetadata.groupSpeechIntent, .summarize)
        XCTAssertEqual(lastSummary?.assistanceMetadata.groupMemberID, members[1].id)

        // 3. Barge-In while a slow turn is in flight
        slowModeBox.set(true)
        XCTAssertEqual(engine.continueGroupDiscussion(in: conv, providers: [provider], context: context), .sent)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(engine.isGenerating(in: conv.id))

        slowModeBox.set(false)
        let bargeOutcome = await engine.bargeInGroupMessage(
            text: "补充一下：我已经存够了 12 个月生活费",
            attachments: [],
            in: conv,
            providers: [provider],
            context: context
        )
        XCTAssertEqual(bargeOutcome, .sent)
        await waitUntilIdle(engine, conversationID: conv.id)

        let finalMessages = ConversationTree.activeMessages(in: conv)
        XCTAssertFalse(finalMessages.contains(where: { $0.errorMessage != nil }), "Interrupted placeholder bubble should be cleaned up without error banner")
        XCTAssertTrue(finalMessages.contains(where: { $0.role == .user && $0.content.contains("12 个月生活费") }))
        XCTAssertTrue(finalMessages.last?.content.contains("12 个月存款") == true)
    }

    func testGroupSettingsAndMetadataBackupRoundTrip() throws {
        let provider = makeLocalProvider()
        let target = provider.makeTarget(for: provider.models[0])
        let member = GroupMember(name: "阿泽", title: "损友", avatarEmoji: "😼", accentHex: "#D9822B", rolePrompt: "犀利幽默", target: target, temperature: 0.9)

        let settings = AssistanceSettings(
            isGroupMode: true,
            groupMembers: [member],
            groupSpeakingMode: .roundRobin,
            groupSpeechStyle: .naturalShort,
            groupMaxRelayTurns: 4,
            groupSplitShortBubbles: false
        )
        let encodedSettings = try JSONEncoder().encode(settings)
        let decodedSettings = try JSONDecoder().decode(AssistanceSettings.self, from: encodedSettings)
        XCTAssertEqual(decodedSettings, settings)

        var meta = AssistanceMetadata()
        meta.groupMemberID = member.id
        meta.groupMemberName = member.name
        meta.groupMemberTitle = member.title
        meta.groupMemberEmoji = member.avatarEmoji
        meta.groupSpeechIntent = .rebuttal
        meta.groupReplyToSpeaker = "知夏"
        meta.groupReplyToExcerpt = "先照顾好自己的情绪"
        meta.groupReactions = [GroupReaction(memberID: UUID(), memberName: "方远", memberEmoji: "🧭", emoji: "👍")]
        meta.groupAskedHost = true

        let encodedMeta = try JSONEncoder().encode(meta)
        let decodedMeta = try JSONDecoder().decode(AssistanceMetadata.self, from: encodedMeta)
        XCTAssertEqual(decodedMeta.groupSpeakerDisplayTitle, "损友·阿泽")
        XCTAssertEqual(decodedMeta.groupSpeechIntent, .rebuttal)
        XCTAssertEqual(decodedMeta.groupReactions.count, 1)
        XCTAssertTrue(decodedMeta.groupAskedHost)
    }

    func testBracketColonChunkSplitAndHostMentionPunctuation() {
        // Chunk split right between closing `]` and `:`
        var sanitizer = GroupStreamSanitizer(speakerName: "老王", speakerDisplayLabel: "毒舌架构师·老王")
        let c1 = sanitizer.ingest("[毒舌架构师·老王]")
        XCTAssertEqual(c1, "", "Must hold until next char confirms whether ':' follows ']'")
        let c2 = sanitizer.ingest(": 这方案不行，@你，预算上限是多少？")
        let out = sanitizer.finalize()
        XCTAssertFalse((c1 + c2).contains("[毒舌架构师·老王]"))
        XCTAssertEqual(out.visibleText, "这方案不行，@你，预算上限是多少？")
        XCTAssertTrue(out.directive.asksHost, "@你 followed by Chinese comma + question mark must trigger asksHost")

        // Ensure `@你们` does NOT false-trigger asksHost
        XCTAssertFalse(GroupStreamSanitizer.detectsHostQuestion(in: "@你们两个觉得呢？"))
        XCTAssertTrue(GroupStreamSanitizer.detectsHostQuestion(in: "这点需要拍板，@你？"))
    }

    func testGroupContinuationPreservesPersonaPerspectiveAndStripsMetaTag() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let provider = makeLocalProvider()
        context.insert(provider)

        let targets = provider.enabledModels.map { provider.makeTarget(for: $0) }
        let lin = GroupMember(name: "林晓", title: "产品经理", avatarEmoji: "👩‍💼", rolePrompt: "关注用户体验", target: targets[0])
        let wang = GroupMember(name: "老王", title: "毒舌架构师", avatarEmoji: "🧑‍💻", rolePrompt: "关注高并发瓶颈", target: targets[1])

        let conv = Conversation(title: "续写测试群", primaryTarget: targets[0])
        var settings = AssistanceSettings()
        settings.isGroupMode = true
        settings.groupMembers = [lin, wang]
        conv.assistanceSettings = settings
        context.insert(conv)

        let uMsg = ChatMessage(role: .user, content: "聊聊缓存一致性", sortIndex: 1)
        let linMsg = ChatMessage(role: .assistant, content: "用户体验优先，允许短暂最终一致。", target: targets[0], sortIndex: 2)
        var linMeta = AssistanceMetadata()
        linMeta.groupMemberID = lin.id
        linMeta.groupMemberName = lin.name
        linMeta.groupMemberTitle = lin.title
        linMsg.assistanceMetadata = linMeta

        let wangMsg = ChatMessage(role: .assistant, content: "在库存扣减场景必须加分布式", target: targets[1], sortIndex: 3)
        wangMsg.finishReason = LLMFinishReason.length.rawValue
        var wangMeta = AssistanceMetadata()
        wangMeta.groupMemberID = wang.id
        wangMeta.groupMemberName = wang.name
        wangMeta.groupMemberTitle = wang.title
        wangMeta.groupMemberEmoji = wang.avatarEmoji
        wangMsg.assistanceMetadata = wangMeta

        for m in [uMsg, linMsg, wangMsg] {
            m.conversation = conv
            conv.messages.append(m)
            context.insert(m)
        }
        try context.save()

        let capture = GroupRequestCapture()
        let engine = ChatEngine(stream: { req in
            capture.append(req)
            return AsyncThrowingStream { continuation in
                continuation.yield(.contentDelta("锁与幂等键。 [[GROUP_META: next=NONE]]"))
                continuation.yield(.done)
                continuation.finish()
            }
        })

        engine.continueGeneration(assistantMessage: wangMsg, in: conv, providers: [provider], context: context)
        await waitUntilIdle(engine, conversationID: conv.id)

        let sentReq = try XCTUnwrap(capture.requests.first)
        XCTAssertTrue(sentReq.systemPrompt.contains("毒舌架构师·老王"), "Continuation must retain persona system prompt")
        XCTAssertTrue(sentReq.messages.first?.content.contains("[产品经理·林晓]") == true, "Peer message must stay perspective-flipped as user context")
        XCTAssertEqual(wangMsg.content, "在库存扣减场景必须加分布式锁与幂等键。")
    }

    func testSingleMemberFailureDoesNotSilenceRemainingHealthyGroupPeers() async throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let provider = makeLocalProvider()
        context.insert(provider)

        let targets = provider.enabledModels.map { provider.makeTarget(for: $0) }
        let members = GroupRoomTemplate.builtInTemplates[0].instantiate(using: targets)

        let conv = Conversation(title: "容错测试群", primaryTarget: targets[0])
        var settings = AssistanceSettings()
        settings.isGroupMode = true
        settings.groupMembers = members
        settings.groupSpeakingMode = .roundRobin
        settings.groupSplitShortBubbles = false
        conv.assistanceSettings = settings
        context.insert(conv)
        try context.save()

        let engine = ChatEngine(stream: { req in
            AsyncThrowingStream { continuation in
                if req.modelID == "deepseek-r1" {
                    continuation.finish(throwing: LLMError.httpError(500, "Upstream overloaded"))
                    return
                }
                continuation.yield(.contentDelta("来自 \(req.modelID) 的正常发言 [[GROUP_META: next=NONE]]"))
                continuation.yield(.done)
                continuation.finish()
            }
        })

        XCTAssertEqual(engine.sendUserMessage(text: "请大家依次发表看法", attachments: [], in: conv, providers: [provider], context: context), .sent)
        await waitUntilIdle(engine, conversationID: conv.id)

        let replies = ConversationTree.activeMessages(in: conv).filter { $0.role == .assistant }
        XCTAssertEqual(replies.count, 3, "All 3 round-robin seats should be attempted even when seat 2 fails")
        XCTAssertNotNil(replies[1].errorMessage)
        XCTAssertNil(replies[2].errorMessage)
        XCTAssertTrue(replies[2].content.contains("gemini-pro"))
    }

    func testGroupExportIncludesQuotesReactionsAndCapsLongShareCard() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let provider = makeLocalProvider()
        let target = provider.makeTarget(for: provider.models[0])

        let conv = Conversation(title: "导出测试群", assistantEmoji: "🚀", primaryTarget: target)
        conv.isGroupMode = true
        context.insert(conv)

        let uMsg = ChatMessage(role: .user, content: "帮我看看架构", sortIndex: 1)
        var uMeta = AssistanceMetadata()
        uMeta.groupReactions = [GroupReaction(memberID: UUID(), memberName: "沈总", memberEmoji: "🧐", emoji: "👍")]
        uMsg.assistanceMetadata = uMeta

        let longBody = String(repeating: "高并发架构细节验证。", count: 200)
        let aMsg = ChatMessage(role: .assistant, content: longBody, target: target, sortIndex: 2)
        var aMeta = AssistanceMetadata()
        aMeta.groupMemberID = UUID()
        aMeta.groupMemberName = "老王"
        aMeta.groupMemberTitle = "架构师"
        aMeta.groupMemberEmoji = "🧑‍💻"
        aMeta.groupReplyToSpeaker = "林晓"
        aMeta.groupReplyToExcerpt = "先上单体快速试错"
        aMeta.groupReactions = [GroupReaction(memberID: UUID(), memberName: "林晓", memberEmoji: "👩‍💼", emoji: "🔥")]
        aMsg.assistanceMetadata = aMeta

        for m in [uMsg, aMsg] {
            m.conversation = conv
            conv.messages.append(m)
            context.insert(m)
        }
        try context.save()

        let md = ConversationExporter.makeMarkdown(for: conv)
        XCTAssertTrue(md.contains("👍 沈总"))
        XCTAssertTrue(md.contains("回复 林晓：先上单体快速试错"))
        XCTAssertTrue(md.contains("🔥 林晓"))

        let image = ConversationExporter.renderShareImage(for: conv)
        XCTAssertNotNil(image)
    }

    func testBackupMergeSyncsNewerGroupSettingsAndReactionsOnExistingConversation() throws {
        let sourceContainer = try makeInMemoryContainer()
        let sourceCtx = sourceContainer.mainContext
        let targetContainer = try makeInMemoryContainer()
        let targetCtx = targetContainer.mainContext

        let provider = makeLocalProvider()
        sourceCtx.insert(provider)
        let modelTarget = provider.makeTarget(for: provider.models[0])

        let conv = Conversation(title: "初始群名", primaryTarget: modelTarget)
        let memberA = GroupMember(name: "林晓", title: "产品", rolePrompt: "P1", target: modelTarget)
        conv.isGroupMode = true
        conv.groupMembers = [memberA]
        sourceCtx.insert(conv)

        let msg = ChatMessage(role: .user, content: "第一句话", sortIndex: 1)
        msg.conversation = conv
        conv.messages.append(msg)
        sourceCtx.insert(msg)
        try sourceCtx.save()

        // First backup import into targetCtx
        let archiveData1 = try BackupService.encode(BackupService.makeArchive(context: sourceCtx))
        _ = try BackupService.apply(BackupService.decode(archiveData1), to: targetCtx)

        // Mutate group title, members, bookmark & reaction in sourceCtx without adding new message IDs
        let memberB = GroupMember(name: "老王", title: "架构", rolePrompt: "P2", target: modelTarget)
        conv.title = "升级后的圆桌群"
        conv.groupMembers = [memberA, memberB]
        conv.updatedAt = Date().addingTimeInterval(30)
        var meta = msg.assistanceMetadata
        meta.isBookmarked = true
        meta.groupReactions = [GroupReaction(memberID: memberB.id, memberName: "老王", memberEmoji: "🧑‍💻", emoji: "🤨")]
        msg.assistanceMetadata = meta
        try sourceCtx.save()

        let archiveData2 = try BackupService.encode(BackupService.makeArchive(context: sourceCtx))
        let summary2 = try BackupService.apply(BackupService.decode(archiveData2), to: targetCtx)
        XCTAssertEqual(summary2.restoredConversations, 1)

        let syncedConv = try XCTUnwrap(targetCtx.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(syncedConv.title, "升级后的圆桌群")
        XCTAssertEqual(syncedConv.groupMembers.count, 2)
        let syncedMsg = try XCTUnwrap(syncedConv.messages.first)
        XCTAssertTrue(syncedMsg.assistanceMetadata.isBookmarked)
        XCTAssertEqual(syncedMsg.assistanceMetadata.groupReactions.first?.emoji, "🤨")
    }

    func testDraftAutosaveGeminiThoughtSignatureReplayAndPersonaVoiceBucket() async throws {
        // 1. Debounced ChatDraftState autosave
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DraftAutosave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = ChatDraftStore(directory: tempDir)
        let convID = UUID()
        let state = store.state(for: convID)
        state.text = "防抖自动保存草稿内容"
        state.scheduleAutosave(delayMilliseconds: 60)
        try? await Task.sleep(for: .milliseconds(150))
        let reloaded = try store.load(convID)
        XCTAssertEqual(reloaded.text, "防抖自动保存草稿内容")

        // 2. Gemini thought block + signature replay on tool call turn
        let call = LLMToolCall(id: "c1", name: "web_search", argumentsJSON: #"{"query":"Swift 6"}"#, thoughtSignature: "sig-call")
        let req = LLMChatRequest(
            providerName: "Gemini",
            protocolType: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "k",
            customHeaders: [],
            modelID: "gemini-2.5-pro",
            supportsReasoning: true,
            systemPrompt: "",
            messages: [
                LLMPromptMessage(role: .user, content: "查一下 Swift 6"),
                LLMPromptMessage(
                    role: .assistant,
                    content: "",
                    reasoningContent: "先查文档",
                    thinkingBlocks: [LLMThinkingBlock(thinking: "先查文档", signature: "sig-thought")],
                    toolCalls: [call]
                ),
                LLMPromptMessage(role: .tool, content: #"{"ok":true}"#, toolCallID: "c1", toolName: "web_search")
            ],
            temperature: 0.5,
            topP: 1.0,
            maxOutputTokens: nil,
            enableThinking: true,
            thinkingBudgetTokens: 2048
        )
        let body = GeminiAdapter.buildRequestBody(req)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let modelParts = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
        XCTAssertEqual(modelParts.first?["thought"] as? Bool, true)
        XCTAssertEqual(modelParts.first?["thoughtSignature"] as? String, "sig-thought")

        // 3. Deterministic persona voice bucket
        let fixedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        XCTAssertEqual(SpeechService.personaVoiceBucket(for: fixedID), SpeechService.personaVoiceBucket(for: fixedID))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        enabled = value
    }
}
