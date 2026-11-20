import XCTest
import SwiftData
@testable import iOSBox

@MainActor
final class ComposerEstimateTiming: XCTestCase {
    func testEstimateWhileTyping() throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let database = try ModelContainer(for: schema, configurations: config)
        let context = database.mainContext
        let binarySize = 2 * 1024 * 1024
        let encoded = Data(repeating: 0x41, count: binarySize).base64EncodedString()
        var textOnlySamples: [Int] = []
        for withMedia in [false, true] {
            let chat = Conversation()
            context.insert(chat)
            for index in 0..<8 {
                let attachments = withMedia ? [MessageAttachment(
                    kind: .image, fileName: "fixture-\(index).jpg", mimeType: "image/jpeg",
                    dataBase64: encoded, extractedText: nil, byteSize: binarySize
                )] : []
                let question = ChatMessage(role: .user, content: "Describe the scene", attachments: attachments, sortIndex: index * 2)
                let answer = ChatMessage(role: .assistant, content: "Sample response", sortIndex: index * 2 + 1)
                for item in [question, answer] {
                    context.insert(item)
                    item.conversation = chat
                }
            }
            try context.save()
            XCTAssertEqual(chat.messages.count, 16)
            var samples: [Double] = []
            for iteration in 0..<11 {
                let start = ContinuousClock.now
                let result = TokenEstimator.estimateUpcomingInput(conversation: chat, providers: [],
                    draftText: String(repeating: "a", count: iteration + 1), attachments: [], quotedText: nil, target: nil)
                let parts = start.duration(to: .now).components
                let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                XCTAssertGreaterThan(result.inputTokens, 0)
                if withMedia {
                    XCTAssertEqual(result.inputTokens, textOnlySamples[iteration] + 2 * 850 + 6 * 400)
                } else {
                    textOnlySamples.append(result.inputTokens)
                }
                if iteration >= 2 { samples.append(ms) }
            }
            let ordered = samples.sorted()
            print("REVIEW_COMPOSER_MS media=\(withMedia) min=\(ordered[0]) median=\(ordered[4]) max=\(ordered[8])")
        }
    }
}
