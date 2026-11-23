import Foundation
import LocalAuthentication
import Observation
import SwiftUI

enum BiometryKind: Equatable, Sendable {
    case faceID
    case touchID
    case opticID
    case passcodeOnly

    var displayName: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .passcodeOnly: return String(localized: "设备密码")
        }
    }

    var systemImage: String {
        switch self {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .passcodeOnly: return "lock.fill"
        }
    }
}

@MainActor
@Observable
final class AppLockController {
    static let shared = AppLockController()

    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    private(set) var isPrivacyShieldVisible = false
    var lastError: String?

    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var didCancelCurrentLock = false
    @ObservationIgnored private var suppressNextInactiveShield = false
    @ObservationIgnored private var suppressResetTask: Task<Void, Never>?

    var biometryKind: BiometryKind {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return .passcodeOnly
        @unknown default: return .passcodeOnly
        }
    }

    static func canAuthenticateDeviceOwner() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func shouldLock(
        lockEnabled: Bool,
        backgroundedAt: Date?,
        now: Date,
        graceSeconds: TimeInterval
    ) -> Bool {
        guard lockEnabled else { return false }
        guard let backgroundedAt else { return true }
        return now.timeIntervalSince(backgroundedAt) >= max(0, graceSeconds)
    }

    func handleLaunch(preferences suppliedPreferences: AppPreferences? = nil) {
        let preferences = suppliedPreferences ?? .shared
        guard preferences.appLockEnabled else {
            isLocked = false
            isPrivacyShieldVisible = false
            didCancelCurrentLock = false
            return
        }
        isLocked = true
        isPrivacyShieldVisible = true
        didCancelCurrentLock = false
        lastError = nil
    }

    func handleScenePhaseChange(
        _ newPhase: ScenePhase,
        preferences suppliedPreferences: AppPreferences? = nil,
        now: Date = Date(),
        autoAuthenticate: Bool = true
    ) {
        let preferences = suppliedPreferences ?? .shared
        switch newPhase {
        case .inactive:
            if !suppressNextInactiveShield && (preferences.appLockEnabled || preferences.privacyBlurOnBackground) {
                isPrivacyShieldVisible = true
            }

        case .background:
            if preferences.appLockEnabled {
                if backgroundedAt == nil && !isLocked {
                    backgroundedAt = now
                }
                didCancelCurrentLock = false
                isPrivacyShieldVisible = true
            } else if preferences.privacyBlurOnBackground {
                isPrivacyShieldVisible = true
            }

        case .active:
            if preferences.appLockEnabled {
                if !isLocked,
                   let backgroundedAt,
                   Self.shouldLock(
                       lockEnabled: true,
                       backgroundedAt: backgroundedAt,
                       now: now,
                       graceSeconds: TimeInterval(preferences.appLockGracePeriod.rawValue)
                   ) {
                    isLocked = true
                }
                if isLocked {
                    isPrivacyShieldVisible = true
                    if autoAuthenticate && !isAuthenticating && !didCancelCurrentLock {
                        Task { @MainActor [weak self] in
                            _ = await self?.authenticate()
                        }
                    }
                } else {
                    backgroundedAt = nil
                    isPrivacyShieldVisible = false
                }
            } else {
                isLocked = false
                backgroundedAt = nil
                isPrivacyShieldVisible = false
                didCancelCurrentLock = false
            }

        @unknown default:
            break
        }
    }

    func lockNow() {
        isLocked = true
        isPrivacyShieldVisible = true
        didCancelCurrentLock = true
        lastError = nil
    }

    @discardableResult
    func authenticate(
        reason: String? = nil,
        authenticator: ((String) async throws -> Bool)? = nil
    ) async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        suppressResetTask?.cancel()
        suppressNextInactiveShield = true
        lastError = nil

        let usesCustomAuthenticator = authenticator != nil
        let resolvedReason = reason ?? String(localized: "解锁「夜奔」以查看你的私人对话与记忆")

        defer {
            isAuthenticating = false
            if usesCustomAuthenticator {
                suppressNextInactiveShield = false
            } else {
                suppressResetTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    self?.suppressNextInactiveShield = false
                }
            }
        }

        do {
            let success: Bool
            if let authenticator {
                success = try await authenticator(resolvedReason)
            } else {
                success = try await Self.evaluateDeviceOwner(reason: resolvedReason)
            }

            if success {
                isLocked = false
                isPrivacyShieldVisible = false
                backgroundedAt = nil
                didCancelCurrentLock = false
                lastError = nil
                return true
            } else {
                didCancelCurrentLock = true
                lastError = String(localized: "验证未通过，请重试。")
                return false
            }
        } catch let laError as LAError {
            didCancelCurrentLock = true
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel:
                lastError = String(localized: "身份验证已取消，轻点下方按钮重试。")
            default:
                lastError = laError.localizedDescription
            }
            return false
        } catch {
            didCancelCurrentLock = true
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setLockEnabled(
        _ enabled: Bool,
        preferences suppliedPreferences: AppPreferences? = nil,
        authenticator: ((String) async throws -> Bool)? = nil
    ) async -> Bool {
        let preferences = suppliedPreferences ?? .shared
        if enabled {
            let ok = await authenticate(
                reason: String(localized: "验证身份以开启「夜奔」隐私锁"),
                authenticator: authenticator
            )
            if ok {
                preferences.appLockEnabled = true
                isLocked = false
                isPrivacyShieldVisible = false
                backgroundedAt = nil
            }
            return ok
        } else {
            let ok = await authenticate(
                reason: String(localized: "验证身份以关闭「夜奔」隐私锁"),
                authenticator: authenticator
            )
            if ok {
                preferences.appLockEnabled = false
                isLocked = false
                isPrivacyShieldVisible = false
                backgroundedAt = nil
                didCancelCurrentLock = false
                lastError = nil
            }
            return ok
        }
    }

    func resetForTesting() {
        suppressResetTask?.cancel()
        isLocked = false
        isAuthenticating = false
        isPrivacyShieldVisible = false
        lastError = nil
        backgroundedAt = nil
        didCancelCurrentLock = false
        suppressNextInactiveShield = false
    }

    private static func evaluateDeviceOwner(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "使用设备密码")
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}
