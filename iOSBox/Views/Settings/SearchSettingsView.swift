import SwiftUI

struct SearchSettingsView: View {
    @State private var preferences = AppPreferences.shared
    @State private var apiKey = ""
    @State private var jinaKey = ""
    @State private var notice: String?
    @State private var isTesting = false
    @State private var testResult: (isError: Bool, message: String)?

    private var activeProvider: WebSearchProvider { preferences.webSearchProvider }

    var body: some View {
        Form {
            Section {
                Picker("默认搜索引擎", selection: $preferences.webSearchProvider) {
                    ForEach(WebSearchProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: preferences.webSearchProvider) { _, next in
                    apiKey = KeychainService.shared.loadSecret(account: next.keychainAccount)
                    notice = nil
                    testResult = nil
                }

                if activeProvider == .searxng {
                    TextField("SearXNG 实例地址（如 https://search.example.com）", text: $preferences.searxngBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("访问令牌（可选，Bearer Token）", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("\(activeProvider.displayName) API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                HStack {
                    Button("保存") {
                        let ok = KeychainService.shared.saveSecret(
                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            account: activeProvider.keychainAccount
                        )
                        notice = ok ? String(localized: "已保存") : String(localized: "无法保存到钥匙串，请重试。")
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
                }
                if let testResult {
                    Label(testResult.message, systemImage: testResult.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(testResult.isError ? .orange : .green)
                }
                if let console = activeProvider.consoleURL {
                    Link("\(activeProvider.displayName) 控制台 / 文档", destination: console)
                }
            } header: {
                Text("联网搜索引擎")
            } footer: {
                Text("密钥仅存入本机钥匙串，不写入普通备份或分享扩展。清空后保存可移除密钥。SearXNG 公网地址须使用 HTTPS，局域网可使用 HTTP。")
            }

            Section {
                Toggle("网页读取启用 Jina Reader 回退", isOn: $preferences.jinaReaderFallbackEnabled)
                if preferences.jinaReaderFallbackEnabled {
                    SecureField("Jina API Key（可选，提高频率限额）", text: $jinaKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存 Jina Key") {
                        let ok = KeychainService.shared.saveSecret(
                            jinaKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            account: WebSearchService.jinaKeychainAccount
                        )
                        notice = ok ? String(localized: "已保存") : String(localized: "无法保存到钥匙串，请重试。")
                    }
                }
            } header: {
                Text("动态网页正文提取（Jina Reader）")
            } footer: {
                Text("开启后，当 AI 调用 read_webpage 遇到纯客户端 JS 渲染页导致直连正文为空时，可经 r.jina.ai 提取 Markdown 正文（同样受外部链接授权保护）。")
            }

            Section {
                Text("发送前打开「联网搜索」并确认搜索词。只把该搜索词发给所选搜索引擎，不发送记忆、附件或聊天历史；来源摘要会发给回答模型。")
                Text("每次最多保留 5 个 HTTPS 来源。失败时停止本次回答；请修改搜索词，或关闭联网搜索重新发送。")
            }

            Section("服务商原生联网（免第三方搜索 Key）") {
                Text("未配置第三方搜索 Key 时，在对话输入栏点按「联网」或在「发送选项」开启「服务商原生联网」，会直接向支持联网的接口请求内置检索（Gemini Google Search、Anthropic Web Search、OpenAI / OpenRouter Web Search），如网关不支持则自动回退。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("联网搜索")
        .onAppear {
            apiKey = KeychainService.shared.loadSecret(account: activeProvider.keychainAccount)
            jinaKey = KeychainService.shared.loadSecret(account: WebSearchService.jinaKeychainAccount)
        }
    }

    private func runTestSearch() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        _ = KeychainService.shared.saveSecret(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            account: activeProvider.keychainAccount
        )
        do {
            let evidence = try await WebSearchService.search(query: "Swift programming language", provider: activeProvider)
            testResult = (false, String(localized: "测试成功，返回 \(evidence.sources.count) 条有效来源。"))
        } catch {
            testResult = (true, error.localizedDescription)
        }
    }
}
