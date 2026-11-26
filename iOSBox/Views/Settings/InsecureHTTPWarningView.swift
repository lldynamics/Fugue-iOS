import SwiftUI

/// Inline warning for `http://` Base URLs that point at a public host. iOS App Transport
/// Security blocks those loads (only local / LAN HTTP is allowed), and keys would be sent
/// in clear text anyway.
struct InsecureHTTPWarningView: View {
    let baseURL: String

    var body: some View {
        if NetworkLocation.isPlainHTTPToPublicHost(baseURL: baseURL) {
            Label {
                Text("该地址使用 http:// 且指向公网：iOS 会阻止此类明文连接，API Key 与对话内容也会以明文传输。请改用 https:// 地址；局域网内的 http 服务（如 Ollama）不受影响。")
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
            }
            .font(.caption2)
            .foregroundStyle(DS.StatusText.error)
        }
    }
}
