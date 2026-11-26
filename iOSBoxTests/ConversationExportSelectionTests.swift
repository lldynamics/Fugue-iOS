import PDFKit
import SwiftData
import XCTest
@testable import iOSBox

@MainActor
final class ConversationExportSelectionTests: XCTestCase {
    func testSelectedMarkdownPDFAndImageShareTheActiveBranchScope() async throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let chat = Conversation(title: "Scoped export", systemPrompt: "hidden directive")
        context.insert(chat)
        let messages = (0..<15).map { index in
            ChatMessage(role: .assistant, content: "selected body \(index)", reasoningContent: "hidden reasoning", sortIndex: index)
        }
        for message in messages { message.conversation = chat }
        chat.messages = messages
        messages[2].assistanceMetadata.groupReplyToExcerpt = "hidden quote"
        try context.save()
        let ids = Set(messages.dropFirst(2).map(\.id))
        var options = ConversationExporter.Options(messageIDs: ids)

        let markdown = ConversationExporter.makeMarkdown(for: chat, options: options)
        XCTAssertTrue(markdown.contains("selected body 2"))
        XCTAssertFalse(markdown.contains("selected body 0"))
        XCTAssertFalse(markdown.contains("hidden"))
        let url = try await ConversationExporter.writePDFFile(for: chat, options: options)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pdfText = try XCTUnwrap(PDFDocument(url: url)?.string)
        XCTAssertTrue(pdfText.contains("selected body 2"))
        XCTAssertFalse(pdfText.contains("hidden"))
        XCTAssertFalse(pdfText.contains("selected body 0"))
        let image = ConversationExporter.shareCardContent(for: chat, selectedIDs: ids)
        XCTAssertEqual(image.entries.map(\.message.id), messages.suffix(12).map(\.id))
        XCTAssertEqual(image.omittedEarlier, 1)
        XCTAssertEqual(image.truncatedCount, 0)

        options.includesSystemPrompt = true
        options.includesReasoning = true
        options.includesReferences = true
        let full = ConversationExporter.makeMarkdown(for: chat, options: options)
        for text in ["hidden directive", "hidden reasoning", "hidden quote"] { XCTAssertTrue(full.contains(text)) }
        XCTAssertTrue(ConversationExporter.makeMarkdown(for: chat).contains("selected body 0"))
    }

    func testImageCountsOnlyOmittedEligibleMessagesAndTruncatedVisibleBodies() throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let chat = Conversation(title: "Image selection")
        container.mainContext.insert(chat)
        let messages = (0..<16).map { ChatMessage(role: .user, content: "Message \($0)", sortIndex: $0) }
        for message in messages { message.conversation = chat }
        chat.messages = messages
        let boundary = String(repeating: "👩🏽‍💻", count: 900)
        for index in [0, 1, 8, 10] { messages[index].content = boundary + "!" }
        messages[2].content = ""
        messages[7].content = "  " + boundary + "\n"
        try container.mainContext.save()

        let selected = Set(messages.dropFirst().map(\.id))
        let card = ConversationExporter.shareCardContent(for: chat, selectedIDs: selected)
        XCTAssertEqual(card.entries.map(\.message.id), messages.suffix(12).map(\.id))
        XCTAssertEqual(card.omittedEarlier, 2)
        XCTAssertEqual(card.truncatedCount, 2)
        XCTAssertEqual(card.entries.first { $0.message.id == messages[7].id }?.text, boundary)
        XCTAssertEqual(card.entries.first { $0.message.id == messages[8].id }?.text, boundary + "…")
        XCTAssertNotNil(card.notice)

        let shortSelection = ConversationExporter.shareCardContent(for: chat, selectedIDs: [messages[2].id, messages[7].id])
        XCTAssertEqual(shortSelection.entries.count, 1)
        XCTAssertNil(shortSelection.notice)
    }
}
