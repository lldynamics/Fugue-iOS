import SwiftUI
import UIKit

struct ProviderSetupPicker: View {
    @Binding var draft: ProviderSetupDraft

    private var selectedTemplate: ProviderTemplate? {
        ProviderTemplate.setupChoices.first { $0.id == draft.serviceID }
    }

    var body: some View {
        Section {
            NavigationLink {
                ProviderTemplateSelectionView(selectedID: draft.serviceID) { template in
                    draft.select(template)
                }
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    DSIconTile(
                        systemImage: selectedTemplate?.iconSymbol ?? draft.iconSymbol,
                        tint: Color(hex: selectedTemplate?.accentHex ?? draft.accentHex),
                        size: 30,
                        cornerRadius: DS.Radius.sm
                    )
                    Text("服务商")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(verbatim: selectedTemplate?.setupName ?? draft.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityIdentifier("providerSetup.service")
        } header: {
            Text("选择提供 API Key 的服务商")
        } footer: {
            if let host = URLComponents(string: draft.baseURL)?.host, host != "api.example.com" {
                Text(verbatim: "\(host) · \(draft.protocolType.shortBadge)")
            }
        }
    }
}

private struct ProviderTemplateSelectionView: View {
    let selectedID: String
    let onSelect: (ProviderTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(ProviderTemplate.Category.allCases) { category in
                let items = ProviderTemplate.setupChoices.filter { $0.category == category }
                if !items.isEmpty {
                    Section(category.title) {
                        ForEach(items) { template in
                            Button {
                                onSelect(template)
                                dismiss()
                            } label: {
                                HStack(alignment: .center, spacing: DS.Spacing.md) {
                                    DSIconTile(
                                        systemImage: template.iconSymbol,
                                        tint: Color(hex: template.accentHex),
                                        size: 36,
                                        cornerRadius: DS.Radius.sm
                                    )
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(verbatim: template.setupName)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                            DSBadge(text: template.protocolType.shortBadge, style: .neutral)
                                        }
                                        if !template.note.isEmpty {
                                            Text(template.note)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    if template.id == selectedID {
                                        Image(systemName: "checkmark")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: template.setupName))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.Surface.grouped)
        .navigationTitle("选择服务商")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProviderSetupKeySection: View {
    @Binding var draft: ProviderSetupDraft
    @FocusState private var keyFocused: Bool
    @State private var revealAPIKey = false
    @State private var smartPasteNote: String?
    @State private var isAuthorizingOpenRouter = false
    @State private var oauthErrorMessage: String?

    private var selectedTemplate: ProviderTemplate? {
        ProviderTemplate.setupChoices.first { $0.id == draft.serviceID }
    }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Group {
                    if revealAPIKey {
                        TextField("输入或粘贴 API Key", text: $draft.apiKey)
                    } else {
                        SecureField("输入或粘贴 API Key", text: $draft.apiKey)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
                .focused($keyFocused)
                .submitLabel(.done)
                .onSubmit { keyFocused = false }
                .accessibilityIdentifier("quickSetup.apiKey")
                .onChange(of: draft.apiKey) { _, newValue in
                    if ClipboardProviderParser.looksLikeMultiFieldSnippet(newValue),
                       let candidate = ClipboardProviderParser.parse(newValue) {
                        keyFocused = false
                        draft.apply(candidate)
                        smartPasteNote = candidate.confidenceNote
                    } else if newValue.isEmpty {
                        smartPasteNote = nil
                    }
                }

                if !draft.apiKey.isEmpty {
                    Button {
                        draft.apiKey = ""
                        smartPasteNote = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: DS.TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除 API Key")
                }

                Button {
                    revealAPIKey.toggle()
                } label: {
                    Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealAPIKey ? String(localized: "隐藏 API Key") : String(localized: "显示 API Key"))

                Button {
                    pasteFromClipboard()
                } label: {
                    Text("粘贴")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if let smartPasteNote {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(DS.StatusText.success)
                    Text(smartPasteNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if draft.serviceID == ProviderTemplate.openRouter.id {
                Button {
                    Task { await startOpenRouterOAuth() }
                } label: {
                    HStack(spacing: 6) {
                        if isAuthorizingOpenRouter {
                            ProgressView().controlSize(.small)
                            Text("正在等待 OpenRouter 授权…")
                        } else {
                            Image(systemName: "person.badge.key.fill")
                            Text("一键登录 OpenRouter 自动获取 Key")
                        }
                    }
                    .font(.subheadline.weight(.medium))
                }
                .disabled(isAuthorizingOpenRouter)
            }

            if let oauthErrorMessage {
                Text(oauthErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(DS.StatusText.error)
            }

            if let issuer = ProviderTemplate.mismatchedIssuer(apiKey: draft.apiKey, baseURL: draft.baseURL) {
                ProviderKeyCorrection(issuer: issuer) {
                    keyFocused = false
                    smartPasteNote = nil
                    oauthErrorMessage = nil
                    draft = ProviderSetupDraft(template: issuer, apiKey: draft.apiKey)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if draft.serviceID == ProviderTemplate.openRouter.id {
                    Text("使用 OpenRouter 签发的密钥（sk-or- 开头），支持直接粘贴整段配置文本自动识别。")
                } else if draft.serviceID == "ollama" {
                    Text("免鉴权的局域网服务可留空。")
                } else if draft.serviceID == "custom_openai" {
                    Text("可直接粘贴含接口地址、协议或模型 ID 的整段配置文本自动填表。")
                }
                if let template = selectedTemplate, let url = template.keyConsoleURL {
                    if template.id == ProviderTemplate.openAIResponses.id {
                        Link("获取 OpenAI API Key", destination: url)
                    } else {
                        Link("前往 \(template.setupName) 获取 API Key", destination: url)
                    }
                }
            }
        }
    }

    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        keyFocused = false
        if ClipboardProviderParser.looksLikeMultiFieldSnippet(raw),
           let candidate = ClipboardProviderParser.parse(raw) {
            draft.apply(candidate)
            smartPasteNote = candidate.confidenceNote
            oauthErrorMessage = nil
        } else {
            smartPasteNote = nil
            oauthErrorMessage = nil
            draft.apiKey = raw
        }
    }

    @MainActor
    private func startOpenRouterOAuth() async {
        keyFocused = false
        oauthErrorMessage = nil
        isAuthorizingOpenRouter = true
        defer { isAuthorizingOpenRouter = false }
        do {
            let provisionedKey = try await OpenRouterOAuthCoordinator.shared.authorize()
            draft.apiKey = provisionedKey
            smartPasteNote = String(localized: "已完成 OpenRouter 授权并自动填入专属 API Key。")
        } catch OpenRouterOAuthError.cancelled {
            return
        } catch {
            oauthErrorMessage = error.localizedDescription
        }
    }
}

struct ProviderSetupProtocolPicker: View {
    @Binding var draft: ProviderSetupDraft

    var body: some View {
        Picker("API 协议类型", selection: $draft.protocolType) {
            ForEach(APIProtocolType.allCases) { proto in
                Text(verbatim: proto == .openAICompatible ? proto.shortBadge : proto.displayName).tag(proto)
            }
        }
    }
}

struct ProviderKeyCorrection: View {
    let issuer: ProviderTemplate
    let correct: () -> Void

    var body: some View {
        Button(action: correct) {
            VStack(alignment: .leading, spacing: 4) {
                Text("这把密钥的前缀属于 \(issuer.setupName)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("改用 \(issuer.setupName)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("providerSetup.correctIssuer")
    }
}
