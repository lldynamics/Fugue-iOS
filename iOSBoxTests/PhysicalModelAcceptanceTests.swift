import XCTest
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import iOSBox

/// Explicit hardware acceptance only. No credentials or user documents are read.
final class PhysicalModelAcceptanceTests: XCTestCase {
    private func requireDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPad or iPhone required")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUGUE_DEVICE_ACCEPTANCE"] == "1", "Opt-in hardware acceptance")
        #endif
    }

    func testSystemModelGeneratesFromSyntheticChineseExcerpt() async throws {
        try requireDevice()
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return XCTFail("iOS 26 or later is required") }
        let model = SystemLanguageModel.default
        XCTAssertEqual(model.availability, .available, "System model availability: \(model.availability)")
        guard model.availability == .available else { return }
        let session = LanguageModelSession(model: model, instructions: "按用户指定的操作处理引文，保留原文语言。")
        let response = try await session.respond(to: "摘要：采购组今天收到了蓝色铅笔。请用一句中文概括，并保留颜色和物品名称。")
        let attachment = XCTAttachment(string: response.content)
        attachment.name = "On-device response to synthetic stationery excerpt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(response.content.contains("蓝") && response.content.contains("铅笔"))
        #else
        XCTFail("SDK has no FoundationModels")
        #endif
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
