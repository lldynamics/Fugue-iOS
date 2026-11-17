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
    @State private var navigationPath: [ProviderConfig] = []
    @State private var exportedJSONURL: URL?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showImporter = false
    @State private var backupAlert: BackupAlert?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section {
                    ForEach(providers) { provider in
                        NavigationLink(value: provider) {
                            providerRow(provider)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                provider.deleteAllSecrets()
                                modelContext.delete(provider)
                                try? modelContext.save()
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

                Section("支持接入的协议说明") {
                    ForEach(APIProtocolType.allCases) { proto in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: proto.symbolName)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proto.displayName)
                                    .font(.footnote.weight(.semibold))
                                Text(proto.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
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
                    .disabled(isExporting)

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
                } header: {
                    Text("数据与隐私安全")
                } footer: {
                    Text("备份包含服务商配置、助手和全部对话（含附件），不含 API Key 与敏感请求头。导入为合并模式：已存在的项目会跳过，不会覆盖或重复。")
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
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    Task { await importBackup(from: url) }
                case .failure(let error):
                    backupAlert = BackupAlert(title: "无法打开文件", message: error.localizedDescription)
                }
            }
            .alert(item: $backupAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
            }
        }
    }

    // MARK: - Backup

    private func exportBackup() async {
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
            backupAlert = BackupAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func importBackup(from url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let decoded = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try BackupService.decode(Data(contentsOf: url))
            }.value
            let summary = try BackupService.apply(decoded, to: modelContext)
            backupAlert = BackupAlert(title: "导入完成", message: summary.description)
        } catch {
            backupAlert = BackupAlert(title: "导入失败", message: error.localizedDescription)
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
        let hasKey = KeychainService.shared.hasAPIKey(for: provider.id)
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(hex: provider.accentHex).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: provider.iconSymbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(hex: provider.accentHex))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(provider.isEnabled ? .primary : .secondary)

                    Text(provider.protocolType.shortBadge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(hasKey ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(hasKey ? "Key 已配置" : "待填 Key")
                            .font(.caption2)
                            .foregroundStyle(hasKey ? .green : .orange)
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
