import SwiftUI

struct MCPServersSettingsView: View {
    @State private var store = MCPServerStore.shared
    @State private var editingServer: MCPServerConfig?
    @State private var showAddServer = false

    var body: some View {
        List {
            Section {
                if store.servers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("连接 Remote MCP 工具服务", systemImage: "puzzlepiece.extension")
                            .font(.headline)
                        Text("支持兼容 Streamable HTTP（JSON-RPC 2.0 / SSE）的远程 MCP 服务端，如 Notion、Linear、GitHub、n8n 或自建知识网关。开启会话「工具」后，AI 调用外部 MCP 工具前都会先经由你手动确认。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("添加 MCP 服务") { showAddServer = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(store.servers) { server in
                        NavigationLink {
                            MCPServerDetailView(server: server)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .foregroundStyle(server.isEnabled ? Color.accentColor : .secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(server.name)
                                            .font(.body.weight(.semibold))
                                        Text("\(server.activeTools.count)/\(server.discoveredTools.count)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.secondarySystemBackground), in: Capsule())
                                    }
                                    Text(server.endpointURL)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.delete(id: server.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editingServer = server
                            } label: {
                                Label("编辑", systemImage: "slider.horizontal.3")
                            }
                            .tint(.blue)
                        }
                    }
                }
            } header: {
                Text("已配置的 MCP 服务（\(store.servers.count)）")
            } footer: {
                Text("鉴权 Header 值仅存于本机钥匙串；所有公网 MCP 端点均强制 HTTPS。调用外部 MCP 工具时，聊天页底部会弹出确认条由你授权。")
            }
        }
        .navigationTitle("Remote MCP 工具服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddServer = true } label: {
                    Label("添加 MCP 服务", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddServer) {
            MCPServerEditorSheet(existing: nil)
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditorSheet(existing: server)
        }
    }
}

private struct MCPServerDetailView: View {
    let server: MCPServerConfig
    @State private var store = MCPServerStore.shared
    @State private var isDiscovering = false
    @State private var statusText: String?
    @State private var isError = false
    @State private var showEditor = false

    private var current: MCPServerConfig {
        store.servers.first { $0.id == server.id } ?? server
    }

    var body: some View {
        List {
            Section("服务状态") {
                Toggle("启用此 MCP 服务", isOn: Binding(
                    get: { current.isEnabled },
                    set: { next in
                        var copy = current
                        copy.isEnabled = next
                        store.upsert(copy)
                    }
                ))
                LabeledContent("端点地址", value: current.endpointURL)
                if let connectedAt = current.lastConnectedAt {
                    LabeledContent("上次同步", value: connectedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task { await refreshTools() }
                } label: {
                    HStack {
                        if isDiscovering {
                            ProgressView().controlSize(.small)
                            Text("正在连接并拉取工具…")
                        } else {
                            Label("连接并拉取工具列表", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                .disabled(isDiscovering)

                if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .green)
                }
            }

            Section("已发现的工具（\(current.discoveredTools.count)）") {
                if current.discoveredTools.isEmpty {
                    Text("尚未拉取到工具，请点击上方按钮连接服务端。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(current.discoveredTools) { tool in
                        Toggle(isOn: Binding(
                            get: { !current.disabledToolNames.contains(tool.name) },
                            set: { enabled in
                                var copy = current
                                if enabled { copy.disabledToolNames.remove(tool.name) }
                                else { copy.disabledToolNames.insert(tool.name) }
                                store.upsert(copy)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                    .font(.subheadline.weight(.semibold).monospaced())
                                Text(tool.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            MCPServerEditorSheet(existing: current)
        }
    }

    private func refreshTools() async {
        isDiscovering = true
        statusText = nil
        isError = false
        defer { isDiscovering = false }
        let secret = KeychainService.shared.loadSecret(account: current.keychainAccount)
        do {
            let tools = try await MCPClient.discoverTools(
                endpointURL: current.endpointURL,
                authHeaderName: current.authHeaderName,
                authHeaderValue: secret
            )
            var copy = current
            copy.discoveredTools = tools
            copy.lastConnectedAt = Date()
            store.upsert(copy)
            statusText = String(localized: "连接成功，共发现 \(tools.count) 个工具。")
        } catch {
            isError = true
            statusText = error.localizedDescription
        }
    }
}

private struct MCPServerEditorSheet: View {
    let existing: MCPServerConfig?
    @Environment(\.dismiss) private var dismiss
    @State private var store = MCPServerStore.shared

    @State private var name: String
    @State private var endpointURL: String
    @State private var authHeaderName: String
    @State private var authHeaderValue: String
    @State private var isTesting = false
    @State private var testFeedback: String?
    @State private var isTestError = false

    init(existing: MCPServerConfig?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _endpointURL = State(initialValue: existing?.endpointURL ?? "")
        _authHeaderName = State(initialValue: existing?.authHeaderName ?? "Authorization")
        let savedSecret = existing.map { KeychainService.shared.loadSecret(account: $0.keychainAccount) } ?? ""
        _authHeaderValue = State(initialValue: savedSecret)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("MCP 服务信息") {
                    TextField("服务名称（如：Notion / 自建网关）", text: $name)
                    TextField("Streamable HTTP 地址（https://...）", text: $endpointURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    TextField("鉴权 Header 名（如 Authorization）", text: $authHeaderName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("鉴权值（如 Bearer sk-...，可选）", text: $authHeaderValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("身份验证（存入钥匙串）")
                }

                Section {
                    Button {
                        Task { await saveAndDiscover() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView().controlSize(.small)
                                Text("正在测试连接并拉取工具…")
                            } else {
                                Label("保存并拉取工具列表", systemImage: "bolt.horizontal.circle")
                            }
                        }
                    }
                    .disabled(isTesting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let testFeedback {
                        Text(testFeedback)
                            .font(.caption)
                            .foregroundStyle(isTestError ? .red : .green)
                    }
                }
            }
            .navigationTitle(existing == nil ? "添加 MCP 服务" : "编辑 MCP 服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("仅保存") {
                        saveOnly(discoveredTools: existing?.discoveredTools ?? [], connectedAt: existing?.lastConnectedAt)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveOnly(discoveredTools: [MCPToolInfo], connectedAt: Date?) {
        let server = MCPServerConfig(
            id: existing?.id ?? UUID(),
            name: name,
            endpointURL: endpointURL,
            isEnabled: existing?.isEnabled ?? true,
            authHeaderName: authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Authorization" : authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
            discoveredTools: discoveredTools,
            disabledToolNames: existing?.disabledToolNames ?? [],
            lastConnectedAt: connectedAt
        )
        _ = KeychainService.shared.saveSecret(authHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines), account: server.keychainAccount)
        store.upsert(server)
    }

    private func saveAndDiscover() async {
        isTesting = true
        testFeedback = nil
        isTestError = false
        defer { isTesting = false }
        let headerName = authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Authorization" : authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = authHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let tools = try await MCPClient.discoverTools(
                endpointURL: endpointURL,
                authHeaderName: headerName,
                authHeaderValue: secret
            )
            saveOnly(discoveredTools: tools, connectedAt: Date())
            dismiss()
        } catch {
            isTestError = true
            testFeedback = error.localizedDescription
        }
    }
}
