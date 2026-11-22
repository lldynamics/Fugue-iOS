import SwiftUI

struct AppearanceSettingsView: View {
    @State private var preferences = AppPreferences.shared
    @ScaledMetric(relativeTo: .body) private var baseBodySize: CGFloat = 17

    var body: some View {
        Form {
            Section {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(DS.AccentTheme.allCases) { theme in
                        let selected = preferences.accentTheme == theme
                        Button {
                            preferences.accentTheme = theme
                            preferences.triggerSelectionHaptic()
                        } label: {
                            VStack(spacing: DS.Spacing.xs) {
                                ZStack {
                                    Circle()
                                        .fill(theme.swatchColor)
                                        .frame(width: 28, height: 28)
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(3)
                                .overlay(
                                    Circle()
                                        .strokeBorder(selected ? theme.readableText : Color.clear, lineWidth: 2)
                                )

                                Text(theme.displayName)
                                    .font(.caption2.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.vertical, DS.Spacing.xxs)
            } header: {
                Text("主题强调色")
            }

            Section {
                Picker("对话正文大小", selection: $preferences.fontScale) {
                    ForEach(AppPreferences.FontScaleOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("排版预览")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        HStack {
                            Spacer(minLength: 48)
                            Text("帮我总结这一段的核心结论")
                                .font(.system(size: baseBodySize * preferences.fontScale))
                                .foregroundStyle(preferences.accentTheme.solidForeground)
                                .padding(.horizontal, DS.Spacing.md)
                                .padding(.vertical, DS.Spacing.sm)
                                .background(
                                    preferences.accentTheme.solidFill,
                                    in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                )
                        }

                        Text("清晰、克制的排版能让长对话与推理内容更易阅读。")
                            .font(.system(size: baseBodySize * preferences.fontScale))
                            .lineSpacing(3.5)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .dsCard(cornerRadius: DS.Radius.md, fill: DS.Surface.subtle, padding: DS.Spacing.md)
                }
                .padding(.vertical, DS.Spacing.xxs)
            } header: {
                Text("阅读排版")
            }

            Section {
                Toggle("极简日常模式（界面减法）", isOn: $preferences.simpleDailyMode)
            } header: {
                Text("界面模式")
            } footer: {
                Text("开启后自动隐藏群聊、竞技场、Agent 工具、分支与名人视角等进阶控件，保留日常对话、拍照识图、文档解析、录音纪要、联网搜索与纯文本复制。")
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
