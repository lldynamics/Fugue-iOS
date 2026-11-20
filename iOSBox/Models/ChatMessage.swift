import Foundation
import SwiftData

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var reasoningContent: String
    /// JSON-encoded attachments (images / PDFs as base64). Large values are stored outside
    /// the SQLite table so conversation lists and queries don't drag megabytes of blobs along.
    @Attribute(.externalStorage) var attachmentsData: Data
    var providerID: UUID?
    var providerName: String
    var modelID: String
    var modelDisplayName: String
    var accentHex: String
    var comparisonGroupID: UUID?
    var isSelectedInGroup: Bool
    var isStreaming: Bool
    var errorMessage: String?
    /// Raw `LLMFinishReason` when the reply ended abnormally (truncated / filtered). Added in schema V2.
    var finishReason: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int?
    var latencyMs: Int?
    var thinkingDurationMs: Int?
    var synthesisSourceDigest: String?
    @Attribute(.externalStorage) var assistanceMetadataData: Data?
    var parentMessageID: UUID?
    @Relationship(deleteRule: .nullify) var latestRequest: RequestRecord?
    var sortIndex: Int
    var createdAt: Date

    var conversation: Conversation?

    @Transient private var cachedAttachmentsSource: Data?
    @Transient private var cachedAttachmentsDecoded: [MessageAttachment]?
    @Transient private var cachedMetadataSource: Data?
    @Transient private var cachedMetadataDecoded: AssistanceMetadata?

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
        let encoded = attachments.isEmpty ? Data() : ((try? JSONEncoder().encode(attachments)) ?? Data())
        self.attachmentsData = encoded
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
        if !encoded.isEmpty {
            self.cachedAttachmentsSource = encoded
            self.cachedAttachmentsDecoded = attachments
        }
    }

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    var attachments: [MessageAttachment] {
        get {
            let raw = attachmentsData
            guard !raw.isEmpty else { return [] }
            if let cached = cachedAttachmentsDecoded, cachedAttachmentsSource == raw {
                return cached
            }
            let decoded = (try? JSONDecoder().decode([MessageAttachment].self, from: raw)) ?? []
            cachedAttachmentsSource = raw
            cachedAttachmentsDecoded = decoded
            return decoded
        }
        set {
            let encoded = newValue.isEmpty ? Data() : ((try? JSONEncoder().encode(newValue)) ?? Data())
            attachmentsData = encoded
            cachedAttachmentsSource = encoded
            cachedAttachmentsDecoded = newValue
        }
    }

    var finishReasonValue: LLMFinishReason? {
        finishReason.flatMap(LLMFinishReason.init(rawValue:))
    }

    var isSynthesis: Bool {
        synthesisSourceDigest != nil
    }

    var assistanceMetadata: AssistanceMetadata {
        get {
            guard let raw = assistanceMetadataData, !raw.isEmpty else {
                return AssistanceMetadata()
            }
            if let cached = cachedMetadataDecoded, cachedMetadataSource == raw {
                return cached
            }
            let decoded = (try? JSONDecoder().decode(AssistanceMetadata.self, from: raw)) ?? AssistanceMetadata()
            cachedMetadataSource = raw
            cachedMetadataDecoded = decoded
            return decoded
        }
        set {
            let encoded = try? JSONEncoder().encode(newValue)
            assistanceMetadataData = encoded
            cachedMetadataSource = encoded
            cachedMetadataDecoded = newValue
        }
    }
}
