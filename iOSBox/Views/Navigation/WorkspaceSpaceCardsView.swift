import SwiftUI

/// Lightweight native footer anchored at the bottom of the iPad sidebar,
/// replacing the legacy mobile drawer card dock.
struct PadSidebarFooterView: View {
    let readyProviderCount: Int
    let monthlySpendText: String?
    let showsUsage: Bool
    let activeSpace: WorkspaceNavigation.PadSpace
    let onOpenQuickKeySetup: () -> Void
    let onOpenUsage: () -> Void
    let onOpenSettings: () -> Void

    @State private var preferences = AppPreferences.shared
    private var theme: DS.AccentTheme { preferences.accentTheme }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(DS.Surface.hairline)

            HStack(spacing: DS.Spacing.xs) {
                if readyProviderCount == 0 {
                    Button {
                        preferences.triggerSelectionHaptic()
                        onOpenQuickKeySetup()
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "bolt.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(theme.readableText)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("连接模型")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("选择服务商并验证")
                                    .font(.caption2)
                                    .foregroundStyle(DS.Surface.inkSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DS.Spacing.sm)
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                        .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                } else if showsUsage {
                    Button {
                        preferences.triggerSelectionHaptic()
                        onOpenUsage()
                    } label: {
                        providerStatus
                            .background(
                                activeSpace == .usage ? theme.softFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("用量")
                    .accessibilityIdentifier("用量")
                } else {
                    providerStatus
                }

                Button {
                    preferences.triggerSelectionHaptic()
                    onOpenSettings()
                } label: {
                    Image(systemName: activeSpace == .settings ? "gearshape.fill" : "gearshape")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(activeSpace == .settings ? theme.readableText : .secondary)
                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        .background(
                            activeSpace == .settings ? theme.softFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("设置")
                .accessibilityIdentifier("设置")
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
        }
        .background(DS.Surface.drawer)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.bottomDock")
    }

    private var providerStatus: some View {
        HStack(spacing: DS.Spacing.xs) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(readyProviderCount) 家服务商就绪")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let monthlySpendText, !monthlySpendText.isEmpty {
                    Text(monthlySpendText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.Surface.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
    }
}
