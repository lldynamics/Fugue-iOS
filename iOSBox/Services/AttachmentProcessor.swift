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

enum ImageUploadQuality: String, CaseIterable, Identifiable, Sendable {
    case standard
    case high
    case original

    static let defaultsKey = "iosbox.pref.imageUploadQuality"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return String(localized: "标准（1600px · 省流量）")
        case .high: return String(localized: "高清（2400px · 清晰文字）")
        case .original: return String(localized: "原图（最高 4096px）")
        }
    }

    var shortLabel: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .high: return String(localized: "高清")
        case .original: return String(localized: "原图")
        }
    }

    var maxDimension: CGFloat {
        switch self {
        case .standard: return 1600
        case .high: return 2400
        case .original: return 4096
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .standard: return 0.82
        case .high: return 0.90
        case .original: return 0.95
        }
    }

    static func current(defaults: UserDefaults = .standard) -> ImageUploadQuality {
        guard let raw = defaults.string(forKey: defaultsKey),
              let parsed = ImageUploadQuality(rawValue: raw) else {
            return .standard
        }
        return parsed
    }
}

enum AttachmentProcessor {
    static let maximumFileBytes = 20 * 1024 * 1024
    static let maximumAttachmentCount = 12
    static let maximumPayloadBytes = 64 * 1024 * 1024

    static func validate(_ attachments: [MessageAttachment]) throws {
        guard attachments.count <= maximumAttachmentCount else { throw AttachmentError.limit }
        var remaining = maximumPayloadBytes
        for item in attachments {
            let size = (item.dataBase64?.utf8.count ?? 0) + (item.extractedText?.utf8.count ?? 0)
            guard size <= remaining else { throw AttachmentError.limit }
            remaining -= size
        }
    }

    static let maxTextCharacters = 200_000
    static let maximumPDFPages = 300
    static let maxInlinePDFBytes = 16 * 1024 * 1024
    private static let maxOriginalPassthroughBytes = 12 * 1024 * 1024

    static func processImage(
        _ image: UIImage,
        fileName: String = "photo.jpg",
        quality: ImageUploadQuality = ImageUploadQuality.current()
    ) -> MessageAttachment? {
        let resized = downscaleIfNeeded(image, maxDimension: quality.maxDimension)
        guard let jpegData = resized.jpegData(compressionQuality: quality.jpegQuality) else {
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

    static func processImageData(
        _ data: Data,
        suggestedName: String = "image.jpg",
        quality: ImageUploadQuality = ImageUploadQuality.current()
    ) -> MessageAttachment? {
        guard data.count <= maximumFileBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        // In original mode, preserve untouched PNG/JPEG bytes when size is reasonable and dimensions fit.
        if quality == .original && data.count <= maxOriginalPassthroughBytes {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if max(w, h) <= Double(quality.maxDimension) && orientation == 1 {
                let mime: String?
                if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                    mime = "image/png"
                } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
                    mime = "image/jpeg"
                } else {
                    mime = nil
                }
                if let mime {
                    return MessageAttachment(
                        kind: .image,
                        fileName: suggestedName,
                        mimeType: mime,
                        dataBase64: data.base64EncodedString(),
                        extractedText: nil,
                        byteSize: data.count
                    )
                }
            }
        }

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(quality.maxDimension)
        ] as CFDictionary) else { return nil }
        return processImage(UIImage(cgImage: thumbnail), fileName: suggestedName, quality: quality)
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
            let extracted = extractPDFText(from: data)
            let base64 = data.count <= maxInlinePDFBytes ? data.base64EncodedString() : nil
            return MessageAttachment(
                kind: .document,
                fileName: fileName,
                mimeType: "application/pdf",
                dataBase64: base64,
                extractedText: truncateIfNeeded(extracted.text),
                byteSize: data.count, textCoverage: extracted.coverage
            )
        }

        if OfficeDocumentReader.legacyBinaryExtensions.contains(ext) {
            throw AttachmentError.legacyOfficeUnsupported
        }

        if OfficeDocumentReader.supportedExtensions.contains(ext) {
            let baseTitle = url.deletingPathExtension().lastPathComponent
            let officeText: String
            do {
                officeText = try OfficeDocumentReader.extractText(
                    from: data,
                    ext: ext,
                    fallbackTitle: baseTitle,
                    maxCharacters: maxTextCharacters
                )
            } catch BookImportError.noText {
                officeText = String(localized: "[文档中未提取到可读文字内容]")
            } catch BookImportError.locked {
                officeText = String(localized: "[此文档已加密，无法读取内容，请先解除密码保护后重试]")
            } catch is BookImportError {
                throw AttachmentError.unsupportedBinary
            }
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            return MessageAttachment(
                kind: .document,
                fileName: fileName,
                mimeType: mimeType,
                dataBase64: nil,
                extractedText: truncateIfNeeded(officeText),
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
            decoded = String(decoding: data.prefix(240_000), as: UTF8.self)
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

    static func extractPDFText(from data: Data) -> (text: String, coverage: AttachmentTextCoverage?) {
        guard let document = PDFDocument(data: data) else { return ("", nil) }
        let maxPages = maximumPDFPages
        let maxOCRPages = 60
        var pages: [String] = []
        var remaining = maxTextCharacters
        var truncated = document.pageCount > maxPages
        var ocrPagesUsed = 0
        for index in 0..<min(document.pageCount, maxPages) {
            guard remaining > 0, !Task.isCancelled else { break }
            autoreleasepool {
                if let page = document.page(at: index) {
                    var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty && ocrPagesUsed >= maxOCRPages { truncated = true }
                    if text.isEmpty && ocrPagesUsed < maxOCRPages {
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
        let count = pages.count
        if truncated { pages.append(String(localized: "…[PDF 内容较长，仅提取前 \(maxPages) 页、最多 \(maxTextCharacters) 个字符]…")) }
        let text = pages.joined(separator: "\n\n")
        return (text, AttachmentTextCoverage(totalPages: document.pageCount, pagesWithText: count, ocrPages: ocrPagesUsed,
                                             isTruncated: truncated || text.count > maxTextCharacters))
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
    case legacyOfficeUnsupported
    var errorDescription: String? {
        switch self {
        case .limit: return String(localized: "附件超出限制：单文件最多 20 MB，每次最多 \(AttachmentProcessor.maximumAttachmentCount) 个附件，总内容最多 64 MB。")
        case .unreadableImage: return String(localized: "无法读取图片，或图片超过 20 MB 限制。")
        case .unsupportedBinary: return String(localized: "不支持的二进制文件格式，请选择图片、PDF、Office 文档（DOCX/XLSX/PPTX）或纯文本/代码文件。")
        case .legacyOfficeUnsupported: return String(localized: "暂不支持旧版二进制 .doc / .xls / .ppt，请先另存为 .docx / .xlsx / .pptx 或 PDF 后再试。")
        }
    }
}
