import Foundation
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

    private nonisolated(unsafe) static let imageCache: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    var cachedImage: UIImage? {
        guard kind == .image else { return nil }
        let key = id as NSUUID
        if let hit = Self.imageCache.object(forKey: key) {
            return hit
        }
        guard let b64 = dataBase64,
              let data = Data(base64Encoded: b64),
              let image = UIImage(data: data) else {
            return nil
        }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }
}

