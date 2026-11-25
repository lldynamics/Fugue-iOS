#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftData

/// Content for the explicitly launched, in-memory UI test scene.
@MainActor
enum WorkspaceTestContent {
    static func insert(in context: ModelContext) throws {
        if ProcessInfo.processInfo.arguments.contains("-ui-test-personas") {
            var sample = ModelSpec(id: "sample-a")
            if ProcessInfo.processInfo.arguments.contains("-ui-test-model-details") {
                sample.supportsVision = true
                sample.supportsReasoning = true
                sample.inputPricePerMillion = 0.1
                sample.outputPricePerMillion = 1
                sample.priceCurrency = "USD"
            }
            let provider = ProviderConfig(name: "本地模型", protocolType: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1",
                                          models: [sample, ModelSpec(id: "sample-b")])
            context.insert(provider)
            let member = GroupMember(name: "林舟", rolePrompt: "记录自然观察。", target: provider.makeTarget(for: provider.models[1]))
            _ = try PersonaLibrary.save(member, in: context)
        }
        let draft = Conversation()
        context.insert(draft)
        try ChatDraftStore.shared.save(ChatDraft(text: "帮我把这份走访笔记整理成三个要点。"), for: draft.id)
        if ProcessInfo.processInfo.arguments.contains("-ui-test-unpriced-usage") {
            let spec = ModelSpec(id: "notes-model")
            let provider = ProviderConfig(name: "本地测试", protocolType: .openAICompatible,
                                          baseURL: "http://127.0.0.1", models: [spec])
            let row = RequestRecord(target: provider.makeTarget(for: spec), spec: nil, conversationID: draft.id,
                                    messageID: UUID(), kind: .answer)
            row.promptTokens = 30
            row.completionTokens = 15
            row.status = .succeeded
            context.insert(row)
            if ProcessInfo.processInfo.arguments.contains("-ui-test-mixed-pricing") {
                var priced = ModelSpec(id: "priced-model")
                priced.inputPricePerMillion = 1
                priced.outputPricePerMillion = 2
                priced.priceCurrency = "USD"
                let paid = RequestRecord(target: provider.makeTarget(for: priced), spec: priced, conversationID: draft.id,
                                         messageID: UUID(), kind: .answer)
                paid.promptTokens = 500_000
                paid.completionTokens = 250_000
                paid.status = .succeeded
                context.insert(paid)
            }
        }

        let book = try BookLibrary.store(PreparedBook(BookManuscript(title: "山路手记", chapters: [
            BookChapter(title: "启程", text: "山路从村口开始。"),
            BookChapter(title: "溪边的旧路", text: "雨停之后，溪水退回石阶下。\n路边的草倒向同一侧，留下昨夜水流的方向。\n小桥尽头，老人重新挂起了晒茶的竹匾。\n\n我沿着青石小路往回走，听见屋檐最后几滴水落进木桶。")
        ])), in: context)
        let reading = Conversation(title: "山路手记", assistantEmoji: "📚")
        reading.assistanceSettings.knowledgeVolumeIDs = [book.id]
        context.insert(reading)
        let question = ChatMessage(role: .user, content: "作者怎样写出雨后的变化？")
        let answer = ChatMessage(role: .assistant, content: "他用倒伏的草写出昨夜的水势，也用重新晒起的茶写出生活的恢复。\n\n[山路手记 · 溪边的旧路]", sortIndex: 1)
        answer.assistanceMetadata.knowledgeEvidence = KnowledgeEvidence(query: question.content, passages: [
            .init(id: 1, volumeID: book.id, documentTitle: book.title, sectionTitle: "溪边的旧路", excerpt: "路边的草倒向同一侧", chapterIndex: 1)
        ])
        for msg in [question, answer] { context.insert(msg); msg.conversation = reading }

        if ProcessInfo.processInfo.arguments.contains("-ui-test-source-layout") {
            let friend = Conversation(title: "旅人私聊")
            friend.assistanceSettings.bookFriend = BookFriend(bookID: book.id, bookTitle: book.title, name: "旅人",
                                                              aliases: [], throughChapter: 0)
            let group = Conversation(title: "读书小组")
            group.isGroupMode = true
            let notes = try BookLibrary.store(PreparedBook(BookManuscript(title: "走访笔记", chapters: [
                BookChapter(title: "村口", text: "访谈从村口开始。")
            ])), in: context)
            group.assistanceSettings.knowledgeVolumeIDs = [book.id, notes.id]
            for chat in [friend, group] {
                context.insert(chat)
                let turn = ChatMessage(role: .user, content: "从哪一章开始？")
                context.insert(turn)
                turn.conversation = chat
            }
        }

        let arena = Conversation(title: "访谈笔记盲评", isArenaMode: true)
        arena.assistanceSettings.blindArenaMode = true
        context.insert(arena)
        let group = UUID()
        let prompt = ChatMessage(role: .user, content: "怎样让一份访谈笔记更容易复用？")
        context.insert(prompt)
        prompt.conversation = arena
        for (index, text) in ["按问题整理。先把访谈拆成几个问题，每条结论附上一段原话。下次遇到相同问题时，就能直接找到依据。", "按主题整理。把观察归成几个主题，每个主题保留一个具体例子。写摘要时，再从这些例子里提取共性。"].enumerated() {
            let reply = ChatMessage(role: .assistant, content: text, comparisonGroupID: group, sortIndex: index + 1)
            reply.providerName = "本地测试"
            reply.modelDisplayName = index == 0 ? "演示甲" : "演示乙"
            reply.modelID = "fixture-\(index)"
            context.insert(reply)
            reply.conversation = arena
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-audit-incomplete-currency") {
            var legacy = ModelSpec(id: "legacy-pricing")
            legacy.inputPricePerMillion = 0.1
            legacy.outputPricePerMillion = 1
            let provider = ProviderConfig(name: "币种缺失测试", protocolType: .openAICompatible,
                                          baseURL: "http://127.0.0.1", models: [legacy])
            context.insert(provider)
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-audit-tiny-cost") {
            var tiny = ModelSpec(id: "tiny-price")
            tiny.inputPricePerMillion = 0.1
            tiny.outputPricePerMillion = 1
            tiny.priceCurrency = "USD"
            let provider = ProviderConfig(name: "本地测试", protocolType: .openAICompatible,
                                          baseURL: "http://127.0.0.1", models: [tiny])
            let record = RequestRecord(target: provider.makeTarget(for: tiny), spec: tiny, conversationID: draft.id,
                                       messageID: UUID(), kind: .answer)
            record.promptTokens = 1
            record.completionTokens = 0
            record.status = .succeeded
            context.insert(record)
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-audit-stale-group-model") {
            let oldModel = ModelSpec(id: "old-model")
            let removedProvider = ProviderConfig(name: "已移除的服务商", protocolType: .openAICompatible,
                                                 baseURL: "http://127.0.0.1", models: [oldModel])
            let staleGroup = Conversation(title: "失效模型测试群")
            staleGroup.isGroupMode = true
            staleGroup.assistanceSettings.groupMembers = [GroupMember(name: "测试成员", rolePrompt: "演示角色", target: removedProvider.makeTarget(for: oldModel))]
            context.insert(staleGroup)
            let message = ChatMessage(role: .user, content: "测试群内讨论")
            context.insert(message)
            message.conversation = staleGroup
        }
        try context.save()
    }
}
#endif
