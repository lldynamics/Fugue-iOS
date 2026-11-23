import UIKit
import XCTest
@testable import iOSBox

final class Phase2AudioAndOCRTests: XCTestCase {

    func testAudioMeteringNormalizerClampsAndRollsHistory() {
        XCTAssertEqual(AudioMeteringNormalizer.normalize(decibels: -120), 0.08, accuracy: 0.001)
        XCTAssertEqual(AudioMeteringNormalizer.normalize(decibels: .nan), 0.08, accuracy: 0.001)
        XCTAssertEqual(AudioMeteringNormalizer.normalize(decibels: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(AudioMeteringNormalizer.normalize(decibels: 6), 1.0, accuracy: 0.001)

        let low = AudioMeteringNormalizer.normalize(decibels: -45)
        let mid = AudioMeteringNormalizer.normalize(decibels: -25)
        let high = AudioMeteringNormalizer.normalize(decibels: -5)
        XCTAssertGreaterThan(mid, low)
        XCTAssertGreaterThan(high, mid)

        var history: [Float] = []
        for idx in 1...45 {
            history = AudioMeteringNormalizer.appendSample(Float(idx) / 50.0, to: history)
        }
        XCTAssertEqual(history.count, AudioMeteringNormalizer.maxSamples)
        XCTAssertEqual(history.first ?? 0, Float(10) / 50.0, accuracy: 0.001)
        XCTAssertEqual(history.last ?? 0, Float(45) / 50.0, accuracy: 0.001)
    }

    func testLocalSpeechTranscriberResolvesCommonLocales() {
        XCTAssertEqual(LocalSpeechTranscriber.resolvedLocale(for: "zh").identifier, "zh-CN")
        XCTAssertEqual(LocalSpeechTranscriber.resolvedLocale(for: "zh_Hant").identifier, "zh-TW")
        XCTAssertEqual(LocalSpeechTranscriber.resolvedLocale(for: "en").identifier, "en-US")
        XCTAssertEqual(LocalSpeechTranscriber.resolvedLocale(for: "ja").identifier, "ja-JP")
        XCTAssertEqual(LocalSpeechTranscriber.resolvedLocale(for: "ko").identifier, "ko-KR")
    }

    func testDocumentOCRFormatterCombinesPagesAndBuildsTextAttachment() {
        XCTAssertEqual(DocumentOCRFormatter.combinePages(["  ", "\n"]), "")
        XCTAssertEqual(DocumentOCRFormatter.combinePages(["  Hello Page 1  ", ""]), "Hello Page 1")

        let multi = DocumentOCRFormatter.combinePages(["First block", "", "Second block"])
        XCTAssertTrue(multi.contains("第 1 页"))
        XCTAssertTrue(multi.contains("First block"))
        XCTAssertTrue(multi.contains("第 2 页"))
        XCTAssertTrue(multi.contains("Second block"))

        XCTAssertEqual(DocumentOCRFormatter.ocrFileName(from: "contract.jpg", pageCount: 1), "contract-OCR.txt")
        XCTAssertEqual(DocumentOCRFormatter.ocrFileName(from: "scan-1.jpg", pageCount: 3), "扫描文档-OCR-3页.txt")

        let attachment = DocumentOCRService.makeOCRDocumentAttachment(
            text: "Extracted text body",
            sourceFileName: "invoice.png",
            pageCount: 1
        )
        XCTAssertEqual(attachment.kind, .document)
        XCTAssertEqual(attachment.fileName, "invoice-OCR.txt")
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertNil(attachment.dataBase64)
        XCTAssertEqual(attachment.extractedText, "Extracted text body")
        XCTAssertEqual(attachment.byteSize, "Extracted text body".utf8.count)
    }

    func testDocumentOCRServiceRecognizesRenderedImageAttachment() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 220), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 220))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 44),
                .foregroundColor: UIColor.black
            ]
            NSString(string: "MEETING NOTES 2026").draw(at: CGPoint(x: 36, y: 80), withAttributes: attrs)
        }

        let imageAttachment = try XCTUnwrap(AttachmentProcessor.processImage(image, fileName: "board.jpg"))
        let result = await DocumentOCRService.convertImageAttachmentsToOCRDocument([imageAttachment])

        let doc = try XCTUnwrap(result.document)
        XCTAssertEqual(result.convertedIDs, [imageAttachment.id])
        XCTAssertEqual(doc.kind, .document)
        XCTAssertNil(doc.dataBase64)
        let extracted = try XCTUnwrap(doc.extractedText).uppercased()
        XCTAssertTrue(extracted.contains("MEETING") || extracted.contains("NOTES") || extracted.contains("2026"))
    }
}
