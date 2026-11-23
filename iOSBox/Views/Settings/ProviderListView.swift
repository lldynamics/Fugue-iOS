import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ProviderListView: View {
    private struct BackupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var showAddSheet = false
    @State private var showQuickSetupSheet = false
    @State private var preferences = AppPreferences.shared
    @State private var navigationPath: [ProviderConfig] = []
    @State private var exportedJSONURL: URL?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showImporter = false
    @State private var showExportPasswordAlert = false
    @State private var exportPassword = ""
    @State private var pendingEncryptedImportData: Data?
    @State private var importPassword = ""
    @State private var backupAlert: BackupAlert?
    @State private var providerPendingDeletion: ProviderConfig?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    Button {
                        showQuickSetupSheet = true
                    } label: {
                        Label("从剪贴板一键配 Key 并测通", systemImage: "bolt.fill")
                            .fontWeight(.medium)
                    }

                    ForEach(providers) { provider in
                        NavigationLink(value: provider) {
                            providerRow(provider)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                providerPendingDeletion = provider
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveProviders)
                } header: {
                    Text("API 服务商与自定义中转站")
                } footer: {
                    Text("点进任意服务商可填入 API Key、修改 Base URL，并支持一键拉取 /models 模型列表或手动添加模型。")
                }

                Section("个性化与联网") {
                    Toggle("极简日常模式（界面减法）", isOn: $preferences.simpleDailyMode)
                    NavigationLink { RequestLedgerView() } label: { Label("用量与费用账本", systemImage: "chart.bar.xaxis") }
                    NavigationLink { NewChatDefaultsView() } label: {
                        Label("新对话默认设置", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    NavigationLink { AppearanceSettingsView() } label: { Label("阅读与交互偏好", systemImage: "textformat.size") }
                    NavigationLink { VoiceSettingsView() } label: { Label("语音转写与自然朗读", systemImage: "waveform") }
                    NavigationLink { PersonalMemoryView() } label: { Label("个人长期记忆", systemImage: "brain.head.profile") }
                    NavigationLink { SearchSettingsView() } label: { Label("联网搜索", systemImage: "globe") }
                    NavigationLink { SystemQuickEntryGuideView() } label: { Label("小组件、控制中心与操作按钮", systemImage: "square.grid.2x2") }
                }

                Section {
                    DisclosureGroup("查看支持的 API 协议说明") {
                        ForEach(APIProtocolType.allCases) { proto in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: proto.symbolName)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proto.displayName)
                                        .font(.footnote.weight(.semibold))
                                    Text(proto.subtitle)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 2)
                            .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("协议说明").foregroundStyle(.primary)
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("纯客户端本地直连")
                                .font(.footnote.weight(.semibold))
                            Text("API Key 加密存储于 iOS 系统 Keychain，所有请求由手机直接发往你配置的 API 地址。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await exportBackup() }
                    } label: {
                        if isExporting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在生成备份…")
                            }
                            .font(.subheadline)
                        } else {
                            Label("导出完整备份 (JSON)", systemImage: "square.and.arrow.up")
                                .font(.subheadline)
                        }
                    }
                    .disabled(isExporting || !PersistenceController.canCommitUserData(in: modelContext))

                    Button {
                        exportPassword = ""
                        showExportPasswordAlert = true
                    } label: {
                        Label("导出密码加密备份 (含 API Key)", systemImage: "lock.doc.fill")
                            .font(.subheadline)
                    }
                    .disabled(isExporting || !PersistenceController.canCommitUserData(in: modelContext))

                    if let url = exportedJSONURL {
                        ShareLink(item: url) {
                            Label("点击分享或保存导出的备份文件", systemImage: "arrow.up.doc.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    Button {
                        showImporter = true
                    } label: {
                        if isImporting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在导入…")
                            }
                            .font(.subheadline)
                        } else {
                            Label("从备份文件导入", systemImage: "square.and.arrow.down")
                                .font(.subheadline)
                        }
                    }
                    .disabled(isImporting)

                    NavigationLink {
                        WebDAVSyncView()
                    } label: {
                        Label("WebDAV 加密云同步", systemImage: "icloud.and.arrow.up")
                            .font(.subheadline)
                    }

                    NavigationLink {
                        PrivacyLockSettingsView()
                    } label: {
                        Label("隐私锁与防窥遮罩", systemImage: "faceid")
                            .font(.subheadline)
                    }

                    NavigationLink {
                        AboutAndPrivacyView()
                    } label: {
                        Label("关于与隐私声明", systemImage: "info.circle")
                            .font(.subheadline)
                    }
                } header: {
                    Text("数据与隐私安全")
                } footer: {
                    Text("导入会补回缺失的对话、附件、分支与助学闪卡，并保留本机已有配置。普通备份会省略密钥、敏感请求头及自定义路径地址；使用「加密导出完整备份」时才会以密码加密包含 API Key 与完整连接地址。")
                }
            }
            .navigationTitle("服务商与设置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("添加 API", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: ProviderConfig.self) { provider in
                ProviderDetailView(provider: provider)
            }
            .sheet(isPresented: $showAddSheet) {
                AddProviderSheet { created in
                    navigationPath.append(created)
                }
            }
            .sheet(isPresented: $showQuickSetupSheet) {
                QuickKeySetupSheet()
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    Task { await importBackup(from: url) }
                case .failure(let error):
                    backupAlert = BackupAlert(title: String(localized: "无法打开文件"), message: error.localizedDescription)
                }
            }
            .alert(item: $backupAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
            }
            .alert("设置加密备份密码", isPresented: $showExportPasswordAlert) {
                SecureField("至少 8 位字符的密码", text: $exportPassword)
                Button("取消", role: .cancel) { exportPassword = "" }
                Button("加密生成") {
                    let pwd = exportPassword
                    exportPassword = ""
                    Task { await exportEncryptedBackup(password: pwd) }
                }
            } message: {
                Text("将使用 AES-GCM 加密导出所有对话、服务商自定义地址及 API Key。请设置至少 8 位密码并妥善保管，遗忘后无法恢复。")
            }
            .alert(
                "确认删除服务商？",
                isPresented: Binding(
                    get: { providerPendingDeletion != nil },
                    set: { if !$0 { providerPendingDeletion = nil } }
                ),
                presenting: providerPendingDeletion
            ) { provider in
                Button("取消", role: .cancel) {
                    providerPendingDeletion = nil
                }
                Button("删除并清除密钥", role: .destructive) {
                    try? SystemIntegration.shared.setEnabled(false, provider: provider, context: modelContext)
                    provider.deleteAllSecrets()
                    modelContext.delete(provider)
                    try? modelContext.save()
                    providerPendingDeletion = nil
                }
            } message: { provider in
                Text("将移除「\(provider.name)」及其保存在本机钥匙串中的 API Key 与敏感请求头。")
            }
            .alert(
                "输入备份解密密码",
                isPresented: Binding(
                    get: { pendingEncryptedImportData != nil },
                    set: { if !$0 { pendingEncryptedImportData = nil; importPassword = "" } }
                )
            ) {
                SecureField("加密备份密码", text: $importPassword)
                Button("取消", role: .cancel) {
                    pendingEncryptedImportData = nil
                    importPassword = ""
                }
                Button("解密并导入") {
                    if let data = pendingEncryptedImportData {
                        let pwd = importPassword
                        pendingEncryptedImportData = nil
                        importPassword = ""
                        Task { await applyEncryptedBackup(data: data, password: pwd) }
                    }
                }
            } message: {
                Text("检测到密码加密备份包，输入密码后将自动恢复数据与 API 凭据。")
            }
        }
    }

    // MARK: - Backup

    private func exportBackup() async {
        exportedJSONURL = nil
        isExporting = true
        defer { isExporting = false }
        do {
            // Snapshot on the main actor, encode and write off the main thread.
            let archive = try BackupService.makeArchive(context: modelContext)
            let url = try await Task.detached(priority: .userInitiated) {
                try BackupService.writeToTemporaryFile(BackupService.encode(archive))
            }.value
            exportedJSONURL = url
        } catch {
            backupAlert = BackupAlert(title: String(localized: "导出失败"), message: error.localizedDescription)
        }
    }

    private func exportEncryptedBackup(password: String) async {
        exportedJSONURL = nil
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try await EncryptedBackupService.exportEncryptedTemporaryFile(
                context: modelContext,
                password: password
            )
            exportedJSONURL = url
        } catch {
            backupAlert = BackupAlert(title: String(localized: "导出失败"), message: error.localizedDescription)
        }
    }

    private func importBackup(from url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let (rawData, isEncrypted) = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let fileSize = values.fileSize else { throw BackupError.unrecognizedFormat }
                try BackupService.validateFileSize(fileSize)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: BackupService.maximumFileBytes + 1) ?? Data()
                try BackupService.validateFileSize(data.count)
                return (data, EncryptedBackupService.isEncryptedBackup(data))
            }.value
            if isEncrypted {
                importPassword = ""
                pendingEncryptedImportData = rawData
                return
            }
            let decoded = try await Task.detached(priority: .userInitiated) {
                try BackupService.decode(rawData)
            }.value
            let summary = try BackupService.apply(decoded, to: modelContext)
            backupAlert = BackupAlert(title: summary.title, message: summary.description)
        } catch {
            backupAlert = BackupAlert(title: String(localized: "导入失败"), message: error.localizedDescription)
        }
    }

    private func applyEncryptedBackup(data: Data, password: String) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let summary = try await EncryptedBackupService.decryptAndApplyAsync(
                data: data,
                password: password,
                to: modelContext
            )
            backupAlert = BackupAlert(title: summary.title, message: summary.description)
        } catch {
            backupAlert = BackupAlert(title: String(localized: "导入失败"), message: error.localizedDescription)
        }
    }

    /// Persists the new order; the order also drives the model picker's provider sections.
    private func moveProviders(from source: IndexSet, to destination: Int) {
        var reordered = providers
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, provider) in reordered.enumerated() where provider.sortOrder != index {
            provider.sortOrder = index
        }
        try? modelContext.save()
    }

    @ViewBuilder
    private func providerRow(_ provider: ProviderConfig) -> some View {
        let hasKey = provider.hasAuthentication
        let isLocal = NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)
        let status: LocalizedStringResource = hasKey ? "Key 已配置" : (isLocal ? "本地地址" : "待填 Key")
        let statusColor = hasKey || isLocal ? Color.green : Color.orange
        HStack(spacing: DS.Spacing.md) {
            DSIconTile(
                systemImage: provider.iconSymbol,
                tint: Color(hex: provider.accentHex),
                size: 40,
                cornerRadius: DS.Radius.sm
            )

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(provider.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(provider.isEnabled ? .primary : .secondary)

                    DSBadge(text: provider.protocolType.shortBadge, style: .neutral)
                }

                HStack(spacing: DS.Spacing.sm) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }

                    Text("· 已启用 \(provider.enabledModels.count) 个模型")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
