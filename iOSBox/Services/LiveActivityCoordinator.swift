import ActivityKit
import Foundation
import Observation

struct GenerationOutcome {
    let phase: String
    let completedTurns: Int

    init(statuses: [RequestStatus], stopped: Bool) {
        completedTurns = statuses.filter { $0 == .succeeded }.count
        if stopped || statuses.contains(.cancelled) {
            phase = String(localized: "已停止生成")
        } else if !statuses.isEmpty && completedTurns == statuses.count {
            phase = String(localized: "已完成")
        } else if completedTurns > 0 || statuses.contains(.incomplete) {
            phase = String(localized: "部分完成")
        } else {
            phase = String(localized: "生成失败")
        }
    }
}

@MainActor
@Observable
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()
    private static let previewKey = "iosbox.liveActivity.showPreviews"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferences: AppPreferences?
    private(set) var showsPreviews: Bool

    private(set) var activeStates: [UUID: IOSBoxGenerationAttributes.ContentState] = [:]
    @ObservationIgnored private var activities: [UUID: Activity<IOSBoxGenerationAttributes>] = [:]
    @ObservationIgnored private var lastUpdateTime: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var pendingUpdates: [String: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard, preferences: AppPreferences? = nil) {
        self.defaults = defaults
        self.preferences = preferences
        showsPreviews = defaults.bool(forKey: Self.previewKey)
    }

    private var isAppLockActive: Bool {
        (preferences ?? .shared).appLockEnabled
    }

    func setShowsPreviews(_ enabled: Bool) {
        showsPreviews = enabled
        defaults.set(enabled, forKey: Self.previewKey)
        guard !enabled else { return }
        redactActivePreviewStates()
    }

    func handleAppLockChange(lockEnabled: Bool) {
        guard lockEnabled else { return }
        redactActivePreviewStates()
    }

    private func redactActivePreviewStates() {
        for (id, var state) in activeStates where state.presentation == .preview {
            state.hideDetails()
            activeStates[id] = state
            if let activity = activities[id] { publishCurrentState(for: id, to: activity) }
        }
        dismissUntrackedActivities()
    }

    // Dismiss previews left visible by an earlier process or a just-finished turn.
    private func dismissUntrackedActivities(in conversationID: UUID? = nil) {
        let runningIDs = Set(activities.values.map(\.id))
        for activity in Activity<IOSBoxGenerationAttributes>.activities where !runningIDs.contains(activity.id) {
            if let conversationID, activity.attributes.conversationID != conversationID.uuidString { continue }
            endActivity(activity, state: activity.content.state, policy: .immediate)
        }
    }

    func start(
        conversationID: UUID,
        chatTitle: String,
        modeBadge: String,
        speakerOrModel: String,
        phaseText: String,
        totalTurns: Int = 1
    ) {
        var initialState = IOSBoxGenerationAttributes.ContentState(
            speakerOrModel: speakerOrModel,
            phaseText: phaseText,
            completedTurns: 0,
            totalTurns: totalTurns,
            previewSnippet: ""
        )
        let allowPreviews = showsPreviews && !isAppLockActive
        initialState.presentation = allowPreviews ? .preview : .status
        if initialState.presentation == .preview {
            initialState.previewTitle = String(chatTitle.prefix(60))
        } else {
            initialState.hideDetails()
        }
        if let existing = activities.removeValue(forKey: conversationID) {
            endActivity(existing, state: existing.content.state, policy: .immediate)
        }
        activeStates[conversationID] = initialState
        lastUpdateTime[conversationID] = .now

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = IOSBoxGenerationAttributes(
            conversationID: conversationID.uuidString,
            chatTitle: "",
            modeBadge: modeBadge
        )
        do {
            let content = ActivityContent(state: initialState, staleDate: Date().addingTimeInterval(600))
            let activity = try Activity.request(attributes: attrs, content: content, pushType: nil)
            activities[conversationID] = activity
        } catch {
            // Gracefully ignore when Live Activities are disabled by system policy or simulator runtime
        }
    }

    func update(
        conversationID: UUID,
        speakerOrModel: String? = nil,
        phaseText: String? = nil,
        completedTurns: Int? = nil,
        totalTurns: Int? = nil,
        previewSnippet: String? = nil,
        force: Bool = false
    ) {
        guard var current = activeStates[conversationID] else { return }
        if !force, let last = lastUpdateTime[conversationID], last.duration(to: .now) < .milliseconds(1200) {
            return
        }
        if isAppLockActive, current.presentation == .preview {
            current.hideDetails()
        }
        let canExposeDetails = current.presentation == .preview && !isAppLockActive
        if canExposeDetails, let speakerOrModel { current.speakerOrModel = speakerOrModel }
        if let phaseText { current.phaseText = phaseText }
        if let completedTurns { current.completedTurns = completedTurns }
        if let totalTurns { current.totalTurns = max(1, totalTurns) }
        if canExposeDetails, let previewSnippet {
            current.previewSnippet = String(
                previewSnippet.suffix(180)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .suffix(90)
            )
        }
        activeStates[conversationID] = current
        lastUpdateTime[conversationID] = .now

        if let activity = activities[conversationID] {
            publishCurrentState(for: conversationID, to: activity)
        }
    }

    private func publishCurrentState(for conversationID: UUID, to activity: Activity<IOSBoxGenerationAttributes>) {
        let previous = pendingUpdates[activity.id]
        pendingUpdates[activity.id] = Task {
            await previous?.value
            guard activities[conversationID]?.id == activity.id, let current = activeStates[conversationID] else { return }
            await activity.update(ActivityContent(state: current, staleDate: Date().addingTimeInterval(600)))
        }
    }

    private func endActivity(_ activity: Activity<IOSBoxGenerationAttributes>, state: IOSBoxGenerationAttributes.ContentState,
                             policy: ActivityUIDismissalPolicy) {
        let previous = pendingUpdates.removeValue(forKey: activity.id)
        Task {
            await previous?.value
            var summary = state
            summary.hideDetails()
            await activity.end(ActivityContent(state: summary, staleDate: nil), dismissalPolicy: policy)
        }
    }

    @discardableResult
    func end(conversationID: UUID, outcome: GenerationOutcome) -> IOSBoxGenerationAttributes.ContentState? {
        guard var finalState = activeStates.removeValue(forKey: conversationID) else { return nil }
        lastUpdateTime.removeValue(forKey: conversationID)
        finalState.phaseText = outcome.phase
        finalState.completedTurns = min(outcome.completedTurns, finalState.totalTurns)
        if let activity = activities.removeValue(forKey: conversationID) {
            endActivity(activity, state: finalState, policy: .after(Date().addingTimeInterval(12)))
        }
        return finalState
    }
}
