import Foundation
import SwiftData

enum MessageRole: String, Codable {
    case system
    case user
    case assistant
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
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var reasoningContent: String
    var attachmentsData: Data
    var providerID: UUID?
    var providerName: String
    var modelID: String
    var modelDisplayName: String
    var accentHex: String
    var comparisonGroupID: UUID?
    var isSelectedInGroup: Bool
    var isStreaming: Bool
    var errorMessage: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var latencyMs: Int?
    var thinkingDurationMs: Int?
    var sortIndex: Int
    var createdAt: Date

    var conversation: Conversation?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String = "",
        reasoningContent: String = "",
        attachments: [MessageAttachment] = [],
        target: ResolvedModelTarget? = nil,
        comparisonGroupID: UUID? = nil,
        isSelectedInGroup: Bool = true,
        isStreaming: Bool = false,
        sortIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.reasoningContent = reasoningContent
        self.attachmentsData = (try? JSONEncoder().encode(attachments)) ?? Data()
        self.providerID = target?.providerID
        self.providerName = target?.providerName ?? ""
        self.modelID = target?.modelID ?? ""
        self.modelDisplayName = target?.modelDisplayName ?? ""
        self.accentHex = target?.accentHex ?? "#3F6EF6"
        self.comparisonGroupID = comparisonGroupID
        self.isSelectedInGroup = isSelectedInGroup
        self.isStreaming = isStreaming
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var attachments: [MessageAttachment] {
        get {
            guard !attachmentsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([MessageAttachment].self, from: attachmentsData)) ?? []
        }
        set {
            attachmentsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }
}
