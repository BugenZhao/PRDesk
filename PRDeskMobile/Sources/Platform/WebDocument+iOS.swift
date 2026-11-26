import SwiftUI
import UIKit
import WebKit

/// The page's web view on iOS: WebKit's own, with a clear background.
typealias DocumentWebView = WKWebView

/// The iOS side of `WebDocument`: the view hosting the page, and its menus (people, reactions,
/// files), which the desk shows as popovers (`PageMenu`).
extension WebDocument {
    func prepare(_ webView: DocumentWebView) {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Reading on puts the keyboard away: a phone's has no key for that.
        webView.scrollView.keyboardDismissMode = .onDrag
        // No edge effect of the bar's over the page: see `DetailPane`, which covers the page
        // behind the bar itself.
        webView.scrollView.topEdgeEffect.isHidden = true
    }

    /// The page gives the point in its own coordinates, which are the web view's.
    func showMenu(_ request: MenuRequest, at point: CGPoint) {
        menuHandler?(request, webView.convert(point, to: nil))
    }
}

/// A document's page. It reaches up under whatever is laid over its top (the navigation bar, a
/// pane's header, a `pageBar`): the web view starts its content below all of that and scrolls it
/// underneath, and reports how far to the pane's `PageScroll`.
struct WebDocumentView: View {
    let document: WebDocument
    let key: String
    let payload: String
    @Environment(PageScroll.self) private var scroll: PageScroll?
    /// A hundred points as the viewer's text size scales body text: how much larger than the
    /// default it is, in hundredths (a metric of 1 comes back rounded to 1 at every size).
    @ScaledMetric(relativeTo: .body) private var scaledHundred: CGFloat = 100

    /// The page's zoom over its 13 px base: a size up, as the stylesheet has it, times the
    /// viewer's text size, which scales the pages as it does the rest of the app, within what
    /// their layout can take.
    private var zoom: CGFloat {
        min(1.2 * scaledHundred / 100, 2.2)
    }

    var body: some View {
        WebDocumentHost(
            document: document, key: key, payload: payload, scroll: scroll,
            chromeHeight: scroll?.chromeHeight ?? 0, bottomRoom: scroll?.bottomRoom ?? 0, zoom: zoom
        )
        // To the window's foot too, under the home indicator.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }
}

/// Hosts a document's web view, which moves into whichever container is showing.
private struct WebDocumentHost: UIViewRepresentable {
    let document: WebDocument
    let key: String
    let payload: String
    let scroll: PageScroll?
    /// The chrome SwiftUI lays over the page's top, which UIKit's safe area doesn't know of.
    let chromeHeight: CGFloat
    /// Room to leave under the page's end beyond the system's own.
    let bottomRoom: CGFloat
    /// The page's zoom (`WebDocumentView.zoom`).
    let zoom: CGFloat

    @MainActor
    final class Coordinator {
        var scroll: PageScroll?
        weak var observed: UIScrollView?
        var observation: NSKeyValueObservation?

        func observe(_ scrollView: UIScrollView) {
            guard observed !== scrollView else { return report(scrollView) }
            observed = scrollView
            observation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.report(scrollView) }
            }
        }

        /// From the top of the page as laid out, below everything over it. This runs inside the
        /// web view's layout at times, so it reads nothing observed (see `PageScroll`).
        func report(_ scrollView: UIScrollView) {
            guard let scroll else { return }
            scroll.source = ObjectIdentifier(self)
            scroll.report(offset: scrollView.contentOffset.y)
        }

        func stop() {
            observation = nil
            if let scroll, scroll.source == ObjectIdentifier(self) { scroll.report(offset: 0) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PageContainer {
        let container = PageContainer()
        update(container, context: context)
        return container
    }

    func updateUIView(_ container: PageContainer, context: Context) {
        update(container, context: context)
    }

    static func dismantleUIView(_: PageContainer, coordinator: Coordinator) {
        coordinator.stop()
    }

    private func update(_ container: PageContainer, context: Context) {
        let webView = document.webView
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.frame = container.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(webView)
        }
        // The page leaves room at its top for the bars and the chrome (WebKit's own scrolling
        // takes no notice of a scroll view inset), and aims what it scrolls to below the bars,
        // which stay once the chrome has scrolled away.
        container.onBarsChange = { [document, chromeHeight, bottomRoom] top, bottom in
            let insets = [top, top + chromeHeight, bottom + bottomRoom + 8].map { String(Int($0.rounded())) }
            document.setting("insets", "PRDesk.setInsets(\(insets.joined(separator: ", ")))")
        }
        container.applyInsets(force: true)
        document.setting("textScale", "PRDesk.setTextScale(\(String(format: "%.3f", zoom)))")
        document.render(key: key, payload: payload)
        context.coordinator.scroll = scroll
        context.coordinator.observe(webView.scrollView)
    }
}

/// The view a page's web view sits in, under the system's bars: it tells how much of it they
/// cover, which UIKit's safe area knows (what SwiftUI lays over the page it doesn't).
final class PageContainer: UIView {
    /// Told how much of the view the system's bars cover at its top and its foot.
    var onBarsChange: ((CGFloat, CGFloat) -> Void)?
    private var reported: UIEdgeInsets?

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        applyInsets()
    }

    func applyInsets(force: Bool = false) {
        guard let scrollView = subviews.lazy.compactMap({ ($0 as? DocumentWebView)?.scrollView }).first else { return }
        // Set only when they change: this runs at every update of the view.
        if scrollView.contentInsetAdjustmentBehavior != .never { scrollView.contentInsetAdjustmentBehavior = .never }
        let bars = safeAreaInsets
        let indicators = UIEdgeInsets(top: bars.top, left: 0, bottom: bars.bottom, right: 0)
        if scrollView.verticalScrollIndicatorInsets != indicators { scrollView.verticalScrollIndicatorInsets = indicators }
        guard force || bars != reported else { return }
        reported = bars
        onBarsChange?(bars.top, bars.bottom)
    }
}
