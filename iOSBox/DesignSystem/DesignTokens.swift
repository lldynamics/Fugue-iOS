import SwiftUI
import UIKit

/// Unified native-minimalist design system tokens for Fugue (夜奔).
enum DS {
    // MARK: - Spacing Scale

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: - Corner Radius Scale

    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 10
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: - Touch Targets

    enum TouchTarget {
        static let minimum: CGFloat = 44
    }

    // MARK: - Adaptive Semantic Surfaces

    enum Surface {
        static let canvas = Color(.systemBackground)
        static let grouped = Color(.systemGroupedBackground)
        static let card = Color(.secondarySystemGroupedBackground)
        static let subtle = Color(.secondarySystemBackground)
        static let elevated = Color(.tertiarySystemBackground)
        static let hairline = Color.primary.opacity(0.08)
        static let strongBorder = Color.primary.opacity(0.14)
        static let neutralChipFill = Color(.tertiarySystemFill)
    }

    // MARK: - Accent Theme

    enum AccentTheme: String, CaseIterable, Identifiable {
        case cobalt
        case graphite
        case indigo
        case teal
        case amber

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cobalt: return String(localized: "钴蓝")
            case .graphite: return String(localized: "石墨")
            case .indigo: return String(localized: "靛青")
            case .teal: return String(localized: "松青")
            case .amber: return String(localized: "暖珀")
            }
        }

        /// Balanced tint for native controls and `.tint(...)` across light and dark mode.
        var tintColor: Color {
            switch self {
            case .cobalt:
                return adaptive(light: (0.145, 0.388, 0.922), dark: (0.294, 0.514, 0.969))
            case .graphite:
                return adaptive(light: (0.149, 0.192, 0.271), dark: (0.612, 0.671, 0.761))
            case .indigo:
                return adaptive(light: (0.294, 0.255, 0.816), dark: (0.490, 0.467, 0.965))
            case .teal:
                return adaptive(light: (0.059, 0.463, 0.431), dark: (0.176, 0.722, 0.678))
            case .amber:
                return adaptive(light: (0.718, 0.333, 0.082), dark: (0.914, 0.525, 0.243))
            }
        }

        /// High-contrast solid fill paired with `solidForeground` (WCAG AA compliant).
        var solidFill: Color {
            switch self {
            case .cobalt:
                return adaptive(light: (0.145, 0.388, 0.922), dark: (0.184, 0.420, 0.902))
            case .graphite:
                return adaptive(light: (0.149, 0.192, 0.271), dark: (0.239, 0.275, 0.341))
            case .indigo:
                return adaptive(light: (0.294, 0.255, 0.816), dark: (0.345, 0.310, 0.859))
            case .teal:
                return adaptive(light: (0.059, 0.463, 0.431), dark: (0.075, 0.514, 0.478))
            case .amber:
                return adaptive(light: (0.706, 0.325, 0.075), dark: (0.761, 0.365, 0.114))
            }
        }

        var solidForeground: Color {
            .white
        }

        /// High-contrast foreground for text and icons placed directly on system surfaces.
        var readableText: Color {
            switch self {
            case .cobalt:
                return adaptive(light: (0.114, 0.306, 0.847), dark: (0.486, 0.698, 1.0))
            case .graphite:
                return adaptive(light: (0.118, 0.161, 0.231), dark: (0.855, 0.886, 0.933))
            case .indigo:
                return adaptive(light: (0.263, 0.220, 0.792), dark: (0.647, 0.631, 0.992))
            case .teal:
                return adaptive(light: (0.059, 0.427, 0.400), dark: (0.337, 0.847, 0.796))
            case .amber:
                return adaptive(light: (0.647, 0.294, 0.063), dark: (0.961, 0.635, 0.376))
            }
        }

        /// Soft tinted surface for subtle chips, badges, and active highlights.
        var softFill: Color {
            tintColor.opacity(0.13)
        }

        /// Preview swatch color used in Appearance settings.
        var swatchColor: Color {
            solidFill
        }

        private func adaptive(
            light: (CGFloat, CGFloat, CGFloat),
            dark: (CGFloat, CGFloat, CGFloat)
        ) -> Color {
            Color(uiColor: UIColor { traits in
                let c = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1.0)
            })
        }
    }
}
