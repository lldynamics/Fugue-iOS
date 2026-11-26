import Foundation
import ImageIO
import UIKit

enum MessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

enum AttachmentKind: String, Codable {
    case image
    case document
}

struct MessageAttachment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: AttachmentKind
    var fileName: String
    var mimeType: String
    var dataBase64: String?
    var extractedText: String?
    var byteSize: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    private nonisolated(unsafe) static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 24
        return cache
    }()

    private static let maximumEncodedImageBytes = 20 * 1024 * 1024

    private static func boundedImageSource(_ base64: String) -> CGImageSource? {
        guard base64.utf8.count <= maximumEncodedImageBytes,
              let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height else { return nil }
        return source
    }

    var withBoundedImagePayload: Self {
        guard kind == .image, let base64 = dataBase64,
              Self.boundedImageSource(base64) == nil else { return self }
        var sanitized = self
        sanitized.dataBase64 = nil
        return sanitized
    }

    var cachedImage: UIImage? {
        guard kind == .image, let b64 = dataBase64, b64.utf8.count <= Self.maximumEncodedImageBytes else { return nil }
        let key = "\(id.uuidString):\(byteSize):\(b64.utf8.count):\(b64.prefix(16)):\(b64.suffix(16))" as NSString
        if let hit = Self.imageCache.object(forKey: key) {
            return hit
        }
        guard let source = Self.boundedImageSource(b64),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        Self.imageCache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}

