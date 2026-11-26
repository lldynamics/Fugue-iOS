import XCTest
import UIKit
import PDFKit
import SwiftData
@testable import iOSBox

private final class ReadCounter { var count = 0 }
private struct FixtureBytes: AsyncSequence {
    typealias Element = UInt8
    let data: [UInt8]
    let counter: ReadCounter
    init(_ text: String, counter: ReadCounter = ReadCounter()) { self.data = Array(text.utf8); self.counter = counter }
    func makeAsyncIterator() -> Iterator { Iterator(data: data, counter: counter) }
    struct Iterator: AsyncIteratorProtocol {
        let data: [UInt8]
        let counter: ReadCounter
        var index = 0
        mutating func next() async throws -> UInt8? {
            guard index < data.count else { return nil }
            defer { index += 1 }
            counter.count += 1
            return data[index]
        }
    }
}

@MainActor
final class ReviewBoundaryTests: XCTestCase {
    private func tempURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private var attachment: MessageAttachment {
        MessageAttachment(kind: .document, fileName: "fixture.txt", mimeType: "text/plain", extractedText: "fixture", byteSize: 7)
    }

    func testSSEFramingAcrossLineEndingsCommentsAndUnicode() async throws {
        for newline in ["\n", "\r", "\r\n"] {
            let input = "\u{FEFF}:ping\nevent: message\ndata: 你好\ndata\ndata: 世界\n\ndata: unfinished".replacingOccurrences(of: "\n", with: newline)
            var output: [String] = []
            for try await event in SSEDecoder.events(FixtureBytes(input)) { output.append(event) }
            XCTAssertEqual(output, ["你好\n\n世界"])
        }
    }

