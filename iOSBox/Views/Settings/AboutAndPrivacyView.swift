import SwiftData
import SwiftUI

struct AboutAndPrivacyView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppCompliance.consentKey, store: AppCompliance.consentDefaults) private var hasConsent = false
    @AppStorage(SpotlightIndexService.enabledKey) private var spotlightEnabled = false
    @AppStorage(WidgetSnapshotService.showRecentTitlesKey) private var widgetShowRecentTitles = false

    private var appVersion: String {
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(ver) (\(build))"
    }

    var body: some View {
        Form {
            Section("应用信息") {
                LabeledContent("版本", value: appVersion)
                LabeledContent("连接架构", value: String(localized: "纯客户端本地直连 (BYOK)"))
            }

            Section("第三方 AI 数据传输说明") {
                Text("本应用不设任何中间转发服务器，也不收集账号、遥测或聊天数据。当你发起对话时，消息、附件及启用的个人记忆会直接由设备发往你自行配置的目标 API 服务商。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if hasConsent {
                    Button("撤回发送授权", role: .destructive) { hasConsent = false }
                } else {
                    Text("尚未授权，下次发送前会显示接收方并请你确认。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("锁屏与灵动岛") {
                Toggle("显示对话标题和回答预览", isOn: Binding(
                    get: { LiveActivityCoordinator.shared.showsPreviews },
                    set: { LiveActivityCoordinator.shared.setShowsPreviews($0) }
                ))
                Text("默认仅显示生成进度。开启后，新的实时活动可显示标题、发言者和回答片段。盲评揭晓前始终匿名。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("桌面与锁屏小组件") {
                Toggle("在中号桌面小组件显示最近对话标题", isOn: Binding(
                    get: { widgetShowRecentTitles },
                    set: { enabled in
                        widgetShowRecentTitles = enabled
                        WidgetSnapshotService.shared.setShowsRecentTitles(enabled, context: modelContext)
                    }
                ))
                Text("默认关闭。仅开启后才会在桌面中号小组件显示最多 3 条最近对话标题，且会自动响应系统隐私隐藏开关。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("系统搜索与本地索引") {
                Toggle("允许系统 Spotlight 索引对话", isOn: $spotlightEnabled)
                Text("默认关闭。开启后，最近对话标题与收藏片段会写入本机 CoreSpotlight 以便从系统桌面搜索直达；关闭时会立即清空已写入的系统索引。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: spotlightEnabled) { _, enabled in
                SpotlightIndexService.shared.handlePreferenceChange(enabled: enabled)
            }

            Section("本地存储与权限边界") {
                Text("API Key 与标记为敏感的请求头仅保存在本机 iOS 钥匙串（Keychain）中；对话、附件、请求记录与个人记忆保存在本机 SwiftData 数据库，支持导出不含密钥的 JSON 备份或使用 AES-256-GCM 密码加密的完整备份，并可随时单条删除、清空对话或移除服务商销毁对应凭据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("相机、相册、麦克风、语音识别、日历/提醒事项与局域网权限仅在你主动点击拍照、选图、语音听写、确认添加待办日程或连接本地模型地址时按需请求，不会在后台静默采集。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("免责声明") {
                Text("对话回复由你接入的第三方人工智能模型生成，可能存在虚构或滞后信息，仅供参考，不构成专业医疗、法律或投资建议。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("支持与政策") {
                NavigationLink {
                    BuiltInPrivacyPolicyView()
                } label: {
                    Label("查看完整隐私政策说明", systemImage: "doc.text.magnifyingglass")
                }

                if let policyURL = AppCompliance.privacyPolicyURL {
                    Link(destination: policyURL) {
                        Label("查看隐私政策网页", systemImage: "hand.raised")
                    }
                }

                if let email = AppCompliance.supportEmail,
                   let mailURL = URL(string: "mailto:\(email)") {
                    Link(destination: mailURL) {
                        Label("联系与反馈 (\(email))", systemImage: "envelope")
                    }
                }
            }
        }
        .navigationTitle("关于与隐私声明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct BuiltInPrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("隐私与数据处理说明")
                        .font(.title3.bold())

                    policyBlock(
                        title: String(localized: "1. 零自建后端与零数据收集"),
                        detail: String(localized: "夜奔（Fugue）是纯本地运行的自带密钥（BYOK）客户端。开发者不运营账号系统、不转发明文请求、不接入第三方广告或行为分析 SDK，也不会向开发者服务器上传任何提示词、回复、电子书、闪卡或 API 密钥。")
                    )

                    policyBlock(
                        title: String(localized: "2. 向第三方服务商的直连传输"),
                        detail: String(localized: "仅在你首次确认数据出境/第三方传输披露后，你主动发送的会话上下文、所选附件、已启用的个人记忆或联网搜索关键词才会从你的设备直接发送至你所配置的模型 API 地址（如 OpenAI、Anthropic、Google Gemini、DeepSeek、OpenRouter、Tavily 或局域网服务）。相关数据的留存与使用受对应服务商自身的隐私条款约束。你可随时在本页点击「撤回发送授权」。")
                    )

                    policyBlock(
                        title: String(localized: "3. 本机存储、备份加密与删除控制"),
                        detail: String(localized: "所有 API 密钥、备用密钥与敏感自定义请求头均存储在受系统硬件级保护的 iOS Keychain 中；会话、知识库与用量账本保存在沙盒内 SwiftData 数据库。普通备份会自动剥离全部密钥与含私密凭据的端点；加密备份采用 Apple CryptoKit（PBKDF2-HMAC-SHA256 + AES-256-GCM）在本地完成加解密，密码仅由你本人掌握。删除对话、清空历史或移除服务商将同步清理对应本地记录与钥匙串凭据。")
                    )

                    policyBlock(
                        title: String(localized: "4. 系统扩展、权限与安全防护"),
                        detail: String(localized: "分享扩展通过本机 App Group 与主应用交换数据。实时活动默认只显示生成进度，你可以在隐私设置中开启或关闭回答预览。盲评揭晓前会隐藏模型身份和回答内容。网页工具会拦截内网地址，访问未经授权的外部域名时会请你确认。Spotlight 索引默认关闭，开启后才会在本机建立搜索条目。")
                    )
                }
            }
            .padding()
        }
        .navigationTitle("隐私政策说明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func policyBlock(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
