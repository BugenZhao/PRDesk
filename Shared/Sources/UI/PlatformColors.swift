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
