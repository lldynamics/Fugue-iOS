import SwiftUI

struct AppearanceSettingsView: View {
    @State private var preferences = AppPreferences.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var baseBodySize: CGFloat = 17

    var body: some View {
        Form {
            Section {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: DS.Spacing.xs),
                        count: dynamicTypeSize.isAccessibilitySize ? 3 : 6
                    ),
                    spacing: DS.Spacing.sm
                ) {
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
                Text("主题强调色（宣纸昼 / 夜航墨自适应）")
            }

            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    messageStylePicker.pickerStyle(.inline)
                    fontScalePicker.pickerStyle(.inline)
                } else {
                    messageStylePicker.pickerStyle(.segmented)
                    fontScalePicker.pickerStyle(.segmented)
                }

                Toggle("长文与回复使用人文衬线体", isOn: $preferences.literarySerifBody)

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("排版预览")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: DS.Spacing.md) {
                        if preferences.chatMessageStyle == .editorial {
                            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(preferences.accentTheme.solidFill)
                                    .frame(width: 2.5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("提问")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Text("帮我总结这一段的核心结论")
                                        .font(DS.Typography.prose(
                                            size: baseBodySize * preferences.fontScale,
                                            serif: preferences.literarySerifBody,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(.primary)
                                }
                            }
                        } else {
                            HStack {
                                Spacer(minLength: 48)
                                Text("帮我总结这一段的核心结论")
                                    .font(.system(size: baseBodySize * preferences.fontScale))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, DS.Spacing.md)
                                    .padding(.vertical, DS.Spacing.sm)
                                    .background(
                                        preferences.accentTheme.softFill,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                                            .strokeBorder(preferences.accentTheme.tintColor.opacity(0.32), lineWidth: 1)
                                    )
                            }
                        }

                        Text("清晰、克制的纸墨排版能让长对话与复调推演更耐读。")
                            .font(DS.Typography.prose(
                                size: baseBodySize * preferences.fontScale,
                                serif: preferences.literarySerifBody
                            ))
                            .lineSpacing(5)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .dsCard(cornerRadius: DS.Radius.md, fill: DS.Surface.canvas, padding: DS.Spacing.md)
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
                Text("开启后收起新建群聊、邀请和部分对话工具。多模型对比由下方开关控制，用量可在设置中查看。")
            }

            Section {
                Toggle("AI 英语私教（无课本跟读与日志）", isOn: $preferences.moduleEnglishCoachEnabled)
                Toggle("项目空间", isOn: $preferences.moduleProjectsEnabled)
                Toggle("书中好友与角色目录", isOn: $preferences.moduleBookFriendsEnabled)
                Toggle("圆桌群聊", isOn: $preferences.moduleGroupChatEnabled)
                Toggle("助学闪卡与互动导师", isOn: $preferences.moduleStudyFlashcardsEnabled)
                Toggle("多模型并发对比", isOn: $preferences.moduleArenaEnabled)
                Toggle("侧栏用量快捷入口", isOn: $preferences.moduleUsageTabEnabled)
            } header: {
                Text("空间模块开关")
            } footer: {
                Text("可按个人使用习惯隐藏不常用的进阶模块，关闭仅隐藏入口，不会删除已保存的数据。")
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
        .scrollContentBackground(.hidden)
        .background(DS.Surface.grouped)
        .navigationTitle("阅读与交互偏好")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var messageStylePicker: some View {
        Picker("对话消息样式", selection: $preferences.chatMessageStyle) {
            ForEach(AppPreferences.ChatMessageStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }
    }

    private var fontScalePicker: some View {
        Picker("对话正文大小", selection: $preferences.fontScale) {
            ForEach(AppPreferences.FontScaleOption.allCases) { option in
                Text(option.label).tag(option.rawValue)
            }
        }
    }
}
