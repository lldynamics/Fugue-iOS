import SwiftUI
import SwiftData

struct ShareProviderAccessSection: View {
    let provider: ProviderConfig
    var onBeforeToggle: (() -> Void)? = nil
    @Environment(\.modelContext) private var context
    @State private var isEnabled = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("允许系统分享使用此服务商", isOn: Binding(get: { isEnabled }, set: updateAccess))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("重试") { updateAccess(isEnabled) }
            }
        } header: { Text("系统分享") } footer: {
            Text("启用后，分享扩展可读取此服务商的模型配置与共享钥匙串中的凭据。关闭后新的分享请求将无法使用它，已发出的请求不受影响。")
        }
        .onAppear { isEnabled = SystemIntegration.shared.isEnabled(provider.id) }
    }

    private func updateAccess(_ enabled: Bool) {
        onBeforeToggle?()
        isEnabled = enabled
        do {
            try SystemIntegration.shared.setEnabled(enabled, providerID: provider.id, context: context)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
