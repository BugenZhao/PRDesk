import SwiftUI

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
