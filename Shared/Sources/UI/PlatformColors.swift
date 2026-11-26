import SwiftUI

#if os(macOS)
    typealias PlatformColor = NSColor
#else
    typealias PlatformColor = UIColor
#endif

/// System colors the shared views use, from each platform's palette.
extension Color {
    /// Behind text the viewer types or previews.
    static var textBackground: Color {
        #if os(macOS)
            Color(nsColor: .textBackgroundColor)
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }

    #if os(iOS)
        /// The ground of the detail's pages on iOS, below the header: a grouped list's, so that
        /// the pages' cards and diffs (a grouped list's cells in color) stand out on it as they
        /// do on the Mac's window.
        static var pageGround: Color { Color(uiColor: .systemGroupedBackground) }
    #endif

    static var separator: Color {
        #if os(macOS)
            Color(nsColor: .separatorColor)
        #else
            Color(uiColor: .separator)
        #endif
    }
}

/// Gray text, by name rather than by the hierarchical styles (`.secondary`, `.tertiary`).
///
/// On the Mac these are the system's own. On iOS they are the Mac's values (50% and 26% black,
/// 55% and 25% white), iOS's own label grays being a shade lighter. Use these for every gray
/// text and symbol in a view an iPad shows: a hierarchical style on a `Text` came out as iOS's
/// own, a level lighter again inside a view that was gray already, whatever styles were set
/// around it.
extension Color {
    static var secondaryText: Color {
        #if os(macOS)
            .secondary
        #else
            Color(uiColor: UIColor { traits in
                UIColor(white: traits.userInterfaceStyle == .dark ? 1 : 0, alpha: traits.userInterfaceStyle == .dark ? 0.55 : 0.5)
            })
        #endif
    }

    static var tertiaryText: Color {
        #if os(macOS)
            Color(nsColor: .tertiaryLabelColor)
        #else
            Color(uiColor: UIColor { traits in
                UIColor(white: traits.userInterfaceStyle == .dark ? 1 : 0, alpha: traits.userInterfaceStyle == .dark ? 0.25 : 0.26)
            })
        #endif
    }
}

extension ShapeStyle where Self == AnyShapeStyle {
    /// On the Mac the hierarchical style itself, which follows what it is drawn in.
    static var secondaryText: AnyShapeStyle {
        #if os(macOS)
            AnyShapeStyle(.secondary)
        #else
            AnyShapeStyle(Color.secondaryText)
        #endif
    }

    static var tertiaryText: AnyShapeStyle {
        #if os(macOS)
            AnyShapeStyle(.tertiary)
        #else
            AnyShapeStyle(Color.tertiaryText)
        #endif
    }
}

/// Diff stat colors, a shade deeper than the system green and red (GitHub's diff palette): as
/// the platform's color for cells that are drawn (the Mac's list), and as SwiftUI's.
extension PlatformColor {
    static let diffAdded = adaptive(light: (0.10, 0.50, 0.22), dark: (0.18, 0.63, 0.26))
    static let diffRemoved = adaptive(light: (0.81, 0.13, 0.18), dark: (0.85, 0.21, 0.20))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> PlatformColor {
        #if os(macOS)
            NSColor(name: nil) { appearance in
                let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            }
        #else
            UIColor { traits in
                let rgb = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            }
        #endif
    }
}

extension Color {
    static let diffAdded = Color(PlatformColor.diffAdded)
    static let diffRemoved = Color(PlatformColor.diffRemoved)
}
