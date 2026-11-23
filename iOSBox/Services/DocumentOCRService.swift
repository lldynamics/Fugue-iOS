import Foundation
import UIKit
import Vision

enum DocumentOCRFormatter {
    static let maxOCRCharacters = 80_000

    static func combinePages(_ pages: [String]) -> String {
        let nonEmpty = pages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }
        if nonEmpty.count == 1 {
            return truncateIfNeeded(nonEmpty[0])
        }
        let combined = nonEmpty.enumerated().map { index, pageText in
            String(localized: "--- 第 \(index + 1) 页 ---\n\(pageText)")
        }.joined(separator: "\n\n")
        return truncateIfNeeded(combined)
    }

    static func ocrFileName(from originalFileName: String?, pageCount: Int = 1) -> String {
        if pageCount > 1 {
            return "扫描文档-OCR-\(pageCount)页.txt"
        }
        let raw = (originalFileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(fileURLWithPath: raw).deletingPathExtension().lastPathComponent
        let cleanBase = base.isEmpty ? "图片" : base
        return "\(cleanBase)-OCR.txt"
    }

    private static func truncateIfNeeded(_ text: String) -> String {
        guard text.count > maxOCRCharacters else { return text }
        let suffix = String(localized: "\n\n…[OCR 文本较长，已截断至前 \(maxOCRCharacters) 个字符]…")
        return String(text.prefix(maxOCRCharacters)) + suffix
    }
}

enum DocumentOCRService {
    private static let maxDimension: CGFloat = 2400

    static func recognizeText(in image: UIImage) -> String {
        autoreleasepool {
            guard let cgImage = normalizedCGImage(from: image) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return ""
            }
        }
    }

    static func recognizeText(from images: [UIImage]) async -> String {
        guard !images.isEmpty else { return "" }
        return await Task.detached(priority: .userInitiated) {
            let pages = images.map { recognizeText(in: $0) }
            return DocumentOCRFormatter.combinePages(pages)
        }.value
    }

    static func makeOCRDocumentAttachment(
        text: String,
        sourceFileName: String? = nil,
        pageCount: Int = 1
    ) -> MessageAttachment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = DocumentOCRFormatter.ocrFileName(from: sourceFileName, pageCount: pageCount)
        return MessageAttachment(
            kind: .document,
            fileName: fileName,
            mimeType: "text/plain",
            dataBase64: nil,
            extractedText: trimmed,
            byteSize: trimmed.utf8.count
        )
    }

    static func convertImageAttachmentsToOCRDocument(
        _ attachments: [MessageAttachment]
    ) async -> (document: MessageAttachment?, convertedIDs: [UUID]) {
        let imageItems = attachments.filter { $0.kind == .image && $0.dataBase64 != nil }
        guard !imageItems.isEmpty else { return (nil, []) }

        return await Task.detached(priority: .userInitiated) {
            var pageTexts: [String] = []
            var processedIDs: [UUID] = []

            for item in imageItems {
                guard let base64 = item.dataBase64,
                      let data = Data(base64Encoded: base64),
                      let uiImage = UIImage(data: data) else {
                    continue
                }
                processedIDs.append(item.id)
                let text = recognizeText(in: uiImage)
                if !text.isEmpty {
                    pageTexts.append(text)
                }
            }

            let combined = DocumentOCRFormatter.combinePages(pageTexts)
            guard !combined.isEmpty else {
                return (nil, [])
            }
            let doc = makeOCRDocumentAttachment(
                text: combined,
                sourceFileName: imageItems.first?.fileName,
                pageCount: processedIDs.count
            )
            return (doc, processedIDs)
        }.value
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return nil }

        if image.imageOrientation == .up, longest <= maxDimension, let direct = image.cgImage {
            return direct
        }

        let ratio = min(1.0, maxDimension / longest)
        let targetSize = CGSize(
            width: max(1, floor(pixelWidth * ratio)),
            height: max(1, floor(pixelHeight * ratio))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.cgImage
    }
}
