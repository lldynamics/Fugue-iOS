import SwiftUI
import UIKit

@MainActor
final class AppLockWindowPresenter {
    static let shared = AppLockWindowPresenter()
    private var window: UIWindow?

    func update(visible: Bool, controller: AppLockController) {
        if visible {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState != .unattached }) ?? scenes.first else {
                return
            }
            if window == nil || window?.windowScene !== scene {
                let hosting = UIHostingController(rootView: AppLockOverlayView(controller: controller))
                hosting.view.backgroundColor = .clear
                let overlay = UIWindow(windowScene: scene)
                overlay.rootViewController = hosting
                overlay.windowLevel = .alert + 5
                overlay.backgroundColor = .clear
                self.window = overlay
            }
            window?.isHidden = false
            window?.makeKeyAndVisible()
        } else if let window {
            window.isHidden = true
            window.resignKey()
            window.windowScene?.windows.first(where: { $0 !== window && !$0.isHidden })?.makeKey()
        }
    }
}

struct AppLockOverlayView: View {
    var controller: AppLockController

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            if controller.isLocked {
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 82, height: 82)
                        Image(systemName: controller.biometryKind.systemImage)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(spacing: 8) {
                        Text("夜奔已锁定")
                            .font(.title2.bold())
                        Text("使用 \(controller.biometryKind.displayName) 解锁以查看对话与个人记忆")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task {
                            _ = await controller.authenticate()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if controller.isAuthenticating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: controller.biometryKind.systemImage)
                            }
                            Text("用 \(controller.biometryKind.displayName) 解锁")
                                .fontWeight(.semibold)
                        }
                        .frame(minWidth: 200, minHeight: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(controller.isAuthenticating)

                    if let error = controller.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(DS.StatusText.error)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                }
                .padding(28)
                .frame(maxWidth: 340)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("夜奔 · 内容已隐藏")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .zIndex(999)
    }
}
