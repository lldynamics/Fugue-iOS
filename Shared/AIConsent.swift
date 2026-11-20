import SwiftUI

enum AppCompliance {
    // Only an explicit confirmation at an outgoing action sets this version.
    static let consentKey = "com.iosbox.aiDataConsentAccepted.v2"
    static let consentDefaults: UserDefaults = {
        let group = SystemEntryLocation.groupID
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil,
           let shared = UserDefaults(suiteName: group) { return shared }
        return .standard
    }()

    static var privacyPolicyURL: URL? {
        resolvedPrivacyPolicyURL(from: Bundle.main.object(forInfoDictionaryKey: "IOSBoxPrivacyPolicyURL") as? String)
    }

    static var supportEmail: String? {
        resolvedSupportEmail(from: Bundle.main.object(forInfoDictionaryKey: "IOSBoxSupportEmail") as? String)
    }

    static func resolvedPrivacyPolicyURL(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              host != "example.com",
              !host.hasSuffix(".example.com"),
              !host.hasSuffix(".invalid") else {
            return nil
        }
        return url
    }

    static func resolvedSupportEmail(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace) else {
            return nil
        }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let domain = parts[1].lowercased()
        guard domain.contains("."),
              domain != "example.com",
              !domain.hasSuffix(".example.com"),
              !domain.hasSuffix(".invalid") else {
            return nil
        }
        return trimmed
    }

    static func hasAcceptedAIDisclosure(defaults: UserDefaults = consentDefaults) -> Bool {
        defaults.bool(forKey: consentKey)
    }

    static func setAcceptedAIDisclosure(_ accepted: Bool, defaults: UserDefaults = consentDefaults) {
        defaults.set(accepted, forKey: consentKey)
    }

    static func requireConsent(defaults: UserDefaults = consentDefaults) throws {
        guard hasAcceptedAIDisclosure(defaults: defaults) else { throw ConsentRequired() }
    }

    struct ConsentRequired: LocalizedError {
        var errorDescription: String? { String(localized: "请先确认接收方并授权发送。") }
    }

    struct RequestChanged: LocalizedError {
        var errorDescription: String? { String(localized: "发送内容或接收方已更改，请重新确认。") }
    }

    /// Endpoints may carry credentials in a path, query or user-info component.
    static func recipient(provider: String, model: String, baseURL: String) -> String {
        let host = URLComponents(string: baseURL)?.host ?? ""
        return host.isEmpty ? "\(provider) · \(model)" : "\(provider) · \(model) (\(host))"
    }
}

@Observable @MainActor
final class AIConsentGate {
    struct Request: Identifiable {
        let id = UUID()
        let recipients: String
        let includesWebSearch: Bool
        let includesTools: Bool
        let isCurrent: () -> Bool
        let send: () -> Void
    }

    var pending: Request?
    var requestChanged = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppCompliance.consentDefaults) { self.defaults = defaults }

    func perform(recipients: [String], search: Bool = false, tools: Bool = false,
                 isCurrent: @escaping () -> Bool = { true }, send: @escaping () -> Void) {
        guard pending == nil else { return }
        if AppCompliance.hasAcceptedAIDisclosure(defaults: defaults) { send(); return }
        var seen = Set<String>()
        pending = Request(recipients: recipients.filter { seen.insert($0).inserted }.joined(separator: "\n"),
                          includesWebSearch: search, includesTools: tools, isCurrent: isCurrent, send: send)
    }

    func approve(_ id: UUID) {
        guard let request = pending, request.id == id else { return }
        guard request.isCurrent() else { requestChanged = true; return }
        pending = nil
        AppCompliance.setAcceptedAIDisclosure(true, defaults: defaults)
        request.send()
    }
}

extension View {
    @MainActor func aiConsentSheet(_ gate: AIConsentGate) -> some View {
        @Bindable var gate = gate
        return sheet(item: $gate.pending) { request in
            AIDataConsentSheet(targetSummary: request.recipients, includesWebSearch: request.includesWebSearch,
                               includesTools: request.includesTools) { gate.approve(request.id) }
                .alert(AppCompliance.RequestChanged().localizedDescription, isPresented: $gate.requestChanged) {
                    Button("好") { gate.pending = nil }
                }
        }
    }
}
