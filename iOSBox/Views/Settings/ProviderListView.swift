import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ProviderListView: View {
    var onClose: (() -> Void)? = nil

    private struct BackupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum ProbeState: Equatable {
        case testing
        case ok(ttftMs: Int)
        case failed(String)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var showAddSheet = false
    @State private var connectionDraft: ProviderSetupDraft?
    @State private var preferences = AppPreferences.shared
    @State private var navigationPath = NavigationPath()
    @State private var exportedJSONURL: URL?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showImporter = false
    @State private var showExportPasswordAlert = false
    @State private var includeDraftsInBackup = false
    @State private var recoveryPlan: BackupRecoveryPlan?
    @State private var exportPassword = ""
    @State private var pendingEncryptedImportData: Data?
    @State private var importPassword = ""
    @State private var backupAlert: BackupAlert?
    @State private var providerPendingDeletion: ProviderConfig?
    @State private var probeStates: [UUID: ProbeState] = [:]
    @State private var isBatchProbing = false
    @State private var balanceStore = ProviderBalanceStore.shared

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    Button {
                        connectionDraft = ProviderSetupDraft()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                                Text("连接模型").font(.headline)
                                Text("OpenAI 官方、OpenRouter 或其他服务商")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "plus.circle")
                        }
                    }
                    .accessibilityIdentifier("settings.connectModel")
                }

                let accounts = providers.filter { $0.hasAuthentication || !$0.extraAPIKeys.isEmpty || NetworkLocation.isLocalOrPrivate(baseURL: $0.baseURL) }
                let accountIDs = Set(accounts.map(\.id))
                let pending = providers.filter { !accountIDs.contains($0.id) }
                if !accounts.isEmpty {
                    Section {
                        providerRows(accounts)
                    } header: {
                        HStack {
                            Text("已保存的服务商")
                            Spacer()
                            if accounts.contains(where: \.isReadyForChat) {
                                Button {
                                    Task { await probeAllReadyProviders(accounts) }
                                } label: {
                                    HStack(spacing: 4) {
                                        if isBatchProbing {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "bolt.horizontal.circle")
                                        }
                                        Text(isBatchProbing ? String(localized: "巡检中…") : String(localized: "一键测速"))
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled(isBatchProbing)
                            }
                        }
                    }
                }
                if !pending.isEmpty {
                    Section {
                        DisclosureGroup("待配置的服务商（\(pending.count)）") { providerRows(pending) }
                    }
                }

                Section("对话与显示") {
                    NavigationLink { NewChatDefaultsView() } label: {
                        Label("新对话默认设置", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    NavigationLink { AppearanceSettingsView() } label: { Label("阅读与交互偏好", systemImage: "textformat.size") }
                    NavigationLink { VoiceSettingsView() } label: { Label("语音转写与自然朗读", systemImage: "waveform") }
                }

                Section("用量与联网") {
                    NavigationLink { RequestLedgerView() } label: { Label("用量与费用账本", systemImage: "chart.bar.xaxis") }
                    NavigationLink { SearchSettingsView() } label: { Label("联网搜索", systemImage: "globe") }
                }

                Section("高级功能") {
                    NavigationLink { PersonalMemoryView() } label: { Label("个人长期记忆", systemImage: "brain.head.profile") }
                    NavigationLink { KnowledgeSearchSettingsView() } label: { Label("全文检索与知识库索引", systemImage: "magnifyingglass.circle") }
                    NavigationLink { SystemQuickEntryGuideView(onDismissSettings: onClose) } label: { Label("小组件、控制中心与操作按钮", systemImage: "square.grid.2x2") }
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
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(DS.StatusText.success)
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

                    Toggle("加密换机备份包含未发送草稿", isOn: $includeDraftsInBackup)
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
                    Text("导入会补回缺失的对话、附件与分支，并保留本机已有配置。普通备份会省略密钥、敏感请求头及自定义路径地址；使用「加密导出完整备份」时才会以密码加密包含 API Key 与完整连接地址。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Surface.grouped)
            .navigationTitle("服务商与设置")
            .toolbar {
                ToolbarItem(placement: onClose != nil ? .cancellationAction : .topBarLeading) {
                    if let onClose {
                        Button("完成", action: onClose)
                            .tint(.primary)
                    } else if !providers.isEmpty {
                        EditButton()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if onClose != nil && !providers.isEmpty {
                        EditButton()
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("手动添加服务商", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: ProviderConfig.self) { provider in
                ProviderDetailView(provider: provider, correctKey: { connectionDraft = $0 })
            }
            .sheet(isPresented: $showAddSheet) {
                AddProviderSheet { created in
                    navigationPath.append(created)
                }
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
                    let deletedProviderID = provider.id
                    try? SystemIntegration.shared.setEnabled(false, provider: provider, context: modelContext)
                    provider.deleteAllSecrets()
                    modelContext.delete(provider)
                    try? modelContext.save()
                    probeStates.removeValue(forKey: deletedProviderID)
                    if !modelContext.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                        SyncTombstoneStore.shared.recordDeletion(kind: .provider, id: deletedProviderID)
                    }
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
                Button("解密并预览") {
                    if let data = pendingEncryptedImportData {
                        let pwd = importPassword
                        pendingEncryptedImportData = nil
                        importPassword = ""
                        Task { await applyEncryptedBackup(data: data, password: pwd) }
                    }
                }
            } message: {
                Text("输入密码后可以查看备份中的资料并选择要恢复的项目。")
            }
        }
        .sheet(item: $connectionDraft) { draft in
            QuickKeySetupSheet(draft: draft) { provider, _ in
                navigationPath = NavigationPath([provider])
            }
        }
        .sheet(item: $recoveryPlan) { plan in
            BackupRecoverySheet(plan: plan) { selected in
                recoveryPlan = nil
                do {
                    let summary = try plan.apply(selected, in: modelContext)
                    backupAlert = BackupAlert(title: summary.title, message: summary.description)
                } catch {
                    backupAlert = BackupAlert(title: String(localized: "导入失败"), message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Provider Operations

    private func toggleProviderEnabled(_ provider: ProviderConfig) {
        let next = !provider.isEnabled
        provider.isEnabled = next
        if !next {
            try? SystemIntegration.shared.setEnabled(false, provider: provider, context: modelContext)
        }
        try? modelContext.save()
    }

    private func cloneProvider(_ source: ProviderConfig) {
        let baseName = "\(source.name) " + String(localized: "副本")
        var candidateName = baseName
        let existingNames = Set(providers.map(\.name))
        var suffix = 2
        while existingNames.contains(candidateName) {
            candidateName = "\(baseName) \(suffix)"
            suffix += 1
        }
        let nonSecretHeaders = source.customHeaders.filter { !$0.isSecret }
        let cloned = ProviderConfig(
            name: candidateName,
            protocolType: source.protocolType,
            baseURL: source.baseURL,
            iconSymbol: source.iconSymbol,
            accentHex: source.accentHex,
            isEnabled: true,
            sortOrder: Int(Date().timeIntervalSince1970),
            models: source.models,
            customHeaders: nonSecretHeaders,
            notes: source.notes
        )
        if source.idleTimeoutSeconds > 0 {
            cloned.idleTimeoutSeconds = source.idleTimeoutSeconds
        }
        modelContext.insert(cloned)
        do {
            try modelContext.save()
            navigationPath.append(cloned)
        } catch {
            modelContext.delete(cloned)
            cloned.deleteAllSecrets()
        }
    }

    @MainActor
    private func probeSingleProvider(_ provider: ProviderConfig) async {
        guard let spec = provider.enabledModels.first, provider.hasConfiguredChatAPI else { return }
        probeStates[provider.id] = .testing
        do {
            let result = try await LLMClient.pingModel(
                providerName: provider.name,
                protocolType: provider.protocolType,
                baseURL: provider.baseURL,
                apiKey: LLMClient.sanitizedAPIKey(provider.apiKey),
                apiKeys: provider.extraAPIKeys,
                customHeaders: provider.resolvedCustomHeaders,
                modelID: spec.id,
                supportsReasoning: spec.supportsReasoning,
                idleTimeoutSeconds: provider.customIdleTimeout
            )
            probeStates[provider.id] = .ok(ttftMs: result.ttftMs)
        } catch {
            probeStates[provider.id] = .failed(ModelSetup.verificationAdvice(for: error, checkingModel: true))
        }
    }

    @MainActor
    private func probeAllReadyProviders(_ displayed: [ProviderConfig]) async {
        let targets = displayed.filter(\.isReadyForChat)
        guard !targets.isEmpty else { return }
        isBatchProbing = true
        defer { isBatchProbing = false }
        await withTaskGroup(of: Void.self) { group in
            for item in targets {
                group.addTask { @MainActor in
                    await probeSingleProvider(item)
                }
                if ProviderBalanceService.supportsBalanceQuery(protocolType: item.protocolType, baseURL: item.baseURL) {
                    group.addTask { @MainActor in
                        await balanceStore.refresh(provider: item)
                    }
                }
            }
        }
    }

    // MARK: - Backup

    private func exportBackup() async {
        exportedJSONURL = nil
        isExporting = true
        defer { isExporting = false }
        do {
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
                password: password,
                includeDrafts: includeDraftsInBackup
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
            recoveryPlan = try BackupRecoveryPlan(.plain(decoded), in: modelContext)
        } catch {
            backupAlert = BackupAlert(title: String(localized: "导入失败"), message: error.localizedDescription)
        }
    }

    private func applyEncryptedBackup(data: Data, password: String) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let payload = try await Task.detached(priority: .userInitiated) {
                try EncryptedBackupService.decryptPayload(data: data, password: password)
            }.value
            recoveryPlan = try BackupRecoveryPlan(.encrypted(payload), in: modelContext)
        } catch {
            backupAlert = BackupAlert(title: String(localized: "导入失败"), message: error.localizedDescription)
        }
    }

    private func providerRows(_ displayed: [ProviderConfig]) -> some View {
        ForEach(displayed) { provider in
            NavigationLink(value: provider) { providerRow(provider) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        toggleProviderEnabled(provider)
                    } label: {
                        Label(
                            provider.isEnabled ? String(localized: "停用") : String(localized: "启用"),
                            systemImage: provider.isEnabled ? "pause.circle" : "play.circle"
                        )
                    }
                    .tint(provider.isEnabled ? .orange : .green)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { providerPendingDeletion = provider } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        cloneProvider(provider)
                    } label: {
                        Label("克隆", systemImage: "doc.on.doc")
                    }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button {
                        toggleProviderEnabled(provider)
                    } label: {
                        Label(
                            provider.isEnabled ? String(localized: "停用该服务商") : String(localized: "启用该服务商"),
                            systemImage: provider.isEnabled ? "pause.circle" : "play.circle"
                        )
                    }
                    if provider.isReadyForChat {
                        Button {
                            Task { await probeSingleProvider(provider) }
                        } label: {
                            Label("测试连通性", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    Button {
                        cloneProvider(provider)
                    } label: {
                        Label("克隆服务商配置", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        providerPendingDeletion = provider
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
        }
        .onMove { offsets, destination in
            moveProviders(displayed, from: offsets, to: destination)
        }
    }

    private func moveProviders(_ displayed: [ProviderConfig], from source: IndexSet, to destination: Int) {
        var moved = displayed
        moved.move(fromOffsets: source, toOffset: destination)
        let shownIDs = Set(displayed.map(\.id))
        var iterator = moved.makeIterator()
        let reordered = providers.map { shownIDs.contains($0.id) ? (iterator.next() ?? $0) : $0 }
        for (index, provider) in reordered.enumerated() where provider.sortOrder != index {
            provider.sortOrder = index
        }
        try? modelContext.save()
    }

    @ViewBuilder
    private func providerRow(_ provider: ProviderConfig) -> some View {
        let keyCount = provider.allAPIKeys.count
        let hasKey = provider.hasAuthentication
        let isLocal = NetworkLocation.isLocalOrPrivate(baseURL: provider.baseURL)
        let statusText: String = {
            if !provider.isEnabled { return String(localized: "已停用") }
            if keyCount >= 2 { return String(localized: "Key 池 (\(keyCount))") }
            if hasKey { return String(localized: "Key 已配置") }
            if isLocal { return String(localized: "本地地址") }
            return String(localized: "待填 Key")
        }()
        let statusColor: Color = {
            if !provider.isEnabled { return .secondary }
            return (hasKey || isLocal) ? .green : .orange
        }()
        let trimmedNote = provider.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(spacing: DS.Spacing.md) {
            DSIconTile(
                systemImage: provider.iconSymbol,
                tint: provider.isEnabled ? Color(hex: provider.accentHex) : .secondary,
                size: 40,
                cornerRadius: DS.Radius.sm
            )

            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                let titleLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Spacing.xxs))
                    : AnyLayout(HStackLayout(spacing: DS.Spacing.xs))
                titleLayout {
                    Text(provider.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(provider.isEnabled ? .primary : .secondary)

                    DSBadge(text: provider.protocolType.shortBadge, style: .neutral)
                }

                let statusLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Spacing.xxs))
                    : AnyLayout(HStackLayout(spacing: DS.Spacing.sm))
                statusLayout {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(statusText)
                            .font(.caption2)
                            .foregroundStyle(provider.isEnabled ? .primary : .secondary)
                    }

                    Text("已启用 \(provider.enabledModels.count) 个模型")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let coolingCount = provider.isEnabled
                        ? APIKeyPoolRouter.shared.coolingKeyCount(
                            keys: provider.allAPIKeys,
                            protocolType: provider.protocolType,
                            baseURL: provider.baseURL
                        )
                        : 0
                    if coolingCount > 0 {
                        Text("冷却 \(coolingCount)")
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.orange)
                    }

                    if let balance = balanceStore.snapshot(for: provider) {
                        Text(verbatim: balance.formattedAvailable)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    if let probe = probeStates[provider.id] {
                        switch probe {
                        case .testing:
                            ProgressView().controlSize(.mini)
                        case .ok(let ms):
                            Text("\(ms) ms")
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(DS.StatusText.success)
                        case .failed:
                            Text("连接异常")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(DS.StatusText.error)
                        }
                    }
                }

                if !trimmedNote.isEmpty {
                    Text(trimmedNote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
