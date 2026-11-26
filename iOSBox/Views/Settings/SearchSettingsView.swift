import SwiftUI

struct SearchSettingsKeyManager {
    let account: String

    init(account: String = TavilySearchClient.keychainAccount) {
        self.account = account
    }

    func loadSavedKey() -> String {
        KeychainService.shared.loadSecret(account: account)
    }

    @discardableResult
    func saveKey(_ rawDraftKey: String) -> Bool {
        let trimmed = rawDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainService.shared.deleteSecret(account: account)
            return true
        }
        return KeychainService.shared.saveSecret(trimmed, account: account)
    }

    func hasUnsavedChanges(draftKey: String, savedKey: String) -> Bool {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines) != savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testDraftKey(
        _ rawDraftKey: String,
        savedKey: String,
        query: String = "Swift programming language",
        session: URLSession? = nil
    ) async -> (isError: Bool, message: String) {
        let trimmed = rawDraftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUnsaved = hasUnsavedChanges(draftKey: trimmed, savedKey: savedKey)
        do {
            let evidence = try await TavilySearchClient.search(query: query, apiKey: trimmed, session: session)
            if hasUnsaved {
                return (false, String(localized: "测试成功，返回 \(evidence.sources.count) 条有效来源。请点按「保存」以保存此密钥。"))
            }
            return (false, String(localized: "测试成功，返回 \(evidence.sources.count) 条有效来源。"))
        } catch {
            return (true, error.localizedDescription)
        }
    }
}

struct SearchSettingsView: View {
    @State private var apiKey = ""
    @State private var savedAPIKey = ""
    @State private var notice: String?
    @State private var isTesting = false
    @State private var testResult: (isError: Bool, message: String)?

    private let keyManager = SearchSettingsKeyManager()

    private var hasUnsavedKeyEdits: Bool {
        keyManager.hasUnsavedChanges(draftKey: apiKey, savedKey: savedAPIKey)
    }

    var body: some View {
        Form {
            Section {
                SecureField("Tavily API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, _ in
                        notice = nil
                    }

                HStack {
                    Button("保存") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        let ok = keyManager.saveKey(trimmed)
                        if ok {
                            apiKey = trimmed
                            savedAPIKey = trimmed
                            notice = trimmed.isEmpty ? String(localized: "已移除已保存的密钥") : String(localized: "已保存")
                        } else {
                            notice = String(localized: "无法保存到钥匙串，请重试。")
                        }
                    }
                    Spacer()
                    Button {
                        Task { await runTestSearch() }
                    } label: {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试搜索")
                        }
                    }
                    .disabled(isTesting)
                }

                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if hasUnsavedKeyEdits {
                    Text("密钥已修改，点击「保存」后正式生效。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(testResult.isError ? .orange : .green)
                }
                if let console = URL(string: "https://app.tavily.com") {
                    Link("Tavily 控制台 / 文档", destination: console)
                }
            } header: {
                Text("第三方联网搜索（Tavily）")
            } footer: {
                Text("密钥仅存入本机钥匙串，不写入普通备份或分享扩展。「测试搜索」仅验证当前输入框中的密钥，不会覆盖已保存的密钥；清空后点击「保存」可移除密钥。")
            }

            Section {
                Text("发送前打开「联网搜索」并确认搜索词。只把该搜索词发给 Tavily，不发送记忆、附件或聊天历史；来源摘要会发给回答模型。")
                Text("每次最多保留 5 个 HTTPS 来源。失败时停止本次回答；请修改搜索词，或关闭联网搜索重新发送。")
            }

            Section("服务商原生联网（免第三方搜索 Key）") {
                Text("未配置 Tavily Key 时，在对话输入栏点按「联网」或在「发送选项」开启「服务商原生联网」，会直接向支持联网的接口请求内置检索（Gemini Google Search、Anthropic Web Search、OpenAI / OpenRouter Web Search），如网关不支持则自动回退。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("联网搜索")
        .onAppear {
            let loaded = keyManager.loadSavedKey()
            apiKey = loaded
            savedAPIKey = loaded
        }
    }

    private func runTestSearch() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        testResult = await keyManager.testDraftKey(apiKey, savedKey: savedAPIKey)
    }
}
