import SwiftUI

/// What sits over a detail page (the commits, a bar of counts and options). On the Mac it stays
/// put above the page. On iOS it is laid over the top of the page and leaves with it as the page
/// scrolls, so reading gets the whole pane.
extension View {
    func pageBar(@ViewBuilder _ bar: () -> some View) -> some View {
        #if os(macOS)
            VStack(spacing: 0) {
                bar()
                Divider()
                self
            }
        #else
            safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    bar()
                    Divider()
                }
                .scrollsAway()
            }
        #endif
    }
}

#if os(iOS)
    /// How far the page in a pane has scrolled from its top, which the pane's web view reports
    /// (`WebDocumentView`), and how tall the chrome laid over the page's top is: the web view
    /// starts the page below it, and the chrome follows the page up as it scrolls.
    @MainActor
    @Observable
    final class PageScroll {
        var offset: CGFloat = 0
        /// The web view host reporting, so one that goes away doesn't reset what its successor set.
        @ObservationIgnored var source: ObjectIdentifier?

        /// All the chrome over the page, top to bottom.
        private(set) var chromeHeight: CGFloat = 0
        @ObservationIgnored private var heights: [UUID: CGFloat] = [:]

        func setChrome(_ id: UUID, height: CGFloat?) {
            heights[id] = height
            let total = heights.values.reduce(0, +)
            if abs(total - chromeHeight) > 0.5 { chromeHeight = total }
        }

        /// The chrome has left with the page: something else has to say what the page is.
        var isChromeAway: Bool { chromeHeight > 0 && offset > chromeHeight - 24 }
    }

    extension View {
        /// Moves the view up with the page under it, as if it were the page's own top. The room
        /// it had stays the page's top inset, so the page starts under it and nothing jumps.
        func scrollsAway() -> some View {
            modifier(ScrollsAway())
        }
    }

    private struct ScrollsAway: ViewModifier {
        @Environment(PageScroll.self) private var scroll: PageScroll?
        @State private var id = UUID()

        func body(content: Content) -> some View {
            content
                .background(Color(uiColor: .systemBackground))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll?.setChrome(id, height: $0) }
                .onDisappear { scroll?.setChrome(id, height: nil) }
                // Not past its own height by much: an offset in the thousands buys nothing.
                .offset(y: -min(max(scroll?.offset ?? 0, 0), 3000))
        }
    }
#endif
