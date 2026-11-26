import SwiftUI

// MARK: - Night-Run Brand Seal Mark

struct FugueSealMark: View {
    var character: String = "奔"
    var size: CGFloat = 24
    var theme: DS.AccentTheme = AppPreferences.shared.accentTheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(5, size * 0.24), style: .continuous)
                .fill(theme.solidFill)
                .frame(width: size, height: size)
            Text(verbatim: character)
                .font(.system(size: size * 0.56, weight: .bold, design: .serif))
                .foregroundStyle(theme.solidForeground)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Unified Badge

struct DSBadge: View {
    enum Style {
        case neutral
        case accent(DS.AccentTheme)
        case tinted(Color)
    }

    private enum LabelContent {
        case localized(LocalizedStringKey)
        case verbatim(String)
    }

    private let content: LabelContent
    var icon: String?
    var style: Style

    init(
        text: LocalizedStringKey,
        icon: String? = nil,
        style: Style = .neutral
    ) {
        self.content = .localized(text)
        self.icon = icon
        self.style = style
    }

    @_disfavoredOverload
    init<S: StringProtocol>(
        text: S,
        icon: String? = nil,
        style: Style = .neutral
    ) {
        self.content = .verbatim(String(text))
        self.icon = icon
        self.style = style
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            labelView
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(backgroundColor, in: Capsule())
    }

    @ViewBuilder
    private var labelView: some View {
        switch content {
        case .localized(let key):
            Text(key)
        case .verbatim(let raw):
            Text(verbatim: raw)
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .neutral:
            return .secondary
        case .accent(let theme):
            return theme.readableText
        case .tinted:
            return .primary
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .neutral:
            return Color.secondary.opacity(0.12)
        case .accent(let theme):
            return theme.softFill
        case .tinted(let color):
            return color.opacity(0.14)
        }
    }
}

// MARK: - Unified Icon Tile

struct DSIconTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 40
    var cornerRadius: CGFloat = DS.Radius.md

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: size, height: size)
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Unified Metric Tile (KPI Cards)

struct DSMetricTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var valueTint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(1)

            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Spacing.md)
        .background(DS.Surface.card, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(DS.Surface.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Card & Floating Island Modifiers

struct DSCardModifier: ViewModifier {
    var cornerRadius: CGFloat = DS.Radius.lg
    var fill: Color = DS.Surface.subtle
    var borderColor: Color = DS.Surface.hairline
    var padding: CGFloat = DS.Spacing.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }
}

struct DSFloatingIslandModifier: ViewModifier {
    var cornerRadius: CGFloat = DS.Radius.island

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(DS.Surface.floatingIsland)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DS.Surface.strongBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 6)
    }
}

extension View {
    func dsCard(
        cornerRadius: CGFloat = DS.Radius.lg,
        fill: Color = DS.Surface.subtle,
        borderColor: Color = DS.Surface.hairline,
        padding: CGFloat = DS.Spacing.md
    ) -> some View {
        modifier(DSCardModifier(
            cornerRadius: cornerRadius,
            fill: fill,
            borderColor: borderColor,
            padding: padding
        ))
    }

    func dsFloatingIsland(cornerRadius: CGFloat = DS.Radius.island) -> some View {
        modifier(DSFloatingIslandModifier(cornerRadius: cornerRadius))
    }
}
