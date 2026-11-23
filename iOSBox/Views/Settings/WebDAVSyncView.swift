import SwiftUI
import SwiftData

struct WebDAVSyncView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var preferences = AppPreferences.shared
    @State private var coordinator = WebDAVAutoSyncCoordinator.shared

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remotePath = "Fugue/fugue-sync.enc.json"
    @State private var syncPassphrase = ""

    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var showClearConfirm = false

    private var canAuthenticate: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }

    private var canSyncEncrypted: Bool {
        canAuthenticate && EncryptedBackupService.isValidExportPassword(syncPassphrase)
    }

    private var activeBusy: Bool {
        isBusy || coordinator.isSyncing
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
                Toggle("开启自动静默同步", isOn: Binding(
                    get: { preferences.webDAVAutoSyncEnabled },
                    set: { enabled in
                        if enabled { saveConfig() }
                        preferences.webDAVAutoSyncEnabled = enabled
                    }
                ))
                .disabled(!canSyncEncrypted || activeBusy)

                if preferences.webDAVAutoSyncEnabled {
                    Picker("同步最小间隔", selection: $preferences.webDAVAutoSyncIntervalMinutes) {
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                }
            } header: {
                Text("自动无感同步")
            } footer: {
                Text("开启后，进入或离开「夜奔」且超过最小间隔时会自动比对云端时间戳：若有新内容先安全合并，再按需上传本机改动，不会覆盖另一台设备的记录。")
            }

            Section {
                Button {
                    saveConfig()
                    statusMessage = String(localized: "已安全保存 WebDAV 配置与凭据。")
                    statusIsError = false
                } label: {
                    Label("保存配置", systemImage: "checkmark.shield")
                }
                .disabled(activeBusy)

                Button {
                    Task { await runTestConnection() }
                } label: {
                    Label("测试连接", systemImage: "antenna.radiowaves.left.and.right")
                }
                .disabled(!canAuthenticate || activeBusy)

                Button {
                    Task { await runCheckRemoteStatus() }
                } label: {
                    Label("检查云端备份状态", systemImage: "arrow.triangle.2.circlepath.icloud")
                }
                .disabled(!canAuthenticate || activeBusy)

                Button {
                    Task { await runSmartBidirectionalSync() }
                } label: {
                    Label("智能双向同步", systemImage: "icloud.and.arrow.up.and.down")
                }
                .disabled(!canSyncEncrypted || activeBusy || !PersistenceController.canCommitUserData(in: modelContext))

                Button {
                    Task { await runEncryptedUpload() }
                } label: {
                    Label("加密上传到云端", systemImage: "icloud.and.arrow.up")
                }
                .disabled(!canSyncEncrypted || activeBusy || !PersistenceController.canCommitUserData(in: modelContext))

                Button {
                    Task { await runEncryptedDownloadAndMerge() }
                } label: {
                    Label("从云端拉取并合并", systemImage: "icloud.and.arrow.down")
                }
                .disabled(!canSyncEncrypted || activeBusy || !PersistenceController.canCommitUserData(in: modelContext))
            } header: {
                Text("同步操作")
            }

            if activeBusy
                || statusMessage != nil
                || coordinator.remoteMetadata != nil
                || !preferences.webDAVLastAutoSyncSummary.isEmpty
                || preferences.webDAVLastSyncAt != nil {
                Section("状态") {
                    if activeBusy {
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
                    } else if let autoError = coordinator.lastSyncError, !autoError.isEmpty {
                        Text(autoError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if !preferences.webDAVLastAutoSyncSummary.isEmpty {
                        Text(preferences.webDAVLastAutoSyncSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let meta = coordinator.remoteMetadata {
                        remoteStatusRows(meta)
                    }

                    if let lastSync = preferences.webDAVLastSyncAt {
                        LabeledContent("上次同步") {
                            Text(lastSync, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                }
            }

            if !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !password.isEmpty || !syncPassphrase.isEmpty {
                Section {
                    Button("清除本地 WebDAV 凭据", role: .destructive) {
                        showClearConfirm = true
                    }
                    .disabled(activeBusy)
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
        .alert("确认清除 WebDAV 配置？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清除", role: .destructive) {
                clearAllCredentials()
            }
        } message: {
            Text("将删除本地保存的 WebDAV 地址、账号及钥匙串中的密码和同步加密密钥，不会影响云端已有文件。")
        }
    }

    @ViewBuilder
    private func remoteStatusRows(_ meta: WebDAVRemoteMetadata) -> some View {
        if !meta.exists {
            LabeledContent("云端备份") {
                Text("云端暂无备份")
                    .foregroundStyle(.secondary)
            }
        } else {
            let remoteNewer = WebDAVAutoSyncPolicy.isRemoteNewer(
                remote: meta,
                knownETag: preferences.webDAVLastRemoteETag,
                knownModifiedAt: preferences.webDAVLastRemoteModifiedAt
            )
            LabeledContent("云端比对") {
                Text(remoteNewer ? String(localized: "云端有更新") : String(localized: "与云端一致"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(remoteNewer ? .orange : .green)
            }
            if let remoteDate = meta.lastModified {
                LabeledContent("云端修改时间") {
                    Text(remoteDate, format: .dateTime.year().month().day().hour().minute())
                }
            }
            if let size = meta.contentLength, size > 0 {
                LabeledContent("云端文件大小") {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
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

    private func clearAllCredentials() {
        serverURL = ""
        username = ""
        password = ""
        syncPassphrase = ""
        remotePath = "Fugue/fugue-sync.enc.json"
        preferences.webDAVServerURL = ""
        preferences.webDAVUsername = ""
        preferences.webDAVRemotePath = "Fugue/fugue-sync.enc.json"
        KeychainService.shared.deleteSecret(account: WebDAVSyncService.webDAVPasswordAccount)
        KeychainService.shared.deleteSecret(account: WebDAVSyncService.webDAVPassphraseAccount)
        coordinator.clearCachedState(preferences: preferences)
        statusIsError = false
        statusMessage = String(localized: "已清除本地 WebDAV 凭据与同步状态。")
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

    private func runCheckRemoteStatus() async {
        saveConfig()
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        if let meta = await coordinator.checkRemoteStatus(preferences: preferences) {
            statusIsError = false
            statusMessage = meta.exists
                ? String(localized: "已获取云端加密备份信息。")
                : String(localized: "云端尚未找到该同步文件。")
        } else {
            statusIsError = true
            statusMessage = coordinator.lastSyncError ?? String(localized: "检查云端状态失败。")
        }
    }

    private func runSmartBidirectionalSync() async {
        saveConfig()
        statusMessage = nil
        await coordinator.syncIfNeeded(trigger: .manualSmart, context: modelContext, preferences: preferences)
        if let err = coordinator.lastSyncError, !err.isEmpty {
            statusIsError = true
            statusMessage = err
        } else {
            statusIsError = false
            statusMessage = coordinator.lastStatusMessage ?? String(localized: "智能双向同步已完成。")
        }
    }

    private func runEncryptedUpload() async {
        saveConfig()
        isBusy = true
        statusMessage = nil
        defer { isBusy = false }
        do {
            let payload = try EncryptedBackupService.makeExportPayload(context: modelContext)
            let pass = syncPassphrase
            let encryptedData = try await Task.detached(priority: .userInitiated) {
                try EncryptedBackupService.encryptPayload(payload, password: pass)
            }.value
            let putMeta = try await WebDAVSyncService.uploadEncryptedData(
                encryptedData,
                serverURL: preferences.webDAVServerURL,
                remotePath: preferences.webDAVRemotePath,
                username: preferences.webDAVUsername,
                password: password
            )
            var finalMeta = putMeta
            if finalMeta.etag == nil && finalMeta.lastModified == nil {
                finalMeta = (try? await WebDAVSyncService.fetchRemoteMetadata(
                    serverURL: preferences.webDAVServerURL,
                    remotePath: preferences.webDAVRemotePath,
                    username: preferences.webDAVUsername,
                    password: password
                )) ?? putMeta
            }
            coordinator.recordSyncedRemoteMetadata(finalMeta, preferences: preferences)
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
            let meta = try? await WebDAVSyncService.fetchRemoteMetadata(
                serverURL: preferences.webDAVServerURL,
                remotePath: preferences.webDAVRemotePath,
                username: preferences.webDAVUsername,
                password: password
            )
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
            if let meta, meta.exists {
                coordinator.recordSyncedRemoteMetadata(meta, preferences: preferences)
            } else {
                preferences.webDAVLastSyncAt = Date()
            }
            WidgetSnapshotService.shared.sync(context: modelContext, forceReload: true)
            statusIsError = summary.hasWarnings
            statusMessage = "\(summary.title)：\(summary.description)"
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
