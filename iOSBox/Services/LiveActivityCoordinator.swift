import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()

    private(set) var activeStates: [UUID: IOSBoxGenerationAttributes.ContentState] = [:]
    @ObservationIgnored private var activities: [UUID: Activity<IOSBoxGenerationAttributes>] = [:]
    @ObservationIgnored private var lastUpdateTime: [UUID: ContinuousClock.Instant] = [:]

    func start(
        conversationID: UUID,
        chatTitle: String,
        modeBadge: String,
        speakerOrModel: String,
        phaseText: String,
        totalTurns: Int = 1
    ) {
        let initialState = IOSBoxGenerationAttributes.ContentState(
            speakerOrModel: speakerOrModel,
            phaseText: phaseText,
            completedTurns: 0,
            totalTurns: totalTurns,
            previewSnippet: ""
        )
        if let existing = activities.removeValue(forKey: conversationID) {
            let endContent = ActivityContent(state: initialState, staleDate: nil)
            Task {
                await existing.end(endContent, dismissalPolicy: .immediate)
            }
        }
        activeStates[conversationID] = initialState
        lastUpdateTime[conversationID] = .now

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = IOSBoxGenerationAttributes(
            conversationID: conversationID.uuidString,
            chatTitle: String(chatTitle.prefix(60)),
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
        if let speakerOrModel { current.speakerOrModel = speakerOrModel }
        if let phaseText { current.phaseText = phaseText }
        if let completedTurns { current.completedTurns = completedTurns }
        if let totalTurns { current.totalTurns = max(1, totalTurns) }
        if let previewSnippet {
            current.previewSnippet = String(
                previewSnippet
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .suffix(90)
            )
        }
        activeStates[conversationID] = current
        lastUpdateTime[conversationID] = .now

        if let activity = activities[conversationID] {
            let content = ActivityContent(state: current, staleDate: Date().addingTimeInterval(600))
            Task {
                await activity.update(content)
            }
        }
    }

    func end(conversationID: UUID, finalPhase: String? = nil) {
        var finalState = activeStates.removeValue(forKey: conversationID)
        lastUpdateTime.removeValue(forKey: conversationID)
        if let finalPhase, var st = finalState {
            st.phaseText = finalPhase
            st.completedTurns = st.totalTurns
            finalState = st
        }
        if let activity = activities.removeValue(forKey: conversationID) {
            let stateToPublish = finalState ?? IOSBoxGenerationAttributes.ContentState(
                speakerOrModel: String(localized: "夜奔"),
                phaseText: finalPhase ?? String(localized: "已完成"),
                completedTurns: 1,
                totalTurns: 1
            )
            let content = ActivityContent(state: stateToPublish, staleDate: nil)
            Task {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(12)))
            }
        }
    }
}
