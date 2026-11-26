import Foundation
#if canImport(ActivityKit)
import ActivityKit

public struct IOSBoxGenerationAttributes: ActivityAttributes {
    public enum Presentation: String, Codable, Sendable {
        case status, preview

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = raw == Self.preview.rawValue ? .preview : .status
        }
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var speakerOrModel: String
        public var phaseText: String
        public var completedTurns: Int
        public var totalTurns: Int
        public var previewSnippet: String
        // Absent on activities written before preview consent was introduced.
        public var presentation: Presentation? = nil
        public var previewTitle: String? = nil

        public var visibleSpeaker: String {
            switch presentation {
            case .preview: return speakerOrModel
            default: return String(localized: "夜奔")
            }
        }

        public var visibleTitle: String? {
            guard presentation == .preview, let previewTitle, !previewTitle.isEmpty else { return nil }
            return previewTitle
        }

        public var visibleSnippet: String? {
            presentation == .preview && !previewSnippet.isEmpty ? previewSnippet : nil
        }

        public mutating func hideDetails() {
            presentation = .status
            speakerOrModel = visibleSpeaker
            previewSnippet = ""
            previewTitle = nil
        }

        public init(
            speakerOrModel: String,
            phaseText: String,
            completedTurns: Int = 0,
            totalTurns: Int = 1,
            previewSnippet: String = ""
        ) {
            self.speakerOrModel = speakerOrModel
            self.phaseText = phaseText
            self.completedTurns = completedTurns
            self.totalTurns = max(1, totalTurns)
            self.previewSnippet = previewSnippet
        }
    }

    public var conversationID: String
    public var chatTitle: String
    public var modeBadge: String

    public init(conversationID: String, chatTitle: String, modeBadge: String) {
        self.conversationID = conversationID
        self.chatTitle = chatTitle
        self.modeBadge = modeBadge
    }
}
#endif
