import Foundation
import UIKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import CoreTransferable

/// PhotosPicker provides a temporary file; process it before the transfer scope ends.
/// Loading Data.self would allocate the whole original before checking its size.
struct ImportedPhoto: Transferable {
    let attachment: MessageAttachment
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let attachment = try await Task.detached {
                try AttachmentProcessor.processFileURL(received.file, imageOnly: true)
            }.value
            return ImportedPhoto(attachment: attachment)
        }
    }
}

enum AttachmentProcessor {
    static let maximumFileBytes = 20 * 1024 * 1024
    static let maximumAttachmentCount = 8
    static let maximumPayloadBytes = 32 * 1024 * 1024

    static func validate(_ attachments: [MessageAttachment]) throws {
        guard attachments.count <= maximumAttachmentCount else { throw AttachmentError.limit }
        var remaining = maximumPayloadBytes
        for item in attachments {
            let size = (item.dataBase64?.utf8.count ?? 0) + (item.extractedText?.utf8.count ?? 0)
            guard size <= remaining else { throw AttachmentError.limit }
            remaining -= size
        }
    }

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
        guard data.count <= maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxImageDimension)
              ] as CFDictionary) else { return nil }
        return processImage(UIImage(cgImage: thumbnail), fileName: suggestedName)
    }

    static func processFileURL(_ url: URL, imageOnly: Bool = false) throws -> MessageAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumFileBytes else { throw AttachmentError.limit }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw AttachmentError.limit }
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Image files selected from Files app
        if imageOnly || ["jpg", "jpeg", "png", "webp", "heic", "heif", "gif"].contains(ext) {
            guard let imageAttachment = processImageData(data, suggestedName: fileName) else { throw AttachmentError.unreadableImage }
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

        // Plain text / code / structured text files: reject binary files containing NUL bytes
        // instead of forwarding decoded binary garbage to the model.
        let decoded: String
        if let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\0") {
            decoded = utf8
        } else if (data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])),
                  let utf16 = String(data: data, encoding: .utf16), !utf16.contains("\0") {
            decoded = utf16
        } else {
            let sample = data.prefix(8192)
            if sample.contains(0) {
                throw AttachmentError.unsupportedBinary
            }
            decoded = String(decoding: data.prefix(120_000), as: UTF8.self)
        }

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
        var remaining = maxTextCharacters
        var truncated = document.pageCount > 200
        var ocrPagesUsed = 0
        for index in 0..<min(document.pageCount, 200) {
            guard remaining > 0, !Task.isCancelled else { break }
            autoreleasepool {
                if let page = document.page(at: index) {
                    var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty && ocrPagesUsed < 30 {
                        ocrPagesUsed += 1
                        text = PDFOCRService.recognizeText(on: page)
                    }
                    if !text.isEmpty {
                        let excerpt = String(text.prefix(remaining))
                        if excerpt.count < text.count { truncated = true }
                        remaining -= excerpt.count
                        pages.append(String(localized: "--- 第 \(index + 1) 页 ---\n\(excerpt)"))
                    }
                }
            }
        }
        if remaining == 0 { truncated = true }
        if truncated { pages.append(String(localized: "…[PDF 内容较长，仅提取前 200 页、最多 80000 个字符]…")) }
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

enum AttachmentError: LocalizedError {
    case limit
    case unreadableImage
    case unsupportedBinary
    var errorDescription: String? {
        switch self {
        case .limit: return String(localized: "附件超出限制：单文件最多 20 MB，每次最多 8 个附件，总内容最多 32 MB。")
        case .unreadableImage: return String(localized: "无法读取图片，或图片超过 20 MB 限制。")
        case .unsupportedBinary: return String(localized: "不支持的二进制文件格式，请选择图片、PDF 或纯文本/代码文件。")
        }
    }
}
