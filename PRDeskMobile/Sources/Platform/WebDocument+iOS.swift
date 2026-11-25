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

/// Hosts a document's web view, which moves into whichever container is showing.
struct WebDocumentView: UIViewRepresentable {
    let document: WebDocument
    let key: String
    let payload: String

    func makeUIView(context _: Context) -> UIView {
        let container = UIView()
        host(in: container)
        document.render(key: key, payload: payload)
        return container
    }

    func updateUIView(_ container: UIView, context _: Context) {
        host(in: container)
        document.render(key: key, payload: payload)
    }

    private func host(in container: UIView) {
        let webView = document.webView
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
