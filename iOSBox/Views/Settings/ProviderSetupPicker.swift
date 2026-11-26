import SwiftUI

struct ProviderSetupPicker: View {
    @Binding var draft: ProviderSetupDraft

    var body: some View {
        Section {
            Picker("服务商", selection: Binding(
                get: { draft.serviceID },
                set: { id in
                    if let template = ProviderTemplate.setupChoices.first(where: { $0.id == id }) {
                        draft.select(template)
                    }
                }
            )) {
                ForEach(ProviderTemplate.setupChoices) { template in
                    Text(verbatim: template.setupName).tag(template.id)
                }
            }
            .pickerStyle(.navigationLink)
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

struct ProviderSetupKeySection: View {
    @Binding var draft: ProviderSetupDraft
    @FocusState private var keyFocused: Bool

    var body: some View {
        Section {
            SecureField("输入或粘贴 API Key", text: $draft.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($keyFocused)
                .submitLabel(.done)
                .onSubmit { keyFocused = false }
                .accessibilityIdentifier("quickSetup.apiKey")
            if let issuer = ProviderTemplate.mismatchedIssuer(apiKey: draft.apiKey, baseURL: draft.baseURL) {
                ProviderKeyCorrection(issuer: issuer) {
                    keyFocused = false
                    draft = ProviderSetupDraft(template: issuer, apiKey: draft.apiKey)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            switch draft.serviceID {
            case ProviderTemplate.openAIResponses.id:
                Link("获取 OpenAI API Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
            case ProviderTemplate.openRouter.id:
                Text("使用 OpenRouter 签发的密钥（sk-or- 开头）。")
            case "ollama":
                Text("免鉴权的局域网服务可留空。")
            default:
                EmptyView()
            }
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
