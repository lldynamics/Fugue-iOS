import Foundation
import SwiftUI

/// Consolidates all modal sheet routes presented from `ChatDetailView`.
enum ChatActiveSheet: Identifiable, Equatable {
    case options
    case inspector
    case model
    case arena
    case settings
    case groupSetup
    case knowledge
    case originalBook
    case bookProgress
    case bookInvitation
    case search
    case modelSetup
    case audioTranscription
    case synthesis(UUID)
    case shareFile(URL)

    var id: String {
        switch self {
        case .options: return "options"
        case .inspector: return "inspector"
        case .model: return "model"
        case .arena: return "arena"
        case .settings: return "settings"
        case .groupSetup: return "groupSetup"
        case .knowledge: return "knowledge"
        case .originalBook: return "originalBook"
        case .bookProgress: return "bookProgress"
        case .bookInvitation: return "bookInvitation"
        case .search: return "search"
        case .modelSetup: return "modelSetup"
        case .audioTranscription: return "audioTranscription"
        case .synthesis(let groupID): return "synthesis-\(groupID.uuidString)"
        case .shareFile(let url): return "share-\(url.absoluteString)"
        }
    }
}

/// Consolidates informational alerts presented from `ChatDetailView`.
struct ChatAlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Bundles optional message-level action callbacks to replace dozens of closure arguments on `MessageRowView`.
struct MessageRowActions {
    var onOpenCitation: ((ReadingCitation) -> Void)? = nil
    var onSwitchBranch: ((ChatMessage) -> Void)? = nil
    var onSelectRevision: ((Int) -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onRegenerateWithCurrentModel: (() -> Void)? = nil
    var onRegenerateWithOverride: ((ResolvedModelTarget) -> Void)? = nil
    var onContinueGeneration: (() -> Void)? = nil
    var onEditAndResend: ((String) -> Void)? = nil
    var onQuote: ((String) -> Void)? = nil
    var onToggleBookmark: (() -> Void)? = nil
    var onToggleExcludeFromContext: (() -> Void)? = nil
    var onForkConversation: (() -> Void)? = nil
    var onCompareWithModel: ((ResolvedModelTarget) -> Void)? = nil
    var onMentionMember: ((UUID) -> Void)? = nil
    var onDeleteMessage: (() -> Void)? = nil
    var onToggleSpeak: (() -> Void)? = nil
}
