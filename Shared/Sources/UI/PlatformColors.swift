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

    static var tertiaryLabel: Color {
        #if os(macOS)
            Color(nsColor: .tertiaryLabelColor)
        #else
            .tertiaryText
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

#if os(iOS)
    extension Color {
        /// Secondary and tertiary text as strong as they read on the Mac. iOS's own label colors
        /// are a shade lighter, and its text isn't smoothed heavier as the Mac's is, so these
        /// are a little darker than the Mac's nominal values (50% and 26% black).
        static let secondaryText = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.6) : UIColor(white: 0, alpha: 0.56)
        })
        static let tertiaryText = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.36) : UIColor(white: 0, alpha: 0.36)
        })
    }

    extension View {
        /// Makes them the hierarchical styles (`.secondary`, `.tertiary`) of the text within.
        /// Only around text: any foreground style set from outside also takes over the labels of
        /// the buttons and menus inside, which then lose their own color (a tinted button's blue,
        /// a prominent one's white) and come out black.
        func macTextStrength() -> some View {
            foregroundStyle(.foreground, Color.secondaryText, Color.tertiaryText)
        }
    }
#endif
