import SwiftUI

struct AppearanceSettingsView: View {
    @State private var preferences = AppPreferences.shared
    @ScaledMetric(relativeTo: .body) private var baseBodySize: CGFloat = 17

    var body: some View {
        Form {
            Section {
                Picker("对话正文大小", selection: $preferences.fontScale) {
                    ForEach(AppPreferences.FontScaleOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Text("排版预览")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("清晰、自然的排版能让长对话与推理内容更易阅读。")
                        .font(.system(size: baseBodySize * preferences.fontScale))
                        .lineSpacing(3.5)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.vertical, 4)
            } header: {
                Text("阅读排版")
            }

            Section {
                Toggle("代码块默认显示行号", isOn: $preferences.codeDefaultLineNumbers)
                Toggle("思考完成后自动折叠思考链", isOn: $preferences.autoCollapseReasoning)
                Toggle("操作与生成完成触感反馈", isOn: $preferences.hapticFeedbackEnabled)
            } header: {
                Text("消息与交互")
            } footer: {
                Text("思考流式输出期间会显示限高实时预览窗；开启自动折叠后，正文开始输出时会自动收起思考过程。")
            }

            if !preferences.recentModelIDs.isEmpty {
                Section("快捷记录") {
                    Button(role: .destructive) {
                        preferences.recentModelIDs = []
                    } label: {
                        Label("清空最近使用的模型记录", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("阅读与交互偏好")
        .navigationBarTitleDisplayMode(.inline)
    }
}
