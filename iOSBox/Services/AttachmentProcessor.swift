import Foundation
import UIKit
import PDFKit
import UniformTypeIdentifiers

enum AttachmentProcessor {
    private static let maxImageDimension: CGFloat = 1600
    private static let jpegQuality: CGFloat = 0.82
    private static let maxTextCharacters = 80_000
    private static let maxInlinePDFBytes = 8 * 1024 * 1024

    static func processImage(_ image: UIImage, fileName: String = "photo.jpg") -> MessageAttachment? {
        let resized = downscaleIfNeeded(image, maxDimension: maxImageDimension)
        guard let jpegData = resized.jpegData(compressionQuality: jpegQuality) else {
            return nil
        }
        return MessageAttachment(
            kind: .image,
            fileName: fileName,
            mimeType: "image/jpeg",
            dataBase64: jpegData.base64EncodedString(),
            extractedText: nil,
            byteSize: jpegData.count
        )
    }

    static func processImageData(_ data: Data, suggestedName: String = "image.jpg") -> MessageAttachment? {
        guard let image = UIImage(data: data) else { return nil }
        return processImage(image, fileName: suggestedName)
    }

    static func processFileURL(_ url: URL) throws -> MessageAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Image files selected from Files app
        if ["jpg", "jpeg", "png", "webp", "heic", "gif"].contains(ext),
           let imageAttachment = processImageData(data, suggestedName: fileName) {
            return imageAttachment
        }

        // PDF files: extract text via PDFKit + preserve base64 for Claude/Gemini native PDF reading
        if ext == "pdf" {
            let pdfText = extractPDFText(from: data)
            let base64 = data.count <= maxInlinePDFBytes ? data.base64EncodedString() : nil
            return MessageAttachment(
                kind: .document,
                fileName: fileName,
                mimeType: "application/pdf",
                dataBase64: base64,
                extractedText: truncateIfNeeded(pdfText),
                byteSize: data.count
            )
        }

        // Plain text / code / structured text files
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data.prefix(120_000), as: UTF8.self)

        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/plain"
        return MessageAttachment(
            kind: .document,
            fileName: fileName,
            mimeType: mimeType,
            dataBase64: nil,
            extractedText: truncateIfNeeded(decoded),
            byteSize: data.count
        )
    }

    private static func extractPDFText(from data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index),
               let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                pages.append(String(localized: "--- 第 \(index + 1) 页 ---\n\(text)"))
            }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func truncateIfNeeded(_ text: String) -> String {
        guard text.count > maxTextCharacters else { return text }
        let prefix = text.prefix(maxTextCharacters)
        return String(localized: "\(prefix)\n\n...[文件内容较长，已截取前 \(maxTextCharacters) 个字符]...")
    }

    private static func downscaleIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else {
            return image
        }
        let scale = maxDimension / longest
        let targetSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
