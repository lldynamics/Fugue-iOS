import Foundation
import SwiftData
import Testing
@testable import iOSBox

private final class FriendMemoryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [LLMChatRequest] = []

    func record(_ request: LLMChatRequest) {
        lock.lock()
        defer { lock.unlock() }
        captured.append(request)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        captured.removeAll()
    }

    var requests: [LLMChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}

@Suite("Friend Persistent Memory Regression Tests", .serialized)
@MainActor
struct FriendPersistentMemoryTests {
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeLocalProvider(id: UUID = UUID(), name: String = "LocalA", modelID: String = "model-a") -> ProviderConfig {
        var spec = ModelSpec(id: modelID, displayName: name, supportsVision: false)
        spec.inputPricePerMillion = 1.0
        spec.outputPricePerMillion = 4.0
        spec.priceCurrency = "USD"
        return ProviderConfig(
            id: id,
            name: name,
            protocolType: .openAICompatible,
            baseURL: "http://127.0.0.1:11434/v1",
            isEnabled: true,
            models: [spec]
        )
    }

    private func waitUntilIdle(_ engine: ChatEngine, conversationID: UUID) async {
        while let generation = engine.activeGenerations[conversationID] { await generation.task.value }
        for task in Array(engine.activeFriendMemoryTasks.values) { await task.value }
    }

    @Test("FriendMemoryStore enforces 25-entry cap, obsolete replacement, and BookFriend chapter spoiler boundaries")
    func storeCapacityObsoleteReplacementAndSpoilerGating() throws {
        let store = FriendMemoryStore(fileURL: nil, notifySyncChanges: false)
        let bookID = UUID()

        let ch2Scope = FriendMemorySubject.bookFriend(
            BookFriend(bookID: bookID, bookTitle: "山路手记", name: "林知夏", aliases: [], throughChapter: 1)
        )
        let ch8Scope = FriendMemorySubject.bookFriend(
            BookFriend(bookID: bookID, bookTitle: "山路手记", name: "林知夏", aliases: [], throughChapter: 7)
        )
        let fullBookScope = FriendMemorySubject.bookFriend(
            BookFriend(bookID: bookID, bookTitle: "山路手记", name: "林知夏", aliases: [], throughChapter: nil)
        )

        #expect(ch2Scope.friendKey == ch8Scope.friendKey)
        #expect(ch8Scope.friendKey == fullBookScope.friendKey)

        // 1. Add early-chapter memory (throughChapter = 1)
        _ = store.applyExtraction(
            .init(
                relationshipSummary: "刚在村口相识，聊起雨后巡山的习惯。",
                upsertMemories: ["用户正在写一份田野调查手记", "约定下周对比东岸水痕记录"],
                obsoleteMemories: nil
            ),
            for: ch2Scope
        )

        // 2. Advance to chapter 8 (throughChapter = 7): supersede old item and add late-chapter spoiler item
        _ = store.applyExtraction(
            .init(
                relationshipSummary: "已读到后半程，深入讨论了谷底石碑的来历。",
                upsertMemories: ["已完成东岸水痕核对并拍照归档", "一起复盘了第八章石碑铭文的暗线"],
                obsoleteMemories: ["约定下周对比东岸水痕记录"]
            ),
            for: ch8Scope
        )

        // At chapter 8: summary + 3 active memories visible ("约定下周..." was replaced)
        let ch8Visible = store.visibleEntries(for: ch8Scope, includeDisabled: false).map(\.content)
        #expect(ch8Visible.count == 3)
        #expect(!ch8Visible.contains("约定下周对比东岸水痕记录"))
        #expect(ch8Visible.contains("一起复盘了第八章石碑铭文的暗线"))
        #expect(store.visibleSummary(for: ch8Scope)?.contains("谷底石碑") == true)

        // Rewind to chapter 2 (throughChapter = 1): late-chapter memories & summary MUST be hidden (zero spoilers!)
        let ch2RewoundPrompt = try #require(store.promptBlock(for: ch2Scope))
        #expect(ch2RewoundPrompt.text.contains("用户正在写一份田野调查手记"))
        #expect(!ch2RewoundPrompt.text.contains("第八章石碑铭文"))
        #expect(!ch2RewoundPrompt.text.contains("谷底石碑"))
        #expect(store.hiddenFutureEntryCount(for: ch2Scope) == 2)

        // Full-book scope sees all 3 entries
        #expect(store.visibleEntries(for: fullBookScope).count == 3)

        // 3. Enforce 25-entry maximum cap
        let persona = FriendMemorySubject.persona(profileID: UUID(), name: "苏格拉底", emoji: "🏛️")
        for i in 1...30 {
            _ = store.addEntry("记忆条目 #\(i)", for: persona, now: Date().addingTimeInterval(Double(i)))
        }
        #expect(store.record(for: persona).entries.count == FriendMemoryStore.maximumEntriesPerFriend)
        #expect(store.record(for: persona).entries.first?.content == "记忆条目 #30")
    }

