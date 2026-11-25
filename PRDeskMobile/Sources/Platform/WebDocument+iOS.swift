import SwiftUI
import UIKit
import WebKit

/// The page's web view on iOS: WebKit's own, with a clear background.
typealias DocumentWebView = WKWebView

/// The iOS side of `WebDocument`: the view hosting the page. Long-press menus (people,
/// reactions, files) aren't offered yet; tapping links and reactions works as on the Mac.
extension WebDocument {
    func prepare(_ webView: DocumentWebView) {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Reading on puts the keyboard away: a phone's has no key for that.
        webView.scrollView.keyboardDismissMode = .onDrag
    }

    func showMenu(_: MenuRequest, at _: CGPoint) {}
}

/// A document's page. It reaches up under whatever is laid over its top (the navigation bar, a
/// pane's header, a `pageBar`): the web view starts its content below all of that and scrolls it
/// underneath, and reports how far to the pane's `PageScroll`.
struct WebDocumentView: View {
    let document: WebDocument
    let key: String
    let payload: String
    @Environment(PageScroll.self) private var scroll: PageScroll?

    var body: some View {
        WebDocumentHost(document: document, key: key, payload: payload, scroll: scroll, chromeHeight: scroll?.chromeHeight ?? 0)
            .ignoresSafeArea(.container, edges: .top)
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

        /// From the top of the page as laid out, below everything over it.
        func report(_ scrollView: UIScrollView) {
            guard let scroll else { return }
            let offset = scrollView.contentOffset.y
            scroll.source = ObjectIdentifier(self)
            if abs(scroll.offset - offset) > 0.2 { scroll.offset = offset }
        }

        func stop() {
            observation = nil
            if let scroll, scroll.source == ObjectIdentifier(self) { scroll.offset = 0 }
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
        container.onBarsChange = { [document, chromeHeight] bars in
            document.setting("topInset", "PRDesk.setTopInset(\(Int(bars.rounded())), \(Int((bars + chromeHeight).rounded())))")
        }
        container.applyInsets(force: true)
        document.render(key: key, payload: payload)
        context.coordinator.scroll = scroll
        context.coordinator.observe(webView.scrollView)
    }
}

/// The view a page's web view sits in, under the system's bars: it tells how tall they are, which
/// UIKit's safe area knows (what SwiftUI lays over the page it doesn't).
final class PageContainer: UIView {
    var onBarsChange: ((CGFloat) -> Void)?
    private var reportedBars: CGFloat = -1

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        applyInsets()
    }

    func applyInsets(force: Bool = false) {
        guard let scrollView = subviews.lazy.compactMap({ ($0 as? DocumentWebView)?.scrollView }).first else { return }
        scrollView.contentInsetAdjustmentBehavior = .never
        let bars = safeAreaInsets.top
        scrollView.verticalScrollIndicatorInsets.top = bars
        guard force || bars != reportedBars else { return }
        reportedBars = bars
        onBarsChange?(bars)
    }
}
