import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    enum FontScaleOption: Double, CaseIterable, Identifiable {
        case compact = 0.92
        case standard = 1.0
        case comfortable = 1.08
        case large = 1.18

        var id: Double { rawValue }

        var label: String {
            switch self {
            case .compact: return String(localized: "紧凑")
            case .standard: return String(localized: "标准")
            case .comfortable: return String(localized: "舒适")
            case .large: return String(localized: "大字")
            }
        }
    }

    private enum Keys {
        static let fontScale = "iosbox.pref.fontScale"
        static let codeDefaultLineNumbers = "iosbox.pref.codeDefaultLineNumbers"
        static let hapticFeedbackEnabled = "iosbox.pref.hapticFeedbackEnabled"
        static let autoCollapseReasoning = "iosbox.pref.autoCollapseReasoning"
        static let recentModelIDs = "iosbox.pref.recentModelIDs"
        static let customGroupTemplates = "iosbox.pref.customGroupTemplates"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var fontScale: Double {
        didSet { defaults.set(fontScale, forKey: Keys.fontScale) }
    }

    var codeDefaultLineNumbers: Bool {
        didSet { defaults.set(codeDefaultLineNumbers, forKey: Keys.codeDefaultLineNumbers) }
    }

    var hapticFeedbackEnabled: Bool {
        didSet { defaults.set(hapticFeedbackEnabled, forKey: Keys.hapticFeedbackEnabled) }
    }

    var autoCollapseReasoning: Bool {
        didSet { defaults.set(autoCollapseReasoning, forKey: Keys.autoCollapseReasoning) }
    }

    var recentModelIDs: [String] {
        didSet { defaults.set(recentModelIDs, forKey: Keys.recentModelIDs) }
    }

    var customGroupTemplates: [GroupRoomTemplate] {
        didSet {
            if let data = try? JSONEncoder().encode(customGroupTemplates) {
                defaults.set(data, forKey: Keys.customGroupTemplates)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedScale = defaults.double(forKey: Keys.fontScale)
        self.fontScale = storedScale > 0.5 ? storedScale : 1.0
        self.codeDefaultLineNumbers = defaults.bool(forKey: Keys.codeDefaultLineNumbers)
        if defaults.object(forKey: Keys.hapticFeedbackEnabled) == nil {
            self.hapticFeedbackEnabled = true
        } else {
            self.hapticFeedbackEnabled = defaults.bool(forKey: Keys.hapticFeedbackEnabled)
        }
        if defaults.object(forKey: Keys.autoCollapseReasoning) == nil {
            self.autoCollapseReasoning = true
        } else {
            self.autoCollapseReasoning = defaults.bool(forKey: Keys.autoCollapseReasoning)
        }
        self.recentModelIDs = defaults.stringArray(forKey: Keys.recentModelIDs) ?? []
        if let data = defaults.data(forKey: Keys.customGroupTemplates),
           let decoded = try? JSONDecoder().decode([GroupRoomTemplate].self, from: data) {
            self.customGroupTemplates = decoded
        } else {
            self.customGroupTemplates = []
        }
    }

    func recordRecentModel(_ target: ResolvedModelTarget, maxCount: Int = 8) {
        var updated = recentModelIDs.filter { $0 != target.id }
        updated.insert(target.id, at: 0)
        if updated.count > maxCount {
            updated = Array(updated.prefix(maxCount))
        }
        if updated != recentModelIDs {
            recentModelIDs = updated
        }
    }

    func recentTargets(from available: [ResolvedModelTarget]) -> [ResolvedModelTarget] {
        let lookup = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        return recentModelIDs.compactMap { lookup[$0] }
    }

    func addCustomGroupTemplate(_ template: GroupRoomTemplate) {
        customGroupTemplates.insert(template, at: 0)
    }

    func removeCustomGroupTemplate(id: String) {
        customGroupTemplates.removeAll { $0.id == id }
    }

    func triggerLightHaptic() {
        guard hapticFeedbackEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func triggerSelectionHaptic() {
        guard hapticFeedbackEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