    @Test("Private Persona chat auto-extracts memory into ledger and shares bidirectionally with Group Relay without leaking across providers")
    func bidirectionalPrivateAndGroupSharingWithProviderIsolation() async throws {
        let container = try makeInMemoryContainer()
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let store = FriendMemoryStore(fileURL: nil, notifySyncChanges: false)

        let providerA = makeLocalProvider(name: "ProviderA", modelID: "friend-a-model")
        let providerB = makeLocalProvider(name: "ProviderB", modelID: "bystander-b-model")
        context.insert(providerA)
        context.insert(providerB)

        let targetA = providerA.makeTarget(for: providerA.models[0])
        let targetB = providerB.makeTarget(for: providerB.models[0])

        let draftProfile = GroupMember(
            name: "林清远",
            title: "建筑师好友",
            avatarEmoji: "🏛️",
            rolePrompt: "温和务实的建筑师。",
            target: targetA
        )
        let savedProfile = try PersonaLibrary.save(draftProfile, in: context)
        let privateChat = try PersonaLibrary.privateChat(with: savedProfile, in: context)

        let recorder = FriendMemoryRequestRecorder()
        let engine = ChatEngine { req in
            recorder.record(req)
            return AsyncThrowingStream { cont in
                if req.systemPrompt.contains("专属持续记忆") || req.systemPrompt.contains("persistent relationship memory") {
                    if req.messages.first?.content.contains("改造老宅天窗") == true {
                        cont.yield(.contentDelta(#"{"relationship_summary":"正在陪用户规划江南老宅采光改造，气氛默契。","upsert_memories":["用户计划秋天改造江南老宅的北向天窗"],"obsolete_memories":[]}"#))
                    } else if req.messages.first?.content.contains("木构榫卯预算") == true {
                        cont.yield(.contentDelta(#"{"relationship_summary":"已从老宅采光推进到木构预算细节。","upsert_memories":["群聊确认老宅木构修缮预算控制在十五万以内"],"obsolete_memories":[]}"#))
                    } else {
                        cont.yield(.contentDelta(#"{"relationship_summary":"","upsert_memories":[],"obsolete_memories":[]}"#))
                    }
                    cont.yield(.usage(promptTokens: 80, completionTokens: 30))
                } else {
                    cont.yield(.contentDelta("好的，这点我记下了。"))
                    cont.yield(.usage(promptTokens: 50, completionTokens: 15))
                }
                cont.yield(.done)
                cont.finish()
            }
        }
        engine.friendMemoryStore = store

        // 1. Two exchanges (4 relevant messages) in 1-on-1 private chat trigger automatic background memory extraction
        #expect(engine.sendUserMessage(text: "你好，最近我想聊聊江南老宅修缮。", attachments: [], in: privateChat, providers: [providerA, providerB], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: privateChat.id)
        #expect(engine.sendUserMessage(text: "我打算今年秋天先改造老宅天窗。", attachments: [], in: privateChat, providers: [providerA, providerB], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: privateChat.id)

        let subject = FriendMemorySubject.persona(savedProfile)
        let entriesAfterPrivate = store.visibleEntries(for: subject, includeDisabled: false)
        #expect(entriesAfterPrivate.contains { $0.content.contains("秋天改造江南老宅的北向天窗") })

        // Verify extraction logged a RequestRecord in RequestLedger
        let allRecords = try context.fetch(FetchDescriptor<RequestRecord>())
        #expect(allRecords.contains { $0.kind == .synthesis && $0.status == .succeeded && $0.promptTokens == 80 })

        // 2. Invite Friend A into a Roundtable Group Chat alongside Bystander B (bound to ProviderB)
        let bystander = GroupMember(
            name: "老周",
            title: "结构顾问",
            avatarEmoji: "🧱",
            rolePrompt: "专注承重核算。",
            target: targetB
        )
        let groupChat = Conversation(title: "老宅改造圆桌", primaryTarget: targetA)
        groupChat.isGroupMode = true
        groupChat.groupMembers = [ try savedProfile.member().inRoom(), bystander ]
        var gs = groupChat.assistanceSettings
        gs.groupSpeakingMode = .roundRobin
        gs.groupMaxRelayTurns = 2
        groupChat.assistanceSettings = gs
        context.insert(groupChat)
        try context.save()

        recorder.reset()
        #expect(engine.sendUserMessage(text: "大家怎么看天窗施工？", attachments: [], in: groupChat, providers: [providerA, providerB], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: groupChat.id)

        let chatRequests = recorder.requests.filter { !$0.systemPrompt.contains("仅输出合法 JSON") }
        let friendARequest = try #require(chatRequests.first { $0.modelID == "friend-a-model" })
        let bystanderBRequest = try #require(chatRequests.first { $0.modelID == "bystander-b-model" })

        // Friend A receives their shared memory in group chat; Bystander B (ProviderB) NEVER sees Friend A's private memory!
        #expect(friendARequest.systemPrompt.contains("秋天改造江南老宅的北向天窗"))
        #expect(!bystanderBRequest.systemPrompt.contains("秋天改造江南老宅的北向天窗"))

        // Second group round reaches 4 relevant messages for Friend A -> group dialogue updates Friend A's memory back!
        #expect(engine.sendUserMessage(text: "另外木构榫卯预算我想控制在十五万以内。", attachments: [], in: groupChat, providers: [providerA, providerB], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: groupChat.id)

        let entriesAfterGroup = store.visibleEntries(for: subject, includeDisabled: false)
        #expect(entriesAfterGroup.contains { $0.content.contains("十五万以内") })

        // Back in 1-on-1 private chat, Friend A immediately knows the budget agreed in the group chat!
        recorder.reset()
        #expect(engine.sendUserMessage(text: "我们回私聊细聊预算分配吧。", attachments: [], in: privateChat, providers: [providerA, providerB], context: context) == .sent)
        await waitUntilIdle(engine, conversationID: privateChat.id)
        let privateFollowUp = try #require(recorder.requests.first { !$0.systemPrompt.contains("仅输出合法 JSON") })
        #expect(privateFollowUp.systemPrompt.contains("十五万以内"))
    }

    @Test("BackupArchive and WebDAV tombstone sync merge FriendMemory entries and cascade Persona/Book deletions")
    func backupMergeWebDAVTombstoneAndCascadeDeletion() throws {
        let containerA = try makeInMemoryContainer()
        let containerB = try makeInMemoryContainer()
        let storeA = FriendMemoryStore(fileURL: nil, notifySyncChanges: false)
        let storeB = FriendMemoryStore(fileURL: nil, notifySyncChanges: false)
        let kbA = PresetKnowledgeStore(fileURL: nil)
        let kbB = PresetKnowledgeStore(fileURL: nil)
        let tombstonesA = SyncTombstoneStore(fileURL: nil)
        let tombstonesB = SyncTombstoneStore(fileURL: nil)

        let personaID = UUID()
        let bookID = UUID()
        let personaSubject = FriendMemorySubject.persona(profileID: personaID, name: "庄周", emoji: "🦋")
        let bookSubject = FriendMemorySubject.bookFriend(
            BookFriend(bookID: bookID, bookTitle: "秋水篇", name: "河伯", aliases: [], throughChapter: 2)
        )

        let e1 = try #require(storeA.addEntry("喜欢在深夜读寓言", for: personaSubject, now: Date(timeIntervalSince1970: 1_000)))
        _ = storeA.addEntry("曾讨论过北海之大", for: bookSubject, now: Date(timeIntervalSince1970: 1_000))

        // Export from Device A and apply to Device B
        let archive1 = try BackupService.makeArchive(
            context: containerA.mainContext,
            knowledgeStore: kbA,
            tombstoneStore: tombstonesA,
            friendMemoryStore: storeA
        )
        try BackupService.apply(
            .full(archive1),
            to: containerB.mainContext,
            knowledgeStore: kbB,
            tombstonePolicy: .enforce(tombstonesB),
            friendMemoryStore: storeB
        )
        #expect(storeB.visibleEntries(for: personaSubject).count == 1)
        #expect(storeB.visibleEntries(for: bookSubject).count == 1)

        // Device B deletes entry e1, adds e2, and deletes the Book (recording book tombstone)
        storeB.deleteEntry(id: e1.id, for: personaSubject, now: Date(timeIntervalSince1970: 2_000))
        _ = storeB.addEntry("最近在研究齐物论", for: personaSubject, now: Date(timeIntervalSince1970: 2_100))
        storeB.removeMemoriesForBook(bookID: bookID, at: Date(timeIntervalSince1970: 2_200))
        tombstonesB.recordDeletion(kind: .book, id: bookID, at: Date(timeIntervalSince1970: 2_200))

        // Sync back from Device B to Device A under .enforce
        let archive2 = try BackupService.makeArchive(
            context: containerB.mainContext,
            knowledgeStore: kbB,
            tombstoneStore: tombstonesB,
            friendMemoryStore: storeB
        )
        try BackupService.apply(
            .full(archive2),
            to: containerA.mainContext,
            knowledgeStore: kbA,
            tombstonePolicy: .enforce(tombstonesA),
            friendMemoryStore: storeA
        )

        let syncedPersonaEntries = storeA.visibleEntries(for: personaSubject).map(\.content)
        #expect(syncedPersonaEntries == ["最近在研究齐物论"])
        #expect(storeA.visibleEntries(for: bookSubject).isEmpty)
    }
}
