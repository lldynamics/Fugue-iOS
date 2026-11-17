import SwiftUI
import SwiftData

struct ProviderListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProviderConfig.sortOrder) private var providers: [ProviderConfig]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var showAddSheet = false
    @State private var navigationPath: [ProviderConfig] = []
    @State private var exportedJSONURL: URL?

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

                Section("数据与隐私安全") {
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
                        exportConversationsJSON()
                    } label: {
                        Label("导出本地对话记录备份 (JSON)", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                    .disabled(conversations.isEmpty)

                    if let url = exportedJSONURL {
                        ShareLink(item: url) {
                            Label("点击分享或保存导出的备份文件", systemImage: "arrow.up.doc.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("服务商与设置")
            .toolbar {
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
        }
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

    private func exportConversationsJSON() {
        struct ExportMessage: Codable {
            let role: String
            let model: String
            let provider: String
            let reasoning: String
            let content: String
            let createdAt: Date
        }
        struct ExportConversation: Codable {
            let title: String
            let systemPrompt: String
            let updatedAt: Date
            let messages: [ExportMessage]
        }

        let payload = conversations.map { conv in
            ExportConversation(
                title: conv.title,
                systemPrompt: conv.systemPrompt,
                updatedAt: conv.updatedAt,
                messages: conv.sortedMessages.map { m in
                    ExportMessage(
                        role: m.roleRaw,
                        model: m.modelID,
                        provider: m.providerName,
                        reasoning: m.reasoningContent,
                        content: m.content,
                        createdAt: m.createdAt
                    )
                }
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iOSBox_Conversations_\(Int(Date().timeIntervalSince1970)).json")
        try? data.write(to: tempURL, options: .atomic)
        exportedJSONURL = tempURL
    }
}
