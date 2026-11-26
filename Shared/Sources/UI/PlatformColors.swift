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
        /// are a little darker than the Mac's nominal values (50% and 26% black). Set as the
        /// hierarchical styles of each pane's content (`macTextStrength`), inside its toolbar: a
        /// bar's menu drawn with them all but vanishes.
        static let secondaryText = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.6) : UIColor(white: 0, alpha: 0.56)
        })
        static let tertiaryText = Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.36) : UIColor(white: 0, alpha: 0.36)
        })
    }

    extension View {
        func macTextStrength() -> some View {
            foregroundStyle(Color.primary, Color.secondaryText, Color.tertiaryText)
        }
    }
#endif
