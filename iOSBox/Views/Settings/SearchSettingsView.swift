import SwiftUI

struct SearchSettingsView: View {
    @State private var apiKey = ""
    @State private var notice: String?
    @State private var isTesting = false
    @State private var testResult: (isError: Bool, message: String)?

    var body: some View {
        Form {
            Section {
                SecureField("Tavily API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                HStack {
                    Button("保存") {
                        let ok = KeychainService.shared.saveSecret(
                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            account: TavilySearchClient.keychainAccount
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
                if let console = URL(string: "https://app.tavily.com") {
                    Link("Tavily 控制台 / 文档", destination: console)
                }
            } header: {
                Text("第三方联网搜索（Tavily）")
            } footer: {
                Text("密钥仅存入本机钥匙串，不写入普通备份或分享扩展。清空后保存可移除密钥。")
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
            apiKey = KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount)
        }
    }

    private func runTestSearch() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = KeychainService.shared.saveSecret(trimmed, account: TavilySearchClient.keychainAccount)
        do {
            let evidence = try await TavilySearchClient.search(query: "Swift programming language", apiKey: trimmed)
            testResult = (false, String(localized: "测试成功，返回 \(evidence.sources.count) 条有效来源。"))
        } catch {
            testResult = (true, error.localizedDescription)
        }
    }
}
