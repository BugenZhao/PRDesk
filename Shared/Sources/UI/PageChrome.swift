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
    ///
    /// The web view reports from inside its own layout at times, and UIKit takes whatever
    /// observed state a view reads during its layout as a reason to lay it out again when that
    /// state changes: a web view laid out at every step of a scroll loses its overscroll (the
    /// layout puts the offset back in bounds). So `report` and `setChrome` read only the
    /// unobserved copies kept here, and write the observed properties.
    @MainActor
    @Observable
    final class PageScroll {
        private(set) var offset: CGFloat = 0
        /// All the chrome over the page, top to bottom.
        private(set) var chromeHeight: CGFloat = 0
        /// The chrome's title has left with the page (or, where it has none, nearly all of the
        /// chrome): the bar has to say what the page is. Set only when it flips, so a view
        /// reading it isn't redrawn at every step of a scroll.
        private(set) var isChromeAway = false
        /// Room to leave under the page's end, for what floats over the pane's foot.
        var bottomRoom: CGFloat = 0

        /// The web view host reporting, so one that goes away doesn't reset what its successor set.
        @ObservationIgnored var source: ObjectIdentifier?
        @ObservationIgnored private var heights: [UUID: CGFloat] = [:]
        /// How far down the chrome its title ends.
        @ObservationIgnored private var titleExtent: CGFloat = 0
        /// What the observed properties hold, to read without being observed.
        @ObservationIgnored private var current = (offset: CGFloat(0), chromeHeight: CGFloat(0), isChromeAway: false)

        /// The page's offset from its top; negative while it is pulled past it.
        func report(offset: CGFloat) {
            guard abs(current.offset - offset) > 0.2 else { return }
            current.offset = offset
            self.offset = offset
            updateAway()
        }

        func setChrome(_ id: UUID, height: CGFloat?) {
            heights[id] = height
            let total = heights.values.reduce(0, +)
            guard abs(total - current.chromeHeight) > 0.5 else { return }
            current.chromeHeight = total
            chromeHeight = total
            updateAway()
        }

        func setTitleExtent(_ extent: CGFloat) {
            titleExtent = extent
            updateAway()
        }

        private func updateAway() {
            let limit = titleExtent > 0 ? titleExtent : current.chromeHeight - 24
            let away = current.chromeHeight > 0 && current.offset > limit
            guard away != current.isChromeAway else { return }
            current.isChromeAway = away
            isChromeAway = away
        }
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
                .background(Color.pageGround)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scroll?.setChrome(id, height: $0) }
                .onDisappear { scroll?.setChrome(id, height: nil) }
                // With the page both ways: up and away, and down when the page is pulled past its
                // top. Not past its own height by much: an offset in the thousands buys nothing.
                .offset(y: -min(scroll?.offset ?? 0, 3000))
        }
    }
#endif
