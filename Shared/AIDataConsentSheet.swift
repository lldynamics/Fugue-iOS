import SwiftUI

/// Explicit third-party AI data transmission disclosure required by App Store Review Guideline 5.1.2(i).
struct AIDataConsentSheet: View {
    let targetSummary: String
    let includesWebSearch: Bool
    let includesTools: Bool
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("第三方 AI 数据直连说明")
                                .font(.headline)
                            Text("首次发送前请确认数据流向与隐私保护机制")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    disclosureBlock(
                        icon: "doc.text.magnifyingglass",
                        title: String(localized: "将发送哪些数据"),
                        detail: String(localized: "本次操作可能发送消息、选用的历史上下文、引用、附件和系统提示词。启用个人记忆时，也会发送适用的记忆。圆桌人物的参考片段会发送给其绑定的模型。与书中好友聊天时，会附上本次选取的原书片段。")
                    )

                    disclosureBlock(
                        icon: "arrow.up.right.square",
                        title: String(localized: "数据发送到哪里"),
                        detail: targetSummary
                    )
                    if includesWebSearch {
                        Text("联网搜索会把搜索词发给 Tavily，并将返回的摘要交给回答模型。")
                    }
                    if includesTools {
                        Text("智能工具可按模型的请求读取公开网址，配置了搜索密钥时还可将模型生成的搜索词发给 Tavily。工具结果会发回模型。")
                    }
                    Text("同意后，今后主动发起的 AI 操作将使用你选择的服务商。你可以在「关于与隐私声明」中撤回授权。")
                        .font(.footnote).foregroundStyle(.secondary)

                    disclosureBlock(
                        icon: "key.fill",
                        title: String(localized: "密钥与本地存储"),
                        detail: String(localized: "API Key 与敏感请求头仅加密保存在本机 iOS 系统钥匙串（Keychain）中，开发者无法读取或收集你的任何对话与凭据。")
                    )

                    Text("AI 模型生成的内容可能存在不准确之处，涉及医疗、法律、财务等重要决策时请独立核实。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        onAccept()
                    } label: {
                        Text("同意并继续发送")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("暂不发送") {
                        dismiss()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("数据与隐私确认")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func disclosureBlock(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
        }
    }
}
