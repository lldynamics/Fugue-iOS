import SwiftUI

struct PrivacyLockSettingsView: View {
    @State private var preferences = AppPreferences.shared
    @State private var lockController = AppLockController.shared

    private var canUseDeviceAuth: Bool {
        AppLockController.canAuthenticateDeviceOwner()
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "开启 \(lockController.biometryKind.displayName) 应用锁",
                    isOn: Binding(
                        get: { preferences.appLockEnabled },
                        set: { enabled in
                            Task {
                                _ = await lockController.setLockEnabled(enabled)
                            }
                        }
                    )
                )
                .disabled(lockController.isAuthenticating || !canUseDeviceAuth)

                if preferences.appLockEnabled {
                    Picker("切后台后自动锁定", selection: $preferences.appLockGracePeriod) {
                        ForEach(AppPreferences.AppLockGracePeriod.allCases) { period in
                            Text(period.label).tag(period)
                        }
                    }

                    Button {
                        lockController.lockNow()
                    } label: {
                        Label("立即锁定应用", systemImage: "lock.fill")
                    }
                }

                if !canUseDeviceAuth {
                    Text("当前设备未设置密码或生物识别，请先在系统「设置」中配置锁屏密码。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = lockController.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("应用锁")
            } footer: {
                Text("开启后，冷启动或切回「夜奔」超过锁定延迟时需通过系统验证，防止他人拿起手机直接翻阅敏感对话。")
            }

            Section {
                Toggle(
                    "切后台时模糊内容防窥",
                    isOn: preferences.appLockEnabled ? .constant(true) : $preferences.privacyBlurOnBackground
                )
                .disabled(preferences.appLockEnabled)
            } header: {
                Text("多任务防窥")
            } footer: {
                Text("开启后，进入系统多任务切换界面时将自动以毛玻璃遮挡当前页面；启用应用锁时防窥遮罩会始终开启。")
            }

            Section("安全说明") {
                Text("生物识别与设备密码验证完全由 iOS 本地安全隔区（Secure Enclave）完成，应用本身不会读取或保存你的面部、指纹或锁屏密码数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("隐私锁与防窥遮罩")
        .navigationBarTitleDisplayMode(.inline)
    }
}
