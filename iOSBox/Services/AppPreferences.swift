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

    enum AppLockGracePeriod: Int, CaseIterable, Identifiable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .immediately: return String(localized: "立即锁定")
            case .oneMinute: return String(localized: "1 分钟后")
            case .fiveMinutes: return String(localized: "5 分钟后")
            case .fifteenMinutes: return String(localized: "15 分钟后")
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
        static let monthlyBudgetLimit = "iosbox.pref.monthlyBudgetLimit"
        static let monthlyBudgetCurrency = "iosbox.pref.monthlyBudgetCurrency"
        static let monthlyBudgetAlertRatio = "iosbox.pref.monthlyBudgetAlertRatio"
        static let providerPricingMultipliers = "iosbox.pref.providerPricingMultipliers"
        static let webDAVServerURL = "iosbox.pref.webDAVServerURL"
        static let webDAVUsername = "iosbox.pref.webDAVUsername"
        static let webDAVRemotePath = "iosbox.pref.webDAVRemotePath"
        static let webDAVLastSyncEpoch = "iosbox.pref.webDAVLastSyncEpoch"
        static let webDAVAutoSyncEnabled = "iosbox.pref.webDAVAutoSyncEnabled"
        static let webDAVAutoSyncIntervalMinutes = "iosbox.pref.webDAVAutoSyncIntervalMinutes"
        static let webDAVLastRemoteETag = "iosbox.pref.webDAVLastRemoteETag"
        static let webDAVLastRemoteModifiedEpoch = "iosbox.pref.webDAVLastRemoteModifiedEpoch"
        static let webDAVLastAutoSyncSummary = "iosbox.pref.webDAVLastAutoSyncSummary"
        static let appLockEnabled = "iosbox.pref.appLockEnabled"
        static let appLockGraceSeconds = "iosbox.pref.appLockGraceSeconds"
        static let privacyBlurOnBackground = "iosbox.pref.privacyBlurOnBackground"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var simpleDailyMode: Bool {
        didSet { defaults.set(simpleDailyMode, forKey: Keys.simpleDailyMode) }
    }

    var monthlyBudgetLimit: Double {
        didSet {
            let clean = (monthlyBudgetLimit.isFinite && monthlyBudgetLimit > 0) ? monthlyBudgetLimit : 0
            defaults.set(clean, forKey: Keys.monthlyBudgetLimit)
        }
    }

    var monthlyBudgetCurrency: String {
        didSet {
            let clean = monthlyBudgetCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(clean.isEmpty ? "USD" : clean, forKey: Keys.monthlyBudgetCurrency)
        }
    }

    var monthlyBudgetAlertRatio: Double {
        didSet {
            let clean = min(max(monthlyBudgetAlertRatio.isFinite ? monthlyBudgetAlertRatio : 0.8, 0.5), 0.95)
            defaults.set(clean, forKey: Keys.monthlyBudgetAlertRatio)
        }
    }

    var providerPricingMultipliers: [String: Double] {
        didSet {
            if let data = try? JSONEncoder().encode(providerPricingMultipliers) {
                defaults.set(data, forKey: Keys.providerPricingMultipliers)
            }
        }
    }

    var webDAVServerURL: String {
        didSet { defaults.set(webDAVServerURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.webDAVServerURL) }
    }

    var webDAVUsername: String {
        didSet { defaults.set(webDAVUsername.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.webDAVUsername) }
    }

    var webDAVRemotePath: String {
        didSet {
            let clean = webDAVRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(clean.isEmpty ? "Fugue/fugue-sync.enc.json" : clean, forKey: Keys.webDAVRemotePath)
        }
    }

    var webDAVLastSyncAt: Date? {
        didSet {
            if let date = webDAVLastSyncAt {
                defaults.set(date.timeIntervalSince1970, forKey: Keys.webDAVLastSyncEpoch)
            } else {
                defaults.removeObject(forKey: Keys.webDAVLastSyncEpoch)
            }
        }
    }

    static let validWebDAVAutoSyncIntervals = [5, 15, 30, 60]

    static func sanitizedWebDAVSyncInterval(_ minutes: Int) -> Int {
        validWebDAVAutoSyncIntervals.contains(minutes) ? minutes : 15
    }

    var webDAVAutoSyncEnabled: Bool {
        didSet { defaults.set(webDAVAutoSyncEnabled, forKey: Keys.webDAVAutoSyncEnabled) }
    }

    var webDAVAutoSyncIntervalMinutes: Int {
        didSet {
            let clean = Self.sanitizedWebDAVSyncInterval(webDAVAutoSyncIntervalMinutes)
            if clean != webDAVAutoSyncIntervalMinutes {
                webDAVAutoSyncIntervalMinutes = clean
            }
            defaults.set(clean, forKey: Keys.webDAVAutoSyncIntervalMinutes)
        }
    }

    var webDAVLastRemoteETag: String {
        didSet { defaults.set(webDAVLastRemoteETag, forKey: Keys.webDAVLastRemoteETag) }
    }

    var webDAVLastRemoteModifiedAt: Date? {
        didSet {
            if let date = webDAVLastRemoteModifiedAt {
                defaults.set(date.timeIntervalSince1970, forKey: Keys.webDAVLastRemoteModifiedEpoch)
            } else {
                defaults.removeObject(forKey: Keys.webDAVLastRemoteModifiedEpoch)
            }
        }
    }

    var webDAVLastAutoSyncSummary: String {
        didSet { defaults.set(webDAVLastAutoSyncSummary, forKey: Keys.webDAVLastAutoSyncSummary) }
    }

    var appLockEnabled: Bool {
        didSet { defaults.set(appLockEnabled, forKey: Keys.appLockEnabled) }
    }

    var appLockGracePeriod: AppLockGracePeriod {
        didSet { defaults.set(appLockGracePeriod.rawValue, forKey: Keys.appLockGraceSeconds) }
    }

    var privacyBlurOnBackground: Bool {
        didSet { defaults.set(privacyBlurOnBackground, forKey: Keys.privacyBlurOnBackground) }
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
        let storedBudget = defaults.double(forKey: Keys.monthlyBudgetLimit)
        self.monthlyBudgetLimit = (storedBudget.isFinite && storedBudget > 0) ? storedBudget : 0
        let storedCurrency = defaults.string(forKey: Keys.monthlyBudgetCurrency)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.monthlyBudgetCurrency = storedCurrency.isEmpty ? "USD" : storedCurrency
        let storedAlert = defaults.double(forKey: Keys.monthlyBudgetAlertRatio)
        self.monthlyBudgetAlertRatio = (storedAlert.isFinite && storedAlert >= 0.5 && storedAlert <= 0.95) ? storedAlert : 0.8
        if let multData = defaults.data(forKey: Keys.providerPricingMultipliers),
           let decodedMult = try? JSONDecoder().decode([String: Double].self, from: multData) {
            self.providerPricingMultipliers = decodedMult
        } else {
            self.providerPricingMultipliers = [:]
        }
        self.webDAVServerURL = defaults.string(forKey: Keys.webDAVServerURL) ?? ""
        self.webDAVUsername = defaults.string(forKey: Keys.webDAVUsername) ?? ""
        let storedRemotePath = defaults.string(forKey: Keys.webDAVRemotePath)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.webDAVRemotePath = storedRemotePath.isEmpty ? "Fugue/fugue-sync.enc.json" : storedRemotePath
        let lastSyncEpoch = defaults.double(forKey: Keys.webDAVLastSyncEpoch)
        self.webDAVLastSyncAt = lastSyncEpoch > 0 ? Date(timeIntervalSince1970: lastSyncEpoch) : nil
        self.webDAVAutoSyncEnabled = defaults.bool(forKey: Keys.webDAVAutoSyncEnabled)
        let storedInterval = defaults.integer(forKey: Keys.webDAVAutoSyncIntervalMinutes)
        self.webDAVAutoSyncIntervalMinutes = Self.sanitizedWebDAVSyncInterval(storedInterval)
        self.webDAVLastRemoteETag = defaults.string(forKey: Keys.webDAVLastRemoteETag) ?? ""
        let remoteModEpoch = defaults.double(forKey: Keys.webDAVLastRemoteModifiedEpoch)
        self.webDAVLastRemoteModifiedAt = remoteModEpoch > 0 ? Date(timeIntervalSince1970: remoteModEpoch) : nil
        self.webDAVLastAutoSyncSummary = defaults.string(forKey: Keys.webDAVLastAutoSyncSummary) ?? ""
        self.appLockEnabled = defaults.bool(forKey: Keys.appLockEnabled)
        if let rawGrace = defaults.object(forKey: Keys.appLockGraceSeconds) as? Int,
           let parsedGrace = AppLockGracePeriod(rawValue: rawGrace) {
            self.appLockGracePeriod = parsedGrace
        } else {
            self.appLockGracePeriod = .immediately
        }
        self.privacyBlurOnBackground = defaults.bool(forKey: Keys.privacyBlurOnBackground)
    }

    func pricingMultiplier(for providerID: UUID) -> Double {
        PricingMultiplierPolicy.sanitize(providerPricingMultipliers[providerID.uuidString.uppercased()])
    }

    func setPricingMultiplier(_ value: Double?, for providerID: UUID) {
        let key = providerID.uuidString.uppercased()
        let clean = PricingMultiplierPolicy.sanitize(value)
        var updated = providerPricingMultipliers
        if abs(clean - PricingMultiplierPolicy.defaultMultiplier) < 0.0001 {
            updated.removeValue(forKey: key)
        } else {
            updated[key] = clean
        }
        providerPricingMultipliers = updated
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