    func testSSEDoesNotReadPastRequestedEvent() async throws {
        let counter = ReadCounter()
        var iterator = SSEDecoder.events(FixtureBytes("data: first\n\ndata: second\n\n", counter: counter)).makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first, "first")
        XCTAssertEqual(counter.count, "data: first\n\n".utf8.count)
    }

    func testSSECancellationStopsBeforeReading() async {
        let counter = ReadCounter()
        let task = Task { @MainActor in
            var iterator = SSEDecoder.events(FixtureBytes("data: hello\n\n", counter: counter)).makeAsyncIterator()
            do { _ = try await iterator.next(); return false }
            catch { return error is CancellationError }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(counter.count, 0)
    }

    func testSSERejectsOversizedLineAndMultilineEvent() async throws {
        for input in ["data: " + String(repeating: "x", count: 2 * 1024 * 1024),
                      String(repeating: "data: " + String(repeating: "x", count: 1024) + "\n", count: 2048) + "\n"] {
            do {
                for try await _ in SSEDecoder.events(FixtureBytes(input)) { }
                XCTFail("Oversized SSE accepted")
            } catch { XCTAssertTrue(error is LLMError) }
        }
    }

    func testInboxRestoresLegacyAndAttachmentDraftsByEditDate() async throws {
        let directory = tempURL()
        let store = ChatDraftStore(directory: directory)
        let textID = UUID(), attachmentID = UUID(), quoteID = UUID()
        try store.save(ChatDraft(text: "original"), for: textID)
        try store.save(ChatDraft(attachments: [attachment]), for: attachmentID)
        try store.save(ChatDraft(quotedText: "a cited passage"), for: quoteID)
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath:
            directory.appendingPathComponent(textID.uuidString + ".json").path)
        let reopened = ChatDraftStore(directory: directory)
        await reopened.loadInboxPreviews()
        XCTAssertEqual(reopened.previews[textID], .text("original"))
        XCTAssertEqual(reopened.previews[attachmentID], .attachments(1))
        XCTAssertEqual(reopened.previews[quoteID], .quotation("a cited passage"))
        let state = reopened.state(for: textID)
        state.save()
        XCTAssertEqual(reopened.draftDates[textID], oldDate)
        state.text = "new follow-up"
        state.save()
        XCTAssertGreaterThan(try XCTUnwrap(reopened.draftDates[textID]), try XCTUnwrap(reopened.draftDates[attachmentID]))
        state.text = ""
        state.save()
        await reopened.loadInboxPreviews()
        XCTAssertNil(reopened.draftDates[textID])
        XCTAssertEqual(reopened.previews[textID], .empty)
    }

    func testLateAttachmentCompletionSharesAndPersistsDraft() throws {
        let attachment = self.attachment
        let directory = tempURL()
        let store = ChatDraftStore(directory: directory)
        let id = UUID()
        let firstPresentation = store.state(for: id)
        firstPresentation.text = "unsent"
        firstPresentation.processingAttachments += 1
        firstPresentation.save() // navigation away before completion
        let reopened = store.state(for: id)
        XCTAssertTrue(reopened === firstPresentation)
        XCTAssertFalse(reopened.canSend)
        firstPresentation.append(attachment)
        firstPresentation.processingAttachments -= 1
        XCTAssertTrue(reopened.canSend)
        XCTAssertEqual(reopened.attachments, [attachment])
        let coldLoad = try ChatDraftStore(directory: directory).load(id)
        XCTAssertEqual(coldLoad.text, "unsent")
        XCTAssertEqual(coldLoad.attachments, [attachment])
    }

    func testDeletedDraftCannotBeRecreatedByLateAttachment() throws {
        let directory = tempURL()
        let store = ChatDraftStore(directory: directory)
        let id = UUID()
        let state = store.state(for: id)
        state.text = "delete with conversation"
        state.append(attachment)
        try store.remove(id)
        state.append(attachment)
        state.save()
        XCTAssertTrue(state.isDeleted)
        XCTAssertTrue(state.attachments.isEmpty)
        XCTAssertFalse(state.canSend)
        XCTAssertEqual(try ChatDraftStore(directory: directory).load(id).text, "")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testFailedDraftWriteKeepsInputAndRetries() throws {
        let directory = tempURL()
        try Data("obstruct directory".utf8).write(to: directory)
        let store = ChatDraftStore(directory: directory)
        let id = UUID()
        let state = store.state(for: id)
        state.text = "keep this"
        state.save()
        XCTAssertNotNil(state.persistenceError)
        XCTAssertEqual(try store.load(id).text, "keep this")
        try FileManager.default.removeItem(at: directory) // generated fixture only
        state.save()
        XCTAssertNil(state.persistenceError)
        XCTAssertEqual(try ChatDraftStore(directory: directory).load(id).text, "keep this")
    }

    func testFailedDraftReadDoesNotOverwriteFileAndCanRetry() throws {
        let directory = tempURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        let corrupt = Data("unreadable fixture".utf8)
        try corrupt.write(to: url)
        let state = ChatDraftStore(directory: directory).state(for: id)
        XCTAssertFalse(state.isLoaded)
        XCTAssertFalse(state.canSend)
        state.save()
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try JSONEncoder().encode(ChatDraft(text: "recovered")).write(to: url)
        state.load()
        XCTAssertTrue(state.isLoaded)
        XCTAssertEqual(state.text, "recovered")
        XCTAssertNil(state.persistenceError)
    }

    func testImageImportChecksSizeAndRejectsInvalidImage() throws {
        let file = tempURL()
        try Data("not an image".utf8).write(to: file)
        XCTAssertThrowsError(try AttachmentProcessor.processFileURL(file, imageOnly: true))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AttachmentProcessor.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try AttachmentProcessor.processFileURL(file, imageOnly: true)) { error in
            guard case AttachmentError.limit = error else { return XCTFail("Wrong size error") }
        }
    }

    func testImageDownsamplingPreservesPixelLimit() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 2000), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 2000))
        }
        let result = try XCTUnwrap(AttachmentProcessor.processImageData(data))
        let image = try XCTUnwrap(UIImage(data: Data(base64Encoded: try XCTUnwrap(result.dataBase64))!))
        XCTAssertLessThanOrEqual(max(image.cgImage!.width, image.cgImage!.height), 1600)
    }

    func testAttachmentCombinedPayloadLimit() throws {
        var item = attachment
        item.dataBase64 = String(repeating: "x", count: AttachmentProcessor.maximumPayloadBytes / 2)
        XCTAssertThrowsError(try AttachmentProcessor.validate([item, item]))
        try AttachmentProcessor.validate([attachment])
    }

    func testPDFPageLimitIsDisclosed() throws {
        let document = PDFDocument()
        let pageRect = CGRect(x: 0, y: 0, width: 120, height: 40)
        let singlePageData = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { context in
            context.beginPage()
            NSString(string: "Page text").draw(at: CGPoint(x: 8, y: 8), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
        let templateDoc = try XCTUnwrap(PDFDocument(data: singlePageData))
        let templatePage = try XCTUnwrap(templateDoc.page(at: 0))
        for index in 0..<(AttachmentProcessor.maximumPDFPages + 1) {
            document.insert(try XCTUnwrap(templatePage.copy() as? PDFPage), at: index)
        }
        let url = tempURL().appendingPathExtension("pdf")
        XCTAssertTrue(document.write(to: url))
        let result = try AttachmentProcessor.processFileURL(url)
        XCTAssertTrue(result.extractedText?.contains("\(AttachmentProcessor.maximumPDFPages)") == true)
        XCTAssertNotNil(result.dataBase64)
    }

    func testConflictingImportDoesNotPartiallyInsertProviderOrLosePendingEdits() throws {
        let schema = Schema(versionedSchema: CurrentSchema.self)
        let store = try ModelContainer(for: schema,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = store.mainContext
        let existing = Conversation(title: "original")
        let message = ChatMessage(role: .user, content: "retain")
        context.insert(existing); context.insert(message); message.conversation = existing
        let provider = ProviderConfig(name: "new", protocolType: .anthropic, baseURL: "https://review.invalid")
        context.insert(provider)
        try context.save()
        var archive = try BackupService.makeArchive(context: context)
        context.delete(provider); try context.save()
        existing.title = "pending user edit"
        archive.conversations[0].id = UUID()
        XCTAssertThrowsError(try BackupService.apply(.full(archive), to: context))
        let verification = ModelContext(store)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ProviderConfig>()), 0)
        XCTAssertEqual(try verification.fetch(FetchDescriptor<Conversation>()).first?.title, "pending user edit")
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ChatMessage>()), 1)
    }

    func testPrivacyManifestIsBundledWithUserDefaultsReason() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let categories = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertTrue(categories.contains { ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryUserDefaults" && ($0["NSPrivacyAccessedAPITypeReasons"] as? [String])?.contains("CA92.1") == true })
    }
}
