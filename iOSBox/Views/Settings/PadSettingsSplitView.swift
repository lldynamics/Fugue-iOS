import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Dual-column iPadOS Settings.app-style workspace that renders the full Provider & Settings
/// directory on the left and displays the selected provider or setting panel live on the right.
struct PadSettingsSplitView: View {
    private enum Destination: Hashable {
        case overview
        case provider(UUID)
        case newChatDefaults
        case appearance
        case voice
        case liveVoice
        case lab(LabMode)
        case usageLedger
        case webSearch
        case personalMemory
        case knowledgeSearch
        case quickEntryGuide
        case backupAndPrivacy
        case webDAV
        case privacyLock
        case about
    }

    private struct BackupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]

    @State private var selection: Destination = .overview
    @State private var showAddSheet = false
    @State private var connectionDraft: ProviderSetupDraft?
    @State private var isBatchProbing = false
    @State private var probeTimes: [UUID: Int] = [:]
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
    @State private var preferences = AppPreferences.shared
    @State private var balanceStore = ProviderBalanceStore.shared

    private var theme: DS.AccentTheme { preferences.accentTheme }

    private var accounts: [ProviderConfig] {
        providers.filter { $0.hasAuthentication || !$0.extraAPIKeys.isEmpty || NetworkLocation.isLocalOrPrivate(baseURL: $0.baseURL) }
    }

    private var pendingProviders: [ProviderConfig] {
        let ids = Set(accounts.map(\.id))
        return providers.filter { !ids.contains($0.id) }
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                NavigationStack {
                    HStack(spacing: 0) {
                        leftDirectory
                            .frame(width: min(330, max(265, geometry.size.width * 0.35)))
                            .background(DS.Surface.grouped)

                        Divider()

                        rightDetail
                            .id(selection)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .navigationTitle(activeNavigationTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { settingsToolbarItems }
                }
            } else {
                ProviderListView(onClose: nil)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet { created in
                selection = .provider(created.id)
            }
        }
        .sheet(item: $connectionDraft) { draft in
            QuickKeySetupSheet(draft: draft) { provider, _ in
                selection = .provider(provider.id)
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
            isPresented: Binding(get: { providerPendingDeletion != nil }, set: { if !$0 { providerPendingDeletion = nil } }),
            presenting: providerPendingDeletion
        ) { provider in
            Button("取消", role: .cancel) { providerPendingDeletion = nil }
            Button("删除并清除密钥", role: .destructive) {
                let deletedID = provider.id
                try? SystemIntegration.shared.setEnabled(false, provider: provider, context: modelContext)
                provider.deleteAllSecrets()
                modelContext.delete(provider)
                try? modelContext.save()
                if !modelContext.container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
                    SyncTombstoneStore.shared.recordDeletion(kind: .provider, id: deletedID)
                }
                if selection == .provider(deletedID) {
                    selection = .overview
                }
                providerPendingDeletion = nil
            }
        } message: { provider in
            Text("将移除「\(provider.name)」及其保存在本机钥匙串中的 API Key 与敏感请求头。")
        }
        .alert(
            "输入备份解密密码",
            isPresented: Binding(get: { pendingEncryptedImportData != nil }, set: { if !$0 { pendingEncryptedImportData = nil; importPassword = "" } })
        ) {
            SecureField("加密备份密码", text: $importPassword)
            Button("取消", role: .cancel) { pendingEncryptedImportData = nil; importPassword = "" }
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

    @ToolbarContentBuilder
    private var settingsToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if accounts.contains(where: \.isReadyForChat) {
                Button {
                    Task { await probeAllReadyProviders() }
                } label: {
                    if isBatchProbing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("一键测速", systemImage: "bolt.horizontal.circle")
                    }
                }
                .disabled(isBatchProbing)
            }

            Button {
                showAddSheet = true
            } label: {
                Label("手动添加服务商", systemImage: "plus")
            }
        }
    }

    private var leftDirectory: some View {
        List {
            Section {
                Button {
                    connectionDraft = ProviderSetupDraft()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("连接模型").font(.subheadline.weight(.semibold))
                            Text("OpenAI 官方、OpenRouter 或其他服务商")
                                .font(.caption).foregroundStyle(DS.Surface.inkSecondary)
                        }
                    } icon: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(theme.readableText)
                    }
                    .frame(minHeight: DS.TouchTarget.minimum)
                }
                .accessibilityIdentifier("settings.connectModel")
            }

            if !accounts.isEmpty {
                Section("已保存的服务商") {
                    ForEach(accounts) { provider in
                        providerRow(provider)
                    }
                }
            }

            if !pendingProviders.isEmpty {
                Section("待配置的服务商（\(pendingProviders.count)）") {
                    ForEach(pendingProviders) { provider in
                        providerRow(provider)
                    }
                }
            }

            Section {
                navRow(.newChatDefaults, title: "新对话默认设置", symbol: "bubble.left.and.text.bubble.right")
                navRow(.appearance, title: "阅读与交互偏好", symbol: "textformat.size")
                navRow(.voice, title: "语音转写与自然朗读", symbol: "waveform")
            } header: {
                Text("对话与显示").foregroundStyle(DS.Surface.inkSecondary)
            }

            Section {
                navRow(.usageLedger, title: "用量与费用账本", symbol: "chart.bar.xaxis")
                navRow(.webSearch, title: "联网搜索", symbol: "globe")
            } header: {
                Text("用量与联网").foregroundStyle(DS.Surface.inkSecondary)
            }

            Section {
                navRow(.liveVoice, title: "实时语音", symbol: "waveform.and.mic")
                ForEach(LabMode.allCases) { mode in
                    navRowVerbatim(.lab(mode), title: mode.title, symbol: "wrench.and.screwdriver")
                }
            } header: {
                Text("模型工具").foregroundStyle(DS.Surface.inkSecondary)
            }

            Section {
                navRow(.personalMemory, title: "个人长期记忆", symbol: "brain.head.profile")
                navRow(.knowledgeSearch, title: "全文检索与知识库索引", symbol: "magnifyingglass.circle")
                navRow(.quickEntryGuide, title: "小组件、控制中心与操作按钮", symbol: "square.grid.2x2")
            } header: {
                Text("高级功能").foregroundStyle(DS.Surface.inkSecondary)
            }

            Section {
                navRow(.backupAndPrivacy, title: "导出与恢复备份", symbol: "externaldrive.badge.timemachine")
                navRow(.webDAV, title: "WebDAV 加密云同步", symbol: "icloud.and.arrow.up")
                navRow(.privacyLock, title: "隐私锁与防窥遮罩", symbol: "faceid")
                navRow(.about, title: "关于与隐私声明", symbol: "info.circle")
            } header: {
                Text("数据与隐私安全").foregroundStyle(DS.Surface.inkSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func providerRow(_ provider: ProviderConfig) -> some View {
        let isSelected = selection == .provider(provider.id)
        return Button {
            selection = .provider(provider.id)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                DSIconTile(
                    systemImage: provider.iconSymbol,
                    tint: provider.isEnabled ? Color(hex: provider.accentHex) : .secondary,
                    size: 34,
                    cornerRadius: DS.Radius.xs
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: provider.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(provider.isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("已启用 \(provider.enabledModels.count) 个模型")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let ms = probeTimes[provider.id] {
                            Text("\(ms) ms")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(DS.StatusText.success)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: DS.TouchTarget.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(isSelected ? theme.softFill : DS.Surface.card)
                .padding(.vertical, 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                providerPendingDeletion = provider
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func navRow(_ dest: Destination, title: LocalizedStringKey, symbol: String) -> some View {
        let isSelected = selection == dest
        return Button {
            selection = dest
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.readableText : .primary)
                .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(isSelected ? theme.softFill : DS.Surface.card)
                .padding(.vertical, 1)
        )
    }

    private func navRowVerbatim(_ dest: Destination, title: String, symbol: String) -> some View {
        let isSelected = selection == dest
        return Button {
            selection = dest
        } label: {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? theme.readableText : .primary)
                .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(isSelected ? theme.softFill : DS.Surface.card)
                .padding(.vertical, 1)
        )
    }

    private var activeNavigationTitle: String {
        switch selection {
        case .overview:
            return String(localized: "服务商与设置")
        case .provider(let id):
            return providers.first(where: { $0.id == id })?.name ?? String(localized: "服务商与设置")
        case .newChatDefaults:
            return String(localized: "新对话默认设置")
        case .appearance:
            return String(localized: "阅读与交互偏好")
        case .voice:
            return String(localized: "语音转写与自然朗读")
        case .liveVoice:
            return String(localized: "实时语音")
        case .lab(let mode):
            return mode.title
        case .usageLedger:
            return String(localized: "用量与测速")
        case .webSearch:
            return String(localized: "联网搜索")
        case .personalMemory:
            return String(localized: "个人长期记忆")
        case .knowledgeSearch:
            return String(localized: "全文检索与知识库索引")
        case .quickEntryGuide:
            return String(localized: "小组件、控制中心与操作按钮")
        case .backupAndPrivacy:
            return String(localized: "导出与恢复备份")
        case .webDAV:
            return String(localized: "WebDAV 加密云同步")
        case .privacyLock:
            return String(localized: "隐私锁与防窥遮罩")
        case .about:
            return String(localized: "关于与隐私声明")
        }
    }

    @ViewBuilder
    private var rightDetail: some View {
        switch selection {
        case .overview:
            providersOverviewPanel
        case .provider(let id):
            if let provider = providers.first(where: { $0.id == id }) {
                ProviderDetailView(provider: provider, correctKey: { connectionDraft = $0 })
            } else {
                providersOverviewPanel
            }
        case .newChatDefaults:
            NewChatDefaultsView()
        case .appearance:
            AppearanceSettingsView()
        case .voice:
            VoiceSettingsView()
        case .liveVoice:
            LiveVoiceView()
        case .lab(let mode):
            ModelWorkshop(mode: mode)
                .id(mode)
        case .usageLedger:
            RequestLedgerView(onClose: nil)
        case .webSearch:
            SearchSettingsView()
        case .personalMemory:
            PersonalMemoryView()
        case .knowledgeSearch:
            KnowledgeSearchSettingsView()
        case .quickEntryGuide:
            SystemQuickEntryGuideView(onDismissSettings: nil)
        case .backupAndPrivacy:
            backupPanel
        case .webDAV:
            WebDAVSyncView()
        case .privacyLock:
            PrivacyLockSettingsView()
        case .about:
            AboutAndPrivacyView()
        }
    }

    private var providersOverviewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                HStack(alignment: .top, spacing: DS.Spacing.md) {
                    DSIconTile(systemImage: "lock.shield.fill", tint: DS.StatusText.success, size: 44, cornerRadius: DS.Radius.md)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("纯客户端本地直连")
                            .font(.headline)
                        Text("API Key 加密存储于 iOS 系统 Keychain，所有请求由本机直接发往你配置的 API 地址。")
                            .font(.subheadline)
                            .foregroundStyle(DS.Surface.inkSecondary)
                    }
                    Spacer()
                    Button {
                        connectionDraft = ProviderSetupDraft()
                    } label: {
                        Text("连接模型")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.solidForeground)
                            .padding(.horizontal, DS.Spacing.lg)
                            .frame(minHeight: DS.TouchTarget.minimum)
                            .background(theme.solidFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.lift)
                }
                .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.lg)

                if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("尚未配置服务商账号", systemImage: "bolt.horizontal.circle")
                    } description: {
                        Text("点击「连接模型」选择服务商并验证密钥，或从左侧进入阅读偏好、用量与加密同步设置。")
                    }
                    .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        Text("已保存的服务商")
                            .font(.headline)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: DS.Spacing.md)],
                            spacing: DS.Spacing.md
                        ) {
                            ForEach(accounts) { provider in
                                Button {
                                    selection = .provider(provider.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                        HStack {
                                            DSIconTile(
                                                systemImage: provider.iconSymbol,
                                                tint: provider.isEnabled ? Color(hex: provider.accentHex) : .secondary,
                                                size: 36,
                                                cornerRadius: DS.Radius.sm
                                            )
                                            Spacer()
                                            if let ms = probeTimes[provider.id] {
                                                Text("\(ms) ms")
                                                    .font(.caption.monospacedDigit().weight(.semibold))
                                                    .foregroundStyle(DS.StatusText.success)
                                            }
                                        }
                                        Text(verbatim: provider.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text("已启用 \(provider.enabledModels.count) 个模型")
                                            .font(.caption)
                                            .foregroundStyle(DS.Surface.inkSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .dsCard(cornerRadius: DS.Radius.lg, fill: DS.Surface.card, padding: DS.Spacing.md)
                                }
                                .buttonStyle(.plain)
                                .hoverEffect(.highlight)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(DS.Spacing.xl)
        }
        .background(DS.Surface.canvas)
    }

    private var backupPanel: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(DS.StatusText.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("纯客户端本地直连")
                            .font(.footnote.weight(.semibold))
                        Text("API Key 加密存储于 iOS 系统 Keychain，所有请求由本机直接发往你配置的 API 地址。")
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
                    } else {
                        Label("导出完整备份 (JSON)", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || !PersistenceController.canCommitUserData(in: modelContext))

                Toggle("加密换机备份包含未发送草稿", isOn: $includeDraftsInBackup)

                Button {
                    exportPassword = ""
                    showExportPasswordAlert = true
                } label: {
                    Label("导出密码加密备份 (含 API Key)", systemImage: "lock.doc.fill")
                }
                .disabled(isExporting || !PersistenceController.canCommitUserData(in: modelContext))

                if let url = exportedJSONURL {
                    ShareLink(item: url) {
                        Label("点击分享或保存导出的备份文件", systemImage: "arrow.up.doc.fill")
                            .foregroundStyle(theme.readableText)
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
                    } else {
                        Label("从备份文件导入", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(isImporting)
            } header: {
                Text("导出与恢复备份")
            } footer: {
                Text("导入会补回缺失的对话、附件与分支，并保留本机已有配置。普通备份会省略密钥、敏感请求头及自定义路径地址；使用「加密导出完整备份」时才会以密码加密包含 API Key 与完整连接地址。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.Surface.grouped)
        .navigationTitle("导出与恢复备份")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func probeAllReadyProviders() async {
        let targets = accounts.filter(\.isReadyForChat)
        guard !targets.isEmpty else { return }
        isBatchProbing = true
        defer { isBatchProbing = false }
        await withTaskGroup(of: Void.self) { group in
            for item in targets {
                group.addTask { @MainActor in
                    guard let spec = item.enabledModels.first, item.hasConfiguredChatAPI else { return }
                    if let result = try? await LLMClient.pingModel(
                        providerName: item.name,
                        protocolType: item.protocolType,
                        baseURL: item.baseURL,
                        apiKey: LLMClient.sanitizedAPIKey(item.apiKey),
                        apiKeys: item.extraAPIKeys,
                        customHeaders: item.resolvedCustomHeaders,
                        modelID: spec.id,
                        supportsReasoning: spec.supportsReasoning,
                        idleTimeoutSeconds: item.customIdleTimeout
                    ) {
                        probeTimes[item.id] = result.ttftMs
                    }
                }
                if ProviderBalanceService.supportsBalanceQuery(protocolType: item.protocolType, baseURL: item.baseURL) {
                    group.addTask { @MainActor in
                        await balanceStore.refresh(provider: item)
                    }
                }
            }
        }
    }

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
}
