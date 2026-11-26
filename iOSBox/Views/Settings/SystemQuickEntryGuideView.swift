import AppIntents
import SwiftData
import SwiftUI

struct SystemQuickEntryGuideView: View {
    var onDismissSettings: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(WidgetSnapshotService.showRecentTitlesKey) private var showsRecentTitles = false
    @State private var isTriggeringQuickAction = false

    @MainActor
    static func triggerQuickEntryPreview(
        _ action: QuickEntryAction,
        router: SystemEntryRouter = .shared,
        onDismissSettings: (() -> Void)?,
        popNavigation: () -> Void,
        sheetDismissDelay: Duration = .milliseconds(450),
        navigationPopDelay: Duration = .milliseconds(100)
    ) async {
        if let onDismissSettings {
            onDismissSettings()
            if sheetDismissDelay > .zero {
                try? await Task.sleep(for: sheetDismissDelay)
            }
        } else {
            popNavigation()
            if navigationPopDelay > .zero {
                try? await Task.sleep(for: navigationPopDelay)
            }
        }
        router.pendingQuickAction = action
    }

    var body: some View {
        Form {
            Section("立即体验快捷直达") {
                ForEach(QuickEntryAction.allCases) { action in
                    Button {
                        guard !isTriggeringQuickAction else { return }
                        isTriggeringQuickAction = true
                        let closeSheet = onDismissSettings
                        let popView = dismiss
                        Task { @MainActor in
                            await Self.triggerQuickEntryPreview(
                                action,
                                onDismissSettings: closeSheet,
                                popNavigation: { popView() }
                            )
                            isTriggeringQuickAction = false
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title)
                                    .foregroundStyle(.primary)
                                Text(action.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: action.systemImage)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            Section {
                Toggle("在桌面小组件显示最近对话标题", isOn: Binding(
                    get: { showsRecentTitles },
                    set: { enabled in
                        showsRecentTitles = enabled
                        WidgetSnapshotService.shared.setShowsRecentTitles(enabled, context: modelContext)
                    }
                ))
            } header: {
                Text("小组件隐私设置")
            } footer: {
                Text("默认关闭。开启后，中号桌面小组件除 4 个快捷动作外，还会额外展示最多 3 条最近对话标题（优先显示置顶对话），并在锁屏/隐私场景自动隐藏。")
            }

            Section("添加方式指南") {
                guideRow(
                    icon: "rectangle.3.group",
                    title: String(localized: "桌面与锁屏小组件"),
                    detail: String(localized: "在主屏幕或锁屏长按空白处点击「+」，搜索「夜奔」，可选小号/中号桌面小组件或锁屏圆角/矩形小组件；长按小号小组件点「编辑小组件」可切换默认直达功能。")
                )

                guideRow(
                    icon: "switch.2",
                    title: String(localized: "控制中心与锁屏底部按钮"),
                    detail: String(localized: "下拉打开控制中心，点击左上角「+」→「添加控制」，即可添加「新建对话」「录音纪要」「扫描文档」「收藏知识库」；同样可替换锁屏左下角或右下角快捷按钮。")
                )

                guideRow(
                    icon: "button.horizontal.top.press",
                    title: String(localized: "操作按钮（Action Button）与快捷指令"),
                    detail: String(localized: "前往系统「设置」→「操作按钮」→「快捷指令」，或在下方快捷指令库中选择「开始录音纪要」「扫描文档转文字」或「运行 AI 技能」即可硬件按键一键唤醒。")
                )

                ShortcutsLink()
                    .shortcutsLinkStyle(.automatic)
            }
        }
        .navigationTitle("系统快捷入口")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
