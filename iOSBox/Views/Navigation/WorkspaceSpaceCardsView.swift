import SwiftUI

struct WorkspaceSpaceCardsView: View {
    let bookCount: Int
    let onOpenSection: (AssistantListView.WorkshopSection) -> Void

    @State private var preferences = AppPreferences.shared

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            shortcut(.books, title: "书架", icon: "books.vertical.fill",
                     detail: bookCount > 0 ? String(localized: "\(bookCount) 本") : nil)
        }
    }

    private func shortcut(
        _ section: AssistantListView.WorkshopSection,
        title: LocalizedStringKey,
        icon: String,
        detail: String? = nil
    ) -> some View {
        Button {
            preferences.triggerSelectionHaptic()
            onOpenSection(section)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Surface.inkSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(DS.Surface.inkSecondary)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
            .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Surface.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WorkspaceBottomDockView: View {
    let readyProviderCount: Int
    let monthlySpendText: String?
    let showsUsage: Bool
    let onOpenQuickKeySetup: () -> Void
    let onOpenWorkshop: () -> Void
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
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DS.Spacing.sm)
                        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
                        .background(theme.softFill, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(theme.tintColor.opacity(0.28), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if showsUsage {
                    Button {
                        preferences.triggerSelectionHaptic()
                        onOpenUsage()
                    } label: {
                        providerStatus.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("用量")
                } else {
                    providerStatus
                }

                Button {
                    preferences.triggerSelectionHaptic()
                    onOpenWorkshop()
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("工作台")
                .accessibilityIdentifier("工作台")

                Button {
                    preferences.triggerSelectionHaptic()
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: DS.TouchTarget.minimum, height: DS.TouchTarget.minimum)
                        .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(DS.Surface.hairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置")
                .accessibilityIdentifier("设置")
            }
            .padding(.horizontal, DS.Spacing.md)
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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: DS.TouchTarget.minimum, alignment: .leading)
    }
}
