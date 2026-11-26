import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ShareInputLoader {
    private static let maximumSharedImageFileBytes = 24 * 1024 * 1024
    static let maximumSharedPDFBytes = 16 * 1024 * 1024

    static func load(_ items: [NSExtensionItem]) async throws -> ReadingInput {
        let providers = items.flatMap { $0.attachments ?? [] }
        var fallbackText = ""
        var fallbackURL: URL?
        var safariInput: ReadingInput?
        var sharedAttachments: [MessageAttachment] = []
        var sharedImages = 0
        var containsPDF = false
        for provider in providers.prefix(12) {
            try Task.checkCancellation()
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
               let value = try? await item(provider, type: UTType.propertyList.identifier) as? [String: Any],
               let data = value[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                let text = (data["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let pageURL = (data["url"] as? String).flatMap(URL.init(string:))
                let title = String((data["title"] as? String ?? "").prefix(300))
                if !text.isEmpty, safariInput == nil {
                    safariInput = ReadingInput(
                        text: String(text.prefix(URLReader.maximumCharacters)),
                        url: pageURL,
                        title: title,
                        isTruncated: data["truncated"] as? Bool == true || text.count > URLReader.maximumCharacters
                    )
                }
                if let pageURL, !pageURL.isFileURL {
                    fallbackURL = fallbackURL ?? pageURL
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                guard !containsPDF else { throw SystemEntryError.pdfLimit }
                sharedAttachments.append(try await loadSharedPDF(from: provider))
                containsPDF = true
                continue
            }
            if sharedImages < 2, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let imgAttachment = try? await loadSharedImage(from: provider) {
                sharedAttachments.append(imgAttachment)
                sharedImages += 1
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let value = try? await item(provider, type: UTType.url.identifier) {
                if let url = value as? URL, !url.isFileURL { fallbackURL = url }
                else if let text = value as? String { fallbackURL = URL(string: text) }
            }
            if fallbackText.isEmpty, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let value = try? await item(provider, type: UTType.plainText.identifier) {
                if let text = value as? String { fallbackText = text }
                else if let data = value as? Data, data.count <= URLReader.maximumBytes {
                    fallbackText = String(data: data, encoding: .utf8) ?? ""
                }
            }
        }
        if var safariInput {
            safariInput.attachments = sharedAttachments
            return safariInput
        }
        if !sharedAttachments.isEmpty {
            var input = fallbackText.isEmpty ? ReadingInput() : ReadingInput.from(text: fallbackText)
            input.url = fallbackURL ?? input.url
            input.attachments = sharedAttachments
            if containsPDF { input.title = sharedAttachments.first { $0.mimeType == "application/pdf" }?.fileName ?? "" }
            return input
        }
        if !fallbackText.isEmpty {
            var input = ReadingInput.from(text: fallbackText)
            input.url = fallbackURL ?? input.url
            return input
        }
        if let fallbackURL { return ReadingInput(url: fallbackURL) }
        // Some hosts supply text directly on NSExtensionItem instead of an attachment.
        if let text = items.compactMap(\.attributedContentText?.string).first, !text.isEmpty {
            return ReadingInput.from(text: text)
        }
        throw SystemEntryError.invalidInput
    }

    private static func loadSharedPDF(from provider: NSItemProvider) async throws -> MessageAttachment {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url, url.isFileURL else { throw SystemEntryError.invalidInput }
                    let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard info.isRegularFile == true, info.isSymbolicLink == false, let count = info.fileSize,
                          count > 0, count <= maximumSharedPDFBytes else { throw SystemEntryError.pdfLimit }
                    // This temporary file is valid only inside the provider callback.
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: maximumSharedPDFBytes + 1) ?? Data()
                    guard data.count == count, data.count <= maximumSharedPDFBytes else { throw SystemEntryError.pdfLimit }
                    guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw SystemEntryError.invalidInput }
                    let name = suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
                    let stem = String((((name as NSString).lastPathComponent as NSString).deletingPathExtension).prefix(240))
                    let filename = (stem.isEmpty ? "Document" : stem) + ".pdf"
                    continuation.resume(returning: MessageAttachment(kind: .document, fileName: filename, mimeType: "application/pdf",
                                                               dataBase64: data.base64EncodedString(), byteSize: data.count, sendOriginalPDF: true))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func loadSharedImage(from provider: NSItemProvider) async throws -> MessageAttachment? {
        let maxDimension = 1280
        guard let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }),
              let image = await downsampleViaFileRepresentation(provider, identifier: identifier, maxPixelSize: maxDimension)
        else { return nil }
        try Task.checkCancellation()
        // Keep each shared image compact so 2 attachments + text stay comfortably within receipt bounds.
        var quality: CGFloat = 0.78
        var jpeg = image.jpegData(compressionQuality: quality)
        while let current = jpeg, current.count > 1_200_000, quality > 0.35 {
            quality -= 0.15
            jpeg = image.jpegData(compressionQuality: quality)
        }
        guard let finalJPEG = jpeg, finalJPEG.count <= 2_000_000 else { return nil }
        return MessageAttachment(
            kind: .image,
            fileName: "shared-image.jpg",
            mimeType: "image/jpeg",
            dataBase64: finalJPEG.base64EncodedString(),
            extractedText: nil,
            byteSize: finalJPEG.count
        )
    }

    private static func downsampleViaFileRepresentation(_ provider: NSItemProvider, identifier: String, maxPixelSize: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                guard error == nil, let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = autoreleasepool { downsampleImage(at: url, maxPixelSize: maxPixelSize) }
                continuation.resume(returning: image)
            }
        }
    }

    static func downsampleImage(at url: URL, maxPixelSize: Int) -> UIImage? {
        guard url.isFileURL, (1...1_280).contains(maxPixelSize),
              let file = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              file.isRegularFile == true, file.isSymbolicLink == false,
              let size = file.fileSize, (1...maximumSharedImageFileBytes).contains(size),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              cgImage.width <= maxPixelSize, cgImage.height <= maxPixelSize,
              cgImage.bytesPerRow <= (16 * 1024 * 1024) / max(1, cgImage.height) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func item(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: SystemEntryError.invalidInput) }
            }
        }
    }
}
