import Foundation
#if canImport(ActivityKit)
import ActivityKit

public struct IOSBoxGenerationAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var speakerOrModel: String
        public var phaseText: String
        public var completedTurns: Int
        public var totalTurns: Int
        public var previewSnippet: String

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
