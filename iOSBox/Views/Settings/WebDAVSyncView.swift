import SwiftUI
import SwiftData

struct WebDAVSyncView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var preferences = AppPreferences.shared

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remotePath = "Fugue/fugue-sync.enc.json"
    @State private var syncPassphrase = ""

    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var canAuthenticate: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    private var canSyncEncrypted: Bool {
        canAuthenticate && EncryptedBackupService.isValidExportPassword(syncPassphrase)
    }

    var body: some View {
        Form {
            Section {
                TextField("WebDAV 地址（如 https://dav.jianguoyun.com/dav/）", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("账号 / 用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("WebDAV 密码 / 应用专用密码", text: $password)
                TextField("远端文件路径", text: $remotePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("服务器连接")
            } footer: {
                Text("支持坚果云、Nextcloud、群晖 NAS 等标准 WebDAV。公网仅允许 HTTPS；局域网可使用 HTTP。")
            }

            Section {
                SecureField("同步加密密码（至少 8 位）", text: $syncPassphrase)
            } header: {
                Text("端到端备份加密密码")
            } footer: {
                Text("所有密码均加密保存于 iOS 系统 Keychain，上传云端前使用 AES-GCM + PBKDF2 本地加密，服务器仅看到密文。")
            }

            Section {
                Button {
                    saveConfig()
                    statusMessage = String(localized: "已安全保存 WebDAV 配置与凭据。")
                    statusIsError = false
                } label: {
                    Label("保存配置", systemImage: "checkmark.shield")
                }
                .disabled(isBusy)

                Button {
                    Task { await runTestConnection() }
                } label: {
                    Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!canAuthenticate || isBusy)

                Button {
                    Task { await runEncryptedUpload() }
                } label: {
                    Label("加密上传到云端", systemImage: "icloud.and.arrow.up")
                }
                .disabled(!canSyncEncrypted || isBusy || !PersistenceController.canCommitUserData(in: modelContext))

                Button {
                    Task { await runEncryptedDownloadAndMerge() }
                } label: {
                    Label("从云端拉取并合并", systemImage: "icloud.and.arrow.down")
                }
                .disabled(!canSyncEncrypted || isBusy || !PersistenceController.canCommitUserData(in: modelContext))
            } header: {
                Text("同步操作")
            }

            if isBusy || statusMessage != nil || preferences.webDAVLastSyncAt != nil {
                Section("状态") {
                    if isBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在与 WebDAV 通信…")
                                .font(.subheadline)
                        }
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? .red : .primary)
                    }
                    if let lastSync = preferences.webDAVLastSyncAt {
                        LabeledContent("上次同步") {
                            Text(lastSync, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                }
            }
        }
        .navigationTitle("WebDAV 加密云同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            serverURL = preferences.webDAVServerURL
            username = preferences.webDAVUsername
            remotePath = preferences.webDAVRemotePath
            password = KeychainService.shared.loadSecret(account: WebDAVSyncService.webDAVPasswordAccount)
            syncPassphrase = KeychainService.shared.loadSecret(account: WebDAVSyncService.webDAVPassphraseAccount)
        }
    }

    private func saveConfig() {
        preferences.webDAVServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.webDAVUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.webDAVRemotePath = cleanPath.isEmpty ? "Fugue/fugue-sync.enc.json" : cleanPath
        _ = KeychainService.shared.saveSecret(password, account: WebDAVSyncService.webDAVPasswordAccount)
        _ = KeychainService.shared.saveSecret(syncPassphrase, account: WebDAVSyncService.webDAVPassphraseAccount)
    }

    private func runTestConnection() async {
        saveConfig()
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            try await WebDAVSyncService.testConnection(
                serverURL: preferences.webDAVServerURL,
                username: preferences.webDAVUsername,
                password: password
            )
            statusIsError = false
            statusMessage = String(localized: "WebDAV 连接验证成功，可以开始加密同步。")
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func runEncryptedUpload() async {
        saveConfig()
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let encryptedData = try EncryptedBackupService.exportEncryptedData(
                context: modelContext,
                password: syncPassphrase
            )
            try await WebDAVSyncService.uploadEncryptedData(
                encryptedData,
                serverURL: preferences.webDAVServerURL,
                remotePath: preferences.webDAVRemotePath,
                username: preferences.webDAVUsername,
                password: password
            )
            preferences.webDAVLastSyncAt = Date()
            statusIsError = false
            statusMessage = String(localized: "已加密上传完整备份到 \(preferences.webDAVRemotePath)。")
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func runEncryptedDownloadAndMerge() async {
        saveConfig()
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let data = try await WebDAVSyncService.downloadEncryptedData(
                serverURL: preferences.webDAVServerURL,
                remotePath: preferences.webDAVRemotePath,
                username: preferences.webDAVUsername,
                password: password
            )
            let summary = try await EncryptedBackupService.decryptAndApplyAsync(
                data: data,
                password: syncPassphrase,
                to: modelContext
            )
            preferences.webDAVLastSyncAt = Date()
            statusIsError = summary.hasWarnings
            statusMessage = "\(summary.title)：\(summary.description)"
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
