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
        static let accentTheme = "iosbox.pref.accentTheme"
        static let codeDefaultLineNumbers = "iosbox.pref.codeDefaultLineNumbers"
        static let hapticFeedbackEnabled = "iosbox.pref.hapticFeedbackEnabled"
        static let autoCollapseReasoning = "iosbox.pref.autoCollapseReasoning"
        static let defaultTarget = "iosbox.pref.defaultTarget"
        static let defaultAssistant = "iosbox.pref.defaultAssistant"
        static let recentModelIDs = "iosbox.pref.recentModelIDs"
        static let customGroupTemplates = "iosbox.pref.customGroupTemplates"
        static let audioTranscriptionProviderID = "iosbox.pref.audioTranscriptionProviderID"
        static let audioTranscriptionModel = "iosbox.pref.audioTranscriptionModel"
        static let audioTranscriptionLanguage = "iosbox.pref.audioTranscriptionLanguage"
        static let useCloudTTS = "iosbox.pref.useCloudTTS"
        static let cloudTTSProviderID = "iosbox.pref.cloudTTSProviderID"
        static let cloudTTSModel = "iosbox.pref.cloudTTSModel"
        static let cloudTTSVoice = "iosbox.pref.cloudTTSVoice"
        static let simpleDailyMode = "iosbox.pref.simpleDailyMode"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var simpleDailyMode: Bool {
        didSet { defaults.set(simpleDailyMode, forKey: Keys.simpleDailyMode) }
    }

    var fontScale: Double {
        didSet { defaults.set(fontScale, forKey: Keys.fontScale) }
    }

    var accentTheme: DS.AccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: Keys.accentTheme) }
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

    var defaultTargetID: String? {
        didSet { defaults.set(defaultTargetID, forKey: Keys.defaultTarget) }
    }

    var defaultAssistantID: UUID? {
        didSet { defaults.set(defaultAssistantID?.uuidString, forKey: Keys.defaultAssistant) }
    }

    func initialTarget(from ready: [ResolvedModelTarget]) -> ResolvedModelTarget? {
        if let defaultTargetID { return ready.first { $0.id == defaultTargetID } }
        return ready.count == 1 ? ready[0] : nil
    }

    func newChat(providers: [ProviderConfig], presets: [AssistantPreset], arena: Bool = false) -> Conversation {
        let ready = ProviderConfig.readyTargets(in: providers)
        let chat = Conversation(title: Conversation.defaultTitle, isArenaMode: arena && ready.count >= 2,
                                primaryTarget: initialTarget(from: ready), arenaTargets: Array(ready.prefix(2)))
        if let preset = presets.first(where: { $0.id == defaultAssistantID }) { chat.applyPreset(preset) }
        return chat
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

    var audioTranscriptionProviderID: UUID? {
        didSet { defaults.set(audioTranscriptionProviderID?.uuidString, forKey: Keys.audioTranscriptionProviderID) }
    }

    var audioTranscriptionModel: String {
        didSet {
            let clean = audioTranscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(clean.isEmpty ? "whisper-1" : clean, forKey: Keys.audioTranscriptionModel)
        }
    }

    var audioTranscriptionLanguage: String {
        didSet { defaults.set(audioTranscriptionLanguage.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.audioTranscriptionLanguage) }
    }

    var useCloudTTS: Bool {
        didSet { defaults.set(useCloudTTS, forKey: Keys.useCloudTTS) }
    }

    var cloudTTSProviderID: UUID? {
        didSet { defaults.set(cloudTTSProviderID?.uuidString, forKey: Keys.cloudTTSProviderID) }
    }

    var cloudTTSModel: String {
        didSet {
            let clean = cloudTTSModel.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(clean.isEmpty ? "tts-1" : clean, forKey: Keys.cloudTTSModel)
        }
    }

    var cloudTTSVoice: String {
        didSet {
            let clean = cloudTTSVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(clean.isEmpty ? "alloy" : clean, forKey: Keys.cloudTTSVoice)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.defaultTargetID = defaults.string(forKey: Keys.defaultTarget)
        self.defaultAssistantID = defaults.string(forKey: Keys.defaultAssistant).flatMap(UUID.init(uuidString:))
        self.audioTranscriptionProviderID = defaults.string(forKey: Keys.audioTranscriptionProviderID).flatMap(UUID.init(uuidString:))
        let storedASRModel = defaults.string(forKey: Keys.audioTranscriptionModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.audioTranscriptionModel = storedASRModel.isEmpty ? "whisper-1" : storedASRModel
        self.audioTranscriptionLanguage = defaults.string(forKey: Keys.audioTranscriptionLanguage)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.useCloudTTS = defaults.bool(forKey: Keys.useCloudTTS)
        self.cloudTTSProviderID = defaults.string(forKey: Keys.cloudTTSProviderID).flatMap(UUID.init(uuidString:))
        let storedTTSModel = defaults.string(forKey: Keys.cloudTTSModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.cloudTTSModel = storedTTSModel.isEmpty ? "tts-1" : storedTTSModel
        let storedTTSVoice = defaults.string(forKey: Keys.cloudTTSVoice)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.cloudTTSVoice = storedTTSVoice.isEmpty ? "alloy" : storedTTSVoice
        let storedScale = defaults.double(forKey: Keys.fontScale)
        self.fontScale = storedScale > 0.5 ? storedScale : 1.0
        if let rawTheme = defaults.string(forKey: Keys.accentTheme),
           let resolvedTheme = DS.AccentTheme(rawValue: rawTheme) {
            self.accentTheme = resolvedTheme
        } else {
            self.accentTheme = .cobalt
        }
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
        self.simpleDailyMode = defaults.bool(forKey: Keys.simpleDailyMode)
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
