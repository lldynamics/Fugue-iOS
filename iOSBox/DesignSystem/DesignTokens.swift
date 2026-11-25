import SwiftUI
import UIKit

/// Unified Night-Run (夜奔 / Fugue) paper-and-ink design system tokens.
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
        static let island: CGFloat = 26
        static let pill: CGFloat = 999
    }

    // MARK: - Touch Targets

    enum TouchTarget {
        static let minimum: CGFloat = 44
    }

    // MARK: - Adaptive Paper & Night-Ink Surfaces

    enum Surface {
        static let uiCanvas = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.067, green: 0.075, blue: 0.094, alpha: 1.0) // #111318 夜航深墨
                : UIColor(red: 0.980, green: 0.969, blue: 0.941, alpha: 1.0) // #FAF7F0 宣纸暖昼
        }

        static let uiGrouped = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.055, green: 0.063, blue: 0.078, alpha: 1.0) // #0E1014
                : UIColor(red: 0.957, green: 0.941, blue: 0.906, alpha: 1.0) // #F4F0E7
        }

        static let uiCard = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.102, green: 0.114, blue: 0.141, alpha: 1.0) // #1A1D24
                : UIColor(red: 0.996, green: 0.992, blue: 0.980, alpha: 1.0) // #FEFDFB
        }

        static let uiSubtle = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.094, green: 0.106, blue: 0.133, alpha: 1.0) // #181B22
                : UIColor(red: 0.945, green: 0.929, blue: 0.894, alpha: 1.0) // #F1EDE4
        }

        static let uiElevated = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.125, green: 0.141, blue: 0.173, alpha: 1.0) // #20242C
                : UIColor(red: 1.000, green: 0.996, blue: 0.988, alpha: 1.0) // #FFFEFC
        }

        static let uiDrawer = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.078, green: 0.086, blue: 0.110, alpha: 1.0) // #14161C
                : UIColor(red: 0.965, green: 0.949, blue: 0.918, alpha: 1.0) // #F6F2EA
        }

        static let canvas = Color(uiColor: uiCanvas)
        static let grouped = Color(uiColor: uiGrouped)
        static let card = Color(uiColor: uiCard)
        static let subtle = Color(uiColor: uiSubtle)
        static let elevated = Color(uiColor: uiElevated)
        static let drawer = Color(uiColor: uiDrawer)

        static let floatingIsland = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.110, green: 0.122, blue: 0.153, alpha: 0.93)
                : UIColor(red: 0.996, green: 0.992, blue: 0.982, alpha: 0.94)
        })

        static let hairline = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.085)
                : UIColor(red: 0.14, green: 0.12, blue: 0.09, alpha: 0.09)
        })

        static let strongBorder = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.14)
                : UIColor(red: 0.14, green: 0.12, blue: 0.09, alpha: 0.15)
        })

        static let neutralChipFill = Color(.tertiarySystemFill)

        /// High-contrast warm ink secondary foreground (WCAG AAA on Xuan-Paper & Night-Ink).
        static let inkSecondary = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.73, green: 0.71, blue: 0.68, alpha: 1.0)
                : UIColor(red: 0.33, green: 0.30, blue: 0.26, alpha: 1.0)
        })
    }

    // MARK: - Editorial Typography

    enum Typography {
        static func prose(size: CGFloat, serif: Bool, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: serif ? .serif : .default)
        }
    }

    /// Readable foregrounds for status text on the standard system surfaces.
    enum StatusText {
        static var warning: Color { AccentTheme.amber.readableText }
        static var success: Color { AccentTheme.teal.readableText }
    }

    // MARK: - Accent Theme

    enum AccentTheme: String, CaseIterable, Identifiable {
        case vermilion
        case cobalt
        case graphite
        case indigo
        case teal
        case amber

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .vermilion: return String(localized: "朱砂")
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
            case .vermilion:
                return adaptive(light: (0.643, 0.173, 0.086), dark: (0.937, 0.549, 0.424))
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
            case .vermilion:
                return adaptive(light: (0.682, 0.196, 0.102), dark: (0.737, 0.243, 0.141))
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

        /// High-contrast foreground for text and icons placed directly on system/paper surfaces.
        var readableText: Color {
            switch self {
            case .vermilion:
                return adaptive(light: (0.631, 0.165, 0.082), dark: (0.957, 0.588, 0.463))
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
