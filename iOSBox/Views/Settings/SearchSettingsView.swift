import SwiftUI

struct SearchSettingsView: View {
    @State private var key = ""
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                SecureField("Tavily API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存") {
                    notice = KeychainService.shared.saveSecret(key, account: TavilySearchClient.keychainAccount)
                        ? String(localized: "已保存") : String(localized: "无法保存到钥匙串，请重试。")
                }
                if let notice { Text(notice).font(.footnote) }
                Link("Tavily 控制台", destination: URL(string: "https://app.tavily.com")!)
            } header: { Text("联网搜索 · Tavily") } footer: {
                Text("密钥仅存入本机钥匙串，不写入备份或分享扩展。清空后保存可移除密钥。")
            }
            Section {
                Text("发送前打开「联网搜索」并确认搜索词。只把该搜索词发给 Tavily，不发送记忆、附件或聊天历史；来源摘要会发给回答模型。搜索可能消耗 Tavily 额度，费用不计入模型 Token 费用。")
                Text("每次使用基础搜索，最多保留 5 个 HTTPS 来源。失败时停止本次回答；请修改搜索词，或关闭联网搜索重新发送。")
            }
            Section("服务商原生联网（免 Tavily Key）") {
                Text("未配置 Tavily Key 时，在对话输入栏点按「联网」或在「发送选项」开启「服务商原生联网」，会直接向支持联网的接口请求内置检索（Gemini Google Search、Anthropic Web Search、OpenAI / OpenRouter Web Search），如网关不支持则自动回退。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("联网搜索")
        .onAppear { key = KeychainService.shared.loadSecret(account: TavilySearchClient.keychainAccount) }
    }
}
