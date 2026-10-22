import AppKit
import SwiftUI
import WebKit

/// Renders GitHub's `bodyHTML` for one comment in a self-sizing web view.
///
/// The surrounding timeline is native; only the body is HTML, so code blocks, tables,
/// images and `<details>` look as on GitHub. The view is exactly as tall as its content,
/// and forwards scrolling to the enclosing native scroll view.
struct HTMLBodyView: View {
    let id: String
    let html: String

    @State private var height: CGFloat

    init(id: String, html: String) {
        self.id = id
        self.html = html
        _height = State(initialValue: HeightCache.shared[id] ?? 20)
    }

    var body: some View {
        WebBody(html: html) { newHeight in
            guard abs(newHeight - height) > 0.5 else { return }
            height = newHeight
            HeightCache.shared[id] = newHeight
        }
        .frame(height: height)
    }
}

/// Last measured heights, so recycled rows don't jump while re-measuring.
@MainActor
private final class HeightCache {
    static let shared = HeightCache()
    private var heights: [String: CGFloat] = [:]

    subscript(id: String) -> CGFloat? {
        get { heights[id] }
        set { heights[id] = newValue }
    }
}

private struct WebBody: NSViewRepresentable {
    let html: String
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHeight: onHeight)
    }

    func makeNSView(context: Context) -> PassthroughWebView {
        let controller = WKUserContentController()
        controller.add(WeakMessageHandler(context.coordinator), name: "height")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.setURLSchemeHandler(LocalResourceHandler.shared, forURLScheme: LocalResourceHandler.scheme)
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.load(html, into: webView)
    }

    /// Fill whatever is offered rather than the web view's own fitting size; the measured
    /// content height is applied by the caller.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: PassthroughWebView, context _: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onHeight: (CGFloat) -> Void
        private var loadedHTML: String?

        init(onHeight: @escaping (CGFloat) -> Void) {
            self.onHeight = onHeight
        }

        func load(_ html: String, into webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            webView.loadHTMLString(HTMLTemplate.page(html), baseURL: WebDocument.pageURL)
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            if let height = message.body as? Double {
                onHeight(ceil(height))
            }
        }

        func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The body itself loads in place; every link opens in the browser.
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}

/// Lets the outer native scroll view handle scrolling; the body never scrolls itself.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

@MainActor
enum HTMLTemplate {
    static func page(_ body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <base href="https://github.com/">
        <style>\(css)
        \(MonospaceFont.css(family: MonospaceFont.family))</style></head>
        <body><div id="content" class="md">\(body)</div>
        <script>
          const content = document.getElementById('content');
          const post = () => window.webkit.messageHandlers.height.postMessage(content.getBoundingClientRect().height);
          new ResizeObserver(post).observe(content);
          window.addEventListener('load', post);
          document.querySelectorAll('img').forEach(img => img.addEventListener('load', post));
          post();
        </script></body></html>
        """
    }

    static let css = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
    body { font: 13px -apple-system, system-ui, sans-serif; color: CanvasText; }
    #content { display: flow-root; }
    """ + WebResources.markdownCSS
}
